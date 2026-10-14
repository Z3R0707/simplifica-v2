-- Etapa 6 parte 1 (0013): conciliação bancária — sugestões, confirmação,
-- pendentes, pagamento em dobro (à mão + extrato), troca atômica,
-- desfazer com histórico, isolamento. Dados fictícios.
\set QUIET on
\o /dev/null
insert into teste.ids values ('cora', teste.novo_usuario('cora@exemplo.com', 'Cora')), ('davi6', teste.novo_usuario('davi6@exemplo.com', 'Davi'));
insert into storage.objects (bucket_id, name, owner) values ('documentos', teste.id('cora') || '/importacoes/' || repeat('c', 64) || '.ofx', teste.id('cora')),
  ('documentos', teste.id('cora') || '/importacoes/' || repeat('d', 64) || '.pdf', teste.id('cora'));
select teste.como(teste.id('cora'));
insert into teste.ids select 'co_tit', id from public.titulares where principal;
insert into teste.ids select 'co_conta', (public.conta_criar(teste.id('co_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Itaú', 'corrente', 500000, '2026-09-01', null, null, true, true, 'cora-conta-0001')).id;
-- cartão Itaú pago pela conta Itaú: fatura de 10/2026 com R$ 987,65
insert into teste.ids select 'co_cart', (public.cartao_criar(teste.id('co_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Cartão Itaú', null, null, 3, 13, teste.id('co_conta'), 'cora-cartao-001')).id;
select public.compra_criar(teste.id('co_cart'), 'compra', null, '2026-09-05', 'Mercado', null, 98765, 1, null, 1, null, null, 'cora-compra-001');
insert into teste.ids select 'co_fat', obrigacao_id from public.faturas where cartao_id = teste.id('co_cart') and competencia = '2026-10-01';
-- cartão Santander pago pela conta Itaú: a fatura importada soma R$ 1.200,50, mas
-- R$ 1.112,50 foram pagos antes do fechamento; o banco cobra só R$ 88,00
insert into teste.ids select 'co_sant', (public.cartao_criar(teste.id('co_tit'), (select id from public.instituicoes where codigo_compe = '033'),
  'Cartão Santander', null, null, 1, 8, teste.id('co_conta'), 'cora-cartao-002')).id;
create temp table impf as select * from public.importacao_fatura_criar(teste.id('co_sant'), 'santander-fatura-pdf', 'santander.pdf', repeat('d', 64),
  teste.id('cora') || '/importacoes/' || repeat('d', 64) || '.pdf', 1000, null, '2026-10-08', '2026-10-01', 120050, 8800,
  '[{"data":"2026-09-10","descricao":"LOJA DE MOVEIS","valor_centavos":120050,"tipo":"compra"}]',
  '[{"data":"2026-09-22","descricao":"PAGAMENTO DE FATURA","valor_centavos":-111250}]', 'cora-impf-0001');
select public.importacao_fatura_confirmar((select id from impf), (select versao from public.importacoes_fatura where id = (select id from impf)), null, 'cora-conff-001');
insert into teste.ids select 'co_fat_s', obrigacao_id from public.faturas where cartao_id = teste.id('co_sant') and competencia = '2026-10-01';
-- contas a pagar avulsas
insert into teste.ids select 'co_sicredi', (public.obrigacao_criar('Boleto cartão Sicredi', 54321, '2026-10-10', null, teste.id('co_conta'), null, 'cora-obr-0001')).id;
insert into teste.ids select 'co_luz', (public.obrigacao_criar('Conta de luz', 31234, '2026-10-05', null, null, null, 'cora-obr-0002')).id;
insert into teste.ids select 'co_net', (public.obrigacao_criar('Internet', 10000, '2026-10-10', null, null, null, 'cora-obr-0003')).id;
-- seguro de mesmo valor que um débito antigo, mas 58 dias distante: fora da janela de 20 dias
select public.obrigacao_criar('Seguro', 4321, '2026-10-30', null, null, null, 'cora-obr-0004');
-- dois débitos do mesmo valor: o nome na descrição vale mais que 3 dias de diferença...
select public.obrigacao_criar('Escola Aurora', 8000, '2026-10-15', null, null, null, 'cora-obr-0005');
-- ...mas 19 dias de distância pesam mais que o nome
select public.obrigacao_criar('Condominio Solar', 9000, '2026-10-12', null, null, null, 'cora-obr-0006');
-- um PIX que pagou duas contas: depois de vincular uma, a outra não é sugerida (divisão é manual)
insert into teste.ids select 'co_acad', (public.obrigacao_criar('Academia', 5000, '2026-10-06', null, null, null, 'cora-obr-0007')).id;
select public.obrigacao_criar('Personal', 10500, '2026-10-06', null, null, null, 'cora-obr-0008');
-- extrato importado
create temp table imp as select * from public.importacao_criar(teste.id('co_conta'), 'ofx', 'ofx-generico', 'itau.ofx', repeat('c', 64),
  teste.id('cora') || '/importacoes/' || repeat('c', 64) || '.ofx', 1000, null, null, null, null, '[
    {"data":"2026-10-13","descricao":"FATURA CARTAO ITAU","valor_centavos":-98765},
    {"data":"2026-10-02","descricao":"PAG BOLETO SICREDI","valor_centavos":-54321},
    {"data":"2026-10-02","descricao":"PAG BOLETO SANTANDER","valor_centavos":-8800},
    {"data":"2026-10-02","descricao":"PAG BOLETO ENERGIA","valor_centavos":-31234},
    {"data":"2026-09-20","descricao":"MERCADO BAIRRO","valor_centavos":-31234},
    {"data":"2026-10-09","descricao":"DEBITO INTERNET","valor_centavos":-10000},
    {"data":"2026-10-03","descricao":"PADARIA","valor_centavos":-1500},
    {"data":"2026-10-04","descricao":"PIX RECEBIDO","valor_centavos":50000},
    {"data":"2026-09-20","descricao":"TED SANTANDER","valor_centavos":-8800},
    {"data":"2026-09-02","descricao":"SEGURO AUTO","valor_centavos":-4321},
    {"data":"2026-10-10","descricao":"PIX ESCOLA AURORA","valor_centavos":-8000},
    {"data":"2026-10-13","descricao":"TARIFA PACOTE","valor_centavos":-8000},
    {"data":"2026-09-23","descricao":"CONDOMINIO SOLAR","valor_centavos":-9000},
    {"data":"2026-10-12","descricao":"DEBITO AUTOMATICO","valor_centavos":-9000},
    {"data":"2026-10-06","descricao":"PIX ACADEMIA E PERSONAL","valor_centavos":-15500}]', 'cora-imp-00001');
select public.importacao_confirmar((select id from imp), (select versao from public.importacoes where id = (select id from imp)), null, 'cora-conf-0001');
insert into teste.ids select 'co_pag_acad', (public.obrigacao_vincular_movimento(teste.id('co_acad'), (select id from public.movimentos where descricao = 'PIX ACADEMIA E PERSONAL'), 5000, 0, 0, 0, 'cora-vinc-acad1')).id;
-- depois de importar o extrato, a Internet foi "paga" à mão (o Simplifica criou outro lançamento)
insert into teste.ids select 'co_pag_net', (public.obrigacao_pagar(teste.id('co_net'), teste.id('co_conta'), '2026-10-09', 10000, 0, 0, 0, null, 'cora-paga-0001')).id;
insert into teste.ids select 'co_m_fat', id from public.movimentos where descricao = 'FATURA CARTAO ITAU';
insert into teste.ids select 'co_m_sant', id from public.movimentos where descricao = 'PAG BOLETO SANTANDER';
insert into teste.ids select 'co_m_net', id from public.movimentos where descricao = 'DEBITO INTERNET';
create function pg_temp.saldo() returns bigint language sql as $$ select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-14') where conta_id = teste.id('co_conta') $$;
\o

-- ------------------------------------------------------------ sugestões
select teste.igual((select string_agg(descricao || ' → ' || obrigacao, ' | ' order by descricao) from public.conciliacao_sugestoes(teste.id('co_conta'))),
  'DEBITO AUTOMATICO → Condominio Solar | FATURA CARTAO ITAU → Fatura Cartão Itaú 10/2026 | PAG BOLETO ENERGIA → Conta de luz | PAG BOLETO SANTANDER → Fatura Cartão Santander 10/2026 | PAG BOLETO SICREDI → Boleto cartão Sicredi | PIX ESCOLA AURORA → Escola Aurora',
  'sugestões: um lançamento por conta a pagar; data e nome pesam; fora de 20 dias não; Internet já paga e PIX já usado em parte não são sugeridos');
select teste.igual((select motivo from public.conciliacao_sugestoes(teste.id('co_conta')) where descricao like 'FATURA%'),
  'mesmo valor · mesmo dia do vencimento · nome na descrição · conta prevista para o pagamento', 'sugestão explica o motivo');
select teste.igual((select pendentes || ' ' || sugestoes || ' ' || divergencias from public.conciliacao_resumo() where conta_id = teste.id('co_conta')),
  '14 6 1', 'resumo da conta: 14 pendentes, 6 sugestões, 1 divergência');
select teste.igual((select restante_centavos || ' ' || valor_vincular_centavos || ' ' || motivo from public.conciliacao_sugestoes(teste.id('co_conta')) where descricao like '%SANTANDER'),
  '120050 8800 valor cobrado pelo banco na fatura (pagamento antecipado já descontado) · 6 dia(s) do vencimento · nome na descrição · conta prevista para o pagamento',
  'fatura com pagamento antecipado: sugere pelo valor cobrado pelo banco e vincula só esse valor');
select teste.igual((select string_agg(tipo || ':' || descricao || '=' || importado_descricao, ' ') from public.conciliacao_divergencias(teste.id('co_conta'))),
  'pagamento_duplicado:Internet=DEBITO INTERNET', 'divergência: Internet paga à mão e também no extrato');
select teste.igual(pg_temp.saldo(), 500000 - 10000 - 98765 - 54321 - 8800 - 31234 - 31234 - 10000 - 1500 + 50000 - 8800 - 4321 - 8000 - 8000 - 9000 - 9000 - 15500::bigint, 'antes: a Internet sai duas vezes do saldo');

-- ------------------------------------------------------------ confirmar uma sugestão
\o /dev/null
insert into teste.ids select 'co_pag_fat', (public.obrigacao_vincular_movimento(teste.id('co_fat'), teste.id('co_m_fat'), 98765, 0, 0, 0, 'cora-vinc-0001')).id;
\o
select teste.igual((select conciliacao || ' ' || classificacao || ' ' || pagamentos from public.conciliacao_lancamentos(teste.id('co_conta'), null, null) where movimento_id = teste.id('co_m_fat')),
  'pagamento pagamento_fatura Fatura Cartão Itaú 10/2026', 'confirmada: lançamento vira pagamento da fatura');
select teste.igual((select count(*)::int from public.conciliacao_sugestoes(teste.id('co_conta'))), 5, 'a sugestão confirmada sai da lista');
\o /dev/null
insert into teste.ids select 'co_pag_sant', (public.obrigacao_vincular_movimento(teste.id('co_fat_s'), teste.id('co_m_sant'), 8800, 0, 0, 0, 'cora-vinc-0002')).id;
-- uma reforma do mesmo valor da fatura, paga à mão no mesmo dia: o débito importado igual já está vinculado à fatura
insert into teste.ids select 'co_ref', (public.obrigacao_criar('Reforma', 98765, '2026-10-13', null, null, null, 'cora-obr-0009')).id;
select public.obrigacao_pagar(teste.id('co_ref'), teste.id('co_conta'), '2026-10-13', 98765, 0, 0, 0, null, 'cora-paga-0002');
-- gás pago à mão sem débito igual no extrato (há débitos próximos de outros valores)
insert into teste.ids select 'co_gas', (public.obrigacao_criar('Gás', 3333, '2026-10-12', null, null, null, 'cora-obr-0010')).id;
select public.obrigacao_pagar(teste.id('co_gas'), teste.id('co_conta'), '2026-10-12', 3333, 0, 0, 0, null, 'cora-paga-0003');
\o
select teste.igual((select string_agg(descricao, ' ') from public.conciliacao_divergencias(teste.id('co_conta')) where tipo = 'pagamento_duplicado'), 'Internet',
  'pagamento à mão só é divergência com débito importado de mesmo valor e ainda sem vínculo');
select teste.igual((select situacao || ' ' || (o.valor_centavos - coalesce((select sum(abatido_centavos) from public.pagamentos where obrigacao_id = o.id and situacao = 'ativo'), 0))
                      from public.obrigacoes o where o.id = teste.id('co_fat_s')),
  'aberta 111250', 'Santander: o boleto do extrato abate R$ 88,00; o pagamento antecipado fica em aberto para vincular');
select teste.igual((select count(*)::int from public.conciliacao_sugestoes(teste.id('co_conta')) where obrigacao_id = teste.id('co_fat_s')), 0,
  'o resto da fatura não é sugerido de novo pelo valor cobrado');
select teste.igual(pg_temp.saldo(), 500000 - 10000 - 98765 - 54321 - 8800 - 31234 - 31234 - 10000 - 1500 + 50000 - 8800 - 4321 - 8000 - 8000 - 9000 - 9000 - 15500 - 98765 - 3333::bigint, 'confirmar não mexe no saldo (a saída já estava contada); só a reforma e o gás pagos à mão saem');

-- ------------------------------------------------------------ trocar o pagamento à mão pelo do extrato
select teste.erro($q$ select public.conciliacao_trocar_pagamento(teste.id('co_pag_net'), 9, teste.id('co_m_net'), 'cora-troca-x01') $q$, '40001', 'versão desatualizada recusada');
select teste.erro($q$ select public.conciliacao_trocar_pagamento(teste.id('co_pag_net'), 1, (select id from public.movimentos where descricao = 'PADARIA'), 'cora-troca-x02') $q$,
  '22023', 'lançamento de outro valor recusado');
select teste.erro($q$ select public.conciliacao_trocar_pagamento(teste.id('co_pag_sant'), 1, (select id from public.movimentos where descricao = 'TED SANTANDER'), 'cora-troca-x03') $q$,
  '22023', 'vínculo (que não criou lançamento) não é trocado, mesmo com débito livre de mesmo valor');
\o /dev/null
select public.conciliacao_trocar_pagamento(teste.id('co_pag_net'), 1, teste.id('co_m_net'), 'cora-troca-0001');
\o
select teste.igual(pg_temp.saldo(), 500000 - 98765 - 54321 - 8800 - 31234 - 31234 - 10000 - 1500 + 50000 - 8800 - 4321 - 8000 - 8000 - 9000 - 9000 - 15500 - 98765 - 3333::bigint, 'trocado: a Internet sai uma vez só');
select teste.igual((select situacao || ' ' || cancelado_motivo from public.movimentos where id = (select movimento_id from public.pagamentos where id = teste.id('co_pag_net'))),
  'cancelado Trocado pelo lançamento do extrato importado', 'o lançamento feito à mão fica cancelado (não é apagado)');
select teste.igual((select conciliacao || ' ' || pagamentos from public.conciliacao_lancamentos(teste.id('co_conta'), null, null) where movimento_id = teste.id('co_m_net')),
  'pagamento Internet', 'o lançamento do extrato passa a pagar a Internet');
select teste.igual((select count(*)::int from public.obrigacoes o where o.id = teste.id('co_net')
                      and o.valor_centavos = (select sum(abatido_centavos) from public.pagamentos where obrigacao_id = o.id and situacao = 'ativo')), 1,
  'a Internet continua paga');
select teste.igual((select count(*)::int from public.conciliacao_divergencias(teste.id('co_conta')) where tipo = 'pagamento_duplicado'), 0, 'divergência resolvida');

-- ------------------------------------------------------------ desfazer com histórico
\o /dev/null
select public.pagamento_desfazer(teste.id('co_pag_fat'), (select versao from public.pagamentos where id = teste.id('co_pag_fat')), 'vinculei errado', false);
\o
select teste.igual((select conciliacao || ' ' || classificacao from public.conciliacao_lancamentos(teste.id('co_conta'), null, null) where movimento_id = teste.id('co_m_fat')),
  'pendente nao_classificado', 'desfeito: o lançamento volta a pendente, com a classificação que tinha');
select teste.igual((select count(*)::int from public.conciliacao_sugestoes(teste.id('co_conta')) where movimento_id = teste.id('co_m_fat')), 1, 'a sugestão volta');
select teste.igual((select string_agg(situacao || ':' || coalesce(desfeito_motivo, '-'), ' ' order by criado_em) from public.conciliacao_historico(teste.id('co_conta'))),
  'ativo:- desfeito:Trocado pelo lançamento do extrato importado desfeito:vinculei errado ativo:- ativo:- ativo:- ativo:-', 'histórico guarda os vínculos desfeitos e o motivo');

-- ------------------------------------------------------------ isolamento
\o /dev/null
select teste.como(teste.id('davi6'));
\o
select teste.igual(((select count(*) from public.conciliacao_lancamentos(null, null, null)) + (select count(*) from public.conciliacao_sugestoes(null))
                   + (select count(*) from public.conciliacao_divergencias(null)) + (select count(*) from public.conciliacao_historico(null)))::int, 0,
  'outro usuário não vê nada da conciliação da Cora');
select teste.erro($q$ select public.conciliacao_trocar_pagamento(teste.id('co_pag_net'), 2, teste.id('co_m_net'), 'davi6-troca-x01') $q$, 'P0002', 'outro usuário não troca pagamento da Cora');
reset role;
\o /dev/null
set role anon;
\o
select teste.erro($q$ select public.conciliacao_sugestoes(null) $q$, '42501', 'anônimo não consulta a conciliação');
reset role;
select teste.igual((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname like 'conciliacao\_%' and has_function_privilege('anon', oid, 'execute')), 0,
  'nenhuma função de conciliação executável por anônimo');
reset role;
