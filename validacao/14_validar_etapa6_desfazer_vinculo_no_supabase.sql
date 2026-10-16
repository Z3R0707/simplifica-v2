-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 6 (PARTE 1c) NO SUPABASE (0015)
-- Desfazer o vínculo de um lançamento com fatura devolve a classificação
-- original, também quando o mesmo lançamento pagou duas faturas.
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
  v_email_a  text := 'validacao14-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao14-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '6.1c-desfazer-vinculo' then
    raise exception 'ABORTADO: a Etapa 6 parte 1c (0015) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1c ou posterior', 'pg', 'valor', $$select (etapa >= '6.1c-desfazer-vinculo')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'pagamento_desfazer com search_path vazio e permissões de antes', 'pg', 'valor', $$select (prosecdef and proconfig = array['search_path=""'])::text || ' ' || has_function_privilege('authenticated', oid, 'execute')::text || ' ' || has_function_privilege('anon', oid, 'execute')::text from pg_proc where oid = 'public.pagamento_desfazer(uuid, integer, text, boolean, text)'::regprocedure$$, 'true true false'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 14"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A cadastra uma conta no Itaú', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Itaú validação', 'corrente', 1000000, '2026-10-01', null, null, true, true, 'validacao14-conta1')).id::text$$, 'itau'),
    (13, 'A cadastra um cartão Nubank (fecha 3, vence 10) pago pela conta Itaú', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Cartão validação', null, null, 3, 10, current_setting('val.itau')::uuid, 'validacao14-cartao')).id::text$$, 'cartao'),
    (14, 'compra de R$ 300,00 na fatura 10/2026', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-02', 'Loja A', null, 30000, 1, null, 1, null, null, 'validacao14-compra1')).id::text$$, null),
    (15, 'compra de R$ 200,00 na fatura 11/2026', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-05', 'Loja B', null, 20000, 1, null, 1, null, null, 'validacao14-compra2')).id::text$$, null),
    (16, 'conta a pagar da fatura 10/2026', 'A', 'ok', $$select obrigacao_id::text from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01'$$, 'f10'),
    (17, 'conta a pagar da fatura 11/2026', 'A', 'ok', $$select obrigacao_id::text from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-11-01'$$, 'f11'),
    (18, 'A cria a categoria Padaria', 'A', 'ok', $$select (public.categoria_criar('Padaria validação', 'despesa', null, null, 'validacao14-cat')).id::text$$, 'pada'),

    -- o problema corrigido: desfaz o 1º vínculo e depois o 2º
    (20, 'Pix de R$ 500,00 lançado como despesa em Alimentação', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'debito', 50000, '2026-10-11', 'Pix cartão', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao14-mov1')).id::text$$, 'm1'),
    (21, 'vincula o Pix à fatura 10/2026 (R$ 300,00)', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f10')::uuid, current_setting('val.m1')::uuid, 30000, 0, 0, 0, 'validacao14-v11')).id::text$$, 'p11'),
    (22, 'vincula o mesmo Pix à fatura 11/2026 (R$ 200,00)', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f11')::uuid, current_setting('val.m1')::uuid, 20000, 0, 0, 0, 'validacao14-v12')).id::text$$, 'p12'),
    (23, 'o Pix vira pagamento de fatura', 'A', 'valor', $$select classificacao from public.movimentos where id = current_setting('val.m1')::uuid$$, 'pagamento_fatura'),
    (24, 'desfaz o 1º vínculo', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p11')::uuid, (select versao from public.pagamentos where id = current_setting('val.p11')::uuid), 'vinculei errado', false, 'validacao14-d11')).situacao$$, 'desfeito'),
    (25, 'com o 2º vínculo ativo, continua pagamento de fatura', 'A', 'valor', $$select classificacao from public.movimentos where id = current_setting('val.m1')::uuid$$, 'pagamento_fatura'),
    (26, 'desfaz o 2º vínculo', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p12')::uuid, (select versao from public.pagamentos where id = current_setting('val.p12')::uuid), 'vinculei errado', false, 'validacao14-d12')).situacao$$, 'desfeito'),
    (27, 'sem vínculo ativo, o Pix volta a ser despesa em Alimentação (antes da 0015 ficava preso)', 'A', 'valor', $$select m.classificacao || ' ' || coalesce(c.nome, '-') from public.movimentos m left join public.categorias c on c.id = m.categoria_id where m.id = current_setting('val.m1')::uuid$$, 'despesa Alimentação'),

    -- ordem inversa: desfaz o 2º e depois o 1º
    (30, 'outro Pix de R$ 500,00 em Alimentação', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'debito', 50000, '2026-10-11', 'Pix cartão 2', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao14-mov2')).id::text$$, 'm2'),
    (31, 'vincula à fatura 10/2026', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f10')::uuid, current_setting('val.m2')::uuid, 30000, 0, 0, 0, 'validacao14-v21')).id::text$$, 'p21'),
    (32, 'vincula à fatura 11/2026', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f11')::uuid, current_setting('val.m2')::uuid, 20000, 0, 0, 0, 'validacao14-v22')).id::text$$, 'p22'),
    (33, 'desfaz o 2º vínculo primeiro', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p22')::uuid, (select versao from public.pagamentos where id = current_setting('val.p22')::uuid), 'vinculei errado', false, 'validacao14-d22')).situacao$$, 'desfeito'),
    (34, 'com o 1º ativo, continua pagamento de fatura', 'A', 'valor', $$select classificacao from public.movimentos where id = current_setting('val.m2')::uuid$$, 'pagamento_fatura'),
    (35, 'desfaz o 1º', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p21')::uuid, (select versao from public.pagamentos where id = current_setting('val.p21')::uuid), 'vinculei errado', false, 'validacao14-d21')).situacao$$, 'desfeito'),
    (36, 'volta a ser despesa em Alimentação', 'A', 'valor', $$select m.classificacao || ' ' || coalesce(c.nome, '-') from public.movimentos m left join public.categorias c on c.id = m.categoria_id where m.id = current_setting('val.m2')::uuid$$, 'despesa Alimentação'),

    -- categoria arquivada enquanto o lançamento estava vinculado
    (40, 'Pix de R$ 500,00 em Padaria', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'debito', 50000, '2026-10-11', 'Pix padaria', 'despesa', current_setting('val.pada')::uuid, 'efetivo', null, 'validacao14-mov3')).id::text$$, 'm3'),
    (41, 'vincula à fatura 10/2026', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f10')::uuid, current_setting('val.m3')::uuid, 30000, 0, 0, 0, 'validacao14-v31')).id::text$$, 'p31'),
    (42, 'vincula à fatura 11/2026', 'A', 'ok', $$select (public.obrigacao_vincular_movimento(current_setting('val.f11')::uuid, current_setting('val.m3')::uuid, 20000, 0, 0, 0, 'validacao14-v32')).id::text$$, 'p32'),
    (43, 'arquiva a categoria Padaria', 'A', 'valor', $$select (public.categoria_atualizar(current_setting('val.pada')::uuid, (select versao from public.categorias where id = current_setting('val.pada')::uuid), 'Padaria validação', null, false, 'validacao14-arq')).ativa::text$$, 'false'),
    (44, 'desfaz o 1º vínculo', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p31')::uuid, (select versao from public.pagamentos where id = current_setting('val.p31')::uuid), 'vinculei errado', false, 'validacao14-d31')).situacao$$, 'desfeito'),
    (45, 'desfaz o 2º vínculo', 'A', 'valor', $$select (public.pagamento_desfazer(current_setting('val.p32')::uuid, (select versao from public.pagamentos where id = current_setting('val.p32')::uuid), 'vinculei errado', false, 'validacao14-d32')).situacao$$, 'desfeito'),
    (46, 'categoria arquivada: volta sem categoria', 'A', 'valor', $$select classificacao || ' ' || coalesce(categoria_id::text, '-') from public.movimentos where id = current_setting('val.m3')::uuid$$, 'nao_classificado -'),

    -- regras que não mudaram
    (50, 'desfazer de novo é recusado', 'A', 'erro', $$select public.pagamento_desfazer(current_setting('val.p11')::uuid, (select versao from public.pagamentos where id = current_setting('val.p11')::uuid), 'de novo', false)$$, '22023'),
    (51, 'B não desfaz vínculo de A', 'B', 'erro', $$select public.pagamento_desfazer(current_setting('val.p12')::uuid, 1, 'invasão', false)$$, 'P0002'),
    (52, 'anônimo não desfaz', 'anon', 'erro', $$select public.pagamento_desfazer(current_setting('val.p12')::uuid, 1, 'invasão', false)$$, '42501')
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
