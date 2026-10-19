-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DO ENDURECIMENTO NO SUPABASE (0016)
--   1. lista única das tabelas do usuário (exportação e exclusão)
--   2. limite de tamanho e tipo no bucket "documentos"
--   3. formato dos pagamentos impressos na fatura importada
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa as verificações e no fim
-- DESFAZ TUDO (rollback). Nada fica gravado e nenhum dado real é tocado.
--
-- O resultado aparece como uma mensagem de "erro" — é proposital: é o
-- erro final que obriga o banco a desfazer os testes.
--   "VALIDAÇÃO APROVADA ..."  → tudo certo
--   "VALIDAÇÃO REPROVADA ..." → copie a mensagem inteira e me envie
--
-- Recusa rodar em qualquer banco que não seja o do Simplifica v2.
-- =====================================================================
do $validacao$
declare
  v_suf      text := left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_email_a  text := 'validacao15-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao15-b-' || v_suf || '@teste.invalid';
  -- importação de uma fatura de 1 lançamento; %L = dígito do arquivo,
  -- %s = pagamentos (expressão SQL), %L = chave de idempotência
  v_criar    text := $t$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat(%1$L, 64), current_setting('val.a') || '/importacoes/' || repeat(%1$L, 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 1000, null, '[{"data": "2026-09-20", "descricao": "Loja validação", "valor_centavos": 1000, "tipo": "compra"}]', %2$s, %3$L)).id::text$t$;
  c          record;
  v_res      text;
  v_uid      text;
  v_ok       integer := 0;
  v_falhas   text[] := '{}';
  v_total    integer := 0;
begin
  if to_regclass('public.versao_esquema') is null then
    raise exception 'ABORTADO: este banco não é o do Simplifica v2. Nenhuma verificação foi executada.';
  end if;
  execute $$select count(*)::text from public.versao_esquema where sistema = 'simplifica-v2'$$ into v_res;
  if v_res <> '1' then
    raise exception 'ABORTADO: este banco não é o do Simplifica v2. Nenhuma verificação foi executada.';
  end if;
  execute $$select etapa from public.versao_esquema where sistema = 'simplifica-v2'$$ into v_res;
  if v_res is null or v_res < '6.1d-endurecimento' then
    raise exception 'ABORTADO: o endurecimento (0016) ainda não está instalado (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1d ou posterior', 'pg', 'valor', $$select (etapa >= '6.1d-endurecimento')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'toda tabela com user_id está na lista única (exceto exclusoes_conta) e vice-versa', 'pg', 'valor', $$select coalesce(string_agg(x, ', ' order by x), 'ok') from (
        (select c.table_name::text as x
           from information_schema.columns c
           join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
          where c.table_schema = 'public' and c.column_name = 'user_id' and t.table_type = 'BASE TABLE' and c.table_name <> 'exclusoes_conta'
         except select tabela from privado.tabelas_do_usuario())
        union all
        (select l.tabela || ' (na lista, sem user_id)' from privado.tabelas_do_usuario() l
          where l.tabela not in (select c.table_name from information_schema.columns c where c.table_schema = 'public' and c.column_name = 'user_id'))
      ) d$$, 'ok'),
    (3, 'ordem de exclusão sem repetição e chaves de exportação sem repetição', 'pg', 'valor', $$select (count(distinct ordem_exclusao) = count(*) and count(distinct chave_exportacao) = count(chave_exportacao))::text from privado.tabelas_do_usuario()$$, 'true'),
    (4, 'filhas apagadas antes das mães (itens, parcelas e compras antes de faturas; movimentos antes de contas)', 'pg', 'valor', $$select ((j ->> 'importacao_fatura_itens')::int < (j ->> 'compras')::int and (j ->> 'parcelas')::int < (j ->> 'compras')::int
        and (j ->> 'compras')::int < (j ->> 'importacoes_fatura')::int and (j ->> 'importacoes_fatura')::int < (j ->> 'faturas')::int
        and (j ->> 'pagamentos')::int < (j ->> 'obrigacoes')::int and (j ->> 'faturas')::int < (j ->> 'obrigacoes')::int
        and (j ->> 'pagamentos')::int < (j ->> 'movimentos')::int and (j ->> 'importacao_itens')::int < (j ->> 'movimentos')::int
        and (j ->> 'movimentos')::int < (j ->> 'importacoes')::int and (j ->> 'movimentos')::int < (j ->> 'contas')::int
        and (j ->> 'faturas')::int < (j ->> 'cartoes')::int and (j ->> 'contas')::int < (j ->> 'titulares')::int)::text
        from (select jsonb_object_agg(tabela, ordem_exclusao) as j from privado.tabelas_do_usuario()) x$$, 'true'),
    (5, 'lista única: ninguém além do banco executa', 'pg', 'valor', $$select has_function_privilege('authenticated', 'privado.tabelas_do_usuario()', 'execute')::text || ' ' || has_function_privilege('anon', 'privado.tabelas_do_usuario()', 'execute')::text || ' ' || has_function_privilege('service_role', 'privado.tabelas_do_usuario()', 'execute')::text$$, 'false false false'),
    (6, 'exportar_meus_dados: search_path vazio e permissões de antes', 'pg', 'valor', $$select (prosecdef and proconfig = array['search_path=""'])::text || ' ' || has_function_privilege('authenticated', oid, 'execute')::text || ' ' || has_function_privilege('anon', oid, 'execute')::text from pg_proc where oid = 'public.exportar_meus_dados()'::regprocedure$$, 'true true false'),
    (7, 'exclusao_concluir: search_path vazio e só o servidor executa', 'pg', 'valor', $$select (prosecdef and proconfig = array['search_path=""'])::text || ' ' || has_function_privilege('service_role', oid, 'execute')::text || ' ' || has_function_privilege('authenticated', oid, 'execute')::text from pg_proc where oid = 'public.exclusao_concluir(uuid,integer,integer)'::regprocedure$$, 'true true false'),
    (8, 'bucket documentos: até 10 MB, só PDF, OFX, CSV e texto', 'pg', 'valor', $$select file_size_limit::text || ' ' || array_to_string(allowed_mime_types, ',') from storage.buckets where id = 'documentos'$$, '10485760 application/pdf,application/x-ofx,text/csv,text/plain'),
    (9, 'bucket documentos continua privado', 'pg', 'valor', $$select public::text from storage.buckets where id = 'documentos'$$, 'false'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 15"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'gatilho dos pagamentos instalado na importação de fatura', 'pg', 'valor', $$select count(*)::text from pg_trigger where tgrelid = 'public.importacoes_fatura'::regclass and tgname = 'importacoes_fatura_validar_pagamentos' and not tgisinternal$$, '1'),

    -- 3. pagamentos impressos na fatura
    (20, 'A guarda o PDF da fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf') returning name$$, null),
    (21, 'A guarda um segundo PDF', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('2', 64) || '.pdf') returning name$$, null),
    (22, 'A cadastra o cartão Nubank (fecha 7, vence 14)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Nubank validação', null, null, 7, 14, null, 'validacao15-cartao')).id::text$$, 'cartao'),
    (23, 'pagamento que não é objeto: recusado', 'A', 'erro', format(v_criar, '1', $j$'[1]'$j$, 'validacao15-e1'), '22023'),
    (24, 'pagamento com data inexistente (30/02): recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "2026-02-30", "descricao": "Pagamento", "valor_centavos": -1000}]'$j$, 'validacao15-e2'), '22023'),
    (25, 'pagamento com data em outro formato (07/10/2026): recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "07/10/2026", "descricao": "Pagamento", "valor_centavos": -1000}]'$j$, 'validacao15-e3'), '22023'),
    (26, 'pagamento com valor em texto: recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "2026-10-07", "descricao": "Pagamento", "valor_centavos": "-1000"}]'$j$, 'validacao15-e4'), '22023'),
    (27, 'pagamento com fração de centavo: recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "2026-10-07", "descricao": "Pagamento", "valor_centavos": -10.5}]'$j$, 'validacao15-e5'), '22023'),
    (28, 'pagamento sem descrição: recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "2026-10-07", "valor_centavos": -1000}]'$j$, 'validacao15-e6'), '22023'),
    (29, 'pagamento sem valor: recusado', 'A', 'erro', format(v_criar, '1', $j$'[{"data": "2026-10-07", "descricao": "Pagamento"}]'$j$, 'validacao15-e7'), '22023'),
    (30, 'mais de 200 pagamentos: recusado', 'A', 'erro', format(v_criar, '1', $j$(select jsonb_agg(jsonb_build_object('data', '2026-10-07', 'descricao', 'Pagamento', 'valor_centavos', -1)) from generate_series(1, 201))$j$, 'validacao15-e8'), '22023'),
    (31, 'fatura com 2 pagamentos bem formados: aceita', 'A', 'ok', format(v_criar, '1', $j$'[{"data": "2026-10-07", "descricao": "Pagamento em 07 OUT", "valor_centavos": -50000}, {"data": "2026-10-01", "descricao": "Saldo restante", "valor_centavos": 1}]'$j$, 'validacao15-ok1'), 'imp'),
    (32, 'os 2 pagamentos ficaram gravados', 'A', 'valor', $$select jsonb_array_length(pagamentos)::text from public.importacoes_fatura where id = current_setting('val.imp')::uuid$$, '2'),
    (33, 'fatura sem pagamentos (null): aceita, com lista vazia', 'A', 'ok', format(v_criar, '2', 'null', 'validacao15-ok2'), 'imp2'),
    (34, 'lista vazia gravada', 'A', 'valor', $$select pagamentos::text from public.importacoes_fatura where id = current_setting('val.imp2')::uuid$$, '[]'),
    (35, 'a tela "Pagamentos da fatura" lê a prévia sem erro', 'A', 'valor', $$select count(*)::text from public.importacao_fatura_pagamentos(current_setting('val.imp')::uuid)$$, '0'),
    (36, 'gravação direta de pagamentos fora de lista: recusada', 'pg', 'erro', $$update public.importacoes_fatura set pagamentos = '{"a": 1}' where id = current_setting('val.imp')::uuid returning id::text$$, '22023'),
    (37, 'gravação direta de pagamento malformado: recusada', 'pg', 'erro', $$update public.importacoes_fatura set pagamentos = '[{"data": "x"}]' where id = current_setting('val.imp')::uuid returning id::text$$, '22023'),
    (38, 'alterar outra coluna não passa pelo gatilho', 'pg', 'valor', $$update public.importacoes_fatura set arquivo_nome = arquivo_nome where id = current_setting('val.imp')::uuid returning 'ok'$$, 'ok'),
    (39, 'usuário não grava direto na tabela', 'A', 'erro', $$update public.importacoes_fatura set pagamentos = '[]' where id = current_setting('val.imp')::uuid returning id::text$$, '42501'),

    -- 1. exportação e exclusão pela lista única
    (40, 'B cadastra uma conta no Itaú', 'B', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Itaú validação', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'validacao15-conta')).id::text$$, 'itau'),
    (41, 'B lança uma despesa', 'B', 'ok', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'debito', 5000, '2026-10-11', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao15-mov')).id::text$$, null),
    (42, 'B cadastra um cartão', 'B', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Cartão validação', null, null, 3, 10, current_setting('val.itau')::uuid, 'validacao15-cartao-b')).id::text$$, 'cartao_b'),
    (43, 'B faz uma compra à vista', 'B', 'ok', $$select (public.compra_criar(current_setting('val.cartao_b')::uuid, 'compra', null, '2026-10-02', 'Loja', null, 30000, 1, null, 1, null, null, 'validacao15-compra')).id::text$$, null),
    (44, 'exportação de B tem as 19 chaves de antes', 'B', 'valor', $$select (select count(*) from jsonb_object_keys(d))::text || ' ' || (d ?& array['gerado_em', 'perfil', 'titulares', 'contas', 'categorias', 'movimentos', 'recorrencias', 'contas_a_pagar', 'pagamentos', 'cartoes', 'faturas', 'compras_cartao', 'parcelas', 'importacoes', 'importacao_itens', 'importacoes_fatura', 'importacao_fatura_itens', 'documentos', 'auditoria'])::text from (select public.exportar_meus_dados() as d) x$$, '19 true'),
    (45, 'exportação de B traz os dados dele', 'B', 'valor', $$select ((d -> 'perfil' ->> 'id') = current_setting('val.b') and jsonb_typeof(d -> 'perfil') = 'object'
        and jsonb_array_length(d -> 'contas') = 1 and jsonb_array_length(d -> 'movimentos') = 1 and jsonb_array_length(d -> 'cartoes') = 1
        and jsonb_array_length(d -> 'compras_cartao') = 1 and jsonb_array_length(d -> 'parcelas') = 1 and jsonb_array_length(d -> 'faturas') >= 1
        and jsonb_array_length(d -> 'contas_a_pagar') >= 1 and jsonb_array_length(d -> 'titulares') >= 1 and jsonb_array_length(d -> 'categorias') > 0
        and jsonb_array_length(d -> 'auditoria') > 0)::text from (select public.exportar_meus_dados() as d) x$$, 'true'),
    (46, 'exportação de B não traz nada de A', 'B', 'valor', $$select jsonb_array_length(d -> 'importacoes_fatura')::text || ' ' || jsonb_array_length(d -> 'documentos')::text from (select public.exportar_meus_dados() as d) x$$, '0 0'),
    (47, 'exportação de A traz as 2 importações e os 2 arquivos', 'A', 'valor', $$select jsonb_array_length(d -> 'importacoes_fatura')::text || ' ' || jsonb_array_length(d -> 'documentos')::text || ' ' || jsonb_array_length(d -> 'importacao_fatura_itens')::text from (select public.exportar_meus_dados() as d) x$$, '2 2 2'),
    (48, 'exportação continua em ordem (itens por importação e posição)', 'A', 'valor', $$select (select string_agg(e ->> 'ordem', ',') from jsonb_array_elements(d -> 'importacao_fatura_itens') e) from (select public.exportar_meus_dados() as d) x$$, '1,1'),
    (50, 'B solicita a exclusão da conta', 'B', 'valor', format($f$select (public.exclusao_solicitar(%L)).status$f$, v_email_b), 'solicitada'),
    (51, 'usuário não conclui a própria exclusão', 'B', 'erro', $$select public.exclusao_concluir(current_setting('val.b')::uuid)$$, '42501'),
    (52, 'servidor conclui a exclusão de B', 'svc', 'valor', $$select (public.exclusao_concluir(current_setting('val.b')::uuid)).status$$, 'concluida'),
    (53, 'nada de B sobra em nenhuma tabela da lista', 'pg', 'valor', $$select sum((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I where user_id = %L', tabela, current_setting('val.b')), false, true, '')))[1]::text::int)::text from privado.tabelas_do_usuario()$$, '0'),
    (54, 'login de B apagado', 'pg', 'valor', $$select count(*)::text from auth.users where id = current_setting('val.b')::uuid$$, '0'),
    (55, 'registro da exclusão de B preservado', 'pg', 'valor', $$select status from public.exclusoes_conta where user_id = current_setting('val.b')::uuid$$, 'concluida'),
    (56, 'dados de A intactos', 'pg', 'valor', $$select (select count(*) from public.cartoes where user_id = current_setting('val.a')::uuid)::text || ' ' || (select count(*) from public.importacoes_fatura where user_id = current_setting('val.a')::uuid)::text$$, '1 2'),
    (57, 'A não sai da fila de exclusão (A nem pediu): servidor recusa', 'svc', 'erro', $$select public.exclusao_concluir(current_setting('val.a')::uuid)$$, 'P0002'),
    (58, 'anônimo não exporta', 'anon', 'erro', $$select public.exportar_meus_dados()$$, '42501')
    ) as t(ordem, nome, quem, tipo, comando, esperado)
    order by ordem
  loop
    v_total := v_total + 1;
    v_res := null;
    begin
      if c.quem in ('A', 'B') then
        v_uid := current_setting('val.' || lower(c.quem), true);
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claim.sub', coalesce(v_uid, ''), true);
        perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
      elsif c.quem = 'svc' then
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
      elsif c.quem = 'anon' then
        perform set_config('role', 'anon', true);
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      end if;

      execute c.comando into v_res;
      execute 'reset role';

      if c.tipo = 'erro' then
        v_falhas := v_falhas || format('#%s %s: deveria falhar com %s, mas executou', c.ordem, c.nome, c.esperado);
      elsif c.tipo = 'valor' and v_res is distinct from c.esperado then
        v_falhas := v_falhas || format('#%s %s: esperado %s, obtido %s', c.ordem, c.nome, c.esperado, coalesce(v_res, 'NULL'));
      else
        if c.tipo = 'ok' and c.esperado is not null then
          perform set_config('val.' || c.esperado, v_res, true);
        end if;
        v_ok := v_ok + 1;
      end if;
    exception when others then
      -- o papel e as variáveis locais voltam automaticamente ao estado anterior
      if c.tipo = 'erro' and sqlstate = c.esperado then
        v_ok := v_ok + 1;
      else
        v_falhas := v_falhas || format('#%s %s: erro %s — %s', c.ordem, c.nome, sqlstate, sqlerrm);
      end if;
    end;
  end loop;

  if cardinality(v_falhas) = 0 then
    raise exception E'VALIDAÇÃO APROVADA: % de % verificações OK.\nTudo foi desfeito (rollback): nenhum usuário, arquivo ou dado de teste ficou gravado.', v_ok, v_total;
  else
    raise exception E'VALIDAÇÃO REPROVADA: % de % OK, % falha(s):\n%\nTudo foi desfeito (rollback).',
      v_ok, v_total, cardinality(v_falhas), array_to_string(v_falhas, E'\n');
  end if;
end
$validacao$;
