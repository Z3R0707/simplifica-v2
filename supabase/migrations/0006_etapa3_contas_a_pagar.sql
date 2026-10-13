-- =====================================================================
-- Simplifica Finanças v2 — 0006 Etapa 3: contas a pagar, recorrências
-- e pagamentos parciais.
--
-- Migração ADICIONAL sobre a 0005 (etapa "2.1-cancelamento-parcial").
-- Não apaga nem recria nada: só acrescenta tabelas e funções e substitui
-- (create or replace) a exportação LGPD e a conclusão da exclusão de
-- conta, que passam a incluir as novas tabelas. As consultas de saldo da
-- Etapa 2 NÃO mudam. Tudo numa única transação.
--
-- CONCEITOS
--   Conta a pagar (obrigacoes): um compromisso com valor e vencimento.
--     Ela NÃO mexe no saldo. O que mexe no saldo é o pagamento.
--   Pagamento (pagamentos): liga uma conta a pagar a um lançamento de
--     saída que já aconteceu. Uma conta pode ter vários pagamentos
--     (pagamento parcial) e um lançamento pode pagar várias contas.
--       abatido = valor pago − juros − multa + desconto
--       restante = valor da conta − soma do abatido dos pagamentos ativos
--     A conta só fica "paga" quando o restante chega a zero; vencer não
--     a torna paga.
--   Recorrência (recorrencias): modelo que gera uma conta a pagar por mês
--     (aluguel, escola, parcelas). Cada mês gerado pode ser ajustado
--     sozinho (ex.: conta de luz com valor diferente).
--
-- GARANTIAS NO BANCO (valem também para operações simultâneas)
--   * a soma do abatido nunca passa do valor da conta;
--   * a soma paga com um lançamento nunca passa do valor dele (já
--     descontados os cancelamentos parciais);
--   * lançamento que paga uma conta não pode ser cancelado, mudar de
--     sentido nem ficar menor que o usado; conta com pagamento não pode
--     ser cancelada nem ficar menor que o pago;
--   * travas sempre na ordem conta a pagar → lançamento.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '2.1-cancelamento-parcial') then
    raise exception 'ABORTADO: este banco não está na Etapa 2 com cancelamento parcial (0005) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- ---------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------
-- Valor em reais para mensagens: 123456 -> 'R$ 1.234,56'
create or replace function privado.reais(p_centavos bigint)
returns text
language sql immutable
set search_path = ''
as $$
  select case when p_centavos < 0 then '−' else '' end || 'R$ '
      || translate(to_char(abs(p_centavos) / 100.0, 'FM999,999,999,999,990.00'), ',.', '.,');
$$;

-- Dia de vencimento dentro do mês (31 em fevereiro vira o último dia)
create or replace function privado.vencimento_no_mes(p_mes date, p_dia integer)
returns date
language sql immutable
set search_path = ''
as $$
  select make_date(extract(year from p_mes)::int, extract(month from p_mes)::int,
                   least(p_dia, extract(day from (date_trunc('month', p_mes) + interval '1 month - 1 day'))::int));
$$;

-- Categoria de despesa ativa do usuário (para contas a pagar e recorrências)
create or replace function privado.exigir_categoria_despesa(p_user uuid, p_categoria uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v record;
begin
  if p_categoria is null then return; end if;
  select tipo, ativa into v from public.categorias where id = p_categoria and user_id = p_user;
  if not found then
    raise exception 'Categoria não encontrada' using errcode = 'P0002';
  end if;
  if v.tipo <> 'despesa' then
    raise exception 'Conta a pagar usa categoria de despesa' using errcode = '22023';
  end if;
  if not v.ativa then
    raise exception 'Categoria arquivada' using errcode = '22023';
  end if;
end $$;

create or replace function privado.exigir_conta_ativa(p_user uuid, p_conta uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v boolean;
begin
  if p_conta is null then return; end if;
  select ativa into v from public.contas where id = p_conta and user_id = p_user;
  if not found then
    raise exception 'Conta não encontrada' using errcode = 'P0002';
  end if;
  if not v then
    raise exception 'Conta arquivada' using errcode = '22023';
  end if;
end $$;

-- =====================================================================
-- TABELAS
-- =====================================================================
create table public.recorrencias (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  descricao          text not null check (length(btrim(descricao)) between 1 and 200),
  categoria_id       uuid,
  conta_prevista_id  uuid,
  valor_centavos     bigint not null check (valor_centavos > 0 and valor_centavos <= 10000000000000),
  dia_vencimento     integer not null check (dia_vencimento between 1 and 31),
  inicio             date not null check (inicio = date_trunc('month', inicio)::date),
  fim                date check (fim = date_trunc('month', fim)::date),
  numerar_parcelas   boolean not null default false,
  observacao         text check (length(observacao) <= 500),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  versao             integer not null default 1,
  unique (id, user_id),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  foreign key (conta_prevista_id, user_id) references public.contas (id, user_id),
  -- fim = mês anterior ao início significa "encerrada antes de começar"
  check (fim is null or fim >= (inicio - interval '1 month')::date),
  check (not numerar_parcelas or fim is not null)
);
alter table public.recorrencias enable row level security;
create policy recorrencias_select on public.recorrencias for select to authenticated using (user_id = auth.uid());
grant select on public.recorrencias to authenticated;
select privado.aplicar_gatilhos_padrao('public.recorrencias');

create table public.obrigacoes (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  descricao          text not null check (length(btrim(descricao)) between 1 and 200),
  categoria_id       uuid,
  conta_prevista_id  uuid,
  valor_centavos     bigint not null check (valor_centavos > 0 and valor_centavos <= 10000000000000),
  vencimento         date not null,
  competencia        date not null check (competencia = date_trunc('month', competencia)::date),
  origem             text not null default 'avulsa' check (origem in ('avulsa', 'recorrencia', 'fatura')),
  recorrencia_id     uuid,
  situacao           text not null default 'aberta' check (situacao in ('aberta', 'cancelada')),
  cancelada_motivo   text,
  cancelada_em       timestamptz,
  observacao         text check (length(observacao) <= 500),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  versao             integer not null default 1,
  unique (id, user_id),
  unique (recorrencia_id, competencia),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  foreign key (conta_prevista_id, user_id) references public.contas (id, user_id),
  foreign key (recorrencia_id, user_id) references public.recorrencias (id, user_id),
  check ((origem = 'recorrencia') = (recorrencia_id is not null)),
  check ((situacao = 'cancelada') = (cancelada_em is not null))
);
create index obrigacoes_vencimento_idx on public.obrigacoes (user_id, vencimento);
alter table public.obrigacoes enable row level security;
create policy obrigacoes_select on public.obrigacoes for select to authenticated using (user_id = auth.uid());
grant select on public.obrigacoes to authenticated;
select privado.aplicar_gatilhos_padrao('public.obrigacoes');

create table public.pagamentos (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references auth.users (id) on delete cascade,
  obrigacao_id         uuid not null,
  movimento_id         uuid not null,
  valor_pago_centavos  bigint not null check (valor_pago_centavos > 0 and valor_pago_centavos <= 10000000000000),
  juros_centavos       bigint not null default 0 check (juros_centavos >= 0),
  multa_centavos       bigint not null default 0 check (multa_centavos >= 0),
  desconto_centavos    bigint not null default 0 check (desconto_centavos >= 0),
  abatido_centavos     bigint generated always as (valor_pago_centavos - juros_centavos - multa_centavos + desconto_centavos) stored,
  origem               text not null check (origem in ('pagamento', 'vinculo')),
  situacao             text not null default 'ativo' check (situacao in ('ativo', 'desfeito')),
  desfeito_motivo      text,
  desfeito_em          timestamptz,
  observacao           text check (length(observacao) <= 500),
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),
  versao               integer not null default 1,
  unique (id, user_id),
  foreign key (obrigacao_id, user_id) references public.obrigacoes (id, user_id),
  foreign key (movimento_id, user_id) references public.movimentos (id, user_id),
  check (valor_pago_centavos - juros_centavos - multa_centavos + desconto_centavos > 0),
  check ((situacao = 'desfeito') = (desfeito_em is not null))
);
create index pagamentos_obrigacao_idx on public.pagamentos (obrigacao_id) where situacao = 'ativo';
create index pagamentos_movimento_idx on public.pagamentos (movimento_id) where situacao = 'ativo';
create unique index pagamentos_um_vinculo_ativo on public.pagamentos (obrigacao_id, movimento_id) where situacao = 'ativo';
alter table public.pagamentos enable row level security;
create policy pagamentos_select on public.pagamentos for select to authenticated using (user_id = auth.uid());
grant select on public.pagamentos to authenticated;
select privado.aplicar_gatilhos_padrao('public.pagamentos');

-- =====================================================================
-- REGRAS (gatilhos)
-- =====================================================================
create or replace function privado.recorrencia_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.categoria_id is distinct from old.categoria_id then
    perform privado.exigir_categoria_despesa(new.user_id, new.categoria_id);
  end if;
  if tg_op = 'INSERT' or new.conta_prevista_id is distinct from old.conta_prevista_id then
    perform privado.exigir_conta_ativa(new.user_id, new.conta_prevista_id);
  end if;
  if tg_op = 'UPDATE' and new.inicio <> old.inicio then
    raise exception 'O mês de início da recorrência não pode ser alterado' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger recorrencias_validar before insert or update on public.recorrencias
  for each row execute function privado.recorrencia_validar();

create or replace function privado.obrigacao_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_abatido bigint;
begin
  if tg_op = 'INSERT' and new.situacao <> 'aberta' then
    raise exception 'Conta a pagar não pode nascer cancelada' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' or new.categoria_id is distinct from old.categoria_id then
    perform privado.exigir_categoria_despesa(new.user_id, new.categoria_id);
  end if;
  if tg_op = 'INSERT' or new.conta_prevista_id is distinct from old.conta_prevista_id then
    perform privado.exigir_conta_ativa(new.user_id, new.conta_prevista_id);
  end if;
  if tg_op = 'UPDATE' then
    if new.origem <> old.origem or new.recorrencia_id is distinct from old.recorrencia_id
       or (old.origem <> 'avulsa' and new.competencia <> old.competencia) then
      raise exception 'Origem e mês de referência da conta a pagar não podem ser alterados' using errcode = '22023';
    end if;
    select coalesce(sum(abatido_centavos), 0) into v_abatido
      from public.pagamentos where obrigacao_id = new.id and situacao = 'ativo';
    if v_abatido > 0 then
      if new.situacao = 'cancelada' then
        raise exception 'Esta conta tem pagamentos (% abatidos). Desfaça os pagamentos antes de cancelar, ou ajuste o valor para o que foi pago.', privado.reais(v_abatido)
          using errcode = '22023';
      end if;
      if new.valor_centavos < v_abatido then
        raise exception 'O valor não pode ficar menor que o já pago (%)', privado.reais(v_abatido) using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger obrigacoes_validar before insert or update on public.obrigacoes
  for each row execute function privado.obrigacao_validar();

-- Pagamento: trava a conta a pagar e depois o lançamento (ordem fixa)
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
    if new.obrigacao_id <> old.obrigacao_id or new.movimento_id <> old.movimento_id
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
create trigger pagamentos_validar before insert or update on public.pagamentos
  for each row execute function privado.pagamento_validar();

-- Lançamentos que pagam contas ficam protegidos.
-- Roda depois de movimentos_regras_estorno (ordem alfabética dos gatilhos).
create or replace function privado.movimento_regras_pagamento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pai      public.movimentos;
  v_usado    bigint;
  v_estornos bigint;
begin
  if new.estorno_de is null then
    if tg_op = 'INSERT' then return new; end if;
    select coalesce(sum(valor_pago_centavos), 0) into v_usado
      from public.pagamentos where movimento_id = new.id and situacao = 'ativo';
    if v_usado = 0 then return new; end if;
    if new.situacao <> 'efetivo' then
      raise exception 'Este lançamento paga conta(s) a pagar. Desfaça o pagamento em Contas a pagar antes de cancelar o lançamento.'
        using errcode = '22023';
    end if;
    if new.natureza <> old.natureza then
      raise exception 'Lançamento que paga conta(s) a pagar não pode mudar de sentido' using errcode = '22023';
    end if;
    select coalesce(sum(valor_centavos), 0) into v_estornos
      from public.movimentos where estorno_de = new.id and situacao <> 'cancelado';
    if new.valor_centavos - v_estornos < v_usado then
      raise exception 'O valor não pode ficar menor que o usado para pagar contas (%)', privado.reais(v_usado) using errcode = '22023';
    end if;
    return new;
  end if;

  -- cancelamento parcial de um lançamento que paga contas
  if new.situacao = 'cancelado' then return new; end if;
  select * into v_pai from public.movimentos where id = new.estorno_de and user_id = new.user_id for update;
  if not found then return new; end if;
  select coalesce(sum(valor_pago_centavos), 0) into v_usado
    from public.pagamentos where movimento_id = v_pai.id and situacao = 'ativo';
  if v_usado = 0 then return new; end if;
  select coalesce(sum(valor_centavos), 0) into v_estornos
    from public.movimentos where estorno_de = v_pai.id and situacao <> 'cancelado' and id <> new.id;
  if v_estornos + new.valor_centavos + v_usado > v_pai.valor_centavos then
    raise exception '% deste lançamento pagam contas a pagar: só é possível cancelar até %',
      privado.reais(v_usado), privado.reais(greatest(v_pai.valor_centavos - v_usado - v_estornos, 0)) using errcode = '22023';
  end if;
  return new;
end $$;
create trigger movimentos_regras_pagamento before insert or update on public.movimentos
  for each row execute function privado.movimento_regras_pagamento();

-- =====================================================================
-- Geração de contas a pagar a partir das recorrências
-- =====================================================================
-- Gera os meses que faltam até p_ate (no máximo 24 meses à frente de hoje).
-- Idempotente: cada mês só existe uma vez (unique recorrencia_id+competencia).
create or replace function privado.recorrencia_gerar(p_rec public.recorrencias, p_ate date)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_limite date := least(date_trunc('month', p_ate)::date,
                         (date_trunc('month', privado.hoje()) + interval '24 months')::date,
                         coalesce(p_rec.fim, 'infinity'::date));
  v_mes    date;
  v_total  integer := 0;
  v_n      integer;
  v_qtd    integer;
  v_cat    uuid;
  v_conta  uuid;
begin
  select (max(competencia) + interval '1 month')::date into v_mes
    from public.obrigacoes where recorrencia_id = p_rec.id;
  v_mes := greatest(coalesce(v_mes, p_rec.inicio), p_rec.inicio);
  if v_mes > v_limite then return 0; end if;
  -- categoria/conta arquivadas depois: o mês novo nasce sem elas
  select id into v_cat from public.categorias where id = p_rec.categoria_id and ativa;
  select id into v_conta from public.contas where id = p_rec.conta_prevista_id and ativa;
  if p_rec.numerar_parcelas then
    v_qtd := ((extract(year from p_rec.fim) - extract(year from p_rec.inicio)) * 12
              + extract(month from p_rec.fim) - extract(month from p_rec.inicio))::int + 1;
  end if;
  while v_mes <= v_limite loop
    insert into public.obrigacoes (user_id, descricao, categoria_id, conta_prevista_id, valor_centavos,
                                   vencimento, competencia, origem, recorrencia_id, observacao)
    values (p_rec.user_id,
            case when p_rec.numerar_parcelas
                 then left(p_rec.descricao, 185) || ' (' || (((extract(year from v_mes) - extract(year from p_rec.inicio)) * 12
                        + extract(month from v_mes) - extract(month from p_rec.inicio))::int + 1) || '/' || v_qtd || ')'
                 else p_rec.descricao end,
            v_cat, v_conta, p_rec.valor_centavos,
            privado.vencimento_no_mes(v_mes, p_rec.dia_vencimento), v_mes, 'recorrencia', p_rec.id, p_rec.observacao)
    on conflict (recorrencia_id, competencia) do nothing;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    v_mes := (v_mes + interval '1 month')::date;
  end loop;
  return v_total;
end $$;

-- =====================================================================
-- RPCs: contas a pagar
-- =====================================================================
create or replace function public.obrigacao_criar(
  p_descricao           text,
  p_valor_centavos      bigint,
  p_vencimento          date,
  p_categoria_id        uuid,
  p_conta_prevista_id   uuid,
  p_observacao          text,
  p_chave_idempotencia  text
)
returns public.obrigacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.obrigacoes;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_criar', jsonb_build_object(
    'descricao', p_descricao, 'valor', p_valor_centavos, 'vencimento', p_vencimento, 'categoria_id', p_categoria_id,
    'conta_prevista_id', p_conta_prevista_id, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.obrigacoes, v_prev); end if;
  if p_vencimento is null then
    raise exception 'Informe o vencimento' using errcode = '22023';
  end if;
  insert into public.obrigacoes (user_id, descricao, categoria_id, conta_prevista_id, valor_centavos, vencimento, competencia, observacao)
  values (v_uid, btrim(p_descricao), p_categoria_id, p_conta_prevista_id, p_valor_centavos, p_vencimento,
          date_trunc('month', p_vencimento)::date, nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.obrigacao_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_descricao           text,
  p_valor_centavos      bigint,
  p_vencimento          date,
  p_categoria_id        uuid,
  p_conta_prevista_id   uuid,
  p_observacao          text,
  p_chave_idempotencia  text default null
)
returns public.obrigacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.obrigacoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'descricao', p_descricao, 'valor', p_valor_centavos, 'vencimento', p_vencimento,
      'categoria_id', p_categoria_id, 'conta_prevista_id', p_conta_prevista_id, 'observacao', p_observacao));
    if v_prev is not null then return jsonb_populate_record(null::public.obrigacoes, v_prev); end if;
  end if;
  if p_vencimento is null then
    raise exception 'Informe o vencimento' using errcode = '22023';
  end if;
  if exists (select 1 from public.obrigacoes where id = p_id and user_id = v_uid and situacao = 'cancelada') then
    raise exception 'Conta a pagar cancelada não pode ser alterada; reabra-a antes' using errcode = '22023';
  end if;
  update public.obrigacoes set
    descricao = btrim(p_descricao), valor_centavos = p_valor_centavos, vencimento = p_vencimento,
    competencia = case when origem = 'avulsa' then date_trunc('month', p_vencimento)::date else competencia end,
    categoria_id = p_categoria_id, conta_prevista_id = p_conta_prevista_id, observacao = nullif(btrim(p_observacao), '')
  where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.obrigacoes', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.obrigacao_cancelar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_motivo              text,
  p_chave_idempotencia  text default null
)
returns public.obrigacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.obrigacoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do cancelamento' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_cancelar',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo));
    if v_prev is not null then return jsonb_populate_record(null::public.obrigacoes, v_prev); end if;
  end if;
  perform set_config('app.motivo', btrim(p_motivo), true);
  update public.obrigacoes set situacao = 'cancelada', cancelada_motivo = btrim(p_motivo), cancelada_em = now()
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'aberta'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.obrigacoes where id = p_id and user_id = v_uid and situacao = 'cancelada') then
      raise exception 'Conta a pagar já está cancelada' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.obrigacoes', p_id, v_uid);
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.obrigacao_reabrir(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_chave_idempotencia  text default null
)
returns public.obrigacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.obrigacoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_reabrir',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada));
    if v_prev is not null then return jsonb_populate_record(null::public.obrigacoes, v_prev); end if;
  end if;
  update public.obrigacoes set situacao = 'aberta', cancelada_motivo = null, cancelada_em = null
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'cancelada'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.obrigacoes where id = p_id and user_id = v_uid and situacao = 'aberta') then
      raise exception 'Conta a pagar não está cancelada' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.obrigacoes', p_id, v_uid);
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Pagar: cria o lançamento de saída (despesa na categoria da conta a pagar)
-- e o pagamento ligado a ele, na mesma transação.
create or replace function public.obrigacao_pagar(
  p_obrigacao_id         uuid,
  p_conta_id             uuid,
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
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_obr  public.obrigacoes;
  v_cat  uuid;
  v_mov  public.movimentos;
  v_reg  public.pagamentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_pagar', jsonb_build_object(
    'obrigacao_id', p_obrigacao_id, 'conta_id', p_conta_id, 'data', p_data, 'valor', p_valor_pago_centavos,
    'juros', p_juros_centavos, 'multa', p_multa_centavos, 'desconto', p_desconto_centavos, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;

  if p_data is null then
    raise exception 'Informe a data do pagamento' using errcode = '22023';
  end if;
  if p_valor_pago_centavos is null or p_valor_pago_centavos <= 0 then
    raise exception 'Informe o valor pago, maior que zero' using errcode = '22023';
  end if;
  if coalesce(p_juros_centavos, 0) < 0 or coalesce(p_multa_centavos, 0) < 0 or coalesce(p_desconto_centavos, 0) < 0 then
    raise exception 'Juros, multa e desconto não podem ser negativos' using errcode = '22023';
  end if;
  -- trava a conta a pagar primeiro (mesma ordem do gatilho de pagamento)
  select * into v_obr from public.obrigacoes where id = p_obrigacao_id and user_id = v_uid for update;
  if not found then
    raise exception 'Conta a pagar não encontrada' using errcode = 'P0002';
  end if;
  if v_obr.situacao <> 'aberta' then
    raise exception 'Conta a pagar cancelada não recebe pagamento' using errcode = '22023';
  end if;
  if not exists (select 1 from public.contas where id = p_conta_id and user_id = v_uid) then
    raise exception 'Conta não encontrada' using errcode = 'P0002';
  end if;
  select id into v_cat from public.categorias where id = v_obr.categoria_id and ativa;

  insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao,
                                 classificacao, categoria_id, situacao, origem, observacao)
  values (v_uid, p_conta_id, 'debito', p_valor_pago_centavos, p_data, v_obr.descricao,
          case when v_cat is null then 'nao_classificado' else 'despesa' end, v_cat, 'efetivo', 'manual',
          nullif(btrim(p_observacao), ''))
  returning * into v_mov;

  insert into public.pagamentos (user_id, obrigacao_id, movimento_id, valor_pago_centavos, juros_centavos,
                                 multa_centavos, desconto_centavos, origem, observacao)
  values (v_uid, v_obr.id, v_mov.id, p_valor_pago_centavos, coalesce(p_juros_centavos, 0),
          coalesce(p_multa_centavos, 0), coalesce(p_desconto_centavos, 0), 'pagamento', nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Vincular: a saída já foi lançada (ou importada); só registra que ela pagou a conta.
create or replace function public.obrigacao_vincular_movimento(
  p_obrigacao_id         uuid,
  p_movimento_id         uuid,
  p_valor_pago_centavos  bigint,
  p_juros_centavos       bigint,
  p_multa_centavos       bigint,
  p_desconto_centavos    bigint,
  p_chave_idempotencia   text
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.pagamentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'obrigacao_vincular_movimento', jsonb_build_object(
    'obrigacao_id', p_obrigacao_id, 'movimento_id', p_movimento_id, 'valor', p_valor_pago_centavos,
    'juros', p_juros_centavos, 'multa', p_multa_centavos, 'desconto', p_desconto_centavos));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;
  if p_valor_pago_centavos is null or p_valor_pago_centavos <= 0 then
    raise exception 'Informe o valor pago, maior que zero' using errcode = '22023';
  end if;
  if coalesce(p_juros_centavos, 0) < 0 or coalesce(p_multa_centavos, 0) < 0 or coalesce(p_desconto_centavos, 0) < 0 then
    raise exception 'Juros, multa e desconto não podem ser negativos' using errcode = '22023';
  end if;
  if exists (select 1 from public.pagamentos where obrigacao_id = p_obrigacao_id and movimento_id = p_movimento_id
                                              and user_id = v_uid and situacao = 'ativo') then
    raise exception 'Este lançamento já está vinculado a esta conta a pagar' using errcode = '22023';
  end if;
  insert into public.pagamentos (user_id, obrigacao_id, movimento_id, valor_pago_centavos, juros_centavos,
                                 multa_centavos, desconto_centavos, origem)
  values (v_uid, p_obrigacao_id, p_movimento_id, p_valor_pago_centavos, coalesce(p_juros_centavos, 0),
          coalesce(p_multa_centavos, 0), coalesce(p_desconto_centavos, 0), 'vinculo')
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Desfazer um pagamento. Se ele criou o lançamento (origem 'pagamento'),
-- p_cancelar_lancamento = true também cancela o lançamento (o dinheiro
-- volta ao saldo). Vínculos apenas se desfazem; o lançamento fica.
create or replace function public.pagamento_desfazer(
  p_id                   uuid,
  p_versao_esperada      integer,
  p_motivo               text,
  p_cancelar_lancamento  boolean,
  p_chave_idempotencia   text default null
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.pagamentos;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'pagamento_desfazer', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo, 'cancelar_lancamento', p_cancelar_lancamento));
    if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;
  end if;
  -- trava a conta a pagar primeiro (mesma ordem do pagamento): quem tentar
  -- pagar ao mesmo tempo espera e já enxerga o restante liberado
  perform 1 from public.obrigacoes o
   where o.id = (select p.obrigacao_id from public.pagamentos p where p.id = p_id and p.user_id = v_uid)
     for update;
  perform set_config('app.motivo', btrim(p_motivo), true);
  update public.pagamentos set situacao = 'desfeito', desfeito_motivo = btrim(p_motivo), desfeito_em = now()
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'ativo'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.pagamentos where id = p_id and user_id = v_uid and situacao = 'desfeito') then
      raise exception 'Pagamento já foi desfeito' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.pagamentos', p_id, v_uid);
  end if;
  if coalesce(p_cancelar_lancamento, false) then
    if v_reg.origem <> 'pagamento' then
      raise exception 'Este pagamento só vinculou um lançamento existente; para cancelar o lançamento, use o extrato da conta' using errcode = '22023';
    end if;
    update public.movimentos set situacao = 'cancelado', cancelado_motivo = btrim(p_motivo), cancelado_em = now()
     where id = v_reg.movimento_id and user_id = v_uid and situacao <> 'cancelado';
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- RPCs: recorrências
-- =====================================================================
create or replace function public.recorrencia_criar(
  p_descricao           text,
  p_valor_centavos      bigint,
  p_dia_vencimento      integer,
  p_inicio              date,
  p_fim                 date,
  p_numerar_parcelas    boolean,
  p_categoria_id        uuid,
  p_conta_prevista_id   uuid,
  p_observacao          text,
  p_chave_idempotencia  text
)
returns public.recorrencias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.recorrencias;
  v_ini  date := date_trunc('month', p_inicio)::date;
  v_fim  date := date_trunc('month', p_fim)::date;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'recorrencia_criar', jsonb_build_object(
    'descricao', p_descricao, 'valor', p_valor_centavos, 'dia', p_dia_vencimento, 'inicio', p_inicio, 'fim', p_fim,
    'numerar', p_numerar_parcelas, 'categoria_id', p_categoria_id, 'conta_prevista_id', p_conta_prevista_id, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.recorrencias, v_prev); end if;
  if v_ini is null then
    raise exception 'Informe o mês de início' using errcode = '22023';
  end if;
  if v_ini < (date_trunc('month', privado.hoje()) - interval '12 months')::date then
    raise exception 'O início pode ser no máximo 12 meses atrás' using errcode = '22023';
  end if;
  if v_fim is not null and v_fim < v_ini then
    raise exception 'O último mês não pode ser anterior ao primeiro' using errcode = '22023';
  end if;
  if v_fim is not null and v_fim > (v_ini + interval '120 months')::date then
    raise exception 'A recorrência pode ter no máximo 120 meses definidos' using errcode = '22023';
  end if;
  if coalesce(p_numerar_parcelas, false) and v_fim is null then
    raise exception 'Para numerar as parcelas, informe o último mês' using errcode = '22023';
  end if;
  insert into public.recorrencias (user_id, descricao, categoria_id, conta_prevista_id, valor_centavos, dia_vencimento,
                                   inicio, fim, numerar_parcelas, observacao)
  values (v_uid, btrim(p_descricao), p_categoria_id, p_conta_prevista_id, p_valor_centavos, p_dia_vencimento,
          v_ini, v_fim, coalesce(p_numerar_parcelas, false), nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  -- já gera o mês atual e o próximo (ou o primeiro mês, se começar no futuro)
  perform privado.recorrencia_gerar(v_reg, (greatest(privado.hoje(), v_ini) + interval '1 month')::date);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Alterar o modelo. p_aplicar_em_abertas = true leva a mudança para as
-- contas já geradas a partir do mês atual que ainda estão abertas e sem
-- pagamento. Meses passados, pagos ou ajustados com pagamento não mudam.
create or replace function public.recorrencia_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_descricao           text,
  p_valor_centavos      bigint,
  p_dia_vencimento      integer,
  p_categoria_id        uuid,
  p_conta_prevista_id   uuid,
  p_observacao          text,
  p_aplicar_em_abertas  boolean,
  p_chave_idempotencia  text default null
)
returns public.recorrencias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.recorrencias;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'recorrencia_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'descricao', p_descricao, 'valor', p_valor_centavos, 'dia', p_dia_vencimento,
      'categoria_id', p_categoria_id, 'conta_prevista_id', p_conta_prevista_id, 'observacao', p_observacao,
      'aplicar', p_aplicar_em_abertas));
    if v_prev is not null then return jsonb_populate_record(null::public.recorrencias, v_prev); end if;
  end if;
  update public.recorrencias set
    descricao = btrim(p_descricao), valor_centavos = p_valor_centavos, dia_vencimento = p_dia_vencimento,
    categoria_id = p_categoria_id, conta_prevista_id = p_conta_prevista_id, observacao = nullif(btrim(p_observacao), '')
  where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.recorrencias', p_id, v_uid); end if;

  if coalesce(p_aplicar_em_abertas, false) then
    update public.obrigacoes o set
      descricao = case when v_reg.numerar_parcelas
                       then left(v_reg.descricao, 185) || coalesce(substring(o.descricao from ' \(\d+/\d+\)$'), '')
                       else v_reg.descricao end,
      valor_centavos = v_reg.valor_centavos,
      vencimento = privado.vencimento_no_mes(o.competencia, v_reg.dia_vencimento),
      categoria_id = v_reg.categoria_id, conta_prevista_id = v_reg.conta_prevista_id,
      observacao = v_reg.observacao
    where o.recorrencia_id = v_reg.id and o.user_id = v_uid and o.situacao = 'aberta'
      and o.competencia >= date_trunc('month', privado.hoje())::date
      and not exists (select 1 from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo');
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Define o último mês (encerra) ou, com p_ultimo_mes = null, volta a
-- repetir sem fim. Meses posteriores ao último que ainda estão abertos e
-- sem pagamento são cancelados com o motivo "Recorrência encerrada"; se a
-- recorrência for retomada, esses meses voltam a ficar abertos.
create or replace function public.recorrencia_definir_fim(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_ultimo_mes          date,
  p_chave_idempotencia  text default null
)
returns public.recorrencias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_reg   public.recorrencias;
  v_fim   date := date_trunc('month', p_ultimo_mes)::date;
  c_motivo constant text := 'Recorrência encerrada';
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'recorrencia_definir_fim',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'ultimo_mes', p_ultimo_mes));
    if v_prev is not null then return jsonb_populate_record(null::public.recorrencias, v_prev); end if;
  end if;
  if exists (select 1 from public.recorrencias where id = p_id and user_id = v_uid and numerar_parcelas) and v_fim is null then
    raise exception 'Recorrência com parcelas numeradas precisa de um último mês' using errcode = '22023';
  end if;
  update public.recorrencias set fim = v_fim
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.recorrencias', p_id, v_uid); end if;

  -- retomada: reabre os meses cancelados pelo encerramento que voltaram a valer
  perform set_config('app.motivo', 'Recorrência retomada', true);
  update public.obrigacoes set situacao = 'aberta', cancelada_motivo = null, cancelada_em = null
   where recorrencia_id = v_reg.id and user_id = v_uid and situacao = 'cancelada' and cancelada_motivo = c_motivo
     and (v_fim is null or competencia <= v_fim);
  -- encerramento: cancela os meses seguintes ainda abertos e sem pagamento
  perform set_config('app.motivo', c_motivo, true);
  update public.obrigacoes o set situacao = 'cancelada', cancelada_motivo = c_motivo, cancelada_em = now()
   where o.recorrencia_id = v_reg.id and o.user_id = v_uid and o.situacao = 'aberta'
     and v_fim is not null and o.competencia > v_fim
     and not exists (select 1 from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo');
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Gera, para todas as recorrências do usuário, os meses até p_ate.
-- Idempotente por natureza (cada mês existe uma vez), por isso não exige
-- chave. Devolve quantas contas a pagar foram criadas.
create or replace function public.recorrencias_gerar(p_ate date)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_rec   public.recorrencias;
  v_total integer := 0;
begin
  if p_ate is null then
    raise exception 'Informe até quando gerar' using errcode = '22023';
  end if;
  for v_rec in select * from public.recorrencias where user_id = v_uid and (fim is null or fim >= inicio) order by criado_em loop
    v_total := v_total + privado.recorrencia_gerar(v_rec, p_ate);
  end loop;
  return v_total;
end $$;

-- =====================================================================
-- CONSULTAS (somente leitura, sob RLS do próprio usuário)
-- =====================================================================
-- Contas a pagar com vencimento no período; p_incluir_vencidas traz
-- também as de antes do período que continuam em aberto.
-- status: cancelada | paga | vencida | parcial | a_vencer
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
           sum(p.abatido_centavos)::bigint as abatido, count(*)::int as n, max(m.data_movimento) as ultimo
      from public.pagamentos p
      join public.movimentos m on m.id = p.movimento_id
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

-- Pagamentos de uma conta a pagar (ativos e desfeitos)
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
  select p.id, p.movimento_id, m.data_movimento, m.conta_id, c.apelido,
         p.valor_pago_centavos, p.juros_centavos, p.multa_centavos, p.desconto_centavos, p.abatido_centavos,
         p.origem, p.situacao, p.desfeito_motivo, m.situacao, p.observacao, p.versao
    from public.pagamentos p
    join public.movimentos m on m.id = p.movimento_id
    join public.contas c on c.id = m.conta_id
   where p.user_id = auth.uid() and p.obrigacao_id = p_obrigacao_id
   order by p.situacao, m.data_movimento, p.criado_em;
$$;

-- Saídas já lançadas que podem pagar a conta (livres, até 60 dias do vencimento)
create or replace function public.movimentos_para_vincular(p_obrigacao_id uuid)
returns table (
  movimento_id     uuid,
  conta_id         uuid,
  conta            text,
  data_movimento   date,
  descricao        text,
  valor_centavos   bigint,
  livre_centavos   bigint,
  categoria        text
)
language sql stable security invoker
set search_path = ''
as $$
  with ob as (select * from public.obrigacoes where id = p_obrigacao_id and user_id = auth.uid()),
  mv as (
    select m.*, m.valor_centavos
             - coalesce((select sum(e.valor_centavos) from public.movimentos e where e.estorno_de = m.id and e.situacao <> 'cancelado'), 0)
             - coalesce((select sum(p.valor_pago_centavos) from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo'), 0) as livre
      from public.movimentos m, ob
     where m.user_id = auth.uid() and m.situacao = 'efetivo' and m.natureza = 'debito' and m.estorno_de is null
       and m.data_movimento between ob.vencimento - 60 and ob.vencimento + 60
       and not exists (select 1 from public.pagamentos p where p.movimento_id = m.id and p.obrigacao_id = ob.id and p.situacao = 'ativo')
  )
  select mv.id, mv.conta_id, c.apelido, mv.data_movimento, mv.descricao, mv.valor_centavos, mv.livre, cat.nome
    from mv
    cross join ob
    join public.contas c on c.id = mv.conta_id
    left join public.categorias cat on cat.id = mv.categoria_id
   where mv.livre > 0
   order by abs(mv.data_movimento - ob.vencimento), mv.data_movimento desc
   limit 50;
$$;

-- Quanto falta pagar até uma data, por conta prevista (null = sem conta)
create or replace function public.contas_a_pagar_por_conta(p_ate date)
returns table (
  conta_prevista_id   uuid,
  quantidade          integer,
  restante_centavos   bigint,
  vencidas_centavos   bigint
)
language sql stable security invoker
set search_path = ''
as $$
  select r.conta_prevista_id, count(*)::int, sum(r.restante)::bigint,
         coalesce(sum(r.restante) filter (where r.vencimento < privado.hoje()), 0)::bigint
    from (
      select o.conta_prevista_id, o.vencimento,
             o.valor_centavos - coalesce((select sum(p.abatido_centavos) from public.pagamentos p
                                           where p.obrigacao_id = o.id and p.situacao = 'ativo'), 0) as restante
        from public.obrigacoes o
       where o.user_id = auth.uid() and o.situacao = 'aberta' and o.vencimento <= p_ate
    ) r
   where r.restante > 0
   group by r.conta_prevista_id;
$$;

-- =====================================================================
-- LGPD: exportação e exclusão incluem as novas tabelas
-- =====================================================================
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := privado.uid_obrigatorio();
begin
  return jsonb_build_object(
    'gerado_em',     now(),
    'perfil',        (select to_jsonb(p) from public.perfis p where p.id = v_uid),
    'titulares',     coalesce((select jsonb_agg(t order by t.criado_em) from public.titulares t where t.user_id = v_uid), '[]'),
    'contas',        coalesce((select jsonb_agg(c order by c.criado_em) from public.contas c where c.user_id = v_uid), '[]'),
    'categorias',    coalesce((select jsonb_agg(c order by c.criado_em) from public.categorias c where c.user_id = v_uid), '[]'),
    'movimentos',    coalesce((select jsonb_agg(m order by m.data_movimento, m.criado_em) from public.movimentos m where m.user_id = v_uid), '[]'),
    'recorrencias',  coalesce((select jsonb_agg(r order by r.criado_em) from public.recorrencias r where r.user_id = v_uid), '[]'),
    'contas_a_pagar', coalesce((select jsonb_agg(o order by o.vencimento, o.criado_em) from public.obrigacoes o where o.user_id = v_uid), '[]'),
    'pagamentos',    coalesce((select jsonb_agg(p order by p.criado_em) from public.pagamentos p where p.user_id = v_uid), '[]'),
    'documentos',    coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                                 from storage.objects o
                                where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'),
    'auditoria',     coalesce((select jsonb_agg(a order by a.id) from public.auditoria a where a.user_id = v_uid), '[]')
  );
end $$;

create or replace function public.exclusao_concluir(p_user_id uuid, p_arquivos_removidos integer default 0, p_espera_ms integer default 20000)
returns public.exclusoes_conta
language plpgsql security definer
set search_path = ''
as $$
declare
  v_reg      public.exclusoes_conta;
  v_restante integer;
begin
  select * into v_reg from public.exclusoes_conta
   where user_id = p_user_id and status <> 'concluida'
   for update;
  if not found then
    raise exception 'Não há solicitação de exclusão ativa para este usuário' using errcode = 'P0002';
  end if;

  perform set_config('lock_timeout', greatest(100, least(coalesce(p_espera_ms, 20000), 60000))::text || 'ms', true);
  perform pg_advisory_xact_lock(privado.chave_trava_usuario(p_user_id));
  perform set_config('lock_timeout', '0', true);

  select count(*) into v_restante from storage.objects o
   where (storage.foldername(o.name))[1] = p_user_id::text;
  if v_restante > 0 then
    raise exception 'Ainda existem % arquivo(s) do usuário no Storage; exclusão não concluída', v_restante
      using errcode = 'SF410';
  end if;

  perform set_config('app.excluindo_usuario', p_user_id::text, true);
  delete from public.auditoria           where user_id = p_user_id;
  delete from public.chaves_idempotencia where user_id = p_user_id;
  delete from public.uso_eventos         where user_id = p_user_id;
  delete from public.limites_uso         where user_id = p_user_id;
  delete from public.pagamentos          where user_id = p_user_id;
  delete from public.obrigacoes          where user_id = p_user_id;
  delete from public.recorrencias        where user_id = p_user_id;
  delete from public.movimentos          where user_id = p_user_id;
  delete from public.contas              where user_id = p_user_id;
  delete from public.categorias          where user_id = p_user_id;
  delete from public.titulares           where user_id = p_user_id;
  delete from public.perfis              where user_id = p_user_id;
  delete from auth.users                 where id = p_user_id;

  update public.exclusoes_conta
     set status = 'concluida', concluida_em = now(), atualizado_em = now(), ultimo_erro = null,
         arquivos_removidos = arquivos_removidos + coalesce(p_arquivos_removidos, 0)
   where id = v_reg.id
  returning * into v_reg;
  return v_reg;
end $$;

-- =====================================================================
-- Permissões das funções NOVAS desta etapa
-- =====================================================================
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as assinatura
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'privado' and p.proname in ('reais', 'vencimento_no_mes', 'exigir_categoria_despesa', 'exigir_conta_ativa',
                     'recorrencia_validar', 'obrigacao_validar', 'pagamento_validar', 'movimento_regras_pagamento', 'recorrencia_gerar'))
               or (n.nspname = 'public' and p.proname in ('obrigacao_criar', 'obrigacao_atualizar', 'obrigacao_cancelar', 'obrigacao_reabrir',
                     'obrigacao_pagar', 'obrigacao_vincular_movimento', 'pagamento_desfazer', 'recorrencia_criar', 'recorrencia_atualizar',
                     'recorrencia_definir_fim', 'recorrencias_gerar', 'contas_a_pagar', 'pagamentos_da_obrigacao',
                     'movimentos_para_vincular', 'contas_a_pagar_por_conta'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.assinatura);
  end loop;
end $$;

grant execute on function public.obrigacao_criar(text, bigint, date, uuid, uuid, text, text) to authenticated;
grant execute on function public.obrigacao_atualizar(uuid, integer, text, bigint, date, uuid, uuid, text, text) to authenticated;
grant execute on function public.obrigacao_cancelar(uuid, integer, text, text) to authenticated;
grant execute on function public.obrigacao_reabrir(uuid, integer, text) to authenticated;
grant execute on function public.obrigacao_pagar(uuid, uuid, date, bigint, bigint, bigint, bigint, text, text) to authenticated;
grant execute on function public.obrigacao_vincular_movimento(uuid, uuid, bigint, bigint, bigint, bigint, text) to authenticated;
grant execute on function public.pagamento_desfazer(uuid, integer, text, boolean, text) to authenticated;
grant execute on function public.recorrencia_criar(text, bigint, integer, date, date, boolean, uuid, uuid, text, text) to authenticated;
grant execute on function public.recorrencia_atualizar(uuid, integer, text, bigint, integer, uuid, uuid, text, boolean, text) to authenticated;
grant execute on function public.recorrencia_definir_fim(uuid, integer, date, text) to authenticated;
grant execute on function public.recorrencias_gerar(date) to authenticated;
grant execute on function public.contas_a_pagar(date, date, boolean) to authenticated;
grant execute on function public.pagamentos_da_obrigacao(uuid) to authenticated;
grant execute on function public.movimentos_para_vincular(uuid) to authenticated;
grant execute on function public.contas_a_pagar_por_conta(date) to authenticated;

update public.versao_esquema set etapa = '3-contas-a-pagar', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
