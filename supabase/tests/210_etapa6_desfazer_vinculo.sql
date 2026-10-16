-- Etapa 6 parte 1c (0015): desfazer o vínculo de um lançamento com fatura
-- devolve a classificação original, também quando o mesmo lançamento pagou
-- duas faturas. Dados fictícios.
\set QUIET on
\o /dev/null
insert into teste.ids values ('vera', teste.novo_usuario('vera@exemplo.com', 'Vera'));
select teste.como(teste.id('vera'));
insert into teste.ids select 'v_tit', id from public.titulares where principal;
insert into teste.ids select 'v_alim', id from public.categorias where nome = 'Alimentação';
insert into teste.ids select 'v_feira', (public.categoria_criar('Feira', 'despesa', null, null, 'vera-cat-feira01')).id;
insert into teste.ids select 'v_pada', (public.categoria_criar('Padaria', 'despesa', null, null, 'vera-cat-pada001')).id;
insert into teste.ids select 'v_itau', (public.conta_criar(teste.id('v_tit'), (select id from public.instituicoes where nome = 'Itaú'),
  'Itaú', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'vera-conta-itau1')).id;
-- cartão fecha 3, vence 10: compra em 02/10 cai na fatura 10/2026, em 05/10 na 11/2026
insert into teste.ids select 'v_nu', (public.cartao_criar(teste.id('v_tit'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', '4321', 500000, 3, 10, teste.id('v_itau'), 'vera-cartao-nu01')).id;
select public.compra_criar(teste.id('v_nu'), 'compra', null, '2026-10-02', 'Loja A', teste.id('v_alim'), 30000, 1, null, 1, null, null, 'vera-compra-0001');
select public.compra_criar(teste.id('v_nu'), 'compra', null, '2026-10-05', 'Loja B', teste.id('v_alim'), 20000, 1, null, 1, null, null, 'vera-compra-0002');
insert into teste.ids select 'v_f10', obrigacao_id from public.faturas where cartao_id = teste.id('v_nu') and competencia = '2026-10-01';
insert into teste.ids select 'v_f11', obrigacao_id from public.faturas where cartao_id = teste.id('v_nu') and competencia = '2026-11-01';
-- vincula um lançamento às duas faturas (R$ 300 + R$ 200) e guarda os ids dos vínculos
create function pg_temp.vincular_duas(p_mov uuid, p_chave text) returns void language sql as $$
  insert into teste.ids select p_chave || '1', (public.obrigacao_vincular_movimento(teste.id('v_f10'), p_mov, 30000, 0, 0, 0, p_chave || '-vinc-1')).id;
  insert into teste.ids select p_chave || '2', (public.obrigacao_vincular_movimento(teste.id('v_f11'), p_mov, 20000, 0, 0, 0, p_chave || '-vinc-2')).id $$;
create function pg_temp.desfazer(p_pag uuid) returns text language sql as $$
  select (public.pagamento_desfazer(p_pag, (select versao from public.pagamentos where id = p_pag), 'vinculei errado', false)).situacao $$;
create function pg_temp.cls(p_mov uuid) returns text language sql as $$
  select m.classificacao || ' ' || coalesce(c.nome, '-') from public.movimentos m left join public.categorias c on c.id = m.categoria_id where m.id = p_mov $$;
\o

-- ------------------------------------------------------------ o bug: desfaz o 1º vínculo e depois o 2º
\o /dev/null
insert into teste.ids select 'v_m1', (public.movimento_criar(teste.id('v_itau'), 'debito', 50000, '2026-10-11', 'Pix cartão', 'despesa', teste.id('v_alim'), 'efetivo', null, 'vera-mov-000001')).id;
select pg_temp.vincular_duas(teste.id('v_m1'), 'vera-a');
\o
select teste.igual(pg_temp.cls(teste.id('v_m1')), 'pagamento_fatura -', 'lançamento que paga duas faturas vira pagamento de fatura');
select teste.igual((select count(*)::int from public.pagamentos where movimento_id = teste.id('v_m1') and classificacao_anterior is not null), 1,
  'só o 1º vínculo guarda a classificação (no 2º ele já era pagamento de fatura)');
select teste.igual(pg_temp.desfazer(teste.id('vera-a1')), 'desfeito', 'desfaz o 1º vínculo');
select teste.igual(pg_temp.cls(teste.id('v_m1')), 'pagamento_fatura -', 'com o 2º vínculo ativo, continua pagamento de fatura');
select teste.igual(pg_temp.desfazer(teste.id('vera-a2')), 'desfeito', 'desfaz o 2º vínculo');
select teste.igual(pg_temp.cls(teste.id('v_m1')), 'despesa Alimentação', 'sem vínculo ativo, volta à classificação original (antes da 0015 ficava preso)');

-- ------------------------------------------------------------ ordem inversa: desfaz o 2º e depois o 1º
\o /dev/null
insert into teste.ids select 'v_m2', (public.movimento_criar(teste.id('v_itau'), 'debito', 50000, '2026-10-11', 'Pix cartão 2', 'despesa', teste.id('v_alim'), 'efetivo', null, 'vera-mov-000002')).id;
select pg_temp.vincular_duas(teste.id('v_m2'), 'vera-b');
select pg_temp.desfazer(teste.id('vera-b2'));
\o
select teste.igual(pg_temp.cls(teste.id('v_m2')), 'pagamento_fatura -', 'ordem inversa: com o 1º ativo, continua pagamento de fatura');
select teste.igual(pg_temp.desfazer(teste.id('vera-b1')), 'desfeito', 'ordem inversa: desfaz o 1º');
select teste.igual(pg_temp.cls(teste.id('v_m2')), 'despesa Alimentação', 'ordem inversa: volta à classificação original');

-- ------------------------------------------------------------ vale a classificação do vínculo mais recente
\o /dev/null
insert into teste.ids select 'v_m3', (public.movimento_criar(teste.id('v_itau'), 'debito', 50000, '2026-10-11', 'Pix cartão 3', 'despesa', teste.id('v_alim'), 'efetivo', null, 'vera-mov-000003')).id;
insert into teste.ids select 'vera-c0', (public.obrigacao_vincular_movimento(teste.id('v_f10'), teste.id('v_m3'), 30000, 0, 0, 0, 'vera-c-vinc-0')).id;
select pg_temp.desfazer(teste.id('vera-c0'));
\o
select teste.igual(pg_temp.cls(teste.id('v_m3')), 'despesa Alimentação', 'um vínculo só: desfeito, volta como antes');
\o /dev/null
select public.movimento_atualizar(teste.id('v_m3'), (select versao from public.movimentos where id = teste.id('v_m3')), 'debito', 50000, '2026-10-11',
  'Pix cartão 3', 'despesa', teste.id('v_feira'), null);
select pg_temp.vincular_duas(teste.id('v_m3'), 'vera-c');
select pg_temp.desfazer(teste.id('vera-c1'));
select pg_temp.desfazer(teste.id('vera-c2'));
\o
select teste.igual(pg_temp.cls(teste.id('v_m3')), 'despesa Feira', 'reclassificado entre um vínculo e outro: volta a última classificação, não a primeira');

-- ------------------------------------------------------------ categoria arquivada enquanto vinculado
\o /dev/null
insert into teste.ids select 'v_m4', (public.movimento_criar(teste.id('v_itau'), 'debito', 50000, '2026-10-11', 'Pix padaria', 'despesa', teste.id('v_pada'), 'efetivo', null, 'vera-mov-000004')).id;
select pg_temp.vincular_duas(teste.id('v_m4'), 'vera-d');
select public.categoria_atualizar(teste.id('v_pada'), (select versao from public.categorias where id = teste.id('v_pada')), 'Padaria', null, false);
select pg_temp.desfazer(teste.id('vera-d1'));
select pg_temp.desfazer(teste.id('vera-d2'));
\o
select teste.igual(pg_temp.cls(teste.id('v_m4')), 'nao_classificado -', 'categoria arquivada: volta sem categoria');

-- ------------------------------------------------------------ regras que não mudaram
select teste.erro($q$ select public.pagamento_desfazer(teste.id('vera-a1'), (select versao from public.pagamentos where id = teste.id('vera-a1')), 'de novo', false) $q$,
  '22023', 'desfazer de novo é recusado');
select teste.igual((select count(*)::int from public.pagamentos where movimento_id in (teste.id('v_m1'), teste.id('v_m2'), teste.id('v_m3'), teste.id('v_m4')) and situacao = 'ativo'), 0,
  'nenhum vínculo ficou ativo');
