-- ============================================================
-- Orion PLuS — atualização 04 (rode DEPOIS do 01, 02 e 03)
-- SQL Editor → New query → cole tudo → Run. Pode rodar de novo.
--
-- Cartão individual "Feliz Aniversário": o site desenha o cartão de cada
-- pessoa quando ela salva o cadastro e guarda a imagem no bucket
-- plus-fotos (pasta cartoes/). No dia, o post do Teams mostra esse cartão
-- no lugar da foto simples. Quem ainda não tem cartão continua com a foto.
-- ============================================================

alter table public.plus_aniversariantes add column if not exists cartao_path text;

-- Nova versão do cartão do Teams: recebe também o link do cartão.
-- (Apaga a antiga de 5 parâmetros pra não ficarem duas com o mesmo nome.)
drop function if exists public.plus_card_teams(text, text, text, text, text);
create or replace function public.plus_card_teams(
  p_nome text, p_email text, p_foto_url text, p_titulo text, p_texto text, p_cartao_url text default null
) returns jsonb
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
  if coalesce(p_cartao_url, '') <> '' then
    -- Cartão pronto (já tem foto, nome e "Feliz Aniversário" desenhados)
    v_body := v_body || jsonb_build_array(jsonb_build_object(
      'type', 'Image', 'url', p_cartao_url, 'size', 'Stretch', 'horizontalAlignment', 'Center',
      'altText', 'Cartão de aniversário de ' || p_nome));
  elsif coalesce(p_foto_url, '') <> '' then
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

/* ---------- plus_processar: igual ao da 02, mas manda o cartão ---------- */
create or replace function public.plus_processar(p_id uuid, p_hoje date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
  v_dias int := coalesce(nullif((select valor from public.plus_config where chave = 'dias_antecedencia'), '')::int, 3);
  v_teams text := nullif((select valor from public.plus_config where chave = 'teams_webhook_url'), '');
  v_email text := nullif((select valor from public.plus_config where chave = 'email_webhook_url'), '');
  v_foto_base text := coalesce((select valor from public.plus_config where chave = 'foto_base_url'), '');
  v_extras text := coalesce((select valor from public.plus_config where chave = 'email_destinatarios_extras'), '');
  r public.plus_aniversariantes%rowtype;
  v_foto text;
  v_cartao text;
  v_quando date;
  v_dest text;
  v_req bigint;
  v_n_teams int := 0;
  v_n_email int := 0;
begin
  select * into r from public.plus_aniversariantes where id = p_id;
  if not found or not r.ativo then return jsonb_build_object('teams', 0, 'emails', 0); end if;
  v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;
  v_cartao := case when coalesce(r.cartao_path, '') <> '' then v_foto_base || r.cartao_path else '' end;

  if v_teams is not null
     and public.plus_proximo_aniversario(r.dia, r.mes, v_hoje) = v_hoje
     and not exists (select 1 from public.plus_envios e
                     where e.aniversariante_id = r.id and e.tipo = 'teams_parabens' and e.data_ref = v_hoje) then
    select net.http_post(
      url := v_teams,
      body := public.plus_card_teams(r.nome, r.email, v_foto, '🎉🎂 Hoje é dia de festa na Orion! 🎂🎉',
                'Toda a equipe deseja um dia incrível, cheio de alegria e muitas conquistas neste novo ciclo. Deixe seu parabéns aqui embaixo! 👇🥳',
                v_cartao),
      headers := '{"Content-Type": "application/json"}'::jsonb
    ) into v_req;
    insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
    values (v_hoje, 'teams_parabens', r.id, v_req);
    v_n_teams := 1;
  end if;

  v_quando := public.plus_proximo_aniversario(r.dia, r.mes, v_hoje + 1);
  if v_email is not null
     and v_hoje >= public.plus_dia_do_aviso(v_quando, v_dias)
     and not exists (select 1 from public.plus_envios e
                     where e.aniversariante_id = r.id and e.tipo = 'email_aviso'
                       and e.data_ref > v_quando - 40 and e.data_ref < v_quando) then
    select string_agg(distinct x.e, ';') into v_dest from (
      select lower(trim(email)) e from public.plus_aniversariantes where ativo and email is not null
      union
      select lower(trim(email)) from public.usuarios_permissoes where email is not null
      union
      select lower(trim(t)) from unnest(string_to_array(replace(v_extras, ',', ';'), ';')) t
    ) x
    where x.e like '%@oriontransmissao.com.br'
      and x.e <> lower(coalesce(r.email, ''));
    if v_dest is not null then
      select net.http_post(
        url := v_email,
        body := jsonb_build_object(
          'destinatarios', v_dest,
          'assunto', '🎈 O aniversário de ' || r.nome || ' está chegando! (' || to_char(v_quando, 'DD/MM') || ')',
          'mensagem_html', public.plus_email_aviso(r.nome, v_foto, v_quando, v_quando - v_hoje)),
        headers := '{"Content-Type": "application/json"}'::jsonb
      ) into v_req;
      insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
      values (v_hoje, 'email_aviso', r.id, v_req);
      v_n_email := 1;
    end if;
  end if;

  return jsonb_build_object('teams', v_n_teams, 'emails', v_n_email);
end $$;
revoke execute on function public.plus_processar(uuid, date) from public, anon, authenticated;

/* ---------- Teste do Teams agora mostra o SEU cartão (se já tiver) ---------- */
create or replace function public.plus_testar(p_canal text) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_url text;
  v_eu record;
  v_req bigint;
  v_base text := (select valor from public.plus_config where chave = 'foto_base_url');
  v_foto text;
  v_cartao text;
begin
  if not public.plus_is_admin() then raise exception 'Só administrador.'; end if;
  select a.*, u.email as email_conta into v_eu
    from auth.users u left join public.plus_aniversariantes a on a.user_id = u.id
   where u.id = auth.uid();
  v_foto := case when coalesce(v_eu.foto_path, '') <> '' then v_base || v_eu.foto_path else '' end;
  v_cartao := case when coalesce(v_eu.cartao_path, '') <> '' then v_base || v_eu.cartao_path else '' end;
  if p_canal = 'teams' then
    v_url := nullif((select valor from public.plus_config where chave = 'teams_webhook_url'), '');
    if v_url is null then raise exception 'Cole o link do Teams e salve antes de testar.'; end if;
    select net.http_post(url := v_url,
      body := public.plus_card_teams(coalesce(v_eu.nome, v_eu.email_conta), v_eu.email_conta, v_foto,
                '🧪 Teste do Orion PLuS',
                'Se você está vendo esta mensagem, o parabéns automático está funcionando. Pode ignorar! ✅',
                v_cartao),
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
