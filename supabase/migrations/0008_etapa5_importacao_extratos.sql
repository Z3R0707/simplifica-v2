-- =====================================================================
-- Simplifica Finanças v2 — 0008 Etapa 5 (parte 1): importação de extratos
--
-- Migração ADICIONAL sobre a 0007 (etapa "4-cartoes"). Não apaga nem
-- recria nada. Tudo numa única transação.
--
-- FLUXO
--   1. O site lê o arquivo (OFX ou CSV), guarda o ORIGINAL no Storage
--      (documentos/<usuário>/importacoes/<sha256>.<ext>) e chama
--      importacao_criar com os itens lidos.
--   2. O banco monta a PRÉVIA: para cada item calcula a chave de
--      deduplicação e uma sugestão (novo, já importado, possível
--      duplicado, anterior ao saldo inicial, data futura). Nada entra no
--      saldo ainda.
--   3. O usuário revisa (incluir/excluir, categoria, descrição) e
--      confirma: importacao_confirmar cria os lançamentos.
--   4. Uma importação confirmada pode ser desfeita: os lançamentos
--      criados por ela são cancelados (nada é apagado).
--
-- DUPLICIDADE
--   * Arquivo igual (mesmo SHA-256) não é importado duas vezes.
--   * Cada lançamento importado guarda uma chave: o identificador do
--     banco (FITID) quando existe; senão data + valor + descrição + nº da
--     ocorrência no arquivo (duas compras iguais no mesmo dia continuam
--     sendo duas). Um índice único impede a mesma chave duas vezes na
--     mesma conta, inclusive em importações simultâneas e em períodos
--     sobrepostos.
--   * Lançamento parecido já existente (mesmo valor, até 3 dias de
--     diferença, sem a mesma chave) vira "possível duplicado": não entra
--     sozinho, o usuário decide. Nada legítimo é descartado sem ele ver.
--
-- Nenhum leitor de banco é marcado como homologado aqui: o leitor OFX e
-- o CSV são genéricos. Homologação por banco só com arquivo real.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '4-cartoes') then
    raise exception 'ABORTADO: este banco não está na Etapa 4 (0007) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- Descrição normalizada para comparar (minúsculas, sem acento, espaços únicos)
create or replace function privado.normalizar_descricao(p text)
returns text
language sql immutable
set search_path = ''
as $$
  select regexp_replace(btrim(translate(lower(coalesce(p, '')),
           'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g');
$$;

-- =====================================================================
-- TABELAS
-- =====================================================================
create table public.importacoes (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users (id) on delete cascade,
  tipo                  text not null default 'extrato' check (tipo in ('extrato')),
  conta_id              uuid not null,
  formato               text not null check (formato in ('ofx', 'csv')),
  leitor                text not null check (length(leitor) between 1 and 60),
  arquivo_nome          text not null check (length(arquivo_nome) between 1 and 200),
  arquivo_hash          text not null check (arquivo_hash ~ '^[0-9a-f]{64}$'),
  arquivo_caminho       text not null check (length(arquivo_caminho) between 1 and 400),
  arquivo_tamanho       integer not null check (arquivo_tamanho between 1 and 10485760),
  banco_no_arquivo      text,
  conta_no_arquivo      text,
  periodo_inicio        date,
  periodo_fim           date,
  saldo_informado_centavos bigint,
  saldo_informado_data  date,
  situacao              text not null default 'previa' check (situacao in ('previa', 'confirmada', 'cancelada')),
  itens_total           integer not null default 0,
  itens_importados      integer not null default 0,
  itens_duplicados      integer not null default 0,
  itens_ignorados       integer not null default 0,
  cancelada_motivo      text,
  confirmada_em         timestamptz,
  cancelada_em          timestamptz,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  versao                integer not null default 1,
  unique (id, user_id),
  foreign key (conta_id, user_id) references public.contas (id, user_id),
  check ((situacao = 'cancelada') = (cancelada_em is not null)),
  check ((saldo_informado_centavos is null) = (saldo_informado_data is null))
);
-- o mesmo arquivo não entra duas vezes (a não ser que a anterior tenha sido desfeita)
create unique index importacoes_arquivo_unico on public.importacoes (user_id, arquivo_hash) where situacao <> 'cancelada';
create index importacoes_conta_idx on public.importacoes (user_id, conta_id, criado_em desc);
alter table public.importacoes enable row level security;
create policy importacoes_select on public.importacoes for select to authenticated using (user_id = auth.uid());
grant select on public.importacoes to authenticated;
select privado.aplicar_gatilhos_padrao('public.importacoes');

-- Movimentos: de qual importação vieram e a chave de deduplicação
alter table public.movimentos add column importacao_id uuid,
                              add column chave_importacao text check (length(chave_importacao) between 3 and 300);
alter table public.movimentos add constraint movimentos_importacao_fk foreign key (importacao_id, user_id) references public.importacoes (id, user_id);
create unique index movimentos_chave_importacao_unica on public.movimentos (user_id, conta_id, chave_importacao)
  where chave_importacao is not null and situacao <> 'cancelado';

create table public.importacao_itens (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  importacao_id      uuid not null,
  ordem              integer not null,
  data               date not null,
  data_operacao      date,
  descricao_original text not null,
  descricao          text not null check (length(btrim(descricao)) between 1 and 200),
  valor_centavos     bigint not null check (valor_centavos <> 0 and abs(valor_centavos) <= 10000000000000),
  identificador      text check (length(identificador) <= 120),
  documento          text check (length(documento) <= 60),
  chave              text not null,
  sugestao           text not null check (sugestao in ('novo', 'ja_importado', 'possivel_duplicado', 'antes_data_base', 'data_futura', 'repetido_no_arquivo')),
  parecido_com       uuid,
  incluir            boolean not null,
  classificacao      text not null default 'nao_classificado' check (classificacao in ('receita', 'despesa', 'nao_classificado', 'pagamento_fatura')),
  categoria_id       uuid,
  situacao           text not null default 'pendente' check (situacao in ('pendente', 'importado', 'duplicado', 'ignorado')),
  movimento_id       uuid,
  unique (id, user_id),
  unique (importacao_id, ordem),
  foreign key (importacao_id, user_id) references public.importacoes (id, user_id),
  foreign key (categoria_id, user_id) references public.categorias (id, user_id),
  foreign key (movimento_id, user_id) references public.movimentos (id, user_id),
  foreign key (parecido_com, user_id) references public.movimentos (id, user_id),
  check ((classificacao in ('nao_classificado', 'pagamento_fatura')) = (categoria_id is null))
);
alter table public.importacao_itens enable row level security;
create policy importacao_itens_select on public.importacao_itens for select to authenticated using (user_id = auth.uid());
grant select on public.importacao_itens to authenticated;

-- =====================================================================
-- RPC: criar a prévia
-- p_itens: lista JSON de {data, data_operacao?, descricao, valor_centavos
-- (positivo = entrou, negativo = saiu), identificador?, documento?}
-- =====================================================================
create or replace function public.importacao_criar(
  p_conta_id                 uuid,
  p_formato                  text,
  p_leitor                   text,
  p_arquivo_nome             text,
  p_arquivo_hash             text,
  p_arquivo_caminho          text,
  p_arquivo_tamanho          integer,
  p_banco_no_arquivo         text,
  p_conta_no_arquivo         text,
  p_saldo_informado_centavos bigint,
  p_saldo_informado_data     date,
  p_itens                    jsonb,
  p_chave_idempotencia       text
)
returns public.importacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid    uuid := privado.uid_para_escrita();
  v_prev   jsonb;
  v_conta  public.contas;
  v_reg    public.importacoes;
  v_outra  public.importacoes;
  v_n      integer;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_criar', jsonb_build_object(
    'conta_id', p_conta_id, 'hash', p_arquivo_hash, 'itens', p_itens, 'saldo', p_saldo_informado_centavos, 'saldo_data', p_saldo_informado_data));
  if v_prev is not null then return jsonb_populate_record(null::public.importacoes, v_prev); end if;

  select * into v_conta from public.contas where id = p_conta_id and user_id = v_uid for share;
  if not found then
    raise exception 'Conta não encontrada' using errcode = 'P0002';
  end if;
  if not v_conta.ativa then
    raise exception 'Conta arquivada não recebe importação' using errcode = '22023';
  end if;
  if p_arquivo_caminho is null or split_part(p_arquivo_caminho, '/', 1) <> v_uid::text then
    raise exception 'O arquivo original precisa estar na sua pasta' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documentos' and o.name = p_arquivo_caminho) then
    raise exception 'O arquivo original não foi guardado; envie o arquivo de novo' using errcode = '22023';
  end if;
  select * into v_outra from public.importacoes where user_id = v_uid and arquivo_hash = p_arquivo_hash and situacao <> 'cancelada';
  if found then
    raise exception 'Este arquivo já foi importado em % (%). Para importar de novo, desfaça a importação anterior.',
      to_char(v_outra.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY'),
      case when v_outra.situacao = 'previa' then 'prévia ainda não confirmada' else 'confirmada' end using errcode = '22023';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O arquivo não tem lançamentos para importar' using errcode = '22023';
  end if;
  if jsonb_array_length(p_itens) > 5000 then
    raise exception 'Arquivo grande demais: no máximo 5.000 lançamentos por importação' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) e
              where (e ->> 'data') is null or (e ->> 'valor_centavos') is null or (e ->> 'valor_centavos')::bigint = 0
                 or length(btrim(coalesce(e ->> 'descricao', ''))) = 0) then
    raise exception 'Há linhas sem data, sem descrição ou com valor zero: revise o arquivo ou o mapeamento das colunas' using errcode = '22023';
  end if;

  insert into public.importacoes (user_id, conta_id, formato, leitor, arquivo_nome, arquivo_hash, arquivo_caminho, arquivo_tamanho,
                                  banco_no_arquivo, conta_no_arquivo, saldo_informado_centavos, saldo_informado_data)
  values (v_uid, v_conta.id, p_formato, left(p_leitor, 60), left(btrim(p_arquivo_nome), 200), p_arquivo_hash, p_arquivo_caminho,
          p_arquivo_tamanho, left(p_banco_no_arquivo, 30), left(p_conta_no_arquivo, 40), p_saldo_informado_centavos, p_saldo_informado_data)
  returning * into v_reg;

  insert into public.importacao_itens (user_id, importacao_id, ordem, data, data_operacao, descricao_original, descricao, valor_centavos,
                                       identificador, documento, chave, sugestao, incluir)
  select v_uid, v_reg.id, x.ordem, x.data, x.data_operacao, x.descricao, left(x.descricao, 200), x.valor, x.identificador, x.documento,
         case when x.identificador is not null then 'id:' || x.identificador
              else 'h:' || md5(x.data::text || '|' || x.valor || '|' || privado.normalizar_descricao(x.descricao))
                   || ':' || row_number() over (partition by x.data, x.valor, privado.normalizar_descricao(x.descricao) order by x.ordem) end,
         'novo', true
    from (
      select (e.ord)::int as ordem, (e.v ->> 'data')::date as data, nullif(e.v ->> 'data_operacao', '')::date as data_operacao,
             btrim(e.v ->> 'descricao') as descricao, (e.v ->> 'valor_centavos')::bigint as valor,
             nullif(btrim(e.v ->> 'identificador'), '') as identificador, nullif(btrim(e.v ->> 'documento'), '') as documento
        from jsonb_array_elements(p_itens) with ordinality as e(v, ord)
    ) x;

  -- sugestões (a ordem importa: a primeira que se aplica vale)
  update public.importacao_itens i set sugestao = 'repetido_no_arquivo', incluir = false
   where i.importacao_id = v_reg.id
     and exists (select 1 from public.importacao_itens j where j.importacao_id = v_reg.id and j.chave = i.chave and j.ordem < i.ordem);
  update public.importacao_itens i set sugestao = 'ja_importado', incluir = false,
         parecido_com = (select m.id from public.movimentos m where m.user_id = v_uid and m.conta_id = v_conta.id
                          and m.chave_importacao = i.chave and m.situacao <> 'cancelado' limit 1)
   where i.importacao_id = v_reg.id and i.sugestao = 'novo'
     and exists (select 1 from public.movimentos m where m.user_id = v_uid and m.conta_id = v_conta.id
                  and m.chave_importacao = i.chave and m.situacao <> 'cancelado');
  update public.importacao_itens i set sugestao = 'data_futura', incluir = false
   where i.importacao_id = v_reg.id and i.sugestao = 'novo' and i.data > privado.hoje();
  update public.importacao_itens i set sugestao = 'antes_data_base', incluir = false
   where i.importacao_id = v_reg.id and i.sugestao = 'novo' and i.data <= v_conta.saldo_inicial_data;
  update public.importacao_itens i set sugestao = 'possivel_duplicado', incluir = false,
         parecido_com = (select m.id from public.movimentos m
                          where m.user_id = v_uid and m.conta_id = v_conta.id and m.situacao <> 'cancelado'
                            and m.valor_assinado_centavos = i.valor_centavos and abs(m.data_movimento - i.data) <= 3
                            and m.chave_importacao is distinct from i.chave
                          order by abs(m.data_movimento - i.data), m.criado_em limit 1)
   where i.importacao_id = v_reg.id and i.sugestao = 'novo'
     and exists (select 1 from public.movimentos m
                  where m.user_id = v_uid and m.conta_id = v_conta.id and m.situacao <> 'cancelado'
                    and m.valor_assinado_centavos = i.valor_centavos and abs(m.data_movimento - i.data) <= 3
                    and m.chave_importacao is distinct from i.chave);
  -- categoria sugerida: a do lançamento mais recente com a mesma descrição e o mesmo sentido
  update public.importacao_itens i set (classificacao, categoria_id) = (
      select m.classificacao, m.categoria_id from public.movimentos m
       where m.user_id = v_uid and m.situacao <> 'cancelado' and m.categoria_id is not null
         and privado.normalizar_descricao(m.descricao) = privado.normalizar_descricao(i.descricao)
         and sign(m.valor_assinado_centavos) = sign(i.valor_centavos)
         and exists (select 1 from public.categorias c where c.id = m.categoria_id and c.ativa)
       order by m.data_movimento desc, m.criado_em desc limit 1)
   where i.importacao_id = v_reg.id
     and exists (select 1 from public.movimentos m
                  where m.user_id = v_uid and m.situacao <> 'cancelado' and m.categoria_id is not null
                    and privado.normalizar_descricao(m.descricao) = privado.normalizar_descricao(i.descricao)
                    and sign(m.valor_assinado_centavos) = sign(i.valor_centavos)
                    and exists (select 1 from public.categorias c where c.id = m.categoria_id and c.ativa));

  select count(*) into v_n from public.importacao_itens where importacao_id = v_reg.id;
  update public.importacoes set itens_total = v_n,
         periodo_inicio = (select min(data) from public.importacao_itens where importacao_id = v_reg.id),
         periodo_fim = (select max(data) from public.importacao_itens where importacao_id = v_reg.id)
   where id = v_reg.id
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- RPC: confirmar. p_ajustes: lista JSON de {id, incluir, classificacao,
-- categoria_id, descricao} com o que o usuário mudou na prévia.
-- =====================================================================
create or replace function public.importacao_confirmar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_ajustes             jsonb,
  p_chave_idempotencia  text
)
returns public.importacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_para_escrita();
  v_prev  jsonb;
  v_reg   public.importacoes;
  v_i     public.importacao_itens;
  v_mov   uuid;
  v_imp   integer := 0;
  v_dup   integer := 0;
  v_ign   integer := 0;
  v_cat   record;
begin
  perform privado.exigir_versao(p_versao_esperada);
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_confirmar',
              jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'ajustes', p_ajustes));
  if v_prev is not null then return jsonb_populate_record(null::public.importacoes, v_prev); end if;

  select * into v_reg from public.importacoes where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'Importação não encontrada' using errcode = 'P0002';
  end if;
  if v_reg.situacao <> 'previa' then
    raise exception 'Esta importação já foi % ', case when v_reg.situacao = 'confirmada' then 'confirmada' else 'descartada' end using errcode = '22023';
  end if;
  if v_reg.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.importacoes', p_id, v_uid);
  end if;

  -- ajustes da prévia
  if p_ajustes is not null and jsonb_typeof(p_ajustes) = 'array' then
    update public.importacao_itens i set
      incluir = coalesce((a.v ->> 'incluir')::boolean, i.incluir),
      descricao = coalesce(nullif(left(btrim(a.v ->> 'descricao'), 200), ''), i.descricao),
      classificacao = case when a.v ? 'classificacao' then coalesce(a.v ->> 'classificacao', 'nao_classificado') else i.classificacao end,
      categoria_id = case when a.v ? 'classificacao' then nullif(a.v ->> 'categoria_id', '')::uuid else i.categoria_id end
      from jsonb_array_elements(p_ajustes) a(v)
     where i.importacao_id = v_reg.id and i.id = (a.v ->> 'id')::uuid;
  end if;

  for v_i in select * from public.importacao_itens where importacao_id = v_reg.id order by ordem loop
    if not v_i.incluir or v_i.sugestao in ('repetido_no_arquivo', 'data_futura') then
      update public.importacao_itens set situacao = 'ignorado' where id = v_i.id;
      v_ign := v_ign + 1;
      continue;
    end if;
    -- categoria precisa combinar com a classificação e estar ativa; senão fica sem categoria
    if v_i.categoria_id is not null then
      select tipo, ativa into v_cat from public.categorias where id = v_i.categoria_id and user_id = v_uid;
      if not found or not v_cat.ativa or v_cat.tipo <> v_i.classificacao then
        v_i.categoria_id := null;
        v_i.classificacao := 'nao_classificado';
      end if;
    end if;
    v_mov := null;
    insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao, categoria_id,
                                   situacao, origem, observacao, importacao_id, chave_importacao)
    values (v_uid, v_reg.conta_id, case when v_i.valor_centavos > 0 then 'credito' else 'debito' end, abs(v_i.valor_centavos),
            v_i.data, v_i.descricao, v_i.classificacao, v_i.categoria_id, 'efetivo', 'importacao',
            case when v_i.descricao <> left(v_i.descricao_original, 200) then left('No arquivo: ' || v_i.descricao_original, 500) end,
            v_reg.id, v_i.chave)
    on conflict (user_id, conta_id, chave_importacao) where chave_importacao is not null and situacao <> 'cancelado' do nothing
    returning id into v_mov;
    if v_mov is null then
      update public.importacao_itens set situacao = 'duplicado' where id = v_i.id;
      v_dup := v_dup + 1;
    else
      update public.importacao_itens set situacao = 'importado', movimento_id = v_mov,
             classificacao = v_i.classificacao, categoria_id = v_i.categoria_id where id = v_i.id;
      v_imp := v_imp + 1;
    end if;
  end loop;

  update public.importacoes set situacao = 'confirmada', confirmada_em = now(),
         itens_importados = v_imp, itens_duplicados = v_dup, itens_ignorados = v_ign
   where id = v_reg.id
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- Descartar a prévia ou desfazer a importação confirmada (cancela os
-- lançamentos criados por ela; recusa se algum paga conta ou tem
-- cancelamento parcial — desfaça isso antes).
create or replace function public.importacao_desfazer(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_motivo              text,
  p_chave_idempotencia  text default null
)
returns public.importacoes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.importacoes;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'importacao_desfazer',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo));
    if v_prev is not null then return jsonb_populate_record(null::public.importacoes, v_prev); end if;
  end if;
  select * into v_reg from public.importacoes where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'Importação não encontrada' using errcode = 'P0002';
  end if;
  if v_reg.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.importacoes', p_id, v_uid);
  end if;
  if v_reg.situacao = 'cancelada' then
    raise exception 'Esta importação já foi desfeita' using errcode = '22023';
  end if;
  perform set_config('app.motivo', btrim(p_motivo), true);
  if v_reg.situacao = 'confirmada' then
    -- os gatilhos recusam se algum lançamento pagar conta ou tiver cancelamento parcial ativo
    update public.movimentos set situacao = 'cancelado', cancelado_motivo = left('Importação desfeita: ' || btrim(p_motivo), 500), cancelado_em = now()
     where importacao_id = v_reg.id and user_id = v_uid and situacao <> 'cancelado';
  end if;
  update public.importacoes set situacao = 'cancelada', cancelada_motivo = btrim(p_motivo), cancelada_em = now()
   where id = v_reg.id
  returning * into v_reg;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- =====================================================================
-- CONSULTAS
-- =====================================================================
-- Importações de uma conta, com a conferência de saldo: saldo informado
-- no arquivo × saldo calculado pelo Simplifica na mesma data.
create or replace function public.importacoes_da_conta(p_conta_id uuid)
returns table (
  importacao_id             uuid,
  arquivo_nome              text,
  formato                   text,
  leitor                    text,
  situacao                  text,
  periodo_inicio            date,
  periodo_fim               date,
  itens_total               integer,
  itens_importados          integer,
  itens_duplicados          integer,
  itens_ignorados           integer,
  saldo_informado_centavos  bigint,
  saldo_informado_data      date,
  saldo_calculado_centavos  bigint,
  sobreposta_a              integer,
  criado_em                 timestamptz,
  cancelada_motivo          text,
  versao                    integer
)
language sql stable security invoker
set search_path = ''
as $$
  select i.id, i.arquivo_nome, i.formato, i.leitor, i.situacao, i.periodo_inicio, i.periodo_fim,
         i.itens_total, i.itens_importados, i.itens_duplicados, i.itens_ignorados,
         i.saldo_informado_centavos, i.saldo_informado_data,
         case when i.saldo_informado_data is not null then
           (select s.saldo_confirmado_centavos from public.saldos_por_conta(i.saldo_informado_data) s where s.conta_id = i.conta_id) end,
         (select count(*) from public.importacoes o
           where o.conta_id = i.conta_id and o.id <> i.id and o.situacao = 'confirmada'
             and o.periodo_inicio <= i.periodo_fim and o.periodo_fim >= i.periodo_inicio)::int,
         i.criado_em, i.cancelada_motivo, i.versao
    from public.importacoes i
   where i.user_id = auth.uid() and i.conta_id = p_conta_id
   order by i.criado_em desc;
$$;

-- Itens de uma importação (prévia ou resultado)
create or replace function public.importacao_itens_lista(p_importacao_id uuid)
returns table (
  item_id            uuid,
  ordem              integer,
  data               date,
  descricao          text,
  descricao_original text,
  valor_centavos     bigint,
  identificador      text,
  sugestao           text,
  parecido_data      date,
  parecido_descricao text,
  incluir            boolean,
  classificacao      text,
  categoria_id       uuid,
  situacao           text,
  movimento_id       uuid
)
language sql stable security invoker
set search_path = ''
as $$
  select it.id, it.ordem, it.data, it.descricao, it.descricao_original, it.valor_centavos, it.identificador, it.sugestao,
         m.data_movimento, m.descricao, it.incluir, it.classificacao, it.categoria_id, it.situacao, it.movimento_id
    from public.importacao_itens it
    left join public.movimentos m on m.id = it.parecido_com
   where it.user_id = auth.uid() and it.importacao_id = p_importacao_id
   order by it.ordem;
$$;

-- =====================================================================
-- LGPD: exportação e exclusão incluem as importações
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
  delete from public.importacao_itens    where user_id = p_user_id;
  delete from public.movimentos          where user_id = p_user_id;
  delete from public.importacoes         where user_id = p_user_id;
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
revoke all on function privado.normalizar_descricao(text) from public, anon, authenticated, service_role;
revoke all on function public.importacao_criar(uuid, text, text, text, text, text, integer, text, text, bigint, date, jsonb, text) from public, anon;
revoke all on function public.importacao_confirmar(uuid, integer, jsonb, text) from public, anon;
revoke all on function public.importacao_desfazer(uuid, integer, text, text) from public, anon;
revoke all on function public.importacoes_da_conta(uuid) from public, anon;
revoke all on function public.importacao_itens_lista(uuid) from public, anon;
grant execute on function public.importacao_criar(uuid, text, text, text, text, text, integer, text, text, bigint, date, jsonb, text) to authenticated;
grant execute on function public.importacao_confirmar(uuid, integer, jsonb, text) to authenticated;
grant execute on function public.importacao_desfazer(uuid, integer, text, text) to authenticated;
grant execute on function public.importacoes_da_conta(uuid) to authenticated;
grant execute on function public.importacao_itens_lista(uuid) to authenticated;

update public.versao_esquema set etapa = '5.1-importacao-extratos', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
