-- Etapa 5 parte 2 (0009): formato PDF, leitores homologados por banco e a
-- troca do CSV genérico pelo leitor do Nubank (chaves diferentes) sem
-- lançar nada em duplicidade.
\set QUIET on
\o /dev/null
insert into teste.ids values ('leia', teste.novo_usuario('leia@exemplo.com', 'Leia'));
insert into storage.objects (bucket_id, name, owner) values
  ('documentos', teste.id('leia') || '/importacoes/' || repeat('1', 64) || '.pdf', teste.id('leia')),
  ('documentos', teste.id('leia') || '/importacoes/' || repeat('2', 64) || '.csv', teste.id('leia')),
  ('documentos', teste.id('leia') || '/importacoes/' || repeat('3', 64) || '.csv', teste.id('leia')),
  ('documentos', teste.id('leia') || '/importacoes/' || repeat('4', 64) || '.xls', teste.id('leia'));
select teste.como(teste.id('leia'));
insert into teste.ids select 'l_tit', id from public.titulares where principal;
insert into teste.ids select 'l_itau', (public.conta_criar(teste.id('l_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Itaú', 'corrente', 18395, '2026-09-12', null, null, true, true, 'leia-conta-itau-01')).id;
insert into teste.ids select 'l_nu', (public.conta_criar(teste.id('l_tit'), (select id from public.instituicoes where codigo_compe = '260'),
  'Nubank', 'corrente', 100000, '2026-10-01', null, null, true, true, 'leia-conta-nu-0001')).id;
\o

-- ------------------------------------------------------------ esquema
reset role;
select teste.igual((select etapa >= '5.2' from public.versao_esquema where sistema = 'simplifica-v2'), true, 'versão do esquema: 5.2 ou posterior');
select teste.igual((select string_agg(nome || ':' || leitor_status || ':' || (case codigo_compe when '341' then 'pdf-extrato' else 'csv-extrato' end = any (formatos_homologados)), ' | ' order by nome)
                      from public.instituicoes where leitor_status <> 'nao_implementado' and codigo_compe in ('260', '341')),
  'Itaú:homologado:true | Nubank:homologado:true', 'homologados só Nubank (CSV da conta) e Itaú (PDF da conta)');
\o /dev/null
select teste.como(teste.id('leia'));
\o

-- ------------------------------------------------------------ PDF (Itaú)
select teste.erro(format($q$ select public.importacao_criar(teste.id('l_itau'), 'xls', 'x', 'a.xls', '%s', '%s/importacoes/%1$s.xls', 10, null, null, null, null,
  '[{"data":"2026-09-14","descricao":"x","valor_centavos":-100}]', 'leia-imp-x0001') $q$, repeat('4', 64), teste.id('leia')), '23514', 'formato desconhecido continua recusado');
\o /dev/null
-- dias 14/09 e 17/09 de um extrato do Itaú (o leitor do site já conferiu o SALDO DO DIA)
create temp table pdf1 as select * from public.importacao_criar(teste.id('l_itau'), 'pdf', 'itau-extrato-pdf', 'extrato-itau.pdf', repeat('1', 64),
  teste.id('leia') || '/importacoes/' || repeat('1', 64) || '.pdf', 90000, '341', '01234-5', 9395, '2026-09-14',
  jsonb_build_array(
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PIX TRANSF FULANO 14/09', 'valor_centavos', -12000),
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PIX TRANSF LIA 14/09', 'valor_centavos', 1800),
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PIX TRANSF LIA 14/09', 'valor_centavos', 1800),
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PAY PADARIA 14/09', 'valor_centavos', -11600),
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PIX TRANSF LIA 2 14/09', 'valor_centavos', 12000),
    jsonb_build_object('data', '2026-09-14', 'descricao', 'PIX TRANSF BELTRANO 12/09', 'valor_centavos', -1000)),
  'leia-imp-pdf-0001');
\o
select teste.igual((select formato || ' ' || leitor || ' ' || itens_total from pdf1), 'pdf itau-extrato-pdf 6', 'importação em PDF aceita');
select teste.igual((select count(*)::int from public.importacao_itens where importacao_id = (select id from pdf1) and sugestao = 'novo'), 6,
  'dois PIX iguais no mesmo dia continuam sendo dois');
\o /dev/null
select public.importacao_confirmar((select id from pdf1), (select versao from public.importacoes where id = (select id from pdf1)), null, 'leia-conf-pdf-001');
\o
select teste.igual((select saldo_informado_centavos::text || ' = ' || saldo_calculado_centavos::text from public.importacoes_da_conta(teste.id('l_itau'))
                     where importacao_id = (select id from pdf1)), '9395 = 9395', 'saldo do PDF (SALDO DO DIA) bate com o calculado');

-- ------------------------------------------------------------ CSV genérico → leitor Nubank
\o /dev/null
-- antes: o mesmo extrato foi importado pelo CSV genérico (sem identificador)
create temp table gen as select * from public.importacao_criar(teste.id('l_nu'), 'csv', 'csv-mapeado', 'extrato nubank.csv', repeat('2', 64),
  teste.id('leia') || '/importacoes/' || repeat('2', 64) || '.csv', 300, null, null, null, null,
  jsonb_build_array(
    jsonb_build_object('data', '2026-10-02', 'descricao', 'Transferência recebida pelo Pix - FULANA', 'valor_centavos', 900),
    jsonb_build_object('data', '2026-10-02', 'descricao', 'Transferência enviada pelo Pix - TELEFONICA', 'valor_centavos', -19600)),
  'leia-imp-gen-0001');
select public.importacao_confirmar((select id from gen), (select versao from public.importacoes where id = (select id from gen)), null, 'leia-conf-gen-001');
-- depois: um arquivo novo do Nubank, lido pelo leitor próprio (com identificador), cobrindo os mesmos dias e mais um
create temp table nu as select * from public.importacao_criar(teste.id('l_nu'), 'csv', 'nubank-csv-extrato', 'NU_2026-10.csv', repeat('3', 64),
  teste.id('leia') || '/importacoes/' || repeat('3', 64) || '.csv', 400, '260', null, null, null,
  jsonb_build_array(
    jsonb_build_object('data', '2026-10-02', 'descricao', 'Transferência recebida pelo Pix - FULANA', 'valor_centavos', 900, 'identificador', '11111111-1111-4111-8111-111111111111'),
    jsonb_build_object('data', '2026-10-02', 'descricao', 'Transferência enviada pelo Pix - TELEFONICA', 'valor_centavos', -19600, 'identificador', '22222222-2222-4222-8222-222222222222'),
    jsonb_build_object('data', '2026-10-13', 'descricao', 'Compra no débito - PADARIA', 'valor_centavos', -1250, 'identificador', '33333333-3333-4333-8333-333333333333')),
  'leia-imp-nu-00001');
\o
select teste.igual((select string_agg(sugestao || ':' || incluir, ',' order by ordem) from public.importacao_itens where importacao_id = (select id from nu)),
  'possivel_duplicado:false,possivel_duplicado:false,novo:true', 'o que já entrou pelo CSV genérico aparece como possível duplicado, desmarcado');
\o /dev/null
select public.importacao_confirmar((select id from nu), (select versao from public.importacoes where id = (select id from nu)), null, 'leia-conf-nu-0001');
\o
select teste.igual((select count(*)::int from public.movimentos where conta_id = teste.id('l_nu') and situacao <> 'cancelado'), 3,
  'na troca de leitor nada é lançado duas vezes');
select teste.igual((select chave_importacao from public.movimentos where conta_id = teste.id('l_nu') and descricao like 'Compra no débito%'),
  'id:33333333-3333-4333-8333-333333333333', 'leitor do Nubank usa o identificador do banco como chave');
reset role;
