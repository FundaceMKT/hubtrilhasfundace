create table public.admin_trail_certificates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  trilha_slug text not null,
  trilha_nome text not null,
  nome_impresso text not null,
  certificate_code text not null unique check (certificate_code ~ '^FDC-ADM-[0-9A-F]{12}$'),
  certificate_issued_at timestamptz not null default now(),
  certificate_carga_horaria numeric not null check (certificate_carga_horaria > 0),
  lessons jsonb not null,
  issued_by uuid not null,
  unique (user_id, trilha_slug)
);

alter table public.admin_trail_certificates enable row level security;
revoke all on public.admin_trail_certificates from public, anon, authenticated;
grant select (
  id, user_id, trilha_slug, trilha_nome, nome_impresso, certificate_code,
  certificate_issued_at, certificate_carga_horaria, lessons
) on public.admin_trail_certificates to authenticated;
grant select on public.admin_trail_certificates to service_role;

create policy "Certificate holders and admins can read manual certificates"
  on public.admin_trail_certificates for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

create function public.emitir_certificado_admin(p_user_id uuid, p_trilha_slug text)
returns table (
  id uuid, trilha_slug text, trilha_nome text, nome_impresso text,
  certificate_code text, certificate_issued_at timestamptz,
  certificate_carga_horaria numeric, lessons jsonb
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin uuid := auth.uid();
  v_slug text := trim(p_trilha_slug);
  v_trail public.trilhas%rowtype;
  v_name text;
  v_existing public.user_trilha_starts%rowtype;
  v_issued public.admin_trail_certificates%rowtype;
  v_lessons jsonb;
begin
  if v_admin is null or not coalesce(public.is_admin(), false) then
    raise exception 'Apenas administradores podem emitir certificados.' using errcode = '42501';
  end if;
  if p_user_id is null or coalesce(v_slug, '') = '' then
    raise exception 'Selecione um aluno e uma trilha.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || v_slug, 0));

  select c.* into v_issued
  from public.admin_trail_certificates c
  where c.user_id = p_user_id and c.trilha_slug = v_slug;

  if found then
    return query select v_issued.id, v_issued.trilha_slug, v_issued.trilha_nome, v_issued.nome_impresso,
      v_issued.certificate_code, v_issued.certificate_issued_at, v_issued.certificate_carga_horaria, v_issued.lessons;
    return;
  end if;

  select t.* into v_trail from public.trilhas t where t.slug = v_slug;

  select coalesce(
    nullif(trim(l.nome), ''),
    nullif(trim(u.raw_user_meta_data->>'name'), ''),
    nullif(trim(u.raw_user_meta_data->>'nome'), ''),
    u.email
  ) into v_name
  from auth.users u
  left join lateral (
    select leads.nome
    from public.leads
    where lower(leads.email::text) = lower(u.email)
    order by leads.created_at desc nulls last, leads.id
    limit 1
  ) l on true
  where u.id = p_user_id;
  if v_name is null then
    raise exception 'Aluno não encontrado ou sem nome para impressão.';
  end if;

  select s.* into v_existing
  from public.user_trilha_starts s
  where s.user_id = p_user_id and s.trilha_slug = v_slug and s.certificate_code is not null;

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title',
    coalesce(nullif(a.titulo, ''), 'Aula ' || a.ordem)) order by a.ordem, a.id), '[]'::jsonb)
  into v_lessons
  from public.aulas a where a.trilha_id = coalesce(v_trail.id, v_existing.trilha_id);

  if v_existing.id is not null then
    return query select v_existing.id, v_existing.trilha_slug, coalesce(v_trail.nome, v_existing.trilha_nome), v_name,
      v_existing.certificate_code, v_existing.certificate_issued_at,
      coalesce(v_existing.certificate_carga_horaria, v_trail.carga_horaria), v_lessons;
    return;
  end if;
  if v_trail.id is null or v_trail.status is distinct from 'publicada' or v_trail.deleted_at is not null then
    raise exception 'Escolha uma trilha publicada.';
  end if;
  if coalesce(v_trail.carga_horaria, 0) <= 0 then
    raise exception 'Cadastre a carga horária da trilha antes de emitir o certificado.';
  end if;

  insert into public.admin_trail_certificates (
    user_id, trilha_slug, trilha_nome, nome_impresso, certificate_code,
    certificate_carga_horaria, lessons, issued_by
  ) values (
    p_user_id, v_slug, v_trail.nome, v_name,
    'FDC-ADM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
    v_trail.carga_horaria, v_lessons, v_admin
  )
  returning * into v_issued;

  return query select v_issued.id, v_issued.trilha_slug, v_issued.trilha_nome, v_issued.nome_impresso,
    v_issued.certificate_code, v_issued.certificate_issued_at, v_issued.certificate_carga_horaria, v_issued.lessons;
end;
$function$;

revoke execute on function public.emitir_certificado_admin(uuid, text) from public, anon, authenticated;
grant execute on function public.emitir_certificado_admin(uuid, text) to authenticated;

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

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || v_slug, 0));

  return query
    select c.nome_impresso, c.trilha_nome, c.certificate_code, c.certificate_issued_at, null::numeric
    from public.admin_trail_certificates c
    where c.user_id = v_user_id and c.trilha_slug = v_slug;
  if found then
    return;
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

