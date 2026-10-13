-- Etapa 4 (0007): cartões, faturas, compras, parcelas, antecipação, estorno,
-- pagamento de fatura, resumo, isolamento e LGPD.
\set QUIET on

-- ------------------------------------------------------------ datas da fatura (funções puras)
select teste.igual(privado.fatura_competencia('2026-10-02', 3, 10), '2026-10-01'::date, 'fecha dia 3 / vence dia 10: compra em 02/10 vence em outubro');
select teste.igual(privado.fatura_competencia('2026-10-03', 3, 10), '2026-11-01'::date, 'compra no dia do fechamento vai para a fatura seguinte');
select teste.igual(privado.fatura_competencia('2026-10-24', 25, 5), '2026-11-01'::date, 'fecha 25 / vence 5: compra em 24/10 vence em novembro');
select teste.igual(privado.fatura_competencia('2026-10-25', 25, 5), '2026-12-01'::date, 'fecha 25 / vence 5: compra em 25/10 vence em dezembro');
select teste.igual(privado.fatura_competencia('2026-12-31', 25, 5), '2027-02-01'::date, 'virada de ano');
select teste.igual(privado.fatura_fechamento('2026-11-01', 25, 5), '2026-10-25'::date, 'fatura de novembro (vence 5) fecha em 25/10');
select teste.igual(privado.fatura_fechamento('2026-10-01', 3, 10), '2026-10-03'::date, 'fatura de outubro (vence 10) fecha em 03/10');
select teste.igual(privado.fatura_fechamento('2027-02-01', 30, 31), '2027-02-27'::date, 'fevereiro: fechamento fica antes do vencimento (28/02)');

\o /dev/null
insert into teste.ids values ('wil', teste.novo_usuario('wil@exemplo.com', 'Wil')), ('xena', teste.novo_usuario('xena@exemplo.com', 'Xena'));
select teste.como(teste.id('wil'));
insert into teste.ids select 'w_tit', id from public.titulares where principal;
insert into teste.ids select 'w_itau', (public.conta_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'wil-conta-itau01')).id;
insert into teste.ids select 'w_alim', id from public.categorias where nome = 'Alimentação';
insert into teste.ids select 'w_lazer', id from public.categorias where nome = 'Lazer';
insert into teste.ids select 'w_juros', id from public.categorias where nome = 'Juros e encargos';
insert into teste.ids select 'w_nu', (public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', '1234', 500000, 3, 10, teste.id('w_itau'), 'wil-cartao-nu-01')).id;
insert into teste.ids select 'w_sant', (public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Santander'),
  'Santander', null, null, 25, 5, null, 'wil-cartao-sa-01')).id;
-- competência da fatura aberta hoje em cada cartão
create temp table hojef as select privado.fatura_competencia(privado.hoje(), 3, 10) as nu, privado.fatura_competencia(privado.hoje(), 25, 5) as sa;
\o

-- ------------------------------------------------------------ cartões
select teste.igual((public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', '1234', 500000, 3, 10, teste.id('w_itau'), 'wil-cartao-nu-01')).id, teste.id('w_nu'), 'reenvio do cadastro do cartão não duplica');
select teste.erro($q$ select public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'), 'nubank', null, null, 1, 9, null, 'wil-cartao-nu-02') $q$, '22023', 'nome repetido recusado');
select teste.erro($q$ select public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'), 'Outro', null, null, 5, 5, null, 'wil-cartao-x-001') $q$, '23514', 'fechamento igual ao vencimento recusado');
select teste.erro($q$ select public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'), 'Outro', '12a4', null, 5, 10, null, 'wil-cartao-x-002') $q$, '23514', 'final do cartão: 4 dígitos');
select teste.erro($q$ select public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes where nome = 'Nubank'), 'Outro', null, null, 32, 10, null, 'wil-cartao-x-003') $q$, '23514', 'dia de fechamento até 31');

-- ------------------------------------------------------------ compras e faturas
\o /dev/null
insert into teste.ids select 'w_c1', (public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-02', 'Mercado', teste.id('w_alim'), 10000, 1, null, 1, null, null, 'wil-compra-0001')).id;
\o
select teste.igual((select f.competencia || ' ' || f.fechamento || ' ' || f.vencimento from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = teste.id('w_c1')),
  '2026-10-01 2026-10-03 2026-10-10', 'compra de 02/10 cai na fatura que fecha 03/10 e vence 10/10');
select teste.igual((select o.origem || ' ' || o.valor_centavos || ' ' || o.vencimento || ' ' || o.descricao || ' ' || (o.conta_prevista_id = teste.id('w_itau'))
  from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('w_nu') and f.competencia = '2026-10-01'),
  'fatura 10000 2026-10-10 Fatura Nubank 10/2026 true', 'fatura vira UMA conta a pagar, paga pela conta do cartão');
select teste.igual((select count(*) from public.obrigacoes where origem <> 'fatura')::int, 0, 'a compra em si não vira conta a pagar');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('w_itau')), 1000000::bigint, 'compra no cartão não mexe no saldo da conta');
select teste.igual((select compra_id from public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-02', 'Mercado', teste.id('w_alim'), 10000, 1, null, 1, null, null, 'wil-compra-0001') x(compra_id)), teste.id('w_c1'), 'reenvio da compra não duplica');

-- parcelada em 10x (R$ 1.000), começa na fatura seguinte (compra depois do fechamento)
\o /dev/null
insert into teste.ids select 'w_tv', (public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-05', 'Televisão', teste.id('w_lazer'), 100000, 10, null, 1, null, null, 'wil-compra-0002')).id;
insert into teste.ids select 'w_r3', (public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-05', 'Fone', teste.id('w_lazer'), 10001, 3, null, 1, null, null, 'wil-compra-0003')).id;
\o
select teste.igual((select string_agg(numero || ':' || to_char(f.competencia, 'MM/YY'), ' ' order by numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where compra_id = teste.id('w_tv')),
  '1:11/26 2:12/26 3:01/27 4:02/27 5:03/27 6:04/27 7:05/27 8:06/27 9:07/27 10:08/27', 'parcelas 1/10 a 10/10, uma por fatura');
select teste.igual((select string_agg(valor_centavos::text, ',' order by numero) from public.parcelas where compra_id = teste.id('w_r3')), '3335,3333,3333', 'centavos que sobram ficam na 1ª parcela');
select teste.igual((select o.valor_centavos from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('w_nu') and f.competencia = '2026-11-01'), 13335::bigint, 'fatura de novembro: 100 + 33,35');
select teste.igual((select parcela || ' ' || valor_centavos from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2027-01-01')) where compra_id = teste.id('w_tv')),
  '3/10 10000', 'fatura mostra a parcela 3/10 (DATA | DESCRIÇÃO | PARCELA | VALOR)');

-- valor da parcela informado (12x de 99,90) e compra já em andamento (3/10)
\o /dev/null
insert into teste.ids select 'w_p12', (public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'Curso', null, null, 12, 9990, 1, null, null, 'wil-compra-0004')).id;
insert into teste.ids select 'w_ant', (public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-06-20', 'Geladeira antiga', teste.id('w_lazer'), 50000, 10, null, 3, null, null, 'wil-compra-0005')).id;
\o
select teste.igual((select valor_total_centavos || ' ' || (select count(*) from public.parcelas where compra_id = teste.id('w_p12')) from public.compras where id = teste.id('w_p12')), '119880 12', '12x de 99,90 = R$ 1.198,80');
select teste.igual((select min(numero) || '-' || max(numero) || ' ' || count(*) from public.parcelas where compra_id = teste.id('w_ant')), '3-10 8', 'compra em andamento: cria só da parcela 3 em diante');
select teste.igual((select f.competencia from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = teste.id('w_ant') and p.numero = 3), (select nu from hojef), 'parcela atual cai na fatura aberta hoje');

-- encargos e créditos
\o /dev/null
insert into teste.ids select 'w_iof', (public.compra_criar(teste.id('w_nu'), 'encargo', 'iof', '2026-10-06', 'IOF compra internacional', teste.id('w_juros'), 350, 1, null, 1, null, null, 'wil-compra-0006')).id;
insert into teste.ids select 'w_cred', (public.compra_criar(teste.id('w_nu'), 'credito', null, '2026-10-06', 'Cashback', null, 2000, 1, null, 1, null, null, 'wil-compra-0007')).id;
\o
select teste.igual((select natureza from public.compras where id = teste.id('w_iof')) || ' ' || (select natureza from public.compras where id = teste.id('w_cred')), 'debito credito', 'encargo soma, crédito abate');
select teste.igual((select valor_centavos from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01')) where compra_id = teste.id('w_cred')), -2000::bigint, 'crédito aparece negativo na fatura');
select teste.igual((select o.valor_centavos from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('w_nu') and f.competencia = '2026-11-01'),
  10000 + 3335 + 9990 + 350 - 2000 + (case when (select nu from hojef) = '2026-11-01' then 5000 else 0 end)::bigint, 'conta a pagar da fatura acompanha débitos e créditos');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, privado.hoje() + 1, 'Futuro', null, 100, 1, null, 1, null, null, 'wil-compra-x001') $q$, '22023', 'compra com data futura recusada');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'encargo', 'iof', '2026-10-06', 'IOF', null, 100, 2, null, 1, null, null, 'wil-compra-x002') $q$, '22023', 'só compras podem ser parceladas');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'estorno', null, '2026-10-06', 'x', null, 100, 1, null, 1, null, null, 'wil-compra-x003') $q$, '22023', 'estorno tem função própria');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'x', null, 100, 100, null, 1, null, null, 'wil-compra-x004') $q$, '22023', 'no máximo 99 parcelas');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'x', null, 1000, 2, 400, 1, null, null, 'wil-compra-x005') $q$, '22023', 'total e valor da parcela divergentes recusados');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'x', (select id from public.categorias where nome = 'Salário'), 100, 1, null, 1, null, null, 'wil-compra-x006') $q$, '22023', 'categoria de receita recusada');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'x', null, 100, 1, null, 1, '2026-09-01', null, 'wil-compra-x007') $q$, '22023', 'fatura não vence antes da compra');

-- limite
select teste.igual((select usado_centavos from public.cartoes_resumo() where cartao_id = teste.id('w_nu')),
  (select sum(valor_assinado_centavos) from public.parcelas where cartao_id = teste.id('w_nu') and situacao = 'ativa')::bigint, 'limite usado = tudo o que falta pagar, inclusive parcelas futuras');
select teste.igual((select disponivel_centavos + usado_centavos from public.cartoes_resumo() where cartao_id = teste.id('w_nu')), 500000::bigint, 'disponível = limite − usado');
select teste.igual((select disponivel_centavos from public.cartoes_resumo() where cartao_id = teste.id('w_sant')), null::bigint, 'cartão sem limite informado: disponível vazio');

-- ------------------------------------------------------------ estados da parcela
select teste.igual((select status from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-10-01')) where compra_id = teste.id('w_c1')), 'cobrada', 'fatura fechada: parcela cobrada (não quitada)');
select teste.igual((select status from public.parcelas_da_compra(teste.id('w_tv')) where numero = 10), 'a_cobrar', 'parcela de fatura futura: a cobrar');
select teste.igual((select situacao from public.faturas_do_cartao(teste.id('w_nu'), '2026-10-01', '2026-10-01')), 'vencida', 'fatura de outubro fechada e não paga: vencida');

-- ------------------------------------------------------------ pagar fatura
\o /dev/null
create temp table pf1 as select * from public.obrigacao_pagar((select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-10-01'),
  teste.id('w_itau'), '2026-10-10', 10000, 0, 0, 0, null, 'wil-pagfat-0001');
\o
select teste.igual((select classificacao || ' ' || coalesce(categoria_id::text, '-') || ' ' || descricao from public.movimentos where id = (select movimento_id from pf1)),
  'pagamento_fatura - Pagamento Fatura Nubank 10/2026', 'pagar a fatura lança "pagamento de fatura", sem categoria');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('w_itau')), 990000::bigint, 'pagamento da fatura sai do saldo');
select teste.igual((select situacao from public.faturas_do_cartao(teste.id('w_nu'), '2026-10-01', '2026-10-01')), 'paga', 'fatura fica paga');
select teste.igual((select status from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-10-01')) where compra_id = teste.id('w_c1')), 'quitada', 'parcela de fatura paga: quitada');
select teste.igual((select total_centavos from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'), 10000::bigint, 'resumo: a compra conta uma vez; o pagamento da fatura não é despesa');
select teste.igual((select count(*) from public.resumo_categorias('2026-10-01', '2026-10-31') where classificacao = 'pagamento_fatura')::int, 0, 'pagamento de fatura fora do resumo');
select teste.igual((select total_centavos from public.resumo_categorias('2026-11-01', '2026-11-30') where categoria = 'Lazer'), 10000 + 3335 + (case when (select nu from hojef) = '2026-11-01' then 5000 else 0 end)::bigint, 'parcelas entram no mês do vencimento da fatura');
select teste.igual((select count(*) from public.resumo_categorias('2026-10-01', '2026-10-31', teste.id('w_itau')) where categoria = 'Alimentação')::int, 0, 'filtrando uma conta bancária, o cartão fica de fora');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'credito', null, '2026-10-02', 'Ajuste', null, 500, 1, null, 1, '2026-10-01', null, 'wil-compra-x008') $q$, '22023', 'crédito numa fatura já paga recusado (lance na seguinte)');

-- conta a pagar da fatura só muda pelo cartão
select teste.erro(format($q$ select public.obrigacao_atualizar('%s', (select versao from public.obrigacoes where id = '%1$s'), 'x', 99, '2026-11-10', null, null, null) $q$, (select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01')), '22023', 'conta a pagar da fatura não é editada à mão');
select teste.erro(format($q$ select public.obrigacao_cancelar('%s', (select versao from public.obrigacoes where id = '%1$s'), 'não pagar') $q$, (select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01')), '22023', 'conta a pagar da fatura não é cancelada à mão');

-- vincular saída já lançada: vira "pagamento de fatura" e volta se desfeito
\o /dev/null
insert into teste.ids select 'w_pix', (public.movimento_criar(teste.id('w_itau'), 'debito', 5000, '2026-10-11', 'Pix Nubank', 'despesa', teste.id('w_alim'), 'efetivo', null, 'wil-mov-pix-0001')).id;
create temp table vf as select * from public.obrigacao_vincular_movimento((select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01'),
  teste.id('w_pix'), 5000, 0, 0, 0, 'wil-vinfat-0001');
\o
select teste.igual((select classificacao || ' ' || coalesce(categoria_id::text, '-') from public.movimentos where id = teste.id('w_pix')), 'pagamento_fatura -', 'saída vinculada à fatura deixa de ser despesa');
select teste.igual((select coalesce(sum(total_centavos), 0)::bigint from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'), 10000::bigint, 'e não é contada duas vezes');
select teste.igual((select motivo from public.auditoria where tabela = 'movimentos' and registro_id = teste.id('w_pix') and operacao = 'UPDATE' order by id limit 1), 'Vinculado ao pagamento de fatura', 'reclassificação auditada');
select teste.erro(format($q$ select public.movimento_atualizar('%s', 2, 'debito', 5000, '2026-10-11', 'Pix', 'despesa', '%s', null) $q$, teste.id('w_pix'), teste.id('w_alim')), '22023', 'enquanto paga a fatura, não volta a ser despesa');
select teste.igual((public.pagamento_desfazer((select id from vf), 1, 'vinculei errado', false)).situacao, 'desfeito', 'desfaz o vínculo');
select teste.igual((select classificacao || ' ' || (categoria_id = teste.id('w_alim'))::text from public.movimentos where id = teste.id('w_pix')), 'despesa true', 'lançamento volta a ser despesa na categoria original');

-- regras cruzadas
\o /dev/null
insert into teste.ids select 'w_boleto', (public.obrigacao_criar('Boleto', 3000, '2026-10-20', null, null, null, 'wil-obr-boleto-1')).id;
insert into teste.ids select 'w_mov2', (public.movimento_criar(teste.id('w_itau'), 'debito', 8000, '2026-10-11', 'Pix duplo', 'nao_classificado', null, 'efetivo', null, 'wil-mov-pix-0002')).id;
select public.obrigacao_vincular_movimento(teste.id('w_boleto'), teste.id('w_mov2'), 3000, 0, 0, 0, 'wil-vin-boleto-1');
\o
select teste.erro(format($q$ select public.obrigacao_vincular_movimento('%s', teste.id('w_mov2'), 1000, 0, 0, 0, 'wil-vin-misto-01') $q$,
  (select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01')), '22023', 'lançamento que já paga um boleto não paga fatura (use um só para a fatura)');
\o /dev/null
insert into teste.ids select 'w_boleto2', (public.obrigacao_criar('Boleto 2', 3000, '2026-10-20', null, null, null, 'wil-obr-boleto-2')).id;
insert into teste.ids select 'w_movpf', (public.movimento_criar(teste.id('w_itau'), 'debito', 1000, '2026-10-11', 'Pgto fatura avulso', 'pagamento_fatura', null, 'efetivo', null, 'wil-mov-pf-00001')).id;
\o
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('w_boleto2'), teste.id('w_movpf'), 1000, 0, 0, 0, 'wil-vin-misto-02') $q$, '22023', 'lançamento de pagamento de fatura não paga boleto');

-- pagamento parcial da fatura e redução do total
\o /dev/null
create temp table pf2 as select * from public.obrigacao_pagar((select obrigacao_id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-12-01'),
  teste.id('w_itau'), '2026-10-12', 25000, 0, 0, 0, 'adiantado', 'wil-pagfat-0002');
\o
select teste.igual((select situacao || ' ' || total_centavos || ' ' || pago_centavos || ' ' || restante_centavos from public.faturas_do_cartao(teste.id('w_nu'), '2026-12-01', '2026-12-01')),
  'aberta 28323 25000 3323', 'pagamento parcial adiantado: fatura de dezembro segue aberta com o restante');
select teste.erro(format($q$ select public.compra_cancelar('%s', 1, 'errado', true) $q$, teste.id('w_tv')), '22023', 'cancelar compra que deixaria uma fatura abaixo do já pago é recusado');

-- ------------------------------------------------------------ antecipação (parcelas 6, 7 e 8 de 10)
\o /dev/null
create temp table antes as select competencia, total_centavos from public.faturas_do_cartao(teste.id('w_nu'), '2026-01-01', '2028-12-01');
\o
select teste.erro($q$ select public.compra_antecipar(teste.id('w_tv'), array[6,7,8], '2026-10-01', 0, 'wil-antec-x0001') $q$, '22023', 'não antecipa para fatura já fechada');
select teste.erro($q$ select public.compra_antecipar(teste.id('w_tv'), array[6,7,8], null, 30000, 'wil-antec-x0002') $q$, '22023', 'desconto não pode cobrir tudo');
select teste.igual(public.compra_antecipar(teste.id('w_tv'), array[6,7,8], null, 3000, 'wil-antec-00001'), 3, 'antecipa 3 parcelas com R$ 30 de desconto');
select teste.igual(public.compra_antecipar(teste.id('w_tv'), array[6,7,8], null, 3000, 'wil-antec-00001'), 3, 'reenvio da antecipação não repete');
select teste.igual((select string_agg(numero || ':' || to_char(competencia, 'MM/YY') || ':' || to_char(fatura_original_competencia, 'MM/YY') || ':' || desconto_centavos, ' ' order by numero)
  from public.parcelas_da_compra(teste.id('w_tv')) where antecipada),
  (select string_agg(n || ':' || to_char(nu, 'MM/YY') || ':' || o || ':1000', ' ' order by n) from hojef, (values (6, '04/27'), (7, '05/27'), (8, '06/27')) v(n, o)),
  'parcelas vão para a fatura atual, guardam a fatura original e dividem o desconto');
select teste.igual((select a.total_centavos - d.total_centavos from antes a join public.faturas_do_cartao(teste.id('w_nu'), '2027-04-01', '2027-04-01') d on d.competencia = a.competencia), 10000::bigint, 'fatura futura (04/27) perde a parcela antecipada');
select teste.igual((select d.total_centavos - a.total_centavos from antes a join public.faturas_do_cartao(teste.id('w_nu'), (select nu from hojef), (select nu from hojef)) d on d.competencia = a.competencia), 27000::bigint, 'fatura atual recebe R$ 270 (300 − 30 de desconto)');
select teste.igual((select count(*) from public.parcelas where compra_id = teste.id('w_tv'))::int, 10, 'histórico preservado: nenhuma parcela apagada');
select teste.igual((select o.valor_centavos from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('w_nu') and f.competencia = '2027-04-01'),
  (select total_centavos from public.faturas_do_cartao(teste.id('w_nu'), '2027-04-01', '2027-04-01')), 'projeção: conta a pagar da fatura futura diminuiu junto');
select teste.erro($q$ select public.compra_antecipar(teste.id('w_tv'), array[6], null, 0, 'wil-antec-x0003') $q$, '22023', 'parcela já antecipada não é antecipada de novo');
select teste.erro($q$ select public.compra_antecipar(teste.id('w_tv'), array[1], null, 0, 'wil-antec-x0004') $q$, '22023', 'parcela que já está na fatura atual não é antecipada');
select teste.igual(public.antecipacao_desfazer(teste.id('w_tv'), array[8], 'antecipei a mais'), 1, 'desfaz a antecipação da parcela 8 (fatura atual ainda aberta)');
select teste.igual((select to_char(competencia, 'MM/YY') || ' ' || desconto_centavos || ' ' || antecipada from public.parcelas_da_compra(teste.id('w_tv')) where numero = 8), '06/27 0 false', 'parcela 8 volta à fatura original, sem desconto');

-- ------------------------------------------------------------ estorno
\o /dev/null
insert into teste.ids select 'w_sapato', (public.compra_criar(teste.id('w_sant'), 'compra', null, '2026-10-10', 'Sapato', teste.id('w_lazer'), 20000, 1, null, 1, null, null, 'wil-compra-0008')).id;
create temp table est1 as select * from public.compra_estornar(teste.id('w_sapato'), 5000, '2026-10-12', null, 'trocou o tamanho', 'wil-estorno-001');
\o
select teste.igual((select tipo || ' ' || natureza || ' ' || (estorno_de = teste.id('w_sapato')) || ' ' || (categoria_id = teste.id('w_lazer')) from est1), 'estorno credito true true', 'estorno: crédito ligado à compra, mesma categoria');
select teste.erro($q$ select public.compra_estornar(teste.id('w_sapato'), 15001, '2026-10-12', null, 'mais', 'wil-estorno-002') $q$, '22023', 'estorno não passa do valor da compra');
select teste.erro($q$ select public.compra_estornar(teste.id('w_sapato'), 100, '2026-10-09', null, 'antes', 'wil-estorno-003') $q$, '22023', 'estorno não é anterior à compra');
select teste.erro(format($q$ select public.compra_estornar('%s', 100, '2026-10-12', null, 'de estorno', 'wil-estorno-004') $q$, (select id from est1)), '22023', 'estorno não é estornado');
select teste.erro($q$ select public.compra_cancelar(teste.id('w_sapato'), 1, 'lancei errado', true) $q$, '22023', 'compra com estorno ativo não é removida inteira');
select teste.igual((select sum(total_centavos) from public.resumo_categorias('2026-11-01', '2026-11-30') where categoria = 'Lazer')
  - (select sum(valor_centavos) from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = teste.id('w_nu') and competencia = '2026-11-01')) where categoria = 'Lazer' and status <> 'cancelada'),
  15000::numeric, 'resumo: estorno reduz a despesa da categoria (200 − 50 no Santander)');

-- ------------------------------------------------------------ cancelamento (Santander: fecha 25, vence 5)
\o /dev/null
insert into teste.ids select 'w_3x', (public.compra_criar(teste.id('w_sant'), 'compra', null, '2026-09-20', 'Jaqueta', null, 30000, 3, null, 1, null, null, 'wil-compra-0009')).id;
insert into teste.ids select 'w_av', (public.compra_criar(teste.id('w_sant'), 'compra', null, '2026-09-20', 'Livro', null, 4000, 1, null, 1, null, null, 'wil-compra-0010')).id;
\o
select teste.igual((select string_agg(status, ',' order by numero) from public.parcelas_da_compra(teste.id('w_3x'))), 'cobrada,a_cobrar,a_cobrar', 'compra de setembro: 1ª parcela cobrada, demais a cobrar');
select teste.igual((public.compra_cancelar(teste.id('w_3x'), 1, 'devolvi na loja', false)).situacao, 'ativa', 'cancelar na loja: compra segue com a parcela já cobrada');
select teste.igual((select string_agg(status, ',' order by numero) from public.parcelas_da_compra(teste.id('w_3x'))), 'cobrada,cancelada,cancelada', 'só as parcelas ainda não cobradas foram canceladas');
select teste.igual((select o.situacao || ' ' || o.cancelada_motivo from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('w_sant') and f.competencia = '2026-12-01'),
  'cancelada Fatura sem valor a pagar', 'fatura que ficou sem valor: conta a pagar cancelada sozinha');
select teste.erro($q$ select public.compra_cancelar(teste.id('w_av'), 1, 'devolvi', false) $q$, '22023', 'tudo já cobrado: cancelar na loja pede estorno');
select teste.igual((public.compra_cancelar(teste.id('w_3x'), 2, 'lancei errado', true)).situacao, 'cancelada', 'lancei errado: remove todas as parcelas');
select teste.erro($q$ select public.compra_cancelar(teste.id('w_3x'), 3, 'de novo', true) $q$, '22023', 'compra cancelada não é cancelada de novo');
select teste.erro($q$ select public.compra_atualizar(teste.id('w_3x'), 3, 'x', null, null) $q$, '22023', 'compra cancelada não é editada');
select teste.igual((public.compra_atualizar(teste.id('w_av'), 1, 'Livro de receitas', teste.id('w_lazer'), 'presente')).categoria_id, teste.id('w_lazer'), 'descrição e categoria editáveis');

-- ------------------------------------------------------------ fatura: datas e conferência com o banco
\o /dev/null
create temp table fo as select * from public.faturas where cartao_id = teste.id('w_sant') and competencia = '2026-10-01';
select public.fatura_atualizar((select id from fo), (select versao from fo), '2026-09-26', '2026-10-06', 140053, null);
\o
select teste.igual((select total_centavos || ' ' || total_informado_centavos || ' ' || diferenca_centavos from public.faturas_do_cartao(teste.id('w_sant'), '2026-10-01', '2026-10-01')),
  '4000 140053 136053', 'conferência: total informado pelo banco × total calculado, diferença à parte (sem ajuste automático)');
select teste.igual((select o.vencimento from public.obrigacoes o where o.id = (select obrigacao_id from fo)), '2026-10-06'::date, 'novo vencimento vai para a conta a pagar');
select teste.erro(format($q$ select public.fatura_atualizar('%s', (select versao from public.faturas where id = '%1$s'), '2026-09-26', '2026-11-06', null, null) $q$, (select id from fo)), '22023', 'vencimento continua no mês da fatura');
select teste.erro(format($q$ select public.fatura_atualizar('%s', (select versao from public.faturas where id = '%1$s'), '2026-10-07', '2026-10-06', null, null) $q$, (select id from fo)), '22023', 'fechamento antes do vencimento');

-- ------------------------------------------------------------ cartão e titular arquivados
\o /dev/null
insert into teste.ids select 'w_tit2', (public.titular_criar('Esposa', 'wil-titular-0002')).id;
insert into teste.ids select 'w_cart2', (public.cartao_criar(teste.id('w_tit2'), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú Esposa', null, null, 1, 8, null, 'wil-cartao-it-01')).id;
\o
select teste.erro($q$ select public.titular_atualizar(teste.id('w_tit2'), 1, 'Esposa', false, null) $q$, '22023', 'titular com cartão ativo não é arquivado');
select teste.igual((public.cartao_definir_ativo(teste.id('w_cart2'), 1, false, 'cancelado no banco')).ativo, false, 'cartão arquivado');
select teste.erro($q$ select public.compra_criar(teste.id('w_cart2'), 'compra', null, '2026-10-06', 'x', null, 100, 1, null, 1, null, null, 'wil-compra-x009') $q$, '22023', 'cartão arquivado não recebe compra');

-- ------------------------------------------------------------ gravação direta e isolamento
select teste.erro($q$ insert into public.compras (user_id, cartao_id, tipo, data_compra, descricao, valor_total_centavos) values (auth.uid(), teste.id('w_nu'), 'compra', '2026-10-01', 'x', 1) $q$, '42501', 'gravação direta em compras negada');
select teste.erro($q$ update public.parcelas set valor_centavos = 1 where compra_id = teste.id('w_tv') $q$, '42501', 'gravação direta em parcelas negada');
select teste.erro($q$ update public.faturas set total_informado_centavos = 1 $q$, '42501', 'gravação direta em faturas negada');
reset role;
select teste.erro($q$ update public.parcelas set valor_centavos = 1 where compra_id = teste.id('w_tv') and numero = 9 $q$, '22023', 'valor da parcela é imutável (mesmo no banco)');
\o /dev/null
select teste.como(teste.id('xena'));
\o
select teste.igual((select count(*) from public.cartoes)::int + (select count(*) from public.faturas)::int + (select count(*) from public.compras)::int + (select count(*) from public.parcelas)::int, 0, 'outro usuário não vê cartões, faturas, compras nem parcelas');
select teste.igual((select count(*) from public.cartoes_resumo())::int, 0, 'nem pelo resumo');
select teste.igual((select count(*) from public.lancamentos_da_fatura((select id from public.faturas limit 1)))::int, 0, 'nem os lançamentos da fatura');
select teste.erro($q$ select public.compra_criar(teste.id('w_nu'), 'compra', null, '2026-10-06', 'x', null, 100, 1, null, 1, null, null, 'xena-compra-0001') $q$, 'P0002', 'não lança no cartão alheio');
select teste.erro($q$ select public.compra_estornar(teste.id('w_sapato'), 100, '2026-10-12', null, 'x', 'xena-estorno-001') $q$, 'P0002', 'não estorna compra alheia');
select teste.erro($q$ select public.compra_antecipar(teste.id('w_tv'), array[9], null, 0, 'xena-antec-0001') $q$, 'P0002', 'não antecipa compra alheia');
select teste.erro($q$ select public.cartao_criar(teste.id('w_tit'), (select id from public.instituicoes limit 1), 'X', null, null, 1, 9, null, 'xena-cartao-001') $q$, 'P0002', 'não usa titular alheio');
reset role;
select teste.igual(has_function_privilege('anon', 'public.compra_criar(uuid, text, text, date, text, uuid, bigint, integer, bigint, integer, date, text, text)', 'execute'), false, 'anon não executa compra_criar');
select teste.igual((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute'))::int, 0, 'anon não executa nenhuma função do public');
select teste.igual((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'privado'
  and p.proname in ('fatura_sincronizar', 'fatura_obter', 'parcela_validar', 'compra_validar') and has_function_privilege('authenticated', p.oid, 'execute'))::int, 0, 'funções internas novas fechadas');

-- ------------------------------------------------------------ invariantes
select teste.igual((select count(*) from public.faturas f
  where (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa') > 0
    and not exists (select 1 from public.obrigacoes o where o.id = f.obrigacao_id and o.situacao = 'aberta'
                     and o.valor_centavos = (select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa')))::int,
  0, 'INVARIANTE: toda fatura com valor tem conta a pagar aberta com o mesmo valor');
select teste.igual((select count(*) from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id
  where o.situacao = 'aberta' and (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa') <= 0)::int,
  0, 'INVARIANTE: fatura sem valor não tem conta a pagar aberta');
select teste.igual((select count(*) from public.compras c where c.tipo in ('compra', 'encargo')
  and (select coalesce(sum(e.valor_total_centavos), 0) from public.compras e where e.estorno_de = c.id and e.situacao = 'ativa')
      > (select coalesce(sum(p.valor_centavos - p.desconto_centavos), 0) from public.parcelas p where p.compra_id = c.id and p.situacao = 'ativa'))::int,
  0, 'INVARIANTE: estornos nunca passam do valor da compra');

-- ------------------------------------------------------------ LGPD
\o /dev/null
select teste.como(teste.id('wil'));
create temp table exp4 as select public.exportar_meus_dados() as j;
\o
select teste.igual((select jsonb_array_length(j->'cartoes') = 3 and jsonb_array_length(j->'faturas') > 10 and jsonb_array_length(j->'compras_cartao') > 5 and jsonb_array_length(j->'parcelas') > 20 from exp4), true, 'exportação inclui cartões, faturas, compras e parcelas');
reset role;
\o /dev/null
select teste.como(teste.id('wil'));
select public.exclusao_solicitar('wil@exemplo.com');
reset role;
set role service_role;
select public.exclusao_concluir(teste.id('wil'), 0, 1000);
reset role;
\o
select teste.igual((select count(*) from public.cartoes where user_id = teste.id('wil')) + (select count(*) from public.faturas where user_id = teste.id('wil'))
  + (select count(*) from public.compras where user_id = teste.id('wil')) + (select count(*) from public.parcelas where user_id = teste.id('wil'))
  + (select count(*) from public.obrigacoes where user_id = teste.id('wil')) + (select count(*) from public.movimentos where user_id = teste.id('wil')), 0::bigint,
  'exclusão da conta apaga cartões, faturas, compras, parcelas, contas a pagar e lançamentos');
