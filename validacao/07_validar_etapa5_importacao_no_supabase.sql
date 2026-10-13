-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 5 (PARTE 1) NO SUPABASE (0008)
-- Importação de extratos: prévia, deduplicação, confirmação, períodos
-- sobrepostos, desfazer e conferência de saldo.
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa ~45 verificações reais e no
-- fim DESFAZ TUDO (rollback). Nada fica gravado: nenhum usuário, arquivo,
-- importação ou lançamento de teste permanece, e nenhum dado real é tocado.
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
  v_email_a  text := 'validacao7-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao7-b-' || v_suf || '@teste.invalid';
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
  if v_res not in ('5.1-importacao-extratos', '5.2-leitores-bancos') then
    raise exception 'ABORTADO: a Etapa 5 parte 1 (0008) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'tabelas novas instaladas', 'pg', 'valor', $$select count(*)::text from pg_tables where schemaname = 'public' and tablename in ('importacoes', 'importacao_itens')$$, '2'),
    (2, 'RLS ligado nas tabelas novas', 'pg', 'valor', $$select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relname in ('importacoes', 'importacao_itens') and relrowsecurity$$, '2'),
    (3, 'índice único da chave de importação instalado', 'pg', 'valor', $$select count(*)::text from pg_indexes where schemaname = 'public' and indexname in ('movimentos_chave_importacao_unica', 'importacoes_arquivo_unico') and indexdef like 'CREATE UNIQUE%'$$, '2'),
    (4, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (5, 'usuário só lê (sem gravação direta) as tabelas novas', 'pg', 'valor', $$select count(*)::text from information_schema.role_table_grants where grantee in ('authenticated', 'anon') and table_name in ('importacoes', 'importacao_itens') and privilege_type <> 'SELECT'$$, '0'),
    (6, 'exclusão de conta inclui importações (na ordem certa)', 'pg', 'valor', $$select (position('delete from public.importacao_itens' in d) > 0 and position('delete from public.importacao_itens' in d) < position('delete from public.movimentos' in d) and position('delete from public.movimentos' in d) < position('delete from public.importacoes' in d))::text from (select pg_get_functiondef('public.exclusao_concluir(uuid,integer,integer)'::regprocedure) d) x$$, 'true'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o 1º arquivo original no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('a', 64) || '.ofx') returning name$$, null),
    (13, 'A guarda o 2º arquivo original no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('b', 64) || '.ofx') returning name$$, null),
    (14, 'B guarda um arquivo na pasta dele', 'B', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.b') || '/importacoes/' || repeat('d', 64) || '.ofx') returning name$$, null),
    (20, 'A cadastra Itaú (R$ 1.000 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'validacao7-conta-01')).id::text$$, 'conta'),
    (21, 'A lança à mão "Supermercado X" (R$ 50, Alimentação)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.conta')::uuid, 'debito', 5000, '2026-10-02', 'Supermercado X', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao7-mov-01')).id::text$$, 'super'),
    (22, 'A lança à mão "Padaria" (R$ 15 em 05/10)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.conta')::uuid, 'debito', 1500, '2026-10-05', 'Padaria', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao7-mov-02')).id::text$$, 'padaria'),
    (23, 'sem o arquivo original guardado, a importação é recusada', 'A', 'erro', $$select public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'x.ofx', repeat('e', 64), current_setting('val.a') || '/importacoes/' || repeat('e', 64) || '.ofx', 100, null, null, null, null, '[{"data":"2026-09-30","descricao":"Tarifa","valor_centavos":-1000},{"data":"2026-10-03","descricao":"SUPERMERCADO   X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-05","descricao":"Padaria pão","valor_centavos":-1500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-07","descricao":"Salário","valor_centavos":500000,"identificador":"F2"},{"data":"2099-01-01","descricao":"Agendado","valor_centavos":-100},{"data":"2026-10-07","descricao":"Salário (repetido)","valor_centavos":500000,"identificador":"F2"}]', 'validacao7-imp-x1')$$, '22023'),
    (24, 'arquivo na pasta de outro usuário é recusado', 'A', 'erro', $$select public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'x.ofx', repeat('d', 64), current_setting('val.b') || '/importacoes/' || repeat('d', 64) || '.ofx', 100, null, null, null, null, '[{"data":"2026-09-30","descricao":"Tarifa","valor_centavos":-1000},{"data":"2026-10-03","descricao":"SUPERMERCADO   X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-05","descricao":"Padaria pão","valor_centavos":-1500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-07","descricao":"Salário","valor_centavos":500000,"identificador":"F2"},{"data":"2099-01-01","descricao":"Agendado","valor_centavos":-100},{"data":"2026-10-07","descricao":"Salário (repetido)","valor_centavos":500000,"identificador":"F2"}]', 'validacao7-imp-x2')$$, '22023'),
    (25, 'linha com valor zero é recusada', 'A', 'erro', $$select public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'x.ofx', repeat('a', 64), current_setting('val.a') || '/importacoes/' || repeat('a', 64) || '.ofx', 100, null, null, null, null, '[{"data":"2026-10-03","descricao":"x","valor_centavos":0}]', 'validacao7-imp-x3')$$, '22023'),
    (26, 'prévia do 1º arquivo (8 lançamentos, saldo do banco R$ 5.845 em 07/10)', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'extrato-a.ofx', repeat('a', 64), current_setting('val.a') || '/importacoes/' || repeat('a', 64) || '.ofx', 2048, '0341', null, 584500, '2026-10-07', '[{"data":"2026-09-30","descricao":"Tarifa","valor_centavos":-1000},{"data":"2026-10-03","descricao":"SUPERMERCADO   X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-05","descricao":"Padaria pão","valor_centavos":-1500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-07","descricao":"Salário","valor_centavos":500000,"identificador":"F2"},{"data":"2099-01-01","descricao":"Agendado","valor_centavos":-100},{"data":"2026-10-07","descricao":"Salário (repetido)","valor_centavos":500000,"identificador":"F2"}]', 'validacao7-imp-01')).id::text$$, 'imp1'),
    (27, 'sugestões: antes do saldo inicial, novo, possível duplicado, novos, data futura, repetido', 'A', 'valor', $$select string_agg(sugestao || ':' || incluir, ' ' order by ordem) from public.importacao_itens where importacao_id = current_setting('val.imp1')::uuid$$, 'antes_data_base:false novo:true possivel_duplicado:false novo:true novo:true novo:true data_futura:false repetido_no_arquivo:false'),
    (28, 'dois cafés iguais no mesmo dia são dois lançamentos', 'A', 'valor', $$select count(distinct chave)::text from public.importacao_itens where importacao_id = current_setting('val.imp1')::uuid and descricao = 'Café'$$, '2'),
    (29, 'categoria sugerida pelo histórico (sem acento/caixa/espaços)', 'A', 'valor', $$select classificacao || ' ' || (categoria_id = (select id from public.categorias where nome = 'Alimentação')) from public.importacao_itens where importacao_id = current_setting('val.imp1')::uuid and ordem = 2$$, 'despesa true'),
    (30, 'possível duplicado mostra o lançamento parecido', 'A', 'valor', $$select parecido_data || ' ' || parecido_descricao from public.importacao_itens_lista(current_setting('val.imp1')::uuid) where ordem = 3$$, '2026-10-05 Padaria'),
    (31, 'a prévia não mexe no saldo', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '93500'),
    (32, 'o mesmo arquivo não entra duas vezes', 'A', 'erro', $$select public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'de novo.ofx', repeat('a', 64), current_setting('val.a') || '/importacoes/' || repeat('a', 64) || '.ofx', 100, null, null, null, null, '[{"data":"2026-09-30","descricao":"Tarifa","valor_centavos":-1000},{"data":"2026-10-03","descricao":"SUPERMERCADO   X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-05","descricao":"Padaria pão","valor_centavos":-1500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-07","descricao":"Salário","valor_centavos":500000,"identificador":"F2"},{"data":"2099-01-01","descricao":"Agendado","valor_centavos":-100},{"data":"2026-10-07","descricao":"Salário (repetido)","valor_centavos":500000,"identificador":"F2"}]', 'validacao7-imp-x4')$$, '22023'),
    (33, 'confirma, marcando o salário como receita', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_importados || ' ' || r.itens_duplicados || ' ' || r.itens_ignorados) from public.importacao_confirmar(current_setting('val.imp1')::uuid, (select versao from public.importacoes where id = current_setting('val.imp1')::uuid), jsonb_build_array(jsonb_build_object('id', (select id from public.importacao_itens where importacao_id = current_setting('val.imp1')::uuid and ordem = 6), 'classificacao', 'receita', 'categoria_id', (select id from public.categorias where nome = 'Salário'))), 'validacao7-conf-01') r$$, 'confirmada 4 0 4'),
    (34, 'saldo = inicial + manuais + importados (R$ 5.845)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '584500'),
    (35, 'conferência: saldo do arquivo em 07/10 = saldo calculado', 'A', 'valor', $$select (saldo_informado_centavos = saldo_calculado_centavos)::text from public.importacoes_da_conta(current_setting('val.conta')::uuid) where importacao_id = current_setting('val.imp1')::uuid$$, 'true'),
    (36, 'lançamentos importados marcados com a origem', 'A', 'valor', $$select count(*)::text from public.movimentos where importacao_id = current_setting('val.imp1')::uuid and origem = 'importacao'$$, '4'),
    (37, 'importação confirmada não é confirmada de novo', 'A', 'erro', $$select public.importacao_confirmar(current_setting('val.imp1')::uuid, (select versao from public.importacoes where id = current_setting('val.imp1')::uuid), null, 'validacao7-conf-x1')$$, '22023'),
    (40, 'prévia do 2º arquivo, com período sobreposto', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'extrato-b.ofx', repeat('b', 64), current_setting('val.a') || '/importacoes/' || repeat('b', 64) || '.ofx', 2048, '0341', null, null, null, '[{"data":"2026-10-03","descricao":"SUPERMERCADO X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"cafe","valor_centavos":-500},{"data":"2026-10-08","descricao":"Farmácia","valor_centavos":-2000}]', 'validacao7-imp-02')).id::text$$, 'imp2'),
    (41, 'arquivo sobreposto: o que já entrou é reconhecido, a farmácia é nova', 'A', 'valor', $$select string_agg(sugestao, ' ' order by ordem) from public.importacao_itens where importacao_id = current_setting('val.imp2')::uuid$$, 'ja_importado ja_importado ja_importado novo'),
    (42, 'aviso de período sobreposto', 'A', 'valor', $$select sobreposta_a::text from public.importacoes_da_conta(current_setting('val.conta')::uuid) where importacao_id = current_setting('val.imp2')::uuid$$, '1'),
    (43, 'forçar um já importado não duplica', 'A', 'valor', $$select (r.itens_importados || ' ' || r.itens_duplicados || ' ' || r.itens_ignorados) from public.importacao_confirmar(current_setting('val.imp2')::uuid, (select versao from public.importacoes where id = current_setting('val.imp2')::uuid), jsonb_build_array(jsonb_build_object('id', (select id from public.importacao_itens where importacao_id = current_setting('val.imp2')::uuid and ordem = 1), 'incluir', true)), 'validacao7-conf-02') r$$, '1 1 2'),
    (44, 'a compra do supermercado existe uma vez só', 'A', 'valor', $$select count(*)::text from public.movimentos where conta_id = current_setting('val.conta')::uuid and chave_importacao = 'id:F1' and situacao <> 'cancelado'$$, '1'),
    (45, 'saldo soma só o que é novo (farmácia)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '582500'),
    (46, 'desfaz a 1ª importação', 'A', 'valor', $$select (public.importacao_desfazer(current_setting('val.imp1')::uuid, (select versao from public.importacoes where id = current_setting('val.imp1')::uuid), 'arquivo errado')).situacao$$, 'cancelada'),
    (47, 'lançamentos dela cancelados (nada apagado) e saldo de volta', 'A', 'valor', $$select (select count(*) from public.movimentos where importacao_id = current_setting('val.imp1')::uuid and situacao = 'cancelado') || ' ' || (select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid)$$, '4 91500'),
    (48, 'depois de desfeita, o mesmo arquivo pode entrar de novo', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'extrato-a.ofx', repeat('a', 64), current_setting('val.a') || '/importacoes/' || repeat('a', 64) || '.ofx', 2048, '0341', null, null, null, '[{"data":"2026-09-30","descricao":"Tarifa","valor_centavos":-1000},{"data":"2026-10-03","descricao":"SUPERMERCADO   X","valor_centavos":-8000,"identificador":"F1"},{"data":"2026-10-05","descricao":"Padaria pão","valor_centavos":-1500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-06","descricao":"Café","valor_centavos":-500},{"data":"2026-10-07","descricao":"Salário","valor_centavos":500000,"identificador":"F2"},{"data":"2099-01-01","descricao":"Agendado","valor_centavos":-100},{"data":"2026-10-07","descricao":"Salário (repetido)","valor_centavos":500000,"identificador":"F2"}]', 'validacao7-imp-03')).id::text$$, 'imp3'),
    (49, 'e os itens voltam a ser novos', 'A', 'valor', $$select sugestao from public.importacao_itens where importacao_id = current_setting('val.imp3')::uuid and ordem = 2$$, 'novo'),
    (50, 'descartar a prévia', 'A', 'valor', $$select (public.importacao_desfazer(current_setting('val.imp3')::uuid, (select versao from public.importacoes where id = current_setting('val.imp3')::uuid), 'descartar')).situacao$$, 'cancelada'),
    (51, 'gravação direta em importações negada', 'A', 'erro', $$update public.importacoes set situacao = 'previa'$$, '42501'),
    (52, 'gravação direta nos itens negada', 'A', 'erro', $$update public.importacao_itens set incluir = true$$, '42501'),
    (60, 'B não vê importações de A', 'B', 'valor', $$select ((select count(*) from public.importacoes) + (select count(*) from public.importacao_itens))::text$$, '0'),
    (61, 'B não confirma importação de A', 'B', 'erro', $$select public.importacao_confirmar(current_setting('val.imp2')::uuid, 9, null, 'validacao7-b-conf')$$, 'P0002'),
    (62, 'B não desfaz importação de A', 'B', 'erro', $$select public.importacao_desfazer(current_setting('val.imp2')::uuid, 9, 'invasão')$$, 'P0002'),
    (63, 'B não importa na conta de A', 'B', 'erro', $$select public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'x.ofx', repeat('d', 64), current_setting('val.b') || '/importacoes/' || repeat('d', 64) || '.ofx', 100, null, null, null, null, '[{"data":"2026-10-03","descricao":"x","valor_centavos":1}]', 'validacao7-b-imp')$$, 'P0002'),
    (64, 'anônimo não consulta importações', 'anon', 'erro', $$select public.importacoes_da_conta(current_setting('val.conta')::uuid)$$, '42501'),
    (70, 'exportação inclui importações e itens', 'A', 'valor', $$select (jsonb_array_length(d->'importacoes') = 3 and jsonb_array_length(d->'importacao_itens') = 20)::text from (select public.exportar_meus_dados() as d) x$$, 'true'),
    (71, 'INVARIANTE: nenhuma chave de importação repetida na mesma conta', 'pg', 'valor', $$select count(*)::text from (select 1 from public.movimentos m where m.chave_importacao is not null and m.situacao <> 'cancelado' group by m.user_id, m.conta_id, m.chave_importacao having count(*) > 1) x$$, '0')
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
