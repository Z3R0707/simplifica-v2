-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 4 NO SUPABASE (0007)
-- Cartões, faturas, compras, parcelas, antecipação, estorno e pagamento
-- de fatura.
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa ~70 verificações reais e no
-- fim DESFAZ TUDO (rollback). Nada fica gravado: nenhum usuário, cartão,
-- compra ou lançamento de teste permanece, e nenhum dado real é tocado.
--
-- O resultado aparece como uma mensagem de "erro" — é proposital: é o
-- erro final que obriga o banco a desfazer os testes.
--   "VALIDAÇÃO APROVADA ..."  → tudo certo
--   "VALIDAÇÃO REPROVADA ..." → copie a mensagem inteira e me envie
--
-- Recusa rodar em qualquer banco que não seja o do Simplifica v2.
-- =====================================================================
do $validacao$
declare
  v_suf      text := left(replace(gen_random_uuid()::text, '-', ''), 12);
  v_email_a  text := 'validacao6-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao6-b-' || v_suf || '@teste.invalid';
  c          record;
  v_res      text;
  v_uid      text;
  v_ok       integer := 0;
  v_falhas   text[] := '{}';
  v_total    integer := 0;
begin
  if to_regclass('public.versao_esquema') is null then
    raise exception 'ABORTADO: este banco não é o do Simplifica v2. Nenhuma verificação foi executada.';
  end if;
  execute $$select count(*)::text from public.versao_esquema where sistema = 'simplifica-v2'$$ into v_res;
  if v_res <> '1' then
    raise exception 'ABORTADO: este banco não é o do Simplifica v2. Nenhuma verificação foi executada.';
  end if;
  execute $$select etapa from public.versao_esquema where sistema = 'simplifica-v2'$$ into v_res;
  if v_res not in ('4-cartoes', '5.1-importacao-extratos', '5.2-leitores-bancos') then
    raise exception 'ABORTADO: a Etapa 4 (0007) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'tabelas novas instaladas', 'pg', 'valor', $$select count(*)::text from pg_tables where schemaname = 'public' and tablename in ('cartoes', 'faturas', 'compras', 'parcelas')$$, '4'),
    (2, 'RLS ligado nas tabelas novas', 'pg', 'valor', $$select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relname in ('cartoes', 'faturas', 'compras', 'parcelas') and relrowsecurity$$, '4'),
    (3, 'gatilhos de regras instalados', 'pg', 'valor', $$select count(*)::text from pg_trigger where not tgisinternal and tgname in ('cartoes_validar', 'compras_validar', 'parcelas_validar', 'parcelas_sincronizar', 'pagamentos_validar_fatura', 'titulares_arquivar_sem_cartoes_ativos')$$, '6'),
    (4, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (5, 'funções internas novas fechadas para usuários', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'privado' and p.proname in ('fatura_sincronizar', 'fatura_obter', 'parcela_validar', 'compra_validar', 'pagamento_validar_fatura') and has_function_privilege('authenticated', p.oid, 'execute')$$, '0'),
    (6, 'usuário só lê (sem gravação direta) as tabelas novas', 'pg', 'valor', $$select count(*)::text from information_schema.role_table_grants where grantee in ('authenticated', 'anon') and table_name in ('cartoes', 'faturas', 'compras', 'parcelas') and privilege_type <> 'SELECT'$$, '0'),
    (7, 'regra de fechamento: compra em 02/10 (fecha 3, vence 10) vence em outubro', 'pg', 'valor', $$select privado.fatura_competencia('2026-10-02', 3, 10)::text$$, '2026-10-01'),
    (8, 'compra no dia do fechamento vai para a fatura seguinte', 'pg', 'valor', $$select privado.fatura_competencia('2026-10-03', 3, 10)::text$$, '2026-11-01'),
    (9, 'fecha 25 / vence 5: compra em 24/10 vence em novembro', 'pg', 'valor', $$select privado.fatura_competencia('2026-10-24', 25, 5)::text$$, '2026-11-01'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (20, 'A cadastra Itaú (R$ 10.000 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'validacao6-conta-01')).id::text$$, 'conta'),
    (21, 'A cadastra cartão (fecha 3, vence 10, limite R$ 5.000)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Nubank'), 'Nubank', '1234', 500000, 3, 10, current_setting('val.conta')::uuid, 'validacao6-cartao-01')).id::text$$, 'cartao'),
    (22, 'reenvio do cadastro não duplica o cartão', 'A', 'valor', $$select ((public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Nubank'), 'Nubank', '1234', 500000, 3, 10, current_setting('val.conta')::uuid, 'validacao6-cartao-01')).id = current_setting('val.cartao')::uuid)::text$$, 'true'),
    (23, 'fechamento igual ao vencimento recusado', 'A', 'erro', $$select public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Nubank'), 'Outro', null, null, 5, 5, null, 'validacao6-cartao-02')$$, '23514'),
    (24, 'compra à vista de R$ 100 em 02/10', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-02', 'Mercado', (select id from public.categorias where nome = 'Alimentação'), 10000, 1, null, 1, null, null, 'validacao6-compra-01')).id::text$$, 'c1'),
    (25, 'cai na fatura que fecha 03/10 e vence 10/10', 'A', 'valor', $$select f.fechamento || ' ' || f.vencimento from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = current_setting('val.c1')::uuid$$, '2026-10-03 2026-10-10'),
    (26, 'fatura vira UMA conta a pagar, paga pela conta do cartão', 'A', 'valor', $$select o.origem || ' ' || o.valor_centavos || ' ' || o.descricao || ' ' || (o.conta_prevista_id = current_setting('val.conta')::uuid) from public.obrigacoes o where o.id = (select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01')$$, 'fatura 10000 Fatura Nubank 10/2026 true'),
    (27, 'compra no cartão não mexe no saldo da conta', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '1000000'),
    (28, 'reenvio da compra não duplica', 'A', 'valor', $$select ((public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-02', 'Mercado', (select id from public.categorias where nome = 'Alimentação'), 10000, 1, null, 1, null, null, 'validacao6-compra-01')).id = current_setting('val.c1')::uuid)::text$$, 'true'),
    (29, 'compra parcelada 10x de R$ 1.000 em 05/10', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-05', 'Televisão', (select id from public.categorias where nome = 'Lazer'), 100000, 10, null, 1, null, null, 'validacao6-compra-02')).id::text$$, 'tv'),
    (30, 'parcelas 1/10 a 10/10, uma por fatura (nov/26 a ago/27)', 'A', 'valor', $$select string_agg(p.numero || ':' || to_char(f.competencia, 'MM/YY'), ' ' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = current_setting('val.tv')::uuid$$, '1:11/26 2:12/26 3:01/27 4:02/27 5:03/27 6:04/27 7:05/27 8:06/27 9:07/27 10:08/27'),
    (31, 'compra R$ 100,01 em 3x', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-05', 'Fone', null, 10001, 3, null, 1, null, null, 'validacao6-compra-03')).id::text$$, 'fone'),
    (32, 'centavos que sobram ficam na 1ª parcela', 'A', 'valor', $$select string_agg(valor_centavos::text, ',' order by numero) from public.parcelas where compra_id = current_setting('val.fone')::uuid$$, '3335,3333,3333'),
    (33, 'fatura mostra a parcela 3/10 (DATA | DESCRIÇÃO | PARCELA | VALOR)', 'A', 'valor', $$select parcela || ' ' || valor_centavos from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2027-01-01')) where compra_id = current_setting('val.tv')::uuid$$, '3/10 10000'),
    (34, 'compra antiga já na parcela 3/10', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-06-20', 'Geladeira antiga', null, 50000, 10, null, 3, null, null, 'validacao6-compra-04')).id::text$$, 'antiga'),
    (35, 'só da parcela 3 em diante, a 3ª na fatura aberta hoje', 'A', 'valor', $$select (min(p.numero) || '-' || max(p.numero) || ' ' || (min(f.competencia) = privado.fatura_competencia(privado.hoje(), 3, 10)))::text from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = current_setting('val.antiga')::uuid$$, '3-10 true'),
    (36, 'IOF (encargo) de R$ 3,50', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'encargo', 'iof', '2026-10-06', 'IOF', (select id from public.categorias where nome = 'Juros e encargos'), 350, 1, null, 1, null, null, 'validacao6-compra-05')).id::text$$, 'iof'),
    (37, 'crédito (cashback) de R$ 20', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'credito', null, '2026-10-06', 'Cashback', null, 2000, 1, null, 1, null, null, 'validacao6-compra-06')).id::text$$, 'cred'),
    (38, 'crédito aparece negativo na fatura', 'A', 'valor', $$select valor_centavos::text from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01')) where compra_id = current_setting('val.cred')::uuid$$, '-2000'),
    (39, 'conta a pagar da fatura acompanha débitos e créditos', 'A', 'valor', $$select (o.valor_centavos = (select sum(valor_assinado_centavos) from public.parcelas where fatura_id = (select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01') and situacao = 'ativa'))::text from public.obrigacoes o where o.id = (select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01')$$, 'true'),
    (40, 'compra com data futura recusada', 'A', 'erro', $$select public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, privado.hoje() + 1, 'x', null, 100, 1, null, 1, null, null, 'validacao6-compra-x1')$$, '22023'),
    (41, 'só compras podem ser parceladas', 'A', 'erro', $$select public.compra_criar(current_setting('val.cartao')::uuid, 'encargo', 'iof', '2026-10-06', 'x', null, 100, 2, null, 1, null, null, 'validacao6-compra-x2')$$, '22023'),
    (42, 'categoria de receita recusada', 'A', 'erro', $$select public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-06', 'x', (select id from public.categorias where nome = 'Salário'), 100, 1, null, 1, null, null, 'validacao6-compra-x3')$$, '22023'),
    (43, 'limite usado = tudo o que falta pagar, inclusive parcelas futuras', 'A', 'valor', $$select (usado_centavos = (select sum(valor_assinado_centavos) from public.parcelas where cartao_id = current_setting('val.cartao')::uuid and situacao = 'ativa') and disponivel_centavos + usado_centavos = 500000)::text from public.cartoes_resumo() where cartao_id = current_setting('val.cartao')::uuid$$, 'true'),
    (44, 'fatura de outubro fechada e não paga: vencida; parcela cobrada', 'A', 'valor', $$select (select situacao from public.faturas_do_cartao(current_setting('val.cartao')::uuid, '2026-10-01', '2026-10-01')) || ' ' || (select status from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01')) where compra_id = current_setting('val.c1')::uuid)$$, 'vencida cobrada'),
    (45, 'paga a fatura de outubro pelo Itaú', 'A', 'ok', $$select (public.obrigacao_pagar((select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01'), current_setting('val.conta')::uuid, '2026-10-10', 10000, 0, 0, 0, null, 'validacao6-pagfat-01')).movimento_id::text$$, 'mpf'),
    (46, 'saída lançada como "pagamento de fatura", sem categoria', 'A', 'valor', $$select classificacao || ' ' || coalesce(categoria_id::text, '-') from public.movimentos where id = current_setting('val.mpf')::uuid$$, 'pagamento_fatura -'),
    (47, 'pagamento sai do saldo', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '990000'),
    (48, 'fatura paga; parcela quitada', 'A', 'valor', $$select (select situacao from public.faturas_do_cartao(current_setting('val.cartao')::uuid, '2026-10-01', '2026-10-01')) || ' ' || (select status from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01')) where compra_id = current_setting('val.c1')::uuid)$$, 'paga quitada'),
    (49, 'resumo: a compra conta uma vez; o pagamento da fatura não é despesa', 'A', 'valor', $$select coalesce(sum(total_centavos), 0)::text from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'$$, '10000'),
    (50, 'pagamento de fatura fora do resumo', 'A', 'valor', $$select count(*)::text from public.resumo_categorias('2026-10-01', '2026-10-31') where classificacao = 'pagamento_fatura'$$, '0'),
    (51, 'crédito numa fatura já paga recusado', 'A', 'erro', $$select public.compra_criar(current_setting('val.cartao')::uuid, 'credito', null, '2026-10-02', 'Ajuste', null, 500, 1, null, 1, '2026-10-01', null, 'validacao6-compra-x4')$$, '22023'),
    (52, 'conta a pagar da fatura não é editada à mão', 'A', 'erro', $$select public.obrigacao_atualizar((select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01'), (select versao from public.obrigacoes where id = (select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01')), 'x', 99, '2026-11-10', null, null, null)$$, '22023'),
    (53, 'A lança Pix como despesa (R$ 50)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.conta')::uuid, 'debito', 5000, '2026-10-11', 'Pix Nubank', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao6-mov-01')).id::text$$, 'pix'),
    (54, 'vincula o Pix à fatura de novembro', 'A', 'ok', $$select (public.obrigacao_vincular_movimento((select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01'), current_setting('val.pix')::uuid, 5000, 0, 0, 0, 'validacao6-vin-01')).id::text$$, 'vin'),
    (55, 'Pix vira "pagamento de fatura" e não é contado duas vezes', 'A', 'valor', $$select (select classificacao from public.movimentos where id = current_setting('val.pix')::uuid) || ' ' || (select coalesce(sum(total_centavos), 0) from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação')$$, 'pagamento_fatura 10000'),
    (56, 'desfaz o vínculo', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.vin')::uuid, 1, 'vinculei errado', false)).situacao$$, 'desfeito'),
    (57, 'Pix volta a ser despesa na categoria original', 'A', 'valor', $$select classificacao || ' ' || (categoria_id = (select id from public.categorias where nome = 'Alimentação'))::text from public.movimentos where id = current_setting('val.pix')::uuid$$, 'despesa true'),
    (60, 'antecipação para fatura já fechada recusada', 'A', 'erro', $$select public.compra_antecipar(current_setting('val.tv')::uuid, array[6,7,8], '2026-10-01', 0, 'validacao6-ant-x1')$$, '22023'),
    (61, 'antecipa as parcelas 6, 7 e 8 com R$ 30 de desconto', 'A', 'valor', $$select public.compra_antecipar(current_setting('val.tv')::uuid, array[6,7,8], null, 3000, 'validacao6-ant-01')::text$$, '3'),
    (62, 'parcelas na fatura atual, com a fatura original guardada e o desconto dividido', 'A', 'valor', $$select string_agg(numero || ':' || (competencia = privado.fatura_competencia(privado.hoje(), 3, 10)) || ':' || to_char(fatura_original_competencia, 'MM/YY') || ':' || desconto_centavos, ' ' order by numero) from public.parcelas_da_compra(current_setting('val.tv')::uuid) where antecipada$$, '6:true:04/27:1000 7:true:05/27:1000 8:true:06/27:1000'),
    (63, 'fatura futura (04/27) perde a parcela e a conta a pagar acompanha (fica R$ 50 da geladeira)', 'A', 'valor', $$select (select total_centavos from public.faturas_do_cartao(current_setting('val.cartao')::uuid, '2027-04-01', '2027-04-01')) || ' ' || (select valor_centavos from public.obrigacoes where id = (select obrigacao_id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2027-04-01'))$$, '5000 5000'),
    (64, 'histórico preservado: nenhuma parcela apagada', 'A', 'valor', $$select count(*)::text from public.parcelas where compra_id = current_setting('val.tv')::uuid$$, '10'),
    (65, 'parcela já antecipada não é antecipada de novo', 'A', 'erro', $$select public.compra_antecipar(current_setting('val.tv')::uuid, array[6], null, 0, 'validacao6-ant-x2')$$, '22023'),
    (66, 'desfaz a antecipação da parcela 8', 'A', 'valor', $$select public.antecipacao_desfazer(current_setting('val.tv')::uuid, array[8], 'antecipei a mais')::text$$, '1'),
    (67, 'parcela 8 volta para 06/27, sem desconto', 'A', 'valor', $$select to_char(competencia, 'MM/YY') || ' ' || desconto_centavos || ' ' || antecipada from public.parcelas_da_compra(current_setting('val.tv')::uuid) where numero = 8$$, '06/27 0 false'),
    (70, 'compra de R$ 200 para estornar', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-10', 'Sapato', (select id from public.categorias where nome = 'Lazer'), 20000, 1, null, 1, null, null, 'validacao6-compra-07')).id::text$$, 'sapato'),
    (71, 'estorno de R$ 50: crédito ligado à compra, mesma categoria', 'A', 'valor', $$select tipo || ' ' || natureza || ' ' || (estorno_de = current_setting('val.sapato')::uuid) || ' ' || (categoria_id = (select id from public.categorias where nome = 'Lazer')) from public.compra_estornar(current_setting('val.sapato')::uuid, 5000, '2026-10-12', null, 'trocou', 'validacao6-est-01')$$, 'estorno credito true true'),
    (72, 'estorno não passa do valor da compra', 'A', 'erro', $$select public.compra_estornar(current_setting('val.sapato')::uuid, 15001, '2026-10-12', null, 'mais', 'validacao6-est-02')$$, '22023'),
    (73, 'compra com estorno não é removida inteira', 'A', 'erro', $$select public.compra_cancelar(current_setting('val.sapato')::uuid, 1, 'lancei errado', true)$$, '22023'),
    (74, 'compra de setembro em 3x (Santander-like: fecha 25, vence 5)', 'A', 'ok', $$select (public.compra_criar((public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Santander'), 'Santander', null, null, 25, 5, null, 'validacao6-cartao-03')).id, 'compra', null, '2026-09-20', 'Jaqueta', null, 30000, 3, null, 1, null, null, 'validacao6-compra-08')).id::text$$, 'jaqueta'),
    (75, '1ª parcela cobrada, demais a cobrar', 'A', 'valor', $$select string_agg(status, ',' order by numero) from public.parcelas_da_compra(current_setting('val.jaqueta')::uuid)$$, 'cobrada,a_cobrar,a_cobrar'),
    (76, 'cancelar na loja: só as parcelas ainda não cobradas', 'A', 'valor', $$select (public.compra_cancelar(current_setting('val.jaqueta')::uuid, 1, 'devolvi', false)).situacao$$, 'ativa'),
    (77, 'parcelas canceladas; fatura sem valor tem a conta a pagar cancelada', 'A', 'valor', $$select (select string_agg(status, ',' order by numero) from public.parcelas_da_compra(current_setting('val.jaqueta')::uuid)) || ' ' || (select o.situacao from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = (select cartao_id from public.compras where id = current_setting('val.jaqueta')::uuid) and f.competencia = '2026-12-01')$$, 'cobrada,cancelada,cancelada cancelada'),
    (78, 'lancei errado: remove tudo', 'A', 'valor', $$select (public.compra_cancelar(current_setting('val.jaqueta')::uuid, 2, 'lancei errado', true)).situacao$$, 'cancelada'),
    (79, 'informa o total do banco na fatura de outubro', 'A', 'ok', $$select (public.fatura_atualizar((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01'), (select versao from public.faturas where id = (select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01')), '2026-10-03', '2026-10-10', 140053, null)).id::text$$, 'fout'),
    (80, 'diferença mostrada à parte, sem lançamento de compensação', 'A', 'valor', $$select total_centavos || ' ' || total_informado_centavos || ' ' || diferenca_centavos from public.faturas_do_cartao(current_setting('val.cartao')::uuid, '2026-10-01', '2026-10-01')$$, '10000 140053 130053'),
    (81, 'gravação direta em compras negada', 'A', 'erro', $$insert into public.compras (user_id, cartao_id, tipo, data_compra, descricao, valor_total_centavos) values (auth.uid(), current_setting('val.cartao')::uuid, 'compra', '2026-10-01', 'x', 1)$$, '42501'),
    (82, 'gravação direta em parcelas negada', 'A', 'erro', $$update public.parcelas set valor_centavos = 1 where compra_id = current_setting('val.tv')::uuid$$, '42501'),
    (83, 'exportação inclui cartões, faturas, compras e parcelas', 'A', 'valor', $$select (jsonb_array_length(d->'cartoes') = 2 and jsonb_array_length(d->'faturas') > 5 and jsonb_array_length(d->'compras_cartao') > 5 and jsonb_array_length(d->'parcelas') > 15)::text from (select public.exportar_meus_dados() as d) x$$, 'true'),
    (90, 'B não vê cartões, faturas, compras nem parcelas de A', 'B', 'valor', $$select ((select count(*) from public.cartoes) + (select count(*) from public.faturas) + (select count(*) from public.compras) + (select count(*) from public.parcelas))::text$$, '0'),
    (91, 'B não vê pelo resumo de cartões', 'B', 'valor', $$select count(*)::text from public.cartoes_resumo()$$, '0'),
    (92, 'B não lança no cartão de A', 'B', 'erro', $$select public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-06', 'x', null, 100, 1, null, 1, null, null, 'validacao6-b-compra')$$, 'P0002'),
    (93, 'B não antecipa compra de A', 'B', 'erro', $$select public.compra_antecipar(current_setting('val.tv')::uuid, array[9], null, 0, 'validacao6-b-ant')$$, 'P0002'),
    (94, 'B não estorna compra de A', 'B', 'erro', $$select public.compra_estornar(current_setting('val.sapato')::uuid, 100, '2026-10-12', null, 'x', 'validacao6-b-est')$$, 'P0002'),
    (95, 'anônimo não consulta cartões', 'anon', 'erro', $$select public.cartoes_resumo()$$, '42501'),
    (96, 'INVARIANTE: toda fatura com valor tem conta a pagar aberta com o mesmo valor', 'pg', 'valor', $$select count(*)::text from public.faturas f where (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa') > 0 and not exists (select 1 from public.obrigacoes o where o.id = f.obrigacao_id and o.situacao = 'aberta' and o.valor_centavos = (select sum(p.valor_assinado_centavos) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa'))$$, '0'),
    (97, 'INVARIANTE: fatura sem valor não tem conta a pagar aberta', 'pg', 'valor', $$select count(*)::text from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where o.situacao = 'aberta' and (select coalesce(sum(p.valor_assinado_centavos), 0) from public.parcelas p where p.fatura_id = f.id and p.situacao = 'ativa') <= 0$$, '0'),
    (98, 'A solicita exclusão da conta', 'A', 'valor', format($f$select (public.exclusao_solicitar(%L)).status$f$, v_email_a), 'solicitada'),
    (99, 'servidor conclui a exclusão de A', 'svc', 'valor', $$select (public.exclusao_concluir(current_setting('val.a')::uuid)).status$$, 'concluida'),
    (100, 'exclusão apagou cartões, faturas, compras, parcelas e lançamentos de A', 'pg', 'valor', $$select ((select count(*) from public.cartoes where user_id = current_setting('val.a')::uuid) + (select count(*) from public.faturas where user_id = current_setting('val.a')::uuid) + (select count(*) from public.compras where user_id = current_setting('val.a')::uuid) + (select count(*) from public.parcelas where user_id = current_setting('val.a')::uuid) + (select count(*) from public.movimentos where user_id = current_setting('val.a')::uuid) + (select count(*) from public.obrigacoes where user_id = current_setting('val.a')::uuid))::text$$, '0')
    ) as t(ordem, nome, quem, tipo, comando, esperado)
    order by ordem
  loop
    v_total := v_total + 1;
    v_res := null;
    begin
      if c.quem in ('A', 'B') then
        v_uid := current_setting('val.' || lower(c.quem), true);
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claim.sub', coalesce(v_uid, ''), true);
        perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
      elsif c.quem = 'svc' then
        perform set_config('role', 'service_role', true);
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
      elsif c.quem = 'anon' then
        perform set_config('role', 'anon', true);
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      end if;

      execute c.comando into v_res;
      execute 'reset role';

      if c.tipo = 'erro' then
        v_falhas := v_falhas || format('#%s %s: deveria falhar com %s, mas executou', c.ordem, c.nome, c.esperado);
      elsif c.tipo = 'valor' and v_res is distinct from c.esperado then
        v_falhas := v_falhas || format('#%s %s: esperado %s, obtido %s', c.ordem, c.nome, c.esperado, coalesce(v_res, 'NULL'));
      else
        if c.tipo = 'ok' and c.esperado is not null then
          perform set_config('val.' || c.esperado, v_res, true);
        end if;
        v_ok := v_ok + 1;
      end if;
    exception when others then
      -- o papel e as variáveis locais voltam automaticamente ao estado anterior
      if c.tipo = 'erro' and sqlstate = c.esperado then
        v_ok := v_ok + 1;
      else
        v_falhas := v_falhas || format('#%s %s: erro %s — %s', c.ordem, c.nome, sqlstate, sqlerrm);
      end if;
    end;
  end loop;

  if cardinality(v_falhas) = 0 then
    raise exception E'VALIDAÇÃO APROVADA: % de % verificações OK.\nTudo foi desfeito (rollback): nenhum usuário, arquivo ou dado de teste ficou gravado.', v_ok, v_total;
  else
    raise exception E'VALIDAÇÃO REPROVADA: % de % OK, % falha(s):\n%\nTudo foi desfeito (rollback).',
      v_ok, v_total, cardinality(v_falhas), array_to_string(v_falhas, E'\n');
  end if;
end
$validacao$;
