-- ============================================================
-- Orion PLuS — atualização 03 (rode DEPOIS do 01 e do 02)
-- SQL Editor → New query → cole tudo → Run. Pode rodar de novo.
--
-- Quem entra no PLuS DEPOIS que um aviso "o aniversário de fulano está
-- chegando" já saiu não ficaria sabendo. Agora, assim que a pessoa passa
-- a ter e-mail no PLuS (cria conta, é adicionada pela Administração ou
-- clica em "Sou eu!"), ela recebe — só ela — os avisos que já foram
-- mandados e cujo aniversário ainda não chegou.
-- ============================================================

create table if not exists public.plus_envios_individuais (
  id bigserial primary key,
  aniversariante_id uuid references public.plus_aniversariantes(id) on delete cascade,
  email text not null,
  data_aniversario date not null,
  request_id bigint,
  criado_em timestamptz not null default now(),
  unique (aniversariante_id, email, data_aniversario)
);
alter table public.plus_envios_individuais enable row level security;
drop policy if exists plus_envios_ind_select on public.plus_envios_individuais;
create policy plus_envios_ind_select on public.plus_envios_individuais
  for select to authenticated using (public.plus_is_admin());

create or replace function public.plus_avisar_quem_chegou(p_email text, p_hoje date default null) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := coalesce(p_hoje, (now() at time zone 'America/Sao_Paulo')::date);
  v_email_url text := nullif((select valor from public.plus_config where chave = 'email_webhook_url'), '');
  v_foto_base text := coalesce((select valor from public.plus_config where chave = 'foto_base_url'), '');
  v_para text := lower(trim(coalesce(p_email, '')));
  v_extras text := coalesce((select valor from public.plus_config where chave = 'email_destinatarios_extras'), '');
  v_enviado_em timestamptz;
  r record;
  v_foto text;
  v_req bigint;
  v_n int := 0;
begin
  if v_email_url is null or v_para not like '%@oriontransmissao.com.br' then return 0; end if;
  for r in
    select a.*, public.plus_proximo_aniversario(a.dia, a.mes, v_hoje + 1) as quando
    from public.plus_aniversariantes a
    where a.ativo
      and lower(coalesce(a.email, '')) <> v_para          -- nunca o aviso do próprio aniversário
  loop
    -- Só avisos que JÁ saíram pra turma e cujo aniversário ainda vem
    select max(e.criado_em) into v_enviado_em from public.plus_envios e
     where e.aniversariante_id = r.id and e.tipo = 'email_aviso'
       and e.data_ref > r.quando - 40 and e.data_ref < r.quando;
    continue when v_enviado_em is null;
    -- Quem já estava na lista quando o aviso saiu (conta do GPS criada
    -- antes, ou nos "e-mails extras") já recebeu — não manda de novo.
    continue when exists (
      select 1 from public.usuarios_permissoes p join auth.users u on u.id = p.id
      where lower(trim(p.email)) = v_para and u.created_at < v_enviado_em);
    continue when v_para = any (select lower(trim(t)) from unnest(string_to_array(replace(v_extras, ',', ';'), ';')) t);
    continue when exists (
      select 1 from public.plus_envios_individuais i
      where i.aniversariante_id = r.id and i.email = v_para and i.data_aniversario = r.quando);
    v_foto := case when coalesce(r.foto_path, '') <> '' then v_foto_base || r.foto_path else '' end;
    select net.http_post(
      url := v_email_url,
      body := jsonb_build_object(
        'destinatarios', v_para,
        'assunto', '🎈 O aniversário de ' || r.nome || ' está chegando! (' || to_char(r.quando, 'DD/MM') || ')',
        'mensagem_html', public.plus_email_aviso(r.nome, v_foto, r.quando, r.quando - v_hoje)),
      headers := '{"Content-Type": "application/json"}'::jsonb
    ) into v_req;
    insert into public.plus_envios_individuais (aniversariante_id, email, data_aniversario, request_id)
    values (r.id, v_para, r.quando, v_req);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.plus_avisar_quem_chegou(text, date) from public, anon, authenticated;

-- Gatilho: quando a linha ganha um e-mail novo (cadastro, "Sou eu!" ou
-- administrador preenchendo). Erro aqui nunca impede o cadastro.
create or replace function public.plus_trg_quem_chegou() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ativo and new.email is not null
     and (tg_op = 'INSERT' or lower(coalesce(old.email, '')) <> lower(new.email)) then
    begin
      perform public.plus_avisar_quem_chegou(new.email);
    exception when others then
      raise warning 'Orion PLuS: aviso para quem chegou falhou (%): %', new.email, sqlerrm;
    end;
  end if;
  return new;
end $$;

drop trigger if exists plus_quem_chegou on public.plus_aniversariantes;
create trigger plus_quem_chegou
  after insert or update of email on public.plus_aniversariantes
  for each row execute function public.plus_trg_quem_chegou();
