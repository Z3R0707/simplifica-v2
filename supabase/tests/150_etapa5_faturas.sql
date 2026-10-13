-- Etapa 5 parte 3 (0010): importação de FATURA de cartão — prévia,
-- parcelas já lançadas (com ajuste de centavos), parcelas novas a partir
-- da n-ésima, possível duplicado, antecipação (de parcela existente e de
-- parcela que nasce na própria importação), crédito, encargo, conferência
-- com o total do banco, reimportação, desfazer, isolamento e LGPD.
-- Dados fictícios no layout das faturas reais.
\set QUIET on
\o /dev/null
insert into teste.ids values ('rosa', teste.novo_usuario('rosa@exemplo.com', 'Rosa')), ('tom', teste.novo_usuario('tom@exemplo.com', 'Tom'));
insert into storage.objects (bucket_id, name, owner)
select 'documentos', teste.id('rosa') || '/importacoes/' || repeat(x, 64) || '.pdf', teste.id('rosa') from unnest(array['1', '2', '3', '4']) x;
insert into storage.objects (bucket_id, name, owner) values ('documentos', teste.id('tom') || '/importacoes/' || repeat('9', 64) || '.pdf', teste.id('tom'));
select teste.como(teste.id('rosa'));
insert into teste.ids select 'rs_tit', id from public.titulares where principal;
insert into teste.ids select 'rs_alim', id from public.categorias where nome = 'Alimentação';
-- cartão: fecha dia 7, vence dia 14
insert into teste.ids select 'rs_nu', (public.cartao_criar(teste.id('rs_tit'), (select id from public.instituicoes where codigo_compe = '260'),
  'Nubank Rosa', '4321', null, 7, 14, null, 'rosa-cartao-0001')).id;
-- o que a Rosa já tinha lançado à mão
insert into teste.ids select 'rs_tv', (public.compra_criar(teste.id('rs_nu'), 'compra', null, '2026-06-02', 'Televisão', null, null, 10, 30000, 4, '2026-10-01', null, 'rosa-compra-tv01')).id;
insert into teste.ids select 'rs_br', (public.compra_criar(teste.id('rs_nu'), 'compra', null, '2026-08-20', 'Brinquedos', null, null, 3, 10001, 1, '2026-09-01', null, 'rosa-compra-ri01')).id;
insert into teste.ids select 'rs_cel', (public.compra_criar(teste.id('rs_nu'), 'compra', null, '2026-09-11', 'Celular', null, null, 2, 5000, 1, null, null, 'rosa-compra-cel1')).id;
insert into teste.ids select 'rs_pad', (public.compra_criar(teste.id('rs_nu'), 'compra', null, '2026-09-12', 'Padaria', teste.id('rs_alim'), 1895, 1, null, 1, null, null, 'rosa-compra-pad1')).id;
create temp table fat as select jsonb_build_array(
  jsonb_build_object('data', '2026-09-07', 'descricao', 'Loja Nova', 'valor_centavos', 12000, 'tipo', 'compra', 'parcela_atual', 4, 'parcelas_total', 12, 'final', '4321'),
  jsonb_build_object('data', '2026-09-07', 'descricao', 'Televisão', 'valor_centavos', 30000, 'tipo', 'compra', 'parcela_atual', 4, 'parcelas_total', 10),
  jsonb_build_object('data', '2026-09-07', 'descricao', 'BRINQUEDOS', 'valor_centavos', 9999, 'tipo', 'compra', 'parcela_atual', 2, 'parcelas_total', 3),
  jsonb_build_object('data', '2026-09-13', 'descricao', 'PADARIA', 'valor_centavos', 1895, 'tipo', 'compra'),
  jsonb_build_object('data', '2026-09-13', 'descricao', 'PADARIA', 'valor_centavos', 1895, 'tipo', 'compra'),
  jsonb_build_object('data', '2026-09-10', 'descricao', 'Drogaria', 'valor_centavos', 8717, 'tipo', 'compra', 'parcela_atual', 1, 'parcelas_total', 3),
  jsonb_build_object('data', '2026-09-17', 'descricao', 'Drogaria', 'valor_centavos', 8716, 'tipo', 'compra', 'parcela_atual', 3, 'parcelas_total', 3, 'antecipada', true),
  jsonb_build_object('data', '2026-09-17', 'descricao', 'Drogaria', 'valor_centavos', 8716, 'tipo', 'compra', 'parcela_atual', 2, 'parcelas_total', 3, 'antecipada', true),
  jsonb_build_object('data', '2026-09-17', 'descricao', 'Drogaria', 'valor_centavos', -218, 'tipo', 'credito'),
  jsonb_build_object('data', '2026-09-09', 'descricao', 'IOF de "Assinatura"', 'valor_centavos', 399, 'tipo', 'encargo', 'subtipo', 'iof'),
  jsonb_build_object('data', '2026-09-11', 'descricao', 'Celular', 'valor_centavos', 5000, 'tipo', 'compra', 'parcela_atual', 1, 'parcelas_total', 2),
  jsonb_build_object('data', '2026-09-17', 'descricao', 'Celular', 'valor_centavos', 5000, 'tipo', 'compra', 'parcela_atual', 2, 'parcelas_total', 2, 'antecipada', true),
  jsonb_build_object('data', '2026-09-20', 'descricao', 'Estorno loja', 'valor_centavos', -1000, 'tipo', 'credito')
) as v;
create temp table pagtos as select '[{"data":"2026-09-08","descricao":"Pagamento em 08 SET","valor_centavos":-50000}]'::jsonb as v;
create function pg_temp.total(p_comp text) returns bigint language sql as $$
  select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p join public.faturas f on f.id = p.fatura_id
   where f.cartao_id = teste.id('rs_nu') and f.competencia = p_comp::date and p.situacao = 'ativa' $$;
\o

select teste.igual(pg_temp.total('2026-10-01'), 46896::bigint, 'antes: fatura 10/2026 tem TV 4/10, Brinquedos 2/3, Celular 1/2 e a padaria (R$ 468,96)');
select teste.igual(pg_temp.total('2026-11-01'), 45001::bigint, 'antes: fatura 11/2026 tem TV 5/10, Brinquedos 3/3 e Celular 2/2 (R$ 450,01)');

-- ------------------------------------------------------------ validações na criação
select teste.erro(format($q$ select public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'f.pdf', '%s', '%s/importacoes/%1$s.pdf', 1000, '4321',
  '2026-10-14', '2026-10-07', 91120, null, (select v from fat), null, 'rosa-impf-x001') $q$, repeat('1', 64), teste.id('rosa')), '22023', 'soma dos lançamentos diferente do total do banco: recusada');
select teste.erro(format($q$ select public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'f.pdf', '%s', '%s/importacoes/%1$s.pdf', 1000, '4321',
  '2026-10-14', '2026-10-07', 91119, null, (select v from fat), null, 'rosa-impf-x002') $q$, repeat('8', 64), teste.id('rosa')), '22023', 'sem o PDF original guardado: recusada');
select teste.erro(format($q$ select public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'f.pdf', '%s', '%s/importacoes/%1$s.pdf', 1000, '4321',
  '2026-10-14', '2026-10-07', -500, null, '[{"data":"2026-09-10","descricao":"x","valor_centavos":-500,"tipo":"compra"}]', null, 'rosa-impf-x003') $q$, repeat('1', 64), teste.id('rosa')), '23514', 'compra com valor negativo é recusada');

-- ------------------------------------------------------------ prévia
\o /dev/null
create temp table imp as select * from public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'Nubank_2026-10.pdf', repeat('1', 64),
  teste.id('rosa') || '/importacoes/' || repeat('1', 64) || '.pdf', 120000, '4321', '2026-10-14', '2026-10-07', 91119, 42000, (select v from fat), (select v from pagtos), 'rosa-impf-0001');
\o
select teste.igual((select string_agg(sugestao || ':' || incluir || case when ajuste_centavos <> 0 then ':' || ajuste_centavos else '' end, ' ' order by ordem)
                      from public.importacao_fatura_itens where importacao_id = (select id from imp)),
  'novo:true ja_lancado:false ja_lancado:false:-2 possivel_duplicado:false novo:true novo:true antecipar:true antecipar:true novo:true novo:true ja_lancado:false antecipar:true novo:true',
  'sugestões: nova a partir da 4ª; já lançadas (com ajuste de centavos); duplicado; padaria repetida é outra compra; antecipações; crédito e IOF');
select teste.igual((select vinculo_ordem from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 7), 6,
  'antecipação da Drogaria aponta para a compra que nasce nesta importação');
select teste.igual((select categoria_id = teste.id('rs_alim') from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 5), true,
  'categoria sugerida pelo histórico (Padaria → Alimentação)');
select teste.igual((select existente_competencia::text from public.importacao_fatura_itens_lista((select id from imp)) where ordem = 12), '2026-11-01',
  'antecipação mostra de qual fatura a parcela sai');
select teste.igual(pg_temp.total('2026-10-01'), 46896::bigint, 'a prévia não muda nada');
select teste.erro(format($q$ select public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'f.pdf', '%s', '%s/importacoes/%1$s.pdf', 1000, '4321',
  '2026-10-14', '2026-10-07', 91119, null, (select v from fat), null, 'rosa-impf-x004') $q$, repeat('1', 64), teste.id('rosa')), '22023', 'a mesma fatura não entra duas vezes');

-- ------------------------------------------------------------ prévia velha
\o /dev/null
insert into teste.ids select 'rs_tmp', (public.compra_criar(teste.id('rs_nu'), 'compra', null, '2026-09-25', 'Lanche', null, 700, 1, null, 1, null, null, 'rosa-compra-tmp1')).id;
\o
select teste.erro($q$ select public.importacao_fatura_confirmar((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), null, 'rosa-impf-c-x00') $q$,
  '40001', 'compra lançada depois da prévia: confirmação recusada (refazer a prévia)');
\o /dev/null
select public.compra_cancelar(teste.id('rs_tmp'), (select versao from public.compras where id = teste.id('rs_tmp')), 'teste', true);
\o
select teste.erro($q$ select public.importacao_fatura_confirmar((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), null, 'rosa-impf-c-x03') $q$,
  '40001', 'mesmo cancelada depois, a prévia continua velha (o estado mudou)');
\o /dev/null
select public.importacao_fatura_desfazer((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), 'prévia velha', 'rosa-impf-d-x00');
drop table imp;
create temp table imp as select * from public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'Nubank_2026-10.pdf', repeat('1', 64),
  teste.id('rosa') || '/importacoes/' || repeat('1', 64) || '.pdf', 120000, '4321', '2026-10-14', '2026-10-07', 91119, 42000, (select v from fat), (select v from pagtos), 'rosa-impf-0001b');
\o

-- ------------------------------------------------------------ confirmar
select teste.erro($q$ select public.importacao_fatura_confirmar((select id from imp), 99, null, 'rosa-impf-c-x01') $q$, '40001', 'versão desatualizada recusada');
\o /dev/null
create temp table conf as select * from public.importacao_fatura_confirmar((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)),
  jsonb_build_array(jsonb_build_object('id', (select id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 1), 'categoria_id', teste.id('rs_alim'))),
  'rosa-impf-c-001');
\o
select teste.igual((select situacao || ' ' || itens_lancados || ' ' || itens_existentes || ' ' || itens_antecipados || ' ' || itens_ajustados || ' ' || itens_ignorados from conf),
  'confirmada 6 3 3 3 1', 'confirmada: 6 lançados, 3 já existiam, 3 antecipados, 3 ajustes de centavos, 1 ignorado (o duplicado)');
select teste.igual(pg_temp.total('2026-10-01'), 91119::bigint, 'fatura 10/2026 = total do banco (R$ 911,19)');
select teste.igual((select total_informado_centavos::text || ' ' || fechamento || ' ' || vencimento from public.faturas where cartao_id = teste.id('rs_nu') and competencia = '2026-10-01'),
  '91119 2026-10-07 2026-10-14', 'fatura recebe as datas reais e o total do banco (conferência)');
select teste.igual(pg_temp.total('2026-11-01'), 52001::bigint, 'fatura 11/2026: TV 5/10 + Brinquedos 3/3 + Loja Nova 5/12 (Celular 2/2 antecipado) = R$ 520,01');
select teste.igual((select string_agg(numero || ':' || valor_centavos || ':' || to_char(f.competencia, 'MM'), ' ' order by numero)
                      from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 6)),
  '1:8717:10 2:8716:10 3:8716:10', 'Drogaria: 1ª parcela criada, 2ª e 3ª antecipadas para esta fatura com o valor do banco');
select teste.igual((select valor_total_centavos::text || ' ' || origem from public.compras where id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 6)),
  '26149 importacao', 'total da compra acompanha o ajuste de centavos (R$ 261,49)');
select teste.igual((select parcela_inicial || '/' || parcelas_total || ' ' || (categoria_id = teste.id('rs_alim')) || ' ' || (select count(*) from public.parcelas where compra_id = c.id)
                      from public.compras c where id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = (select id from imp) and ordem = 1)),
  '4/12 true 9', 'Loja Nova: compra criada da 4ª à 12ª parcela, com a categoria escolhida');
select teste.igual((select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = teste.id('rs_br')), '1:10001 2:9999 3:10001',
  'Brinquedos: só a parcela desta fatura recebe o valor do banco');
select teste.igual((select tipo || ' ' || subtipo from public.compras where importacao_fatura_id = (select id from imp) and descricao like 'IOF%'), 'encargo iof', 'IOF entra como encargo');
select teste.igual((select count(*)::int from public.compras where cartao_id = teste.id('rs_nu') and descricao in ('Padaria', 'PADARIA') and situacao = 'ativa'), 2,
  'duas padarias: a lançada à mão e a segunda da fatura');
select teste.igual((select fatura_original_id is not null and antecipada_em is not null from public.parcelas where compra_id = teste.id('rs_cel') and numero = 2), true,
  'Celular 2/2 marcado como antecipado, guardando a fatura original');
select teste.erro($q$ select public.importacao_fatura_confirmar((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), null, 'rosa-impf-c-x02') $q$,
  '22023', 'importação confirmada não é confirmada de novo');

-- ------------------------------------------------------------ a mesma fatura baixada de novo (outro arquivo)
\o /dev/null
create temp table imp2 as select * from public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'Nubank_2026-10 (1).pdf', repeat('2', 64),
  teste.id('rosa') || '/importacoes/' || repeat('2', 64) || '.pdf', 120001, '4321', '2026-10-14', '2026-10-07', 91119, 42000, (select v from fat), null, 'rosa-impf-0002');
\o
select teste.igual((select string_agg(sugestao, ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = (select id from imp2)),
  'ja_lancado ja_lancado ja_lancado possivel_duplicado ja_importado ja_lancado ja_lancado ja_lancado ja_importado ja_importado ja_lancado ja_lancado ja_importado',
  'baixada de novo: tudo reconhecido (a padaria deixada de fora continua como possível duplicado da lançada à mão)');
\o /dev/null
select public.importacao_fatura_confirmar((select id from imp2), (select versao from public.importacoes_fatura where id = (select id from imp2)),
  (select jsonb_agg(jsonb_build_object('id', id, 'incluir', true)) from public.importacao_fatura_itens where importacao_id = (select id from imp2)), 'rosa-impf-c-002');
\o
select teste.igual(pg_temp.total('2026-10-01'), 93014::bigint, 'confirmar a cópia marcando tudo: nada já lançado se repete; só entra a padaria duvidosa que a pessoa marcou');
\o /dev/null
select public.importacao_fatura_desfazer((select id from imp2), (select versao from public.importacoes_fatura where id = (select id from imp2)), 'cópia', 'rosa-impf-d-002');
\o
select teste.igual(pg_temp.total('2026-10-01'), 91119::bigint, 'desfazer a cópia tira só o que ela lançou');

-- ------------------------------------------------------------ isolamento
\o /dev/null
select teste.como(teste.id('tom'));
\o
select teste.igual(((select count(*) from public.importacoes_fatura) + (select count(*) from public.importacao_fatura_itens))::int, 0, 'Tom não vê importações de fatura da Rosa');
select teste.erro($q$ select public.importacao_fatura_desfazer((select id from imp), 3, 'invasão') $q$, 'P0002', 'Tom não desfaz importação da Rosa');
select teste.erro(format($q$ select public.importacao_fatura_criar('%s', 'nubank-fatura-pdf', 'f.pdf', '%s', '%s/importacoes/%2$s.pdf', 1000, null,
  '2026-10-14', null, 100, null, '[{"data":"2026-09-10","descricao":"x","valor_centavos":100,"tipo":"compra"}]', null, 'tom-impf-x001') $q$,
  teste.id('rs_nu'), repeat('9', 64), teste.id('tom')), 'P0002', 'Tom não importa no cartão da Rosa');
reset role;
select teste.erro($q$ update public.parcelas set valor_centavos = valor_centavos + 1 where compra_id = teste.id('rs_tv') and numero = 6 $q$, '22023',
  'fora da importação, o valor da parcela continua sem poder mudar');
\o /dev/null
select teste.como(teste.id('rosa'));
\o

-- ------------------------------------------------------------ desfazer
\o /dev/null
select public.importacao_fatura_desfazer((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), 'fatura errada', 'rosa-impf-d-001');
\o
select teste.igual(pg_temp.total('2026-10-01'), 46896::bigint, 'desfeita: fatura 10/2026 volta a R$ 468,96');
select teste.igual(pg_temp.total('2026-11-01'), 45001::bigint, 'desfeita: fatura 11/2026 volta a R$ 450,01 (Celular volta e Loja Nova sai)');
select teste.igual((select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = teste.id('rs_br')), '1:10001 2:10001 3:10001',
  'desfeita: o ajuste de centavos volta');
select teste.igual((select total_informado_centavos is null from public.faturas where cartao_id = teste.id('rs_nu') and competencia = '2026-10-01'), true,
  'desfeita: o total informado volta ao que era (vazio)');
select teste.igual((select count(*)::int from public.compras where importacao_fatura_id = (select id from imp) and situacao = 'ativa'), 0,
  'desfeita: compras criadas pela importação ficam canceladas (nada é apagado)');
select teste.erro($q$ select public.importacao_fatura_desfazer((select id from imp), (select versao from public.importacoes_fatura where id = (select id from imp)), 'de novo') $q$,
  '22023', 'não desfaz duas vezes');

-- ------------------------------------------------------------ importar de novo depois de desfeita
\o /dev/null
create temp table imp3 as select * from public.importacao_fatura_criar(teste.id('rs_nu'), 'nubank-fatura-pdf', 'Nubank_2026-10.pdf', repeat('1', 64),
  teste.id('rosa') || '/importacoes/' || repeat('1', 64) || '.pdf', 120000, '4321', '2026-10-14', '2026-10-07', 91119, 42000, (select v from fat), null, 'rosa-impf-0003');
select public.importacao_fatura_confirmar((select id from imp3), (select versao from public.importacoes_fatura where id = (select id from imp3)), null, 'rosa-impf-c-003');
\o
select teste.igual(pg_temp.total('2026-10-01'), 91119::bigint, 'depois de desfeita, a mesma fatura pode ser importada de novo e fecha com o banco');

-- ------------------------------------------------------------ cartão cadastrado com datas diferentes das do banco
\o /dev/null
insert into teste.ids select 'rs_x', (public.cartao_criar(teste.id('rs_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Outro cartão', null, null, 1, 8, null, 'rosa-cartao-0002')).id;
create temp table imp4 as select * from public.importacao_fatura_criar(teste.id('rs_x'), 'itau-fatura-pdf', 'itau.pdf', repeat('3', 64),
  teste.id('rosa') || '/importacoes/' || repeat('3', 64) || '.pdf', 5000, '5678', '2026-10-13', '2026-10-03', 1800, 1800,
  '[{"data":"2026-09-04","descricao":"ACADEMIA","valor_centavos":1800,"tipo":"compra"}]', null, 'rosa-impf-0004');
\o
select teste.igual((select fechamento || ' ' || vencimento from public.faturas where id = (select fatura_id from imp4)), '2026-10-01 2026-10-08',
  'cartão cadastrado para vencer dia 8: a fatura de 10/2026 nasce com as datas do cadastro');
\o /dev/null
select public.importacao_fatura_confirmar((select id from imp4), (select versao from public.importacoes_fatura where id = (select id from imp4)), null, 'rosa-impf-c-004');
\o
select teste.igual((select fechamento || ' ' || vencimento || ' ' || total_informado_centavos from public.faturas where id = (select fatura_id from imp4)), '2026-10-03 2026-10-13 1800',
  'ao confirmar, a fatura passa a ter as datas reais do banco (03/10 e 13/10)');
select teste.igual((select vencimento::text from public.obrigacoes where id = (select obrigacao_id from public.faturas where id = (select fatura_id from imp4))), '2026-10-13',
  'a conta a pagar da fatura acompanha o vencimento real');
\o /dev/null
select public.importacao_fatura_desfazer((select id from imp4), (select versao from public.importacoes_fatura where id = (select id from imp4)), 'teste de datas', 'rosa-impf-d-004');
\o
select teste.igual((select fechamento || ' ' || vencimento from public.faturas where id = (select fatura_id from imp4)), '2026-10-01 2026-10-08',
  'desfeita: as datas voltam às do cadastro');

-- ------------------------------------------------------------ antecipação com desconto feita no Simplifica
\o /dev/null
insert into teste.ids select 'rs_fone', (public.compra_criar(teste.id('rs_x'), 'compra', null, '2026-10-05', 'Fone', null, 30000, 3, null, 1, null, null, 'rosa-compra-fone')).id;
select public.compra_antecipar(teste.id('rs_fone'), array[2, 3], null, 500, 'rosa-antecipa-fone');
-- lançada à mão na fatura errada: a 1ª parcela ficou na fatura de 12/2026
select public.compra_criar(teste.id('rs_x'), 'compra', null, '2026-10-06', 'Bicicleta', null, null, 5, 20000, 1, '2026-12-01', null, 'rosa-compra-bike');
create temp table imp5 as select * from public.importacao_fatura_criar(teste.id('rs_x'), 'nubank-fatura-pdf', 'nov.pdf', repeat('4', 64),
  teste.id('rosa') || '/importacoes/' || repeat('4', 64) || '.pdf', 5000, null, '2026-11-08', '2026-11-01', 49500, null,
  '[{"data":"2026-10-05","descricao":"Fone","valor_centavos":10000,"tipo":"compra","parcela_atual":1,"parcelas_total":3},
    {"data":"2026-10-13","descricao":"Fone","valor_centavos":10000,"tipo":"compra","parcela_atual":3,"parcelas_total":3,"antecipada":true},
    {"data":"2026-10-13","descricao":"Fone","valor_centavos":10000,"tipo":"compra","parcela_atual":2,"parcelas_total":3,"antecipada":true},
    {"data":"2026-10-13","descricao":"Fone","valor_centavos":-500,"tipo":"credito","desconto_antecipacao":true},
    {"data":"2026-10-06","descricao":"Bicicleta","valor_centavos":20000,"tipo":"compra","parcela_atual":1,"parcelas_total":5}]', null, 'rosa-impf-0005');
\o
select teste.igual((select string_agg(sugestao, ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = (select id from imp5)),
  'ja_lancado ja_lancado ja_lancado ja_lancado possivel_duplicado', 'antecipação com desconto já feita no Simplifica: parcelas e a linha de desconto reconhecidas; parcela lançada noutra fatura vira possível duplicado');
select teste.igual((select existente_competencia::text from public.importacao_fatura_itens_lista((select id from imp5)) where ordem = 5), '2026-12-01',
  'possível duplicado mostra em que fatura a parcela está');
\o /dev/null
select public.importacao_fatura_confirmar((select id from imp5), (select versao from public.importacoes_fatura where id = (select id from imp5)), null, 'rosa-impf-c-005');
\o
select teste.igual((select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = (select fatura_id from imp5) and p.situacao = 'ativa'), 29500::numeric,
  'o desconto não entra duas vezes e a bicicleta (deixada de fora) não duplica: fatura = R$ 295,00');

-- ------------------------------------------------------------ LGPD
select teste.igual((select jsonb_array_length(d -> 'importacoes_fatura') || ' ' || jsonb_array_length(d -> 'importacao_fatura_itens') from (select public.exportar_meus_dados() d) x),
  '6 58', 'exportação inclui as importações de fatura e seus itens');
reset role;
\o /dev/null
delete from storage.objects where (storage.foldername(name))[1] = teste.id('rosa')::text;
select teste.como(teste.id('rosa'));
select public.exclusao_solicitar('rosa@exemplo.com');
reset role;
set role service_role;
select public.exclusao_concluir(teste.id('rosa'), 3, 1000);
reset role;
\o
select teste.igual((select count(*) from public.importacoes_fatura where user_id = teste.id('rosa')) + (select count(*) from public.importacao_fatura_itens where user_id = teste.id('rosa'))
  + (select count(*) from public.compras where user_id = teste.id('rosa')), 0::bigint, 'exclusão da conta apaga importações de fatura, itens e compras');
