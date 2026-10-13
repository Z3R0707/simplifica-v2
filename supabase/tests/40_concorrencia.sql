-- Transações SIMULTÂNEAS reais (duas ou três conexões em paralelo via dblink).
-- Cada cenário verifica: (1) quem fica bloqueado esperando quem,
-- (2) o resultado de cada lado e (3) o estado final do banco.
\set QUIET on
\o /dev/null
insert into teste.ids values
  ('ivo',   teste.novo_usuario('ivo@exemplo.com', 'Ivo')),
  ('lia',   teste.novo_usuario('lia@exemplo.com', 'Lia')),
  ('joana', teste.novo_usuario('joana@exemplo.com', 'Joana'));
\o

-- =====================================================================
-- PARTE 1 — UPLOAD × EXCLUSÃO DE CONTA
-- =====================================================================

-- U1. Upload iniciado ANTES da solicitação e ainda não confirmado quando o
--     servidor tenta concluir a exclusão.
\o /dev/null
select teste.c_abrir('upload', teste.id('ivo'));
select teste.c_abrir('servidor', null);
select teste.dblink_exec('upload', 'begin');
\o
select teste.igual(teste.c_executar('upload', format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/em-andamento.pdf') returning name $q$, teste.id('ivo'))),
  teste.id('ivo')::text || '/em-andamento.pdf', 'U1: upload em andamento (transação aberta, ainda invisível)');
\o /dev/null
select teste.como(teste.id('ivo'));
select public.exclusao_solicitar('ivo@exemplo.com');
reset role;
\o
select teste.igual((select count(*) from storage.objects where name like teste.id('ivo')::text || '/%')::int, 0, 'U1: listagem do servidor ainda não enxerga o upload em andamento');
select teste.c_disparar('servidor', format($q$ select (public.exclusao_concluir('%s', 0, 5000)).status $q$, teste.id('ivo')));
select teste.igual(teste.c_bloqueada('servidor'), true, 'U1: conclusão ESPERA o upload em andamento terminar');
\o /dev/null
select teste.dblink_exec('upload', 'commit');
\o
select teste.igual(teste.c_resultado('servidor'), 'ERRO:SF410', 'U1: após o upload confirmar, a conclusão enxerga o arquivo e RECUSA');
select teste.igual((select count(*) from auth.users where id = teste.id('ivo'))::int, 1, 'U1: login preservado (o arquivo ainda tem dono)');
-- o servidor repete o ciclo: apaga pelo Storage e conclui
delete from storage.objects where (string_to_array(name, '/'))[1] = teste.id('ivo')::text;
select teste.igual(teste.c_executar('servidor', format($q$ select (public.exclusao_concluir('%s', 1, 5000)).status $q$, teste.id('ivo'))), 'concluida', 'U1: nova tentativa conclui');
select teste.igual((select count(*) from storage.objects where name like teste.id('ivo')::text || '/%')::int, 0, 'U1: nenhum arquivo órfão');

-- U2. Token antigo do usuário já excluído (JWT ainda dentro da validade)
select teste.igual(teste.c_executar('upload', format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/depois.pdf') returning name $q$, teste.id('ivo'))),
  'ERRO:42501', 'U2: upload com token de usuário já excluído é recusado');
select teste.igual((select count(*) from storage.objects where name like teste.id('ivo')::text || '/%')::int, 0, 'U2: nenhum arquivo órfão');
\o /dev/null
select teste.c_fechar('upload');
\o

-- U3. Upload que não termina: a conclusão desiste após o tempo limite sem apagar nada
\o /dev/null
select teste.c_abrir('upload', teste.id('lia'));
select teste.dblink_exec('upload', 'begin');
\o
select teste.igual(teste.c_executar('upload', format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/lento.pdf') returning name $q$, teste.id('lia'))),
  teste.id('lia')::text || '/lento.pdf', 'U3: upload lento em andamento');
\o /dev/null
select teste.como(teste.id('lia'));
select public.exclusao_solicitar('lia@exemplo.com');
reset role;
\o
select teste.igual(teste.c_executar('servidor', format($q$ select (public.exclusao_concluir('%s', 0, 600)).status $q$, teste.id('lia'))),
  'ERRO:55P03', 'U3: conclusão desiste após o tempo limite (sem apagar nada)');
select teste.igual((select count(*) from public.titulares where user_id = teste.id('lia'))::int, 1, 'U3: dados preservados após desistência');
-- o upload termina depois: precisa ser visto pela próxima tentativa
\o /dev/null
select teste.dblink_exec('upload', 'commit');
\o
select teste.igual(teste.c_executar('servidor', format($q$ select (public.exclusao_concluir('%s', 0, 5000)).status $q$, teste.id('lia'))),
  'ERRO:SF410', 'U3: próxima tentativa enxerga o upload tardio e recusa');
delete from storage.objects where (string_to_array(name, '/'))[1] = teste.id('lia')::text;
select teste.igual(teste.c_executar('servidor', format($q$ select (public.exclusao_concluir('%s', 1, 5000)).status $q$, teste.id('lia'))), 'concluida', 'U3: conclui depois de limpar');
select teste.igual((select count(*) from storage.objects where name like teste.id('lia')::text || '/%')::int, 0, 'U3: nenhum arquivo órfão');

-- U4. Upload disparado ENQUANTO a conclusão está em curso: espera e é recusado
--     (a solicitação já bloqueia; aqui provamos que a espera não deixa passar)
\o /dev/null
select teste.c_fechar('upload');
insert into teste.ids values ('mel', teste.novo_usuario('mel@exemplo.com', 'Mel'));
select teste.c_abrir('upload', teste.id('mel'));
select teste.como(teste.id('mel'));
select public.exclusao_solicitar('mel@exemplo.com');
reset role;
select teste.dblink_exec('servidor', 'begin');
\o
select teste.igual(teste.c_executar('servidor', format($q$ select (public.exclusao_concluir('%s', 0, 5000)).status $q$, teste.id('mel'))), 'concluida', 'U4: conclusão executada (transação ainda aberta)');
select teste.c_disparar('upload', format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/corrida.pdf') returning name $q$, teste.id('mel')));
select teste.igual(teste.c_bloqueada('upload'), true, 'U4: upload ESPERA a conclusão terminar');
\o /dev/null
select teste.dblink_exec('servidor', 'commit');
\o
select teste.igual(teste.c_resultado('upload'), 'ERRO:42501', 'U4: upload recusado depois da conclusão');
select teste.igual((select count(*) from storage.objects where name like teste.id('mel')::text || '/%')::int, 0, 'U4: nenhum arquivo órfão');
\o /dev/null
select teste.c_fechar('upload');
select teste.c_fechar('servidor');
\o

-- =====================================================================
-- PARTE 2 — ARQUIVAMENTO DE TITULAR × CONTAS
-- =====================================================================
\o /dev/null
select teste.como(teste.id('joana'));
insert into teste.ids select 'j_principal', id from public.titulares where principal;
insert into teste.ids select 'j_t1', (public.titular_criar('Titular T1', 'joana-t1-000001')).id;
insert into teste.ids select 'j_t2', (public.titular_criar('Titular T2', 'joana-t2-000001')).id;
insert into teste.ids select 'j_t3', (public.titular_criar('Titular T3', 'joana-t3-000001')).id;
insert into teste.ids select 'j_t4', (public.titular_criar('Titular T4', 'joana-t4-000001')).id;
insert into teste.ids select 'j_t5', (public.titular_criar('Titular T5', 'joana-t5-000001')).id;
insert into teste.ids select 'nubank', id from public.instituicoes where nome = 'Nubank';
-- T3: conta já arquivada do titular T3 (para tentar reativar)
insert into teste.ids select 'j_c3', (public.conta_criar(teste.id('j_t3'), teste.id('nubank'), 'Conta T3', 'corrente', 0, '2026-10-01', null, null, false, true, 'joana-c3-000001')).id;
select public.conta_definir_ativa(teste.id('j_c3'), 1, false);
-- T4: conta ativa do titular principal (vai tentar mudar para T4)
insert into teste.ids select 'j_c4', (public.conta_criar(teste.id('j_principal'), teste.id('nubank'), 'Conta T4', 'corrente', 0, '2026-10-01', null, null, false, true, 'joana-c4-000001')).id;
-- T5: conta arquivada do titular T5 (vai ser reativada enquanto T5 é arquivado)
insert into teste.ids select 'j_c5', (public.conta_criar(teste.id('j_t5'), teste.id('nubank'), 'Conta T5', 'corrente', 0, '2026-10-01', null, null, false, true, 'joana-c5-000001')).id;
select public.conta_definir_ativa(teste.id('j_c5'), 1, false);
reset role;
select teste.c_abrir('a', teste.id('joana'));
select teste.c_abrir('b', teste.id('joana'));
\o

-- T1. Arquivamento primeiro (não confirmado) × criação de conta
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.titular_atualizar('%s', 1, 'Titular T1', false)).ativo::text $q$, teste.id('j_t1'))), 'false', 'T1: arquivamento em andamento');
select teste.c_disparar('b', format($q$ select (public.conta_criar('%s', '%s', 'Conta T1', 'corrente', 0, '2026-10-01', null, null, false, true, 'joana-c1-000001')).id::text $q$, teste.id('j_t1'), teste.id('nubank')));
select teste.igual(teste.c_bloqueada('b'), true, 'T1: criação de conta ESPERA o arquivamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(left(teste.c_resultado('b'), 5), 'ERRO:', 'T1: criação recusada após o arquivamento');

-- T2. Criação de conta primeiro (não confirmada) × arquivamento
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.conta_criar('%s', '%s', 'Conta T2', 'corrente', 0, '2026-10-01', null, null, false, true, 'joana-c2-000001')).id::text $q$, teste.id('j_t2'), teste.id('nubank')))), 36, 'T2: criação de conta em andamento');
select teste.c_disparar('b', format($q$ select (public.titular_atualizar('%s', 1, 'Titular T2', false)).ativo::text $q$, teste.id('j_t2')));
select teste.igual(teste.c_bloqueada('b'), true, 'T2: arquivamento ESPERA a criação da conta');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'T2: arquivamento recusado (titular passou a ter conta ativa)');

-- T3. Arquivamento (não confirmado) × reativação de conta
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.titular_atualizar('%s', 1, 'Titular T3', false)).ativo::text $q$, teste.id('j_t3'))), 'false', 'T3: arquivamento em andamento');
select teste.c_disparar('b', format($q$ select (public.conta_definir_ativa('%s', 2, true)).ativa::text $q$, teste.id('j_c3')));
select teste.igual(teste.c_bloqueada('b'), true, 'T3: reativação ESPERA o arquivamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(left(teste.c_resultado('b'), 5), 'ERRO:', 'T3: reativação recusada após o arquivamento');
-- e sem concorrência também: titular arquivado não aceita conta reativada
select teste.igual(teste.c_executar('b', format($q$ select (public.conta_definir_ativa('%s', 2, true)).ativa::text $q$, teste.id('j_c3'))), 'ERRO:22023', 'T3: reativação recusada com o titular já arquivado');

-- T4. Arquivamento (não confirmado) × alteração movendo conta ativa para o titular
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.titular_atualizar('%s', 1, 'Titular T4', false)).ativo::text $q$, teste.id('j_t4'))), 'false', 'T4: arquivamento em andamento');
select teste.c_disparar('b', format($q$ select (public.conta_atualizar('%s', 1, '%s', '%s', 'Conta T4', 'corrente', 0, '2026-10-01', null, null, false, true)).versao::text $q$,
  teste.id('j_c4'), teste.id('j_t4'), teste.id('nubank')));
select teste.igual(teste.c_bloqueada('b'), true, 'T4: alteração ESPERA o arquivamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(left(teste.c_resultado('b'), 5), 'ERRO:', 'T4: alteração para titular arquivado recusada');

-- T5. Reativação de conta primeiro (não confirmada) × arquivamento
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.conta_definir_ativa('%s', 2, true)).ativa::text $q$, teste.id('j_c5'))), 'true', 'T5: reativação em andamento');
select teste.c_disparar('b', format($q$ select (public.titular_atualizar('%s', 1, 'Titular T5', false)).ativo::text $q$, teste.id('j_t5')));
select teste.igual(teste.c_bloqueada('b'), true, 'T5: arquivamento ESPERA a reativação');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'T5: arquivamento recusado (conta foi reativada)');

-- Invariante final: nenhuma conta ativa ligada a titular arquivado
select teste.igual((select count(*) from public.contas c join public.titulares t on t.id = c.titular_id where c.ativa and not t.ativo)::int, 0,
  'INVARIANTE: nenhuma conta ativa com titular arquivado');
select teste.igual((select string_agg(t.nome || '=' || t.ativo, ', ' order by t.nome) from public.titulares t where t.user_id = teste.id('joana') and not t.principal),
  'Titular T1=false, Titular T2=true, Titular T3=false, Titular T4=false, Titular T5=true', 'estado final dos titulares coerente');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 40_concorrencia: concluído =='
