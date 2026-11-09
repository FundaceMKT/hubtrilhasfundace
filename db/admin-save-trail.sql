-- Atomic Admin create/edit. Invoker permissions preserve existing RLS.
create or replace function public.save_trilha_admin(
  p_trilha_id uuid, p_values jsonb, p_lessons jsonb, p_expected jsonb default null
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_trail public.trilhas%rowtype;
  v_lesson jsonb;
  v_id uuid;
  v_ids uuid[] := '{}';
  v_order integer := 0;
  v_snapshot jsonb;
  v_old_name text;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Acesso administrativo necessário.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lessons) is distinct from 'array' then raise exception 'Aulas inválidas.'; end if;
  if jsonb_array_length(p_lessons) < 1 then raise exception 'Adicione pelo menos uma aula.'; end if;
  if coalesce(btrim(p_values->>'nome'),'') = '' or char_length(coalesce(p_values->>'descricao','')) > 250
     or coalesce((p_values->>'carga_horaria')::numeric,0) <= 0
     or nullif(p_values->>'curso_id','') is null then raise exception 'Confira nome, descrição (até 250 caracteres), curso e carga horária.'; end if;
  if coalesce(p_values->>'lp_url','') <> '' and (p_values->>'lp_url') !~* '^https://[^[:space:]]+$' then raise exception 'A URL da LP precisa começar com https://'; end if;
  if coalesce((p_values->>'lp_ativa')::boolean,false) and coalesce(btrim(p_values->>'lp_url'),'') = '' then raise exception 'Informe a URL da LP.'; end if;
  if p_trilha_id is not null then
    select * into v_trail from public.trilhas where id=p_trilha_id and deleted_at is null for update;
    if not found then raise exception 'Trilha não encontrada ou arquivada.'; end if;
    perform 1 from public.aulas where trilha_id=p_trilha_id for update;
    select jsonb_build_object('atualizada_em',v_trail.atualizada_em,'aulas',coalesce(jsonb_agg(jsonb_build_object('id',a.id,'atualizada_em',a.atualizada_em) order by a.id),'[]'::jsonb))
      into v_snapshot from public.aulas a where a.trilha_id=p_trilha_id;
    if p_expected is distinct from v_snapshot then raise exception 'Esta trilha foi alterada em outra sessão. Feche e abra a edição novamente.' using errcode='40001'; end if;
    v_old_name := v_trail.nome;
    -- Slug, publication state and enrollment settings are intentionally immutable here.
    update public.trilhas set nome=btrim(p_values->>'nome'),descricao=coalesce(p_values->>'descricao',''),curso_id=(p_values->>'curso_id')::uuid,
      carga_horaria=(p_values->>'carga_horaria')::numeric,lp_url=nullif(btrim(p_values->>'lp_url'),''),lp_ativa=coalesce((p_values->>'lp_ativa')::boolean,false)
      where id=p_trilha_id returning * into v_trail;
  else
    if coalesce(p_values->>'slug','') !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then raise exception 'URL oficial inválida.'; end if;
    insert into public.trilhas(nome,slug,descricao,curso_id,carga_horaria,lp_url,lp_ativa,status)
      values(btrim(p_values->>'nome'),p_values->>'slug',coalesce(p_values->>'descricao',''),(p_values->>'curso_id')::uuid,
        (p_values->>'carga_horaria')::numeric,nullif(btrim(p_values->>'lp_url'),''),coalesce((p_values->>'lp_ativa')::boolean,false),'rascunho') returning * into v_trail;
  end if;
  for v_lesson in select value from jsonb_array_elements(p_lessons) loop
    v_order := v_order+1;
    if coalesce(btrim(v_lesson->>'titulo'),'')='' or coalesce(v_lesson->>'vimeo_id','')='' or coalesce(v_lesson->>'video_provider','') not in ('vimeo','youtube') then raise exception 'Confira o título e vídeo de todas as aulas.'; end if;
    v_id := nullif(v_lesson->>'id','')::uuid;
    if v_id is not null then
      if p_trilha_id is null or v_id=any(v_ids) then raise exception 'ID de aula inválido ou duplicado.'; end if;
      update public.aulas set titulo=btrim(v_lesson->>'titulo'),descricao=coalesce(v_lesson->>'descricao',''),
        vimeo_id=v_lesson->>'vimeo_id',video_provider=v_lesson->>'video_provider',ordem=v_order,
        video_duration_seconds=case when vimeo_id is distinct from v_lesson->>'vimeo_id' or video_provider is distinct from v_lesson->>'video_provider' then null else video_duration_seconds end,
        duracao=case when vimeo_id is distinct from v_lesson->>'vimeo_id' or video_provider is distinct from v_lesson->>'video_provider' then null else duracao end
        where id=v_id and trilha_id=v_trail.id;
      if not found then raise exception 'A aula não pertence a esta trilha.'; end if;
    else
      insert into public.aulas(trilha_id,titulo,descricao,vimeo_id,video_provider,ordem)
        values(v_trail.id,btrim(v_lesson->>'titulo'),coalesce(v_lesson->>'descricao',''),v_lesson->>'vimeo_id',v_lesson->>'video_provider',v_order) returning id into v_id;
    end if;
    v_ids := array_append(v_ids,v_id);
  end loop;
  -- Only rows omitted explicitly from the verified editor snapshot are removed.
  delete from public.aulas where trilha_id=v_trail.id and not(id=any(v_ids))
    and id in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p_expected->'aulas','[]'::jsonb)) x);
  if p_trilha_id is not null then
    update public.trilha_activecampaign_tags set trilha_nome=v_trail.nome,trilha_id=v_trail.id,curso_id=v_trail.curso_id,updated_at=now()
      where trilha_slug=v_trail.slug and (trilha_nome,trilha_id,curso_id) is distinct from (v_trail.nome,v_trail.id,v_trail.curso_id);
    update public.user_trilha_starts set trilha_nome=v_trail.nome,curso_id=v_trail.curso_id,updated_at=now()
      where (trilha_id=v_trail.id or trilha_slug=v_trail.slug) and (trilha_nome,curso_id) is distinct from (v_trail.nome,v_trail.curso_id);
    if v_old_name is distinct from v_trail.nome then
      update public.leads set nome_trilha=v_trail.nome where nome_trilha=v_old_name;
    end if;
  end if;
  return jsonb_build_object('trilha',to_jsonb(v_trail),'aulas',(select jsonb_agg(to_jsonb(a) order by ordem) from public.aulas a where a.trilha_id=v_trail.id));
end;
$$;
revoke all on function public.save_trilha_admin(uuid,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.save_trilha_admin(uuid,jsonb,jsonb,jsonb) to authenticated;
