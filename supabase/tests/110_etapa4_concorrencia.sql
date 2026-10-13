-- Etapa 4 (0007): operações simultâneas reais (duas conexões via dblink).
\set QUIET on
\o /dev/null
insert into teste.ids values ('yuri', teste.novo_usuario('yuri@exemplo.com', 'Yuri'));
select teste.como(teste.id('yuri'));
insert into teste.ids select 'y_tit', id from public.titulares where principal;
insert into teste.ids select 'y_conta', (public.conta_criar(teste.id('y_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'yuri-conta-0001')).id;
insert into teste.ids select 'y_cart', (public.cartao_criar(teste.id('y_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', null, 1000000, 3, 10, teste.id('y_conta'), 'yuri-cartao-0001')).id;
-- fatura de outubro (fechada): R$ 100
insert into teste.ids select 'y_out', (public.compra_criar(teste.id('y_cart'), 'compra', null, '2026-10-02', 'Base outubro', null, 10000, 1, null, 1, null, null, 'yuri-compra-0001')).id;
insert into teste.ids select 'y_out2', (public.compra_criar(teste.id('y_cart'), 'compra', null, '2026-10-02', 'Outra outubro', null, 5000, 1, null, 1, null, null, 'yuri-compra-0002')).id;
insert into teste.ids select 'y_10x', (public.compra_criar(teste.id('y_cart'), 'compra', null, '2026-10-05', 'Dez vezes', null, 100000, 10, null, 1, null, null, 'yuri-compra-0003')).id;
insert into teste.ids select 'y_est', (public.compra_criar(teste.id('y_cart'), 'compra', null, '2026-10-05', 'Para estornar', null, 10000, 1, null, 1, null, null, 'yuri-compra-0004')).id;
insert into teste.ids select 'y_ob_out', obrigacao_id from public.faturas where cartao_id = teste.id('y_cart') and competencia = '2026-10-01';
reset role;
select teste.c_abrir('a', teste.id('yuri'));
select teste.c_abrir('b', teste.id('yuri'));
\o

-- K1: duas compras ao mesmo tempo na mesma fatura (web × WhatsApp): nenhum valor se perde
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.compra_criar('%s', 'compra', null, '2026-10-06', 'K1 web', null, 1111, 1, null, 1, null, null, 'yuri-k1-a-00001')).id::text $q$, teste.id('y_cart')))), 36, 'K1: primeira compra em andamento');
select teste.c_disparar('b', format($q$ select (public.compra_criar('%s', 'compra', null, '2026-10-06', 'K1 whatsapp', null, 2222, 1, null, 1, null, null, 'yuri-k1-b-00001')).id::text $q$, teste.id('y_cart')));
select teste.igual(teste.c_bloqueada('b'), true, 'K1: segunda ESPERA a primeira (mesma fatura)');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(length(teste.c_resultado('b')), 36, 'K1: segunda também gravada');
select teste.igual((select o.valor_centavos from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = teste.id('y_cart') and f.competencia = '2026-11-01'),
  (select sum(p.valor_assinado_centavos) from public.parcelas p join public.faturas f on f.id = p.fatura_id where f.cartao_id = teste.id('y_cart') and f.competencia = '2026-11-01' and p.situacao = 'ativa')::bigint,
  'K1: conta a pagar da fatura soma as duas (sem perder atualização)');

-- K2: pagar a fatura inteira × cancelar uma compra dela
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.obrigacao_pagar('%s', '%s', '2026-10-10', 15000, 0, 0, 0, null, 'yuri-k2-a-00001')).id::text $q$, teste.id('y_ob_out'), teste.id('y_conta')))), 36, 'K2: pagamento da fatura em andamento');
select teste.c_disparar('b', format($q$ select (public.compra_cancelar('%s', 1, 'lancei errado', true)).situacao $q$, teste.id('y_out2')));
select teste.igual(teste.c_bloqueada('b'), true, 'K2: cancelamento ESPERA o pagamento');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'K2: cancelamento recusado (a fatura ficaria abaixo do pago)');

-- K3: cancelar a compra × antecipar parcelas dela
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(teste.c_executar('a', format($q$ select public.compra_antecipar('%s', array[6,7,8], null, 0, 'yuri-k3-a-00001')::text $q$, teste.id('y_10x'))), '3', 'K3: antecipação em andamento');
select teste.c_disparar('b', format($q$ select (public.compra_cancelar('%s', 1, 'devolvi', false)).situacao $q$, teste.id('y_10x')));
select teste.igual(teste.c_bloqueada('b'), true, 'K3: cancelamento ESPERA a antecipação');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'cancelada', 'K3: depois, o cancelamento vale para todas as parcelas ainda não cobradas (inclusive as antecipadas)');

-- K4: dois estornos de R$ 60 ao mesmo tempo numa compra de R$ 100
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.compra_estornar('%s', 6000, '2026-10-12', null, 'web', 'yuri-k4-a-00001')).id::text $q$, teste.id('y_est')))), 36, 'K4: primeiro estorno em andamento');
select teste.c_disparar('b', format($q$ select (public.compra_estornar('%s', 6000, '2026-10-12', null, 'whatsapp', 'yuri-k4-b-00001')).id::text $q$, teste.id('y_est')));
select teste.igual(teste.c_bloqueada('b'), true, 'K4: segundo ESPERA o primeiro');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(teste.c_resultado('b'), 'ERRO:22023', 'K4: segundo recusado (passaria do valor da compra)');

-- K5: duas compras parceladas cruzando as mesmas faturas não travam uma à outra para sempre
\o /dev/null
select teste.dblink_exec('a', 'begin');
\o
select teste.igual(length(teste.c_executar('a', format($q$ select (public.compra_criar('%s', 'compra', null, '2026-10-06', 'K5 a', null, 60000, 6, null, 1, null, null, 'yuri-k5-a-00001')).id::text $q$, teste.id('y_cart')))), 36, 'K5: compra 6x em andamento');
select teste.c_disparar('b', format($q$ select (public.compra_criar('%s', 'compra', null, '2026-10-06', 'K5 b', null, 40000, 4, null, 1, null, null, 'yuri-k5-b-00001')).id::text $q$, teste.id('y_cart')));
select teste.igual(teste.c_bloqueada('b'), true, 'K5: compra 4x ESPERA (mesmas faturas, mesma ordem)');
\o /dev/null
select teste.dblink_exec('a', 'commit');
\o
select teste.igual(length(teste.c_resultado('b')), 36, 'K5: segunda gravada depois, sem impasse');

-- Invariantes
select teste.igual((select count(*) from public.faturas f
  where (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa') > 0
    and not exists (select 1 from public.obrigacoes o where o.id = f.obrigacao_id and o.situacao = 'aberta'
                     and o.valor_centavos = (select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa')))::int,
  0, 'INVARIANTE: conta a pagar de cada fatura igual ao total da fatura');
select teste.igual((select count(*) from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id
  where (select coalesce(sum(pg.abatido_centavos), 0) from public.pagamentos pg where pg.obrigacao_id = o.id and pg.situacao = 'ativo')
      > greatest((select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa'), 0))::int,
  0, 'INVARIANTE: nenhuma fatura com pago acima do total');
select teste.igual((select count(*) from public.compras c where c.tipo in ('compra', 'encargo')
  and (select coalesce(sum(e.valor_total_centavos), 0) from public.compras e where e.estorno_de = c.id and e.situacao = 'ativa')
      > (select coalesce(sum(p.valor_centavos - p.desconto_centavos), 0) from public.parcelas p where p.compra_id = c.id and p.situacao = 'ativa'))::int,
  0, 'INVARIANTE: estornos nunca passam da compra');
\o /dev/null
select teste.c_fechar('a');
select teste.c_fechar('b');
\o
\echo '== 110_etapa4_concorrencia: concluído =='
