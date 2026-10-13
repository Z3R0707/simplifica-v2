-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO NO PROJETO SUPABASE NOVO (Etapa 1)
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria usuários de teste, executa ~70 verificações reais
-- (cadastro, permissões, RLS, versão, idempotência, titular × contas,
-- Storage, exclusão e bloqueio de token antigo)
-- e no fim DESFAZ TUDO (rollback). Nada fica gravado.
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
  v_email_a  text := 'validacao-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao-b-' || v_suf || '@teste.invalid';
  v_orfao    text := gen_random_uuid()::text || '/orfao-validacao.txt';
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

  for c in
    select * from (values
    -- ------------------------------------------------------------------ configuração
    (1,  'bucket documentos é privado', 'pg', 'valor', $$select public::text from storage.buckets where id = 'documentos'$$, 'false'),
    (2,  'RLS ativa em todas as tabelas do schema public', 'pg', 'valor',
         $$select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity$$, '0'),
    (3,  'anon sem privilégio em tabelas do public', 'pg', 'valor',
         $$select count(*)::text from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'$$, '0'),
    (4,  'anon não executa nenhuma função do public', 'pg', 'valor',
         $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (5,  'usuário não executa funções do servidor', 'pg', 'valor',
         $$select (has_function_privilege('authenticated', 'public.exclusao_concluir(uuid,integer,integer)', 'execute') or has_function_privilege('authenticated', 'public.storage_listar_orfaos(integer)', 'execute'))::text$$, 'false'),
    (6,  'service_role executa funções do servidor', 'pg', 'valor',
         $$select (has_function_privilege('service_role', 'public.exclusao_concluir(uuid,integer,integer)', 'execute') and has_function_privilege('service_role', 'public.exclusao_listar_arquivos(uuid,integer)', 'execute'))::text$$, 'true'),
    (7,  'nenhum banco consta como homologado', 'pg', 'valor', $$select count(*)::text from public.instituicoes where leitor_status = 'homologado'$$, '0'),
    (8,  'gatilhos titular × conta instalados', 'pg', 'valor',
         $$select count(*)::text from pg_trigger where tgname in ('contas_exige_titular_ativo', 'titulares_arquivar_sem_contas_ativas') and not tgisinternal$$, '2'),
    (9,  'política de upload usa a trava por usuário', 'pg', 'valor',
         $$select count(*)::text from pg_policies where schemaname = 'storage' and policyname = 'documentos_insert_proprio' and with_check like '%pode_enviar_arquivo%'$$, '1'),
    -- ------------------------------------------------------------------ cadastro
    (10, 'cria usuário de teste A', 'pg', 'ok',
         format($$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok',
         format($$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$$, v_email_b), 'b'),
    (12, 'perfil criado com o nome do cadastro', 'pg', 'valor', $$select nome from public.perfis where id = current_setting('val.a')::uuid$$, 'Validação A'),
    (13, 'titular principal criado', 'pg', 'valor', $$select count(*)::text from public.titulares where user_id = current_setting('val.a')::uuid and principal$$, '1'),
    (14, '16 categorias padrão criadas', 'pg', 'valor', $$select count(*)::text from public.categorias where user_id = current_setting('val.a')::uuid$$, '16'),
    (15, 'limites de uso criados', 'pg', 'valor', $$select count(*)::text from public.limites_uso where user_id = current_setting('val.b')::uuid$$, '1'),
    -- ------------------------------------------------------------------ usuário A
    (20, 'A vê somente o próprio perfil', 'A', 'valor', $$select count(*)::text from public.perfis$$, '1'),
    (21, 'A cria conta via RPC', 'A', 'ok',
         $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicredi'), 'Conta validação', 'corrente', 123456, current_date, null, null, false, true, 'validacao-conta-0001')).id::text$$, 'conta_a'),
    (22, 'saldo inicial gravado em centavos', 'A', 'valor', $$select saldo_inicial_centavos::text from public.contas where id = current_setting('val.conta_a')::uuid$$, '123456'),
    (23, 'reenvio idêntico devolve a mesma conta', 'A', 'valor',
         $$select ((public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicredi'), 'Conta validação', 'corrente', 123456, current_date, null, null, false, true, 'validacao-conta-0001')).id = current_setting('val.conta_a')::uuid)::text$$, 'true'),
    (24, 'reenvio não duplica', 'A', 'valor', $$select count(*)::text from public.contas$$, '1'),
    (25, 'mesma chave com conteúdo diferente é recusada', 'A', 'erro',
         $$select public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicredi'), 'Conta validação', 'corrente', 999, current_date, null, null, false, true, 'validacao-conta-0001')$$, 'SF409'),
    (26, 'criação sem chave de idempotência é recusada', 'A', 'erro',
         $$select public.titular_criar('Sem chave', null)$$, '22023'),
    (27, 'alteração sem versão esperada é recusada', 'A', 'erro',
         $$select public.conta_definir_ativa(current_setting('val.conta_a')::uuid, null, false)$$, '22023'),
    (28, 'alteração com versão correta aplica (versão 2)', 'A', 'valor',
         $$select (public.conta_definir_ativa(current_setting('val.conta_a')::uuid, 1, false, 'validação')).versao::text$$, '2'),
    (29, 'alteração com versão antiga é recusada', 'A', 'erro',
         $$select public.conta_definir_ativa(current_setting('val.conta_a')::uuid, 1, true)$$, '40001'),
    (30, 'UPDATE direto em contas é negado', 'A', 'erro', $$update public.contas set saldo_inicial_centavos = 0$$, '42501'),
    (31, 'UPDATE direto em perfis é negado', 'A', 'erro', $$update public.perfis set nome = 'x'$$, '42501'),
    (32, 'auditoria não pode ser apagada', 'A', 'erro', $$delete from public.auditoria$$, '42501'),
    (33, 'perfil: versão incrementa ao alterar', 'A', 'valor', $$select (public.perfil_atualizar(1, 'Validação A2')).versao::text$$, '2'),
    (34, 'perfil: criação e alteração auditadas', 'A', 'valor', $$select count(*)::text from public.auditoria where tabela = 'perfis'$$, '2'),
    (35, 'conta: auditoria guarda motivo da alteração', 'A', 'valor', $$select motivo from public.auditoria where tabela = 'contas' and operacao = 'UPDATE'$$, 'validação'),
    (36, 'A grava arquivo na própria pasta', 'A', 'ok',
         $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/validacao.txt') returning name$$, null),
    (37, 'A não grava na pasta de B', 'A', 'erro',
         $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.b') || '/invasao.txt')$$, '42501'),
    (38, 'A não grava fora de pasta de usuário', 'A', 'erro',
         $$insert into storage.objects (bucket_id, name) values ('documentos', 'solto.txt')$$, '42501'),
    -- ------------------------------------------------------------------ usuário B
    (40, 'B não vê contas de A', 'B', 'valor', $$select count(*)::text from public.contas$$, '0'),
    (41, 'B não vê arquivos de A', 'B', 'valor', $$select count(*)::text from storage.objects where bucket_id = 'documentos'$$, '0'),
    (42, 'B não vê auditoria de A', 'B', 'valor', $$select count(*)::text from public.auditoria where user_id <> current_setting('val.b')::uuid$$, '0'),
    (43, 'B não altera conta de A', 'B', 'erro', $$select public.conta_definir_ativa(current_setting('val.conta_a')::uuid, 2, true)$$, 'P0002'),
    (44, 'exportação de B não traz dados de A', 'B', 'valor', $$select jsonb_array_length(public.exportar_meus_dados() -> 'contas')::text$$, '0'),
    -- ------------------------------------------------------------------ titular × contas
    (45, 'A cria titular extra', 'A', 'ok', $$select (public.titular_criar('Titular validação', 'validacao-titular-x1')).id::text$$, 'tx'),
    (46, 'A cria conta ativa no titular extra', 'A', 'ok',
         $$select (public.conta_criar(current_setting('val.tx')::uuid, (select id from public.instituicoes where nome = 'Itaú'), 'Conta titular extra', 'corrente', 0, current_date, null, null, false, true, 'validacao-conta-x1')).id::text$$, 'cx'),
    (47, 'arquivar titular com conta ativa é recusado', 'A', 'erro', $$select public.titular_atualizar(current_setting('val.tx')::uuid, 1, 'Titular validação', false)$$, '22023'),
    (48, 'arquivar a conta antes', 'A', 'valor', $$select (public.conta_definir_ativa(current_setting('val.cx')::uuid, 1, false)).ativa::text$$, 'false'),
    (49, 'agora o titular pode ser arquivado', 'A', 'valor', $$select (public.titular_atualizar(current_setting('val.tx')::uuid, 1, 'Titular validação', false)).ativo::text$$, 'false'),
    (52, 'reativar conta de titular arquivado é recusado', 'A', 'erro', $$select public.conta_definir_ativa(current_setting('val.cx')::uuid, 2, true)$$, '22023'),
    (53, 'criar conta em titular arquivado é recusado', 'A', 'erro',
         $$select public.conta_criar(current_setting('val.tx')::uuid, (select id from public.instituicoes where nome = 'Itaú'), 'Outra', 'corrente', 0, current_date, null, null, false, true, 'validacao-conta-x2')$$, 'P0002'),
    (54, 'nenhuma conta ativa ligada a titular arquivado', 'pg', 'valor',
         $$select count(*)::text from public.contas c join public.titulares t on t.id = c.titular_id where c.ativa and not t.ativo$$, '0'),
    -- ------------------------------------------------------------------ anônimo
    (50, 'anônimo não lê contas', 'anon', 'erro', $$select count(*) from public.contas$$, '42501'),
    (51, 'anônimo não solicita exclusão', 'anon', 'erro', format($$select public.exclusao_solicitar(%L)$$, v_email_a), '42501'),
    -- ------------------------------------------------------------------ exclusão: confirmação
    (60, 'exclusão: confirmação NULL rejeitada', 'A', 'erro', $$select public.exclusao_solicitar(null)$$, '22023'),
    (61, 'exclusão: confirmação vazia rejeitada', 'A', 'erro', $$select public.exclusao_solicitar('')$$, '22023'),
    (62, 'exclusão: confirmação só com espaços rejeitada', 'A', 'erro', $$select public.exclusao_solicitar('   ')$$, '22023'),
    (63, 'exclusão: e-mail divergente rejeitado', 'A', 'erro', $$select public.exclusao_solicitar('outro@teste.invalid')$$, '22023'),
    (64, 'exclusão: e-mail de outro usuário rejeitado', 'A', 'erro', format($$select public.exclusao_solicitar(%L)$$, v_email_b), '22023'),
    (65, 'exclusão: nada registrado pelas tentativas inválidas', 'pg', 'valor',
         $$select count(*)::text from public.exclusoes_conta where user_id = current_setting('val.a')::uuid$$, '0'),
    (66, 'exclusão: e-mail correto registra solicitação', 'A', 'valor', format($$select (public.exclusao_solicitar(%L)).status$$, upper(v_email_a)), 'solicitada'),
    (67, 'exclusão: envio de arquivo bloqueado', 'A', 'erro',
         $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/novo.txt')$$, '42501'),
    (68, 'exclusão: alteração de dados bloqueada', 'A', 'erro', $$select public.titular_criar('Novo', 'validacao-titular-01')$$, '42501'),
    (69, 'exclusão: usuário não executa a conclusão', 'A', 'erro', $$select public.exclusao_concluir(current_setting('val.a')::uuid)$$, '42501'),
    -- ------------------------------------------------------------------ exclusão: servidor
    (70, 'servidor lista o arquivo pendente de A', 'svc', 'valor', $$select count(*)::text from public.exclusao_listar_arquivos(current_setting('val.a')::uuid)$$, '1'),
    (71, 'conclusão RECUSADA enquanto houver arquivo', 'svc', 'erro', $$select public.exclusao_concluir(current_setting('val.a')::uuid)$$, 'SF410'),
    (72, 'login e dados de A preservados após recusa', 'pg', 'valor',
         $$select ((select count(*) from auth.users where id = current_setting('val.a')::uuid) + (select count(*) from public.contas where user_id = current_setting('val.a')::uuid))::text$$, '3'),
    (73, 'sem solicitação, servidor não exclui (B)', 'svc', 'erro', $$select public.exclusao_concluir(current_setting('val.b')::uuid)$$, 'P0002'),
    (74, 'B solicita exclusão (sem arquivos)', 'B', 'valor', format($$select (public.exclusao_solicitar(%L)).status$$, v_email_b), 'solicitada'),
    (75, 'servidor conclui exclusão de B (apaga login no auth.users)', 'svc', 'valor', $$select (public.exclusao_concluir(current_setting('val.b')::uuid)).status$$, 'concluida'),
    (76, 'login de B removido', 'pg', 'valor', $$select count(*)::text from auth.users where id = current_setting('val.b')::uuid$$, '0'),
    (77, 'dados e auditoria de B removidos', 'pg', 'valor',
         $$select ((select count(*) from public.perfis where id = current_setting('val.b')::uuid) + (select count(*) from public.titulares where user_id = current_setting('val.b')::uuid)
                 + (select count(*) from public.categorias where user_id = current_setting('val.b')::uuid) + (select count(*) from public.auditoria where user_id = current_setting('val.b')::uuid))::text$$, '0'),
    (78, 'comprovante da exclusão de B mantido', 'pg', 'valor',
         $$select status from public.exclusoes_conta where user_id = current_setting('val.b')::uuid$$, 'concluida'),
    (79, 'dados de A intactos após exclusão de B', 'pg', 'valor', $$select count(*)::text from public.contas where user_id = current_setting('val.a')::uuid$$, '2'),
    -- ------------------------------------------------------------------ órfãos
    (83, 'token antigo de B (excluído) não envia arquivo', 'B', 'erro',
         $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.b') || '/depois.txt') returning name$$, '42501'),
    (84, 'token antigo de B (excluído) não grava dados', 'B', 'erro', $$select public.titular_criar('Depois', 'validacao-depois-01')$$, '42501'),
    (80, 'cria arquivo órfão de teste', 'pg', 'ok', format($$insert into storage.objects (bucket_id, name) values ('documentos', %L) returning name$$, v_orfao), null),
    (81, 'varredura encontra o órfão', 'svc', 'valor', format($$select count(*)::text from public.storage_listar_orfaos() where nome = %L$$, v_orfao), '1'),
    (82, 'varredura não aponta arquivo de usuário existente', 'svc', 'valor',
         $$select count(*)::text from public.storage_listar_orfaos() where nome like current_setting('val.a') || '/%'$$, '0')
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
