CREATE OR REPLACE FUNCTION public.emitir_certificado(p_trilha_slug text, p_origem text DEFAULT 'hub'::text)
 RETURNS TABLE(nome_impresso text, trilha_titulo text, codigo text, emitido_em timestamp with time zone, assistido_percentual numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_slug text := trim(coalesce(p_trilha_slug,''));
  v_nome text;
  v_titulo text;
  v_status text;
  v_total bigint := 0;
  v_watched bigint := 0;
  v_percent numeric := 0;
  v_override numeric;
  v_code text;
  v_issued timestamptz;
  v_cert_percent numeric;
  v_start_id uuid;
  v_carga_horaria numeric(6,2);
  v_cert_carga_horaria numeric(6,2);
begin
  if v_user_id is null then
    raise exception 'Autenticação obrigatória.';
  end if;

  select s.id,
         s.certificate_code,
         s.certificate_issued_at,
         s.certificate_watched_percent,
         s.watch_progress_override_percent,
         s.certificate_carga_horaria
    into v_start_id, v_code, v_issued, v_cert_percent, v_override, v_cert_carga_horaria
  from public.user_trilha_starts s
  where s.user_id = v_user_id
    and s.trilha_slug = v_slug
  order by s.started_at desc
  limit 1;

  if v_start_id is null then
    raise exception 'Confirme o início da trilha antes de solicitar o certificado.';
  end if;

  select t.nome, t.status, t.carga_horaria
    into v_titulo, v_status, v_carga_horaria
  from public.trilhas t
  where t.slug = v_slug
  limit 1;

  if v_titulo is null then
    select s.trilha_nome
      into v_titulo
    from public.user_trilha_starts s
    where s.id = v_start_id;
  end if;

  select coalesce(l.nome, u.raw_user_meta_data->>'name', u.email)
    into v_nome
  from auth.users u
  left join public.leads l on lower(l.email::text)=lower(u.email)
  where u.id = v_user_id
  limit 1;

  if v_code is not null then
    if v_cert_carga_horaria is null and v_carga_horaria is not null then
      update public.user_trilha_starts
      set certificate_carga_horaria = v_carga_horaria,
          updated_at = now()
      where id = v_start_id;
    end if;

    return query
    select v_nome,
           coalesce(v_titulo, v_slug),
           v_code,
           v_issued,
           coalesce(v_cert_percent, v_override, 100::numeric);
    return;
  end if;

  if v_status is distinct from 'publicada' then
    raise exception 'Trilha indisponível.';
  end if;

  if v_carga_horaria is null then
    raise exception 'Carga horária da trilha não cadastrada.';
  end if;

  if v_override is null and exists (select 1 from public.aulas a join public.trilhas t on t.id=a.trilha_id where t.slug=v_slug and (a.video_duration_seconds is null or a.video_duration_seconds<=0)) then
    raise exception 'Continue assistindo às aulas para liberar seu certificado. Aguarde o registro da duração de todas as aulas.';
  end if;

  if v_override is not null then
    v_percent := v_override;
  else
    select
      coalesce(sum(a.video_duration_seconds),0)::bigint,
      coalesce(sum(
        (
          select coalesce(sum(greatest(0, least(5, a.video_duration_seconds - b.bucket_start))),0)
          from public.lesson_watch_buckets b
          where b.user_id = v_user_id
            and b.trail_slug = v_slug
            and b.lesson_id = a.id::text
        )
      ),0)::bigint
    into v_total, v_watched
    from public.aulas a
    join public.trilhas t on t.id = a.trilha_id
    where t.slug = v_slug;

    if v_total <= 0 then
      raise exception 'Continue assistindo às aulas para liberar seu certificado.';
    end if;

    v_percent := round((v_watched::numeric / v_total::numeric) * 100, 2);
  end if;

  if v_percent < 90 then
    raise exception 'Continue assistindo às aulas para liberar seu certificado.';
  end if;

  v_code := 'FDC-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_issued := now();

  update public.user_trilha_starts
  set certificate_code = v_code,
      certificate_issued_at = v_issued,
      certificate_watched_percent = v_percent,
      certificate_carga_horaria = v_carga_horaria,
      updated_at = now()
  where id = v_start_id;

  return query
  select v_nome, coalesce(v_titulo, v_slug), v_code, v_issued, v_percent;
end;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_certificate_watch_threshold()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
    declare
      v_total bigint := 0;
      v_watched bigint := 0;
      v_percent numeric := 0;
    begin
      if new.certificate_code is not null
         and new.certificate_code is distinct from old.certificate_code then

        if new.watch_progress_override_percent is null and exists (select 1 from public.aulas a join public.trilhas t on t.id=a.trilha_id where t.slug=new.trilha_slug and (a.video_duration_seconds is null or a.video_duration_seconds<=0)) then
          raise exception 'Continue assistindo às aulas para liberar seu certificado. Aguarde o registro da duração de todas as aulas.';
        end if;

        if new.watch_progress_override_percent is not null then
          v_percent := new.watch_progress_override_percent;
        else
          select
            coalesce(sum(a.video_duration_seconds),0)::bigint,
            coalesce(sum(
              (
                select coalesce(sum(greatest(0, least(5, a.video_duration_seconds - b.bucket_start))),0)
                from public.lesson_watch_buckets b
                where b.user_id = new.user_id
                  and b.trail_slug = new.trilha_slug
                  and b.lesson_id = a.id::text
              )
            ),0)::bigint
          into v_total, v_watched
          from public.aulas a
          join public.trilhas t on t.id = a.trilha_id
          where t.slug = new.trilha_slug;

          if v_total > 0 then
            v_percent := round((v_watched::numeric / v_total::numeric) * 100, 2);
          end if;
        end if;

        if v_percent < 90 then
          raise exception 'Continue assistindo às aulas para liberar seu certificado.';
        end if;
      end if;

      return new;
    end;
    $function$

;
