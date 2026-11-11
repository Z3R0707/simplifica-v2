-- =====================================================================
-- Simplifica Finanças v2 — 0017 Pagamento sem conta e centavos da fatura
--
-- Migração ADICIONAL sobre a 0016 (etapa "6.1d-endurecimento"). Não apaga
-- nada, não cria tabelas e não altera dados já gravados. Tudo numa única
-- transação.
--
--   1. Pagamento SEM CONTA: uma conta a pagar (inclusive fatura de cartão)
--      pode receber um pagamento feito fora do Simplifica (outra pessoa,
--      conta não cadastrada, dinheiro). Ele abate o que falta pagar e NÃO
--      cria lançamento em nenhuma conta, então nenhum saldo muda.
--      Na tabela pagamentos: origem 'externo', sem movimento_id e com
--      data_pagamento. Nova RPC obrigacao_pagar_externo.
--   2. Pagamentos impressos na fatura importada podem ser registrados sem
--      conta (importacao_fatura_registrar_pagamento ganha p_sem_conta).
--   3. Centavos: um pagamento impresso na fatura que passe do que falta
--      pagar por até R$ 0,99 (saldo de centavos da fatura anterior, que o
--      banco cobra junto) é registrado com a diferença como acréscimo, e a
--      fatura fica quitada. Antes era recusado.
--   4. Listas que mostram pagamentos (contas a pagar, pagamentos da conta,
--      pagamentos da fatura importada) passam a incluir os sem conta.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '6.1d-endurecimento') then
    raise exception 'ABORTADO: este banco não está na 0016 (endurecimento) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- 1. Tabela pagamentos: origem 'externo' (sem lançamento, com data própria)
-- =====================================================================
alter table public.pagamentos add column data_pagamento date;
alter table public.pagamentos alter column movimento_id drop not null;
do $origem$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.pagamentos'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%origem%' and pg_get_constraintdef(oid) like '%vinculo%' loop
    execute format('alter table public.pagamentos drop constraint %I', r.conname);
  end loop;
end $origem$;
alter table public.pagamentos add constraint pagamentos_origem_check
  check (origem in ('pagamento', 'vinculo', 'externo'));
-- sem conta <=> sem lançamento e com data própria
alter table public.pagamentos add constraint pagamentos_externo_coerente
  check ((origem = 'externo') = (movimento_id is null) and (origem = 'externo') = (data_pagamento is not null));

create or replace function privado.pagamento_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_obr      public.obrigacoes;
  v_mov      public.movimentos;
  v_abate    bigint;
  v_abatido  bigint;
  v_usado    bigint;
  v_estornos bigint;
begin
  if tg_op = 'UPDATE' then
    if new.obrigacao_id <> old.obrigacao_id or new.movimento_id is distinct from old.movimento_id or new.data_pagamento is distinct from old.data_pagamento
       or new.valor_pago_centavos <> old.valor_pago_centavos or new.juros_centavos <> old.juros_centavos
       or new.multa_centavos <> old.multa_centavos or new.desconto_centavos <> old.desconto_centavos
       or new.origem <> old.origem then
      raise exception 'Pagamento não pode ser alterado: desfaça e registre de novo' using errcode = '22023';
    end if;
    if old.situacao = 'desfeito' and new.situacao <> 'desfeito' then
      raise exception 'Pagamento desfeito não pode ser reativado' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.situacao <> 'ativo' then
    raise exception 'Pagamento não pode nascer desfeito' using errcode = '22023';
  end if;
  v_abate := new.valor_pago_centavos - new.juros_centavos - new.multa_centavos + new.desconto_centavos;
  if v_abate <= 0 then
    raise exception 'Juros e multa não podem ser maiores que o valor pago' using errcode = '22023';
  end if;

  select * into v_obr from public.obrigacoes
   where id = new.obrigacao_id and user_id = new.user_id
     for update;
  if not found then
    raise exception 'Conta a pagar não encontrada' using errcode = 'P0002';
  end if;
  if v_obr.situacao <> 'aberta' then
    raise exception 'Conta a pagar cancelada não recebe pagamento' using errcode = '22023';
  end if;
  select coalesce(sum(abatido_centavos), 0) into v_abatido
    from public.pagamentos where obrigacao_id = v_obr.id and situacao = 'ativo';
  if v_abatido >= v_obr.valor_centavos then
    raise exception 'Esta conta já está paga' using errcode = '22023';
  end if;
  if v_abatido + v_abate > v_obr.valor_centavos then
    raise exception 'O pagamento abate % e faltam só % nesta conta. Se pagou a mais, informe a diferença como juros ou multa.',
      privado.reais(v_abate), privado.reais(v_obr.valor_centavos - v_abatido) using errcode = '22023';
  end if;

  -- pagamento sem conta (feito fora do Simplifica): não há lançamento para conferir
  if new.origem = 'externo' then
    return new;
  end if;

  select * into v_mov from public.movimentos
   where id = new.movimento_id and user_id = new.user_id
     for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;
  if v_mov.situacao <> 'efetivo' or v_mov.natureza <> 'debito' or v_mov.estorno_de is not null then
    raise exception 'Só um lançamento de saída que já aconteceu (não cancelado) pode pagar uma conta' using errcode = '22023';
  end if;
  select coalesce(sum(valor_centavos), 0) into v_estornos
    from public.movimentos where estorno_de = v_mov.id and situacao <> 'cancelado';
  select coalesce(sum(valor_pago_centavos), 0) into v_usado
    from public.pagamentos where movimento_id = v_mov.id and situacao = 'ativo';
  if v_usado + new.valor_pago_centavos > v_mov.valor_centavos - v_estornos then
    raise exception 'O lançamento tem só % livres para pagar contas', privado.reais(greatest(v_mov.valor_centavos - v_estornos - v_usado, 0))
      using errcode = '22023';
  end if;
  return new;
end $$;

create or replace function public.obrigacao_pagar_externo(
  p_obrigacao_id         uuid,
  p_data                 date,
  p_valor_pago_centavos  bigint,
  p_juros_centavos       bigint,
  p_multa_centavos       bigint,
  p_desconto_centavos    bigint,
  p_observacao           text,
  p_chave_idempotencia   text
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_obr   public.obrigacoes;
  v_reg   public.pagamentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_pagar_externo', jsonb_build_object(
    'obrigacao_id', p_obrigacao_id, 'data', p_data, 'valor', p_valor_pago_centavos,
    'juros', p_juros_centavos, 'multa', p_multa_centavos, 'desconto', p_desconto_centavos, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;

  if p_data is null then
    raise exception 'Informe a data do pagamento' using errcode = '22023';
  end if;
  if p_data > privado.hoje() then
    raise exception 'O pagamento sem conta precisa ter sido feito até hoje' using errcode = '22023';
  end if;
  if p_valor_pago_centavos is null or p_valor_pago_centavos <= 0 then
    raise exception 'Informe o valor pago, maior que zero' using errcode = '22023';
  end if;
  if coalesce(p_juros_centavos, 0) < 0 or coalesce(p_multa_centavos, 0) < 0 or coalesce(p_desconto_centavos, 0) < 0 then
    raise exception 'Juros, multa e desconto não podem ser negativos' using errcode = '22023';
  end if;
  select * into v_obr from public.obrigacoes where id = p_obrigacao_id and user_id = v_uid for update;
  if not found then
    raise exception 'Conta a pagar não encontrada' using errcode = 'P0002';
  end if;

  insert into public.pagamentos (user_id, obrigacao_id, movimento_id, data_pagamento, valor_pago_centavos, juros_centavos,
                                 multa_centavos, desconto_centavos, origem, observacao)
  values (v_uid, v_obr.id, null, p_data, p_valor_pago_centavos, coalesce(p_juros_centavos, 0),
          coalesce(p_multa_centavos, 0), coalesce(p_desconto_centavos, 0), 'externo', nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- 4. Listas: incluem os pagamentos sem conta (left join no lançamento)
-- =====================================================================
create or replace function public.contas_a_pagar(p_inicio date, p_fim date, p_incluir_vencidas boolean default true)
returns table (
  obrigacao_id          uuid,
  descricao             text,
  vencimento            date,
  competencia           date,
  valor_centavos        bigint,
  categoria_id          uuid,
  categoria             text,
  conta_prevista_id     uuid,
  conta_prevista        text,
  origem                text,
  recorrencia_id        uuid,
  situacao              text,
  cancelada_motivo      text,
  observacao            text,
  pago_centavos         bigint,
  juros_centavos        bigint,
  multa_centavos        bigint,
  desconto_centavos     bigint,
  abatido_centavos      bigint,
  restante_centavos     bigint,
  pagamentos            integer,
  ultimo_pagamento_em   date,
  status                text,
  versao                integer
)
language sql stable security invoker
set search_path = ''
as $$
  with pg as (
    select p.obrigacao_id,
           sum(p.valor_pago_centavos)::bigint as pago, sum(p.juros_centavos)::bigint as juros,
           sum(p.multa_centavos)::bigint as multa, sum(p.desconto_centavos)::bigint as desconto,
           sum(p.abatido_centavos)::bigint as abatido, count(*)::int as n, max(coalesce(m.data_movimento, p.data_pagamento)) as ultimo
      from public.pagamentos p
      left join public.movimentos m on m.id = p.movimento_id
     where p.user_id = auth.uid() and p.situacao = 'ativo'
     group by p.obrigacao_id
  ),
  o as (
    select ob.*, coalesce(pg.abatido, 0) as abatido, ob.valor_centavos - coalesce(pg.abatido, 0) as restante,
           pg.pago, pg.juros, pg.multa, pg.desconto, pg.n, pg.ultimo
      from public.obrigacoes ob
      left join pg on pg.obrigacao_id = ob.id
     where ob.user_id = auth.uid()
  )
  select o.id, o.descricao, o.vencimento, o.competencia, o.valor_centavos,
         o.categoria_id, cat.nome, o.conta_prevista_id, ct.apelido, o.origem, o.recorrencia_id,
         o.situacao, o.cancelada_motivo, o.observacao,
         coalesce(o.pago, 0), coalesce(o.juros, 0), coalesce(o.multa, 0), coalesce(o.desconto, 0),
         o.abatido, o.restante, coalesce(o.n, 0), o.ultimo,
         case when o.situacao = 'cancelada' then 'cancelada'
              when o.restante <= 0 then 'paga'
              when o.vencimento < privado.hoje() then 'vencida'
              when o.abatido > 0 then 'parcial'
              else 'a_vencer' end,
         o.versao
    from o
    left join public.categorias cat on cat.id = o.categoria_id
    left join public.contas ct on ct.id = o.conta_prevista_id
   where (o.vencimento between p_inicio and p_fim)
      or (coalesce(p_incluir_vencidas, true) and o.situacao = 'aberta' and o.restante > 0 and o.vencimento < p_inicio)
   order by o.vencimento, o.descricao, o.id;
$$;

create or replace function public.pagamentos_da_obrigacao(p_obrigacao_id uuid)
returns table (
  pagamento_id          uuid,
  movimento_id          uuid,
  data_pagamento        date,
  conta_id              uuid,
  conta                 text,
  valor_pago_centavos   bigint,
  juros_centavos        bigint,
  multa_centavos        bigint,
  desconto_centavos     bigint,
  abatido_centavos      bigint,
  origem                text,
  situacao              text,
  desfeito_motivo       text,
  movimento_situacao    text,
  observacao            text,
  versao                integer
)
language sql stable security invoker
set search_path = ''
as $$
  select p.id, p.movimento_id, coalesce(m.data_movimento, p.data_pagamento), m.conta_id, c.apelido,
         p.valor_pago_centavos, p.juros_centavos, p.multa_centavos, p.desconto_centavos, p.abatido_centavos,
         p.origem, p.situacao, p.desfeito_motivo, m.situacao, p.observacao, p.versao
    from public.pagamentos p
    left join public.movimentos m on m.id = p.movimento_id
    left join public.contas c on c.id = m.conta_id
   where p.user_id = auth.uid() and p.obrigacao_id = p_obrigacao_id
   order by p.situacao, coalesce(m.data_movimento, p.data_pagamento), p.criado_em;
$$;

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
      select p.id from public.pagamentos p left join public.movimentos m on m.id = p.movimento_id
       where p.obrigacao_id = a.alvo_id and p.situacao = 'ativo' and p.valor_pago_centavos = a.valor
         and abs(coalesce(m.data_movimento, p.data_pagamento) - a.data) <= 3
       order by abs(coalesce(m.data_movimento, p.data_pagamento) - a.data) limit 1) reg on true
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

-- =====================================================================
-- 2 e 3. Registrar pagamento impresso na fatura: sem conta e centavos
-- =====================================================================
drop function public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text);
create function public.importacao_fatura_registrar_pagamento(
  p_importacao_id       uuid,
  p_ordem               integer,
  p_conta_id            uuid,
  p_movimento_id        uuid,
  p_chave_idempotencia  text,
  p_sem_conta           boolean default false
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_pg    record;
  v_juros bigint := 0;
  v_obs   text;
  v_novo  public.pagamentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_fatura_registrar_pagamento', jsonb_build_object(
    'importacao_id', p_importacao_id, 'ordem', p_ordem, 'conta_id', p_conta_id, 'movimento_id', p_movimento_id,
    'sem_conta', coalesce(p_sem_conta, false)));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;

  if coalesce(p_sem_conta, false) then
    if p_conta_id is not null or p_movimento_id is not null then
      raise exception 'Pagamento sem conta não leva conta nem lançamento do extrato' using errcode = '22023';
    end if;
  elsif (p_conta_id is null) = (p_movimento_id is null) then
    raise exception 'Escolha a conta de onde saiu o pagamento ou o lançamento do extrato (um dos dois), ou registre sem conta' using errcode = '22023';
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
    -- até R$ 0,99 a mais: centavos que o banco cobrou junto (saldo da fatura
    -- anterior, arredondamento). A diferença entra como acréscimo e quita.
    if v_pg.obrigacao_restante_centavos > 0 and v_pg.valor_centavos - v_pg.obrigacao_restante_centavos <= 99 then
      v_juros := v_pg.valor_centavos - v_pg.obrigacao_restante_centavos;
    else
      raise exception 'O pagamento (%) passa do que falta pagar na fatura (%)', privado.reais(v_pg.valor_centavos), privado.reais(v_pg.obrigacao_restante_centavos)
        using errcode = '22023';
    end if;
  end if;

  v_obs := left('Pagamento mostrado na fatura importada: ' || v_pg.descricao
                || case when v_juros > 0 then ' (' || privado.reais(v_juros) || ' de centavos cobrados pelo banco entram como acréscimo)' else '' end, 500);
  if coalesce(p_sem_conta, false) then
    v_novo := public.obrigacao_pagar_externo(v_pg.obrigacao_id, v_pg.data, v_pg.valor_centavos, v_juros, 0, 0, v_obs, p_chave_idempotencia || '-e');
  elsif p_movimento_id is not null then
    v_novo := public.obrigacao_vincular_movimento(v_pg.obrigacao_id, p_movimento_id, v_pg.valor_centavos, v_juros, 0, 0, p_chave_idempotencia || '-v');
  else
    v_novo := public.obrigacao_pagar(v_pg.obrigacao_id, p_conta_id, v_pg.data, v_pg.valor_centavos, v_juros, 0, 0, v_obs, p_chave_idempotencia || '-p');
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_novo));
  return v_novo;
end $$;

-- =====================================================================
-- Permissões (as funções substituídas com create or replace mantêm as suas)
-- =====================================================================
revoke all on function public.obrigacao_pagar_externo(uuid, date, bigint, bigint, bigint, bigint, text, text) from public, anon;
revoke all on function public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text, boolean) from public, anon;
grant execute on function public.obrigacao_pagar_externo(uuid, date, bigint, bigint, bigint, bigint, text, text) to authenticated;
grant execute on function public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text, boolean) to authenticated;

update public.versao_esquema set etapa = '6.1e-pagamento-sem-conta', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
