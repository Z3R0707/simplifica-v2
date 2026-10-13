-- Etapa 3 (0006): contas a pagar, pagamentos parciais, vínculos, recorrências, LGPD.
\set QUIET on
\o /dev/null
insert into teste.ids values ('tais', teste.novo_usuario('tais@exemplo.com', 'Taís')), ('ugo', teste.novo_usuario('ugo@exemplo.com', 'Ugo'));
select teste.como(teste.id('tais'));
insert into teste.ids select 't_tit', id from public.titulares where principal;
insert into teste.ids select 't_itau', (public.conta_criar(teste.id('t_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'tais-conta-itau')).id;
insert into teste.ids select 't_nu', (public.conta_criar(teste.id('t_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', 'corrente', 50000, '2026-10-01', null, null, true, true, 'tais-conta-nubank')).id;
insert into teste.ids select 't_moradia', id from public.categorias where nome = 'Moradia';
insert into teste.ids select 't_servicos', id from public.categorias where nome = 'Serviços e assinaturas';
insert into teste.ids select 't_salario', id from public.categorias where nome = 'Salário';
\o

-- ------------------------------------------------------------ criar
\o /dev/null
insert into teste.ids select 't_luz', (public.obrigacao_criar('Conta de luz', 20000, '2026-10-10', teste.id('t_servicos'), teste.id('t_itau'), null, 'tais-obr-luz-01')).id;
\o
select teste.igual((select situacao || ' ' || origem || ' ' || competencia from public.obrigacoes where id = teste.id('t_luz')), 'aberta avulsa 2026-10-01', 'conta a pagar nasce aberta, avulsa, mês de referência do vencimento');
select teste.igual((public.obrigacao_criar('Conta de luz', 20000, '2026-10-10', teste.id('t_servicos'), teste.id('t_itau'), null, 'tais-obr-luz-01')).id, teste.id('t_luz'), 'reenvio idêntico não duplica');
select teste.erro($q$ select public.obrigacao_criar('Conta de luz', 20001, '2026-10-10', teste.id('t_servicos'), teste.id('t_itau'), null, 'tais-obr-luz-01') $q$, 'SF409', 'mesma chave com outro valor é recusada');
select teste.erro($q$ select public.obrigacao_criar('x', 100, '2026-10-10', null, null, null, null) $q$, '22023', 'chave de idempotência obrigatória');
select teste.erro($q$ select public.obrigacao_criar('x', 0, '2026-10-10', null, null, null, 'tais-obr-x-0001') $q$, '23514', 'valor zero recusado');
select teste.erro($q$ select public.obrigacao_criar('x', 100, null, null, null, null, 'tais-obr-x-0002') $q$, '22023', 'vencimento obrigatório');
select teste.erro($q$ select public.obrigacao_criar('x', 100, '2026-10-10', teste.id('t_salario'), null, null, 'tais-obr-x-0003') $q$, '22023', 'categoria de receita recusada');
select teste.erro($q$ select public.obrigacao_criar(' ', 100, '2026-10-10', null, null, null, 'tais-obr-x-0004') $q$, '23514', 'descrição obrigatória');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('t_itau')), 100000::bigint, 'conta a pagar sozinha não mexe no saldo');
select teste.igual((select status || ' ' || restante_centavos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_luz')),
  case when privado.hoje() > '2026-10-10' then 'vencida 20000' else 'a_vencer 20000' end, 'vencida (ou a vencer) com restante total');

-- ------------------------------------------------------------ pagar parcial
\o /dev/null
create temp table pg1 as select * from public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-05', 8000, 0, 0, 0, null, 'tais-pag-luz-01');
\o
select teste.igual((select abatido_centavos || ' ' || origem || ' ' || situacao from pg1), '8000 pagamento ativo', 'pagamento parcial abate R$ 80');
select teste.igual((select natureza || ' ' || classificacao || ' ' || valor_centavos || ' ' || descricao || ' ' || situacao from public.movimentos where id = (select movimento_id from pg1)),
  'debito despesa 8000 Conta de luz efetivo', 'pagar cria a saída na conta, como despesa');
select teste.igual((select categoria_id from public.movimentos where id = (select movimento_id from pg1)), teste.id('t_servicos'), 'saída herda a categoria da conta a pagar');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('t_itau')), 92000::bigint, 'saldo cai R$ 80');
select teste.igual((select status || ' ' || abatido_centavos || ' ' || restante_centavos || ' ' || pagamentos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_luz')),
  case when privado.hoje() > '2026-10-10' then 'vencida 8000 12000 1' else 'parcial 8000 12000 1' end, 'restam R$ 120 (parcial não é paga)');
select teste.igual((public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-05', 8000, 0, 0, 0, null, 'tais-pag-luz-01')).id, (select id from pg1), 'reenvio do pagamento não paga duas vezes');
select teste.igual((select count(*) from public.movimentos where descricao = 'Conta de luz'), 1::bigint, 'reenvio não cria segunda saída');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-06', 12001, 0, 0, 0, null, 'tais-pag-luz-02') $q$, '22023', 'não abate mais do que falta (R$ 120)');
select teste.igual((select count(*) from public.movimentos where descricao = 'Conta de luz'), 1::bigint, 'pagamento recusado não deixa saída solta');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), privado.hoje() + 1, 100, 0, 0, 0, null, 'tais-pag-luz-03') $q$, '22023', 'pagamento com data futura recusado');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-06', 100, -1, 0, 0, null, 'tais-pag-luz-04') $q$, '22023', 'juros negativos recusados');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-06', 100, 100, 0, 0, null, 'tais-pag-luz-05') $q$, '22023', 'juros iguais ao valor pago (nada abatido) recusados');

-- quita com juros e multa: paga R$ 125 = 120 + 3 juros + 2 multa
\o /dev/null
create temp table pg2 as select * from public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_nu'), '2026-10-11', 12500, 300, 200, 0, 'atrasou', 'tais-pag-luz-06');
\o
select teste.igual((select abatido_centavos from pg2), 12000::bigint, 'pagamento com juros e multa abate só o principal');
select teste.igual((select status || ' ' || restante_centavos || ' ' || pago_centavos || ' ' || juros_centavos || ' ' || multa_centavos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_luz')),
  'paga 0 20500 300 200', 'conta fica paga; pagos R$ 205 com R$ 5 de encargos');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('t_nu')), 37500::bigint, 'saída de R$ 125 no Nubank');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_luz'), teste.id('t_itau'), '2026-10-11', 100, 0, 0, 0, null, 'tais-pag-luz-07') $q$, '22023', 'conta paga não aceita mais pagamento');
select teste.igual((select total_centavos from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Serviços e assinaturas'), 20500::bigint, 'resumo por categoria conta o que saiu (R$ 205)');

-- desconto: conta de R$ 100 paga com R$ 90 e R$ 10 de desconto
\o /dev/null
insert into teste.ids select 't_net', (public.obrigacao_criar('Internet', 10000, '2026-10-20', teste.id('t_servicos'), null, null, 'tais-obr-net-01')).id;
select public.obrigacao_pagar(teste.id('t_net'), teste.id('t_itau'), '2026-10-12', 9000, 0, 0, 1000, null, 'tais-pag-net-01');
\o
select teste.igual((select status || ' ' || pago_centavos || ' ' || desconto_centavos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_net')), 'paga 9000 1000', 'desconto quita a conta pagando menos');

-- ------------------------------------------------------------ proteções
select teste.erro(format($q$ select public.movimento_cancelar('%s', 1, 'quero cancelar') $q$, (select movimento_id from pg1)), '22023', 'saída que paga conta não pode ser cancelada');
select teste.erro(format($q$ select public.movimento_atualizar('%s', 1, 'debito', 7000, '2026-10-05', 'Conta de luz', 'despesa', '%s', null) $q$, (select movimento_id from pg1), teste.id('t_servicos')), '22023', 'saída não fica menor que o usado');
select teste.erro(format($q$ select public.movimento_atualizar('%s', 1, 'credito', 8000, '2026-10-05', 'Conta de luz', 'nao_classificado', null, null) $q$, (select movimento_id from pg1)), '22023', 'saída não muda de sentido');
select teste.igual((public.movimento_atualizar((select movimento_id from pg1), 1, 'debito', 8000, '2026-10-05', 'Luz outubro', 'despesa', teste.id('t_servicos'), null)).versao, 2, 'descrição da saída pode mudar');
select teste.erro(format($q$ select public.movimento_cancelar_parcial('%s', 100, '2026-10-06', 'parcial', 'tais-cp-luz-0001') $q$, (select movimento_id from pg1)), '22023', 'cancelamento parcial não invade o valor usado');
select teste.erro($q$ select public.obrigacao_cancelar(teste.id('t_luz'), 1, 'não devo mais') $q$, '22023', 'conta com pagamento não pode ser cancelada');
select teste.erro($q$ select public.obrigacao_atualizar(teste.id('t_luz'), 1, 'Conta de luz', 19000, '2026-10-10', teste.id('t_servicos'), teste.id('t_itau'), null) $q$, '22023', 'valor não fica menor que o pago');
select teste.erro(format($q$ update public.pagamentos set valor_pago_centavos = 1 where id = '%s' $q$, (select id from pg1)), '42501', 'gravação direta em pagamentos negada');
select teste.erro($q$ insert into public.obrigacoes (user_id, descricao, valor_centavos, vencimento, competencia) values (auth.uid(), 'x', 1, '2026-10-01', '2026-10-01') $q$, '42501', 'gravação direta em contas a pagar negada');
reset role;
select teste.erro(format($q$ update public.pagamentos set valor_pago_centavos = 1 where id = '%s' $q$, (select id from pg1)), '22023', 'pagamento é imutável (mesmo no banco)');
\o /dev/null
select teste.como(teste.id('tais'));
\o

-- ------------------------------------------------------------ desfazer
select teste.igual((select pagamento_id from public.pagamentos_da_obrigacao(teste.id('t_luz')) order by data_pagamento limit 1), (select id from pg1), 'histórico de pagamentos da conta');
select teste.erro(format($q$ select public.pagamento_desfazer('%s', 1, '', false) $q$, (select id from pg1)), '22023', 'desfazer exige motivo');
select teste.erro(format($q$ select public.pagamento_desfazer('%s', null, 'errado', false) $q$, (select id from pg1)), '22023', 'desfazer exige versão');
select teste.igual((public.pagamento_desfazer((select id from pg1), 1, 'paguei na conta errada', true)).situacao, 'desfeito', 'desfaz pagamento e cancela a saída');
select teste.igual((select situacao || ' ' || cancelado_motivo from public.movimentos where id = (select movimento_id from pg1)), 'cancelado paguei na conta errada', 'saída cancelada com o motivo');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('t_itau')), 91000::bigint, 'dinheiro volta ao saldo (1000 − 90 da internet)');
select teste.igual((select status || ' ' || restante_centavos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_luz')),
  case when privado.hoje() > '2026-10-10' then 'vencida 8000' else 'parcial 8000' end, 'conta volta a ter R$ 80 em aberto');
select teste.erro(format($q$ select public.pagamento_desfazer('%s', 2, 'de novo', false) $q$, (select id from pg1)), '22023', 'pagamento desfeito não se desfaz de novo');
select teste.igual((select motivo from public.auditoria where tabela = 'pagamentos' and registro_id = (select id from pg1) and operacao = 'UPDATE'), 'paguei na conta errada', 'desfazer auditado com motivo');

-- ------------------------------------------------------------ vincular saída já lançada
\o /dev/null
insert into teste.ids select 't_mov_luz', (public.movimento_criar(teste.id('t_itau'), 'debito', 10000, '2026-10-09', 'Débito automático', 'despesa', teste.id('t_servicos'), 'efetivo', null, 'tais-mov-luz-01')).id;
\o
select teste.igual((select livre_centavos from public.movimentos_para_vincular(teste.id('t_luz')) where movimento_id = teste.id('t_mov_luz')), 10000::bigint, 'saída já lançada aparece para vincular');
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('t_luz'), teste.id('t_mov_luz'), 10000, 0, 0, 0, 'tais-vin-luz-01') $q$, '22023', 'vínculo também respeita o restante (R$ 80)');
\o /dev/null
create temp table vin1 as select * from public.obrigacao_vincular_movimento(teste.id('t_luz'), teste.id('t_mov_luz'), 8000, 0, 0, 0, 'tais-vin-luz-02');
\o
select teste.igual((select status from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = teste.id('t_luz')), 'paga', 'vínculo quita a conta sem criar saída nova');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('t_itau')), 81000::bigint, 'saldo conta a saída uma única vez');
select teste.igual((select livre_centavos from public.movimentos_para_vincular(teste.id('t_net')) where movimento_id = teste.id('t_mov_luz')), 2000::bigint, 'saída mostra só o que sobrou livre (R$ 20)');
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('t_luz'), teste.id('t_mov_luz'), 100, 0, 0, 0, 'tais-vin-luz-03') $q$, '22023', 'mesmo vínculo não se repete');
select teste.igual((public.movimento_cancelar_parcial(teste.id('t_mov_luz'), 2000, '2026-10-10', 'devolveram', 'tais-cp-mov-0001')).valor_centavos, 2000::bigint, 'cancelamento parcial da parte livre é aceito');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('t_mov_luz'), 1, '2026-10-10', 'mais', 'tais-cp-mov-0002') $q$, '22023', 'e para aí: o resto paga a conta');
\o /dev/null
insert into teste.ids select 't_extra', (public.obrigacao_criar('Extra', 5000, '2026-10-20', null, null, null, 'tais-obr-extra-01')).id;
\o
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('t_extra'), teste.id('t_mov_luz'), 1, 0, 0, 0, 'tais-vin-extra-1') $q$, '22023', 'saída sem valor livre não paga outra conta');
select teste.erro(format($q$ select public.obrigacao_vincular_movimento(teste.id('t_extra'), '%s', 100, 0, 0, 0, 'tais-vin-extra-2') $q$,
  (select id from public.movimentos where estorno_de = teste.id('t_mov_luz'))), '22023', 'entrada (cancelamento parcial) não paga conta');
select teste.erro(format($q$ select public.pagamento_desfazer('%s', 1, 'errado', true) $q$, (select id from vin1)), '22023', 'vínculo não cancela o lançamento junto');
select teste.igual((public.pagamento_desfazer((select id from vin1), 1, 'vinculei errado', false)).situacao, 'desfeito', 'vínculo desfeito; o lançamento fica');
select teste.igual((select situacao from public.movimentos where id = teste.id('t_mov_luz')), 'efetivo', 'lançamento vinculado continua efetivo');

-- um lançamento pagando duas contas
\o /dev/null
insert into teste.ids select 't_mov_dois', (public.movimento_criar(teste.id('t_nu'), 'debito', 15000, '2026-10-12', 'Pix duas contas', 'nao_classificado', null, 'efetivo', null, 'tais-mov-dois-01')).id;
select public.obrigacao_vincular_movimento(teste.id('t_extra'), teste.id('t_mov_dois'), 5000, 0, 0, 0, 'tais-vin-dois-01');
select public.obrigacao_vincular_movimento(teste.id('t_luz'), teste.id('t_mov_dois'), 8000, 0, 0, 0, 'tais-vin-dois-02');
\o
select teste.igual((select string_agg(status, ',' order by descricao) from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id in (teste.id('t_luz'), teste.id('t_extra'))), 'paga,paga', 'um lançamento paga duas contas');
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('t_net'), teste.id('t_mov_dois'), 2001, 0, 0, 0, 'tais-vin-dois-03') $q$, '22023', 'soma usada não passa do lançamento (R$ 150)');

-- ------------------------------------------------------------ cancelar / reabrir / editar
\o /dev/null
insert into teste.ids select 't_iptu', (public.obrigacao_criar('IPTU', 30000, '2026-11-15', teste.id('t_moradia'), teste.id('t_itau'), null, 'tais-obr-iptu-01')).id;
\o
select teste.igual((public.obrigacao_atualizar(teste.id('t_iptu'), 1, 'IPTU 2026', 31000, '2026-12-15', teste.id('t_moradia'), null, 'cota única')).competencia, '2026-12-01'::date, 'editar avulsa acompanha o mês do vencimento');
select teste.erro($q$ select public.obrigacao_atualizar(teste.id('t_iptu'), 1, 'IPTU', 31000, '2026-12-15', null, null, null) $q$, '40001', 'versão desatualizada recusada');
select teste.igual((public.obrigacao_cancelar(teste.id('t_iptu'), 2, 'parcelei de outro jeito')).situacao, 'cancelada', 'conta sem pagamento pode ser cancelada');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_iptu'), teste.id('t_itau'), '2026-10-12', 100, 0, 0, 0, null, 'tais-pag-iptu-01') $q$, '22023', 'conta cancelada não recebe pagamento');
select teste.erro($q$ select public.obrigacao_atualizar(teste.id('t_iptu'), 3, 'IPTU', 31000, '2026-12-15', null, null, null) $q$, '22023', 'conta cancelada não é editada');
select teste.igual((select status from public.contas_a_pagar('2026-12-01', '2026-12-31') where obrigacao_id = teste.id('t_iptu')), 'cancelada', 'aparece como cancelada');
select teste.igual((public.obrigacao_reabrir(teste.id('t_iptu'), 3)).situacao, 'aberta', 'reabrir conta cancelada');

-- ------------------------------------------------------------ recorrências
\o /dev/null
create temp table rec1 as select * from public.recorrencia_criar('Aluguel', 150000, 31, date_trunc('month', privado.hoje())::date, null, false,
  teste.id('t_moradia'), teste.id('t_itau'), null, 'tais-rec-alug-01');
\o
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec1)), 2::bigint, 'recorrência gera o mês atual e o próximo');
select teste.igual((select vencimento from public.obrigacoes where recorrencia_id = (select id from rec1) and competencia = date_trunc('month', privado.hoje())::date),
  (date_trunc('month', privado.hoje()) + interval '1 month - 1 day')::date, 'dia 31 vira o último dia do mês');
select teste.igual((public.recorrencia_criar('Aluguel', 150000, 31, date_trunc('month', privado.hoje())::date, null, false, teste.id('t_moradia'), teste.id('t_itau'), null, 'tais-rec-alug-01')).id,
  (select id from rec1), 'reenvio não duplica a recorrência');
select teste.igual(public.recorrencias_gerar((privado.hoje() + interval '4 months')::date), 3, 'gerar até daqui a 4 meses cria 3 meses novos');
select teste.igual(public.recorrencias_gerar((privado.hoje() + interval '4 months')::date), 0, 'gerar de novo não duplica');
select teste.igual(public.recorrencias_gerar((privado.hoje() + interval '10 years')::date), 20, 'geração limitada a 24 meses à frente');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec1)), 25::bigint, '25 meses no total (atual + 24)');
select teste.erro($q$ select public.recorrencia_criar('x', 100, 10, (privado.hoje() - interval '13 months')::date, null, false, null, null, null, 'tais-rec-x-00001') $q$, '22023', 'início no máximo 12 meses atrás');
select teste.erro($q$ select public.recorrencia_criar('x', 100, 32, privado.hoje(), null, false, null, null, null, 'tais-rec-x-00002') $q$, '23514', 'dia de vencimento até 31');
select teste.erro($q$ select public.recorrencia_criar('x', 100, 10, privado.hoje(), null, true, null, null, null, 'tais-rec-x-00003') $q$, '22023', 'parcelas numeradas exigem último mês');

-- mês ajustado sozinho e alteração do modelo
\o /dev/null
create temp table mes_atual as select * from public.obrigacoes where recorrencia_id = (select id from rec1) and competencia = date_trunc('month', privado.hoje())::date;
select public.obrigacao_pagar((select id from mes_atual), teste.id('t_itau'), privado.hoje(), 50000, 0, 0, 0, null, 'tais-pag-alug-01');
create temp table mes_prox as select * from public.obrigacoes where recorrencia_id = (select id from rec1) and competencia = (date_trunc('month', privado.hoje()) + interval '1 month')::date;
select public.obrigacao_atualizar((select id from mes_prox), 1, 'Aluguel', 155000, (select vencimento from mes_prox), teste.id('t_moradia'), teste.id('t_itau'), 'reajuste');
select public.recorrencia_atualizar((select id from rec1), 1, 'Aluguel apto', 160000, 5, teste.id('t_moradia'), teste.id('t_itau'), null, true);
\o
select teste.igual((select valor_centavos || ' ' || descricao from public.obrigacoes where id = (select id from mes_atual)), '150000 Aluguel', 'mês com pagamento não muda com o modelo');
select teste.igual((select valor_centavos || ' ' || extract(day from vencimento) from public.obrigacoes where id = (select id from mes_prox)), '160000 5', 'mês aberto sem pagamento recebe o novo valor e dia');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec1) and valor_centavos = 160000 and descricao = 'Aluguel apto'), 24::bigint, 'todos os meses futuros abertos atualizados');

-- encerrar e retomar (um mês depois do último já tem pagamento parcial)
\o /dev/null
create temp table mes_pago_futuro as select * from public.obrigacoes where recorrencia_id = (select id from rec1) and competencia = (date_trunc('month', privado.hoje()) + interval '3 months')::date;
select public.obrigacao_pagar((select id from mes_pago_futuro), teste.id('t_itau'), privado.hoje(), 1000, 0, 0, 0, 'adiantado', 'tais-pag-alug-02');
\o
select teste.igual((public.recorrencia_definir_fim((select id from rec1), 2, (date_trunc('month', privado.hoje()) + interval '2 months')::date)).fim,
  (date_trunc('month', privado.hoje()) + interval '2 months')::date, 'define o último mês');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec1) and situacao = 'cancelada' and cancelada_motivo = 'Recorrência encerrada'), 21::bigint, 'meses depois do último são cancelados');
select teste.igual((select situacao from public.obrigacoes where id = (select id from mes_pago_futuro)), 'aberta', 'mês depois do último com pagamento continua aberto');
select teste.igual((select situacao from public.obrigacoes where id = (select id from mes_atual)), 'aberta', 'mês com pagamento nunca é cancelado pelo encerramento');
select teste.igual(public.recorrencias_gerar((privado.hoje() + interval '30 months')::date), 0, 'recorrência encerrada não gera mais meses');
select teste.igual((public.recorrencia_definir_fim((select id from rec1), 3, null)).fim, null::date, 'retomar sem fim');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec1) and situacao = 'aberta'), 25::bigint, 'retomada reabre os meses');

-- parcelas numeradas
\o /dev/null
create temp table rec2 as select * from public.recorrencia_criar('Geladeira', 30000, 10, date_trunc('month', privado.hoje())::date,
  (date_trunc('month', privado.hoje()) + interval '9 months')::date, true, null, null, null, 'tais-rec-gel-001');
select public.recorrencias_gerar((privado.hoje() + interval '2 years')::date);
\o
select teste.igual((select string_agg(descricao, ',' order by competencia) from public.obrigacoes where recorrencia_id = (select id from rec2) and competencia <= (date_trunc('month', privado.hoje()) + interval '1 month')::date),
  'Geladeira (1/10),Geladeira (2/10)', 'parcelas numeradas 1/10, 2/10');
select teste.igual((select count(*) from public.obrigacoes where recorrencia_id = (select id from rec2)), 10::bigint, 'para no último mês (10 parcelas)');
\o /dev/null
select public.recorrencia_atualizar((select id from rec2), 1, 'Geladeira nova', 30000, 10, null, null, null, true);
\o
select teste.igual((select descricao from public.obrigacoes where recorrencia_id = (select id from rec2) and competencia = (date_trunc('month', privado.hoje()) + interval '9 months')::date),
  'Geladeira nova (10/10)', 'alterar o modelo mantém a numeração');

-- ------------------------------------------------------------ resumo por conta (painel)
select teste.igual((select restante_centavos from public.contas_a_pagar_por_conta((date_trunc('month', privado.hoje()) + interval '1 month - 1 day')::date) where conta_prevista_id = teste.id('t_itau')),
  100000::bigint, 'a pagar no Itaú até o fim do mês: R$ 1.000 do aluguel (já pagos R$ 500)');

-- ------------------------------------------------------------ isolamento
reset role;
\o /dev/null
select teste.como(teste.id('ugo'));
\o
select teste.igual((select count(*) from public.obrigacoes), 0::bigint, 'outro usuário não vê contas a pagar alheias');
select teste.igual((select count(*) from public.contas_a_pagar('2000-01-01', '2100-01-01')), 0::bigint, 'nem pela consulta');
select teste.igual((select count(*) from public.pagamentos), 0::bigint, 'nem pagamentos');
select teste.erro($q$ select public.obrigacao_pagar(teste.id('t_net'), (select id from public.contas limit 1), '2026-10-12', 100, 0, 0, 0, null, 'ugo-pag-0000001') $q$, 'P0002', 'não paga conta a pagar alheia');
select teste.erro($q$ select public.obrigacao_cancelar(teste.id('t_iptu'), 4, 'invasão') $q$, 'P0002', 'não cancela conta a pagar alheia');
\o /dev/null
insert into teste.ids select 'u_tit', id from public.titulares where principal;
insert into teste.ids select 'u_conta', (public.conta_criar(teste.id('u_tit'), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 0, '2026-10-01', null, null, true, true, 'ugo-conta-0001')).id;
insert into teste.ids select 'u_obr', (public.obrigacao_criar('Ugo', 1000, '2026-10-20', null, null, null, 'ugo-obr-000001')).id;
\o
select teste.erro($q$ select public.obrigacao_vincular_movimento(teste.id('u_obr'), teste.id('t_mov_dois'), 100, 0, 0, 0, 'ugo-vin-000001') $q$, 'P0002', 'não vincula lançamento alheio');
select teste.erro($q$ select public.obrigacao_criar('x', 100, '2026-10-20', teste.id('t_moradia'), null, null, 'ugo-obr-000002') $q$, 'P0002', 'não usa categoria alheia');
select teste.erro($q$ select public.obrigacao_criar('x', 100, '2026-10-20', null, teste.id('t_itau'), null, 'ugo-obr-000003') $q$, 'P0002', 'não usa conta alheia');
reset role;
select teste.igual(has_function_privilege('anon', 'public.obrigacao_pagar(uuid, uuid, date, bigint, bigint, bigint, bigint, text, text)', 'execute'), false, 'anon não executa obrigacao_pagar');
select teste.igual((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute'))::int, 0, 'anon não executa nenhuma função do public');
select teste.igual((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'privado' and p.proname in ('reais', 'recorrencia_gerar', 'pagamento_validar') and has_function_privilege('authenticated', p.oid, 'execute'))::int, 0, 'funções internas novas fechadas');

-- ------------------------------------------------------------ LGPD
\o /dev/null
select teste.como(teste.id('tais'));
create temp table exp as select public.exportar_meus_dados() as j;
\o
select teste.igual((select jsonb_array_length(j->'contas_a_pagar') > 0 and jsonb_array_length(j->'pagamentos') > 0 and jsonb_array_length(j->'recorrencias') = 2 from exp), true, 'exportação inclui contas a pagar, pagamentos e recorrências');
reset role;
\o /dev/null
select teste.como(teste.id('tais'));
select public.exclusao_solicitar('tais@exemplo.com');
reset role;
set role service_role;
select public.exclusao_concluir(teste.id('tais'), 0, 1000);
reset role;
\o
select teste.igual((select count(*) from public.obrigacoes where user_id = teste.id('tais')) + (select count(*) from public.pagamentos where user_id = teste.id('tais'))
  + (select count(*) from public.recorrencias where user_id = teste.id('tais')) + (select count(*) from public.movimentos where user_id = teste.id('tais')), 0::bigint, 'exclusão da conta apaga contas a pagar, pagamentos e recorrências');
select teste.igual((select count(*) from public.obrigacoes where user_id = teste.id('ugo')), 1::bigint, 'dados do outro usuário intactos');
