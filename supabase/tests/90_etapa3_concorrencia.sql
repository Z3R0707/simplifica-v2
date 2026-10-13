-- Etapa 3 (0006): operações simultâneas reais (duas conexões via dblink).
\set QUIET on
\o /dev/null
insert into teste.ids values ('vera', teste.novo_usuario('vera@exemplo.com', 'Vera'));
select teste.como(teste.id('vera'));
insert into teste.ids select 'v_tit', id from public.titulares where principal;
insert into teste.ids select 'v_conta', (public.conta_criar(teste.id('v_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'vera-conta-itau')).id;
insert into teste.ids select 'v_cat', id from public.categorias where nome = 'Moradia';
-- uma conta a pagar e uma saída por cenário
insert into teste.ids select 'v_o1', (public.obrigacao_criar('C1', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o1-0000001')).id;
insert into teste.ids select 'v_o2', (public.obrigacao_criar('C2', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o2-0000001')).id;
insert into teste.ids select 'v_o3', (public.obrigacao_criar('C3', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o3-0000001')).id;
insert into teste.ids select 'v_m3', (public.movimento_criar(teste.id('v_conta'), 'debito', 10000, '2026-10-05', 'Saída C3', 'despesa', teste.id('v_cat'), 'efetivo', null, 'vera-m3-0000001')).id;
insert into teste.ids select 'v_o4', (public.obrigacao_criar('C4', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o4-0000001')).id;
insert into teste.ids select 'v_m4', (public.movimento_criar(teste.id('v_conta'), 'debito', 10000, '2026-10-05', 'Saída C4', 'despesa', teste.id('v_cat'), 'efetivo', null, 'vera-m4-0000001')).id;
insert into teste.ids select 'v_o5a', (public.obrigacao_criar('C5a', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o5a-000001')).id;
insert into teste.ids select 'v_o5b', (public.obrigacao_criar('C5b', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o5b-000001')).id;
insert into teste.ids select 'v_m5', (public.movimento_criar(teste.id('v_conta'), 'debito', 10000, '2026-10-05', 'Saída C5', 'despesa', teste.id('v_cat'), 'efetivo', null, 'vera-m5-0000001')).id;
insert into teste.ids select 'v_o6', (public.obrigacao_criar('C6', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o6-0000001')).id;
insert into teste.ids select 'v_m6', (public.movimento_criar(teste.id('v_conta'), 'debito', 10000, '2026-10-05', 'Saída C6', 'despesa', teste.id('v_cat'), 'efetivo', null, 'vera-m6-0000001')).id;
insert into teste.ids select 'v_o7', (public.obrigacao_criar('C7', 10000, '2026-10-20', teste.id('v_cat'), null, null, 'vera-o7-0000001')).id;
insert into teste.ids select 'v_rec', (public.recorrencia_criar('Condomínio', 50000, 10, date_trunc('month', privado.hoje())::date, null, false, null, null, null, 'vera-rec-000001')).id;
reset role;
select teste.c_abrir('a', teste.id('vera'));
select teste.c_abrir('b', teste.id('vera'));
\o

-- C1: dois pagamentos de R$ 60 ao mesmo tempo numa conta de R$ 100 (web × WhatsApp)
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.obrigacao_pagar('%s', '%s', '2026-10-06', 6000, 0, 0, 0, null, 'vera-c1-a-00001')).id::text $q$, teste.id('v_o1'), teste.id('v_conta')))), 36, 'C1: primeiro pagamento em andamento');
select teste.c_disparar('b', format($q$ select (public.obrigacao_pagar('%s', '%s', '2026-10-06', 6000, 0, 0, 0, null, 'vera-c1-b-00001')).id::text $q$, teste.id('v_o1'), teste.id('v_conta')));
select teste.igual(teste.c_bloqueada('b'), true, 'C1: segundo pagamento ESPERA o primeiro');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C1: segundo recusado (passaria do valor da conta)');
select teste.igual((select count(*) from public.movimentos where descricao = 'C1')::int, 1, 'C1: só uma saída criada (a recusada não deixa saída solta)');
select teste.igual((select sum(abatido_centavos) from public.pagamentos where obrigacao_id = teste.id('v_o1') and situacao = 'ativo'), 6000::numeric, 'C1: abatido R$ 60');

-- C2: cancelar a conta a pagar × pagar
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.obrigacao_cancelar('%s', 1, 'não devo')).situacao $q$, teste.id('v_o2'))), 'cancelada', 'C2: cancelamento em andamento');
select teste.c_disparar('b', format($q$ select (public.obrigacao_pagar('%s', '%s', '2026-10-06', 1000, 0, 0, 0, null, 'vera-c2-b-00001')).id::text $q$, teste.id('v_o2'), teste.id('v_conta')));
select teste.igual(teste.c_bloqueada('b'), true, 'C2: pagamento ESPERA o cancelamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C2: pagamento recusado (conta cancelada)');
select teste.igual((select count(*) from public.movimentos where descricao = 'C2')::int, 0, 'C2: nenhuma saída criada');

-- C3: cancelar a saída × vinculá-la a uma conta
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.movimento_cancelar('%s', 1, 'lançado errado')).situacao $q$, teste.id('v_m3'))), 'cancelado', 'C3: cancelamento da saída em andamento');
select teste.c_disparar('b', format($q$ select (public.obrigacao_vincular_movimento('%s', '%s', 10000, 0, 0, 0, 'vera-c3-b-00001')).id::text $q$, teste.id('v_o3'), teste.id('v_m3')));
select teste.igual(teste.c_bloqueada('b'), true, 'C3: vínculo ESPERA o cancelamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C3: vínculo recusado (saída cancelada)');

-- C4: vincular a saída × cancelá-la
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.obrigacao_vincular_movimento('%s', '%s', 10000, 0, 0, 0, 'vera-c4-a-00001')).id::text $q$, teste.id('v_o4'), teste.id('v_m4')))), 36, 'C4: vínculo em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar('%s', 1, 'cancelar')).situacao $q$, teste.id('v_m4')));
select teste.igual(teste.c_bloqueada('b'), true, 'C4: cancelamento ESPERA o vínculo');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C4: cancelamento recusado (saída paga uma conta)');

-- C5: a mesma saída de R$ 100 pagando duas contas de R$ 60 ao mesmo tempo
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.obrigacao_vincular_movimento('%s', '%s', 6000, 0, 0, 0, 'vera-c5-a-00001')).id::text $q$, teste.id('v_o5a'), teste.id('v_m5')))), 36, 'C5: primeiro vínculo em andamento');
select teste.c_disparar('b', format($q$ select (public.obrigacao_vincular_movimento('%s', '%s', 6000, 0, 0, 0, 'vera-c5-b-00001')).id::text $q$, teste.id('v_o5b'), teste.id('v_m5')));
select teste.igual(teste.c_bloqueada('b'), true, 'C5: segundo vínculo ESPERA o primeiro');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C5: segundo recusado (passaria do valor da saída)');

-- C6: vincular R$ 80 × cancelamento parcial de R$ 30 da mesma saída de R$ 100
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.obrigacao_vincular_movimento('%s', '%s', 8000, 0, 0, 0, 'vera-c6-a-00001')).id::text $q$, teste.id('v_o6'), teste.id('v_m6')))), 36, 'C6: vínculo em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar_parcial('%s', 3000, '2026-10-06', 'devolução', 'vera-c6-b-00001')).id::text $q$, teste.id('v_m6')));
select teste.igual(teste.c_bloqueada('b'), true, 'C6: cancelamento parcial ESPERA o vínculo');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'C6: cancelamento parcial recusado (só R$ 20 livres)');

-- C7: desfazer o pagamento × pagar de novo (o segundo vê o restante liberado)
\o /dev/null
select teste.como(teste.id('vera'));
create temp table c7 as select * from public.obrigacao_pagar(teste.id('v_o7'), teste.id('v_conta'), '2026-10-06', 10000, 0, 0, 0, null, 'vera-c7-0000001');
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.pagamento_desfazer('%s', 1, 'errado', true)).situacao $q$, (select id from c7))), 'desfeito', 'C7: desfazer em andamento');
select teste.c_disparar('b', format($q$ select (public.obrigacao_pagar('%s', '%s', '2026-10-07', 10000, 0, 0, 0, null, 'vera-c7-b-00001')).id::text $q$, teste.id('v_o7'), teste.id('v_conta')));
select teste.igual(teste.c_bloqueada('b'), true, 'C7: novo pagamento ESPERA o desfazer');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(length(teste.c_resultado('b')), 36, 'C7: novo pagamento aceito depois que o anterior foi desfeito');

-- C8: duas gerações de recorrência ao mesmo tempo não duplicam meses
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', $q$ select public.recorrencias_gerar((privado.hoje() + interval '5 months')::date)::text $q$), '4', 'C8: primeira geração cria 4 meses');
select teste.c_disparar('b', $q$ select public.recorrencias_gerar((privado.hoje() + interval '5 months')::date)::text $q$);
select teste.igual(teste.c_bloqueada('b'), true, 'C8: segunda geração ESPERA a primeira');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), '0', 'C8: segunda geração não cria nada');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = teste.id('v_rec'))::int, 6, 'C8: 6 meses, sem duplicata');

-- Invariantes
select teste.igual((select count(*) from public.obrigacoes o
  where (select coalesce(sum(p.abatido_centavos), 0) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo') > o.valor_centavos)::int,
  0, 'INVARIANTE: nenhuma conta a pagar com abatido acima do valor');
select teste.igual((select count(*) from public.movimentos m where m.estorno_de is null
  and (select coalesce(sum(p.valor_pago_centavos), 0) from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo')
      + (select coalesce(sum(e.valor_centavos), 0) from public.movimentos e where e.estorno_de = m.id and e.situacao <> 'cancelado') > m.valor_centavos)::int,
  0, 'INVARIANTE: nenhuma saída usada acima do valor');
select teste.igual((select count(*) from public.pagamentos p join public.movimentos m on m.id = p.movimento_id
  where p.situacao = 'ativo' and m.situacao <> 'efetivo')::int, 0, 'INVARIANTE: nenhum pagamento ativo com saída cancelada');
select teste.igual((select count(*) from public.pagamentos p join public.obrigacoes o on o.id = p.obrigacao_id
  where p.situacao = 'ativo' and o.situacao = 'cancelada')::int, 0, 'INVARIANTE: nenhuma conta cancelada com pagamento ativo');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 90_etapa3_concorrencia: concluído =='
