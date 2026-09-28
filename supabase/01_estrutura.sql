-- ============================================================
-- Orion PLuS — estrutura no Supabase
-- Roda no MESMO projeto do GPS Orion (as contas de login são as mesmas).
-- Como usar: Supabase → SQL Editor → New query → cole este arquivo
-- inteiro → Run. Pode rodar de novo sem medo: tudo aqui é "se não
-- existir, cria" / "substitui a função", nada apaga dados.
--
-- Tudo do PLuS usa o prefixo plus_ pra não misturar com as tabelas do GPS.
-- Única coisa do GPS que o PLuS LÊ (sem alterar): usuarios_permissoes,
-- pra saber quem é administrador ('admin' ou 'plus_admin' em abas) e pra
-- pegar os e-mails de quem tem conta no GPS na hora de mandar os avisos.
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

/* ---------- Tabela principal: uma linha por aniversariante ----------
   user_id fica vazio nas pessoas importadas das fotos antigas (ainda sem
   conta) — quando a pessoa cria conta, ela "reivindica" a própria linha
   (ver plus_reivindicar) em vez de ficar duplicada. Só dia e mês, sem ano. */
create table if not exists public.plus_aniversariantes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  nome text not null,
  email text,
  dia smallint not null check (dia between 1 and 31),
  mes smallint not null check (mes between 1 and 12),
  foto_path text,
  consentimento boolean not null default false,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint plus_data_valida check (
    (mes = 2 and dia <= 29) or (mes in (4, 6, 9, 11) and dia <= 30) or mes in (1, 3, 5, 7, 8, 10, 12)
  )
);

/* ---------- Configuração da automação (links do Teams/e-mail etc.) ----------
   Sem nenhuma policy de RLS de propósito: ninguém lê direto pela API, só
   as funções abaixo (e o painel do Supabase). Os links de webhook são
   "senhas" — quem tiver o link consegue postar no grupo do Teams. */
create table if not exists public.plus_config (
  chave text primary key,
  valor text not null default ''
);
insert into public.plus_config (chave, valor) values
  ('teams_webhook_url', ''),
  ('email_webhook_url', ''),
  ('site_url', ''),
  ('dias_antecedencia', '3'),
  ('teams_mencionar', 'sim'),
  ('email_destinatarios_extras', ''),
  ('foto_base_url', 'https://nwoealwevimhnqdmuhxh.supabase.co/storage/v1/object/public/plus-fotos/')
on conflict (chave) do nothing;

/* ---------- Registro do que já foi enviado ----------
   Evita mandar o mesmo aviso duas vezes se a rotina rodar de novo no
   mesmo dia (ex.: alguém clicou em "rodar agora" depois do horário). */
create table if not exists public.plus_envios (
  id bigserial primary key,
  data_ref date not null,
  tipo text not null,               -- 'teams_parabens' | 'email_aviso'
  aniversariante_id uuid references public.plus_aniversariantes(id) on delete cascade,
  request_id bigint,                -- id do pg_net, pra conferir a resposta
  criado_em timestamptz not null default now(),
  unique (data_ref, tipo, aniversariante_id)
);

/* ---------- Quem é administrador do PLuS ----------
   to_jsonb() funciona tanto se abas for text[] quanto jsonb. */
create or replace function public.plus_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.usuarios_permissoes p
    where p.id = auth.uid()
      and (to_jsonb(p.abas) ? 'admin' or to_jsonb(p.abas) ? 'plus_admin')
  );
$$;
grant execute on function public.plus_is_admin() to authenticated;

/* ---------- RLS da tabela principal ----------
   Qualquer pessoa logada vê todo mundo (é a ideia do site). Cada um só
   cria/edita a própria linha; administrador mexe em qualquer uma. */
alter table public.plus_aniversariantes enable row level security;
alter table public.plus_config enable row level security;
alter table public.plus_envios enable row level security;

drop policy if exists plus_aniv_select on public.plus_aniversariantes;
create policy plus_aniv_select on public.plus_aniversariantes
  for select to authenticated using (true);

drop policy if exists plus_aniv_insert on public.plus_aniversariantes;
create policy plus_aniv_insert on public.plus_aniversariantes
  for insert to authenticated
  with check (user_id = auth.uid() or public.plus_is_admin());

drop policy if exists plus_aniv_update on public.plus_aniversariantes;
create policy plus_aniv_update on public.plus_aniversariantes
  for update to authenticated
  using (user_id = auth.uid() or public.plus_is_admin())
  with check (user_id = auth.uid() or public.plus_is_admin());

drop policy if exists plus_aniv_delete on public.plus_aniversariantes;
create policy plus_aniv_delete on public.plus_aniversariantes
  for delete to authenticated
  using (user_id = auth.uid() or public.plus_is_admin());

drop policy if exists plus_envios_select on public.plus_envios;
create policy plus_envios_select on public.plus_envios
  for select to authenticated using (public.plus_is_admin());

/* ---------- "Esse aí sou eu": vincular uma linha importada à conta ---------- */
create or replace function public.plus_reivindicar(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Faça login primeiro.'; end if;
  if exists (select 1 from public.plus_aniversariantes where user_id = auth.uid()) then
    raise exception 'Você já tem um cadastro no Orion PLuS.';
  end if;
  update public.plus_aniversariantes
     set user_id = auth.uid(),
         email = (select u.email from auth.users u where u.id = auth.uid()),
         atualizado_em = now()
   where id = p_id and user_id is null;
  if not found then raise exception 'Esse cadastro já está vinculado a outra conta.'; end if;
end $$;
revoke execute on function public.plus_reivindicar(uuid) from public, anon;
grant execute on function public.plus_reivindicar(uuid) to authenticated;

/* ---------- Configuração pelo site (só administrador) ---------- */
create or replace function public.plus_ler_config() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.plus_is_admin() then raise exception 'Só administrador.'; end if;
  return (select coalesce(jsonb_object_agg(chave, valor), '{}'::jsonb) from public.plus_config);
end $$;
revoke execute on function public.plus_ler_config() from public, anon;
grant execute on function public.plus_ler_config() to authenticated;

create or replace function public.plus_salvar_config(p_config jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text; v text;
begin
  if not public.plus_is_admin() then raise exception 'Só administrador.'; end if;
  for k, v in select * from jsonb_each_text(p_config) loop
    -- Só aceita as chaves conhecidas (as que o insert lá em cima criou).
    update public.plus_config set valor = coalesce(v, '') where chave = k;
  end loop;
end $$;
revoke execute on function public.plus_salvar_config(jsonb) from public, anon;
grant execute on function public.plus_salvar_config(jsonb) to authenticated;

/* ---------- Datas ----------
   29/02 em ano que não é bissexto comemora em 28/02. */
create or replace function public.plus_data_no_ano(p_dia int, p_mes int, p_ano int) returns date
language sql immutable as $$
  select case
    when p_mes = 2 and p_dia = 29 and not (p_ano % 4 = 0 and (p_ano % 100 <> 0 or p_ano % 400 = 0))
      then make_date(p_ano, 2, 28)
    else make_date(p_ano, p_mes, p_dia)
  end;
$$;

create or replace function public.plus_proximo_aniversario(p_dia int, p_mes int, p_de date) returns date
language sql immutable as $$
  select case
    when public.plus_data_no_ano(p_dia, p_mes, extract(year from p_de)::int) >= p_de
      then public.plus_data_no_ano(p_dia, p_mes, extract(year from p_de)::int)
    else public.plus_data_no_ano(p_dia, p_mes, extract(year from p_de)::int + 1)
  end;
$$;

-- Dia do aviso antecipado: N dias antes; se cair no fim de semana, vai na
-- sexta-feira anterior (ninguém lê e-mail de trabalho no sábado).
create or replace function public.plus_dia_do_aviso(p_aniversario date, p_dias int) returns date
language sql immutable as $$
  select case extract(dow from p_aniversario - p_dias)::int
    when 6 then p_aniversario - p_dias - 1
    when 0 then p_aniversario - p_dias - 2
    else p_aniversario - p_dias
  end;
$$;

create or replace function public.plus_html(p text) returns text
language sql immutable as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

/* ---------- Mensagem do Teams (Adaptive Card) ----------
   Formato que o fluxo "Postar em um canal quando uma solicitação de
   webhook for recebida" do app Workflows do Teams espera. */
create or replace function public.plus_card_teams(p_nome text, p_email text, p_foto_url text, p_titulo text, p_texto text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_site text := (select valor from public.plus_config where chave = 'site_url');
  v_mencionar boolean := coalesce((select valor from public.plus_config where chave = 'teams_mencionar'), 'sim') = 'sim'
                         and coalesce(p_email, '') <> '';
  v_nome_txt text := case when v_mencionar then '<at>' || p_nome || '</at>' else p_nome end;
  v_body jsonb;
  v_card jsonb;
begin
  v_body := jsonb_build_array(
    jsonb_build_object('type', 'TextBlock', 'text', p_titulo, 'size', 'Large', 'weight', 'Bolder',
                       'color', 'Accent', 'horizontalAlignment', 'Center', 'wrap', true)
  );
  if coalesce(p_foto_url, '') <> '' then
    v_body := v_body || jsonb_build_array(jsonb_build_object(
      'type', 'Image', 'url', p_foto_url, 'size', 'Large', 'style', 'Person', 'horizontalAlignment', 'Center'));
  end if;
  v_body := v_body || jsonb_build_array(
    jsonb_build_object('type', 'TextBlock', 'text', 'Parabéns, ' || v_nome_txt || '! 🎈', 'size', 'ExtraLarge',
                       'weight', 'Bolder', 'horizontalAlignment', 'Center', 'wrap', true),
    jsonb_build_object('type', 'TextBlock', 'text', p_texto, 'horizontalAlignment', 'Center', 'wrap', true)
  );
  v_card := jsonb_build_object(
    '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type', 'AdaptiveCard', 'version', '1.4', 'body', v_body);
  if coalesce(v_site, '') <> '' then
    v_card := v_card || jsonb_build_object('actions', jsonb_build_array(
      jsonb_build_object('type', 'Action.OpenUrl', 'title', '🎂 Abrir o Orion PLuS', 'url', v_site)));
  end if;
  if v_mencionar then
    v_card := v_card || jsonb_build_object('msteams', jsonb_build_object('entities', jsonb_build_array(
      jsonb_build_object('type', 'mention', 'text', '<at>' || p_nome || '</at>',
                         'mentioned', jsonb_build_object('id', p_email, 'name', p_nome)))));
  end if;
  return jsonb_build_object('type', 'message', 'attachments', jsonb_build_array(jsonb_build_object(
    'contentType', 'application/vnd.microsoft.card.adaptive', 'contentUrl', null, 'content', v_card)));
end $$;

/* ---------- E-mail do aviso antecipado ---------- */
create or replace function public.plus_email_aviso(p_nome text, p_foto_url text, p_data date, p_faltam int) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_site text := (select valor from public.plus_config where chave = 'site_url');
  v_semana text[] := array['domingo','segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado'];
  v_quando text := case p_faltam when 1 then 'amanhã' else 'daqui a ' || p_faltam || ' dias' end;
  v_foto text := case when coalesce(p_foto_url, '') <> ''
    then '<img src="' || p_foto_url || '" width="140" height="140" style="border-radius:50%;border:5px solid #ffffff;box-shadow:0 0 0 4px #f06292;object-fit:cover;" alt="">'
    else '' end;
  v_botao text := case when coalesce(v_site, '') <> ''
    then '<p style="margin:22px 0 0;"><a href="' || v_site || '" style="background:#d81b60;color:#ffffff;text-decoration:none;padding:11px 22px;border-radius:24px;font-weight:bold;display:inline-block;">Ver no Orion PLuS 🎂</a></p>'
    else '' end;
begin
  return '<div style="font-family:Segoe UI,Arial,sans-serif;background:#fff0f6;padding:28px 12px;">'
    || '<div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:18px;padding:28px 26px;text-align:center;border:1px solid #f8c8dc;">'
    || '<div style="font-size:34px;line-height:1;">🎈🎂🎉</div>'
    || '<h2 style="color:#ad1457;margin:12px 0 18px;">O aniversário de ' || public.plus_html(p_nome) || ' está chegando!</h2>'
    || v_foto
    || '<p style="font-size:16px;color:#4a2338;margin:18px 0 6px;">É <b>' || v_quando || '</b>: '
    || v_semana[extract(dow from p_data)::int + 1] || ', <b>' || to_char(p_data, 'DD/MM') || '</b>.</p>'
    || '<p style="font-size:15px;color:#4a2338;margin:6px 0;">Seja legal e dê os parabéns pra ' || public.plus_html(split_part(p_nome, ' ', 1))
    || ' no dia — uma mensagem, um abraço ou um café já fazem a diferença! 💖</p>'
    || '<p style="font-size:13px;color:#8a6479;margin:14px 0 0;">🤫 Psiu: esse e-mail foi pra todo mundo, menos pra quem está fazendo aniversário.</p>'
    || v_botao
    || '<p style="font-size:11.5px;color:#b08aa0;margin:24px 0 0;">Orion PLuS — mais um ano pra celebrar · aviso automático do RH</p>'
    || '</div></div>';
end $$;

/* ---------- A rotina diária ----------
   Roda sozinha todo dia às 8h (horário de Brasília) pelo pg_cron (ver o
   fim do arquivo). 1) Parabéns no grupo do Teams no dia. 2) E-mail de
   aviso N dias antes pra todo mundo MENOS o aniversariante. */
create or replace function public.plus_rodar_avisos(p_hoje date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
  v_dias int := coalesce(nullif((select valor from public.plus_config where chave = 'dias_antecedencia'), '')::int, 3);
  v_teams text := nullif((select valor from public.plus_config where chave = 'teams_webhook_url'), '');
  v_email text := nullif((select valor from public.plus_config where chave = 'email_webhook_url'), '');
  v_foto_base text := coalesce((select valor from public.plus_config where chave = 'foto_base_url'), '');
  v_extras text := coalesce((select valor from public.plus_config where chave = 'email_destinatarios_extras'), '');
  r record;
  v_foto text;
  v_dest text;
  v_req bigint;
  v_n_teams int := 0;
  v_n_email int := 0;
begin
  -- 1) Parabéns do dia no Teams
  if v_teams is not null then
    for r in
      select a.* from public.plus_aniversariantes a
      where a.ativo
        and public.plus_proximo_aniversario(a.dia, a.mes, v_hoje) = v_hoje
        and not exists (select 1 from public.plus_envios e
                        where e.aniversariante_id = a.id and e.tipo = 'teams_parabens' and e.data_ref = v_hoje)
    loop
      v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;
      select net.http_post(
        url := v_teams,
        body := public.plus_card_teams(r.nome, r.email, v_foto, '🎉🎂 Hoje é dia de festa na Orion! 🎂🎉',
                  'Toda a equipe deseja um dia incrível, cheio de alegria e muitas conquistas neste novo ciclo. Deixe seu parabéns aqui embaixo! 👇🥳'),
        headers := '{"Content-Type": "application/json"}'::jsonb
      ) into v_req;
      insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
      values (v_hoje, 'teams_parabens', r.id, v_req);
      v_n_teams := v_n_teams + 1;
    end loop;
  end if;

  -- 2) E-mail de aviso antecipado
  if v_email is not null then
    for r in
      select a.*, public.plus_proximo_aniversario(a.dia, a.mes, v_hoje + 1) as quando
      from public.plus_aniversariantes a
      where a.ativo
        and public.plus_dia_do_aviso(public.plus_proximo_aniversario(a.dia, a.mes, v_hoje + 1), v_dias) = v_hoje
        and not exists (select 1 from public.plus_envios e
                        where e.aniversariante_id = a.id and e.tipo = 'email_aviso' and e.data_ref = v_hoje)
    loop
      select string_agg(distinct x.e, ';') into v_dest from (
        select lower(trim(email)) e from public.plus_aniversariantes where ativo and email is not null
        union
        select lower(trim(email)) from public.usuarios_permissoes where email is not null
        union
        select lower(trim(t)) from unnest(string_to_array(replace(v_extras, ',', ';'), ';')) t
      ) x
      where x.e like '%@oriontransmissao.com.br'
        and x.e <> lower(coalesce(r.email, ''));
      continue when v_dest is null;
      v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;
      select net.http_post(
        url := v_email,
        body := jsonb_build_object(
          'destinatarios', v_dest,
          'assunto', '🎈 O aniversário de ' || r.nome || ' está chegando! (' || to_char(r.quando, 'DD/MM') || ')',
          'mensagem_html', public.plus_email_aviso(r.nome, v_foto, r.quando, r.quando - v_hoje)),
        headers := '{"Content-Type": "application/json"}'::jsonb
      ) into v_req;
      insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
      values (v_hoje, 'email_aviso', r.id, v_req);
      v_n_email := v_n_email + 1;
    end loop;
  end if;

  return jsonb_build_object('data', v_hoje, 'teams', v_n_teams, 'emails', v_n_email);
end $$;
-- Ninguém chama pela API — só o agendamento (pg_cron roda como postgres).
revoke execute on function public.plus_rodar_avisos(date) from public, anon, authenticated;

/* ---------- Botões de teste da página de administração ----------
   Manda uma mensagem de teste só pro próprio administrador (no Teams, o
   post vai pro grupo, mas marcado como teste). Devolve o id do pg_net pra
   página conferir depois se o Teams/Power Automate respondeu OK. */
create or replace function public.plus_testar(p_canal text) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_url text;
  v_eu record;
  v_req bigint;
  v_foto text;
begin
  if not public.plus_is_admin() then raise exception 'Só administrador.'; end if;
  select a.*, u.email as email_conta into v_eu
    from auth.users u left join public.plus_aniversariantes a on a.user_id = u.id
   where u.id = auth.uid();
  v_foto := case when coalesce(v_eu.foto_path, '') <> ''
    then (select valor from public.plus_config where chave = 'foto_base_url') || v_eu.foto_path else '' end;
  if p_canal = 'teams' then
    v_url := nullif((select valor from public.plus_config where chave = 'teams_webhook_url'), '');
    if v_url is null then raise exception 'Cole o link do Teams e salve antes de testar.'; end if;
    select net.http_post(url := v_url,
      body := public.plus_card_teams(coalesce(v_eu.nome, v_eu.email_conta), v_eu.email_conta, v_foto,
                '🧪 Teste do Orion PLuS',
                'Se você está vendo esta mensagem, o parabéns automático está funcionando. Pode ignorar! ✅'),
      headers := '{"Content-Type": "application/json"}'::jsonb) into v_req;
  elsif p_canal = 'email' then
    v_url := nullif((select valor from public.plus_config where chave = 'email_webhook_url'), '');
    if v_url is null then raise exception 'Cole o link do fluxo de e-mail e salve antes de testar.'; end if;
    select net.http_post(url := v_url,
      body := jsonb_build_object('destinatarios', v_eu.email_conta,
        'assunto', '🧪 Teste do Orion PLuS — aviso de aniversário',
        'mensagem_html', public.plus_email_aviso(coalesce(v_eu.nome, 'Fulano de Tal'), v_foto,
          (now() at time zone 'America/Sao_Paulo')::date + 3, 3)),
      headers := '{"Content-Type": "application/json"}'::jsonb) into v_req;
  else
    raise exception 'Canal desconhecido.';
  end if;
  return v_req;
end $$;
revoke execute on function public.plus_testar(text) from public, anon;
grant execute on function public.plus_testar(text) to authenticated;

create or replace function public.plus_resultado_envio(p_request_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.plus_is_admin() then raise exception 'Só administrador.'; end if;
  select status_code, left(content, 300) as content, error_msg into r
    from net._http_response where id = p_request_id;
  if not found then return jsonb_build_object('pendente', true); end if;
  return jsonb_build_object('status', r.status_code, 'resposta', r.content, 'erro', r.error_msg);
end $$;
revoke execute on function public.plus_resultado_envio(bigint) from public, anon;
grant execute on function public.plus_resultado_envio(bigint) to authenticated;

/* ---------- Fotos (Supabase Storage) ----------
   Bucket público: o Teams e o e-mail precisam abrir a foto por link, sem
   login. Os nomes dos arquivos são aleatórios, não dá pra "adivinhar". */
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('plus-fotos', 'plus-fotos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists plus_fotos_select on storage.objects;
create policy plus_fotos_select on storage.objects
  for select to authenticated using (bucket_id = 'plus-fotos');
drop policy if exists plus_fotos_insert on storage.objects;
create policy plus_fotos_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'plus-fotos');
drop policy if exists plus_fotos_delete on storage.objects;
create policy plus_fotos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'plus-fotos' and (owner_id = auth.uid()::text or public.plus_is_admin()));

/* ---------- Agendamento: todo dia às 8h de Brasília (11h UTC) ---------- */
select cron.unschedule(jobid) from cron.job where jobname = 'plus-avisos-diarios';
select cron.schedule('plus-avisos-diarios', '0 11 * * *', $$select public.plus_rodar_avisos()$$);
