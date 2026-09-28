-- ============================================================
-- Orion PLuS — atualização 02 (rode DEPOIS do 01_estrutura.sql)
-- SQL Editor → New query → cole tudo → Run. Pode rodar de novo.
--
-- 1) Coluna "cor": cada pessoa escolhe a cor da bolinha atrás da foto
--    (no site e no cartaz do mês).
-- 2) Aviso imediato: se alguém se cadastra (ou corrige a data) já
--    dentro da janela do aviso — ex.: o aniversário é amanhã — o e-mail
--    "está chegando" sai na hora, em vez de nunca sair. E se o cadastro
--    é no próprio dia, o parabéns vai pro Teams na hora.
-- ============================================================

alter table public.plus_aniversariantes add column if not exists cor text;
alter table public.plus_aniversariantes drop constraint if exists plus_cor_valida;
alter table public.plus_aniversariantes add constraint plus_cor_valida
  check (cor is null or cor ~ '^#[0-9a-fA-F]{6}$');

/* ---------- Processa UMA pessoa: parabéns do dia + aviso antecipado ----------
   Usado pela rotina diária (todo mundo, às 8h) e pelo gatilho abaixo (só
   quem acabou de ser salvo). Nunca manda nada repetido — confere em
   plus_envios antes de mandar. */
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
  v_quando date;
  v_dest text;
  v_req bigint;
  v_n_teams int := 0;
  v_n_email int := 0;
begin
  select * into r from public.plus_aniversariantes where id = p_id;
  if not found or not r.ativo then return jsonb_build_object('teams', 0, 'emails', 0); end if;
  v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;

  -- 1) Hoje é o aniversário → parabéns no Teams
  if v_teams is not null
     and public.plus_proximo_aniversario(r.dia, r.mes, v_hoje) = v_hoje
     and not exists (select 1 from public.plus_envios e
                     where e.aniversariante_id = r.id and e.tipo = 'teams_parabens' and e.data_ref = v_hoje) then
    select net.http_post(
      url := v_teams,
      body := public.plus_card_teams(r.nome, r.email, v_foto, '🎉🎂 Hoje é dia de festa na Orion! 🎂🎉',
                'Toda a equipe deseja um dia incrível, cheio de alegria e muitas conquistas neste novo ciclo. Deixe seu parabéns aqui embaixo! 👇🥳'),
      headers := '{"Content-Type": "application/json"}'::jsonb
    ) into v_req;
    insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
    values (v_hoje, 'teams_parabens', r.id, v_req);
    v_n_teams := 1;
  end if;

  -- 2) Aviso por e-mail: a partir do dia do aviso até a véspera. Se o dia
  --    certo já passou sem aviso (cadastro atrasado), manda agora.
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

/* ---------- Rotina diária (substitui a do 01): passa por todo mundo ---------- */
create or replace function public.plus_rodar_avisos(p_hoje date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
  v_id uuid;
  v_res jsonb;
  v_n_teams int := 0;
  v_n_email int := 0;
begin
  for v_id in select id from public.plus_aniversariantes where ativo loop
    v_res := public.plus_processar(v_id, v_hoje);
    v_n_teams := v_n_teams + (v_res->>'teams')::int;
    v_n_email := v_n_email + (v_res->>'emails')::int;
  end loop;
  return jsonb_build_object('data', v_hoje, 'teams', v_n_teams, 'emails', v_n_email);
end $$;
revoke execute on function public.plus_rodar_avisos(date) from public, anon, authenticated;

/* ---------- Gatilho: roda na hora pra quem acabou de ser salvo ----------
   Se algo der errado aqui (ex.: link do Teams inválido), o cadastro da
   pessoa é salvo mesmo assim — o erro só vira um aviso no log. */
create or replace function public.plus_trg_aviso_imediato() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.plus_processar(new.id);
  exception when others then
    raise warning 'Orion PLuS: aviso imediato falhou para %: %', new.id, sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists plus_aviso_imediato on public.plus_aniversariantes;
create trigger plus_aviso_imediato
  after insert or update of dia, mes, ativo, foto_path on public.plus_aniversariantes
  for each row execute function public.plus_trg_aviso_imediato();
