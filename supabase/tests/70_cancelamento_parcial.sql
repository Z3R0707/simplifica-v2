-- Cancelamento parcial (0005): regras, saldo, resumo e operações simultâneas.
\set QUIET on
\o /dev/null
insert into teste.ids values ('rita', teste.novo_usuario('rita@exemplo.com', 'Rita')), ('saulo', teste.novo_usuario('saulo@exemplo.com', 'Saulo'));
select teste.como(teste.id('rita'));
insert into teste.ids select 'r_tit', id from public.titulares where principal;
insert into teste.ids select 'r_conta', (public.conta_criar(teste.id('r_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'rita-conta-itau')).id;
insert into teste.ids select 'r_conta2', (public.conta_criar(teste.id('r_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', 'corrente', 0, '2026-10-01', null, null, true, true, 'rita-conta-nubank')).id;
insert into teste.ids select 'r_alim', id from public.categorias where nome = 'Alimentação';
insert into teste.ids select 'r_compra', (public.movimento_criar(teste.id('r_conta'), 'debito', 10000, '2026-10-03', 'Compra loja', 'despesa',
  teste.id('r_alim'), 'efetivo', null, 'rita-compra-0001')).id;
\o
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('r_conta')), 90000::bigint, 'compra de R$ 100 reduz o saldo (R$ 900)');

-- ------------------------------------------------------------ cancelamento parcial
\o /dev/null
create temp table cp1 as select * from public.movimento_cancelar_parcial(teste.id('r_compra'), 3000, '2026-10-06', 'Devolveram um item', 'rita-cp-000001');
\o
select teste.igual((select natureza || ' ' || classificacao || ' ' || valor_centavos from cp1), 'credito despesa 3000', 'cancelamento parcial cria lançamento de sentido contrário na mesma classificação');
select teste.igual((select estorno_de from cp1), teste.id('r_compra'), 'cancelamento parcial fica ligado ao original');
select teste.igual((select categoria_id from cp1), teste.id('r_alim'), 'cancelamento parcial herda a categoria');
select teste.igual((select descricao from cp1), 'Cancelamento parcial: Compra loja', 'descrição identifica o original');
select teste.igual((select valor_centavos || ' ' || situacao from public.movimentos where id = teste.id('r_compra')), '10000 efetivo', 'lançamento original continua intacto');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('r_conta')), 93000::bigint, 'saldo considera o líquido (R$ 930)');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-05') where conta_id = teste.id('r_conta')), 90000::bigint, 'cancelamento parcial vale a partir da data dele');
select teste.igual((select total_centavos from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'), 7000::bigint, 'resumo mostra R$ 70 na categoria');
select teste.igual((select motivo from public.auditoria where tabela = 'movimentos' and registro_id = (select id from cp1)), 'Devolveram um item', 'cancelamento parcial auditado com motivo');

-- idempotência
select teste.igual((select id from public.movimento_cancelar_parcial(teste.id('r_compra'), 3000, '2026-10-06', 'Devolveram um item', 'rita-cp-000001')), (select id from cp1), 'reenvio devolve o mesmo cancelamento parcial');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 3001, '2026-10-06', 'Devolveram um item', 'rita-cp-000001') $q$, 'SF409', 'mesma chave com valor diferente é recusada');

-- limites
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 7001, '2026-10-07', 'demais', 'rita-cp-000002') $q$, '22023', 'não cancela mais que o restante (R$ 70)');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 0, '2026-10-07', 'zero', 'rita-cp-000003') $q$, '22023', 'valor zero recusado');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 100, '2026-10-07', '', 'rita-cp-000004') $q$, '22023', 'motivo obrigatório');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 100, '2026-10-02', 'antes', 'rita-cp-000005') $q$, '22023', 'data anterior ao original recusada');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 100, privado.hoje() + 1, 'futuro', 'rita-cp-000006') $q$, '22023', 'data futura recusada');
select teste.erro(format($q$ select public.movimento_cancelar_parcial('%s', 100, '2026-10-07', 'de cancelamento', 'rita-cp-000007') $q$, (select id from cp1)), '22023', 'não cancela parcialmente um cancelamento parcial');

-- original protegido
select teste.erro($q$ select public.movimento_cancelar(teste.id('r_compra'), 1, 'cancelar tudo') $q$, '22023', 'original com cancelamento parcial ativo não é cancelado por completo');
select teste.erro($q$ select public.movimento_atualizar(teste.id('r_compra'), 1, 'debito', 2000, '2026-10-03', 'Compra loja', 'despesa', teste.id('r_alim'), null) $q$, '22023', 'original não fica menor que o já cancelado');
select teste.erro($q$ select public.movimento_atualizar(teste.id('r_compra'), 1, 'credito', 10000, '2026-10-03', 'Compra loja', 'despesa', teste.id('r_alim'), null) $q$, '22023', 'original não muda de sentido');
select teste.erro($q$ select public.movimento_atualizar(teste.id('r_compra'), 1, 'debito', 10000, '2026-10-03', 'Compra loja', 'despesa', (select id from public.categorias where nome = 'Lazer'), null) $q$, '22023', 'original não muda de categoria');
select teste.igual((public.movimento_atualizar(teste.id('r_compra'), 1, 'debito', 12000, '2026-10-03', 'Compra loja centro', 'despesa', teste.id('r_alim'), null)).versao, 2, 'original pode ter descrição alterada e valor aumentado');

-- cancelamento parcial: editar e desfazer
select teste.erro(format($q$ select public.movimento_atualizar('%s', 1, 'credito', 12001, '2026-10-06', 'x', 'despesa', '%s', null) $q$, (select id from cp1), teste.id('r_alim')), '22023', 'editar o cancelamento parcial respeita o limite (R$ 120)');
select teste.erro(format($q$ select public.movimento_atualizar('%s', 1, 'credito', 3000, '2026-10-06', 'x', 'despesa', (select id from public.categorias where nome = 'Lazer'), null) $q$, (select id from cp1)), '22023', 'cancelamento parcial não muda de categoria');
select teste.igual((public.movimento_cancelar((select id from cp1), 1, 'lançado errado')).situacao, 'cancelado', 'desfazer o cancelamento parcial');
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('r_conta')), 88000::bigint, 'saldo volta ao original (1.000 − 120)');
select teste.igual((public.movimento_cancelar(teste.id('r_compra'), 2, 'desistiu da compra')).situacao, 'cancelado', 'sem parciais ativos, o original pode ser cancelado por completo');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_compra'), 100, '2026-10-07', 'depois', 'rita-cp-000008') $q$, '22023', 'original cancelado não aceita cancelamento parcial');

-- receita também
\o /dev/null
insert into teste.ids select 'r_receita', (public.movimento_criar(teste.id('r_conta'), 'credito', 50000, '2026-10-04', 'Venda', 'receita',
  (select id from public.categorias where nome = 'Outras receitas'), 'efetivo', null, 'rita-receita-001')).id;
select public.movimento_cancelar_parcial(teste.id('r_receita'), 50000, '2026-10-05', 'cliente devolveu tudo', 'rita-cp-000009');
\o
select teste.igual((select saldo_confirmado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = teste.id('r_conta')), 100000::bigint, 'receita cancelada parcialmente pelo valor todo zera o efeito');
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_receita'), 1, '2026-10-05', 'mais um', 'rita-cp-000010') $q$, '22023', 'sem restante, não aceita mais cancelamento parcial');

-- gravação direta e vínculo imutável
select teste.erro(format($q$ insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao, estorno_de) values ('%s', '%s', 'credito', 1, '2026-10-06', 'x', 'nao_classificado', '%s') $q$,
  teste.id('rita'), teste.id('r_conta'), teste.id('r_receita')), '42501', 'gravação direta negada');

-- isolamento
reset role;
\o /dev/null
select teste.como(teste.id('saulo'));
\o
select teste.erro($q$ select public.movimento_cancelar_parcial(teste.id('r_receita'), 1, '2026-10-05', 'invasão', 'saulo-cp-000001') $q$, 'P0002', 'outro usuário não cancela parcialmente lançamento alheio');

-- vínculo não pode ser trocado nem apontar para outra conta (direto no banco, como dono)
reset role;
select teste.erro(format($q$ update public.movimentos set estorno_de = null where id = '%s' $q$, (select id from cp1)), '22023', 'vínculo do cancelamento parcial é imutável');
select teste.erro(format($q$ insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao, categoria_id, estorno_de)
  values ('%s', '%s', 'credito', 100, '2026-10-06', 'outra conta', 'despesa', '%s', '%s') $q$, teste.id('rita'), teste.id('r_conta2'), teste.id('r_alim'), teste.id('r_compra')),
  '22023', 'cancelamento parcial precisa ser da mesma conta');

-- ================================================================ simultâneos
\o /dev/null
select teste.como(teste.id('rita'));
insert into teste.ids select 'r_tv', (public.movimento_criar(teste.id('r_conta'), 'debito', 10000, '2026-10-08', 'Televisão', 'despesa',
  teste.id('r_alim'), 'efetivo', null, 'rita-tv-00000001')).id;
reset role;
select teste.c_abrir('a', teste.id('rita'));
select teste.c_abrir('b', teste.id('rita'));
\o
-- P1: dois cancelamentos parciais de R$ 60 ao mesmo tempo num lançamento de R$ 100
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.movimento_cancelar_parcial('%s', 6000, '2026-10-09', 'web', 'rita-p1-a-00001')).id::text $q$, teste.id('r_tv')))), 36, 'P1: primeiro cancelamento parcial em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar_parcial('%s', 6000, '2026-10-09', 'whatsapp', 'rita-p1-b-00001')).id::text $q$, teste.id('r_tv')));
select teste.igual(teste.c_bloqueada('b'), true, 'P1: segundo ESPERA o primeiro');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'P1: segundo recusado (passaria do valor original)');
select teste.igual((select sum(valor_centavos) from public.movimentos where estorno_de = teste.id('r_tv') and situacao <> 'cancelado'), 6000::numeric, 'P1: só R$ 60 cancelados');

-- P2: cancelamento total do original × cancelamento parcial
\o /dev/null
select teste.como(teste.id('rita'));
insert into teste.ids select 'r_livro', (public.movimento_criar(teste.id('r_conta'), 'debito', 5000, '2026-10-08', 'Livro', 'despesa',
  teste.id('r_alim'), 'efetivo', null, 'rita-livro-00001')).id;
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select (public.movimento_cancelar('%s', 1, 'desistiu')).situacao $q$, teste.id('r_livro'))), 'cancelado', 'P2: cancelamento total em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar_parcial('%s', 1000, '2026-10-09', 'parcial', 'rita-p2-b-00001')).id::text $q$, teste.id('r_livro')));
select teste.igual(teste.c_bloqueada('b'), true, 'P2: parcial ESPERA o total');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'P2: parcial recusado (original já cancelado)');

-- P3: cancelamento parcial primeiro × cancelamento total
\o /dev/null
select teste.como(teste.id('rita'));
insert into teste.ids select 'r_tenis', (public.movimento_criar(teste.id('r_conta'), 'debito', 8000, '2026-10-08', 'Tênis', 'despesa',
  teste.id('r_alim'), 'efetivo', null, 'rita-tenis-00001')).id;
reset role;
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.movimento_cancelar_parcial('%s', 2000, '2026-10-09', 'parcial', 'rita-p3-a-00001')).id::text $q$, teste.id('r_tenis')))), 36, 'P3: parcial em andamento');
select teste.c_disparar('b', format($q$ select (public.movimento_cancelar('%s', 1, 'total')).situacao $q$, teste.id('r_tenis')));
select teste.igual(teste.c_bloqueada('b'), true, 'P3: total ESPERA o parcial');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'P3: total recusado (há cancelamento parcial ativo)');

-- Invariante
select teste.igual((select count(*) from public.movimentos p
  where p.estorno_de is null and (select coalesce(sum(e.valor_centavos), 0) from public.movimentos e where e.estorno_de = p.id and e.situacao <> 'cancelado') > p.valor_centavos)::int,
  0, 'INVARIANTE: nenhum lançamento com cancelamentos parciais acima do valor');
select teste.igual((select count(*) from public.movimentos p where p.situacao = 'cancelado'
  and exists (select 1 from public.movimentos e where e.estorno_de = p.id and e.situacao <> 'cancelado'))::int,
  0, 'INVARIANTE: nenhum original cancelado com parcial ativo');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 70_cancelamento_parcial: concluído =='
