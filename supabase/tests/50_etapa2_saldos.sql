-- Etapa 2 — movimentos, regra da data-base, saldos por conta, consolidado,
-- receitas/despesas por categoria, isolamento e LGPD.
-- Datas fixas no passado (efetivos não podem ter data futura).
\set QUIET on
\o /dev/null
insert into teste.ids values
  ('nina', teste.novo_usuario('nina@exemplo.com', 'Nina')),
  ('otto', teste.novo_usuario('otto@exemplo.com', 'Otto'));
select teste.como(teste.id('nina'));
insert into teste.ids select 'n_tit', id from public.titulares where principal;
insert into teste.ids select 'cat_alim', id from public.categorias where nome = 'Alimentação';
insert into teste.ids select 'cat_mor', id from public.categorias where nome = 'Moradia';
insert into teste.ids select 'cat_sal', id from public.categorias where nome = 'Salário';
insert into teste.ids select 'cat_reemb', id from public.categorias where nome = 'Reembolsos';
-- Exemplo da especificação (seção 4): cinco contas, consolidado R$ 13.250,00
insert into teste.ids select 'n2_santander', (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Santander'),   'Santander',    'corrente', 500000, '2026-10-01', null, null, true, true, 'nina-conta-santander')).id;
insert into teste.ids select 'n2_sicredi',   (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Sicredi'),     'Sicredi',      'corrente', 350000, '2026-10-01', null, null, true, true, 'nina-conta-sicredi')).id;
insert into teste.ids select 'n2_itau',      (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Itaú'),        'Itaú',         'corrente', 280000, '2026-10-01', null, null, true, true, 'nina-conta-itau')).id;
insert into teste.ids select 'n2_nubank',    (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Nubank'),      'Nubank',       'pagamento', 120000, '2026-10-01', null, null, true, true, 'nina-conta-nubank')).id;
insert into teste.ids select 'n2_mp',        (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Mercado Pago'),'Mercado Pago', 'pagamento',  75000, '2026-10-01', null, null, true, true, 'nina-conta-mp')).id;
\o

-- ------------------------------------------------------------ consolidado inicial
select teste.igual((select saldo_confirmado_centavos from public.saldo_consolidado('2026-10-01')), 1325000::bigint, 'consolidado do exemplo da especificação = R$ 13.250,00');
select teste.igual((select contas_somadas from public.saldo_consolidado('2026-10-01')), 5, 'consolidado soma as 5 contas');
select teste.igual((select count(*) from public.saldos_por_conta('2026-10-01'))::int, 5, 'painel mostra cada conta separadamente');

-- ------------------------------------------------------------ data-base
\o /dev/null
insert into teste.ids select 'n2_m_ant', (public.movimento_criar(teste.id('n2_santander'), 'debito', 10000, '2026-09-30', 'Compra anterior à data-base', 'nao_classificado', null, 'efetivo', null, 'nina-mov-ant-01')).id;
insert into teste.ids select 'n2_m_dia', (public.movimento_criar(teste.id('n2_santander'), 'credito', 5000, '2026-10-01', 'Reembolso no próprio dia-base', 'receita', teste.id('cat_reemb'), 'efetivo', null, 'nina-mov-dia-01')).id;
insert into teste.ids select 'n2_m1', (public.movimento_criar(teste.id('n2_santander'), 'debito', 20000, '2026-10-02', 'Mercado', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-m1-0001')).id;
insert into teste.ids select 'n2_m2', (public.movimento_criar(teste.id('n2_santander'), 'credito', 100000, '2026-10-05', 'Salário', 'receita', teste.id('cat_sal'), 'efetivo', null, 'nina-mov-m2-0001')).id;
\o
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')), 580000::bigint,
  'saldo confirmado = inicial + movimentos APÓS a data-base (5.000 − 200 + 1.000 = 5.800)');
select teste.igual((select movimentos_no_saldo || '/' || movimentos_anteriores_data_base from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')), '2/2',
  'movimentos até a data-base (inclusive) ficam registrados mas fora do saldo');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-03') where conta_id = teste.id('n2_santander')), 480000::bigint, 'saldo numa data intermediária (03/10) = 4.800');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-01') where conta_id = teste.id('n2_santander')), 500000::bigint, 'na própria data-base o saldo é o inicial');
select teste.igual((select coalesce(saldo_confirmado_centavos::text, 'NULL') || ' ' || situacao from public.saldos_por_conta('2026-09-30') where conta_id = teste.id('n2_santander')),
  'NULL data_anterior_a_data_base', 'antes da data-base não há saldo confirmado');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_sicredi')), 350000::bigint, 'movimento numa conta não afeta outra do mesmo usuário');
select teste.igual((select saldo_confirmado_centavos from public.saldo_consolidado('2026-10-12')), 1405000::bigint, 'consolidado = soma dos saldos confirmados (13.250 + 800)');

-- ------------------------------------------------------------ previstos e efetivação
\o /dev/null
insert into teste.ids select 'n2_p1', (public.movimento_criar(teste.id('n2_santander'), 'debito', 30000, '2026-11-10', 'Aluguel', 'despesa', teste.id('cat_mor'), 'previsto', null, 'nina-prev-p1-001')).id;
\o
select teste.igual((select saldo_confirmado_centavos || '/' || saldo_projetado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')), '580000/550000',
  'previsto não altera o confirmado, só o projetado');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_santander'), 'debito', 100, '2026-10-01', 'Previsto na data-base', 'nao_classificado', null, 'previsto', null, 'nina-prev-ruim-1') $q$,
  '22023', 'previsto com data até a data-base é recusado');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_santander'), 'debito', 100, privado.hoje() + 1, 'Efetivo futuro', 'nao_classificado', null, 'efetivo', null, 'nina-efet-futuro') $q$,
  '22023', 'efetivo com data futura é recusado');
select teste.igual((public.movimento_efetivar(teste.id('n2_p1'), 1, '2026-10-10')).situacao, 'efetivo', 'previsto efetivado na mesma linha');
select teste.igual((select count(*) from public.movimentos where descricao = 'Aluguel')::int, 1, 'efetivação não cria segundo movimento');
select teste.igual((select saldo_confirmado_centavos || '/' || saldo_projetado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')), '550000/550000',
  'após efetivar, confirmado e projetado coincidem');
select teste.erro($q$ select public.movimento_efetivar(teste.id('n2_p1'), 2, '2026-10-10') $q$, '22023', 'efetivar de novo é recusado');

-- ------------------------------------------------------------ alteração, cancelamento, versão
select teste.erro($q$ select public.movimento_atualizar(teste.id('n2_m1'), null, 'debito', 25000, '2026-10-02', 'Mercado', 'despesa', teste.id('cat_alim'), null) $q$, '22023', 'alterar movimento sem versão é recusado');
select teste.igual((public.movimento_atualizar(teste.id('n2_m1'), 1, 'debito', 25000, '2026-10-02', 'Mercado', 'despesa', teste.id('cat_alim'), null)).versao, 2, 'alteração com versão aplica');
select teste.erro($q$ select public.movimento_atualizar(teste.id('n2_m1'), 1, 'debito', 1, '2026-10-02', 'x', 'despesa', teste.id('cat_alim'), null) $q$, '40001', 'versão antiga recusada');
select teste.erro($q$ select public.movimento_cancelar(teste.id('n2_m2'), 1, '') $q$, '22023', 'cancelar sem motivo é recusado');
select teste.igual((public.movimento_cancelar(teste.id('n2_m2'), 1, 'Lançado em duplicidade')).situacao, 'cancelado', 'cancelamento com motivo');
select teste.erro($q$ select public.movimento_cancelar(teste.id('n2_m2'), 2, 'de novo') $q$, '22023', 'cancelar duas vezes é recusado');
select teste.erro($q$ select public.movimento_atualizar(teste.id('n2_m2'), 2, 'credito', 1, '2026-10-05', 'x', 'receita', teste.id('cat_sal'), null) $q$, '22023', 'movimento cancelado não pode ser alterado');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')), 445000::bigint,
  'cancelado sai do saldo (5.000 − 250 − 300 = 4.450)');
select teste.igual((select count(*) from public.movimentos where id = teste.id('n2_m2'))::int, 1, 'cancelado continua registrado (não é apagado)');
select teste.igual((select motivo from public.auditoria where tabela = 'movimentos' and registro_id = teste.id('n2_m2') and operacao = 'UPDATE'), 'Lançado em duplicidade', 'cancelamento auditado com motivo');

-- ------------------------------------------------------------ extrato
select teste.igual((select saldo_apos_centavos from public.extrato_conta(teste.id('n2_santander')) where situacao = 'efetivo' and conta_no_saldo order by data_movimento desc limit 1), 445000::bigint,
  'extrato: saldo após o último movimento = saldo confirmado');
select teste.igual((select string_agg(descricao || ':' || conta_no_saldo, ', ' order by data_movimento) from public.extrato_conta(teste.id('n2_santander')) where data_movimento <= '2026-10-01'),
  'Compra anterior à data-base:false, Reembolso no próprio dia-base:false', 'extrato marca o que está fora do saldo');

-- ------------------------------------------------------------ idempotência
\o /dev/null
create temp table mv_orig as select * from public.movimento_criar(teste.id('n2_sicredi'), 'debito', 4590, '2026-10-06', 'Farmácia', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-farmacia');
\o
select teste.igual((select id from public.movimento_criar(teste.id('n2_sicredi'), 'debito', 4590, '2026-10-06', 'Farmácia', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-farmacia')),
  (select id from mv_orig), 'reenvio do mesmo lançamento devolve o mesmo movimento');
select teste.igual((select count(*) from public.movimentos where descricao = 'Farmácia')::int, 1, 'reenvio não duplica o lançamento');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_sicredi'), 'debito', 4599, '2026-10-06', 'Farmácia', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-farmacia') $q$,
  'SF409', 'mesma chave com valor diferente é recusada');
-- dois lançamentos iguais com chaves diferentes são legítimos (ex.: duas compras iguais no dia)
\o /dev/null
select public.movimento_criar(teste.id('n2_sicredi'), 'debito', 4590, '2026-10-06', 'Farmácia', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-farmacia-2');
\o
select teste.igual((select count(*) from public.movimentos where descricao = 'Farmácia')::int, 2, 'compras idênticas com chaves diferentes são mantidas');

-- ------------------------------------------------------------ mudança da data-base
\o /dev/null
select public.conta_atualizar(teste.id('n2_santander'), 1, teste.id('n_tit'), (select id from public.instituicoes where nome = 'Santander'),
  'Santander', 'corrente', 470000, '2026-10-05', null, null, true, true);
\o
select teste.igual((select saldo_confirmado_centavos || ' ' || movimentos_no_saldo || '/' || movimentos_anteriores_data_base from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_santander')),
  '440000 1/3', 'nova data-base (05/10, R$ 4.700): só conta o que vem depois (4.700 − 300)');

-- ------------------------------------------------------------ saldo inicial pendente, fora do consolidado, arquivada
\o /dev/null
insert into teste.ids select 'n2_pendente', (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú poupança', 'poupanca', 99900, '2026-10-01', null, null, false, true, 'nina-conta-pendente')).id;
insert into teste.ids select 'n2_fora', (public.conta_criar(teste.id('n_tit'), (select id from public.instituicoes where nome = 'Nubank'), 'Nubank caixinha', 'investimento', 1000000, '2026-10-01', null, null, true, false, 'nina-conta-fora')).id;
\o
select teste.igual((select coalesce(saldo_confirmado_centavos::text, 'NULL') || ' ' || situacao from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('n2_pendente')),
  'NULL saldo_inicial_nao_validado', 'saldo inicial não validado: sem saldo confirmado');
select teste.igual((select contas_pendentes || ' ' || completo from public.saldo_consolidado('2026-10-12')), '1 false', 'consolidado avisa conta pendente e se marca incompleto');
select teste.igual((select saldo_confirmado_centavos from public.saldo_consolidado('2026-10-12')), 1255820::bigint,
  'consolidado ignora a pendente e a conta fora do consolidado (4.400 + 3.408,20 + 2.800 + 1.200 + 750)');
\o /dev/null
select public.conta_definir_ativa(teste.id('n2_mp'), 1, false, 'conta encerrada');
\o
select teste.erro($q$ select public.movimento_criar(teste.id('n2_mp'), 'credito', 100, '2026-10-06', 'x', 'nao_classificado', null, 'efetivo', null, 'nina-mov-mp-arq') $q$,
  '22023', 'conta arquivada não recebe movimento');
select teste.igual((select contas_somadas from public.saldo_consolidado('2026-10-12')), 4, 'conta arquivada sai do consolidado');

-- ------------------------------------------------------------ validações de dados
select teste.erro($q$ select public.movimento_criar(teste.id('n2_itau'), 'debito', 0, '2026-10-06', 'zero', 'nao_classificado', null, 'efetivo', null, 'nina-mov-zero-01') $q$, '23514', 'valor zero recusado');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_itau'), 'debito', -100, '2026-10-06', 'neg', 'nao_classificado', null, 'efetivo', null, 'nina-mov-neg-001') $q$, '23514', 'valor negativo recusado (o sentido vem da natureza)');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_itau'), 'credito', 100, '2026-10-06', 'x', 'receita', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-cat-err') $q$, '22023', 'categoria de despesa não classifica receita');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_itau'), 'credito', 100, '2026-10-06', 'x', 'receita', null, 'efetivo', null, 'nina-mov-sem-cat') $q$, '23514', 'receita exige categoria');
select teste.erro($q$ insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao) values (teste.id('nina'), teste.id('n2_itau'), 'credito', 1, '2026-10-06', 'x', 'nao_classificado') $q$,
  '42501', 'gravação direta na tabela de movimentos é negada');

-- ------------------------------------------------------------ receitas e despesas por categoria
select teste.igual((select string_agg(classificacao || ':' || categoria || '=' || total_centavos, ', ' order by classificacao, categoria) from public.resumo_categorias('2026-10-01', '2026-10-31')),
  'despesa:Alimentação=34180, despesa:Moradia=30000, receita:Reembolsos=5000',
  'resumo de outubro por categoria (inclui o reembolso do dia-base; exclui o cancelado)');
select teste.igual((select total_centavos from public.resumo_categorias('2026-10-01', '2026-10-31', teste.id('n2_santander')) where categoria = 'Alimentação'), 25000::bigint, 'resumo filtrado por conta');
\o /dev/null
select public.movimento_criar(teste.id('n2_sicredi'), 'credito', 2000, '2026-10-07', 'Estorno farmácia', 'despesa', teste.id('cat_alim'), 'efetivo', null, 'nina-mov-estorno');
\o
select teste.igual((select total_centavos from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'), 32180::bigint, 'estorno (crédito classificado como despesa) reduz a despesa');

-- ------------------------------------------------------------ isolamento
reset role;
\o /dev/null
select teste.como(teste.id('otto'));
\o
select teste.igual((select count(*) from public.movimentos)::int, 0, 'Otto não vê movimentos da Nina');
select teste.igual((select count(*) from public.saldos_por_conta())::int, 0, 'Otto não vê saldos da Nina');
select teste.igual((select count(*) from public.extrato_conta(teste.id('n2_santander')))::int, 0, 'Otto não vê o extrato da conta da Nina');
select teste.igual((select count(*) from public.resumo_categorias('2026-01-01', '2026-12-31'))::int, 0, 'Otto não vê o resumo da Nina');
select teste.erro($q$ select public.movimento_criar(teste.id('n2_santander'), 'debito', 100, '2026-10-06', 'invasão', 'nao_classificado', null, 'efetivo', null, 'otto-mov-invasao') $q$, 'P0002', 'Otto não lança na conta da Nina');
select teste.erro($q$ select public.movimento_cancelar(teste.id('n2_m1'), 2, 'invasão') $q$, 'P0002', 'Otto não cancela movimento da Nina');

-- ------------------------------------------------------------ LGPD com movimentos
\o /dev/null
insert into teste.ids select 'o_conta', (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicoob'),
  'Sicoob', 'corrente', 10000, '2026-10-01', null, null, true, true, 'otto-conta-sicoob')).id;
select public.movimento_criar(teste.id('o_conta'), 'debito', 500, '2026-10-02', 'Café', 'nao_classificado', null, 'efetivo', null, 'otto-mov-cafe-01');
\o
select teste.igual(jsonb_array_length(public.exportar_meus_dados() -> 'movimentos'), 1, 'exportação LGPD inclui os movimentos');
\o /dev/null
select public.exclusao_solicitar('otto@exemplo.com');
reset role;
set role service_role;
\o
select teste.igual((public.exclusao_concluir(teste.id('otto'))).status, 'concluida', 'exclusão de conta com movimentos é concluída');
reset role;
select teste.igual((select count(*) from public.movimentos where user_id = teste.id('otto'))::int, 0, 'movimentos do usuário excluído removidos');
select teste.igual((select count(*) from public.movimentos where user_id = teste.id('nina'))::int > 0, true, 'movimentos de outros usuários intactos');
\echo '== 50_etapa2_saldos: concluído =='
