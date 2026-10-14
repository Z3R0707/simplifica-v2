-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 6 (PARTE 1) NO SUPABASE (0013)
-- Conciliação bancária: sugestões (inclusive fatura com pagamento
-- antecipado), pendentes, pagamento em dobro, troca atômica, desfazer com
-- histórico e isolamento entre usuários.
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
  v_email_a  text := 'validacao12-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao12-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '6.1-conciliacao' then
    raise exception 'ABORTADO: a Etapa 6 parte 1 (0013) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1 ou posterior', 'pg', 'valor', $$select (etapa >= '6.1-conciliacao')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, '6 funções de conciliação instaladas', 'pg', 'valor', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'conciliacao\_%'$$, '6'),
    (3, 'anônimo sem acesso às funções de conciliação', 'pg', 'valor', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'conciliacao\_%' and has_function_privilege('anon', oid, 'execute')$$, '0'),
    (4, 'consultas respeitam a segurança por usuário (security invoker); a troca usa search_path vazio', 'pg', 'valor', $$select string_agg(proname || ':' || case when prosecdef then 'definer' else 'invoker' end || coalesce(':' || array_to_string(proconfig, ','), ''), ' ' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname like 'conciliacao\_%'$$, 'conciliacao_divergencias:invoker:search_path="" conciliacao_historico:invoker:search_path="" conciliacao_lancamentos:invoker:search_path="" conciliacao_resumo:invoker:search_path="" conciliacao_sugestoes:invoker:search_path="" conciliacao_trocar_pagamento:definer:search_path=""'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 12"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o extrato e a fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('8', 64) || '.ofx'), ('documentos', current_setting('val.a') || '/importacoes/' || repeat('9', 64) || '.pdf') returning name$$, null),
    (13, 'A cadastra uma conta corrente', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Conta validação', 'corrente', 500000, '2026-09-01', null, null, true, true, 'validacao12-conta')).id::text$$, 'conta'),
    (14, 'A cadastra um cartão pago por essa conta (vence dia 13)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Cartão validação', null, null, 3, 13, current_setting('val.conta')::uuid, 'validacao12-cartao')).id::text$$, 'cartao'),
    (15, 'A lança uma compra de R$ 987,65 no cartão', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-05', 'Mercado', null, 98765, 1, null, 1, null, null, 'validacao12-compra')).id::text$$, null),
    (16, 'A cadastra um 2º cartão (vence dia 8) pago pela mesma conta', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '033'), 'Santander validação', null, null, 1, 8, current_setting('val.conta')::uuid, 'validacao12-cartao2')).id::text$$, 'cartao2'),
    (17, 'importa a fatura do 2º cartão: soma R$ 1.200,50, banco cobra R$ 88,00 (pagamento antecipado)', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao2')::uuid, 'santander-fatura-pdf', 'fatura.pdf', repeat('9', 64), current_setting('val.a') || '/importacoes/' || repeat('9', 64) || '.pdf', 1000, null, '2026-10-08', '2026-10-01', 120050, 8800, '[{"data":"2026-09-10","descricao":"LOJA DE MOVEIS","valor_centavos":120050,"tipo":"compra"}]', '[{"data":"2026-09-22","descricao":"PAGAMENTO DE FATURA","valor_centavos":-111250}]', 'validacao12-impf')).id::text$$, 'impf'),
    (18, 'confirma a importação da fatura', 'A', 'valor', $$select r.situacao from public.importacao_fatura_confirmar(current_setting('val.impf')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.impf')::uuid), null, 'validacao12-conff') r$$, 'confirmada'),
    (19, 'A cadastra a conta a pagar "Internet" (R$ 100,00)', 'A', 'ok', $$select (public.obrigacao_criar('Internet', 10000, '2026-10-10', null, null, null, 'validacao12-obr')).id::text$$, 'net'),
    (20, 'prévia do extrato com 4 lançamentos', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.conta')::uuid, 'ofx', 'ofx-generico', 'extrato.ofx', repeat('8', 64), current_setting('val.a') || '/importacoes/' || repeat('8', 64) || '.ofx', 1000, null, null, null, null, '[{"data":"2026-10-13","descricao":"FATURA CARTAO","valor_centavos":-98765},{"data":"2026-10-02","descricao":"PAG BOLETO SANTANDER","valor_centavos":-8800},{"data":"2026-10-09","descricao":"DEBITO INTERNET","valor_centavos":-10000},{"data":"2026-10-03","descricao":"PADARIA","valor_centavos":-1500}]', 'validacao12-imp')).id::text$$, 'imp'),
    (21, 'confirma a importação do extrato', 'A', 'valor', $$select r.situacao from public.importacao_confirmar(current_setting('val.imp')::uuid, (select versao from public.importacoes where id = current_setting('val.imp')::uuid), null, 'validacao12-conf') r$$, 'confirmada'),
    (22, 'depois, a Internet é paga à mão (outro lançamento igual)', 'A', 'ok', $$select (public.obrigacao_pagar(current_setting('val.net')::uuid, current_setting('val.conta')::uuid, '2026-10-09', 10000, 0, 0, 0, null, 'validacao12-paga')).id::text$$, 'pagnet'),
    (30, 'sugestões: fatura (mesmo valor) e 2º cartão (valor cobrado pelo banco); a Internet já paga não é sugerida', 'A', 'valor', $$select string_agg(descricao || '→' || obrigacao || ':' || valor_vincular_centavos, ' | ' order by descricao) from public.conciliacao_sugestoes(current_setting('val.conta')::uuid)$$, 'FATURA CARTAO→Fatura Cartão validação 10/2026:98765 | PAG BOLETO SANTANDER→Fatura Santander validação 10/2026:8800'),
    (31, 'a sugestão explica o motivo', 'A', 'valor', $$select motivo from public.conciliacao_sugestoes(current_setting('val.conta')::uuid) where descricao = 'FATURA CARTAO'$$, 'mesmo valor · mesmo dia do vencimento · conta prevista para o pagamento'),
    (32, 'divergência: Internet paga à mão e também no extrato', 'A', 'valor', $$select string_agg(tipo || ':' || descricao || '=' || importado_descricao, ' ') from public.conciliacao_divergencias(current_setting('val.conta')::uuid)$$, 'pagamento_duplicado:Internet=DEBITO INTERNET'),
    (33, 'resumo da conta: pendentes, sugestões, divergências', 'A', 'valor', $$select pendentes || ' ' || sugestoes || ' ' || divergencias from public.conciliacao_resumo() where conta_id = current_setting('val.conta')::uuid$$, '4 2 1'),
    (40, 'confirma a sugestão da fatura', 'A', 'ok', $$select (public.obrigacao_vincular_movimento((select obrigacao_id from public.conciliacao_sugestoes(current_setting('val.conta')::uuid) where descricao = 'FATURA CARTAO'), (select id from public.movimentos where descricao = 'FATURA CARTAO'), 98765, 0, 0, 0, 'validacao12-vinc')).id::text$$, 'pagfat'),
    (41, 'o lançamento vira pagamento da fatura', 'A', 'valor', $$select conciliacao || ' ' || classificacao from public.conciliacao_lancamentos(current_setting('val.conta')::uuid, null, null) where descricao = 'FATURA CARTAO'$$, 'pagamento pagamento_fatura'),
    (42, 'confirma a do 2º cartão pelo valor cobrado', 'A', 'ok', $$select (public.obrigacao_vincular_movimento((select obrigacao_id from public.conciliacao_sugestoes(current_setting('val.conta')::uuid) where descricao = 'PAG BOLETO SANTANDER'), (select id from public.movimentos where descricao = 'PAG BOLETO SANTANDER'), 8800, 0, 0, 0, 'validacao12-vinc2')).id::text$$, null),
    (43, 'a fatura do 2º cartão fica aberta pelo pagamento antecipado (R$ 1.112,50) e não volta a ser sugerida', 'A', 'valor', $$select o.situacao || ' ' || (o.valor_centavos - (select sum(abatido_centavos) from public.pagamentos where obrigacao_id = o.id and situacao = 'ativo')) || ' ' || (select count(*) from public.conciliacao_sugestoes(current_setting('val.conta')::uuid)) from public.obrigacoes o join public.faturas f on f.obrigacao_id = o.id where f.cartao_id = current_setting('val.cartao2')::uuid and f.competencia = '2026-10-01'$$, 'aberta 111250 0'),
    (44, 'troca com versão desatualizada é recusada', 'A', 'erro', $$select public.conciliacao_trocar_pagamento(current_setting('val.pagnet')::uuid, 9, (select id from public.movimentos where descricao = 'DEBITO INTERNET'), 'validacao12-troca-x')$$, '40001'),
    (45, 'troca por lançamento de outro valor é recusada', 'A', 'erro', $$select public.conciliacao_trocar_pagamento(current_setting('val.pagnet')::uuid, 1, (select id from public.movimentos where descricao = 'PADARIA'), 'validacao12-troca-y')$$, '22023'),
    (46, 'troca o pagamento feito à mão pelo lançamento do extrato', 'A', 'ok', $$select (public.conciliacao_trocar_pagamento(current_setting('val.pagnet')::uuid, 1, (select id from public.movimentos where descricao = 'DEBITO INTERNET'), 'validacao12-troca')).id::text$$, null),
    (47, 'o lançamento feito à mão fica cancelado (não é apagado)', 'A', 'valor', $$select situacao from public.movimentos where id = (select movimento_id from public.pagamentos where id = current_setting('val.pagnet')::uuid)$$, 'cancelado'),
    (48, 'a Internet sai do saldo uma vez só', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-14') where conta_id = current_setting('val.conta')::uuid$$, '380935'),
    (49, 'divergência resolvida', 'A', 'valor', $$select count(*)::text from public.conciliacao_divergencias(current_setting('val.conta')::uuid)$$, '0'),
    (50, 'desfaz o vínculo da fatura com motivo', 'A', 'ok', $$select (public.pagamento_desfazer(current_setting('val.pagfat')::uuid, (select versao from public.pagamentos where id = current_setting('val.pagfat')::uuid), 'vinculei errado', false)).id::text$$, null),
    (51, 'o lançamento volta a pendente e a sugestão volta', 'A', 'valor', $$select (select conciliacao from public.conciliacao_lancamentos(current_setting('val.conta')::uuid, null, null) where descricao = 'FATURA CARTAO') || ' ' || (select count(*) from public.conciliacao_sugestoes(current_setting('val.conta')::uuid) where descricao = 'FATURA CARTAO')$$, 'pendente 1'),
    (52, 'o histórico guarda o vínculo desfeito e o motivo', 'A', 'valor', $$select count(*)::text from public.conciliacao_historico(current_setting('val.conta')::uuid) where situacao = 'desfeito' and desfeito_motivo = 'vinculei errado'$$, '1'),
    (60, 'B não vê nada da conciliação de A', 'B', 'valor', $$select ((select count(*) from public.conciliacao_lancamentos(null, null, null)) + (select count(*) from public.conciliacao_sugestoes(null)) + (select count(*) from public.conciliacao_divergencias(null)) + (select count(*) from public.conciliacao_historico(null)) + (select count(*) from public.conciliacao_resumo()))::text$$, '0'),
    (61, 'B não troca pagamento de A', 'B', 'erro', $$select public.conciliacao_trocar_pagamento(current_setting('val.pagnet')::uuid, 2, current_setting('val.pagnet')::uuid, 'validacao12-troca-b')$$, 'P0002'),
    (62, 'anônimo não consulta a conciliação', 'anon', 'erro', $$select count(*) from public.conciliacao_sugestoes(null)$$, '42501')
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
