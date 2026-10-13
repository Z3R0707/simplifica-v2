-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 3 NO SUPABASE (0006)
-- Contas a pagar, pagamentos parciais, vínculos e recorrências.
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa ~60 verificações reais
-- (pagamento parcial, juros/multa/desconto, saldo, proteção das saídas,
-- desfazer, vincular, recorrências, isolamento, exportação e exclusão
-- LGPD) e no fim DESFAZ TUDO (rollback). Nada fica gravado: nenhum
-- usuário, conta, lançamento ou conta a pagar de teste permanece, e
-- nenhum dado real é tocado.
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
  v_email_a  text := 'validacao5-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao5-b-' || v_suf || '@teste.invalid';
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
  if v_res not in ('3-contas-a-pagar', '4-cartoes', '5.1-importacao-extratos', '5.2-leitores-bancos', '5.3-importacao-faturas') then
    raise exception 'ABORTADO: a Etapa 3 (0006) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'tabelas novas instaladas', 'pg', 'valor', $$select count(*)::text from pg_tables where schemaname = 'public' and tablename in ('obrigacoes', 'pagamentos', 'recorrencias')$$, '3'),
    (2, 'RLS ligado nas tabelas novas', 'pg', 'valor', $$select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relname in ('obrigacoes', 'pagamentos', 'recorrencias') and relrowsecurity$$, '3'),
    (3, 'gatilhos de regras instalados', 'pg', 'valor', $$select count(*)::text from pg_trigger where not tgisinternal and tgname in ('obrigacoes_validar', 'pagamentos_validar', 'recorrencias_validar', 'movimentos_regras_pagamento')$$, '4'),
    (4, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (5, 'funções internas novas fechadas para usuários', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'privado' and p.proname in ('reais', 'recorrencia_gerar', 'pagamento_validar', 'movimento_regras_pagamento', 'obrigacao_validar') and has_function_privilege('authenticated', p.oid, 'execute')$$, '0'),
    (6, 'usuário só lê (sem gravação direta) as tabelas novas', 'pg', 'valor', $$select count(*)::text from information_schema.role_table_grants where grantee in ('authenticated', 'anon') and table_name in ('obrigacoes', 'pagamentos', 'recorrencias') and privilege_type <> 'SELECT'$$, '0'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (20, 'A cadastra Itaú (R$ 1.000 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'validacao5-conta-01')).id::text$$, 'conta'),
    (21, 'A cadastra Nubank (R$ 500 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Nubank'), 'Nubank', 'corrente', 50000, '2026-10-01', null, null, true, true, 'validacao5-conta-02')).id::text$$, 'conta2'),
    (22, 'A cadastra conta de luz R$ 200 (vence 20/10)', 'A', 'ok', $$select (public.obrigacao_criar('Conta de luz', 20000, '2026-10-20', (select id from public.categorias where nome = 'Serviços e assinaturas'), current_setting('val.conta')::uuid, null, 'validacao5-luz-0001')).id::text$$, 'luz'),
    (23, 'reenvio idêntico não duplica a conta a pagar', 'A', 'valor', $$select ((public.obrigacao_criar('Conta de luz', 20000, '2026-10-20', (select id from public.categorias where nome = 'Serviços e assinaturas'), current_setting('val.conta')::uuid, null, 'validacao5-luz-0001')).id = current_setting('val.luz')::uuid)::text$$, 'true'),
    (24, 'mesma chave com outro valor é recusada', 'A', 'erro', $$select public.obrigacao_criar('Conta de luz', 20001, '2026-10-20', null, null, null, 'validacao5-luz-0001')$$, 'SF409'),
    (25, 'categoria de receita é recusada', 'A', 'erro', $$select public.obrigacao_criar('x', 100, '2026-10-20', (select id from public.categorias where nome = 'Salário'), null, null, 'validacao5-x-00001')$$, '22023'),
    (26, 'conta a pagar sozinha não mexe no saldo', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '100000'),
    (27, 'paga R$ 80 (parcial) pelo Itaú em 12/10', 'A', 'ok', $$select (public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 8000, 0, 0, 0, null, 'validacao5-pag-0001')).id::text$$, 'pg1'),
    (28, 'pagar cria a saída como despesa na categoria da conta', 'A', 'valor', $$select m.natureza || ' ' || m.classificacao || ' ' || m.valor_centavos || ' ' || m.descricao || ' ' || (m.categoria_id = (select id from public.categorias where nome = 'Serviços e assinaturas')) from public.movimentos m join public.pagamentos p on p.movimento_id = m.id where p.id = current_setting('val.pg1')::uuid$$, 'debito despesa 8000 Conta de luz true'),
    (29, 'saldo do Itaú cai R$ 80', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '92000'),
    (30, 'restam R$ 120', 'A', 'valor', $$select restante_centavos::text from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = current_setting('val.luz')::uuid$$, '12000'),
    (31, 'pagamento parcial não marca como paga', 'A', 'valor', $$select (status <> 'paga')::text from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = current_setting('val.luz')::uuid$$, 'true'),
    (32, 'reenvio do pagamento não paga duas vezes', 'A', 'valor', $$select ((public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 8000, 0, 0, 0, null, 'validacao5-pag-0001')).id = current_setting('val.pg1')::uuid)::text$$, 'true'),
    (33, 'só uma saída criada', 'A', 'valor', $$select count(*)::text from public.movimentos where descricao = 'Conta de luz'$$, '1'),
    (34, 'não abate mais do que falta (R$ 120)', 'A', 'erro', $$select public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 12001, 0, 0, 0, null, 'validacao5-pag-0002')$$, '22023'),
    (35, 'pagamento recusado não deixa saída solta', 'A', 'valor', $$select count(*)::text from public.movimentos where descricao = 'Conta de luz'$$, '1'),
    (36, 'pagamento com data futura recusado', 'A', 'erro', $$select public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta')::uuid, privado.hoje() + 1, 100, 0, 0, 0, null, 'validacao5-pag-0003')$$, '22023'),
    (37, 'quita pagando R$ 125 pelo Nubank (R$ 3 juros + R$ 2 multa)', 'A', 'ok', $$select (public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta2')::uuid, '2026-10-12', 12500, 300, 200, 0, 'atrasou', 'validacao5-pag-0004')).id::text$$, 'pg2'),
    (38, 'conta fica paga; pagos R$ 205 com R$ 5 de encargos', 'A', 'valor', $$select status || ' ' || restante_centavos || ' ' || pago_centavos || ' ' || juros_centavos || ' ' || multa_centavos from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = current_setting('val.luz')::uuid$$, 'paga 0 20500 300 200'),
    (39, 'saldo do Nubank cai R$ 125', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta2')::uuid$$, '37500'),
    (40, 'conta paga não aceita mais pagamento', 'A', 'erro', $$select public.obrigacao_pagar(current_setting('val.luz')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 100, 0, 0, 0, null, 'validacao5-pag-0005')$$, '22023'),
    (41, 'saída que paga conta não pode ser cancelada', 'A', 'erro', $$select public.movimento_cancelar((select movimento_id from public.pagamentos where id = current_setting('val.pg1')::uuid), 1, 'tentativa')$$, '22023'),
    (42, 'cancelamento parcial não invade o valor usado', 'A', 'erro', $$select public.movimento_cancelar_parcial((select movimento_id from public.pagamentos where id = current_setting('val.pg1')::uuid), 100, '2026-10-12', 'parcial', 'validacao5-cp-00001')$$, '22023'),
    (43, 'conta com pagamento não pode ser cancelada', 'A', 'erro', $$select public.obrigacao_cancelar(current_setting('val.luz')::uuid, 1, 'não devo')$$, '22023'),
    (44, 'valor não fica menor que o pago', 'A', 'erro', $$select public.obrigacao_atualizar(current_setting('val.luz')::uuid, 1, 'Conta de luz', 19000, '2026-10-20', null, null, null)$$, '22023'),
    (45, 'desfaz o pagamento de R$ 80 cancelando a saída', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.pg1')::uuid, 1, 'Paguei na conta errada', true)).situacao$$, 'desfeito'),
    (46, 'saída cancelada com o motivo', 'A', 'valor', $$select m.situacao || ' ' || m.cancelado_motivo from public.movimentos m join public.pagamentos p on p.movimento_id = m.id where p.id = current_setting('val.pg1')::uuid$$, 'cancelado Paguei na conta errada'),
    (47, 'dinheiro volta ao saldo do Itaú', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '100000'),
    (48, 'conta volta a ter R$ 80 em aberto', 'A', 'valor', $$select restante_centavos::text from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = current_setting('val.luz')::uuid$$, '8000'),
    (49, 'desfazer auditado com motivo e canal', 'A', 'valor', $$select motivo from public.auditoria where tabela = 'pagamentos' and registro_id = current_setting('val.pg1')::uuid and operacao = 'UPDATE'$$, 'Paguei na conta errada'),
    (50, 'A lança débito automático de R$ 100 (09/10)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.conta')::uuid, 'debito', 10000, '2026-10-09', 'Débito automático', 'despesa', (select id from public.categorias where nome = 'Serviços e assinaturas'), 'efetivo', null, 'validacao5-mov-0001')).id::text$$, 'mov'),
    (51, 'saída já lançada aparece para vincular', 'A', 'valor', $$select livre_centavos::text from public.movimentos_para_vincular(current_setting('val.luz')::uuid) where movimento_id = current_setting('val.mov')::uuid$$, '10000'),
    (52, 'vincula R$ 80 da saída à conta de luz', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.luz')::uuid, current_setting('val.mov')::uuid, 8000, 0, 0, 0, 'validacao5-vin-0001')).id::text$$, 'vin'),
    (53, 'vínculo quita a conta', 'A', 'valor', $$select status from public.contas_a_pagar('2026-10-01', '2026-10-31') where obrigacao_id = current_setting('val.luz')::uuid$$, 'paga'),
    (54, 'vínculo não lança a saída de novo (saldo R$ 900)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '90000'),
    (55, 'A cadastra outra conta a pagar de R$ 50', 'A', 'ok', $$select (public.obrigacao_criar('Extra', 5000, '2026-10-20', null, null, null, 'validacao5-ext-0001')).id::text$$, 'extra'),
    (56, 'saída mostra só o que sobrou livre (R$ 20)', 'A', 'valor', $$select livre_centavos::text from public.movimentos_para_vincular(current_setting('val.extra')::uuid) where movimento_id = current_setting('val.mov')::uuid$$, '2000'),
    (57, 'não vincula mais do que o livre da saída', 'A', 'erro', $$select public.obrigacao_vincular_movimento(current_setting('val.extra')::uuid, current_setting('val.mov')::uuid, 2001, 0, 0, 0, 'validacao5-vin-0002')$$, '22023'),
    (58, 'desconto quita pagando menos (R$ 45 + R$ 5 de desconto)', 'A', 'valor', $$select (public.obrigacao_pagar(current_setting('val.extra')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 4500, 0, 0, 500, null, 'validacao5-pag-0006')).abatido_centavos::text$$, '5000'),
    (60, 'cria aluguel R$ 1.500 todo dia 31, a partir deste mês', 'A', 'ok', $$select (public.recorrencia_criar('Aluguel', 150000, 31, date_trunc('month', privado.hoje())::date, null, false, (select id from public.categorias where nome = 'Moradia'), current_setting('val.conta')::uuid, null, 'validacao5-rec-0001')).id::text$$, 'rec'),
    (61, 'gera o mês atual e o próximo', 'A', 'valor', $$select count(*)::text from public.obrigacoes where recorrencia_id = current_setting('val.rec')::uuid$$, '2'),
    (62, 'dia 31 vira o último dia do mês', 'A', 'valor', $$select (vencimento = (date_trunc('month', privado.hoje())::date + interval '1 month - 1 day')::date)::text from public.obrigacoes where recorrencia_id = current_setting('val.rec')::uuid and competencia = date_trunc('month', privado.hoje())::date$$, 'true'),
    (63, 'gerar até daqui a 4 meses cria 3 meses novos', 'A', 'valor', $$select public.recorrencias_gerar((privado.hoje() + interval '4 months')::date)::text$$, '3'),
    (64, 'gerar de novo não duplica', 'A', 'valor', $$select public.recorrencias_gerar((privado.hoje() + interval '4 months')::date)::text$$, '0'),
    (65, 'encerra no próximo mês', 'A', 'valor', $$select ((public.recorrencia_definir_fim(current_setting('val.rec')::uuid, 1, (date_trunc('month', privado.hoje())::date + interval '1 month')::date)).fim = (date_trunc('month', privado.hoje())::date + interval '1 month')::date)::text$$, 'true'),
    (66, 'meses seguintes cancelados, sem apagar', 'A', 'valor', $$select count(*)::text from public.obrigacoes where recorrencia_id = current_setting('val.rec')::uuid and situacao = 'cancelada' and cancelada_motivo = 'Recorrência encerrada'$$, '3'),
    (67, 'retomar (repetir sem fim)', 'A', 'valor', $$select ((public.recorrencia_definir_fim(current_setting('val.rec')::uuid, 2, null)).fim is null)::text$$, 'true'),
    (68, 'retomada reabre os meses', 'A', 'valor', $$select count(*)::text from public.obrigacoes where recorrencia_id = current_setting('val.rec')::uuid and situacao = 'aberta'$$, '5'),
    (69, 'cria geladeira em 10 parcelas numeradas', 'A', 'ok', $$select (public.recorrencia_criar('Geladeira', 30000, 10, date_trunc('month', privado.hoje())::date, (date_trunc('month', privado.hoje())::date + interval '9 months')::date, true, null, null, null, 'validacao5-rec-0002')).id::text$$, 'rec2'),
    (85, 'parcelas numeradas (1/10)', 'A', 'valor', $$select descricao from public.obrigacoes where recorrencia_id = current_setting('val.rec2')::uuid order by competencia limit 1$$, 'Geladeira (1/10)'),
    (84, 'contas a pagar até o fim do mês, por conta prevista', 'A', 'valor', $$select restante_centavos::text from public.contas_a_pagar_por_conta((date_trunc('month', privado.hoje())::date + interval '1 month - 1 day')::date) where conta_prevista_id = current_setting('val.conta')::uuid$$, '150000'),
    (70, 'B não vê contas a pagar de A', 'B', 'valor', $$select count(*)::text from public.obrigacoes$$, '0'),
    (71, 'B não vê pela consulta', 'B', 'valor', $$select count(*)::text from public.contas_a_pagar('2000-01-01', '2100-01-01')$$, '0'),
    (72, 'B não vê pagamentos de A', 'B', 'valor', $$select count(*)::text from public.pagamentos$$, '0'),
    (73, 'B não paga conta de A', 'B', 'erro', $$select public.obrigacao_pagar(current_setting('val.extra')::uuid, current_setting('val.conta')::uuid, '2026-10-12', 100, 0, 0, 0, null, 'validacao5-b-pag-01')$$, 'P0002'),
    (74, 'B cadastra a própria conta a pagar', 'B', 'ok', $$select (public.obrigacao_criar('Conta de B', 1000, '2026-10-20', null, null, null, 'validacao5-b-obr-01')).id::text$$, 'obrb'),
    (75, 'B não vincula lançamento de A', 'B', 'erro', $$select public.obrigacao_vincular_movimento(current_setting('val.obrb')::uuid, current_setting('val.mov')::uuid, 100, 0, 0, 0, 'validacao5-b-vin-01')$$, 'P0002'),
    (76, 'B não usa conta de A como prevista', 'B', 'erro', $$select public.obrigacao_criar('x', 100, '2026-10-20', null, current_setting('val.conta')::uuid, null, 'validacao5-b-obr-02')$$, 'P0002'),
    (77, 'anônimo não consulta contas a pagar', 'anon', 'erro', $$select public.contas_a_pagar('2026-10-01', '2026-10-31')$$, '42501'),
    (78, 'gravação direta em contas a pagar negada', 'A', 'erro', $$insert into public.obrigacoes (user_id, descricao, valor_centavos, vencimento, competencia) values (auth.uid(), 'x', 1, '2026-10-01', '2026-10-01')$$, '42501'),
    (79, 'gravação direta em pagamentos negada', 'A', 'erro', $$update public.pagamentos set valor_pago_centavos = 1 where id = current_setting('val.pg2')::uuid$$, '42501'),
    (80, 'exportação inclui contas a pagar, pagamentos e recorrências', 'A', 'valor', $$select (jsonb_array_length(d->'contas_a_pagar') > 0 and jsonb_array_length(d->'pagamentos') = 4 and jsonb_array_length(d->'recorrencias') = 2)::text from (select public.exportar_meus_dados() as d) x$$, 'true'),
    (81, 'INVARIANTE: nenhuma conta com abatido acima do valor', 'pg', 'valor', $$select count(*)::text from public.obrigacoes o where (select coalesce(sum(p.abatido_centavos), 0) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo') > o.valor_centavos$$, '0'),
    (82, 'INVARIANTE: nenhuma saída usada acima do valor', 'pg', 'valor', $$select count(*)::text from public.movimentos m where m.estorno_de is null and (select coalesce(sum(p.valor_pago_centavos), 0) from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo') + (select coalesce(sum(e.valor_centavos), 0) from public.movimentos e where e.estorno_de = m.id and e.situacao <> 'cancelado') > m.valor_centavos$$, '0'),
    (83, 'INVARIANTE: nenhum pagamento ativo com saída cancelada', 'pg', 'valor', $$select count(*)::text from public.pagamentos p join public.movimentos m on m.id = p.movimento_id where p.situacao = 'ativo' and m.situacao <> 'efetivo'$$, '0'),
    (90, 'A solicita exclusão da conta', 'A', 'valor', format($f$select (public.exclusao_solicitar(%L)).status$f$, v_email_a), 'solicitada'),
    (91, 'servidor conclui a exclusão de A', 'svc', 'valor', $$select (public.exclusao_concluir(current_setting('val.a')::uuid)).status$$, 'concluida'),
    (92, 'exclusão apagou contas a pagar, pagamentos, recorrências e lançamentos de A', 'pg', 'valor', $$select ((select count(*) from public.obrigacoes where user_id = current_setting('val.a')::uuid) + (select count(*) from public.pagamentos where user_id = current_setting('val.a')::uuid) + (select count(*) from public.recorrencias where user_id = current_setting('val.a')::uuid) + (select count(*) from public.movimentos where user_id = current_setting('val.a')::uuid))::text$$, '0'),
    (93, 'dados de B intactos', 'pg', 'valor', $$select count(*)::text from public.obrigacoes where user_id = current_setting('val.b')::uuid$$, '1')
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
