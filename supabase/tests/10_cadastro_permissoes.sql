-- Etapa 1 — cadastro automático, RPCs de cadastro e isolamento entre usuários
\set QUIET on
\pset tuples_only on
\o /dev/null

insert into teste.ids values
  ('ana',   teste.novo_usuario('ana@exemplo.com', 'Ana')),
  ('bruno', teste.novo_usuario('bruno@exemplo.com'));
\o
-- ---------------------------------------------------------- cadastro automático
select teste.igual((select nome from public.perfis where id = teste.id('ana')), 'Ana', 'perfil criado com nome do cadastro');
select teste.igual((select nome from public.titulares where user_id = teste.id('ana') and principal), 'Ana', 'titular principal criado');
select teste.igual((select nome from public.titulares where user_id = teste.id('bruno') and principal), 'bruno', 'sem nome: usa parte do e-mail');
select teste.igual((select count(*) from public.categorias where user_id = teste.id('ana'))::int, 16, '16 categorias padrão');
select teste.igual((select count(*) from public.limites_uso where user_id = teste.id('ana'))::int, 1, 'limites de uso criados');
select teste.igual((select count(*) from public.auditoria where user_id = teste.id('ana') and tabela = 'perfis' and canal = 'cadastro')::int, 1, 'criação do perfil auditada (canal cadastro)');
select teste.igual((select count(*) from public.instituicoes where leitor_status = 'homologado' and cardinality(formatos_homologados) = 0)::int, 0, 'banco só consta como homologado com o formato conferido em arquivo real');

-- ================================================================= como ANA
\o /dev/null
select teste.como(teste.id('ana'));
select set_config('request.headers', '{"x-canal":"web"}', false);
insert into teste.ids select 'titular_ana', id from public.titulares where principal;
insert into teste.ids select 'sicredi', id from public.instituicoes where nome = 'Sicredi';
insert into teste.ids select 'conta1', (public.conta_criar(teste.id('titular_ana'), teste.id('sicredi'),
  'Sicredi corrente', 'corrente', 500000, '2026-10-01', '0101', '12345-6', true, true, 'chave-conta-0001')).id;
insert into teste.ids select 'conta2', (public.conta_criar(teste.id('titular_ana'), teste.id('sicredi'),
  'Sicredi poupança', 'poupanca', 0, '2026-10-01', '0101', '99999-0', false, true, 'chave-conta-0002')).id;
\o
select teste.igual((select saldo_inicial_centavos from public.contas where id = teste.id('conta1')), 500000::bigint, 'saldo inicial em centavos (R$ 5.000,00)');
select teste.igual((select count(*) from public.contas)::int, 2, 'duas contas independentes no mesmo banco');
select teste.erro($q$ select public.conta_criar(teste.id('titular_ana'), teste.id('sicredi'), 'Sem chave', 'corrente', 0, '2026-10-01', null, null, false, true, null) $q$,
  '22023', 'criação sem chave de idempotência é recusada');

-- titulares e categorias pelas RPCs
\o /dev/null
insert into teste.ids select 'titular_carla', (public.titular_criar('Carla', 'chave-titular-carla')).id;
insert into teste.ids select 'cat_pet', (public.categoria_criar('Pet', 'despesa', null, '#336699', 'chave-cat-pet')).id;
insert into teste.ids select 'cat_racao', (public.categoria_criar('Ração', 'despesa', teste.id('cat_pet'), null, 'chave-cat-racao')).id;
\o
select teste.erro($q$ select public.categoria_criar('Marca X', 'despesa', teste.id('cat_racao'), null, 'chave-cat-marca') $q$, '22023', 'subcategoria de 2º nível recusada');
select teste.erro($q$ select public.categoria_criar('Bônus', 'receita', teste.id('cat_pet'), null, 'chave-cat-bonus') $q$, '22023', 'subcategoria com tipo diferente do pai recusada');
select teste.erro($q$ select public.titular_atualizar(teste.id('titular_ana'), 1, 'Ana', false) $q$, '22023', 'titular principal não pode ser arquivado');
select teste.igual((public.titular_atualizar(teste.id('titular_carla'), 1, 'Carla Souza', true)).versao, 2, 'titular atualizado com versão esperada');

-- escrita direta nas tabelas é proibida (só RPC)
select teste.erro($q$ update public.contas set saldo_inicial_centavos = 1 $q$, '42501', 'UPDATE direto em contas negado');
select teste.erro($q$ delete from public.contas $q$, '42501', 'DELETE direto em contas negado');
select teste.erro($q$ insert into public.titulares (user_id, nome) values (teste.id('ana'), 'X') $q$, '42501', 'INSERT direto em titulares negado');
select teste.erro($q$ update public.categorias set nome = 'x' $q$, '42501', 'UPDATE direto em categorias negado');
select teste.erro($q$ update public.perfis set nome = 'x' $q$, '42501', 'UPDATE direto em perfis negado');
select teste.erro($q$ delete from public.auditoria $q$, '42501', 'auditoria não pode ser apagada pelo usuário');
select teste.erro($q$ select * from public.chaves_idempotencia $q$, '42501', 'tabela de idempotência inacessível');
select teste.erro($q$ select privado.idempotencia_fim('qualquer-chave', '{}') $q$, '42501', 'funções internas inacessíveis ao usuário');

-- auditoria com canal e valor anterior
select teste.igual((select count(*) > 0 from public.auditoria where tabela = 'titulares' and operacao = 'UPDATE' and canal = 'web'), true, 'auditoria registra alteração com canal web');
select teste.igual((select dados_antes->>'nome' from public.auditoria where tabela = 'titulares' and operacao = 'UPDATE' order by id limit 1), 'Carla', 'auditoria guarda valor anterior');

-- storage
\o /dev/null
insert into storage.objects (bucket_id, name) values ('documentos', teste.id('ana')::text || '/faturas/2026-09.pdf');
\o
select teste.erro(format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/invasao.pdf') $q$, teste.id('bruno')), '42501', 'storage: não grava na pasta de outro usuário');
select teste.erro($q$ insert into storage.objects (bucket_id, name) values ('documentos', 'solto.pdf') $q$, '42501', 'storage: não grava fora de uma pasta de usuário');
select teste.igual(teste.linhas($q$ delete from storage.objects $q$), 0::bigint, 'storage: usuário não apaga o documento original');
select teste.igual(teste.linhas($q$ update storage.objects set name = 'x' $q$), 0::bigint, 'storage: usuário não sobrescreve o documento original');

-- ================================================================= como BRUNO
reset role;
\o /dev/null
select teste.como(teste.id('bruno'));
\o
select teste.igual((select count(*) from public.contas)::int, 0, 'Bruno não vê contas da Ana');
select teste.igual((select count(*) from public.titulares)::int, 1, 'Bruno vê só o próprio titular');
select teste.igual((select count(*) from public.categorias where nome = 'Pet')::int, 0, 'Bruno não vê categorias da Ana');
select teste.igual((select count(*) from public.perfis)::int, 1, 'Bruno vê só o próprio perfil');
select teste.igual((select count(*) from public.auditoria where user_id <> teste.id('bruno'))::int, 0, 'Bruno não vê auditoria da Ana');
select teste.igual((select count(*) from storage.objects)::int, 0, 'Bruno não vê documentos da Ana');
select teste.erro($q$ select public.conta_atualizar(teste.id('conta1'), 1, teste.id('titular_ana'), teste.id('sicredi'), 'roubo', 'corrente', 0, '2026-10-01', null, null, false, true) $q$,
  'P0002', 'RPC: Bruno não edita conta da Ana (nem com titular dela)');
select teste.erro($q$ select public.conta_definir_ativa(teste.id('conta1'), 1, false) $q$, 'P0002', 'RPC: Bruno não arquiva conta da Ana');
select teste.erro($q$ select public.titular_atualizar(teste.id('titular_carla'), 2, 'hack', true) $q$, 'P0002', 'RPC: Bruno não altera titular da Ana');
select teste.erro($q$ select public.categoria_atualizar(teste.id('cat_pet'), 1, 'hack', null, true) $q$, 'P0002', 'RPC: Bruno não altera categoria da Ana');
select teste.erro($q$ select public.categoria_criar('Sub', 'despesa', teste.id('cat_pet'), null, 'chave-bruno-sub') $q$, 'P0002', 'RPC: Bruno não usa categoria da Ana como pai');
select teste.erro($q$ select public.conta_criar(teste.id('titular_ana'), teste.id('sicredi'), 'x', 'corrente', 0, '2026-10-01', null, null, false, true, 'chave-bruno-001') $q$,
  'P0002', 'RPC: Bruno não cria conta com titular da Ana');
select teste.igual(jsonb_array_length(public.exportar_meus_dados()->'contas'), 0, 'exportação do Bruno não traz dados da Ana');
-- Mesma chave de idempotência que a Ana usou: é um espaço de chaves por usuário
select teste.igual((public.titular_criar('Dani', 'chave-titular-carla')).nome, 'Dani', 'chaves de idempotência são isoladas por usuário');

-- ================================================================= ANÔNIMO
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false) \g /dev/null
select set_config('request.jwt.claims', '', false) \g /dev/null
select teste.erro($q$ select count(*) from public.contas $q$, '42501', 'anônimo não lê contas');
select teste.erro($q$ select public.exportar_meus_dados() $q$, '42501', 'anônimo não executa RPC');
select teste.erro($q$ select public.exclusao_solicitar('ana@exemplo.com') $q$, '42501', 'anônimo não solicita exclusão');
reset role;
\echo '== 10_cadastro_permissoes: concluído =='
