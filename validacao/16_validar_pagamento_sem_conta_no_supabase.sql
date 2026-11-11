-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DO PAGAMENTO SEM CONTA NO SUPABASE (0017)
-- Pagamento feito fora do Simplifica (não sai de nenhuma conta), registro
-- dos pagamentos impressos na fatura sem conta, e os centavos que o banco
-- cobra junto (até R$ 0,99 a mais entram como acréscimo).
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa as verificações e no fim
-- DESFAZ TUDO (rollback). Nada fica gravado e nenhum dado real é tocado.
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
  v_email_a  text := 'validacao16-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao16-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '6.1e-pagamento-sem-conta' then
    raise exception 'ABORTADO: a 0017 (pagamento sem conta) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1e ou posterior', 'pg', 'valor', $$select (etapa >= '6.1e-pagamento-sem-conta')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'funções novas: search_path vazio, abertas só para usuário logado', 'pg', 'valor', $$select string_agg((prosecdef and proconfig = array['search_path=""'])::text || ':' || has_function_privilege('authenticated', oid, 'execute')::text || ':' || has_function_privilege('anon', oid, 'execute')::text, ' ' order by proname) from pg_proc where oid in ('public.obrigacao_pagar_externo(uuid, date, bigint, bigint, bigint, bigint, text, text)'::regprocedure, 'public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text, boolean)'::regprocedure)$$, 'true:true:false true:true:false'),
    (3, 'a versão antiga do registro (sem p_sem_conta) foi removida', 'pg', 'valor', $$select (to_regprocedure('public.importacao_fatura_registrar_pagamento(uuid, integer, uuid, uuid, text)') is null)::text$$, 'true'),
    (4, 'pagamento sem conta: sem lançamento e com data própria (regra no banco)', 'pg', 'valor', $$select count(*)::text from pg_constraint where conrelid = 'public.pagamentos'::regclass and conname in ('pagamentos_externo_coerente', 'pagamentos_origem_check')$$, '2'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 16"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o PDF da fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('7', 64) || '.pdf') returning name$$, null),
    (13, 'A cadastra uma conta no Itaú', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Itaú validação', 'corrente', 500000, '2026-08-01', null, null, true, true, 'validacao16-conta1')).id::text$$, 'itau'),
    (14, 'A cadastra um cartão Nubank (fecha 7, vence 14) pago pela conta Itaú', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Cartão validação', null, null, 7, 14, current_setting('val.itau')::uuid, 'validacao16-cartao')).id::text$$, 'cartao'),
    (15, 'compra na fatura de 09/2026 (R$ 375,15)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-08-10', 'Loja A', null, 37515, 1, null, 1, null, null, 'validacao16-compra1')).id::text$$, null),
    (16, 'compra na fatura de 10/2026 (R$ 618,40)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-10', 'Loja B', null, 61840, 1, null, 1, null, null, 'validacao16-compra2')).id::text$$, null),
    (17, 'importa a fatura 10/2026 com 2 pagamentos impressos (06/09 e 16/09)', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('7', 64), current_setting('val.a') || '/importacoes/' || repeat('7', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 61840, 59341, '[{"data":"2026-09-10","descricao":"Loja B","valor_centavos":61840,"tipo":"compra"}]', '[{"data":"2026-09-06","descricao":"Pagamento em 06 SET","valor_centavos":-37515},{"data":"2026-09-16","descricao":"Pagamento em 16 SET","valor_centavos":-2500},{"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":1},{"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":-1}]', 'validacao16-impf')).id::text$$, 'impf'),
    (18, 'confirma a importação', 'A', 'valor', $$select r.situacao from public.importacao_fatura_confirmar(current_setting('val.impf')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.impf')::uuid), null, 'validacao16-conff') r$$, 'confirmada'),
    (19, 'contas a pagar das faturas 09 e 10', 'A', 'ok', $$select string_agg(f.obrigacao_id::text, ',' order by f.competencia) from public.faturas f where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia in ('2026-09-01', '2026-10-01')$$, 'faturas'),

    -- pagamento antecipado SEM CONTA
    (20, 'registro sem conta recusa conta junto', 'A', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, current_setting('val.itau')::uuid, null, 'validacao16-reg-x', true)$$, '22023'),
    (21, 'registra o antecipado de 16/09 SEM CONTA', 'A', 'valor', $$select r.origem || ' ' || (r.movimento_id is null)::text || ' ' || r.data_pagamento::text || ' ' || r.abatido_centavos::text from public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, null, null, 'validacao16-reg-2', true) r$$, 'externo true 2026-09-16 2500'),
    (22, 'nenhum lançamento foi criado em conta nenhuma (saldo intacto)', 'A', 'valor', $$select count(*)::text || ' ' || (select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-31', null) where conta_id = current_setting('val.itau')::uuid) from public.movimentos$$, '0 500000'),
    (23, 'fatura 10/2026: falta pagar R$ 593,40 (igual ao PDF, menos o centavo da anterior)', 'A', 'valor', $$select restante_centavos::text || ' ' || abatido_centavos::text || ' ' || ultimo_pagamento_em::text from public.contas_a_pagar('2026-10-01', '2026-10-31', false) where obrigacao_id = split_part(current_setting('val.faturas'), ',', 2)::uuid$$, '59340 2500 2026-09-16'),
    (24, 'lista de pagamentos da conta mostra o sem conta (sem conta bancária, com a data)', 'A', 'valor', $$select origem || ' ' || coalesce(conta, 'sem-conta') || ' ' || data_pagamento::text || ' ' || situacao from public.pagamentos_da_obrigacao(split_part(current_setting('val.faturas'), ',', 2)::uuid)$$, 'externo sem-conta 2026-09-16 ativo'),
    (25, 'pagamentos da fatura: o de 16/09 aparece como registrado', 'A', 'valor', $$select string_agg(ordem || ':' || registrado, ' ' order by ordem) from public.importacao_fatura_pagamentos(current_setting('val.impf')::uuid)$$, '1:false 2:true'),
    (26, 'registrar de novo é recusado', 'A', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, null, null, 'validacao16-reg-2b', true)$$, '23505'),

    -- centavos: até R$ 0,99 a mais entra como acréscimo
    (30, 'pagamento sem conta com data futura é recusado', 'A', 'erro', $$select public.obrigacao_pagar_externo(split_part(current_setting('val.faturas'), ',', 1)::uuid, (now() + interval '3 days')::date, 100, 0, 0, 0, null, 'validacao16-fut')$$, '22023'),
    (31, 'paga R$ 1,00 da fatura 09 sem conta (sobra R$ 374,15)', 'A', 'ok', $$select (public.obrigacao_pagar_externo(split_part(current_setting('val.faturas'), ',', 1)::uuid, '2026-09-01', 100, 0, 0, 0, 'teste', 'validacao16-um-real')).id::text$$, 'um_real'),
    (32, 'pagamento impresso de R$ 375,15 passa R$ 1,00 do que falta: recusado', 'A', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 1, current_setting('val.itau')::uuid, null, 'validacao16-reg-1x')$$, '22023'),
    (33, 'desfaz o pagamento sem conta de R$ 1,00', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.um_real')::uuid, (select versao from public.pagamentos where id = current_setting('val.um_real')::uuid), 'teste', false)).situacao$$, 'desfeito'),
    (34, 'paga R$ 0,02 da fatura 09 sem conta (sobra R$ 374,13)', 'A', 'ok', $$select (public.obrigacao_pagar_externo(split_part(current_setting('val.faturas'), ',', 1)::uuid, '2026-09-01', 2, 0, 0, 0, 'teste', 'validacao16-dois-centavos')).id::text$$, null),
    (35, 'pagamento impresso de R$ 375,15 (R$ 0,02 a mais) saindo da conta Itaú: aceito, diferença como acréscimo', 'A', 'valor', $$select r.valor_pago_centavos || ' ' || r.juros_centavos || ' ' || r.abatido_centavos from public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 1, current_setting('val.itau')::uuid, null, 'validacao16-reg-1') r$$, '37515 2 37513'),
    (36, 'fatura 09/2026 quitada', 'A', 'valor', $$select status || ' ' || restante_centavos from public.contas_a_pagar('2026-09-01', '2026-09-30', false) where obrigacao_id = split_part(current_setting('val.faturas'), ',', 1)::uuid$$, 'paga 0'),
    (37, 'esse saiu da conta: a conta Itaú tem a saída de R$ 375,15', 'A', 'valor', $$select count(*)::text || ' ' || sum(valor_centavos)::text from public.movimentos where conta_id = current_setting('val.itau')::uuid$$, '1 37515'),

    -- desfazer o sem conta e isolamento
    (40, 'desfaz o antecipado sem conta', 'A', 'valor', $$select (public.pagamento_desfazer(p.id, p.versao, 'teste', false)).situacao from public.pagamentos p where p.obrigacao_id = split_part(current_setting('val.faturas'), ',', 2)::uuid and p.origem = 'externo' and p.situacao = 'ativo'$$, 'desfeito'),
    (41, 'a fatura 10 volta a R$ 618,40 a pagar e o de 16/09 volta a não registrado', 'A', 'valor', $$select (select restante_centavos::text from public.contas_a_pagar('2026-10-01', '2026-10-31', false) where obrigacao_id = split_part(current_setting('val.faturas'), ',', 2)::uuid) || ' ' || (select registrado::text from public.importacao_fatura_pagamentos(current_setting('val.impf')::uuid) where ordem = 2)$$, '61840 false'),
    (42, 'B não registra pagamento sem conta na fatura de A', 'B', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, null, null, 'validacao16-reg-b', true)$$, 'P0002'),
    (43, 'B não paga sem conta a fatura de A', 'B', 'erro', $$select public.obrigacao_pagar_externo(split_part(current_setting('val.faturas'), ',', 2)::uuid, '2026-09-01', 100, 0, 0, 0, null, 'validacao16-b-ext')$$, 'P0002'),
    (44, 'anônimo não paga sem conta', 'anon', 'erro', $$select public.obrigacao_pagar_externo(null, '2026-09-01', 100, 0, 0, 0, null, 'validacao16-anon')$$, '42501')
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
