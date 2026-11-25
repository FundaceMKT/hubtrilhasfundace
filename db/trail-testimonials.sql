alter table public.trilha_nps_respostas
  add column publication_status text not null default 'pending'
    check (publication_status in ('pending', 'published', 'unpublished')),
  add column public_name text,
  add column published_at timestamptz,
  add column published_by uuid,
  add column unpublished_at timestamptz,
  add column unpublished_by uuid,
  add constraint trail_testimonials_publication_metadata check (
    publication_status <> 'published'
    or (public_name is not null and published_at is not null and published_by is not null)
  );

create index trail_testimonials_published_idx
  on public.trilha_nps_respostas (trail_slug, created_at desc, id desc)
  where publication_status = 'published';

create function public.trail_testimonial_public_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  with parts as (
    select regexp_split_to_array(
      btrim(regexp_replace(p_name, '[[:space:]]+', ' ', 'g')), ' '
    ) as tokens
  ), name_parts as (
    select tokens[1] as first_name, tokens[cardinality(tokens)] as last_name,
           array_to_string(tokens, ' ') as full_name
    from parts
    where cardinality(tokens) >= 2
  )
  select first_name || ' ' || upper(left(last_name, 1)) || '.'
  from name_parts
  where full_name ~ '^[[:alpha:]]+([''’-][[:alpha:]]+)*( [[:alpha:]]+([''’-][[:alpha:]]+)*)+$'
    and char_length(first_name) between 2 and 60
    and char_length(last_name) >= 2
    and lower(last_name) not in ('de', 'da', 'das', 'do', 'dos', 'e')
    and lower(first_name) not in ('aluno', 'aluna', 'visitante', 'sem', 'usuário', 'usuaria', 'usuária');
$$;

revoke all on function public.trail_testimonial_public_name(text) from public, anon, authenticated, service_role;

-- O reenvio pelo RPC existente continua normal. Um texto ou uma identidade
-- diferente precisa passar por uma nova revisão antes de voltar à LP.
create function public.reset_trail_testimonial_on_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.publication_status := 'pending';
  new.public_name := null;
  return new;
end;
$$;

revoke all on function public.reset_trail_testimonial_on_edit() from public, anon, authenticated, service_role;

create trigger reset_trail_testimonial_on_edit
before update of trail_slug, lead_email, lead_nome, score, comentario on public.trilha_nps_respostas
for each row
when (
  (old.trail_slug, old.lead_email, old.lead_nome, old.score, old.comentario)
    is distinct from
  (new.trail_slug, new.lead_email, new.lead_nome, new.score, new.comentario)
)
execute function public.reset_trail_testimonial_on_edit();

create function public.set_trail_testimonial_publication(
  p_feedback_id bigint,
  p_status text,
  p_expected_status text,
  p_expected_updated_at timestamptz,
  p_authorization_verified boolean default false
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid := auth.uid();
  v_feedback public.trilha_nps_respostas%rowtype;
  v_name text;
begin
  if v_admin is null or public.is_admin() is distinct from true then
    raise exception 'Apenas administradores podem alterar a publicação.' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('published', 'unpublished') then
    raise exception 'Ação de publicação inválida.';
  end if;

  select * into v_feedback
  from public.trilha_nps_respostas
  where id = p_feedback_id
  for update;

  if not found then
    raise exception 'Feedback não encontrado.';
  end if;

  if v_feedback.publication_status is distinct from p_expected_status
     or v_feedback.updated_at is distinct from p_expected_updated_at then
    raise exception 'O feedback mudou. Atualize a lista e revise o registro novamente.';
  end if;

  if p_status = 'published' then
    if p_authorization_verified is distinct from true then
      raise exception 'Valide a autorização aplicável antes de publicar.';
    end if;

    v_name := public.trail_testimonial_public_name(v_feedback.lead_nome);
    if v_name is null then
      raise exception 'O nome do aluno precisa ser revisado antes da publicação.';
    end if;

    if nullif(btrim(v_feedback.comentario), '') is null then
      raise exception 'O feedback precisa ter um comentário para ser publicado.';
    end if;

    if strpos(v_feedback.comentario, '@') > 0
       or v_feedback.comentario ~ '([[:digit:]][[:blank:]().+-]*){8}' then
      raise exception 'O comentário pode conter e-mail, telefone ou outro identificador. Revise o registro antes de publicar.';
    end if;

    if v_feedback.publication_status <> 'published' then
      update public.trilha_nps_respostas
      set publication_status = 'published',
          public_name = v_name,
          published_by = v_admin,
          published_at = now()
      where id = p_feedback_id;
    end if;
  elsif v_feedback.publication_status = 'published' then
    update public.trilha_nps_respostas
    set publication_status = 'unpublished',
        public_name = null,
        unpublished_by = v_admin,
        unpublished_at = now()
    where id = p_feedback_id;
  else
    raise exception 'O feedback não está publicado.';
  end if;

  return p_status;
end;
$$;

revoke all on function public.set_trail_testimonial_publication(bigint, text, text, timestamptz, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.set_trail_testimonial_publication(bigint, text, text, timestamptz, boolean)
  to authenticated;

-- A tabela mantém sua política de leitura exclusiva do admin. A API pública
-- devolve uma projeção fixa, com no máximo três avaliações por chamada.
create function public.list_public_trail_testimonials(p_trail_slug text, p_offset integer default 0)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with matches as (
    select id, public_name, score, comentario as comment, created_at, trail_slug
    from public.trilha_nps_respostas
    where publication_status = 'published'
      and trail_slug = p_trail_slug
    order by created_at desc, id desc
    limit 4 offset greatest(0, coalesce(p_offset, 0))
  ), page as (
    select *
    from matches
    order by created_at desc, id desc
    limit 3
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(page) - 'id' order by created_at desc, id desc) from page), '[]'::jsonb),
    'has_more', (select count(*) > 3 from matches)
  );
$$;

revoke all on function public.list_public_trail_testimonials(text, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.list_public_trail_testimonials(text, integer)
  to anon, authenticated;
