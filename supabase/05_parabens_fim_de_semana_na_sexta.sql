-- ============================================================
-- Orion PLuS — atualização 05 (rode DEPOIS do 01 ao 04)
-- SQL Editor → New query → cole tudo → Run. Pode rodar de novo.
--
-- Aniversário no sábado ou domingo: o parabéns no Teams sai na SEXTA
-- anterior (às 8h), com o texto "Neste domingo (11/10) é dia de festa!".
-- Se a pessoa só se cadastrar no fim de semana, o parabéns sai na hora
-- (melhor que nunca). Dia útil continua igual: sai no próprio dia.
-- ============================================================

-- Dia em que o parabéns vai pro Teams: o próprio aniversário, ou a sexta
-- anterior se cair no fim de semana.
create or replace function public.plus_dia_do_parabens(p_aniversario date) returns date
language sql immutable as $$
  select case extract(dow from p_aniversario)::int
    when 6 then p_aniversario - 1
    when 0 then p_aniversario - 2
    else p_aniversario
  end;
$$;

create or replace function public.plus_processar(p_id uuid, p_hoje date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
  v_dias int := coalesce(nullif((select valor from public.plus_config where chave = 'dias_antecedencia'), '')::int, 3);
  v_teams text := nullif((select valor from public.plus_config where chave = 'teams_webhook_url'), '');
  v_email text := nullif((select valor from public.plus_config where chave = 'email_webhook_url'), '');
  v_foto_base text := coalesce((select valor from public.plus_config where chave = 'foto_base_url'), '');
  v_extras text := coalesce((select valor from public.plus_config where chave = 'email_destinatarios_extras'), '');
  v_semana text[] := array['domingo','segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado'];
  r public.plus_aniversariantes%rowtype;
  v_foto text;
  v_cartao text;
  v_aniv date;       -- próximo aniversário contando hoje
  v_quando date;     -- próximo aniversário a partir de amanhã (pro aviso)
  v_titulo text;
  v_texto text;
  v_dest text;
  v_req bigint;
  v_n_teams int := 0;
  v_n_email int := 0;
begin
  select * into r from public.plus_aniversariantes where id = p_id;
  if not found or not r.ativo then return jsonb_build_object('teams', 0, 'emails', 0); end if;
  v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;
  v_cartao := case when coalesce(r.cartao_path, '') <> '' then v_foto_base || r.cartao_path else '' end;

  -- 1) Parabéns no Teams: no dia (dia útil) ou na sexta antes (fim de semana)
  v_aniv := public.plus_proximo_aniversario(r.dia, r.mes, v_hoje);
  if v_teams is not null
     and v_hoje >= public.plus_dia_do_parabens(v_aniv)
     and v_hoje <= v_aniv
     and not exists (select 1 from public.plus_envios e
                     where e.aniversariante_id = r.id and e.tipo = 'teams_parabens'
                       and e.data_ref > v_aniv - 5 and e.data_ref <= v_aniv) then
    if v_aniv = v_hoje then
      v_titulo := '🎉🎂 Hoje é dia de festa na Orion! 🎂🎉';
      v_texto := 'Toda a equipe deseja um dia incrível, cheio de alegria e muitas conquistas neste novo ciclo. Deixe seu parabéns aqui embaixo! 👇🥳';
    else
      v_titulo := '🎉🎂 Neste ' || v_semana[extract(dow from v_aniv)::int + 1] || ' (' || to_char(v_aniv, 'DD/MM') || ') é dia de festa! 🎂🎉';
      v_texto := 'O aniversário cai no fim de semana, então a gente já comemora hoje! Toda a equipe deseja um dia incrível e muitas conquistas neste novo ciclo. Deixe seu parabéns aqui embaixo! 👇🥳';
    end if;
    select net.http_post(
      url := v_teams,
      body := public.plus_card_teams(r.nome, r.email, v_foto, v_titulo, v_texto, v_cartao),
      headers := '{"Content-Type": "application/json"}'::jsonb
    ) into v_req;
    insert into public.plus_envios (data_ref, tipo, aniversariante_id, request_id)
    values (v_hoje, 'teams_parabens', r.id, v_req);
    v_n_teams := 1;
  end if;

  -- 2) Aviso por e-mail (igual à 04)
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
