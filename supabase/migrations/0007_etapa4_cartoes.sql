-- =====================================================================
-- Simplifica Finanças v2 — 0007 Etapa 4: cartões de crédito, faturas,
-- compras, parcelas, antecipações e estornos.
--
-- Migração ADICIONAL sobre a 0006 (etapa "3-contas-a-pagar"). Não apaga
-- nem recria nada. Tudo numa única transação.
--
-- CONCEITOS
--   Cartão (cartoes): dia de fechamento, dia de vencimento, limite e a
--     conta bancária de onde a fatura costuma ser paga.
--   Fatura (faturas): uma por cartão e mês de vencimento. O total é a
--     soma das parcelas ativas (débitos − créditos); NUNCA é digitado.
--     O total informado pelo banco é guardado à parte, só para conferir.
--   Compra (compras): compra à vista ou parcelada, encargo (juros, IOF,
--     tarifa, anuidade, multa), crédito ou estorno. Cada uma gera
--     parcelas (parcelas), e cada parcela pertence a uma fatura.
--   Regra de fechamento: compra feita ANTES do dia de fechamento entra
--     na fatura que fecha naquele mês; no dia do fechamento ou depois,
--     na seguinte. A fatura pode ser escolhida à mão quando o banco
--     tiver lançado diferente.
--
-- INTEGRAÇÃO
--   * Cada fatura com valor a pagar tem UMA conta a pagar (origem
--     'fatura') cujo valor acompanha a fatura automaticamente. As compras
--     NÃO viram contas a pagar: nada é somado duas vezes.
--   * Pagar a fatura lança a saída como "pagamento de fatura" (nova
--     classificação), que mexe no saldo mas NÃO é despesa: as despesas
--     são as compras, por categoria, no mês do vencimento da fatura.
--   * Antecipar parcelas leva as parcelas escolhidas para a fatura
--     atual (com desconto, se houver), guarda a fatura original e tira o
--     valor das faturas futuras.
--   * Estados da parcela: a cobrar → cobrada (fatura fechou) → quitada
--     (fatura paga); antecipada é marcada à parte, sem perder o histórico.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '3-contas-a-pagar') then
    raise exception 'ABORTADO: este banco não está na Etapa 3 (0006) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- Datas da fatura (funções puras)
-- =====================================================================
-- Mês de vencimento (competência) da fatura em que cai uma compra.
create or replace function privado.fatura_competencia(p_data date, p_dia_fechamento integer, p_dia_vencimento integer)
returns date
language sql immutable
set search_path = ''
as $$
  select ((case when p_data < privado.vencimento_no_mes(p_data, p_dia_fechamento)
                then date_trunc('month', p_data)
                else date_trunc('month', p_data) + interval '1 month' end)
          + case when p_dia_vencimento > p_dia_fechamento then interval '0' else interval '1 month' end)::date;
$$;

-- Fechamento e vencimento previstos de uma competência
create or replace function privado.fatura_fechamento(p_competencia date, p_dia_fechamento integer, p_dia_vencimento integer)
returns date
language sql immutable
set search_path = ''
as $$
  select least(
           privado.vencimento_no_mes((case when p_dia_vencimento > p_dia_fechamento then p_competencia
                                           else p_competencia - interval '1 month' end)::date, p_dia_fechamento),
           privado.vencimento_no_mes(p_competencia, p_dia_vencimento) - 1);
$$;

-- =====================================================================
-- Movimentos: nova classificação "pagamento_fatura" (sai da conta, mas
-- não é despesa; as despesas são as compras do cartão)
-- =====================================================================
alter table public.movimentos drop constraint movimentos_classificacao_check;
alter table public.movimentos add constraint movimentos_classificacao_check
  check (classificacao in ('receita', 'despesa', 'nao_classificado', 'pagamento_fatura'));
alter table public.movimentos drop constraint movimentos_check;
alter table public.movimentos add constraint movimentos_categoria_conforme_classificacao
  check ((classificacao in ('nao_classificado', 'pagamento_fatura')) = (categoria_id is null));
alter table public.movimentos add constraint movimentos_pagamento_fatura_e_saida
  check (classificacao <> 'pagamento_fatura' or natureza = 'debito' or estorno_de is not null);

-- Pagamentos guardam a classificação anterior quando um lançamento é
-- vinculado a uma fatura (para devolver se o vínculo for desfeito)
alter table public.pagamentos add column classificacao_anterior text,
                              add column categoria_anterior uuid;

-- =====================================================================
-- TABELAS
-- =====================================================================
create table public.cartoes (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  titular_id          uuid not null,
  instituicao_id      uuid not null references public.instituicoes (id),
  apelido             text not null check (length(btrim(apelido)) between 1 and 80),
  final               text check (final ~ '^[0-9]{4}$'),
  limite_centavos     bigint check (limite_centavos >= 0 and limite_centavos <= 10000000000000),
  dia_fechamento      integer not null check (dia_fechamento between 1 and 31),
  dia_vencimento      integer not null check (dia_vencimento between 1 and 31),
  conta_pagamento_id  uuid,
  ativo               boolean not null default true,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  versao              integer not null default 1,
  unique (id, user_id),
  foreign key (titular_id, user_id) references public.titulares (id, user_id),
  foreign key (conta_pagamento_id, user_id) references public.contas (id, user_id),
  check (dia_fechamento <> dia_vencimento)
);
create unique index cartoes_apelido_unico on public.cartoes (user_id, lower(btrim(apelido)));
alter table public.cartoes enable row level security;
create policy cartoes_select on public.cartoes for select to authenticated using (user_id = auth.uid());
grant select on public.cartoes to authenticated;
select privado.aplicar_gatilhos_padrao('public.cartoes');

create table public.faturas (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users (id) on delete cascade,
  cartao_id                 uuid not null,
  competencia               date not null check (competencia = date_trunc('month', competencia)::date),
  fechamento                date not null,
  vencimento                date not null,
  total_informado_centavos  bigint check (abs(total_informado_centavos) <= 10000000000000),
  obrigacao_id              uuid unique,
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),
  versao                    integer not null default 1,
  unique (id, user_id),
  unique (cartao_id, competencia),
  foreign key (cartao_id, user_id) references public.cartoes (id, user_id),
  foreign key (obrigacao_id, user_id) references public.obrigacoes (id, user_id),
  check (fechamento < vencimento)
);
alter table public.faturas enable row level security;
create policy faturas_select on public.faturas for select to authenticated using (user_id = auth.uid());
grant select on public.faturas to authenticated;
select privado.aplicar_gatilhos_padrao('public.faturas');

create table public.compras (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  cartao_id             uuid not null,
  tipo                  text not null check (tipo in ('compra', 'encargo', 'credito', 'estorno')),
  subtipo               text check (subtipo in ('juros', 'iof', 'tarifa', 'anuidade', 'multa', 'outro')),
  natureza              text generated always as (case when tipo in ('compra', 'encargo') then 'debito' else 'credito' end) stored,
  data_compra           date not null,
  descricao             text not null check (length(btrim(descricao)) between 1 and 200),
  categoria_id          uuid,
  valor_total_centavos  bigint not null check (valor_total_centavos > 0 and valor_total_centavos <= 10000000000000),
  parcelas_total        integer not null default 1 check (parcelas_total between 1 and 99),
  parcela_inicial       integer not null default 1,
  estorno_de            uuid,
  situacao              text not null default 'ativa' check (situacao in ('ativa', 'cancelada')),
  cancelada_motivo      text,
  cancelada_em          timestamptz,
  origem                text not null default 'manual' check (origem in ('manual', 'importacao', 'whatsapp')),
  observacao            text check (length(observacao) <= 500),
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  versao                integer not null default 1,
  unique (id, user_id),
  foreign key (cartao_id, user_id) references public.cartoes (id, user_id),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  foreign key (estorno_de, user_id) references public.compras (id, user_id),
  check (parcela_inicial between 1 and parcelas_total),
  check ((tipo = 'encargo') = (subtipo is not null)),
  check (tipo = 'compra' or (parcelas_total = 1 and parcela_inicial = 1)),
  check ((tipo = 'estorno') = (estorno_de is not null)),
  check ((situacao = 'cancelada') = (cancelada_em is not null))
);
create index compras_cartao_idx on public.compras (user_id, cartao_id, data_compra);
create index compras_estorno_idx on public.compras (estorno_de) where estorno_de is not null;
alter table public.compras enable row level security;
create policy compras_select on public.compras for select to authenticated using (user_id = auth.uid());
grant select on public.compras to authenticated;
select privado.aplicar_gatilhos_padrao('public.compras');

create table public.parcelas (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  compra_id             uuid not null,
  cartao_id             uuid not null,
  numero                integer not null check (numero between 1 and 99),
  natureza              text not null check (natureza in ('debito', 'credito')),
  valor_centavos        bigint not null check (valor_centavos > 0),
  desconto_centavos     bigint not null default 0 check (desconto_centavos >= 0),
  valor_assinado_centavos bigint generated always as
                        (case when natureza = 'debito' then valor_centavos - desconto_centavos else -valor_centavos end) stored,
  fatura_id             uuid not null,
  fatura_original_id    uuid,
  antecipada_em         timestamptz,
  situacao              text not null default 'ativa' check (situacao in ('ativa', 'cancelada')),
  cancelada_motivo      text,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  versao                integer not null default 1,
  unique (id, user_id),
  unique (compra_id, numero),
  foreign key (compra_id, user_id) references public.compras (id, user_id),
  foreign key (fatura_id, user_id) references public.faturas (id, user_id),
  foreign key (fatura_original_id, user_id) references public.faturas (id, user_id),
  check (desconto_centavos <= valor_centavos),
  check (natureza = 'debito' or desconto_centavos = 0),
  check ((antecipada_em is null) = (fatura_original_id is null))
);
create index parcelas_fatura_idx on public.parcelas (fatura_id) where situacao = 'ativa';
alter table public.parcelas enable row level security;
create policy parcelas_select on public.parcelas for select to authenticated using (user_id = auth.uid());
grant select on public.parcelas to authenticated;
select privado.aplicar_gatilhos_padrao('public.parcelas');

-- =====================================================================
-- REGRAS (gatilhos)
-- =====================================================================
create or replace function privado.cartao_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.ativo then
    perform 1 from public.titulares where id = new.titular_id and user_id = new.user_id and ativo for share;
    if not found then
      raise exception 'Titular arquivado ou inexistente: o cartão não pode ficar ativo' using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' or new.conta_pagamento_id is distinct from old.conta_pagamento_id then
    perform privado.exigir_conta_ativa(new.user_id, new.conta_pagamento_id);
  end if;
  return new;
end $$;
create trigger cartoes_validar before insert or update on public.cartoes
  for each row execute function privado.cartao_validar();

-- Titular com cartão ativo não pode ser arquivado
create or replace function privado.titular_arquivar_sem_cartoes_ativos()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ativo and not new.ativo
     and exists (select 1 from public.cartoes where titular_id = new.id and user_id = new.user_id and ativo) then
    raise exception 'Arquive antes os cartões ativos deste titular' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger titulares_arquivar_sem_cartoes_ativos before update on public.titulares
  for each row execute function privado.titular_arquivar_sem_cartoes_ativos();

create or replace function privado.compra_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.situacao <> 'ativa' then
      raise exception 'Lançamento do cartão não pode nascer cancelado' using errcode = '22023';
    end if;
    perform 1 from public.cartoes where id = new.cartao_id and user_id = new.user_id and ativo for share;
    if not found then
      raise exception 'Cartão inexistente ou arquivado' using errcode = '22023';
    end if;
  else
    if new.cartao_id <> old.cartao_id or new.tipo <> old.tipo or new.subtipo is distinct from old.subtipo
       or new.valor_total_centavos <> old.valor_total_centavos or new.parcelas_total <> old.parcelas_total
       or new.parcela_inicial <> old.parcela_inicial or new.data_compra <> old.data_compra
       or new.estorno_de is distinct from old.estorno_de then
      raise exception 'Valor, data, parcelas e tipo do lançamento do cartão não mudam: cancele e lance de novo' using errcode = '22023';
    end if;
    if old.situacao = 'cancelada' and new.situacao <> 'cancelada' then
      raise exception 'Lançamento cancelado não volta a valer' using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' or new.categoria_id is distinct from old.categoria_id then
    perform privado.exigir_categoria_despesa(new.user_id, new.categoria_id);
  end if;
  return new;
end $$;
create trigger compras_validar before insert or update on public.compras
  for each row execute function privado.compra_validar();

-- Parcela: trava a fatura (FOR UPDATE) para o total ser recalculado em fila
create or replace function privado.parcela_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_fat public.faturas;
begin
  if tg_op = 'UPDATE' then
    if new.compra_id <> old.compra_id or new.numero <> old.numero or new.natureza <> old.natureza
       or new.valor_centavos <> old.valor_centavos or new.cartao_id <> old.cartao_id then
      raise exception 'Parcela não muda de compra, número, sentido ou valor' using errcode = '22023';
    end if;
    if old.situacao = 'cancelada' and new.situacao <> 'cancelada' then
      raise exception 'Parcela cancelada não volta a valer' using errcode = '22023';
    end if;
    if new.fatura_id = old.fatura_id and new.situacao = old.situacao and new.desconto_centavos = old.desconto_centavos then
      return new;
    end if;
    perform 1 from public.faturas where id = old.fatura_id for update;
  end if;
  select * into v_fat from public.faturas where id = new.fatura_id and user_id = new.user_id for update;
  if not found or v_fat.cartao_id <> new.cartao_id then
    raise exception 'Fatura inexistente ou de outro cartão' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger parcelas_validar before insert or update on public.parcelas
  for each row execute function privado.parcela_validar();

-- =====================================================================
-- Fatura ↔ conta a pagar
-- =====================================================================
-- Obtém (ou cria) a fatura de um cartão numa competência
create or replace function privado.fatura_obter(p_cartao_id uuid, p_competencia date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_c   public.cartoes;
  v_id  uuid;
  v_comp date := date_trunc('month', p_competencia)::date;
begin
  select id into v_id from public.faturas where cartao_id = p_cartao_id and competencia = v_comp;
  if found then return v_id; end if;
  select * into v_c from public.cartoes where id = p_cartao_id;
  insert into public.faturas (user_id, cartao_id, competencia, fechamento, vencimento)
  values (v_c.user_id, v_c.id, v_comp,
          privado.fatura_fechamento(v_comp, v_c.dia_fechamento, v_c.dia_vencimento),
          privado.vencimento_no_mes(v_comp, v_c.dia_vencimento))
  on conflict (cartao_id, competencia) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.faturas where cartao_id = p_cartao_id and competencia = v_comp;
  end if;
  return v_id;
end $$;

-- Recalcula o total da fatura e acerta a conta a pagar dela.
-- Total > 0: conta a pagar aberta com esse valor. Total <= 0: conta a pagar
-- cancelada ("sem valor a pagar"), salvo se já houver pagamento (recusa).
create or replace function privado.fatura_sincronizar(p_fatura_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_f       public.faturas;
  v_c       public.cartoes;
  v_o       public.obrigacoes;
  v_total   bigint;
  v_abatido bigint := 0;
  v_conta   uuid;
begin
  select * into v_f from public.faturas where id = p_fatura_id for update;
  if not found then return; end if;
  select * into v_c from public.cartoes where id = v_f.cartao_id;
  select coalesce(sum(valor_assinado_centavos), 0) into v_total
    from public.parcelas where fatura_id = p_fatura_id and situacao = 'ativa';
  perform set_config('app.fatura_sistema', 'on', true);
  if v_f.obrigacao_id is null then
    if v_total > 0 then
      select id into v_conta from public.contas where id = v_c.conta_pagamento_id and ativa;
      insert into public.obrigacoes (user_id, descricao, categoria_id, conta_prevista_id, valor_centavos, vencimento,
                                     competencia, origem)
      values (v_f.user_id, left('Fatura ' || v_c.apelido || ' ' || to_char(v_f.competencia, 'MM/YYYY'), 200), null, v_conta,
              v_total, v_f.vencimento, v_f.competencia, 'fatura')
      returning * into v_o;
      update public.faturas set obrigacao_id = v_o.id where id = p_fatura_id;
    end if;
  else
    select * into v_o from public.obrigacoes where id = v_f.obrigacao_id for update;
    select coalesce(sum(abatido_centavos), 0) into v_abatido
      from public.pagamentos where obrigacao_id = v_o.id and situacao = 'ativo';
    if v_total < v_abatido then
      raise exception 'A fatura de % já tem % pagos; com esta alteração o total ficaria %. Desfaça o pagamento antes, ou lance o crédito na fatura seguinte.',
        to_char(v_f.competencia, 'MM/YYYY'), privado.reais(v_abatido), privado.reais(v_total) using errcode = '22023';
    end if;
    if v_total > 0 then
      update public.obrigacoes set valor_centavos = v_total, vencimento = v_f.vencimento,
             situacao = 'aberta', cancelada_motivo = null, cancelada_em = null
       where id = v_o.id
         and (valor_centavos <> v_total or vencimento <> v_f.vencimento or situacao <> 'aberta');
    elsif v_o.situacao = 'aberta' then
      update public.obrigacoes set situacao = 'cancelada', cancelada_motivo = 'Fatura sem valor a pagar', cancelada_em = now()
       where id = v_o.id;
    end if;
  end if;
  perform set_config('app.fatura_sistema', '', true);
end $$;

create or replace function privado.parcela_sincronizar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.fatura_id <> new.fatura_id then
    perform privado.fatura_sincronizar(old.fatura_id);
  end if;
  perform privado.fatura_sincronizar(new.fatura_id);
  return null;
end $$;
create trigger parcelas_sincronizar after insert or update on public.parcelas
  for each row execute function privado.parcela_sincronizar();

-- Contas a pagar de fatura só mudam pelo próprio cartão (substitui a da 0006)
create or replace function privado.obrigacao_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_abatido bigint;
  v_sistema boolean := coalesce(current_setting('app.fatura_sistema', true), '') = 'on';
begin
  if tg_op = 'INSERT' and new.situacao <> 'aberta' then
    raise exception 'Conta a pagar não pode nascer cancelada' using errcode = '22023';
  end if;
  if not v_sistema and (new.origem = 'fatura' or (tg_op = 'UPDATE' and old.origem = 'fatura')) then
    if tg_op = 'INSERT' or new.valor_centavos <> old.valor_centavos or new.vencimento <> old.vencimento
       or new.situacao <> old.situacao or new.descricao <> old.descricao or new.categoria_id is distinct from old.categoria_id
       or new.competencia <> old.competencia then
      raise exception 'A conta a pagar da fatura acompanha os lançamentos do cartão: ajuste na aba Cartões' using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' or new.categoria_id is distinct from old.categoria_id then
    perform privado.exigir_categoria_despesa(new.user_id, new.categoria_id);
  end if;
  if tg_op = 'INSERT' or new.conta_prevista_id is distinct from old.conta_prevista_id then
    perform privado.exigir_conta_ativa(new.user_id, new.conta_prevista_id);
  end if;
  if tg_op = 'UPDATE' then
    if new.origem <> old.origem or new.recorrencia_id is distinct from old.recorrencia_id
       or (old.origem = 'recorrencia' and new.competencia <> old.competencia) then
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

-- Pagamento de fatura só com lançamento "pagamento de fatura", e vice-versa.
-- Roda depois de pagamentos_validar (ordem alfabética), com as travas já feitas.
create or replace function privado.pagamento_validar_fatura()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_origem text;
  v_class  text;
begin
  if tg_op <> 'INSERT' then return new; end if;
  select origem into v_origem from public.obrigacoes where id = new.obrigacao_id;
  select classificacao into v_class from public.movimentos where id = new.movimento_id;
  if v_origem = 'fatura' and v_class <> 'pagamento_fatura' then
    raise exception 'Fatura de cartão só é paga por lançamento marcado como pagamento de fatura' using errcode = '22023';
  end if;
  if v_origem <> 'fatura' and v_class = 'pagamento_fatura' then
    raise exception 'Lançamento de pagamento de fatura só paga faturas de cartão' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger pagamentos_validar_fatura before insert on public.pagamentos
  for each row execute function privado.pagamento_validar_fatura();

-- Lançamento que paga conta: além das regras da 0006, não troca de/para
-- "pagamento de fatura" enquanto paga alguma coisa (substitui a da 0006)
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
    if new.classificacao is distinct from old.classificacao
       and 'pagamento_fatura' in (new.classificacao, old.classificacao) then
      raise exception 'Este lançamento já paga outra conta: use um lançamento só para a fatura' using errcode = '22023';
    end if;
    select coalesce(sum(valor_centavos), 0) into v_estornos
      from public.movimentos where estorno_de = new.id and situacao <> 'cancelado';
    if new.valor_centavos - v_estornos < v_usado then
      raise exception 'O valor não pode ficar menor que o usado para pagar contas (%)', privado.reais(v_usado) using errcode = '22023';
    end if;
    return new;
  end if;

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

-- =====================================================================
-- RPCs de pagamento (substituem as da 0006): fatura → "pagamento de fatura"
-- =====================================================================
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
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_obr   public.obrigacoes;
  v_cat   uuid;
  v_class text;
  v_mov   public.movimentos;
  v_reg   public.pagamentos;
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
  if v_obr.origem = 'fatura' then
    v_class := 'pagamento_fatura';
  else
    select id into v_cat from public.categorias where id = v_obr.categoria_id and ativa;
    v_class := case when v_cat is null then 'nao_classificado' else 'despesa' end;
  end if;

  insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao,
                                 classificacao, categoria_id, situacao, origem, observacao)
  values (v_uid, p_conta_id, 'debito', p_valor_pago_centavos, p_data,
          case when v_obr.origem = 'fatura' then left('Pagamento ' || v_obr.descricao, 200) else v_obr.descricao end,
          v_class, v_cat, 'efetivo', 'manual', nullif(btrim(p_observacao), ''))
  returning * into v_mov;

  insert into public.pagamentos (user_id, obrigacao_id, movimento_id, valor_pago_centavos, juros_centavos,
                                 multa_centavos, desconto_centavos, origem, observacao)
  values (v_uid, v_obr.id, v_mov.id, p_valor_pago_centavos, coalesce(p_juros_centavos, 0),
          coalesce(p_multa_centavos, 0), coalesce(p_desconto_centavos, 0), 'pagamento', nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

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
  v_obr  public.obrigacoes;
  v_mov  public.movimentos;
  v_cls  text;
  v_cat  uuid;
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
  -- ordem das travas: conta a pagar → lançamento
  select * into v_obr from public.obrigacoes where id = p_obrigacao_id and user_id = v_uid for update;
  if not found then
    raise exception 'Conta a pagar não encontrada' using errcode = 'P0002';
  end if;
  select * into v_mov from public.movimentos where id = p_movimento_id and user_id = v_uid for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.pagamentos where obrigacao_id = p_obrigacao_id and movimento_id = p_movimento_id
                                              and user_id = v_uid and situacao = 'ativo') then
    raise exception 'Este lançamento já está vinculado a esta conta a pagar' using errcode = '22023';
  end if;
  -- pagar fatura com um lançamento comum: ele passa a ser "pagamento de
  -- fatura" (as despesas são as compras); a classificação anterior fica
  -- guardada e volta se o vínculo for desfeito
  if v_obr.origem = 'fatura' and v_mov.classificacao <> 'pagamento_fatura' and v_mov.natureza = 'debito'
     and v_mov.situacao = 'efetivo' and v_mov.estorno_de is null then
    v_cls := v_mov.classificacao;
    v_cat := v_mov.categoria_id;
    perform set_config('app.motivo', 'Vinculado ao pagamento de fatura', true);
    update public.movimentos set classificacao = 'pagamento_fatura', categoria_id = null where id = v_mov.id;
    perform set_config('app.motivo', '', true);
  end if;
  insert into public.pagamentos (user_id, obrigacao_id, movimento_id, valor_pago_centavos, juros_centavos,
                                 multa_centavos, desconto_centavos, origem, classificacao_anterior, categoria_anterior)
  values (v_uid, p_obrigacao_id, p_movimento_id, p_valor_pago_centavos, coalesce(p_juros_centavos, 0),
          coalesce(p_multa_centavos, 0), coalesce(p_desconto_centavos, 0), 'vinculo', v_cls, v_cat)
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

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
  v_cat  uuid;
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
  elsif v_reg.classificacao_anterior is not null
        and not exists (select 1 from public.pagamentos where movimento_id = v_reg.movimento_id and situacao = 'ativo') then
    -- vínculo com fatura desfeito: o lançamento volta à classificação que
    -- tinha (sem categoria, se a categoria tiver sido arquivada)
    select id into v_cat from public.categorias where id = v_reg.categoria_anterior and ativa;
    update public.movimentos
       set classificacao = case when v_cat is null then 'nao_classificado' else v_reg.classificacao_anterior end,
           categoria_id = v_cat
     where id = v_reg.movimento_id and user_id = v_uid and classificacao = 'pagamento_fatura';
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- RPCs: cartões
-- =====================================================================
create or replace function public.cartao_criar(
  p_titular_id          uuid,
  p_instituicao_id      uuid,
  p_apelido             text,
  p_final               text,
  p_limite_centavos     bigint,
  p_dia_fechamento      integer,
  p_dia_vencimento      integer,
  p_conta_pagamento_id  uuid,
  p_chave_idempotencia  text
)
returns public.cartoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.cartoes;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'cartao_criar', jsonb_build_object(
    'titular_id', p_titular_id, 'instituicao_id', p_instituicao_id, 'apelido', p_apelido, 'final', p_final,
    'limite', p_limite_centavos, 'fechamento', p_dia_fechamento, 'vencimento', p_dia_vencimento, 'conta', p_conta_pagamento_id));
  if v_prev is not null then return jsonb_populate_record(null::public.cartoes, v_prev); end if;
  perform privado.travar_titular_ativo(p_titular_id, v_uid);
  if exists (select 1 from public.cartoes where user_id = v_uid and lower(btrim(apelido)) = lower(btrim(p_apelido))) then
    raise exception 'Já existe um cartão com este nome' using errcode = '22023';
  end if;
  insert into public.cartoes (user_id, titular_id, instituicao_id, apelido, final, limite_centavos,
                              dia_fechamento, dia_vencimento, conta_pagamento_id)
  values (v_uid, p_titular_id, p_instituicao_id, btrim(p_apelido), nullif(btrim(p_final), ''), p_limite_centavos,
          p_dia_fechamento, p_dia_vencimento, p_conta_pagamento_id)
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Mudar os dias vale para as faturas ainda não criadas; as existentes se
-- ajustam uma a uma em fatura_atualizar.
create or replace function public.cartao_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_titular_id          uuid,
  p_instituicao_id      uuid,
  p_apelido             text,
  p_final               text,
  p_limite_centavos     bigint,
  p_dia_fechamento      integer,
  p_dia_vencimento      integer,
  p_conta_pagamento_id  uuid,
  p_chave_idempotencia  text default null
)
returns public.cartoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.cartoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'cartao_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'titular_id', p_titular_id, 'instituicao_id', p_instituicao_id,
      'apelido', p_apelido, 'final', p_final, 'limite', p_limite_centavos, 'fechamento', p_dia_fechamento,
      'vencimento', p_dia_vencimento, 'conta', p_conta_pagamento_id));
    if v_prev is not null then return jsonb_populate_record(null::public.cartoes, v_prev); end if;
  end if;
  if exists (select 1 from public.cartoes where user_id = v_uid and id <> p_id and lower(btrim(apelido)) = lower(btrim(p_apelido))) then
    raise exception 'Já existe um cartão com este nome' using errcode = '22023';
  end if;
  update public.cartoes set titular_id = p_titular_id, instituicao_id = p_instituicao_id, apelido = btrim(p_apelido),
         final = nullif(btrim(p_final), ''), limite_centavos = p_limite_centavos, dia_fechamento = p_dia_fechamento,
         dia_vencimento = p_dia_vencimento, conta_pagamento_id = p_conta_pagamento_id
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.cartoes', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.cartao_definir_ativo(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_ativo               boolean,
  p_motivo              text,
  p_chave_idempotencia  text default null
)
returns public.cartoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_reg  public.cartoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_ativo is null then
    raise exception 'Informe se o cartão fica ativo' using errcode = '22023';
  end if;
  perform set_config('app.motivo', coalesce(btrim(p_motivo), ''), true);
  update public.cartoes set ativo = p_ativo
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.cartoes', p_id, v_uid); end if;
  perform set_config('app.motivo', '', true);
  return v_reg;
end $$;

-- =====================================================================
-- RPCs: lançamentos do cartão
-- =====================================================================
-- p_tipo: compra | encargo (p_subtipo: juros, iof, tarifa, anuidade, multa, outro) | credito
-- Valor: informe o TOTAL (p_valor_centavos) ou o valor de CADA parcela
-- (p_valor_parcela_centavos); com o total, os centavos que sobram da
-- divisão vão para a 1ª parcela.
-- p_parcela_atual > 1: compra que já vinha sendo paga antes do Simplifica;
-- só são criadas as parcelas a partir dela.
-- p_fatura_competencia: mês de vencimento da fatura da 1ª parcela criada
-- (padrão: pela data da compra; com p_parcela_atual > 1, a fatura de hoje).
create or replace function public.compra_criar(
  p_cartao_id               uuid,
  p_tipo                    text,
  p_subtipo                 text,
  p_data                    date,
  p_descricao               text,
  p_categoria_id            uuid,
  p_valor_centavos          bigint,
  p_parcelas                integer,
  p_valor_parcela_centavos  bigint,
  p_parcela_atual           integer,
  p_fatura_competencia      date,
  p_observacao              text,
  p_chave_idempotencia      text
)
returns public.compras
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := privado.uid_para_escrita();
  v_prev    jsonb;
  v_c       public.cartoes;
  v_reg     public.compras;
  v_n       integer := coalesce(p_parcelas, 1);
  v_atual   integer := coalesce(p_parcela_atual, 1);
  v_total   bigint;
  v_base    bigint;
  v_resto   bigint;
  v_comp    date;
  v_i       integer;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_criar', jsonb_build_object(
    'cartao_id', p_cartao_id, 'tipo', p_tipo, 'subtipo', p_subtipo, 'data', p_data, 'descricao', p_descricao,
    'categoria_id', p_categoria_id, 'valor', p_valor_centavos, 'parcelas', p_parcelas, 'valor_parcela', p_valor_parcela_centavos,
    'parcela_atual', p_parcela_atual, 'fatura', p_fatura_competencia, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.compras, v_prev); end if;

  if p_tipo is null or p_tipo not in ('compra', 'encargo', 'credito') then
    raise exception 'Tipo deve ser compra, encargo ou crédito (estorno tem função própria)' using errcode = '22023';
  end if;
  if p_data is null then
    raise exception 'Informe a data' using errcode = '22023';
  end if;
  if p_data > privado.hoje() then
    raise exception 'A data não pode ser futura' using errcode = '22023';
  end if;
  if v_n < 1 or v_n > 99 or v_atual < 1 or v_atual > v_n then
    raise exception 'Parcelas: de 1 a 99, e a parcela atual entre 1 e o total' using errcode = '22023';
  end if;
  if p_tipo <> 'compra' and v_n > 1 then
    raise exception 'Só compras podem ser parceladas' using errcode = '22023';
  end if;
  if p_valor_parcela_centavos is not null then
    if p_valor_parcela_centavos <= 0 then
      raise exception 'Informe o valor da parcela, maior que zero' using errcode = '22023';
    end if;
    v_total := p_valor_parcela_centavos * v_n;
    if p_valor_centavos is not null and p_valor_centavos <> v_total then
      raise exception 'Informe o valor total OU o valor da parcela' using errcode = '22023';
    end if;
  else
    v_total := p_valor_centavos;
    if v_total is null or v_total <= 0 then
      raise exception 'Informe o valor, maior que zero' using errcode = '22023';
    end if;
    if v_total < v_n then
      raise exception 'Valor menor que o número de parcelas' using errcode = '22023';
    end if;
  end if;
  select * into v_c from public.cartoes where id = p_cartao_id and user_id = v_uid for share;
  if not found then
    raise exception 'Cartão não encontrado' using errcode = 'P0002';
  end if;
  v_comp := date_trunc('month', coalesce(p_fatura_competencia,
              case when v_atual = 1 then privado.fatura_competencia(p_data, v_c.dia_fechamento, v_c.dia_vencimento)
                   else privado.fatura_competencia(privado.hoje(), v_c.dia_fechamento, v_c.dia_vencimento) end))::date;
  if v_comp < date_trunc('month', p_data)::date then
    raise exception 'A fatura não pode vencer antes da data da compra' using errcode = '22023';
  end if;
  if v_comp > (date_trunc('month', privado.hoje()) + interval '24 months')::date then
    raise exception 'Fatura muito distante' using errcode = '22023';
  end if;

  insert into public.compras (user_id, cartao_id, tipo, subtipo, data_compra, descricao, categoria_id, valor_total_centavos,
                              parcelas_total, parcela_inicial, observacao)
  values (v_uid, v_c.id, p_tipo, case when p_tipo = 'encargo' then p_subtipo end, p_data, btrim(p_descricao), p_categoria_id,
          v_total, v_n, v_atual, nullif(btrim(p_observacao), ''))
  returning * into v_reg;

  v_base  := v_total / v_n;
  v_resto := v_total - v_base * v_n;
  for v_i in v_atual .. v_n loop
    insert into public.parcelas (user_id, compra_id, cartao_id, numero, natureza, valor_centavos, fatura_id)
    values (v_uid, v_reg.id, v_c.id, v_i, v_reg.natureza,
            coalesce(p_valor_parcela_centavos, v_base + case when v_i = 1 then v_resto else 0 end),
            privado.fatura_obter(v_c.id, (v_comp + make_interval(months => v_i - v_atual))::date));
  end loop;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.compra_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_descricao           text,
  p_categoria_id        uuid,
  p_observacao          text,
  p_chave_idempotencia  text default null
)
returns public.compras
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.compras;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'descricao', p_descricao, 'categoria_id', p_categoria_id, 'observacao', p_observacao));
    if v_prev is not null then return jsonb_populate_record(null::public.compras, v_prev); end if;
  end if;
  update public.compras set descricao = btrim(p_descricao), categoria_id = p_categoria_id, observacao = nullif(btrim(p_observacao), '')
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'ativa'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.compras where id = p_id and user_id = v_uid and situacao = 'cancelada') then
      raise exception 'Lançamento cancelado não pode ser alterado' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.compras', p_id, v_uid);
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Cancelar:
--   p_incluir_cobradas = true  → "lancei errado": cancela todas as parcelas;
--   p_incluir_cobradas = false → "compra cancelada na loja": cancela só as
--     parcelas de faturas que ainda não fecharam; as já cobradas ficam
--     (o banco devolve com um estorno, lançado à parte).
create or replace function public.compra_cancelar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_motivo              text,
  p_incluir_cobradas    boolean,
  p_chave_idempotencia  text default null
)
returns public.compras
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_reg   public.compras;
  v_p     record;
  v_n     integer := 0;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do cancelamento' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_cancelar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo, 'todas', p_incluir_cobradas));
    if v_prev is not null then return jsonb_populate_record(null::public.compras, v_prev); end if;
  end if;
  select * into v_reg from public.compras where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;
  if v_reg.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.compras', p_id, v_uid);
  end if;
  if v_reg.situacao = 'cancelada' then
    raise exception 'Lançamento já está cancelado' using errcode = '22023';
  end if;
  if coalesce(p_incluir_cobradas, false)
     and exists (select 1 from public.compras where estorno_de = v_reg.id and situacao = 'ativa') then
    raise exception 'Esta compra tem estornos. Cancele os estornos antes de remover a compra inteira.' using errcode = '22023';
  end if;
  perform set_config('app.motivo', btrim(p_motivo), true);
  -- trava as faturas na ordem de vencimento (mesma ordem da criação)
  perform 1 from public.faturas f
   where f.id in (select fatura_id from public.parcelas where compra_id = v_reg.id and situacao = 'ativa')
   order by f.competencia, f.id
     for update;
  for v_p in
    select p.id from public.parcelas p join public.faturas f on f.id = p.fatura_id
     where p.compra_id = v_reg.id and p.situacao = 'ativa'
       and (coalesce(p_incluir_cobradas, false) or f.fechamento > privado.hoje())
     order by f.competencia, p.numero
  loop
    update public.parcelas set situacao = 'cancelada', cancelada_motivo = btrim(p_motivo) where id = v_p.id;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    raise exception 'Todas as parcelas já foram cobradas. Para a devolução, lance um estorno; se lançou errado, escolha remover tudo.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.parcelas where compra_id = v_reg.id and situacao = 'ativa') then
    update public.compras set situacao = 'cancelada', cancelada_motivo = btrim(p_motivo), cancelada_em = now()
     where id = v_reg.id returning * into v_reg;
  else
    update public.compras set observacao = left(coalesce(observacao || ' · ', '') || 'Parcelas futuras canceladas: ' || btrim(p_motivo), 500)
     where id = v_reg.id returning * into v_reg;
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Estorno: crédito ligado à compra, na mesma categoria. A soma dos
-- estornos ativos nunca passa do valor ativo da compra.
create or replace function public.compra_estornar(
  p_compra_id           uuid,
  p_valor_centavos      bigint,
  p_data                date,
  p_fatura_competencia  date,
  p_motivo              text,
  p_chave_idempotencia  text
)
returns public.compras
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_pai   public.compras;
  v_c     public.cartoes;
  v_reg   public.compras;
  v_ativo bigint;
  v_ja    bigint;
  v_comp  date;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_estornar', jsonb_build_object(
    'compra_id', p_compra_id, 'valor', p_valor_centavos, 'data', p_data, 'fatura', p_fatura_competencia, 'motivo', p_motivo));
  if v_prev is not null then return jsonb_populate_record(null::public.compras, v_prev); end if;
  if p_valor_centavos is null or p_valor_centavos <= 0 then
    raise exception 'Informe o valor estornado, maior que zero' using errcode = '22023';
  end if;
  if p_data is null or p_data > privado.hoje() then
    raise exception 'Informe a data do estorno (hoje ou antes)' using errcode = '22023';
  end if;
  select * into v_pai from public.compras where id = p_compra_id and user_id = v_uid for update;
  if not found then
    raise exception 'Compra não encontrada' using errcode = 'P0002';
  end if;
  if v_pai.tipo not in ('compra', 'encargo') or v_pai.situacao <> 'ativa' then
    raise exception 'Só compras e encargos ativos podem ser estornados' using errcode = '22023';
  end if;
  if p_data < v_pai.data_compra then
    raise exception 'O estorno não pode ser anterior à compra' using errcode = '22023';
  end if;
  select coalesce(sum(valor_centavos - desconto_centavos), 0) into v_ativo
    from public.parcelas where compra_id = v_pai.id and situacao = 'ativa';
  select coalesce(sum(valor_total_centavos), 0) into v_ja
    from public.compras where estorno_de = v_pai.id and situacao = 'ativa';
  if v_ja + p_valor_centavos > v_ativo then
    raise exception 'O estorno passa do valor da compra (restam % para estornar)', privado.reais(greatest(v_ativo - v_ja, 0))
      using errcode = '22023';
  end if;
  select * into v_c from public.cartoes where id = v_pai.cartao_id;
  v_comp := date_trunc('month', coalesce(p_fatura_competencia,
              privado.fatura_competencia(p_data, v_c.dia_fechamento, v_c.dia_vencimento)))::date;
  perform set_config('app.motivo', coalesce(btrim(p_motivo), ''), true);
  insert into public.compras (user_id, cartao_id, tipo, data_compra, descricao, categoria_id, valor_total_centavos, estorno_de, observacao)
  values (v_uid, v_c.id, 'estorno', p_data, left('Estorno: ' || v_pai.descricao, 200),
          (select id from public.categorias where id = v_pai.categoria_id and ativa), p_valor_centavos, v_pai.id,
          nullif(btrim(p_motivo), ''))
  returning * into v_reg;
  insert into public.parcelas (user_id, compra_id, cartao_id, numero, natureza, valor_centavos, fatura_id)
  values (v_uid, v_reg.id, v_c.id, 1, 'credito', p_valor_centavos, privado.fatura_obter(v_c.id, v_comp));
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Antecipar parcelas: levam-se as parcelas escolhidas para a fatura de
-- destino (padrão: a fatura aberta hoje), com desconto opcional dividido
-- entre elas. A fatura original fica guardada; as faturas futuras perdem
-- o valor (e a conta a pagar delas acompanha).
create or replace function public.compra_antecipar(
  p_compra_id           uuid,
  p_numeros             integer[],
  p_fatura_competencia  date,
  p_desconto_centavos   bigint,
  p_chave_idempotencia  text
)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := privado.uid_para_escrita();
  v_prev    jsonb;
  v_pai     public.compras;
  v_c       public.cartoes;
  v_comp    date;
  v_dest    uuid;
  v_fdest   public.faturas;
  v_soma    bigint;
  v_qtd     integer;
  v_desc    bigint := coalesce(p_desconto_centavos, 0);
  v_usado   bigint := 0;
  v_p       record;
  v_i       integer := 0;
  v_d       bigint;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_antecipar', jsonb_build_object(
    'compra_id', p_compra_id, 'numeros', p_numeros, 'fatura', p_fatura_competencia, 'desconto', p_desconto_centavos));
  if v_prev is not null then return (v_prev #>> '{}')::integer; end if;
  if p_numeros is null or cardinality(p_numeros) = 0 then
    raise exception 'Escolha as parcelas a antecipar' using errcode = '22023';
  end if;
  if v_desc < 0 then
    raise exception 'Desconto não pode ser negativo' using errcode = '22023';
  end if;
  select * into v_pai from public.compras where id = p_compra_id and user_id = v_uid for update;
  if not found then
    raise exception 'Compra não encontrada' using errcode = 'P0002';
  end if;
  if v_pai.tipo <> 'compra' or v_pai.situacao <> 'ativa' then
    raise exception 'Só compras ativas têm parcelas para antecipar' using errcode = '22023';
  end if;
  select * into v_c from public.cartoes where id = v_pai.cartao_id;
  v_comp := date_trunc('month', coalesce(p_fatura_competencia,
              privado.fatura_competencia(privado.hoje(), v_c.dia_fechamento, v_c.dia_vencimento)))::date;
  v_dest := privado.fatura_obter(v_c.id, v_comp);
  -- trava todas as faturas envolvidas, na ordem de vencimento
  perform 1 from public.faturas f
   where f.id = v_dest or f.id in (select fatura_id from public.parcelas where compra_id = v_pai.id and numero = any (p_numeros))
   order by f.competencia, f.id
     for update;
  select * into v_fdest from public.faturas where id = v_dest;
  if v_fdest.fechamento <= privado.hoje() then
    raise exception 'A fatura de destino já fechou; escolha a fatura aberta' using errcode = '22023';
  end if;
  select count(*), coalesce(sum(p.valor_centavos), 0) into v_qtd, v_soma
    from public.parcelas p join public.faturas f on f.id = p.fatura_id
   where p.compra_id = v_pai.id and p.numero = any (p_numeros) and p.situacao = 'ativa'
     and p.antecipada_em is null and f.competencia > v_comp;
  if v_qtd <> (select count(distinct x) from unnest(p_numeros) x) then
    raise exception 'Só dá para antecipar parcelas ativas, ainda não antecipadas, de faturas depois da fatura de destino' using errcode = '22023';
  end if;
  if v_desc >= v_soma then
    raise exception 'O desconto precisa ser menor que o valor antecipado (%)', privado.reais(v_soma) using errcode = '22023';
  end if;
  perform set_config('app.motivo', 'Antecipação de parcelas', true);
  for v_p in
    select p.id, p.valor_centavos from public.parcelas p
     where p.compra_id = v_pai.id and p.numero = any (p_numeros) order by p.numero
  loop
    v_i := v_i + 1;
    v_d := case when v_i = v_qtd then v_desc - v_usado else (v_desc * v_p.valor_centavos) / v_soma end;
    v_usado := v_usado + v_d;
    update public.parcelas set fatura_original_id = fatura_id, fatura_id = v_dest, antecipada_em = now(), desconto_centavos = v_d
     where id = v_p.id;
  end loop;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_qtd));
  return v_qtd;
end $$;

-- Desfazer antecipação (erro de lançamento): só enquanto a fatura de
-- destino não fechou. As parcelas voltam às faturas originais, sem desconto.
create or replace function public.antecipacao_desfazer(
  p_compra_id           uuid,
  p_numeros             integer[],
  p_motivo              text
)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_pai   public.compras;
  v_n     integer := 0;
  v_p     record;
begin
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo' using errcode = '22023';
  end if;
  select * into v_pai from public.compras where id = p_compra_id and user_id = v_uid for update;
  if not found then
    raise exception 'Compra não encontrada' using errcode = 'P0002';
  end if;
  perform 1 from public.faturas f
   where f.id in (select fatura_id from public.parcelas where compra_id = v_pai.id and numero = any (p_numeros)
                  union select fatura_original_id from public.parcelas where compra_id = v_pai.id and numero = any (p_numeros))
   order by f.competencia, f.id
     for update;
  perform set_config('app.motivo', btrim(p_motivo), true);
  for v_p in
    select p.id, f.fechamento from public.parcelas p join public.faturas f on f.id = p.fatura_id
     where p.compra_id = v_pai.id and p.numero = any (p_numeros) and p.antecipada_em is not null and p.situacao = 'ativa'
     order by p.numero
  loop
    if v_p.fechamento <= privado.hoje() then
      raise exception 'A fatura da antecipação já fechou; a antecipação não pode mais ser desfeita' using errcode = '22023';
    end if;
    update public.parcelas set fatura_id = fatura_original_id, fatura_original_id = null, antecipada_em = null, desconto_centavos = 0
     where id = v_p.id;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    raise exception 'Nenhuma parcela antecipada entre as escolhidas' using errcode = '22023';
  end if;
  perform set_config('app.motivo', '', true);
  return v_n;
end $$;

-- Datas de uma fatura (o banco às vezes muda por feriado) e o total
-- informado pelo banco, só para conferência (não altera nada).
create or replace function public.fatura_atualizar(
  p_id                        uuid,
  p_versao_esperada           integer,
  p_fechamento                date,
  p_vencimento                date,
  p_total_informado_centavos  bigint,
  p_chave_idempotencia        text default null
)
returns public.faturas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.faturas;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'fatura_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'fechamento', p_fechamento, 'vencimento', p_vencimento, 'informado', p_total_informado_centavos));
    if v_prev is not null then return jsonb_populate_record(null::public.faturas, v_prev); end if;
  end if;
  if p_fechamento is null or p_vencimento is null or p_fechamento >= p_vencimento then
    raise exception 'O fechamento precisa ser antes do vencimento' using errcode = '22023';
  end if;
  update public.faturas set fechamento = p_fechamento, vencimento = p_vencimento, total_informado_centavos = p_total_informado_centavos
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.faturas', p_id, v_uid); end if;
  if date_trunc('month', p_vencimento)::date <> v_reg.competencia then
    raise exception 'O vencimento precisa continuar no mês da fatura (%)', to_char(v_reg.competencia, 'MM/YYYY') using errcode = '22023';
  end if;
  perform privado.fatura_sincronizar(v_reg.id);
  select * into v_reg from public.faturas where id = p_id;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- CONSULTAS (somente leitura, sob RLS do próprio usuário)
-- =====================================================================
-- Faturas de um cartão num intervalo de competências, com totais.
-- situacao: aberta | fechada | vencida | paga | sem_saldo
create or replace function public.faturas_do_cartao(p_cartao_id uuid, p_de date, p_ate date)
returns table (
  fatura_id                 uuid,
  competencia               date,
  fechamento                date,
  vencimento                date,
  total_centavos            bigint,
  debitos_centavos          bigint,
  creditos_centavos         bigint,
  total_informado_centavos  bigint,
  diferenca_centavos        bigint,
  pago_centavos             bigint,
  restante_centavos         bigint,
  lancamentos               integer,
  obrigacao_id              uuid,
  situacao                  text,
  versao                    integer
)
language sql stable security invoker
set search_path = ''
as $$
  with f as (
    select fa.*,
           coalesce((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = fa.id and p.situacao = 'ativa'), 0)::bigint as total,
           coalesce((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = fa.id and p.situacao = 'ativa' and p.natureza = 'debito'), 0)::bigint as deb,
           coalesce((select -sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = fa.id and p.situacao = 'ativa' and p.natureza = 'credito'), 0)::bigint as cred,
           (select count(*) from public.parcelas p where p.fatura_id = fa.id and p.situacao = 'ativa')::int as n,
           coalesce((select sum(pg.abatido_centavos) from public.pagamentos pg where pg.obrigacao_id = fa.obrigacao_id and pg.situacao = 'ativo'), 0)::bigint as pago
      from public.faturas fa
     where fa.user_id = auth.uid() and fa.cartao_id = p_cartao_id
       and fa.competencia between date_trunc('month', p_de)::date and date_trunc('month', p_ate)::date
  )
  select f.id, f.competencia, f.fechamento, f.vencimento, f.total, f.deb, f.cred,
         f.total_informado_centavos, f.total_informado_centavos - f.total,
         f.pago, greatest(f.total - f.pago, 0), f.n, f.obrigacao_id,
         case when f.total > 0 and f.pago >= f.total then 'paga'
              when privado.hoje() < f.fechamento then 'aberta'
              when f.total <= 0 then 'sem_saldo'
              when privado.hoje() > f.vencimento then 'vencida'
              else 'fechada' end,
         f.versao
    from f
   order by f.competencia;
$$;

-- Lançamentos de uma fatura no formato DATA | DESCRIÇÃO | PARCELA | VALOR,
-- mais os dados internos (valor: débito positivo, crédito negativo).
-- status da parcela: a_cobrar | cobrada | quitada | cancelada
create or replace function public.lancamentos_da_fatura(p_fatura_id uuid)
returns table (
  parcela_id                  uuid,
  compra_id                   uuid,
  tipo                        text,
  subtipo                     text,
  data                        date,
  descricao                   text,
  parcela                     text,
  numero                      integer,
  parcelas_total              integer,
  valor_centavos              bigint,
  desconto_centavos           bigint,
  categoria_id                uuid,
  categoria                   text,
  antecipada                  boolean,
  fatura_original_competencia date,
  estorno_de                  uuid,
  status                      text,
  compra_versao               integer
)
language sql stable security invoker
set search_path = ''
as $$
  with fa as (
    select f.*, coalesce((select sum(pg.abatido_centavos) from public.pagamentos pg where pg.obrigacao_id = f.obrigacao_id and pg.situacao = 'ativo'), 0) as pago,
           coalesce((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa'), 0) as total
      from public.faturas f where f.id = p_fatura_id and f.user_id = auth.uid()
  )
  select p.id, c.id, c.tipo, c.subtipo, c.data_compra, c.descricao,
         case when c.parcelas_total > 1 then p.numero || '/' || c.parcelas_total end,
         p.numero, c.parcelas_total, p.valor_assinado_centavos, p.desconto_centavos, c.categoria_id, cat.nome,
         p.antecipada_em is not null, fo.competencia, c.estorno_de,
         case when p.situacao = 'cancelada' then 'cancelada'
              when fa.total > 0 and fa.pago >= fa.total then 'quitada'
              when privado.hoje() >= fa.fechamento then 'cobrada'
              else 'a_cobrar' end,
         c.versao
    from fa
    join public.parcelas p on p.fatura_id = fa.id
    join public.compras c on c.id = p.compra_id
    left join public.categorias cat on cat.id = c.categoria_id
    left join public.faturas fo on fo.id = p.fatura_original_id
   order by (p.situacao = 'cancelada'), c.data_compra, c.criado_em, p.numero;
$$;

-- Parcelas de uma compra (histórico, antecipação)
create or replace function public.parcelas_da_compra(p_compra_id uuid)
returns table (
  parcela_id                  uuid,
  numero                      integer,
  valor_centavos              bigint,
  desconto_centavos           bigint,
  fatura_id                   uuid,
  competencia                 date,
  fechamento                  date,
  vencimento                  date,
  antecipada                  boolean,
  fatura_original_competencia date,
  situacao                    text,
  status                      text
)
language sql stable security invoker
set search_path = ''
as $$
  select p.id, p.numero, p.valor_centavos, p.desconto_centavos, f.id, f.competencia, f.fechamento, f.vencimento,
         p.antecipada_em is not null, fo.competencia, p.situacao,
         case when p.situacao = 'cancelada' then 'cancelada'
              when tot.total > 0 and coalesce(pg.pago, 0) >= tot.total then 'quitada'
              when privado.hoje() >= f.fechamento then 'cobrada'
              else 'a_cobrar' end
    from public.parcelas p
    join public.faturas f on f.id = p.fatura_id
    left join public.faturas fo on fo.id = p.fatura_original_id
    cross join lateral (select coalesce(sum(x.valor_assinado_centavos), 0) as total from public.parcelas x where x.fatura_id = f.id and x.situacao = 'ativa') tot
    left join lateral (select sum(pp.abatido_centavos) as pago from public.pagamentos pp where pp.obrigacao_id = f.obrigacao_id and pp.situacao = 'ativo') pg on true
   where p.user_id = auth.uid() and p.compra_id = p_compra_id
   order by p.numero;
$$;

-- Resumo dos cartões: limite usado (tudo o que ainda não foi pago, inclusive
-- parcelas futuras), disponível e a fatura aberta hoje.
create or replace function public.cartoes_resumo()
returns table (
  cartao_id                 uuid,
  apelido                   text,
  instituicao               text,
  titular                   text,
  final                     text,
  ativo                     boolean,
  limite_centavos           bigint,
  usado_centavos            bigint,
  disponivel_centavos       bigint,
  dia_fechamento            integer,
  dia_vencimento            integer,
  conta_pagamento_id        uuid,
  fatura_atual_competencia  date,
  fatura_atual_total        bigint,
  fatura_atual_fechamento   date,
  fatura_atual_vencimento   date,
  a_pagar_vencidas_centavos bigint,
  versao                    integer
)
language sql stable security invoker
set search_path = ''
as $$
  with fat as (
    select f.cartao_id, f.competencia, f.fechamento, f.vencimento,
           coalesce((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa'), 0) as total,
           coalesce((select sum(pg.abatido_centavos) from public.pagamentos pg where pg.obrigacao_id = f.obrigacao_id and pg.situacao = 'ativo'), 0) as pago
      from public.faturas f where f.user_id = auth.uid()
  )
  select c.id, c.apelido, i.nome, t.nome, c.final, c.ativo, c.limite_centavos,
         coalesce((select sum(greatest(fat.total - fat.pago, 0)) from fat where fat.cartao_id = c.id), 0)::bigint,
         case when c.limite_centavos is not null
              then c.limite_centavos - coalesce((select sum(greatest(fat.total - fat.pago, 0)) from fat where fat.cartao_id = c.id), 0)::bigint end,
         c.dia_fechamento, c.dia_vencimento, c.conta_pagamento_id,
         privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento),
         coalesce((select fat.total from fat where fat.cartao_id = c.id
                    and fat.competencia = privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento)), 0)::bigint,
         coalesce((select fat.fechamento from fat where fat.cartao_id = c.id
                    and fat.competencia = privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento)),
                  privado.fatura_fechamento(privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento), c.dia_fechamento, c.dia_vencimento)),
         coalesce((select fat.vencimento from fat where fat.cartao_id = c.id
                    and fat.competencia = privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento)),
                  privado.vencimento_no_mes(privado.fatura_competencia(privado.hoje(), c.dia_fechamento, c.dia_vencimento), c.dia_vencimento)),
         coalesce((select sum(greatest(fat.total - fat.pago, 0)) from fat where fat.cartao_id = c.id and fat.vencimento < privado.hoje()), 0)::bigint,
         c.versao
    from public.cartoes c
    join public.instituicoes i on i.id = c.instituicao_id
    join public.titulares t on t.id = c.titular_id
   where c.user_id = auth.uid()
   order by c.ativo desc, c.apelido;
$$;

-- Em que fatura cai uma compra (prévia na tela)
create or replace function public.fatura_prevista(p_cartao_id uuid, p_data date)
returns table (competencia date, fechamento date, vencimento date, fechada boolean)
language sql stable security invoker
set search_path = ''
as $$
  with c as (select * from public.cartoes where id = p_cartao_id and user_id = auth.uid()),
  k as (select privado.fatura_competencia(p_data, c.dia_fechamento, c.dia_vencimento) as comp, c.* from c)
  select k.comp,
         coalesce(f.fechamento, privado.fatura_fechamento(k.comp, k.dia_fechamento, k.dia_vencimento)),
         coalesce(f.vencimento, privado.vencimento_no_mes(k.comp, k.dia_vencimento)),
         coalesce(f.fechamento, privado.fatura_fechamento(k.comp, k.dia_fechamento, k.dia_vencimento)) <= privado.hoje()
    from k left join public.faturas f on f.cartao_id = k.id and f.competencia = k.comp;
$$;

-- Receitas e despesas por categoria (substitui a da 0004):
--   lançamentos da conta efetivos (sem "pagamento de fatura") pela data;
--   lançamentos do cartão pelo VENCIMENTO da fatura em que caem.
-- Com p_conta_id, só a conta bancária (sem cartões).
create or replace function public.resumo_categorias(p_inicio date, p_fim date, p_conta_id uuid default null)
returns table (
  classificacao   text,
  categoria_id    uuid,
  categoria       text,
  movimentos      integer,
  total_centavos  bigint
)
language sql stable security invoker
set search_path = ''
as $$
  with itens as (
    select m.classificacao, m.categoria_id,
           case when m.classificacao = 'despesa' then -m.valor_assinado_centavos else m.valor_assinado_centavos end as valor
      from public.movimentos m
     where m.user_id = auth.uid() and m.situacao = 'efetivo' and m.classificacao <> 'pagamento_fatura'
       and m.data_movimento between p_inicio and p_fim
       and (p_conta_id is null or m.conta_id = p_conta_id)
    union all
    select case when c.categoria_id is null then 'nao_classificado' else 'despesa' end, c.categoria_id,
           case when c.categoria_id is null then -p.valor_assinado_centavos else p.valor_assinado_centavos end
      from public.parcelas p
      join public.compras c on c.id = p.compra_id
      join public.faturas f on f.id = p.fatura_id
     where p.user_id = auth.uid() and p.situacao = 'ativa' and p_conta_id is null
       and f.vencimento between p_inicio and p_fim
  )
  select i.classificacao, i.categoria_id, coalesce(cat.nome, 'Não classificado'), count(*)::int, sum(i.valor)::bigint
    from itens i
    left join public.categorias cat on cat.id = i.categoria_id
   group by i.classificacao, i.categoria_id, cat.nome
   order by i.classificacao desc, 5 desc;
$$;

-- =====================================================================
-- LGPD: exportação e exclusão incluem cartões, faturas, compras e parcelas
-- =====================================================================
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := privado.uid_obrigatorio();
begin
  return jsonb_build_object(
    'gerado_em',      now(),
    'perfil',         (select to_jsonb(p) from public.perfis p where p.id = v_uid),
    'titulares',      coalesce((select jsonb_agg(t order by t.criado_em) from public.titulares t where t.user_id = v_uid), '[]'),
    'contas',         coalesce((select jsonb_agg(c order by c.criado_em) from public.contas c where c.user_id = v_uid), '[]'),
    'categorias',     coalesce((select jsonb_agg(c order by c.criado_em) from public.categorias c where c.user_id = v_uid), '[]'),
    'movimentos',     coalesce((select jsonb_agg(m order by m.data_movimento, m.criado_em) from public.movimentos m where m.user_id = v_uid), '[]'),
    'recorrencias',   coalesce((select jsonb_agg(r order by r.criado_em) from public.recorrencias r where r.user_id = v_uid), '[]'),
    'contas_a_pagar', coalesce((select jsonb_agg(o order by o.vencimento, o.criado_em) from public.obrigacoes o where o.user_id = v_uid), '[]'),
    'pagamentos',     coalesce((select jsonb_agg(p order by p.criado_em) from public.pagamentos p where p.user_id = v_uid), '[]'),
    'cartoes',        coalesce((select jsonb_agg(c order by c.criado_em) from public.cartoes c where c.user_id = v_uid), '[]'),
    'faturas',        coalesce((select jsonb_agg(f order by f.cartao_id, f.competencia) from public.faturas f where f.user_id = v_uid), '[]'),
    'compras_cartao', coalesce((select jsonb_agg(c order by c.data_compra, c.criado_em) from public.compras c where c.user_id = v_uid), '[]'),
    'parcelas',       coalesce((select jsonb_agg(p order by p.compra_id, p.numero) from public.parcelas p where p.user_id = v_uid), '[]'),
    'documentos',     coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                                  from storage.objects o
                                 where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'),
    'auditoria',      coalesce((select jsonb_agg(a order by a.id) from public.auditoria a where a.user_id = v_uid), '[]')
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
  delete from public.parcelas            where user_id = p_user_id;
  delete from public.compras             where user_id = p_user_id;
  delete from public.faturas             where user_id = p_user_id;
  delete from public.obrigacoes          where user_id = p_user_id;
  delete from public.recorrencias        where user_id = p_user_id;
  delete from public.movimentos          where user_id = p_user_id;
  delete from public.cartoes             where user_id = p_user_id;
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
            where (n.nspname = 'privado' and p.proname in ('fatura_competencia', 'fatura_fechamento', 'cartao_validar',
                     'titular_arquivar_sem_cartoes_ativos', 'compra_validar', 'parcela_validar', 'fatura_obter', 'fatura_sincronizar',
                     'parcela_sincronizar', 'pagamento_validar_fatura'))
               or (n.nspname = 'public' and p.proname in ('cartao_criar', 'cartao_atualizar', 'cartao_definir_ativo', 'compra_criar',
                     'compra_atualizar', 'compra_cancelar', 'compra_estornar', 'compra_antecipar', 'antecipacao_desfazer',
                     'fatura_atualizar', 'faturas_do_cartao', 'lancamentos_da_fatura', 'parcelas_da_compra', 'cartoes_resumo',
                     'fatura_prevista'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.assinatura);
  end loop;
end $$;

-- funções puras de data usadas dentro das consultas (avaliadas como o usuário)
grant execute on function privado.vencimento_no_mes(date, integer) to authenticated;
grant execute on function privado.fatura_competencia(date, integer, integer) to authenticated;
grant execute on function privado.fatura_fechamento(date, integer, integer) to authenticated;

grant execute on function public.cartao_criar(uuid, uuid, text, text, bigint, integer, integer, uuid, text) to authenticated;
grant execute on function public.cartao_atualizar(uuid, integer, uuid, uuid, text, text, bigint, integer, integer, uuid, text) to authenticated;
grant execute on function public.cartao_definir_ativo(uuid, integer, boolean, text, text) to authenticated;
grant execute on function public.compra_criar(uuid, text, text, date, text, uuid, bigint, integer, bigint, integer, date, text, text) to authenticated;
grant execute on function public.compra_atualizar(uuid, integer, text, uuid, text, text) to authenticated;
grant execute on function public.compra_cancelar(uuid, integer, text, boolean, text) to authenticated;
grant execute on function public.compra_estornar(uuid, bigint, date, date, text, text) to authenticated;
grant execute on function public.compra_antecipar(uuid, integer[], date, bigint, text) to authenticated;
grant execute on function public.antecipacao_desfazer(uuid, integer[], text) to authenticated;
grant execute on function public.fatura_atualizar(uuid, integer, date, date, bigint, text) to authenticated;
grant execute on function public.faturas_do_cartao(uuid, date, date) to authenticated;
grant execute on function public.lancamentos_da_fatura(uuid) to authenticated;
grant execute on function public.parcelas_da_compra(uuid) to authenticated;
grant execute on function public.cartoes_resumo() to authenticated;
grant execute on function public.fatura_prevista(uuid, date) to authenticated;

update public.versao_esquema set etapa = '4-cartoes', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
