-- Etapa 5 parte 5 (0012): leitores de fatura de mais bancos; instituição
-- Riachuelo; parcelas da mesma compra na mesma fatura (antecipação que o
-- leitor deduz) entram uma vez só. Dados fictícios.
\set QUIET on
\o /dev/null
insert into teste.ids values ('gil5', teste.novo_usuario('gil5@exemplo.com', 'Gil'));
insert into storage.objects (bucket_id, name, owner) values ('documentos', teste.id('gil5') || '/importacoes/' || repeat('5', 64) || '.pdf', teste.id('gil5'));
reset role;
\o
select teste.igual((select etapa >= '5.5' from public.versao_esquema where sistema = 'simplifica-v2'), true, 'versão do esquema: 5.5 ou posterior');
select teste.igual((select count(*)::int from public.instituicoes where nome = 'Riachuelo (Midway)' and codigo_compe is null), 1, 'instituição Riachuelo (Midway) cadastrada');
select teste.igual((select string_agg(nome, ', ' order by nome) from public.instituicoes where 'pdf-fatura' = any (formatos_homologados) and leitor_status = 'homologado'),
  'Itaú, Mercado Pago, Nubank, Riachuelo (Midway), Santander, Sicoob, Sicredi', 'leitores de fatura conferidos com arquivo real: 7 bancos');
select teste.igual((select count(*)::int from public.instituicoes where leitor_status = 'homologado' and cardinality(formatos_homologados) = 0), 0,
  'nenhum banco homologado sem formato conferido');
\o /dev/null
select teste.como(teste.id('gil5'));
insert into teste.ids select 'g5_c', (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '033'),
  'Santander Gil', null, null, 1, 8, null, 'gil5-cartao-001')).id;
create temp table imp as select * from public.importacao_fatura_criar(teste.id('g5_c'), 'santander-fatura-pdf', 'santander.pdf', repeat('5', 64),
  teste.id('gil5') || '/importacoes/' || repeat('5', 64) || '.pdf', 1000, '1234', '2026-10-08', '2026-10-01', 24925, 24925,
  '[{"data":"2026-10-01","descricao":"ANUIDADE","valor_centavos":2750,"tipo":"compra","parcela_atual":4,"parcelas_total":12},
    {"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":4,"parcelas_total":6},
    {"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":5,"parcelas_total":6,"antecipada":true},
    {"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":6,"parcelas_total":6,"antecipada":true},
    {"data":"2026-08-17","descricao":"QUADROS","valor_centavos":-2,"tipo":"credito"},
    {"data":"2026-09-15","descricao":"ASSINATURA","valor_centavos":4900,"tipo":"compra"},
    {"data":"2025-10-08","descricao":"LOJA ANTIGA","valor_centavos":102,"tipo":"compra","parcela_atual":12,"parcelas_total":12}]',
  '[{"data":"2026-09-08","descricao":"PAGAMENTO DE FATURA","valor_centavos":-50000}]', 'gil5-impf-0001');
\o
select teste.igual((select string_agg(sugestao || coalesce(':' || vinculo_ordem, ''), ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = (select id from imp)),
  'novo novo antecipar:2 antecipar:2 novo novo novo', 'parcelas 5 e 6 da mesma compra apontam para a 4 desta fatura');
\o /dev/null
select public.importacao_fatura_confirmar((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), null, 'gil5-impf-c-001');
\o
select teste.igual((select string_agg(p.numero || ':' || to_char(f.competencia, 'MM/YY'), ' ' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id
                     where p.compra_id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 2) and p.situacao = 'ativa'),
  '4:10/26 5:10/26 6:10/26', 'a compra fica com as 3 parcelas nesta fatura e nada nas seguintes');
select teste.igual((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = (select fatura_id from imp) and p.situacao = 'ativa'), 24925::numeric,
  'fatura = total do banco');
select teste.igual((select count(*)::int from public.parcelas where compra_id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 1)), 9,
  'anuidade em 12x a partir da 4ª: 9 parcelas');
select teste.igual((select data_compra::text || ' ' || parcela_inicial || '/' || parcelas_total from public.compras where id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 7)),
  '2025-10-08 12/12', 'compra antiga (12/12 do ano anterior) entra só com a última parcela');
reset role;
