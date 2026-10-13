-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 5 (PARTE 4) NO SUPABASE (0011)
-- Corrigir o valor de UMA parcela (centavos que o banco cobrou diferente).
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
  v_email_a  text := 'validacao10-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao10-b-' || v_suf || '@teste.invalid';
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
  if v_res <> '5.4-valor-parcela' then
    raise exception 'ABORTADO: a Etapa 5 parte 4 (0011) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 5.4', 'pg', 'valor', $$select etapa from public.versao_esquema where sistema = 'simplifica-v2'$$, '5.4-valor-parcela'),
    (2, 'função instalada e fechada para anônimo', 'pg', 'valor', $$select (has_function_privilege('authenticated', 'public.parcela_alterar_valor(uuid,bigint,text,text)', 'execute') and not has_function_privilege('anon', 'public.parcela_alterar_valor(uuid,bigint,text,text)', 'execute'))::text$$, 'true'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 10"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (20, 'A cadastra um cartão', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Cartão validação', null, null, 3, 13, null, 'validacao10-cartao')).id::text$$, 'cartao'),
    (21, 'A lança uma compra em 4x de R$ 75,32', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-10-05', 'Compra validação', null, null, 4, 7532, 1, null, null, 'validacao10-compra')).id::text$$, 'compra'),
    (22, 'A corrige a 2ª parcela para R$ 75,31', 'A', 'valor', $$select (public.parcela_alterar_valor((select id from public.parcelas where compra_id = current_setting('val.compra')::uuid and numero = 2), 7531, 'centavos do banco', 'validacao10-valor1')).valor_centavos::text$$, '7531'),
    (23, 'só a parcela escolhida muda', 'A', 'valor', $$select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = current_setting('val.compra')::uuid$$, '1:7532 2:7531 3:7532 4:7532'),
    (24, 'o total da compra acompanha', 'A', 'valor', $$select valor_total_centavos::text from public.compras where id = current_setting('val.compra')::uuid$$, '30127'),
    (25, 'a conta a pagar da fatura acompanha', 'A', 'valor', $$select o.valor_centavos::text from public.obrigacoes o join public.faturas f on f.obrigacao_id = o.id where f.id = (select fatura_id from public.parcelas where id = (select id from public.parcelas where compra_id = current_setting('val.compra')::uuid and numero = 2))$$, '7531'),
    (26, 'a mudança fica na auditoria com o motivo', 'A', 'valor', $$select motivo from public.auditoria where tabela = 'parcelas' and registro_id = (select id from public.parcelas where compra_id = current_setting('val.compra')::uuid and numero = 2) order by id desc limit 1$$, 'centavos do banco'),
    (27, 'valor zero é recusado', 'A', 'erro', $$select public.parcela_alterar_valor((select id from public.parcelas where compra_id = current_setting('val.compra')::uuid and numero = 2), 0, null, 'validacao10-x1')$$, '22023'),
    (30, 'B não altera a parcela de A', 'B', 'erro', $$select public.parcela_alterar_valor((select id from public.parcelas where compra_id = current_setting('val.compra')::uuid and numero = 3), 100, null, 'validacao10-b1')$$, 'P0002'),
    (31, 'anônimo não altera parcela', 'anon', 'erro', $$select public.parcela_alterar_valor(gen_random_uuid(), 100, null, 'validacao10-anon')$$, '42501'),
    (32, 'fora desta função, o valor da parcela continua travado', 'pg', 'erro', $$update public.parcelas set valor_centavos = valor_centavos + 1 where compra_id = current_setting('val.compra')::uuid and numero = 4$$, '22023')
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
