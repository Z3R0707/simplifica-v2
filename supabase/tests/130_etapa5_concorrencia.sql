-- Etapa 5 parte 1 (0008): importações simultâneas (duas conexões via dblink).
\set QUIET on
\o /dev/null
insert into teste.ids values ('wal', teste.novo_usuario('wal@exemplo.com', 'Wal'));
insert into storage.objects (bucket_id, name, owner)
select 'documentos', teste.id('wal') || '/importacoes/' || repeat(x, 64) || '.ofx', teste.id('wal') from unnest(array['1', '2', '3', '4']) x;
select teste.como(teste.id('wal'));
insert into teste.ids select 'w_conta', (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'wal-conta-00001')).id;
create temp table itens as select jsonb_build_array(
  jsonb_build_object('data', '2026-10-03', 'descricao', 'Mercado', 'valor_centavos', -8000, 'identificador', 'A1'),
  jsonb_build_object('data', '2026-10-04', 'descricao', 'Luz', 'valor_centavos', -12000, 'identificador', 'A2'),
  jsonb_build_object('data', '2026-10-05', 'descricao', 'Pix', 'valor_centavos', 30000)) as v;
insert into teste.ids select 'w_i1', (public.importacao_criar(teste.id('w_conta'), 'ofx', 'ofx-generico', 'web.ofx', repeat('1', 64),
  teste.id('wal') || '/importacoes/' || repeat('1', 64) || '.ofx', 100, null, null, null, null, (select v from itens), 'wal-imp-000001')).id;
insert into teste.ids select 'w_i2', (public.importacao_criar(teste.id('w_conta'), 'ofx', 'ofx-generico', 'celular.ofx', repeat('2', 64),
  teste.id('wal') || '/importacoes/' || repeat('2', 64) || '.ofx', 100, null, null, null, null, (select v from itens), 'wal-imp-000002')).id;
insert into teste.ids select 'w_i3', (public.importacao_criar(teste.id('w_conta'), 'ofx', 'ofx-generico', 'outro.ofx', repeat('3', 64),
  teste.id('wal') || '/importacoes/' || repeat('3', 64) || '.ofx', 100, null, null, null, null,
  '[{"data":"2026-10-06","descricao":"Padaria","valor_centavos":-700}]', 'wal-imp-000003')).id;
insert into teste.ids select 'w_i4', (public.importacao_criar(teste.id('w_conta'), 'ofx', 'ofx-generico', 'quarto.ofx', repeat('4', 64),
  teste.id('wal') || '/importacoes/' || repeat('4', 64) || '.ofx', 100, null, null, null, null,
  '[{"data":"2026-10-07","descricao":"Feira","valor_centavos":-900}]', 'wal-imp-000004')).id;
reset role;
select teste.c_abrir('a', teste.id('wal'));
select teste.c_abrir('b', teste.id('wal'));
\o

-- I1: o mesmo extrato baixado duas vezes (web e celular) e confirmado ao mesmo tempo
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_confirmar('%s', (select versao from public.importacoes where id = '%1$s'), null, 'wal-conf-a-0001')).itens_importados::text $q$, teste.id('w_i1'))), '3', 'I1: primeira confirmação em andamento (3 lançamentos)');
select teste.c_disparar('b', format($q$ select (r.itens_importados || ' ' || r.itens_duplicados) from public.importacao_confirmar('%s', (select versao from public.importacoes where id = '%1$s'),
  (select jsonb_agg(jsonb_build_object('id', id, 'incluir', true)) from public.importacao_itens where importacao_id = '%1$s'), 'wal-conf-b-0001') r $q$, teste.id('w_i2')));
select teste.igual(teste.c_bloqueada('b'), true, 'I1: segunda ESPERA a primeira (mesmas chaves)');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), '0 3', 'I1: segunda não duplica nada (3 reconhecidos como duplicados)');
select teste.igual((select count(*)::int from public.movimentos where conta_id = teste.id('w_conta') and situacao <> 'cancelado'), 3, 'I1: só 3 lançamentos na conta');

-- I2: confirmar e descartar a mesma prévia ao mesmo tempo
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_confirmar('%s', (select versao from public.importacoes where id = '%1$s'), null, 'wal-conf-a-0002')).situacao $q$, teste.id('w_i3'))), 'confirmada', 'I2: confirmação em andamento');
select teste.c_disparar('b', format($q$ select (public.importacao_desfazer('%s', (select versao from public.importacoes where id = '%1$s'), 'descartar')).situacao $q$, teste.id('w_i3')));
select teste.igual(teste.c_bloqueada('b'), true, 'I2: descarte ESPERA a confirmação');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:40001', 'I2: descarte recusado (a prévia mudou: foi confirmada)');
-- I3: descartar a prévia × confirmar (ordem inversa)
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.importacao_desfazer('%s', (select versao from public.importacoes where id = '%1$s'), 'descartar')).situacao $q$, teste.id('w_i4'))), 'cancelada', 'I3: descarte em andamento');
select teste.c_disparar('b', format($q$ select (public.importacao_confirmar('%s', (select versao from public.importacoes where id = '%1$s'), null, 'wal-conf-b-0004')).situacao $q$, teste.id('w_i4')));
select teste.igual(teste.c_bloqueada('b'), true, 'I3: confirmação ESPERA o descarte');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'I3: confirmação recusada (a prévia foi descartada)');
select teste.igual((select situacao from public.importacoes where id = teste.id('w_i4')) || ' ' || (select count(*) from public.movimentos where importacao_id = teste.id('w_i4')), 'cancelada 0', 'I3: nada da prévia descartada entrou');
select teste.igual((select count(*) from public.movimentos m where m.chave_importacao is not null and m.situacao <> 'cancelado'
  group by m.user_id, m.conta_id, m.chave_importacao having count(*) > 1) is null, true, 'INVARIANTE: nenhuma chave de importação repetida');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 130_etapa5_concorrencia: concluído =='
