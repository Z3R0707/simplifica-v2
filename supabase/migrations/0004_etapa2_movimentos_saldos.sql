-- =====================================================================
-- Simplifica Finanças v2 — 0004 Etapa 2: movimentos, receitas, despesas
-- e painel de saldos por conta.
--
-- Migração ADICIONAL: roda sobre a fundação homologada (0001–0003,
-- revisão 3). Não apaga nem recria nada; só acrescenta tabelas e funções
-- e substitui (create or replace) a exportação LGPD e a conclusão da
-- exclusão de conta, que passam a incluir os movimentos.
-- Tudo numa única transação: se algo falhar, nada é alterado.
--
-- REGRA DO SALDO (data-base)
--   O saldo inicial de cada conta é o saldo AO FINAL do dia da data-base
--   (contas.saldo_inicial_data), como aparece no extrato daquele dia.
--   Saldo confirmado numa data D (D >= data-base):
--       saldo inicial validado
--     + soma dos movimentos EFETIVOS com data > data-base e data <= D
--   Movimentos com data <= data-base continuam registrados (histórico,
--   relatórios por categoria), mas NÃO entram no saldo, porque já estão
--   dentro do saldo inicial. Assim nada é contado duas vezes.
--   Se o saldo inicial não estiver validado, o saldo confirmado não é
--   exibido (fica pendente) e a conta não entra no consolidado.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '1-fundacao-rev3') then
    raise exception 'ABORTADO: este banco não está na Etapa 1 (revisão 3) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- "Hoje" no fuso de Brasília (o servidor do Supabase trabalha em UTC)
create or replace function privado.hoje()
returns date
language sql stable
set search_path = ''
as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- ---------------------------------------------------------------------
-- Movimentos bancários (o que efetivamente aconteceu, ou está previsto,
-- numa conta). Somente movimentos EFETIVOS alteram o saldo confirmado.
-- Nada é apagado: cancelamento muda a situação e fica auditado.
-- ---------------------------------------------------------------------
create table public.movimentos (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references auth.users (id) on delete cascade,
  conta_id                 uuid not null,
  natureza                 text not null check (natureza in ('credito', 'debito')),
  valor_centavos           bigint not null check (valor_centavos > 0 and valor_centavos <= 10000000000000),
  valor_assinado_centavos  bigint generated always as (case when natureza = 'credito' then valor_centavos else -valor_centavos end) stored,
  data_movimento           date not null,
  descricao                text not null check (length(btrim(descricao)) between 1 and 200),
  classificacao            text not null check (classificacao in ('receita', 'despesa', 'nao_classificado')),
  categoria_id             uuid,
  situacao                 text not null default 'efetivo' check (situacao in ('efetivo', 'previsto', 'cancelado')),
  origem                   text not null default 'manual' check (origem in ('manual', 'importacao', 'whatsapp', 'sistema')),
  observacao               text check (length(observacao) <= 500),
  cancelado_motivo         text,
  cancelado_em             timestamptz,
  criado_em                timestamptz not null default now(),
  atualizado_em            timestamptz not null default now(),
  versao                   integer not null default 1,
  unique (id, user_id),
  foreign key (conta_id, user_id) references public.contas (id, user_id),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  check ((classificacao = 'nao_classificado') = (categoria_id is null)),
  check ((situacao = 'cancelado') = (cancelado_em is not null))
);
create index movimentos_conta_data_idx on public.movimentos (user_id, conta_id, data_movimento) where situacao <> 'cancelado';
create index movimentos_categoria_idx on public.movimentos (user_id, categoria_id, data_movimento) where situacao = 'efetivo';
alter table public.movimentos enable row level security;
create policy movimentos_select on public.movimentos for select to authenticated using (user_id = auth.uid());
grant select on public.movimentos to authenticated;
select privado.aplicar_gatilhos_padrao('public.movimentos');

-- Regras de integridade garantidas no banco (valem para qualquer caminho):
--  * movimento (exceto cancelamento) exige conta ATIVA, travada em FOR SHARE
--    para não correr junto com o arquivamento da conta;
--  * categoria ativa e do tipo compatível (receita↔receita; despesa↔despesa);
--  * efetivo não pode ter data futura; previsto precisa ser posterior à
--    data-base da conta (o que é anterior já está no saldo inicial).
create or replace function privado.movimento_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_conta  record;
  v_cat    record;
begin
  if new.situacao = 'cancelado' then
    if tg_op = 'INSERT' then
      raise exception 'Movimento não pode nascer cancelado' using errcode = '22023';
    end if;
    return new;
  end if;

  select ativa, saldo_inicial_data into v_conta
    from public.contas where id = new.conta_id and user_id = new.user_id
     for share;
  if not found or not v_conta.ativa then
    raise exception 'Conta inexistente ou arquivada: o movimento não pode ser registrado' using errcode = '22023';
  end if;

  if new.categoria_id is not null then
    select tipo, ativa into v_cat from public.categorias where id = new.categoria_id and user_id = new.user_id;
    if not found or not v_cat.ativa then
      raise exception 'Categoria inexistente ou arquivada' using errcode = '22023';
    end if;
    if v_cat.tipo <> new.classificacao then
      raise exception 'Categoria de % não pode classificar um movimento de %', v_cat.tipo, new.classificacao using errcode = '22023';
    end if;
  end if;

  if new.situacao = 'efetivo' and new.data_movimento > privado.hoje() then
    raise exception 'Movimento efetivo não pode ter data futura; registre como previsto' using errcode = '22023';
  end if;
  if new.situacao = 'previsto' and new.data_movimento <= v_conta.saldo_inicial_data then
    raise exception 'Previsto precisa ser posterior à data-base da conta (%)', v_conta.saldo_inicial_data using errcode = '22023';
  end if;
  return new;
end $$;
create trigger movimentos_validar before insert or update on public.movimentos
  for each row execute function privado.movimento_validar();

-- =====================================================================
-- RPCs de movimentos (únicas portas de escrita)
-- =====================================================================
create or replace function public.movimento_criar(
  p_conta_id            uuid,
  p_natureza            text,
  p_valor_centavos      bigint,
  p_data                date,
  p_descricao           text,
  p_classificacao       text,
  p_categoria_id        uuid,
  p_situacao            text,
  p_observacao          text,
  p_chave_idempotencia  text
)
returns public.movimentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.movimentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'movimento_criar', jsonb_build_object(
    'conta_id', p_conta_id, 'natureza', p_natureza, 'valor', p_valor_centavos, 'data', p_data,
    'descricao', p_descricao, 'classificacao', p_classificacao, 'categoria_id', p_categoria_id,
    'situacao', p_situacao, 'observacao', p_observacao));
  if v_prev is not null then return jsonb_populate_record(null::public.movimentos, v_prev); end if;

  if p_situacao is null or p_situacao not in ('efetivo', 'previsto') then
    raise exception 'Situação deve ser efetivo ou previsto' using errcode = '22023';
  end if;
  if not exists (select 1 from public.contas where id = p_conta_id and user_id = v_uid) then
    raise exception 'Conta não encontrada' using errcode = 'P0002';
  end if;
  insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao,
                                 classificacao, categoria_id, situacao, observacao)
  values (v_uid, p_conta_id, p_natureza, p_valor_centavos, p_data, btrim(p_descricao),
          coalesce(p_classificacao, 'nao_classificado'), p_categoria_id, p_situacao, nullif(btrim(p_observacao), ''))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.movimento_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_natureza            text,
  p_valor_centavos      bigint,
  p_data                date,
  p_descricao           text,
  p_classificacao       text,
  p_categoria_id        uuid,
  p_observacao          text,
  p_chave_idempotencia  text default null
)
returns public.movimentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.movimentos;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'movimento_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'natureza', p_natureza, 'valor', p_valor_centavos, 'data', p_data,
      'descricao', p_descricao, 'classificacao', p_classificacao, 'categoria_id', p_categoria_id, 'observacao', p_observacao));
    if v_prev is not null then return jsonb_populate_record(null::public.movimentos, v_prev); end if;
  end if;
  if exists (select 1 from public.movimentos where id = p_id and user_id = v_uid and situacao = 'cancelado') then
    raise exception 'Movimento cancelado não pode ser alterado' using errcode = '22023';
  end if;
  update public.movimentos set
    natureza = p_natureza, valor_centavos = p_valor_centavos, data_movimento = p_data,
    descricao = btrim(p_descricao), classificacao = coalesce(p_classificacao, 'nao_classificado'),
    categoria_id = p_categoria_id, observacao = nullif(btrim(p_observacao), '')
  where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.movimentos', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Previsto → efetivo (mesma linha: não gera um segundo movimento)
create or replace function public.movimento_efetivar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_data_efetiva        date,
  p_valor_centavos      bigint default null,
  p_chave_idempotencia  text default null
)
returns public.movimentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.movimentos;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_data_efetiva is null then
    raise exception 'Informe a data em que o movimento aconteceu' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'movimento_efetivar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'data', p_data_efetiva, 'valor', p_valor_centavos));
    if v_prev is not null then return jsonb_populate_record(null::public.movimentos, v_prev); end if;
  end if;
  update public.movimentos set
    situacao = 'efetivo', data_movimento = p_data_efetiva,
    valor_centavos = coalesce(p_valor_centavos, valor_centavos)
  where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'previsto'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.movimentos where id = p_id and user_id = v_uid and situacao <> 'previsto') then
      raise exception 'Só um movimento previsto pode ser efetivado' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.movimentos', p_id, v_uid);
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.movimento_cancelar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_motivo              text,
  p_chave_idempotencia  text default null
)
returns public.movimentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.movimentos;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do cancelamento' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'movimento_cancelar',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo));
    if v_prev is not null then return jsonb_populate_record(null::public.movimentos, v_prev); end if;
  end if;
  perform set_config('app.motivo', btrim(p_motivo), true);
  update public.movimentos set situacao = 'cancelado', cancelado_motivo = btrim(p_motivo), cancelado_em = now()
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao <> 'cancelado'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.movimentos where id = p_id and user_id = v_uid and situacao = 'cancelado') then
      raise exception 'Movimento já está cancelado' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.movimentos', p_id, v_uid);
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- CONSULTAS (somente leitura, sob RLS do próprio usuário)
-- =====================================================================

-- Painel "Saldos por Conta" numa data (padrão: hoje, em Brasília)
--  saldo_confirmado_centavos: NULL quando o saldo inicial não está
--    validado ou a data pedida é anterior à data-base (ver "situacao");
--  saldo_projetado_centavos: confirmado + previstos pendentes posteriores
--    à data-base (até p_projetar_ate, se informado);
--  movimentos_anteriores_data_base: registrados, mas fora do saldo.
create or replace function public.saldos_por_conta(p_data date default null, p_projetar_ate date default null)
returns table (
  conta_id                         uuid,
  apelido                          text,
  instituicao                      text,
  titular                          text,
  tipo                             text,
  ativa                            boolean,
  incluir_consolidado              boolean,
  saldo_inicial_centavos           bigint,
  saldo_inicial_data               date,
  saldo_inicial_validado           boolean,
  movimentos_no_saldo              integer,
  movimentos_anteriores_data_base  integer,
  saldo_confirmado_centavos        bigint,
  previstos_pendentes_centavos     bigint,
  saldo_projetado_centavos         bigint,
  ultimo_movimento_em              date,
  atualizado_em                    timestamptz,
  situacao                         text
)
language sql stable security invoker
set search_path = ''
as $$
  with ref as (select coalesce(p_data, privado.hoje()) as d),
  base as (
    select c.*, i.nome as instituicao_nome, t.nome as titular_nome, ref.d
      from public.contas c
      join public.instituicoes i on i.id = c.instituicao_id
      join public.titulares t on t.id = c.titular_id
      cross join ref
     where c.user_id = auth.uid()
  ),
  calc as (
    select b.id,
      count(*) filter (where m.situacao = 'efetivo' and m.data_movimento > b.saldo_inicial_data and m.data_movimento <= b.d)::int as n_no_saldo,
      count(*) filter (where m.situacao = 'efetivo' and m.data_movimento <= b.saldo_inicial_data)::int as n_anteriores,
      coalesce(sum(m.valor_assinado_centavos) filter (where m.situacao = 'efetivo' and m.data_movimento > b.saldo_inicial_data and m.data_movimento <= b.d), 0)::bigint as soma_efetivos,
      coalesce(sum(m.valor_assinado_centavos) filter (where m.situacao = 'previsto' and m.data_movimento > b.saldo_inicial_data
                                                     and (p_projetar_ate is null or m.data_movimento <= p_projetar_ate)), 0)::bigint as soma_previstos,
      max(m.data_movimento) filter (where m.situacao = 'efetivo') as ultimo,
      max(m.atualizado_em) as mov_atualizado
      from base b
      left join public.movimentos m on m.conta_id = b.id and m.user_id = b.user_id
     group by b.id
  )
  select b.id, b.apelido, b.instituicao_nome, b.titular_nome, b.tipo, b.ativa, b.incluir_consolidado,
         b.saldo_inicial_centavos, b.saldo_inicial_data, b.saldo_inicial_validado,
         c.n_no_saldo, c.n_anteriores,
         case when b.saldo_inicial_validado and b.d >= b.saldo_inicial_data
              then b.saldo_inicial_centavos + c.soma_efetivos end,
         c.soma_previstos,
         case when b.saldo_inicial_validado and b.d >= b.saldo_inicial_data
              then b.saldo_inicial_centavos + c.soma_efetivos + c.soma_previstos end,
         c.ultimo,
         greatest(b.atualizado_em, c.mov_atualizado),
         case when not b.saldo_inicial_validado then 'saldo_inicial_nao_validado'
              when b.d < b.saldo_inicial_data then 'data_anterior_a_data_base'
              when not b.ativa then 'conta_arquivada'
              else 'ok' end
    from base b join calc c on c.id = b.id
   order by b.ativa desc, b.instituicao_nome, b.apelido;
$$;

-- Saldo consolidado: soma dos saldos confirmados das contas incluídas.
-- Contas incluídas com saldo inicial pendente NÃO entram na soma e são
-- informadas em contas_pendentes (o total fica marcado como incompleto).
create or replace function public.saldo_consolidado(p_data date default null)
returns table (
  data_referencia            date,
  saldo_confirmado_centavos  bigint,
  saldo_projetado_centavos   bigint,
  contas_somadas             integer,
  contas_pendentes           integer,
  completo                   boolean
)
language sql stable security invoker
set search_path = ''
as $$
  select coalesce(p_data, privado.hoje()),
         coalesce(sum(s.saldo_confirmado_centavos) filter (where s.saldo_confirmado_centavos is not null), 0)::bigint,
         coalesce(sum(s.saldo_projetado_centavos) filter (where s.saldo_confirmado_centavos is not null), 0)::bigint,
         (count(*) filter (where s.saldo_confirmado_centavos is not null))::int,
         (count(*) filter (where s.saldo_confirmado_centavos is null))::int,
         count(*) filter (where s.saldo_confirmado_centavos is null) = 0
    from public.saldos_por_conta(p_data) s
   where s.incluir_consolidado and s.ativa;
$$;

-- Extrato de uma conta com indicação do que entra no saldo e o saldo
-- acumulado após cada movimento contado.
create or replace function public.extrato_conta(p_conta_id uuid, p_inicio date default null, p_fim date default null)
returns table (
  movimento_id             uuid,
  data_movimento           date,
  descricao                text,
  natureza                 text,
  valor_centavos           bigint,
  valor_assinado_centavos  bigint,
  situacao                 text,
  classificacao            text,
  categoria                text,
  conta_no_saldo           boolean,
  saldo_apos_centavos      bigint,
  versao                   integer
)
language sql stable security invoker
set search_path = ''
as $$
  with c as (select * from public.contas where id = p_conta_id and user_id = auth.uid()),
  m as (
    select mv.*, cat.nome as categoria_nome,
           (mv.situacao = 'efetivo' and mv.data_movimento > c.saldo_inicial_data) as no_saldo,
           c.saldo_inicial_centavos, c.saldo_inicial_validado
      from public.movimentos mv
      join c on c.id = mv.conta_id
      left join public.categorias cat on cat.id = mv.categoria_id
     where mv.user_id = auth.uid()
  ),
  acumulado as (
    select m.*,
           case when m.no_saldo and m.saldo_inicial_validado then
             m.saldo_inicial_centavos + sum(case when m.no_saldo then m.valor_assinado_centavos else 0 end)
               over (order by m.data_movimento, m.criado_em, m.id rows unbounded preceding)
           end as saldo_apos
      from m
  )
  select a.id, a.data_movimento, a.descricao, a.natureza, a.valor_centavos, a.valor_assinado_centavos,
         a.situacao, a.classificacao, a.categoria_nome, a.no_saldo, a.saldo_apos, a.versao
    from acumulado a
   where (p_inicio is null or a.data_movimento >= p_inicio)
     and (p_fim is null or a.data_movimento <= p_fim)
   order by a.data_movimento, a.criado_em, a.id;
$$;

-- Receitas e despesas por categoria num período (somente efetivos).
-- Inclui movimentos anteriores à data-base: são fatos reais do período,
-- apenas não entram no saldo. Créditos classificados como despesa
-- (ex.: estorno) reduzem a despesa; débitos como receita reduzem a receita.
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
  select m.classificacao, m.categoria_id, coalesce(cat.nome, 'Não classificado'),
         count(*)::int,
         sum(case when m.classificacao = 'despesa' then -m.valor_assinado_centavos else m.valor_assinado_centavos end)::bigint
    from public.movimentos m
    left join public.categorias cat on cat.id = m.categoria_id
   where m.user_id = auth.uid() and m.situacao = 'efetivo'
     and m.data_movimento between p_inicio and p_fim
     and (p_conta_id is null or m.conta_id = p_conta_id)
   group by m.classificacao, m.categoria_id, cat.nome
   order by m.classificacao desc, 5 desc;
$$;

-- =====================================================================
-- LGPD: exportação e exclusão passam a incluir os movimentos
-- (create or replace mantém as permissões já concedidas)
-- =====================================================================
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := privado.uid_obrigatorio();
begin
  return jsonb_build_object(
    'gerado_em',   now(),
    'perfil',      (select to_jsonb(p) from public.perfis p where p.id = v_uid),
    'titulares',   coalesce((select jsonb_agg(t order by t.criado_em) from public.titulares t where t.user_id = v_uid), '[]'),
    'contas',      coalesce((select jsonb_agg(c order by c.criado_em) from public.contas c where c.user_id = v_uid), '[]'),
    'categorias',  coalesce((select jsonb_agg(c order by c.criado_em) from public.categorias c where c.user_id = v_uid), '[]'),
    'movimentos',  coalesce((select jsonb_agg(m order by m.data_movimento, m.criado_em) from public.movimentos m where m.user_id = v_uid), '[]'),
    'documentos',  coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                               from storage.objects o
                              where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'),
    'auditoria',   coalesce((select jsonb_agg(a order by a.id) from public.auditoria a where a.user_id = v_uid), '[]')
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
-- Permissões das funções NOVAS desta etapa (as da Etapa 1 não mudam)
-- =====================================================================
revoke all on function privado.hoje() from public, anon, authenticated, service_role;
revoke all on function privado.movimento_validar() from public, anon, authenticated, service_role;
revoke all on function public.movimento_criar(uuid, text, bigint, date, text, text, uuid, text, text, text) from public, anon;
revoke all on function public.movimento_atualizar(uuid, integer, text, bigint, date, text, text, uuid, text, text) from public, anon;
revoke all on function public.movimento_efetivar(uuid, integer, date, bigint, text) from public, anon;
revoke all on function public.movimento_cancelar(uuid, integer, text, text) from public, anon;
revoke all on function public.saldos_por_conta(date, date) from public, anon;
revoke all on function public.saldo_consolidado(date) from public, anon;
revoke all on function public.extrato_conta(uuid, date, date) from public, anon;
revoke all on function public.resumo_categorias(date, date, uuid) from public, anon;

-- privado.hoje() é usada dentro das consultas (avaliadas como o usuário)
grant execute on function privado.hoje() to authenticated;
grant execute on function public.movimento_criar(uuid, text, bigint, date, text, text, uuid, text, text, text) to authenticated;
grant execute on function public.movimento_atualizar(uuid, integer, text, bigint, date, text, text, uuid, text, text) to authenticated;
grant execute on function public.movimento_efetivar(uuid, integer, date, bigint, text) to authenticated;
grant execute on function public.movimento_cancelar(uuid, integer, text, text) to authenticated;
grant execute on function public.saldos_por_conta(date, date) to authenticated;
grant execute on function public.saldo_consolidado(date) to authenticated;
grant execute on function public.extrato_conta(uuid, date, date) to authenticated;
grant execute on function public.resumo_categorias(date, date, uuid) to authenticated;

update public.versao_esquema set etapa = '2-movimentos', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
