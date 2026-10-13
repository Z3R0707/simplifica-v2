-- Etapa 5 parte 4 (0011): corrigir o valor de UMA parcela.
\set QUIET on
\o /dev/null
insert into teste.ids values ('nina5', teste.novo_usuario('nina5@exemplo.com', 'Nina')), ('otto5', teste.novo_usuario('otto5@exemplo.com', 'Otto'));
select teste.como(teste.id('nina5'));
insert into teste.ids select 'n5_conta', (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'),
  'Itaú', 'corrente', 500000, '2026-09-01', null, null, true, true, 'nina5-conta-001')).id;
insert into teste.ids select 'n5_cart', (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'),
  'Itaú Nina', null, null, 3, 13, teste.id('n5_conta'), 'nina5-cartao-01')).id;
-- compra em 4x de R$ 75,32 lançada em outubro (o banco cobra R$ 75,31 da 2ª em diante)
insert into teste.ids select 'n5_ml', (public.compra_criar(teste.id('n5_cart'), 'compra', null, '2026-10-05', 'Mercado online', null, null, 4, 7532, 1, null, null, 'nina5-compra-01')).id;
insert into teste.ids select 'n5_p2', id from public.parcelas where compra_id = teste.id('n5_ml') and numero = 2;
insert into teste.ids select 'n5_est', (public.compra_estornar(teste.id('n5_ml'), 1000, '2026-10-06', null, 'devolução parcial', 'nina5-estorno-1')).id;
create function pg_temp.fatura(p_parcela uuid) returns bigint language sql as $$
  select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = (select fatura_id from public.parcelas where id = p_parcela) and p.situacao = 'ativa' $$;
\o

select teste.igual(pg_temp.fatura(teste.id('n5_p2')), 7532::bigint, 'antes: a fatura da 2ª parcela tem R$ 75,32');
\o /dev/null
select public.parcela_alterar_valor(teste.id('n5_p2'), 7531, 'centavos do banco', 'nina5-valor-0001');
\o
select teste.igual((select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = teste.id('n5_ml')), '1:7532 2:7531 3:7532 4:7532',
  'só a parcela escolhida muda');
select teste.igual((select valor_total_centavos from public.compras where id = teste.id('n5_ml')), 30127::bigint, 'o total da compra acompanha (R$ 301,27)');
select teste.igual(pg_temp.fatura(teste.id('n5_p2')), 7531::bigint, 'a fatura passa a R$ 75,31');
select teste.igual((select vencimento::text || ' ' || valor_centavos from public.obrigacoes where id = (select obrigacao_id from public.faturas where id = (select fatura_id from public.parcelas where id = teste.id('n5_p2')))),
  '2026-12-13 7531', 'a conta a pagar da fatura (12/2026) acompanha');
select teste.igual((select motivo from public.auditoria where tabela = 'parcelas' and registro_id = teste.id('n5_p2') order by id desc limit 1), 'centavos do banco',
  'a mudança fica na auditoria, com o motivo');
select teste.igual((public.parcela_alterar_valor(teste.id('n5_p2'), 7531, 'centavos do banco', 'nina5-valor-0001')).valor_centavos, 7531::bigint,
  'repetir o mesmo pedido (mesma chave) não muda nada');
\o /dev/null
select public.parcela_alterar_valor(teste.id('n5_p2'), 7531, null, 'nina5-valor-0002');
\o
select teste.igual((select valor_total_centavos from public.compras where id = teste.id('n5_ml')), 30127::bigint, 'mesmo valor de novo: nada muda');

select teste.erro($q$ select public.parcela_alterar_valor(teste.id('n5_p2'), 0, null, 'nina5-valor-x001') $q$, '22023', 'valor zero recusado');
select teste.erro($q$ select public.parcela_alterar_valor(teste.id('n5_p2'), -100, null, 'nina5-valor-x002') $q$, '22023', 'valor negativo recusado');
select teste.erro($q$ select public.parcela_alterar_valor((select id from public.parcelas where compra_id = teste.id('n5_est')), 500, null, 'nina5-valor-x003') $q$, '22023',
  'parcela de estorno (crédito) não muda de valor');

-- fatura paga: subir é possível; baixar abaixo do pago, não
\o /dev/null
select public.obrigacao_pagar(f.obrigacao_id, teste.id('n5_conta'), '2026-10-10', 6532, 0, 0, 0, null, 'nina5-paga-0001')
  from public.faturas f where f.id = (select fatura_id from public.parcelas where compra_id = teste.id('n5_ml') and numero = 1);
\o
select teste.erro($q$ select public.parcela_alterar_valor((select id from public.parcelas where compra_id = teste.id('n5_ml') and numero = 1), 5000, null, 'nina5-valor-x004') $q$, '22023',
  'fatura paga: o total não fica abaixo do que já foi pago');
\o /dev/null
select public.parcela_alterar_valor((select id from public.parcelas where compra_id = teste.id('n5_ml') and numero = 1), 7600, 'banco cobrou mais', 'nina5-valor-0003');
\o
select teste.igual((select valor_centavos from public.obrigacoes where id = (select obrigacao_id from public.faturas where id = (select fatura_id from public.parcelas where compra_id = teste.id('n5_ml') and numero = 1))),
  6600::bigint, 'fatura paga: subir o valor aumenta a conta a pagar (R$ 76,00 − R$ 10,00 de estorno)');

-- parcela cancelada
\o /dev/null
select public.compra_cancelar(teste.id('n5_est'), (select versao from public.compras where id = teste.id('n5_est')), 'teste', true);
insert into teste.ids select 'n5_tv', (public.compra_criar(teste.id('n5_cart'), 'compra', null, '2026-10-05', 'TV', null, 20000, 2, null, 1, null, null, 'nina5-compra-02')).id;
select public.compra_cancelar(teste.id('n5_tv'), (select versao from public.compras where id = teste.id('n5_tv')), 'errei', true);
\o
select teste.erro($q$ select public.parcela_alterar_valor((select id from public.parcelas where compra_id = teste.id('n5_tv') and numero = 2), 9000, null, 'nina5-valor-x005') $q$, '22023',
  'parcela cancelada não muda de valor');

-- isolamento
\o /dev/null
select teste.como(teste.id('otto5'));
\o
select teste.erro($q$ select public.parcela_alterar_valor(teste.id('n5_p2'), 100, null, 'otto5-valor-x001') $q$, 'P0002', 'outro usuário não altera a parcela');
reset role;
\o /dev/null
set role anon;
\o
select teste.erro($q$ select public.parcela_alterar_valor(teste.id('n5_p2'), 100, null, 'anon-valor-x0001') $q$, '42501', 'anônimo não altera parcela');
reset role;
select teste.erro($q$ update public.parcelas set valor_centavos = 1 where id = teste.id('n5_p2') $q$, '22023', 'fora desta função, o valor continua travado');
