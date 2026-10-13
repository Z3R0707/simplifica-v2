-- Etapa 2 — transações SIMULTÂNEAS reais (duas conexões em paralelo).
\set QUIET on
\o /dev/null
insert into teste.ids values ('paulo', teste.novo_usuario('paulo@exemplo.com', 'Paulo'));
select teste.como(teste.id('paulo'));
insert into teste.ids select 'p_tit', id from public.titulares where principal;
insert into teste.ids select 'p_conta', (public.conta_criar(teste.id('p_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'paulo-conta-itau')).id;
insert into teste.ids select 'p_conta2', (public.conta_criar(teste.id('p_tit'), (select id from public.instituicoes where nome = 'Sicredi'),
  'Sicredi', 'corrente', 50000, '2026-10-01', null, null, true, true, 'paulo-conta-sicredi')).id;
reset role;
select teste.c_abrir('a', teste.id('paulo'));
select teste.c_abrir('b', teste.id('paulo'));
\o

-- S1. Dois lançamentos na MESMA conta ao mesmo tempo: nenhum espera o outro e os dois contam
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.movimento_criar('%s', 'debito', 1000, '2026-10-02', 'Lanche A', 'nao_classificado', null, 'efetivo', null, 'paulo-s1-a-0001')).id::text $q$, teste.id('p_conta')))), 36, 'S1: lançamento A em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_criar('%s', 'debito', 2500, '2026-10-02', 'Lanche B', 'nao_classificado', null, 'efetivo', null, 'paulo-s1-b-0001')).id::text $q$, teste.id('p_conta')));
select teste.igual(teste.c_bloqueada('b'), false, 'S1: lançamento B não espera o A (mesma conta)');
select teste.igual(length(teste.c_resultado('b')), 36, 'S1: lançamento B gravado');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_executar('a', format($q$ select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = '%s' $q$, teste.id('p_conta'))), '96500',
  'S1: saldo considera os dois (1.000 − 10 − 25)');

-- S2. Mesmo lançamento enviado ao mesmo tempo por dois canais (mesma chave)
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
create temp table s2 (id text);
insert into s2 select teste.c_executar('a', format($q$ select (public.movimento_criar('%s', 'debito', 7000, '2026-10-03', 'Conta de luz', 'nao_classificado', null, 'efetivo', null, 'paulo-s2-mesma-chave')).id::text $q$, teste.id('p_conta')));
select teste.c_disparar('b', format($q$ select (public.movimento_criar('%s', 'debito', 7000, '2026-10-03', 'Conta de luz', 'nao_classificado', null, 'efetivo', null, 'paulo-s2-mesma-chave')).id::text $q$, teste.id('p_conta')));
select teste.igual(teste.c_bloqueada('b'), true, 'S2: segundo envio ESPERA o primeiro');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), (select id from s2), 'S2: segundo envio recebe o MESMO movimento');
select teste.igual((select count(*) from public.movimentos where descricao = 'Conta de luz')::int, 1, 'S2: um único lançamento gravado');

-- S3. Arquivar a conta (não confirmado) × lançar nela
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.conta_definir_ativa('%s', 1, false, 'encerrada')).ativa::text $q$, teste.id('p_conta2'))), 'false', 'S3: arquivamento em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_criar('%s', 'credito', 100, '2026-10-04', 'Pix', 'nao_classificado', null, 'efetivo', null, 'paulo-s3-mov-0001')).id::text $q$, teste.id('p_conta2')));
select teste.igual(teste.c_bloqueada('b'), true, 'S3: lançamento ESPERA o arquivamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'S3: lançamento recusado na conta arquivada');
select teste.igual((select count(*) from public.movimentos where conta_id = teste.id('p_conta2'))::int, 0, 'S3: nenhum movimento na conta arquivada');

-- S4. Duas alterações do mesmo movimento com a mesma versão
\o /dev/null
insert into teste.ids select 's4', id from public.movimentos where descricao = 'Lanche A';
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.movimento_atualizar('%s', 1, 'debito', 1200, '2026-10-02', 'Lanche A (web)', 'nao_classificado', null, null)).versao::text $q$, teste.id('s4'))), '2', 'S4: alteração pela web em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_atualizar('%s', 1, 'debito', 1500, '2026-10-02', 'Lanche A (whatsapp)', 'nao_classificado', null, null)).versao::text $q$, teste.id('s4')));
select teste.igual(teste.c_bloqueada('b'), true, 'S4: segunda alteração ESPERA a primeira');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:40001', 'S4: segunda alteração recusada (versão desatualizada)');
select teste.igual((select descricao || ' ' || valor_centavos from public.movimentos where id = teste.id('s4')), 'Lanche A (web) 1200', 'S4: vale a primeira, sem mistura');

-- S5. Efetivar × cancelar o mesmo previsto ao mesmo tempo
\o /dev/null
select teste.como(teste.id('paulo'));
insert into teste.ids select 's5', (public.movimento_criar(teste.id('p_conta'), 'debito', 9900, '2026-11-01', 'Internet', 'nao_classificado', null, 'previsto', null, 'paulo-s5-prev-01')).id;
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.movimento_efetivar('%s', 1, '2026-10-08')).situacao $q$, teste.id('s5'))), 'efetivo', 'S5: efetivação em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar('%s', 1, 'desistiu')).situacao $q$, teste.id('s5')));
select teste.igual(teste.c_bloqueada('b'), true, 'S5: cancelamento ESPERA a efetivação');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:40001', 'S5: cancelamento recusado');
select teste.igual(teste.c_executar('a', format($q$ select saldo_confirmado_centavos::text || '/' || saldo_projetado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = '%s' $q$, teste.id('p_conta'))),
  '79400/79400', 'S5: efetivado conta UMA vez e sai do projetado (1.000 − 12 − 25 − 70 − 99 = 794)');

-- S6. Mudar a data-base (não confirmado) × lançar na conta
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.conta_atualizar('%s', 1, '%s', (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 90000, '2026-10-05', null, null, true, true)).saldo_inicial_data::text $q$,
  teste.id('p_conta'), teste.id('p_tit'))), '2026-10-05', 'S6: nova data-base em andamento (R$ 900 em 05/10)');
select teste.c_disparar('b', format($q$ select (public.movimento_criar('%s', 'credito', 5000, '2026-10-06', 'Venda', 'nao_classificado', null, 'efetivo', null, 'paulo-s6-mov-0001')).id::text $q$, teste.id('p_conta')));
select teste.igual(teste.c_bloqueada('b'), true, 'S6: lançamento ESPERA a mudança da data-base');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(length(teste.c_resultado('b')), 36, 'S6: lançamento gravado depois');
select teste.igual(teste.c_executar('a', format($q$ select saldo_confirmado_centavos::text || ' ' || movimentos_no_saldo from public.saldos_por_conta('2026-10-12') where conta_id = '%s' $q$, teste.id('p_conta'))),
  '85100 2', 'S6: saldo = nova base + só o posterior a ela (900 − 99 + 50 = 851)');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 60_etapa2_concorrencia: concluído =='
