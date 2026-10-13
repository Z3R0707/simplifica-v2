-- =====================================================================
-- Simplifica Finanças v2 — 0010 Etapa 5 (parte 3): importação de FATURAS
--
-- Migração ADICIONAL sobre a 0009 (etapa "5.2-leitores-bancos"). Não apaga
-- nem recria nada. Tudo numa única transação.
--
-- FLUXO
--   1. O site lê a fatura (PDF), confere a soma dos lançamentos com o total
--      do banco, guarda o ORIGINAL no Storage e chama
--      importacao_fatura_criar. O banco confere a soma DE NOVO.
--   2. PRÉVIA (nada muda ainda). Para cada lançamento da fatura:
--      * à vista / encargo / crédito: "já importado" (mesma chave de uma
--        importação anterior), "possível duplicado" (lançamento parecido já
--        no cartão: mesmo valor, até 3 dias) ou "novo";
--      * parcela n/N: "já lançada" quando a parcela n de uma compra em N
--        vezes, com o mesmo valor (até R$ 0,99 de diferença de
--        arredondamento), já está nesta fatura; "possível duplicado" quando
--        está em outra fatura próxima; senão "nova" (cria a compra a partir
--        da parcela n, como em compra_criar);
--      * parcela antecipada: "antecipar" a parcela que estava numa fatura
--        futura (ou que nasce nesta mesma importação), ou "já lançada".
--   3. CONFIRMAR: cria as compras, antecipa, acerta os centavos de
--      parcelas já lançadas pelo valor do banco, grava as datas reais da
--      fatura e o total do banco (conferência). Pagamentos da fatura não
--      viram lançamentos.
--   4. DESFAZER: cancela o que a importação criou, devolve as parcelas
--      antecipadas, desfaz os ajustes de centavos e as datas.
--
-- Concorrência: tudo acontece com a linha do CARTÃO travada (FOR UPDATE),
-- então duas importações do mesmo cartão andam em fila.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '5.2-leitores-bancos') then
    raise exception 'ABORTADO: este banco não está na Etapa 5 parte 2 (0009) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- TABELAS
-- =====================================================================
create table public.importacoes_fatura (
  id                         uuid primary key default gen_random_uuid(),
  user_id                    uuid not null references auth.users (id) on delete cascade,
  cartao_id                  uuid not null,
  fatura_id                  uuid not null,
  leitor                     text not null check (length(leitor) between 1 and 60),
  arquivo_nome               text not null check (length(arquivo_nome) between 1 and 200),
  arquivo_hash               text not null check (arquivo_hash ~ '^[0-9a-f]{64}$'),
  arquivo_caminho            text not null check (length(arquivo_caminho) between 1 and 400),
  arquivo_tamanho            integer not null check (arquivo_tamanho between 1 and 10485760),
  finais_no_arquivo          text check (length(finais_no_arquivo) <= 100),
  vencimento                 date not null,
  fechamento                 date,
  total_lancamentos_centavos bigint not null check (abs(total_lancamentos_centavos) <= 10000000000000),
  total_a_pagar_centavos     bigint check (abs(total_a_pagar_centavos) <= 10000000000000),
  pagamentos                 jsonb not null default '[]',
  carimbo                    text not null,   -- estado das parcelas do cartão quando a prévia foi feita
  fatura_fechamento_anterior date,
  fatura_vencimento_anterior date,
  fatura_informado_anterior  bigint,
  situacao                   text not null default 'previa' check (situacao in ('previa', 'confirmada', 'cancelada')),
  itens_total                integer not null default 0,
  itens_lancados             integer not null default 0,
  itens_existentes           integer not null default 0,
  itens_antecipados          integer not null default 0,
  itens_ajustados            integer not null default 0,
  itens_ignorados            integer not null default 0,
  cancelada_motivo           text,
  confirmada_em              timestamptz,
  cancelada_em               timestamptz,
  criado_em                  timestamptz not null default now(),
  atualizado_em              timestamptz not null default now(),
  versao                     integer not null default 1,
  unique (id, user_id),
  foreign key (cartao_id, user_id) references public.cartoes (id, user_id),
  foreign key (fatura_id, user_id) references public.faturas (id, user_id),
  check ((situacao = 'cancelada') = (cancelada_em is not null)),
  check (fechamento is null or fechamento < vencimento)
);
create unique index importacoes_fatura_arquivo_unico on public.importacoes_fatura (user_id, arquivo_hash) where situacao <> 'cancelada';
create index importacoes_fatura_cartao_idx on public.importacoes_fatura (user_id, cartao_id, criado_em desc);
alter table public.importacoes_fatura enable row level security;
create policy importacoes_fatura_select on public.importacoes_fatura for select to authenticated using (user_id = auth.uid());
grant select on public.importacoes_fatura to authenticated;
select privado.aplicar_gatilhos_padrao('public.importacoes_fatura');

-- Compras: de qual importação de fatura vieram e a chave de deduplicação
alter table public.compras add column importacao_fatura_id uuid,
                           add column chave_importacao text check (length(chave_importacao) between 3 and 300);
alter table public.compras add constraint compras_importacao_fatura_fk foreign key (importacao_fatura_id, user_id) references public.importacoes_fatura (id, user_id);
create unique index compras_chave_importacao_unica on public.compras (user_id, cartao_id, chave_importacao)
  where chave_importacao is not null and situacao = 'ativa';

create table public.importacao_fatura_itens (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users (id) on delete cascade,
  importacao_id          uuid not null,
  ordem                  integer not null,
  data                   date not null,
  descricao_original     text not null,
  descricao              text not null check (length(btrim(descricao)) between 1 and 200),
  valor_centavos         bigint not null check (valor_centavos <> 0 and abs(valor_centavos) <= 10000000000000),
  tipo                   text not null check (tipo in ('compra', 'encargo', 'credito')),
  subtipo                text check (subtipo in ('juros', 'iof', 'tarifa', 'anuidade', 'multa', 'outro')),
  parcela_atual          integer,
  parcelas_total         integer,
  antecipada             boolean not null default false,
  desconto_antecipacao   boolean not null default false,
  final                  text check (final ~ '^[0-9]{4}$'),
  chave                  text,
  sugestao               text not null check (sugestao in ('novo', 'ja_importado', 'ja_lancado', 'possivel_duplicado', 'antecipar')),
  compra_existente_id    uuid,          -- compra parecida / já lançada
  parcela_existente_id   uuid,          -- parcela já lançada (ou a antecipar)
  vinculo_ordem          integer,       -- antecipação de parcela que nasce nesta mesma importação
  ajuste_centavos        bigint not null default 0, -- valor do banco − valor no Simplifica (parcela já lançada / antecipada)
  incluir                boolean not null,
  categoria_id           uuid,
  situacao               text not null default 'pendente' check (situacao in ('pendente', 'lancado', 'existente', 'antecipado', 'ignorado')),
  compra_criada_id       uuid,
  parcela_alterada_id    uuid,
  parcela_valor_anterior bigint,
  parcela_fatura_anterior uuid,
  unique (id, user_id),
  unique (importacao_id, ordem),
  foreign key (importacao_id, user_id) references public.importacoes_fatura (id, user_id),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  foreign key (compra_existente_id, user_id) references public.compras (id, user_id),
  foreign key (parcela_existente_id, user_id) references public.parcelas (id, user_id),
  foreign key (compra_criada_id, user_id) references public.compras (id, user_id),
  foreign key (parcela_alterada_id, user_id) references public.parcelas (id, user_id),
  check ((tipo = 'credito') = (valor_centavos < 0)),
  check ((tipo = 'encargo') = (subtipo is not null)),
  check ((parcela_atual is null) = (parcelas_total is null)),
  check (parcela_atual is null or (tipo = 'compra' and parcela_atual between 1 and parcelas_total and parcelas_total between 2 and 99)),
  check (not antecipada or parcela_atual is not null),
  check (not desconto_antecipacao or tipo = 'credito')
);
alter table public.importacao_fatura_itens enable row level security;
create policy importacao_fatura_itens_select on public.importacao_fatura_itens for select to authenticated using (user_id = auth.uid());
grant select on public.importacao_fatura_itens to authenticated;

-- =====================================================================
-- Ajuste de centavos: o valor de uma parcela (e o total da compra) só
-- muda pela importação de fatura, que usa o valor impresso pelo banco.
-- (substitui as funções da 0007, acrescentando só essa exceção)
-- =====================================================================
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
       or (new.valor_total_centavos <> old.valor_total_centavos and coalesce(current_setting('app.ajuste_importacao', true), '') <> 'on')
       or new.parcelas_total <> old.parcelas_total
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

create or replace function privado.parcela_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_fat public.faturas;
begin
  if tg_op = 'UPDATE' then
    if new.compra_id <> old.compra_id or new.numero <> old.numero or new.natureza <> old.natureza
       or (new.valor_centavos <> old.valor_centavos and coalesce(current_setting('app.ajuste_importacao', true), '') <> 'on')
       or new.cartao_id <> old.cartao_id then
      raise exception 'Parcela não muda de compra, número, sentido ou valor' using errcode = '22023';
    end if;
    if old.situacao = 'cancelada' and new.situacao <> 'cancelada' then
      raise exception 'Parcela cancelada não volta a valer' using errcode = '22023';
    end if;
    if new.fatura_id = old.fatura_id and new.situacao = old.situacao and new.desconto_centavos = old.desconto_centavos
       and new.valor_centavos = old.valor_centavos then
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

-- Estado das parcelas do cartão a partir de 2 meses antes da fatura: se
-- mudar entre a prévia e a confirmação, a prévia ficou velha.
create or replace function privado.fatura_importacao_carimbo(p_cartao_id uuid, p_competencia date)
returns text
language sql stable
set search_path = ''
as $$
  select md5(coalesce(string_agg(p.id::text || ':' || p.valor_centavos || ':' || p.fatura_id::text || ':' || p.situacao, ',' order by p.id), ''))
    from public.parcelas p join public.faturas f on f.id = p.fatura_id
   where p.cartao_id = p_cartao_id and f.competencia >= (p_competencia - interval '2 months')::date;
$$;

-- Acerta o valor de uma parcela (e o total da compra) pelo valor do banco
create or replace function privado.parcela_ajustar_valor(p_parcela_id uuid, p_novo bigint)
returns void
language plpgsql
set search_path = ''
as $$
declare v_p public.parcelas;
begin
  select * into v_p from public.parcelas where id = p_parcela_id for update;
  if v_p.valor_centavos = p_novo then return; end if;
  if p_novo <= 0 or p_novo < v_p.desconto_centavos then
    raise exception 'Valor de parcela inválido no ajuste' using errcode = '22023';
  end if;
  perform set_config('app.ajuste_importacao', 'on', true);
  perform set_config('app.motivo', 'Valor da parcela conforme a fatura do banco', true);
  update public.parcelas set valor_centavos = p_novo where id = v_p.id;
  update public.compras set valor_total_centavos = valor_total_centavos + (p_novo - v_p.valor_centavos) where id = v_p.compra_id;
  perform set_config('app.ajuste_importacao', '', true);
  perform set_config('app.motivo', '', true);
end $$;

-- =====================================================================
-- RPC: criar a prévia
-- p_itens: lista JSON de {data, descricao, valor_centavos (+ débito,
-- − crédito), tipo (compra|encargo|credito), subtipo?, parcela_atual?,
-- parcelas_total?, antecipada?, desconto_antecipacao?, final?}
-- p_pagamentos: lista JSON de {data, descricao, valor_centavos} (só registro)
-- =====================================================================
create or replace function public.importacao_fatura_criar(
  p_cartao_id                  uuid,
  p_leitor                     text,
  p_arquivo_nome               text,
  p_arquivo_hash               text,
  p_arquivo_caminho            text,
  p_arquivo_tamanho            integer,
  p_finais                     text,
  p_vencimento                 date,
  p_fechamento                 date,
  p_total_lancamentos_centavos bigint,
  p_total_a_pagar_centavos     bigint,
  p_itens                      jsonb,
  p_pagamentos                 jsonb,
  p_chave_idempotencia         text
)
returns public.importacoes_fatura
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := privado.uid_para_escrita();
  v_prev    jsonb;
  v_c       public.cartoes;
  v_reg     public.importacoes_fatura;
  v_outra   public.importacoes_fatura;
  v_comp    date;
  v_fat     uuid;
  v_soma    bigint;
  v_i       public.importacao_fatura_itens;
  v_usadas  uuid[] := '{}';
  v_cid     uuid;
  v_pid     uuid;
  v_pfat    uuid;
  v_dif     bigint;
  v_ord     integer;
  v_n       integer;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_fatura_criar', jsonb_build_object(
    'cartao_id', p_cartao_id, 'hash', p_arquivo_hash, 'itens', p_itens, 'vencimento', p_vencimento, 'total', p_total_lancamentos_centavos));
  if v_prev is not null then return jsonb_populate_record(null::public.importacoes_fatura, v_prev); end if;

  select * into v_c from public.cartoes where id = p_cartao_id and user_id = v_uid for update;
  if not found then
    raise exception 'Cartão não encontrado' using errcode = 'P0002';
  end if;
  if not v_c.ativo then
    raise exception 'Cartão arquivado não recebe importação' using errcode = '22023';
  end if;
  if p_arquivo_caminho is null or split_part(p_arquivo_caminho, '/', 1) <> v_uid::text then
    raise exception 'O arquivo original precisa estar na sua pasta' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documentos' and o.name = p_arquivo_caminho) then
    raise exception 'O arquivo original não foi guardado; envie o arquivo de novo' using errcode = '22023';
  end if;
  select * into v_outra from public.importacoes_fatura where user_id = v_uid and arquivo_hash = p_arquivo_hash and situacao <> 'cancelada';
  if found then
    raise exception 'Esta fatura já foi importada em % (%). Para importar de novo, desfaça a importação anterior.',
      to_char(v_outra.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY'),
      case when v_outra.situacao = 'previa' then 'prévia ainda não confirmada' else 'confirmada' end using errcode = '22023';
  end if;
  if p_vencimento is null or p_total_lancamentos_centavos is null then
    raise exception 'A fatura precisa ter vencimento e total de lançamentos' using errcode = '22023';
  end if;
  if p_fechamento is not null and p_fechamento >= p_vencimento then
    raise exception 'O fechamento precisa ser antes do vencimento' using errcode = '22023';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A fatura não tem lançamentos para importar' using errcode = '22023';
  end if;
  if jsonb_array_length(p_itens) > 2000 then
    raise exception 'Fatura grande demais: no máximo 2.000 lançamentos' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) e
              where (e ->> 'data') is null or (e ->> 'valor_centavos') is null or (e ->> 'valor_centavos')::bigint = 0
                 or length(btrim(coalesce(e ->> 'descricao', ''))) = 0 or (e ->> 'data')::date > p_vencimento) then
    raise exception 'Há lançamentos sem data, sem descrição, com valor zero ou depois do vencimento' using errcode = '22023';
  end if;
  select sum((e ->> 'valor_centavos')::bigint) into v_soma from jsonb_array_elements(p_itens) e;
  if v_soma <> p_total_lancamentos_centavos then
    raise exception 'A soma dos lançamentos (%) não bate com o total da fatura (%): leitura recusada',
      privado.reais(v_soma), privado.reais(p_total_lancamentos_centavos) using errcode = '22023';
  end if;
  v_comp := date_trunc('month', p_vencimento)::date;
  if v_comp > (date_trunc('month', privado.hoje()) + interval '2 months')::date then
    raise exception 'Fatura muito distante' using errcode = '22023';
  end if;
  v_fat := privado.fatura_obter(v_c.id, v_comp);
  perform 1 from public.faturas where id = v_fat for update;

  insert into public.importacoes_fatura (user_id, cartao_id, fatura_id, leitor, arquivo_nome, arquivo_hash, arquivo_caminho, arquivo_tamanho,
                                         finais_no_arquivo, vencimento, fechamento, total_lancamentos_centavos, total_a_pagar_centavos, pagamentos, carimbo)
  values (v_uid, v_c.id, v_fat, left(p_leitor, 60), left(btrim(p_arquivo_nome), 200), p_arquivo_hash, p_arquivo_caminho, p_arquivo_tamanho,
          left(p_finais, 100), p_vencimento, p_fechamento, p_total_lancamentos_centavos, p_total_a_pagar_centavos,
          case when jsonb_typeof(p_pagamentos) = 'array' then p_pagamentos else '[]' end,
          privado.fatura_importacao_carimbo(v_c.id, v_comp))
  returning * into v_reg;

  -- itens (os CHECKs da tabela recusam combinações inválidas)
  insert into public.importacao_fatura_itens (user_id, importacao_id, ordem, data, descricao_original, descricao, valor_centavos, tipo, subtipo,
                                              parcela_atual, parcelas_total, antecipada, desconto_antecipacao, final, chave, sugestao, incluir)
  select v_uid, v_reg.id, x.ordem, x.data, x.descricao, left(x.descricao, 200), x.valor, x.tipo, x.subtipo, x.atual, x.total,
         x.antecipada, x.desconto, x.final,
         case when x.atual is null then
           'fat:' || to_char(v_comp, 'YYYY-MM') || ':' || md5(x.data::text || '|' || x.valor || '|' || x.tipo || '|' || privado.normalizar_descricao(x.descricao))
           || ':' || row_number() over (partition by x.atual is null, x.data, x.valor, x.tipo, privado.normalizar_descricao(x.descricao) order by x.ordem) end,
         'novo', true
    from (
      select (e.ord)::int as ordem, (e.v ->> 'data')::date as data, btrim(e.v ->> 'descricao') as descricao,
             (e.v ->> 'valor_centavos')::bigint as valor, e.v ->> 'tipo' as tipo,
             case when e.v ->> 'tipo' = 'encargo' then coalesce(nullif(e.v ->> 'subtipo', ''), 'outro') end as subtipo,
             nullif(e.v ->> 'parcela_atual', '')::int as atual, nullif(e.v ->> 'parcelas_total', '')::int as total,
             coalesce((e.v ->> 'antecipada')::boolean, false) as antecipada,
             coalesce((e.v ->> 'desconto_antecipacao')::boolean, false) as desconto, nullif(e.v ->> 'final', '') as final
        from jsonb_array_elements(p_itens) with ordinality as e(v, ord)
    ) x;

  -- sugestões, item a item (cada compra/parcela existente casa com um item só)
  for v_i in select * from public.importacao_fatura_itens where importacao_id = v_reg.id order by antecipada, ordem loop
    v_cid := null; v_pid := null; v_pfat := null; v_dif := 0; v_ord := null;
    if v_i.parcela_atual is null then
      select c.id into v_cid from public.compras c
       where c.user_id = v_uid and c.cartao_id = v_c.id and c.situacao = 'ativa' and c.chave_importacao = v_i.chave;
      if found then
        update public.importacao_fatura_itens set sugestao = 'ja_importado', incluir = false, compra_existente_id = v_cid where id = v_i.id;
        v_usadas := v_usadas || v_cid;
        continue;
      end if;
      -- desconto de antecipação que já está nas parcelas antecipadas (antecipação feita no Simplifica)
      if v_i.desconto_antecipacao then
        select c.id into v_cid from public.compras c
         where c.user_id = v_uid and c.cartao_id = v_c.id and c.situacao = 'ativa' and c.id <> all (v_usadas)
           and (select coalesce(sum(p.desconto_centavos), 0) from public.parcelas p
                 where p.compra_id = c.id and p.fatura_id = v_fat and p.situacao = 'ativa' and p.antecipada_em is not null) = abs(v_i.valor_centavos)
         order by (privado.normalizar_descricao(c.descricao) = privado.normalizar_descricao(v_i.descricao)) desc, c.criado_em
         limit 1;
        if found then
          update public.importacao_fatura_itens set sugestao = 'ja_lancado', incluir = false, compra_existente_id = v_cid where id = v_i.id;
          v_usadas := v_usadas || v_cid;
          continue;
        end if;
      end if;
      select c.id into v_cid from public.compras c
       where c.user_id = v_uid and c.cartao_id = v_c.id and c.situacao = 'ativa' and c.parcelas_total = 1
         and c.natureza = case when v_i.valor_centavos > 0 then 'debito' else 'credito' end
         and c.valor_total_centavos = abs(v_i.valor_centavos) and abs(c.data_compra - v_i.data) <= 3
         and c.id <> all (v_usadas)
       order by (privado.normalizar_descricao(c.descricao) = privado.normalizar_descricao(v_i.descricao)) desc,
                abs(c.data_compra - v_i.data), c.criado_em
       limit 1;
      if found then
        update public.importacao_fatura_itens set sugestao = 'possivel_duplicado', incluir = false, compra_existente_id = v_cid where id = v_i.id;
        v_usadas := v_usadas || v_cid;
      end if;
      continue;
    end if;

    -- parcela n/N de uma compra já no Simplifica (mesmo valor, até R$ 0,99 de arredondamento)
    select p.id, p.compra_id, p.fatura_id, v_i.valor_centavos - p.valor_centavos into v_pid, v_cid, v_pfat, v_dif
      from public.parcelas p
      join public.compras c on c.id = p.compra_id
      join public.faturas f on f.id = p.fatura_id
     where p.user_id = v_uid and p.cartao_id = v_c.id and p.situacao = 'ativa' and c.situacao = 'ativa' and c.tipo = 'compra'
       and c.parcelas_total = v_i.parcelas_total and p.numero = v_i.parcela_atual
       and abs(p.valor_centavos - v_i.valor_centavos) < 100
       and p.id <> all (v_usadas)
       and (p.fatura_id = v_fat
            or (not v_i.antecipada and abs((f.competencia - v_comp)) <= 62)
            or (v_i.antecipada and f.competencia > v_comp and p.antecipada_em is null))
     order by (p.fatura_id = v_fat) desc,
              (privado.normalizar_descricao(c.descricao) = privado.normalizar_descricao(v_i.descricao)) desc,
              abs(p.valor_centavos - v_i.valor_centavos), abs(f.competencia - v_comp), c.criado_em
     limit 1;
    if v_pid is not null then
      v_usadas := v_usadas || v_pid;
      update public.importacao_fatura_itens
         set sugestao = case when v_pfat = v_fat then 'ja_lancado' when v_i.antecipada then 'antecipar' else 'possivel_duplicado' end,
             incluir = (v_pfat <> v_fat and v_i.antecipada),
             compra_existente_id = v_cid, parcela_existente_id = v_pid, ajuste_centavos = v_dif
       where id = v_i.id;
      continue;
    end if;
    -- antecipação de uma parcela cuja compra nasce nesta mesma importação
    if v_i.antecipada then
      select j.ordem into v_ord from public.importacao_fatura_itens j
       where j.importacao_id = v_reg.id and not j.antecipada and j.sugestao = 'novo'
         and j.parcelas_total = v_i.parcelas_total and j.parcela_atual < v_i.parcela_atual
         and privado.normalizar_descricao(j.descricao) = privado.normalizar_descricao(v_i.descricao)
         and not exists (select 1 from public.importacao_fatura_itens k
                          where k.importacao_id = v_reg.id and k.vinculo_ordem = j.ordem and k.parcela_atual = v_i.parcela_atual)
       order by j.ordem limit 1;
      if v_ord is not null then
        update public.importacao_fatura_itens set sugestao = 'antecipar', vinculo_ordem = v_ord where id = v_i.id;
      end if;
    end if;
  end loop;

  -- categoria sugerida pelo histórico de compras do mesmo estabelecimento
  update public.importacao_fatura_itens i set categoria_id = (
      select c.categoria_id from public.compras c
       where c.user_id = v_uid and c.situacao = 'ativa' and c.categoria_id is not null
         and privado.normalizar_descricao(c.descricao) = privado.normalizar_descricao(i.descricao)
         and exists (select 1 from public.categorias k where k.id = c.categoria_id and k.ativa)
       order by c.data_compra desc, c.criado_em desc limit 1)
   where i.importacao_id = v_reg.id and i.sugestao in ('novo', 'possivel_duplicado');

  select count(*) into v_n from public.importacao_fatura_itens where importacao_id = v_reg.id;
  update public.importacoes_fatura set itens_total = v_n where id = v_reg.id returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- RPC: confirmar. p_ajustes: lista JSON de {id, incluir, categoria_id,
-- descricao} com o que o usuário mudou na prévia.
-- =====================================================================
create or replace function public.importacao_fatura_confirmar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_ajustes             jsonb,
  p_chave_idempotencia  text
)
returns public.importacoes_fatura
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid    uuid := privado.uid_para_escrita();
  v_prev   jsonb;
  v_reg    public.importacoes_fatura;
  v_c      public.cartoes;
  v_f      public.faturas;
  v_i      public.importacao_fatura_itens;
  v_compra public.compras;
  v_p      public.parcelas;
  v_cat    uuid;
  v_comp   date;
  v_lanc   integer := 0;
  v_exist  integer := 0;
  v_ant    integer := 0;
  v_aj     integer := 0;
  v_ign    integer := 0;
  v_pid    uuid;
begin
  perform privado.exigir_versao(p_versao_esperada);
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_fatura_confirmar',
              jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'ajustes', p_ajustes));
  if v_prev is not null then return jsonb_populate_record(null::public.importacoes_fatura, v_prev); end if;

  select * into v_reg from public.importacoes_fatura where id = p_id and user_id = v_uid;
  if not found then
    raise exception 'Importação não encontrada' using errcode = 'P0002';
  end if;
  select * into v_c from public.cartoes where id = v_reg.cartao_id for update;
  select * into v_reg from public.importacoes_fatura where id = p_id for update;
  if v_reg.situacao <> 'previa' then
    raise exception 'Esta importação já foi %', case when v_reg.situacao = 'confirmada' then 'confirmada' else 'descartada' end using errcode = '22023';
  end if;
  if v_reg.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.importacoes_fatura', p_id, v_uid);
  end if;
  if not v_c.ativo then
    raise exception 'Cartão arquivado não recebe importação' using errcode = '22023';
  end if;
  select * into v_f from public.faturas where id = v_reg.fatura_id for update;
  v_comp := v_f.competencia;
  if privado.fatura_importacao_carimbo(v_c.id, v_comp) <> v_reg.carimbo then
    raise exception 'Os lançamentos deste cartão mudaram depois da prévia (outra importação ou um lançamento novo). Descarte esta prévia e importe a fatura de novo.'
      using errcode = '40001';
  end if;

  if p_ajustes is not null and jsonb_typeof(p_ajustes) = 'array' then
    update public.importacao_fatura_itens i set
      incluir = case when i.sugestao in ('ja_importado', 'ja_lancado') then false else coalesce((a.v ->> 'incluir')::boolean, i.incluir) end,
      descricao = coalesce(nullif(left(btrim(a.v ->> 'descricao'), 200), ''), i.descricao),
      categoria_id = case when a.v ? 'categoria_id' then nullif(a.v ->> 'categoria_id', '')::uuid else i.categoria_id end
      from jsonb_array_elements(p_ajustes) a(v)
     where i.importacao_id = v_reg.id and i.id = (a.v ->> 'id')::uuid;
  end if;

  -- 1ª passada: lançamentos novos, já existentes e ajustes de centavos
  for v_i in select * from public.importacao_fatura_itens where importacao_id = v_reg.id and sugestao <> 'antecipar' order by ordem loop
    if v_i.sugestao in ('ja_importado', 'ja_lancado') then
      if v_i.sugestao = 'ja_lancado' and v_i.ajuste_centavos <> 0 then
        select * into v_p from public.parcelas where id = v_i.parcela_existente_id;
        perform privado.parcela_ajustar_valor(v_p.id, v_i.valor_centavos);
        update public.importacao_fatura_itens set parcela_alterada_id = v_p.id, parcela_valor_anterior = v_p.valor_centavos where id = v_i.id;
        v_aj := v_aj + 1;
      end if;
      update public.importacao_fatura_itens set situacao = 'existente' where id = v_i.id;
      v_exist := v_exist + 1;
      continue;
    end if;
    if not v_i.incluir then
      update public.importacao_fatura_itens set situacao = 'ignorado' where id = v_i.id;
      v_ign := v_ign + 1;
      continue;
    end if;
    -- outra importação pode ter lançado o mesmo item depois da prévia
    if v_i.chave is not null and exists (select 1 from public.compras where user_id = v_uid and cartao_id = v_c.id
                                          and chave_importacao = v_i.chave and situacao = 'ativa') then
      update public.importacao_fatura_itens set situacao = 'existente' where id = v_i.id;
      v_exist := v_exist + 1;
      continue;
    end if;
    v_cat := (select id from public.categorias where id = v_i.categoria_id and user_id = v_uid and ativa and tipo = 'despesa');
    if v_i.parcela_atual is not null and not v_i.antecipada then
      v_compra := public.compra_criar(v_c.id, 'compra', null, least(v_i.data, privado.hoje()), v_i.descricao, v_cat, null,
                                      v_i.parcelas_total, v_i.valor_centavos, v_i.parcela_atual, v_comp, null,
                                      'impfat-' || v_i.id::text);
    elsif v_i.antecipada then
      -- parcela antecipada sem a compra no Simplifica: entra como lançamento único nesta fatura
      v_compra := public.compra_criar(v_c.id, 'compra', null, least(v_i.data, privado.hoje()),
                                      left('Antecipada: ' || v_i.descricao || ' (parcela ' || v_i.parcela_atual || '/' || v_i.parcelas_total || ')', 200),
                                      v_cat, v_i.valor_centavos, 1, null, 1, v_comp, null, 'impfat-' || v_i.id::text);
    else
      v_compra := public.compra_criar(v_c.id, v_i.tipo, v_i.subtipo, least(v_i.data, privado.hoje()), v_i.descricao, v_cat,
                                      abs(v_i.valor_centavos), 1, null, 1, v_comp, null, 'impfat-' || v_i.id::text);
    end if;
    update public.compras set origem = 'importacao', importacao_fatura_id = v_reg.id, chave_importacao = v_i.chave,
           observacao = case when v_i.descricao <> left(v_i.descricao_original, 200) then left('Na fatura: ' || v_i.descricao_original, 500) end
     where id = v_compra.id;
    update public.importacao_fatura_itens set situacao = 'lancado', compra_criada_id = v_compra.id, categoria_id = v_cat where id = v_i.id;
    v_lanc := v_lanc + 1;
  end loop;

  -- 2ª passada: antecipações (parcela de fatura futura, ou nascida agora)
  for v_i in select * from public.importacao_fatura_itens where importacao_id = v_reg.id and sugestao = 'antecipar' order by ordem loop
    if not v_i.incluir then
      update public.importacao_fatura_itens set situacao = 'ignorado' where id = v_i.id;
      v_ign := v_ign + 1;
      continue;
    end if;
    v_pid := v_i.parcela_existente_id;
    if v_pid is null then
      select p.id into v_pid from public.parcelas p
        join public.importacao_fatura_itens j on j.compra_criada_id = p.compra_id
       where j.importacao_id = v_reg.id and j.ordem = v_i.vinculo_ordem and p.numero = v_i.parcela_atual;
    end if;
    select p.* into v_p from public.parcelas p join public.faturas f on f.id = p.fatura_id
     where p.id = v_pid and p.situacao = 'ativa' and p.antecipada_em is null and f.competencia > v_comp;
    if not found then
      raise exception 'A parcela % a antecipar ("%") mudou depois da prévia. Descarte a prévia e importe de novo.',
        v_i.parcela_atual || '/' || v_i.parcelas_total, v_i.descricao using errcode = '40001';
    end if;
    perform 1 from public.faturas where id = v_p.fatura_id for update;
    perform set_config('app.motivo', 'Antecipação conforme a fatura do banco', true);
    update public.parcelas set fatura_original_id = fatura_id, fatura_id = v_reg.fatura_id, antecipada_em = now()
     where id = v_p.id;
    perform set_config('app.motivo', '', true);
    if v_p.valor_centavos <> v_i.valor_centavos then
      perform privado.parcela_ajustar_valor(v_p.id, v_i.valor_centavos);
      v_aj := v_aj + 1;
    end if;
    update public.importacao_fatura_itens set situacao = 'antecipado', parcela_alterada_id = v_p.id,
           parcela_valor_anterior = v_p.valor_centavos, parcela_fatura_anterior = v_p.fatura_id
     where id = v_i.id;
    v_ant := v_ant + 1;
  end loop;

  -- datas reais da fatura e o total do banco, para conferência
  update public.importacoes_fatura set fatura_fechamento_anterior = v_f.fechamento, fatura_vencimento_anterior = v_f.vencimento,
         fatura_informado_anterior = v_f.total_informado_centavos
   where id = v_reg.id;
  update public.faturas set vencimento = v_reg.vencimento,
         fechamento = coalesce(v_reg.fechamento, least(fechamento, v_reg.vencimento - 1)),
         total_informado_centavos = v_reg.total_lancamentos_centavos
   where id = v_f.id;
  perform privado.fatura_sincronizar(v_f.id);

  update public.importacoes_fatura set situacao = 'confirmada', confirmada_em = now(),
         itens_lancados = v_lanc, itens_existentes = v_exist, itens_antecipados = v_ant, itens_ajustados = v_aj, itens_ignorados = v_ign
   where id = v_reg.id
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- RPC: descartar a prévia ou desfazer a importação confirmada
-- =====================================================================
create or replace function public.importacao_fatura_desfazer(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_motivo              text,
  p_chave_idempotencia  text default null
)
returns public.importacoes_fatura
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.importacoes_fatura;
  v_i    public.importacao_fatura_itens;
  v_p    public.parcelas;
  v_cp   public.compras;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_fatura_desfazer',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo));
    if v_prev is not null then return jsonb_populate_record(null::public.importacoes_fatura, v_prev); end if;
  end if;
  select * into v_reg from public.importacoes_fatura where id = p_id and user_id = v_uid;
  if not found then
    raise exception 'Importação não encontrada' using errcode = 'P0002';
  end if;
  perform 1 from public.cartoes where id = v_reg.cartao_id for update;
  select * into v_reg from public.importacoes_fatura where id = p_id for update;
  if v_reg.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.importacoes_fatura', p_id, v_uid);
  end if;
  if v_reg.situacao = 'cancelada' then
    raise exception 'Esta importação já foi desfeita' using errcode = '22023';
  end if;

  if v_reg.situacao = 'confirmada' then
    perform 1 from public.faturas where id = v_reg.fatura_id for update;
    perform set_config('app.motivo', left('Importação de fatura desfeita: ' || btrim(p_motivo), 500), true);
    -- antecipações voltam para a fatura de origem (com o valor anterior)
    for v_i in select * from public.importacao_fatura_itens where importacao_id = v_reg.id and situacao = 'antecipado' order by ordem desc loop
      select * into v_p from public.parcelas where id = v_i.parcela_alterada_id;
      if v_p.situacao = 'ativa' and v_p.fatura_id = v_reg.fatura_id and v_p.antecipada_em is not null then
        if v_p.valor_centavos <> v_i.parcela_valor_anterior then
          perform privado.parcela_ajustar_valor(v_p.id, v_i.parcela_valor_anterior);
        end if;
        perform set_config('app.motivo', left('Importação de fatura desfeita: ' || btrim(p_motivo), 500), true);
        update public.parcelas set fatura_id = v_i.parcela_fatura_anterior, fatura_original_id = null, antecipada_em = null, desconto_centavos = 0
         where id = v_p.id;
      end if;
    end loop;
    -- ajustes de centavos em parcelas que já existiam
    for v_i in select * from public.importacao_fatura_itens where importacao_id = v_reg.id and situacao = 'existente'
                                                                and parcela_alterada_id is not null loop
      select * into v_p from public.parcelas where id = v_i.parcela_alterada_id;
      if v_p.situacao = 'ativa' and v_p.valor_centavos <> v_i.parcela_valor_anterior then
        perform privado.parcela_ajustar_valor(v_p.id, v_i.parcela_valor_anterior);
      end if;
    end loop;
    perform set_config('app.motivo', left('Importação de fatura desfeita: ' || btrim(p_motivo), 500), true);
    -- compras criadas pela importação: canceladas por inteiro (nada é apagado)
    for v_cp in select * from public.compras where importacao_fatura_id = v_reg.id and situacao = 'ativa' order by data_compra, id loop
      if exists (select 1 from public.compras where estorno_de = v_cp.id and situacao = 'ativa') then
        raise exception 'A compra "%" tem estorno lançado depois da importação. Cancele o estorno antes de desfazer.', v_cp.descricao
          using errcode = '22023';
      end if;
      perform 1 from public.faturas f where f.id in (select fatura_id from public.parcelas where compra_id = v_cp.id and situacao = 'ativa')
       order by f.competencia, f.id for update;
      update public.parcelas set situacao = 'cancelada', cancelada_motivo = left('Importação de fatura desfeita: ' || btrim(p_motivo), 500)
       where compra_id = v_cp.id and situacao = 'ativa';
      update public.compras set situacao = 'cancelada', cancelada_motivo = left('Importação de fatura desfeita: ' || btrim(p_motivo), 500),
             cancelada_em = now()
       where id = v_cp.id;
    end loop;
    -- datas e total informado voltam ao que eram
    update public.faturas set vencimento = coalesce(v_reg.fatura_vencimento_anterior, vencimento),
           fechamento = coalesce(v_reg.fatura_fechamento_anterior, fechamento),
           total_informado_centavos = v_reg.fatura_informado_anterior
     where id = v_reg.fatura_id;
    perform privado.fatura_sincronizar(v_reg.fatura_id);
    perform set_config('app.motivo', '', true);
  end if;
  update public.importacoes_fatura set situacao = 'cancelada', cancelada_motivo = btrim(p_motivo), cancelada_em = now()
   where id = v_reg.id
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- CONSULTAS
-- =====================================================================
-- Importações de fatura de um cartão, com a conferência: total de
-- lançamentos segundo o banco × total da fatura no Simplifica.
create or replace function public.importacoes_fatura_do_cartao(p_cartao_id uuid)
returns table (
  importacao_id              uuid,
  arquivo_nome               text,
  leitor                     text,
  situacao                   text,
  competencia                date,
  vencimento                 date,
  total_lancamentos_centavos bigint,
  total_fatura_centavos      bigint,
  itens_total                integer,
  itens_lancados             integer,
  itens_existentes           integer,
  itens_antecipados          integer,
  itens_ajustados            integer,
  itens_ignorados            integer,
  criado_em                  timestamptz,
  cancelada_motivo           text,
  versao                     integer
)
language sql stable security invoker
set search_path = ''
as $$
  select i.id, i.arquivo_nome, i.leitor, i.situacao, f.competencia, i.vencimento, i.total_lancamentos_centavos,
         (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa'),
         i.itens_total, i.itens_lancados, i.itens_existentes, i.itens_antecipados, i.itens_ajustados, i.itens_ignorados,
         i.criado_em, i.cancelada_motivo, i.versao
    from public.importacoes_fatura i
    join public.faturas f on f.id = i.fatura_id
   where i.user_id = auth.uid() and i.cartao_id = p_cartao_id
   order by i.criado_em desc;
$$;

create or replace function public.importacao_fatura_itens_lista(p_importacao_id uuid)
returns table (
  item_id               uuid,
  ordem                 integer,
  data                  date,
  descricao             text,
  descricao_original    text,
  valor_centavos        bigint,
  tipo                  text,
  parcela_atual         integer,
  parcelas_total        integer,
  antecipada            boolean,
  final                 text,
  sugestao              text,
  ajuste_centavos       bigint,
  existente_descricao   text,
  existente_data        date,
  existente_competencia date,
  vinculo_ordem         integer,
  incluir               boolean,
  categoria_id          uuid,
  situacao              text
)
language sql stable security invoker
set search_path = ''
as $$
  select it.id, it.ordem, it.data, it.descricao, it.descricao_original, it.valor_centavos, it.tipo, it.parcela_atual, it.parcelas_total,
         it.antecipada, it.final, it.sugestao, it.ajuste_centavos, c.descricao, c.data_compra, f.competencia, it.vinculo_ordem,
         it.incluir, it.categoria_id, it.situacao
    from public.importacao_fatura_itens it
    left join public.compras c on c.id = it.compra_existente_id
    left join public.parcelas p on p.id = it.parcela_existente_id
    left join public.faturas f on f.id = coalesce(p.fatura_id, (select p2.fatura_id from public.parcelas p2 where p2.compra_id = c.id order by p2.numero limit 1))
   where it.user_id = auth.uid() and it.importacao_id = p_importacao_id
   order by it.ordem;
$$;

-- =====================================================================
-- LGPD: exportação e exclusão incluem as importações de fatura
-- =====================================================================
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := privado.uid_obrigatorio();
begin
  return jsonb_build_object(
    'gerado_em',        now(),
    'perfil',           (select to_jsonb(p) from public.perfis p where p.id = v_uid),
    'titulares',        coalesce((select jsonb_agg(t order by t.criado_em) from public.titulares t where t.user_id = v_uid), '[]'),
    'contas',           coalesce((select jsonb_agg(c order by c.criado_em) from public.contas c where c.user_id = v_uid), '[]'),
    'categorias',       coalesce((select jsonb_agg(c order by c.criado_em) from public.categorias c where c.user_id = v_uid), '[]'),
    'movimentos',       coalesce((select jsonb_agg(m order by m.data_movimento, m.criado_em) from public.movimentos m where m.user_id = v_uid), '[]'),
    'recorrencias',     coalesce((select jsonb_agg(r order by r.criado_em) from public.recorrencias r where r.user_id = v_uid), '[]'),
    'contas_a_pagar',   coalesce((select jsonb_agg(o order by o.vencimento, o.criado_em) from public.obrigacoes o where o.user_id = v_uid), '[]'),
    'pagamentos',       coalesce((select jsonb_agg(p order by p.criado_em) from public.pagamentos p where p.user_id = v_uid), '[]'),
    'cartoes',          coalesce((select jsonb_agg(c order by c.criado_em) from public.cartoes c where c.user_id = v_uid), '[]'),
    'faturas',          coalesce((select jsonb_agg(f order by f.cartao_id, f.competencia) from public.faturas f where f.user_id = v_uid), '[]'),
    'compras_cartao',   coalesce((select jsonb_agg(c order by c.data_compra, c.criado_em) from public.compras c where c.user_id = v_uid), '[]'),
    'parcelas',         coalesce((select jsonb_agg(p order by p.compra_id, p.numero) from public.parcelas p where p.user_id = v_uid), '[]'),
    'importacoes',      coalesce((select jsonb_agg(i order by i.criado_em) from public.importacoes i where i.user_id = v_uid), '[]'),
    'importacao_itens', coalesce((select jsonb_agg(i order by i.importacao_id, i.ordem) from public.importacao_itens i where i.user_id = v_uid), '[]'),
    'importacoes_fatura',      coalesce((select jsonb_agg(i order by i.criado_em) from public.importacoes_fatura i where i.user_id = v_uid), '[]'),
    'importacao_fatura_itens', coalesce((select jsonb_agg(i order by i.importacao_id, i.ordem) from public.importacao_fatura_itens i where i.user_id = v_uid), '[]'),
    'documentos',       coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                                    from storage.objects o
                                   where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'),
    'auditoria',        coalesce((select jsonb_agg(a order by a.id) from public.auditoria a where a.user_id = v_uid), '[]')
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
  delete from public.auditoria               where user_id = p_user_id;
  delete from public.chaves_idempotencia     where user_id = p_user_id;
  delete from public.uso_eventos             where user_id = p_user_id;
  delete from public.limites_uso             where user_id = p_user_id;
  delete from public.importacao_fatura_itens where user_id = p_user_id;
  delete from public.pagamentos              where user_id = p_user_id;
  delete from public.parcelas                where user_id = p_user_id;
  delete from public.compras                 where user_id = p_user_id;
  delete from public.importacoes_fatura      where user_id = p_user_id;
  delete from public.faturas                 where user_id = p_user_id;
  delete from public.obrigacoes              where user_id = p_user_id;
  delete from public.recorrencias            where user_id = p_user_id;
  delete from public.importacao_itens        where user_id = p_user_id;
  delete from public.movimentos              where user_id = p_user_id;
  delete from public.importacoes             where user_id = p_user_id;
  delete from public.cartoes                 where user_id = p_user_id;
  delete from public.contas                  where user_id = p_user_id;
  delete from public.categorias              where user_id = p_user_id;
  delete from public.titulares               where user_id = p_user_id;
  delete from public.perfis                  where user_id = p_user_id;
  delete from auth.users                     where id = p_user_id;

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
revoke all on function privado.parcela_ajustar_valor(uuid, bigint) from public, anon, authenticated, service_role;
revoke all on function privado.fatura_importacao_carimbo(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.importacao_fatura_criar(uuid, text, text, text, text, integer, text, date, date, bigint, bigint, jsonb, jsonb, text) from public, anon;
revoke all on function public.importacao_fatura_confirmar(uuid, integer, jsonb, text) from public, anon;
revoke all on function public.importacao_fatura_desfazer(uuid, integer, text, text) from public, anon;
revoke all on function public.importacoes_fatura_do_cartao(uuid) from public, anon;
revoke all on function public.importacao_fatura_itens_lista(uuid) from public, anon;
grant execute on function public.importacao_fatura_criar(uuid, text, text, text, text, integer, text, date, date, bigint, bigint, jsonb, jsonb, text) to authenticated;
grant execute on function public.importacao_fatura_confirmar(uuid, integer, jsonb, text) to authenticated;
grant execute on function public.importacao_fatura_desfazer(uuid, integer, text, text) to authenticated;
grant execute on function public.importacoes_fatura_do_cartao(uuid) to authenticated;
grant execute on function public.importacao_fatura_itens_lista(uuid) to authenticated;

-- leitores de fatura homologados com arquivo real
update public.instituicoes
   set formatos_homologados = (select array(select distinct unnest(formatos_homologados || array['pdf-fatura']) order by 1))
 where codigo_compe in ('260', '341');

update public.versao_esquema set etapa = '5.3-importacao-faturas', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
