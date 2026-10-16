-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 6 (PARTE 1b) NO SUPABASE (0014)
-- Pagamentos mostrados na fatura importada (fatura anterior × antecipado),
-- registro pela conta ou pelo lançamento do extrato, e conciliação de
-- fatura com centavos de diferença.
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
  v_email_a  text := 'validacao13-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao13-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '6.1b-pagamentos-fatura' then
    raise exception 'ABORTADO: a Etapa 6 parte 1b (0014) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1b ou posterior', 'pg', 'valor', $$select (etapa >= '6.1b-pagamentos-fatura')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'funções novas instaladas e sugestão com acréscimo/desconto', 'pg', 'valor', $$select (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('importacao_fatura_pagamentos', 'importacao_fatura_registrar_pagamento'))::text || ' ' || (pg_get_function_result('public.conciliacao_sugestoes(uuid)'::regprocedure) like '%juros_centavos%desconto_centavos%')::text$$, '2 true'),
    (3, 'anônimo sem acesso às funções novas', 'pg', 'valor', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname in ('importacao_fatura_pagamentos', 'importacao_fatura_registrar_pagamento', 'conciliacao_sugestoes') and has_function_privilege('anon', oid, 'execute')$$, '0'),
    (4, 'consulta respeita a segurança por usuário; registro com search_path vazio', 'pg', 'valor', $$select string_agg(proname || ':' || case when prosecdef then 'definer' else 'invoker' end || coalesce(':' || array_to_string(proconfig, ','), ''), ' ' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('importacao_fatura_pagamentos', 'importacao_fatura_registrar_pagamento')$$, 'importacao_fatura_pagamentos:invoker:search_path="" importacao_fatura_registrar_pagamento:definer:search_path=""'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 13"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o PDF da fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('6', 64) || '.pdf') returning name$$, null),
    (13, 'A cadastra uma conta no Itaú', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Itaú validação', 'corrente', 500000, '2026-08-01', null, null, true, true, 'validacao13-conta1')).id::text$$, 'itau'),
    (14, 'A cadastra uma conta no Nubank', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Nubank validação', 'corrente', 300000, '2026-08-01', null, null, true, true, 'validacao13-conta2')).id::text$$, 'nuc'),
    (15, 'A cadastra um cartão Nubank (fecha 7, vence 14) pago pela conta Itaú', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Cartão validação', null, null, 7, 14, current_setting('val.itau')::uuid, 'validacao13-cartao')).id::text$$, 'cartao'),
    (16, 'compra na fatura de 09/2026 (R$ 375,15)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-08-10', 'Loja A', null, 37515, 1, null, 1, null, null, 'validacao13-compra1')).id::text$$, null),
    (17, 'compra na fatura de 10/2026 (R$ 618,40)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-10', 'Loja B', null, 61840, 1, null, 1, null, null, 'validacao13-compra2')).id::text$$, null),
    (18, 'importa a fatura 10/2026 com 2 pagamentos (06/09 e 16/09)', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('6', 64), current_setting('val.a') || '/importacoes/' || repeat('6', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 61840, 59341, '[{"data":"2026-09-10","descricao":"Loja B","valor_centavos":61840,"tipo":"compra"}]', '[{"data":"2026-09-06","descricao":"Pagamento em 06 SET","valor_centavos":-37515},{"data":"2026-09-16","descricao":"Pagamento em 16 SET","valor_centavos":-2500},{"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":1},{"data":"2026-09-14","descricao":"Saldo restante da fatura anterior","valor_centavos":-1}]', 'validacao13-impf')).id::text$$, 'impf'),
    (19, 'confirma a importação', 'A', 'valor', $$select r.situacao from public.importacao_fatura_confirmar(current_setting('val.impf')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.impf')::uuid), null, 'validacao13-conff') r$$, 'confirmada'),
    (20, 'débito de R$ 25,00 na conta Nubank em 16/09 (pagamento pelo app)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.nuc')::uuid, 'debito', 2500, '2026-09-16', 'Pagamento de fatura', 'nao_classificado', null, 'efetivo', null, 'validacao13-mov1')).id::text$$, 'mov'),
    (30, 'pagamentos da fatura: 06/09 quita a anterior, 16/09 é antecipado desta; saldo restante fica de fora', 'A', 'valor', $$select string_agg(ordem || ':' || tipo || ':' || valor_centavos || ':' || coalesce(obrigacao, '-') || ':' || registrado, ' | ' order by ordem) from public.importacao_fatura_pagamentos(current_setting('val.impf')::uuid)$$, '1:fatura_anterior:37515:Fatura Cartão validação 09/2026:false | 2:antecipado:2500:Fatura Cartão validação 10/2026:false'),
    (31, 'sugere a conta do mesmo banco do cartão e o débito de 16/09', 'A', 'valor', $$select ((conta_sugerida_id = current_setting('val.nuc')::uuid) and (movimento_sugerido_id = current_setting('val.mov')::uuid))::text from public.importacao_fatura_pagamentos(current_setting('val.impf')::uuid) where ordem = 2$$, 'true'),
    (40, 'registra o pagamento da fatura anterior saindo da conta Itaú', 'A', 'ok', $$select (public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 1, current_setting('val.itau')::uuid, null, 'validacao13-reg1')).id::text$$, null),
    (41, 'registra o antecipado vinculando o débito da conta Nubank', 'A', 'ok', $$select (public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, null, current_setting('val.mov')::uuid, 'validacao13-reg2')).id::text$$, null),
    (42, 'fatura anterior quitada; nesta falta R$ 593,40', 'A', 'valor', $$select string_agg((o.valor_centavos - coalesce((select sum(p.abatido_centavos) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo'), 0))::text, ' ' order by f.competencia) from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia in ('2026-09-01', '2026-10-01')$$, '0 59340'),
    (43, 'registrar de novo é recusado', 'A', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 2, current_setting('val.nuc')::uuid, null, 'validacao13-reg3')$$, '23505'),
    (50, 'débito da fatura na conta Nubank: R$ 593,41 (R$ 0,01 a mais)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.nuc')::uuid, 'debito', 59341, '2026-10-14', 'Pagamento de fatura', 'nao_classificado', null, 'efetivo', null, 'validacao13-mov2')).id::text$$, 'mov2'),
    (51, 'conciliação sugere com R$ 0,01 de acréscimo', 'A', 'valor', $$select valor_vincular_centavos || '+' || juros_centavos || '-' || desconto_centavos from public.conciliacao_sugestoes(current_setting('val.nuc')::uuid) where movimento_id = current_setting('val.mov2')::uuid$$, '59341+1-0'),
    (52, 'confirma a sugestão', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(s.obrigacao_id, s.movimento_id, s.valor_vincular_centavos, s.juros_centavos, 0, s.desconto_centavos, 'validacao13-vinc')).id::text from public.conciliacao_sugestoes(current_setting('val.nuc')::uuid) s where s.movimento_id = current_setting('val.mov2')::uuid$$, null),
    (53, 'fatura 10/2026 quitada', 'A', 'valor', $$select (o.valor_centavos - (select sum(p.abatido_centavos) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo'))::text from public.faturas f join public.obrigacoes o on o.id = f.obrigacao_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia = '2026-10-01'$$, '0'),
    (60, 'B não vê os pagamentos da fatura de A', 'B', 'valor', $$select count(*)::text from public.importacao_fatura_pagamentos(current_setting('val.impf')::uuid)$$, '0'),
    (61, 'B não registra pagamento na fatura de A', 'B', 'erro', $$select public.importacao_fatura_registrar_pagamento(current_setting('val.impf')::uuid, 1, current_setting('val.itau')::uuid, null, 'validacao13-reg-b')$$, 'P0002'),
    (62, 'anônimo não consulta', 'anon', 'erro', $$select count(*) from public.importacao_fatura_pagamentos(null)$$, '42501')
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
