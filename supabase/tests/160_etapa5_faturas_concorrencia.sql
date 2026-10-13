-- Etapa 5 parte 3 (0010): importações de fatura simultâneas (duas conexões via dblink).
\set QUIET on
\o /dev/null
insert into teste.ids values ('vilma', teste.novo_usuario('vilma@exemplo.com', 'Vilma'));
insert into storage.objects (bucket_id, name, owner)
select 'documentos', teste.id('vilma') || '/importacoes/' || repeat(x, 64) || '.pdf', teste.id('vilma') from unnest(array['1', '2', '3']) x;
select teste.como(teste.id('vilma'));
insert into teste.ids select 'v_c', (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'),
  'Nubank Vera', null, null, 7, 14, null, 'vilma-cartao-001')).id;
create temp table fat as select '[
  {"data":"2026-09-10","descricao":"Loja","valor_centavos":30000,"tipo":"compra","parcela_atual":1,"parcelas_total":3},
  {"data":"2026-09-11","descricao":"Mercado","valor_centavos":5000,"tipo":"compra"}]'::jsonb as v;
-- a mesma fatura baixada duas vezes (web e celular): duas prévias
insert into teste.ids select 'v_i1', (public.importacao_fatura_criar(teste.id('v_c'), 'nubank-fatura-pdf', 'web.pdf', repeat('1', 64),
  teste.id('vilma') || '/importacoes/' || repeat('1', 64) || '.pdf', 100, null, '2026-10-14', '2026-10-07', 35000, null, (select v from fat), null, 'vilma-impf-0001')).id;
insert into teste.ids select 'v_i2', (public.importacao_fatura_criar(teste.id('v_c'), 'nubank-fatura-pdf', 'celular.pdf', repeat('2', 64),
  teste.id('vilma') || '/importacoes/' || repeat('2', 64) || '.pdf', 100, null, '2026-10-14', '2026-10-07', 35000, null, (select v from fat), null, 'vilma-impf-0002')).id;
reset role;
select teste.c_abrir('a', teste.id('vilma'));
select teste.c_abrir('b', teste.id('vilma'));
create function pg_temp.total() returns bigint language sql as $$
  select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.cartao_id = teste.id('v_c') and p.situacao = 'ativa' $$;
\o

-- F1: as duas cópias confirmadas ao mesmo tempo
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_fatura_confirmar('%s', (select versao from public.importacoes_fatura where id = '%1$s'), null, 'vilma-conf-a-01')).itens_lancados::text $q$, teste.id('v_i1'))),
  '2', 'F1: primeira confirmação em andamento (2 lançamentos)');
select teste.c_disparar('b', format($q$ select (public.importacao_fatura_confirmar('%s', (select versao from public.importacoes_fatura where id = '%1$s'), null, 'vilma-conf-b-01')).itens_lancados::text $q$, teste.id('v_i2')));
select teste.igual(teste.c_bloqueada('b'), true, 'F1: segunda ESPERA a primeira (cartão travado)');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:40001', 'F1: segunda é recusada (prévia ficou velha): nada lançado em dobro');
select teste.igual(pg_temp.total(), 95000::bigint, 'F1: só uma vez — Loja em 3x (R$ 900) + Mercado (R$ 50)');

-- F2: a mesma importação confirmada duas vezes ao mesmo tempo (duplo clique)
\o /dev/null
select teste.como(teste.id('vilma'));
select public.importacao_fatura_desfazer(teste.id('v_i2'), (select versao from public.importacoes_fatura where id = teste.id('v_i2')), 'prévia velha');
select public.importacao_fatura_desfazer(teste.id('v_i1'), (select versao from public.importacoes_fatura where id = teste.id('v_i1')), 'refazer');
insert into teste.ids select 'v_i3', (public.importacao_fatura_criar(teste.id('v_c'), 'nubank-fatura-pdf', 'web.pdf', repeat('1', 64),
  teste.id('vilma') || '/importacoes/' || repeat('1', 64) || '.pdf', 100, null, '2026-10-14', '2026-10-07', 35000, null, (select v from fat), null, 'vilma-impf-0003')).id;
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_fatura_confirmar('%s', (select versao from public.importacoes_fatura where id = '%1$s'), null, 'vilma-conf-a-02')).situacao $q$, teste.id('v_i3'))),
  'confirmada', 'F2: primeira confirmação em andamento');
select teste.c_disparar('b', format($q$ select (public.importacao_fatura_confirmar('%s', 1, null, 'vilma-conf-b-02')).situacao $q$, teste.id('v_i3')));
select teste.igual(teste.c_bloqueada('b'), true, 'F2: segunda espera');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b') in ('ERRO:22023', 'ERRO:40001'), true, 'F2: segunda é recusada (já confirmada)');
select teste.igual(pg_temp.total(), 95000::bigint, 'F2: nada em dobro');

-- F3: compra lançada à mão enquanto a importação confirma
\o /dev/null
select teste.como(teste.id('vilma'));
insert into teste.ids select 'v_i4', (public.importacao_fatura_criar(teste.id('v_c'), 'nubank-fatura-pdf', 'nov.pdf', repeat('3', 64),
  teste.id('vilma') || '/importacoes/' || repeat('3', 64) || '.pdf', 100, null, '2026-11-14', '2026-11-07', 30000, null,
  '[{"data":"2026-10-10","descricao":"Loja","valor_centavos":30000,"tipo":"compra","parcela_atual":2,"parcelas_total":3}]', null, 'vilma-impf-0004')).id;
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_fatura_confirmar('%s', (select versao from public.importacoes_fatura where id = '%1$s'), null, 'vilma-conf-a-03')).itens_existentes::text $q$, teste.id('v_i4'))),
  '1', 'F3: fatura de novembro reconhece a parcela 2/3 já criada');
select teste.c_disparar('b', format($q$ select (public.compra_criar('%s', 'compra', null, '2026-10-05', 'Feira', null, 1000, 1, null, 1, null, null, 'vilma-compra-b-01')).descricao $q$, teste.id('v_c')));
select teste.igual(teste.c_bloqueada('b'), true, 'F3: compra à mão espera a importação terminar');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'Feira', 'F3: depois, a compra à mão entra normalmente');
select teste.igual(pg_temp.total(), 96000::bigint, 'F3: R$ 950 + Feira R$ 10');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
