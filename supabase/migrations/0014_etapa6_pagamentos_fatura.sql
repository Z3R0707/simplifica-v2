-- =====================================================================
-- Simplifica Finanças v2 — 0014 Etapa 6 (parte 1b): pagamentos que a
-- fatura importada mostra + centavos na conciliação
--
-- Migração ADICIONAL sobre a 0013 (etapa "6.1-conciliacao"). Não apaga
-- nada e não cria tabelas. Tudo numa única transação.
--
--   * importacao_fatura_pagamentos: os pagamentos impressos na fatura
--     importada (que não são compras), cada um identificado como
--     pagamento da FATURA ANTERIOR (até o vencimento dela) ou pagamento
--     ANTECIPADO desta fatura (depois disso). Mostra se já está
--     registrado no Simplifica e sugere o lançamento do extrato
--     correspondente (mesmo valor, até 3 dias), se houver.
--   * importacao_fatura_registrar_pagamento: registra um desses
--     pagamentos na fatura certa — vinculando o lançamento do extrato ou
--     lançando a saída na conta escolhida. Só o usuário confirma.
--   * conciliacao_sugestoes passa a aceitar fatura com diferença de até
--     R$ 0,99 (centavos que o banco arredonda ou carrega), só quando o
--     nome do banco/cartão está na descrição ou o débito é numa conta do
--     mesmo banco do cartão; a diferença entra como
--     acréscimo ou desconto do pagamento e a fatura fica quitada.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '6.1-conciliacao') then
    raise exception 'ABORTADO: este banco não está na Etapa 6 parte 1 (0013) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- Pagamentos mostrados na fatura importada
-- =====================================================================
create or replace function public.importacao_fatura_pagamentos(p_importacao_id uuid)
returns table (
  ordem                    integer,
  data                     date,
  descricao                text,
  valor_centavos           bigint,
  tipo                     text,      -- 'fatura_anterior' | 'antecipado'
  obrigacao_id             uuid,      -- fatura (conta a pagar) que o pagamento quita; null se não existe no Simplifica
  obrigacao                text,
  obrigacao_restante_centavos bigint,
  registrado               boolean,
  pagamento_id             uuid,
  conta_sugerida_id        uuid,
  movimento_sugerido_id    uuid,
  movimento_sugerido       text
)
language sql stable security invoker
set search_path = ''
as $$
  with imp as (
    select i.*, f.competencia, f.obrigacao_id as obr_atual, k.conta_pagamento_id, k.instituicao_id as banco_cartao,
           regexp_replace(btrim(translate(lower(coalesce((select b.nome from public.instituicoes b where b.id = k.instituicao_id) || ' ' || k.apelido, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g') as nome_cartao,
           (select a.vencimento from public.faturas a where a.cartao_id = i.cartao_id and a.competencia = (f.competencia - interval '1 month')::date) as venc_anterior,
           (select a.obrigacao_id from public.faturas a where a.cartao_id = i.cartao_id and a.competencia = (f.competencia - interval '1 month')::date) as obr_anterior
      from public.importacoes_fatura i
      join public.faturas f on f.id = i.fatura_id
      join public.cartoes k on k.id = i.cartao_id
     where i.id = p_importacao_id and i.user_id = auth.uid() and i.situacao = 'confirmada'
  ),
  pg as (
    select (e.n)::int as ordem, (e.v->>'data')::date as data, left(e.v->>'descricao', 200) as descricao,
           -((e.v->>'valor_centavos')::bigint) as valor, imp.*
      from imp cross join lateral jsonb_array_elements(imp.pagamentos) with ordinality as e(v, n)
     where (e.v->>'valor_centavos')::bigint < 0 and e.v->>'descricao' !~* '^saldo restante'
  ),
  cls as (
    select pg.*,
           case when pg.data <= coalesce(pg.venc_anterior, (pg.vencimento - interval '1 month')::date) then 'fatura_anterior' else 'antecipado' end as tipo
      from pg
  ),
  alvo as (
    select cls.*, case when cls.tipo = 'antecipado' then cls.obr_atual else cls.obr_anterior end as alvo_id
      from cls
  )
  select a.ordem, a.data, a.descricao, a.valor, a.tipo, o.id, o.descricao,
         o.valor_centavos - coalesce((select sum(p.abatido_centavos) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo'), 0),
         reg.id is not null, reg.id,
         -- conta sugerida: uma conta do mesmo banco do cartão (pagamento pelo app do banco); senão a conta de pagamento do cartão
         coalesce((select c.id from public.contas c where c.user_id = auth.uid() and c.ativa and c.instituicao_id = a.banco_cartao order by c.criado_em limit 1),
                  a.conta_pagamento_id),
         sug.id, case when sug.id is not null then sug.descricao || ' · ' || sug.apelido || ' · ' || to_char(sug.data_movimento, 'DD/MM/YYYY') end
    from alvo a
    left join public.obrigacoes o on o.id = a.alvo_id and o.situacao = 'aberta'
    left join lateral (
      select p.id from public.pagamentos p join public.movimentos m on m.id = p.movimento_id
       where p.obrigacao_id = a.alvo_id and p.situacao = 'ativo' and p.valor_pago_centavos = a.valor
         and abs(m.data_movimento - a.data) <= 3
       order by abs(m.data_movimento - a.data) limit 1) reg on true
    left join lateral (
      select m.id, m.descricao, m.data_movimento, c.apelido from public.movimentos m join public.contas c on c.id = m.conta_id
       where reg.id is null
         -- só débito que parece pagamento deste cartão: conta do mesmo banco do cartão, ou descrição
         -- com "fatura"/"cartão" ou o nome do banco/cartão (uma transferência entre contas não serve)
         and (c.instituicao_id is not distinct from a.banco_cartao
              or regexp_replace(btrim(translate(lower(coalesce(m.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g') ~ '(fatura|cartao)'
              or exists (select 1 from regexp_split_to_table(a.nome_cartao, '[^a-z0-9]+') t
                          where length(t) >= 4 and position(t in regexp_replace(btrim(translate(lower(coalesce(m.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g')) > 0)) and m.user_id = auth.uid() and m.situacao = 'efetivo' and m.natureza = 'debito' and m.estorno_de is null
         and m.valor_centavos = a.valor and abs(m.data_movimento - a.data) <= 3
         and not exists (select 1 from public.pagamentos q where q.movimento_id = m.id and q.situacao = 'ativo')
       order by (m.conta_id is not distinct from a.conta_pagamento_id) desc, abs(m.data_movimento - a.data), m.criado_em limit 1) sug on true
   order by a.ordem;
$$;

-- Registra um pagamento mostrado na fatura: vincula o lançamento do extrato
-- (p_movimento_id) OU lança a saída na conta escolhida (p_conta_id).
create or replace function public.importacao_fatura_registrar_pagamento(
  p_importacao_id       uuid,
  p_ordem               integer,
  p_conta_id            uuid,
  p_movimento_id        uuid,
  p_chave_idempotencia  text
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_pg    record;
  v_rest  bigint;
  v_novo  public.pagamentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_fatura_registrar_pagamento', jsonb_build_object(
    'importacao_id', p_importacao_id, 'ordem', p_ordem, 'conta_id', p_conta_id, 'movimento_id', p_movimento_id));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;

  if (p_conta_id is null) = (p_movimento_id is null) then
    raise exception 'Escolha a conta de onde saiu o pagamento ou o lançamento do extrato (um dos dois)' using errcode = '22023';
  end if;
  perform 1 from public.importacoes_fatura where id = p_importacao_id and user_id = v_uid and situacao = 'confirmada';
  if not found then
    raise exception 'Importação de fatura não encontrada (ou não confirmada)' using errcode = 'P0002';
  end if;
  select * into v_pg from public.importacao_fatura_pagamentos(p_importacao_id) x where x.ordem = p_ordem;
  if not found then
    raise exception 'Pagamento não encontrado nesta fatura' using errcode = 'P0002';
  end if;
  if v_pg.obrigacao_id is null then
    raise exception 'A fatura que este pagamento quita não está em aberto no Simplifica' using errcode = '22023';
  end if;
  -- trava a conta a pagar e confere de novo, já com a trava
  perform 1 from public.obrigacoes where id = v_pg.obrigacao_id for update;
  select * into v_pg from public.importacao_fatura_pagamentos(p_importacao_id) x where x.ordem = p_ordem;
  if v_pg.registrado then
    raise exception 'Este pagamento já está registrado nesta fatura' using errcode = '23505';
  end if;
  if v_pg.valor_centavos > v_pg.obrigacao_restante_centavos then
    raise exception 'O pagamento (%) passa do que falta pagar na fatura (%)', privado.reais(v_pg.valor_centavos), privado.reais(v_pg.obrigacao_restante_centavos)
      using errcode = '22023';
  end if;

  if p_movimento_id is not null then
    v_novo := public.obrigacao_vincular_movimento(v_pg.obrigacao_id, p_movimento_id, v_pg.valor_centavos, 0, 0, 0, p_chave_idempotencia || '-v');
  else
    v_novo := public.obrigacao_pagar(v_pg.obrigacao_id, p_conta_id, v_pg.data, v_pg.valor_centavos, 0, 0, 0,
                                     left('Pagamento mostrado na fatura importada: ' || v_pg.descricao, 500), p_chave_idempotencia || '-p');
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_novo));
  return v_novo;
end $$;

-- =====================================================================
-- Conciliação: fatura com diferença de centavos (troca o tipo de retorno)
-- =====================================================================
drop function public.conciliacao_sugestoes(uuid);
create function public.conciliacao_sugestoes(p_conta_id uuid)
returns table (
  movimento_id      uuid,
  conta_id          uuid,
  conta             text,
  data_movimento    date,
  descricao         text,
  valor_centavos    bigint,
  obrigacao_id      uuid,
  obrigacao         text,
  vencimento        date,
  restante_centavos bigint,
  valor_vincular_centavos bigint,
  juros_centavos    bigint,
  desconto_centavos bigint,
  e_fatura          boolean,
  pontos            integer,
  motivo            text
)
language sql stable security invoker
set search_path = ''
as $$
  with mov as (
    select m.*, m.valor_centavos
             - coalesce((select sum(e.valor_centavos) from public.movimentos e where e.estorno_de = m.id and e.situacao <> 'cancelado'), 0)
             - coalesce((select sum(p.valor_pago_centavos) from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo'), 0) as livre,
           regexp_replace(btrim(translate(lower(coalesce(m.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g') as norm
      from public.movimentos m
     where m.user_id = auth.uid() and m.situacao = 'efetivo' and m.natureza = 'debito' and m.estorno_de is null
       and (p_conta_id is null or m.conta_id = p_conta_id)
       and m.data_movimento >= privado.hoje() - 400
       and not exists (select 1 from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo')
  ),
  obr as (
    select o.*, o.valor_centavos - coalesce((select sum(p.abatido_centavos) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo'), 0) as restante,
           (select regexp_replace(btrim(translate(lower(coalesce(i.nome || ' ' || k.apelido, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g')
              from public.faturas f join public.cartoes k on k.id = f.cartao_id join public.instituicoes i on i.id = k.instituicao_id
             where f.obrigacao_id = o.id) as nome_cartao,
           (select k.instituicao_id from public.faturas f join public.cartoes k on k.id = f.cartao_id where f.obrigacao_id = o.id) as banco_cartao,
           (select i.total_a_pagar_centavos from public.importacoes_fatura i join public.faturas f on f.id = i.fatura_id
             where f.obrigacao_id = o.id and i.situacao = 'confirmada' order by i.confirmada_em desc limit 1) as cobrado
      from public.obrigacoes o
     where o.user_id = auth.uid() and o.situacao = 'aberta'
  ),
  par as (
    select mov.id as mid, obr.id as oid, mov.conta_id, mov.data_movimento, mov.descricao as mdesc, mov.valor_centavos, obr.descricao as odesc,
           obr.vencimento, obr.restante, obr.origem = 'fatura' as e_fatura,
           coalesce(obr.cobrado > 0 and obr.cobrado < obr.restante and obr.restante = obr.valor_centavos and obr.cobrado = mov.livre, false) as pelo_cobrado,
           (mov.livre - obr.restante)::bigint as dif_centavos,
           abs(mov.data_movimento - obr.vencimento) as dias,
           exists (select 1 from regexp_split_to_table(coalesce(obr.nome_cartao, '') || ' ' || regexp_replace(btrim(translate(lower(coalesce(obr.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g'), '[^a-z0-9]+') t
                    where length(t) >= 4 and t not in ('fatura', 'conta', 'pagamento', 'boleto', 'cartao') and position(t in mov.norm) > 0) as nome_bate,
           obr.conta_prevista_id = mov.conta_id as conta_prevista,
           obr.banco_cartao is not null and obr.banco_cartao = (select c.instituicao_id from public.contas c where c.id = mov.conta_id) as mesmo_banco
      from mov join obr on obr.restante > 0
                       and (obr.restante = mov.livre
                            or (obr.cobrado > 0 and obr.cobrado < obr.restante and obr.restante = obr.valor_centavos and obr.cobrado = mov.livre)
                            or (obr.origem = 'fatura' and abs(mov.livre - obr.restante) between 1 and 99))
     where abs(mov.data_movimento - obr.vencimento) <= 20
  ),
  pont as (
    select par.*, (100 - least(dias, 20) * 2 + case when nome_bate then 30 else 0 end + case when conta_prevista then 10 else 0 end
             - case when dif_centavos <> 0 and not pelo_cobrado then 20 else 0 end)::int as pontos
      from par
     -- diferença de centavos só vale com o nome do banco/cartão na descrição ou conta do mesmo banco
     where dif_centavos = 0 or pelo_cobrado or nome_bate or mesmo_banco
  ),
  rank as (
    select pont.*, row_number() over (partition by mid order by pontos desc, dias, oid) as rm,
           row_number() over (partition by oid order by pontos desc, dias, mid) as ro
      from pont
  )
  select r.mid, r.conta_id, c.apelido, r.data_movimento, r.mdesc, r.valor_centavos, r.oid, r.odesc, r.vencimento, r.restante,
         case when r.pelo_cobrado then r.valor_centavos when r.dif_centavos <> 0 then r.valor_centavos else r.restante end,
         case when not r.pelo_cobrado and r.dif_centavos > 0 then r.dif_centavos else 0 end,
         case when not r.pelo_cobrado and r.dif_centavos < 0 then -r.dif_centavos else 0 end,
         r.e_fatura, r.pontos,
         concat_ws(' · ', case when r.pelo_cobrado then 'valor cobrado pelo banco na fatura (pagamento antecipado já descontado)'
                               when r.dif_centavos > 0 then 'banco cobrou R$ ' || replace(to_char(r.dif_centavos / 100.0, 'FM999990.00'), '.', ',') || ' a mais (entra como acréscimo)'
                               when r.dif_centavos < 0 then 'banco cobrou R$ ' || replace(to_char(-r.dif_centavos / 100.0, 'FM999990.00'), '.', ',') || ' a menos (entra como desconto)'
                               else 'mesmo valor' end,
                   case when r.dias = 0 then 'mesmo dia do vencimento' else r.dias || ' dia(s) do vencimento' end,
                   case when r.nome_bate then 'nome na descrição' end,
                   case when r.conta_prevista then 'conta prevista para o pagamento' end,
                   case when r.mesmo_banco and not r.nome_bate and r.dif_centavos <> 0 and not r.pelo_cobrado then 'conta do mesmo banco do cartão' end)
    from rank r join public.contas c on c.id = r.conta_id
   where r.rm = 1 and r.ro = 1
   order by r.data_movimento desc, r.pontos desc;
$$;


-- =====================================================================
-- Permissões
-- =====================================================================
revoke all on function public.importacao_fatura_pagamentos(uuid) from public, anon;
revoke all on function public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text) from public, anon;
revoke all on function public.conciliacao_sugestoes(uuid) from public, anon;
grant execute on function public.importacao_fatura_pagamentos(uuid) to authenticated;
grant execute on function public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text) to authenticated;
grant execute on function public.conciliacao_sugestoes(uuid) to authenticated;

update public.versao_esquema set etapa = '6.1b-pagamentos-fatura', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
