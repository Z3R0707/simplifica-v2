-- Etapa 6 parte 1b (0014): pagamentos mostrados na fatura importada (fatura
-- anterior × antecipado), registro pela conta ou pelo lançamento do extrato,
-- e conciliação de fatura com diferença de centavos. Dados fictícios.
\set QUIET on
\o /dev/null
insert into teste.ids values ('iris', teste.novo_usuario('iris@exemplo.com', 'Iris')), ('otto7', teste.novo_usuario('otto7@exemplo.com', 'Otto'));
insert into storage.objects (bucket_id, name, owner) values ('documentos', teste.id('iris') || '/importacoes/' || repeat('e', 64) || '.pdf', teste.id('iris'));
select teste.como(teste.id('iris'));
insert into teste.ids select 'ir_tit', id from public.titulares where principal;
insert into teste.ids select 'ir_itau', (public.conta_criar(teste.id('ir_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Conta Itaú', 'corrente', 500000, '2026-08-01', null, null, true, true, 'iris-conta-0001')).id;
insert into teste.ids select 'ir_nuc', (public.conta_criar(teste.id('ir_tit'), (select id from public.instituicoes where codigo_compe = '260'),
  'Conta Nubank', 'corrente', 300000, '2026-08-01', null, null, true, true, 'iris-conta-0002')).id;
-- cartão Nubank (fecha 7, vence 14) com conta de pagamento no Itaú
insert into teste.ids select 'ir_nu', (public.cartao_criar(teste.id('ir_tit'), (select id from public.instituicoes where codigo_compe = '260'),
  'Cartão Nubank', null, null, 7, 14, teste.id('ir_itau'), 'iris-cartao-001')).id;
select public.compra_criar(teste.id('ir_nu'), 'compra', null, '2026-08-10', 'Loja A', null, 37515, 1, null, 1, null, null, 'iris-compra-001');
select public.compra_criar(teste.id('ir_nu'), 'compra', null, '2026-09-10', 'Loja B', null, 61840, 1, null, 1, null, null, 'iris-compra-002');
insert into teste.ids select 'ir_f09', obrigacao_id from public.faturas where cartao_id = teste.id('ir_nu') and competencia = '2026-09-01';
insert into teste.ids select 'ir_f10', obrigacao_id from public.faturas where cartao_id = teste.id('ir_nu') and competencia = '2026-10-01';
-- fatura 10/2026 importada: soma R$ 618,40; o banco cobra R$ 593,41 (R$ 25,00 pagos em 16/09 e R$ 0,01 de saldo anterior)
create temp table impf as select * from public.importacao_fatura_criar(teste.id('ir_nu'), 'nubank-fatura-pdf', 'nubank.pdf', repeat('e', 64),
  teste.id('iris') || '/importacoes/' || repeat('e', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 61840, 59341,
  '[{"data":"2026-09-10","descricao":"Loja B","valor_centavos":61840,"tipo":"compra"}]',
  '[{"data":"2026-09-06","descricao":"Pagamento em 06 SET","valor_centavos":-37515},
    {"data":"2026-09-16","descricao":"Pagamento em 16 SET","valor_centavos":-2500},
    {"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":1},
    {"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":-1},
    {"data":"2026-09-20","descricao":"Estorno de pagamento","valor_centavos":500}]', 'iris-impf-0001');
-- transferência de R$ 25,00 do Itaú para a própria conta Nubank no mesmo dia: não é pagamento do cartão
select public.movimento_criar(teste.id('ir_itau'), 'debito', 2500, '2026-09-16', 'PIX TRANSF IRIS 16/09', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00001');
-- débito igual na conta Nubank, mas 8 dias depois: fora da janela de 3 dias
select public.movimento_criar(teste.id('ir_nuc'), 'debito', 2500, '2026-09-25', 'Pagamento de fatura', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00007');
create function pg_temp.restante(p uuid) returns bigint language sql as $$
  select o.valor_centavos - coalesce((select sum(abatido_centavos) from public.pagamentos where obrigacao_id = o.id and situacao = 'ativo'), 0) from public.obrigacoes o where o.id = p $$;
create function pg_temp.pags() returns text language sql as $$
  select string_agg(ordem || ':' || tipo || ':' || valor_centavos || ':' || coalesce(obrigacao, '-') || ':' || registrado || coalesce(':' || movimento_sugerido, ''), ' | ' order by ordem)
    from public.importacao_fatura_pagamentos((select id from impf)) $$;
\o

select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 1, teste.id('ir_nuc'), null, 'iris-reg-x0001') $q$, 'P0002',
  'prévia ainda não confirmada: nada a registrar');
select teste.igual((select count(*)::int from public.importacao_fatura_pagamentos((select id from impf))), 0, 'prévia não confirmada não lista pagamentos');
\o /dev/null
select public.importacao_fatura_confirmar((select id from impf), (select versao from public.importacoes_fatura where id = (select id from impf)), null, 'iris-conff-001');
\o

-- ------------------------------------------------------------ lista
select teste.igual(pg_temp.pags(),
  '1:fatura_anterior:37515:Fatura Cartão Nubank 09/2026:false | 2:antecipado:2500:Fatura Cartão Nubank 10/2026:false',
  'pagamento até o vencimento anterior quita a fatura anterior; depois, é antecipado desta; saldo restante e estorno não são pagamento; transferência e débito fora de 3 dias não são sugeridos');
select teste.igual((select conta_sugerida_id = teste.id('ir_nuc') from public.importacao_fatura_pagamentos((select id from impf)) where ordem = 2), true,
  'conta sugerida: a conta do mesmo banco do cartão');
\o /dev/null
insert into teste.ids select 'ir_m_nu', (public.movimento_criar(teste.id('ir_nuc'), 'debito', 2500, '2026-09-16', 'Pagamento de fatura', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00002')).id;
\o
select teste.igual((select movimento_sugerido_id = teste.id('ir_m_nu') and movimento_sugerido = 'Pagamento de fatura · Conta Nubank · 16/09/2026'
                      from public.importacao_fatura_pagamentos((select id from impf)) where ordem = 2), true,
  'débito da conta do mesmo banco é sugerido para o pagamento antecipado');

-- ------------------------------------------------------------ validações
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 2, null, null, 'iris-reg-x0002') $q$, '22023', 'sem conta e sem lançamento: recusado');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 2, teste.id('ir_nuc'), teste.id('ir_m_nu'), 'iris-reg-x0003') $q$, '22023', 'conta e lançamento juntos: recusado');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 9, teste.id('ir_nuc'), null, 'iris-reg-x0004') $q$, 'P0002', 'pagamento inexistente');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 3, teste.id('ir_nuc'), null, 'iris-reg-x0005') $q$, 'P0002', 'saldo restante (positivo) não é pagamento');

-- R$ 1,00 pago à mão na fatura anterior, no mesmo dia: outro valor, não conta como o pagamento da fatura,
-- mas o que falta pagar fica menor que o pagamento mostrado
\o /dev/null
insert into teste.ids select 'ir_p_100', (public.obrigacao_pagar(teste.id('ir_f09'), teste.id('ir_itau'), '2026-09-06', 100, 0, 0, 0, null, 'iris-paga-0001')).id;
\o
select teste.igual((select registrado::text from public.importacao_fatura_pagamentos((select id from impf)) where ordem = 1), 'false', 'pagamento de outro valor não conta como registrado');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 1, teste.id('ir_itau'), null, 'iris-reg-x0007') $q$, '22023',
  'pagamento maior que o que falta pagar na fatura: recusado');
\o /dev/null
select public.pagamento_desfazer(teste.id('ir_p_100'), 1, 'teste', true, null);
\o

-- ------------------------------------------------------------ registrar
\o /dev/null
insert into teste.ids select 'ir_p_ant', (public.importacao_fatura_registrar_pagamento((select id from impf), 1, teste.id('ir_itau'), null, 'iris-reg-00001')).id;
insert into teste.ids select 'ir_p_atc', (public.importacao_fatura_registrar_pagamento((select id from impf), 2, null, teste.id('ir_m_nu'), 'iris-reg-00002')).id;
\o
select teste.igual(pg_temp.restante(teste.id('ir_f09')) || ' ' || pg_temp.restante(teste.id('ir_f10')), '0 59340',
  'fatura anterior quitada pela conta escolhida; fatura atual abatida pelo antecipado (falta R$ 593,40)');
select teste.igual((select m.conta_id = teste.id('ir_itau') and m.data_movimento = '2026-09-06' and m.valor_centavos = 37515 and p.origem = 'pagamento'
                      from public.pagamentos p join public.movimentos m on m.id = p.movimento_id where p.id = teste.id('ir_p_ant')), true,
  'registrar pela conta lança a saída na data do pagamento mostrado na fatura');
select teste.igual((select origem || ' ' || (movimento_id = teste.id('ir_m_nu')) from public.pagamentos where id = teste.id('ir_p_atc')), 'vinculo true',
  'registrar pelo lançamento do extrato vincula, sem lançar outra saída');
select teste.igual(pg_temp.pags(),
  '1:fatura_anterior:37515:Fatura Cartão Nubank 09/2026:true | 2:antecipado:2500:Fatura Cartão Nubank 10/2026:true', 'os dois aparecem como registrados');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 2, teste.id('ir_nuc'), null, 'iris-reg-x0006') $q$, '23505', 'registrar de novo é recusado');
select teste.igual((select id from public.importacao_fatura_registrar_pagamento((select id from impf), 2, null, teste.id('ir_m_nu'), 'iris-reg-00002')), teste.id('ir_p_atc'),
  'mesma chave devolve o mesmo pagamento (idempotente)');
\o /dev/null
select public.pagamento_desfazer(teste.id('ir_p_atc'), (select versao from public.pagamentos where id = teste.id('ir_p_atc')), 'teste', false, null);
\o
select teste.igual((select registrado::text from public.importacao_fatura_pagamentos((select id from impf)) where ordem = 2), 'false', 'desfeito o vínculo, o pagamento volta a não registrado');
-- o mesmo débito usado para outra conta a pagar não é sugerido
\o /dev/null
insert into teste.ids select 'ir_outra', (public.obrigacao_criar('Outra conta', 2500, '2026-09-16', null, null, null, 'iris-obr-00001')).id;
insert into teste.ids select 'ir_p_outra', (public.obrigacao_vincular_movimento(teste.id('ir_outra'), teste.id('ir_m_nu'), 2500, 0, 0, 0, 'iris-vinc-00001')).id;
\o
select teste.igual((select coalesce(movimento_sugerido, '-') from public.importacao_fatura_pagamentos((select id from impf)) where ordem = 2), '-',
  'débito já vinculado a outra conta a pagar não é sugerido');
\o /dev/null
select public.pagamento_desfazer(teste.id('ir_p_outra'), 1, 'teste', false, null);
select public.obrigacao_cancelar(teste.id('ir_outra'), 1, 'teste', 'iris-canc-00001');
\o
\o /dev/null
select public.importacao_fatura_registrar_pagamento((select id from impf), 2, null, teste.id('ir_m_nu'), 'iris-reg-00003');
\o

-- ------------------------------------------------------------ conciliação com centavos
\o /dev/null
-- o débito da fatura na conta Nubank: R$ 593,41 (o banco cobra R$ 0,01 de saldo anterior)
insert into teste.ids select 'ir_m_fat', (public.movimento_criar(teste.id('ir_nuc'), 'debito', 59341, '2026-10-14', 'Pagamento de fatura', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00003')).id;
-- cartão Itaú (vence 13) com fatura de R$ 100,00
insert into teste.ids select 'ir_it', (public.cartao_criar(teste.id('ir_tit'), (select id from public.instituicoes where codigo_compe = '341'),
  'Cartão Itaú', null, null, 3, 13, teste.id('ir_itau'), 'iris-cartao-002')).id;
select public.compra_criar(teste.id('ir_it'), 'compra', null, '2026-09-05', 'Loja C', null, 10000, 1, null, 1, null, null, 'iris-compra-003');
insert into teste.ids select 'ir_fi', obrigacao_id from public.faturas where cartao_id = teste.id('ir_it') and competencia = '2026-10-01';
-- R$ 99,97 saindo da conta Nubank sem nome do banco: não serve; R$ 98,00 com o nome: diferença grande demais
select public.movimento_criar(teste.id('ir_nuc'), 'debito', 9997, '2026-10-13', 'TRANSFERENCIA', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00004');
select public.movimento_criar(teste.id('ir_nuc'), 'debito', 9800, '2026-10-13', 'PAGTO FATURA ITAU', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00005');
-- conta a pagar que não é fatura: centavos de diferença não valem, mesmo com o nome
select public.obrigacao_criar('Energia Solar', 5000, '2026-10-13', null, null, null, 'iris-obr-00002');
select public.movimento_criar(teste.id('ir_itau'), 'debito', 4998, '2026-10-13', 'ENERGIA SOLAR', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00008');
\o
select teste.igual((select string_agg(descricao || '→' || obrigacao || ':' || valor_vincular_centavos || '+' || juros_centavos || '-' || desconto_centavos, ' | ' order by descricao)
                      from public.conciliacao_sugestoes(null) where e_fatura),
  'Pagamento de fatura→Fatura Cartão Nubank 10/2026:59341+1-0',
  'fatura com R$ 0,01 de diferença na conta do mesmo banco: sugerida, diferença como acréscimo; sem nome/outro banco ou diferença ≥ R$ 1,00: não');
select teste.igual((select count(*)::int from public.conciliacao_sugestoes(null) where not e_fatura), 0, 'conta a pagar comum com centavos de diferença: não sugerida');
select teste.igual((select motivo from public.conciliacao_sugestoes(null) where obrigacao like 'Fatura Cartão Nubank%'),
  'banco cobrou R$ 0,01 a mais (entra como acréscimo) · mesmo dia do vencimento · conta do mesmo banco do cartão', 'motivo explica a diferença');
\o /dev/null
select public.movimento_criar(teste.id('ir_itau'), 'debito', 9997, '2026-10-13', 'SAQUE', 'nao_classificado', null, 'efetivo', null, 'iris-mov-00006');
\o
select teste.igual((select valor_vincular_centavos || '+' || juros_centavos || '-' || desconto_centavos from public.conciliacao_sugestoes(null) where obrigacao like 'Fatura Cartão Itaú%'),
  '9997+0-3', 'R$ 0,03 a menos, na conta do mesmo banco do cartão: entra como desconto');
\o /dev/null
select public.obrigacao_vincular_movimento(s.obrigacao_id, s.movimento_id, s.valor_vincular_centavos, s.juros_centavos, 0, s.desconto_centavos, 'iris-vinc-' || left(s.obrigacao_id::text, 8))
  from public.conciliacao_sugestoes(null) s where s.e_fatura;
\o
select teste.igual(pg_temp.restante(teste.id('ir_f10')) || ' ' || pg_temp.restante(teste.id('ir_fi')), '0 0', 'confirmadas: as duas faturas ficam quitadas');

-- ------------------------------------------------------------ isolamento
\o /dev/null
select teste.como(teste.id('otto7'));
\o
select teste.igual((select count(*)::int from public.importacao_fatura_pagamentos((select id from impf))), 0, 'outro usuário não vê os pagamentos da fatura');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 1, null, null, 'otto7-reg-x0001') $q$, '22023', 'outro usuário: parâmetros conferidos antes');
select teste.erro($q$ select public.importacao_fatura_registrar_pagamento((select id from impf), 1, teste.id('ir_itau'), null, 'otto7-reg-x0002') $q$, 'P0002', 'outro usuário não registra pagamento da Iris');
reset role;
\o /dev/null
set role anon;
\o
select teste.erro($q$ select public.importacao_fatura_pagamentos(null) $q$, '42501', 'anônimo não consulta');
reset role;
select teste.igual((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname in ('importacao_fatura_pagamentos', 'importacao_fatura_registrar_pagamento', 'conciliacao_sugestoes')
                      and has_function_privilege('anon', oid, 'execute')), 0, 'nenhuma função nova executável por anônimo');
