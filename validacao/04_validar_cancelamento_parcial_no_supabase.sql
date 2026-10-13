-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DO CANCELAMENTO PARCIAL NO SUPABASE (0005)
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria usuários de teste, executa ~30 verificações reais do
-- cancelamento parcial (saldo, resumo, limites, proteção do original,
-- isolamento) e no fim DESFAZ TUDO (rollback). Nada fica gravado.
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
  v_email_a  text := 'validacao3-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao3-b-' || v_suf || '@teste.invalid';
  v_orfao    text := gen_random_uuid()::text || '/orfao-validacao.txt';
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
  if v_res not in ('2.1-cancelamento-parcial', '3-contas-a-pagar', '4-cartoes') then
    raise exception 'ABORTADO: o cancelamento parcial (0005) ainda não está instalado (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'coluna de vínculo instalada', 'pg', 'valor', $$select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'movimentos' and column_name = 'estorno_de'$$, '1'),
    (2, 'gatilho de regras instalado', 'pg', 'valor', $$select count(*)::text from pg_trigger where tgname = 'movimentos_regras_estorno' and not tgisinternal$$, '1'),
    (3, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (20, 'A cadastra conta (R$ 1.000 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 100000, '2026-10-01', null, null, true, true, 'validacao3-conta-01')).id::text$$, 'conta'),
    (21, 'A lança compra de R$ 100 (03/10)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.conta')::uuid, 'debito', 10000, '2026-10-03', 'Compra loja', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao3-compra-01')).id::text$$, 'compra'),
    (22, 'cancelamento parcial de R$ 30 (06/10)', 'A', 'ok', $$select (public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 3000, '2026-10-06', 'Devolveram um item', 'validacao3-cp-0001')).id::text$$, 'cp'),
    (23, 'cria lançamento de sentido contrário, mesma categoria, ligado ao original', 'A', 'valor', $$select natureza || ' ' || classificacao || ' ' || valor_centavos || ' ' || (estorno_de = current_setting('val.compra')::uuid) || ' ' || (categoria_id = (select id from public.categorias where nome = 'Alimentação')) from public.movimentos where id = current_setting('val.cp')::uuid$$, 'credito despesa 3000 true true'),
    (24, 'original continua intacto', 'A', 'valor', $$select valor_centavos || ' ' || situacao from public.movimentos where id = current_setting('val.compra')::uuid$$, '10000 efetivo'),
    (25, 'saldo líquido (R$ 930)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '93000'),
    (26, 'antes da data do parcial, saldo ainda R$ 900', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-05') where conta_id = current_setting('val.conta')::uuid$$, '90000'),
    (27, 'resumo da categoria = R$ 70', 'A', 'valor', $$select total_centavos::text from public.resumo_categorias('2026-10-01', '2026-10-31') where categoria = 'Alimentação'$$, '7000'),
    (28, 'reenvio idêntico não duplica', 'A', 'valor', $$select ((public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 3000, '2026-10-06', 'Devolveram um item', 'validacao3-cp-0001')).id = current_setting('val.cp')::uuid)::text$$, 'true'),
    (29, 'mesma chave com outro valor é recusada', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 3001, '2026-10-06', 'Devolveram um item', 'validacao3-cp-0001')$$, 'SF409'),
    (30, 'não cancela mais que o restante (R$ 70)', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 7001, '2026-10-07', 'demais', 'validacao3-cp-0002')$$, '22023'),
    (31, 'motivo obrigatório', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 100, '2026-10-07', '', 'validacao3-cp-0003')$$, '22023'),
    (32, 'data anterior ao original recusada', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 100, '2026-10-02', 'antes', 'validacao3-cp-0004')$$, '22023'),
    (33, 'não cancela parcialmente um cancelamento parcial', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.cp')::uuid, 100, '2026-10-07', 'encadeado', 'validacao3-cp-0005')$$, '22023'),
    (34, 'original com parcial ativo não é cancelado por completo', 'A', 'erro', $$select public.movimento_cancelar(current_setting('val.compra')::uuid, 1, 'tudo')$$, '22023'),
    (35, 'original não fica menor que o já cancelado', 'A', 'erro', $$select public.movimento_atualizar(current_setting('val.compra')::uuid, 1, 'debito', 2000, '2026-10-03', 'Compra loja', 'despesa', (select id from public.categorias where nome = 'Alimentação'), null)$$, '22023'),
    (36, 'original não muda de categoria', 'A', 'erro', $$select public.movimento_atualizar(current_setting('val.compra')::uuid, 1, 'debito', 10000, '2026-10-03', 'Compra loja', 'despesa', (select id from public.categorias where nome = 'Lazer'), null)$$, '22023'),
    (37, 'desfazer o cancelamento parcial', 'A', 'valor', $$select (public.movimento_cancelar(current_setting('val.cp')::uuid, 1, 'lançado errado')).situacao$$, 'cancelado'),
    (38, 'saldo volta a R$ 900', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.conta')::uuid$$, '90000'),
    (39, 'agora o original pode ser cancelado por completo', 'A', 'valor', $$select (public.movimento_cancelar(current_setting('val.compra')::uuid, 1, 'desistiu')).situacao$$, 'cancelado'),
    (40, 'original cancelado não aceita cancelamento parcial', 'A', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 100, '2026-10-07', 'depois', 'validacao3-cp-0006')$$, '22023'),
    (41, 'gravação direta em movimentos continua negada', 'A', 'erro', $$insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao) values (current_setting('val.a')::uuid, current_setting('val.conta')::uuid, 'credito', 1, '2026-10-06', 'x', 'nao_classificado')$$, '42501'),
    (50, 'B não cancela parcialmente lançamento de A', 'B', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 100, '2026-10-07', 'invasão', 'validacao3-b-cp-01')$$, 'P0002'),
    (51, 'anônimo não executa o cancelamento parcial', 'anon', 'erro', $$select public.movimento_cancelar_parcial(current_setting('val.compra')::uuid, 100, '2026-10-07', 'anon', 'validacao3-anon-01')$$, '42501'),
    (60, 'INVARIANTE: nenhum lançamento com parciais acima do valor', 'pg', 'valor', $$select count(*)::text from public.movimentos p where p.estorno_de is null and (select coalesce(sum(e.valor_centavos), 0) from public.movimentos e where e.estorno_de = p.id and e.situacao <> 'cancelado') > p.valor_centavos$$, '0')
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
