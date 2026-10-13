-- Etapa 5 parte 1 (0008): importação de extratos — prévia, deduplicação,
-- confirmação, períodos sobrepostos, desfazer, conferência de saldo, isolamento, LGPD.
\set QUIET on
\o /dev/null
insert into teste.ids values ('zeca', teste.novo_usuario('zeca@exemplo.com', 'Zeca')), ('yara', teste.novo_usuario('yara@exemplo.com', 'Yara'));
-- arquivos originais "enviados" ao Storage
insert into storage.objects (bucket_id, name, owner) values
  ('documentos', teste.id('zeca') || '/importacoes/' || repeat('a', 64) || '.ofx', teste.id('zeca')),
  ('documentos', teste.id('zeca') || '/importacoes/' || repeat('b', 64) || '.ofx', teste.id('zeca')),
  ('documentos', teste.id('zeca') || '/importacoes/' || repeat('c', 64) || '.csv', teste.id('zeca')),
  ('documentos', teste.id('yara') || '/importacoes/' || repeat('d', 64) || '.ofx', teste.id('yara'));
select teste.como(teste.id('zeca'));
insert into teste.ids select 'z_tit', id from public.titulares where principal;
insert into teste.ids select 'z_conta', (public.conta_criar(teste.id('z_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'zeca-conta-0001')).id;
insert into teste.ids select 'z_alim', id from public.categorias where nome = 'Alimentação';
insert into teste.ids select 'z_sal', id from public.categorias where nome = 'Salário';
-- lançamentos feitos à mão antes da importação
insert into teste.ids select 'z_super', (public.movimento_criar(teste.id('z_conta'), 'debito', 5000, '2026-10-02', 'Supermercado X', 'despesa', teste.id('z_alim'), 'efetivo', null, 'zeca-mov-00001')).id;
insert into teste.ids select 'z_padaria', (public.movimento_criar(teste.id('z_conta'), 'debito', 1500, '2026-10-05', 'Padaria', 'despesa', teste.id('z_alim'), 'efetivo', null, 'zeca-mov-00002')).id;
create temp table arq1 as select jsonb_build_array(
  jsonb_build_object('data', '2026-09-30', 'descricao', 'Tarifa pacote', 'valor_centavos', -1000),
  jsonb_build_object('data', '2026-10-03', 'descricao', 'SUPERMERCADO   X', 'valor_centavos', -8000, 'identificador', 'F1'),
  jsonb_build_object('data', '2026-10-05', 'descricao', 'Padaria pão', 'valor_centavos', -1500),
  jsonb_build_object('data', '2026-10-06', 'descricao', 'Café', 'valor_centavos', -500),
  jsonb_build_object('data', '2026-10-06', 'descricao', 'Café', 'valor_centavos', -500),
  jsonb_build_object('data', '2026-10-07', 'descricao', 'Salário', 'valor_centavos', 500000, 'identificador', 'F2'),
  jsonb_build_object('data', (privado.hoje() + 5)::text, 'descricao', 'Agendado', 'valor_centavos', -100),
  jsonb_build_object('data', '2026-10-07', 'descricao', 'Salário (repetido)', 'valor_centavos', 500000, 'identificador', 'F2')
) as itens;
\o

-- ------------------------------------------------------------ validações na criação
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, (select itens from arq1), 'zeca-imp-x0001') $q$,
  repeat('e', 64), teste.id('zeca')), '22023', 'sem o arquivo original guardado, a importação é recusada');
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, (select itens from arq1), 'zeca-imp-x0002') $q$,
  repeat('d', 64), teste.id('yara')), '22023', 'arquivo na pasta de outro usuário é recusado');
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, '[]', 'zeca-imp-x0003') $q$,
  repeat('a', 64), teste.id('zeca')), '22023', 'arquivo sem lançamentos é recusado');
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, '[{"data":"2026-10-03","descricao":"x","valor_centavos":0}]', 'zeca-imp-x0004') $q$,
  repeat('a', 64), teste.id('zeca')), '22023', 'linha com valor zero é recusada');

-- ------------------------------------------------------------ prévia
\o /dev/null
create temp table imp1 as select * from public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato-out.ofx', repeat('a', 64),
  teste.id('zeca') || '/importacoes/' || repeat('a', 64) || '.ofx', 2048, '0341', '1234-5', 584500, '2026-10-07', (select itens from arq1), 'zeca-imp-00001');
\o
select teste.igual((select situacao || ' ' || itens_total || ' ' || periodo_inicio || ' ' || periodo_fim from imp1), 'previa 8 2026-09-30 ' || (privado.hoje() + 5), 'prévia criada com 8 itens e o período do arquivo');
select teste.igual((select string_agg(sugestao || ':' || incluir, ' ' order by ordem) from public.importacao_itens where importacao_id = (select id from imp1)),
  'antes_data_base:false novo:true possivel_duplicado:false novo:true novo:true novo:true data_futura:false repetido_no_arquivo:false',
  'sugestões: anterior ao saldo inicial, novo, possível duplicado, novos, data futura, repetido no arquivo');
select teste.igual((select count(distinct chave)::int from public.importacao_itens where importacao_id = (select id from imp1) and descricao = 'Café'), 2, 'dois cafés iguais no mesmo dia são dois lançamentos (chaves diferentes)');
select teste.igual((select chave from public.importacao_itens where importacao_id = (select id from imp1) and ordem = 2), 'id:F1', 'com identificador do banco, a chave é o identificador');
select teste.igual((select classificacao || ' ' || (categoria_id = teste.id('z_alim')) from public.importacao_itens where importacao_id = (select id from imp1) and ordem = 2), 'despesa true',
  'categoria sugerida pelo histórico (mesma descrição, sem acento/caixa/espaços)');
select teste.igual((select parecido_data || ' ' || parecido_descricao from public.importacao_itens_lista((select id from imp1)) where ordem = 3), '2026-10-05 Padaria',
  'possível duplicado mostra o lançamento parecido');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('z_conta')), 93500::bigint, 'a prévia não mexe no saldo');
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'de novo.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, (select itens from arq1), 'zeca-imp-x0005') $q$,
  repeat('a', 64), teste.id('zeca')), '22023', 'o mesmo arquivo não entra duas vezes');
select teste.igual((public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato-out.ofx', repeat('a', 64),
  teste.id('zeca') || '/importacoes/' || repeat('a', 64) || '.ofx', 2048, '0341', '1234-5', 584500, '2026-10-07', (select itens from arq1), 'zeca-imp-00001')).id, (select id from imp1),
  'reenvio idêntico devolve a mesma prévia');

-- ------------------------------------------------------------ confirmar
select teste.erro($q$ select public.importacao_confirmar((select id from imp1), 9, null, 'zeca-conf-x001') $q$, '40001', 'versão desatualizada recusada');
\o /dev/null
create temp table conf1 as select * from public.importacao_confirmar((select id from imp1), (select versao from public.importacoes where id = (select id from imp1)),
  jsonb_build_array(jsonb_build_object('id', (select id from public.importacao_itens where importacao_id = (select id from imp1) and ordem = 6),
                                       'classificacao', 'receita', 'categoria_id', teste.id('z_sal'), 'descricao', 'Salário outubro')),
  'zeca-conf-00001');
\o
select teste.igual((select situacao || ' ' || itens_importados || ' ' || itens_duplicados || ' ' || itens_ignorados from conf1), 'confirmada 4 0 4', 'confirmada: 4 importados, 4 ignorados');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('z_conta')), 584500::bigint, 'saldo = inicial + manuais + importados (R$ 5.845,00)');
select teste.igual((select count(*)::int from public.movimentos where importacao_id = (select id from imp1) and origem = 'importacao'), 4, 'lançamentos marcados como importados');
select teste.igual((select descricao || ' ' || classificacao || ' ' || (categoria_id = teste.id('z_sal')) || ' ' || observacao from public.movimentos where chave_importacao = 'id:F2'),
  'Salário outubro receita true No arquivo: Salário', 'ajuste da prévia vale; a descrição original fica na observação');
select teste.igual((select saldo_informado_centavos = saldo_calculado_centavos from public.importacoes_da_conta(teste.id('z_conta')) where importacao_id = (select id from imp1)), true,
  'conferência: saldo do arquivo em 07/10 = saldo calculado');
select teste.erro($q$ select public.importacao_confirmar((select id from imp1), (select versao from public.importacoes where id = (select id from imp1)), null, 'zeca-conf-x002') $q$, '22023', 'importação confirmada não é confirmada de novo');

-- ------------------------------------------------------------ período sobreposto
\o /dev/null
create temp table imp2 as select * from public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato-out-2.ofx', repeat('b', 64),
  teste.id('zeca') || '/importacoes/' || repeat('b', 64) || '.ofx', 2048, null, null, null, null, jsonb_build_array(
    jsonb_build_object('data', '2026-10-03', 'descricao', 'SUPERMERCADO X', 'valor_centavos', -8000, 'identificador', 'F1'),
    jsonb_build_object('data', '2026-10-06', 'descricao', 'Café', 'valor_centavos', -500),
    jsonb_build_object('data', '2026-10-06', 'descricao', 'cafe', 'valor_centavos', -500),
    jsonb_build_object('data', '2026-10-06', 'descricao', 'Café', 'valor_centavos', -500),
    jsonb_build_object('data', '2026-10-08', 'descricao', 'Farmácia', 'valor_centavos', -2000)), 'zeca-imp-00002');
\o
select teste.igual((select string_agg(sugestao, ' ' order by ordem) from public.importacao_itens where importacao_id = (select id from imp2)),
  'ja_importado ja_importado ja_importado possivel_duplicado novo', 'arquivo sobreposto: o que já entrou é reconhecido; um 3º café igual no dia fica para você decidir');
select teste.igual((select sobreposta_a from public.importacoes_da_conta(teste.id('z_conta')) where importacao_id = (select id from imp2)), 1, 'aviso de período sobreposto');
\o /dev/null
create temp table conf2 as select * from public.importacao_confirmar((select id from imp2), (select versao from public.importacoes where id = (select id from imp2)),
  jsonb_build_array(jsonb_build_object('id', (select id from public.importacao_itens where importacao_id = (select id from imp2) and ordem = 1), 'incluir', true)), 'zeca-conf-00002');
\o
select teste.igual((select itens_importados || ' ' || itens_duplicados || ' ' || itens_ignorados from conf2), '1 1 3', 'forçar um já importado não duplica (conta como duplicado)');
select teste.igual((select count(*)::int from public.movimentos where conta_id = teste.id('z_conta') and chave_importacao = 'id:F1' and situacao <> 'cancelado'), 1, 'a compra do supermercado existe uma vez só');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('z_conta')), 584500 - 2000::bigint, 'saldo soma só o que é novo');

-- ------------------------------------------------------------ desfazer
\o /dev/null
insert into teste.ids select 'z_obr', (public.obrigacao_criar('Remédio', 2000, '2026-10-10', null, null, null, 'zeca-obr-00001')).id;
select public.obrigacao_vincular_movimento(teste.id('z_obr'), (select id from public.movimentos where descricao = 'Farmácia'), 2000, 0, 0, 0, 'zeca-vin-00001');
\o
select teste.erro($q$ select public.importacao_desfazer((select id from imp2), (select versao from public.importacoes where id = (select id from imp2)), 'errado') $q$, '22023', 'não desfaz importação cujo lançamento paga uma conta');
select teste.igual((public.importacao_desfazer((select id from imp1), (select versao from public.importacoes where id = (select id from imp1)), 'arquivo errado')).situacao, 'cancelada', 'desfaz a primeira importação');
select teste.igual((select count(*)::int from public.movimentos where importacao_id = (select id from imp1) and situacao = 'cancelado'), 4, 'lançamentos dela cancelados (nada apagado)');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('z_conta')), 93500 - 2000::bigint, 'saldo volta');
\o /dev/null
create temp table imp3 as select * from public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'extrato-out.ofx', repeat('a', 64),
  teste.id('zeca') || '/importacoes/' || repeat('a', 64) || '.ofx', 2048, null, null, null, null, (select itens from arq1), 'zeca-imp-00003');
\o
select teste.igual((select sugestao from public.importacao_itens where importacao_id = (select id from imp3) and ordem = 2), 'novo', 'depois de desfeita, o mesmo arquivo pode ser importado de novo');
select teste.igual((public.importacao_desfazer((select id from imp3), (select versao from public.importacoes where id = (select id from imp3)), 'descartar prévia')).situacao, 'cancelada', 'descartar uma prévia');

-- ------------------------------------------------------------ CSV e auditoria
\o /dev/null
create temp table imp4 as select * from public.importacao_criar(teste.id('z_conta'), 'csv', 'csv-mapeado', 'extrato.csv', repeat('c', 64),
  teste.id('zeca') || '/importacoes/' || repeat('c', 64) || '.csv', 300, null, null, null, null,
  '[{"data":"2026-10-09","descricao":"Pix recebido","valor_centavos":12345}]', 'zeca-imp-00004');
select public.importacao_confirmar((select id from imp4), (select versao from public.importacoes where id = (select id from imp4)), null, 'zeca-conf-00004');
\o
select teste.igual((select natureza || ' ' || valor_centavos || ' ' || classificacao from public.movimentos where importacao_id = (select id from imp4)), 'credito 12345 nao_classificado', 'CSV: valor positivo entra, sem categoria');
select teste.igual((select count(*)::int from public.auditoria where tabela = 'importacoes' and registro_id = (select id from imp1)), 4, 'importação auditada (criada, totais, confirmada, desfeita)');

-- ------------------------------------------------------------ gravação direta e isolamento
select teste.erro($q$ update public.importacoes set situacao = 'previa' $q$, '42501', 'gravação direta em importações negada');
select teste.erro($q$ update public.importacao_itens set incluir = true $q$, '42501', 'gravação direta nos itens negada');
reset role;
\o /dev/null
select teste.como(teste.id('yara'));
\o
select teste.igual((select count(*)::int from public.importacoes) + (select count(*)::int from public.importacao_itens), 0, 'outro usuário não vê importações');
select teste.igual((select count(*)::int from public.importacao_itens_lista((select id from imp2))), 0, 'nem os itens pela consulta');
select teste.erro($q$ select public.importacao_confirmar((select id from imp4), 3, null, 'yara-conf-00001') $q$, 'P0002', 'não confirma importação alheia');
select teste.erro($q$ select public.importacao_desfazer((select id from imp2), 3, 'invasão') $q$, 'P0002', 'não desfaz importação alheia');
select teste.erro(format($q$ select public.importacao_criar(teste.id('z_conta'), 'ofx', 'ofx-generico', 'x.ofx', '%s', '%s/importacoes/%1$s.ofx', 100, null, null, null, null, '[{"data":"2026-10-03","descricao":"x","valor_centavos":1}]', 'yara-imp-00001') $q$,
  repeat('d', 64), teste.id('yara')), 'P0002', 'não importa na conta alheia');
reset role;
select teste.igual((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute'))::int, 0, 'anon não executa nenhuma função do public');
select teste.igual(has_function_privilege('authenticated', 'privado.normalizar_descricao(text)', 'execute'), false, 'função interna nova fechada');
select teste.igual((select count(*) from public.movimentos m where m.chave_importacao is not null and m.situacao <> 'cancelado'
  group by m.user_id, m.conta_id, m.chave_importacao having count(*) > 1) is null, true, 'INVARIANTE: nenhuma chave de importação repetida na mesma conta');

-- ------------------------------------------------------------ LGPD
\o /dev/null
select teste.como(teste.id('zeca'));
create temp table exp5 as select public.exportar_meus_dados() as j;
\o
select teste.igual((select jsonb_array_length(j->'importacoes') = 4 and jsonb_array_length(j->'importacao_itens') = 22 from exp5), true, 'exportação inclui importações e itens');
reset role;
\o /dev/null
delete from storage.objects where (storage.foldername(name))[1] = teste.id('zeca')::text;
select teste.como(teste.id('zeca'));
select public.exclusao_solicitar('zeca@exemplo.com');
reset role;
set role service_role;
select public.exclusao_concluir(teste.id('zeca'), 3, 1000);
reset role;
\o
select teste.igual((select count(*) from public.importacoes where user_id = teste.id('zeca')) + (select count(*) from public.importacao_itens where user_id = teste.id('zeca'))
  + (select count(*) from public.movimentos where user_id = teste.id('zeca')), 0::bigint, 'exclusão da conta apaga importações, itens e lançamentos');
