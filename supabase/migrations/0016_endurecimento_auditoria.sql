-- =====================================================================
-- Simplifica Finanças v2 — 0016 Endurecimento (itens P1 da auditoria)
--
-- Migração ADICIONAL sobre a 0015 (etapa "6.1c-desfazer-vinculo"). Não
-- apaga nada, não cria tabelas e não altera dados já gravados. Tudo
-- numa única transação.
--
--   1. privado.tabelas_do_usuario(): lista ÚNICA das tabelas com dados
--      do usuário, com a chave na exportação e a ordem de exclusão.
--      exportar_meus_dados e exclusao_concluir passam a ler essa lista
--      em vez de repetir as tabelas à mão a cada etapa. O roteiro 15
--      confere a lista contra o catálogo: uma tabela nova com user_id
--      que não entrar nela reprova a validação.
--   2. Bucket "documentos": no máximo 10 MB por arquivo (o mesmo limite
--      do site) e só PDF, OFX, CSV e texto.
--   3. Importação de fatura: a lista de pagamentos impressos na fatura
--      é conferida ao gravar. Uma entrada malformada (sem data válida,
--      valor que não é número inteiro…) quebrava depois a tela
--      "Pagamentos da fatura" e o registro desses pagamentos.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '6.1c-desfazer-vinculo') then
    raise exception 'ABORTADO: este banco não está na Etapa 6 parte 1c (0015) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- 1. Lista única das tabelas do usuário (LGPD)
-- =====================================================================
-- tabela            : nome em public (todas têm a coluna user_id)
-- chave_exportacao  : chave no JSON de exportar_meus_dados; null = não
--                     exportada (controles internos)
-- ordenar_por       : colunas da ordenação na exportação; null = objeto
--                     único em vez de lista (perfil)
-- ordem_exclusao    : ordem dos DELETEs em exclusao_concluir (filhas
--                     antes das mães, por causa das chaves estrangeiras)
--
-- Etapa nova com tabela de dados do usuário: acrescente uma linha aqui.
create or replace function privado.tabelas_do_usuario()
returns table (tabela text, chave_exportacao text, ordenar_por text, ordem_exclusao integer)
language sql immutable
set search_path = ''
as $$
  select * from (values
    ('auditoria',               'auditoria',               'id',                       1),
    ('chaves_idempotencia',     null,                      null,                       2),
    ('uso_eventos',             null,                      null,                       3),
    ('limites_uso',             null,                      null,                       4),
    ('importacao_fatura_itens', 'importacao_fatura_itens', 'importacao_id, ordem',     5),
    ('pagamentos',              'pagamentos',              'criado_em',                6),
    ('parcelas',                'parcelas',                'compra_id, numero',        7),
    ('compras',                 'compras_cartao',          'data_compra, criado_em',   8),
    ('importacoes_fatura',      'importacoes_fatura',      'criado_em',                9),
    ('faturas',                 'faturas',                 'cartao_id, competencia',  10),
    ('obrigacoes',              'contas_a_pagar',          'vencimento, criado_em',   11),
    ('recorrencias',            'recorrencias',            'criado_em',               12),
    ('importacao_itens',        'importacao_itens',        'importacao_id, ordem',    13),
    ('movimentos',              'movimentos',              'data_movimento, criado_em', 14),
    ('importacoes',             'importacoes',             'criado_em',               15),
    ('cartoes',                 'cartoes',                 'criado_em',               16),
    ('contas',                  'contas',                  'criado_em',               17),
    ('categorias',              'categorias',              'criado_em',               18),
    ('titulares',               'titulares',               'criado_em',               19),
    ('perfis',                  'perfil',                  null,                      20)
  ) as t(tabela, chave_exportacao, ordenar_por, ordem_exclusao)
$$;

create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := privado.uid_obrigatorio();
  v_res jsonb;
  v_val jsonb;
  r     record;
begin
  v_res := jsonb_build_object(
    'gerado_em',  now(),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                              from storage.objects o
                             where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'));
  for r in select * from privado.tabelas_do_usuario() where chave_exportacao is not null order by ordem_exclusao loop
    if r.ordenar_por is null then
      execute format('select to_jsonb(t) from public.%I t where t.user_id = $1', r.tabela) into v_val using v_uid;
    else
      execute format('select coalesce(jsonb_agg(t order by %s), ''[]''::jsonb) from public.%I t where t.user_id = $1', r.ordenar_por, r.tabela)
        into v_val using v_uid;
    end if;
    v_res := v_res || jsonb_build_object(r.chave_exportacao, v_val);
  end loop;
  return v_res;
end $$;

create or replace function public.exclusao_concluir(p_user_id uuid, p_arquivos_removidos integer default 0, p_espera_ms integer default 20000)
returns public.exclusoes_conta
language plpgsql security definer
set search_path = ''
as $$
declare
  v_reg      public.exclusoes_conta;
  v_restante integer;
  r          record;
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
  for r in select tabela from privado.tabelas_do_usuario() order by ordem_exclusao loop
    execute format('delete from public.%I where user_id = $1', r.tabela) using p_user_id;
  end loop;
  delete from auth.users where id = p_user_id;

  update public.exclusoes_conta
     set status = 'concluida', concluida_em = now(), atualizado_em = now(), ultimo_erro = null,
         arquivos_removidos = arquivos_removidos + coalesce(p_arquivos_removidos, 0)
   where id = v_reg.id
  returning * into v_reg;
  return v_reg;
end $$;

-- =====================================================================
-- 2. Bucket "documentos": tamanho e tipo
-- =====================================================================
-- 10 MB é o mesmo limite das telas de importação. text/plain fica
-- liberado porque alguns navegadores mandam CSV assim (e o roteiro 02
-- envia arquivos de texto). Arquivos já guardados não são afetados.
update storage.buckets
   set file_size_limit    = 10485760,
       allowed_mime_types = array['application/pdf', 'application/x-ofx', 'text/csv', 'text/plain']
 where id = 'documentos';

-- =====================================================================
-- 3. Pagamentos impressos na fatura: formato conferido ao gravar
-- =====================================================================
create or replace function privado.importacao_fatura_validar_pagamentos()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_e   jsonb;
  v_pos bigint;
begin
  if new.pagamentos is null then
    new.pagamentos := '[]'::jsonb;
  end if;
  if jsonb_typeof(new.pagamentos) <> 'array' then
    raise exception 'Os pagamentos da fatura precisam vir numa lista' using errcode = '22023';
  end if;
  if jsonb_array_length(new.pagamentos) > 200 then
    raise exception 'Fatura com pagamentos demais: no máximo 200' using errcode = '22023';
  end if;
  for v_e, v_pos in select e.v, e.n from jsonb_array_elements(new.pagamentos) with ordinality as e(v, n) loop
    if jsonb_typeof(v_e) is distinct from 'object'
       or jsonb_typeof(v_e -> 'data') is distinct from 'string'
       or (v_e ->> 'data') !~ '^\d{4}-\d{2}-\d{2}$'
       or jsonb_typeof(v_e -> 'descricao') is distinct from 'string'
       or length(v_e ->> 'descricao') > 500
       or jsonb_typeof(v_e -> 'valor_centavos') is distinct from 'number'
       or (v_e ->> 'valor_centavos') !~ '^-?\d{1,15}$' then
      raise exception 'Pagamento nº % da fatura em formato inválido: precisa de data (AAAA-MM-DD), descrição e valor em centavos (número inteiro)', v_pos
        using errcode = '22023';
    end if;
    begin
      perform (v_e ->> 'data')::date;
    exception when others then
      raise exception 'Pagamento nº % da fatura com data inexistente (%)', v_pos, v_e ->> 'data' using errcode = '22023';
    end;
  end loop;
  return new;
end $$;

drop trigger if exists importacoes_fatura_validar_pagamentos on public.importacoes_fatura;
create trigger importacoes_fatura_validar_pagamentos
  before insert or update of pagamentos on public.importacoes_fatura
  for each row execute function privado.importacao_fatura_validar_pagamentos();

-- =====================================================================
-- Permissões das funções NOVAS (as substituídas mantêm as de antes)
-- =====================================================================
revoke all on function privado.tabelas_do_usuario() from public, anon, authenticated, service_role;
revoke all on function privado.importacao_fatura_validar_pagamentos() from public, anon, authenticated, service_role;

update public.versao_esquema set etapa = '6.1d-endurecimento', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
