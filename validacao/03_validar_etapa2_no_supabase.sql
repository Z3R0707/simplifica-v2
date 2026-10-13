-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 2 NO SUPABASE (movimentos e saldos)
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria usuários de teste, executa ~50 verificações reais da
-- Etapa 2 (regra da data-base, saldos por conta, consolidado, previstos,
-- versão, idempotência, categorias, isolamento, exclusão LGPD com
-- movimentos) e no fim DESFAZ TUDO (rollback). Nada fica gravado.
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
  v_email_a  text := 'validacao2-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao2-b-' || v_suf || '@teste.invalid';
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
  if v_res <> '2-movimentos' then
    raise exception 'ABORTADO: a Etapa 2 ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'Etapa 2 instalada (tabela movimentos com RLS)', 'pg', 'valor', $$select relrowsecurity::text from pg_class where oid = 'public.movimentos'::regclass$$, 'true'),
    (2, 'gatilho de validação de movimentos instalado', 'pg', 'valor', $$select count(*)::text from pg_trigger where tgname = 'movimentos_validar' and not tgisinternal$$, '1'),
    (3, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (4, 'anon sem privilégio em tabelas do public', 'pg', 'valor', $$select count(*)::text from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'$$, '0'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação A"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (20, 'A cadastra Santander (R$ 5.000,00 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Santander'), 'Santander', 'corrente', 500000, '2026-10-01', null, null, true, true, 'validacao2-c-santander')).id::text$$, 'santander'),
    (21, 'A cadastra Sicredi (R$ 3.500,00)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicredi'), 'Sicredi', 'corrente', 350000, '2026-10-01', null, null, true, true, 'validacao2-c-sicredi')).id::text$$, 'sicredi'),
    (22, 'A cadastra Itaú (R$ 2.800,00)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Itaú', 'corrente', 280000, '2026-10-01', null, null, true, true, 'validacao2-c-itau')).id::text$$, 'itau'),
    (23, 'A cadastra Nubank (R$ 1.200,00)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Nubank'), 'Nubank', 'corrente', 120000, '2026-10-01', null, null, true, true, 'validacao2-c-nubank')).id::text$$, 'nubank'),
    (24, 'A cadastra Mercado Pago (R$ 750,00)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Mercado Pago'), 'Mercado Pago', 'corrente', 75000, '2026-10-01', null, null, true, true, 'validacao2-c-mp')).id::text$$, 'mp'),
    (25, 'consolidado do exemplo da especificação = R$ 13.250,00', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldo_consolidado('2026-10-01')$$, '1325000'),
    (26, 'painel mostra as 5 contas separadas', 'A', 'valor', $$select count(*)::text from public.saldos_por_conta('2026-10-01')$$, '5'),
    (30, 'movimento ANTERIOR à data-base (30/09)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 10000, '2026-09-30', 'Anterior', 'nao_classificado', null, 'efetivo', null, 'validacao2-m-ant')).id::text$$, 'm_ant'),
    (31, 'movimento NO dia-base (01/10)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'credito', 5000, '2026-10-01', 'No dia-base', 'receita', (select id from public.categorias where nome = 'Reembolsos'), 'efetivo', null, 'validacao2-m-dia')).id::text$$, 'm_dia'),
    (32, 'despesa em 02/10 (R$ 200)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 20000, '2026-10-02', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao2-m1')).id::text$$, 'm1'),
    (33, 'receita em 05/10 (R$ 1.000)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'credito', 100000, '2026-10-05', 'Salário', 'receita', (select id from public.categorias where nome = 'Salário'), 'efetivo', null, 'validacao2-m2')).id::text$$, 'm2'),
    (34, 'saldo = inicial + só o que vem DEPOIS da data-base (R$ 5.800)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '580000'),
    (35, 'movimentos até a data-base ficam fora do saldo (2 no saldo / 2 anteriores)', 'A', 'valor', $$select movimentos_no_saldo || '/' || movimentos_anteriores_data_base from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '2/2'),
    (36, 'saldo em data intermediária (03/10) = R$ 4.800', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-03') where conta_id = current_setting('val.santander')::uuid$$, '480000'),
    (37, 'antes da data-base não há saldo confirmado', 'A', 'valor', $$select coalesce(saldo_confirmado_centavos::text, 'NULL') || ' ' || situacao from public.saldos_por_conta('2026-09-30') where conta_id = current_setting('val.santander')::uuid$$, 'NULL data_anterior_a_data_base'),
    (38, 'outra conta não é afetada', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.sicredi')::uuid$$, '350000'),
    (39, 'consolidado = soma dos confirmados (R$ 14.050)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldo_consolidado('2026-10-12')$$, '1405000'),
    (40, 'previsto em 10/11 (R$ 300)', 'A', 'ok', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 30000, '2026-11-10', 'Aluguel', 'despesa', (select id from public.categorias where nome = 'Moradia'), 'previsto', null, 'validacao2-p1')).id::text$$, 'p1'),
    (41, 'previsto altera só o projetado', 'A', 'valor', $$select saldo_confirmado_centavos || '/' || saldo_projetado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '580000/550000'),
    (42, 'previsto até a data-base é recusado', 'A', 'erro', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 100, '2026-10-01', 'x', 'nao_classificado', null, 'previsto', null, 'validacao2-p-ruim')).id::text$$, '22023'),
    (43, 'efetivo com data futura é recusado', 'A', 'erro', $$select public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 100, privado.hoje() + 1, 'x', 'nao_classificado', null, 'efetivo', null, 'validacao2-futuro')$$, '22023'),
    (44, 'efetivar o previsto (mesma linha)', 'A', 'valor', $$select (public.movimento_efetivar(current_setting('val.p1')::uuid, 1, '2026-10-10')).situacao$$, 'efetivo'),
    (45, 'efetivação não duplica', 'A', 'valor', $$select count(*)::text from public.movimentos where descricao = 'Aluguel'$$, '1'),
    (46, 'confirmado e projetado coincidem após efetivar (R$ 5.500)', 'A', 'valor', $$select saldo_confirmado_centavos || '/' || saldo_projetado_centavos from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '550000/550000'),
    (47, 'alterar sem versão é recusado', 'A', 'erro', $$select public.movimento_atualizar(current_setting('val.m1')::uuid, null, 'debito', 25000, '2026-10-02', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), null)$$, '22023'),
    (48, 'alterar com versão aplica', 'A', 'valor', $$select (public.movimento_atualizar(current_setting('val.m1')::uuid, 1, 'debito', 25000, '2026-10-02', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), null)).versao::text$$, '2'),
    (49, 'versão antiga é recusada', 'A', 'erro', $$select public.movimento_atualizar(current_setting('val.m1')::uuid, 1, 'debito', 1, '2026-10-02', 'x', 'despesa', (select id from public.categorias where nome = 'Alimentação'), null)$$, '40001'),
    (50, 'cancelar sem motivo é recusado', 'A', 'erro', $$select public.movimento_cancelar(current_setting('val.m2')::uuid, 1, '')$$, '22023'),
    (51, 'cancelar com motivo', 'A', 'valor', $$select (public.movimento_cancelar(current_setting('val.m2')::uuid, 1, 'Duplicado')).situacao$$, 'cancelado'),
    (52, 'cancelado sai do saldo (R$ 4.450)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '445000'),
    (53, 'cancelado continua registrado e auditado', 'A', 'valor', $$select count(*)::text from public.auditoria where tabela = 'movimentos' and registro_id = current_setting('val.m2')::uuid and motivo = 'Duplicado'$$, '1'),
    (54, 'extrato: saldo após o último = confirmado', 'A', 'valor', $$select saldo_apos_centavos::text from public.extrato_conta(current_setting('val.santander')::uuid) where conta_no_saldo order by data_movimento desc limit 1$$, '445000'),
    (55, 'reenvio idêntico não duplica', 'A', 'valor', $$select ((public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 20000, '2026-10-02', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao2-m1')).id = current_setting('val.m1')::uuid)::text$$, 'true'),
    (56, 'mesma chave com outro valor é recusada', 'A', 'erro', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 99, '2026-10-02', 'Mercado', 'despesa', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao2-m1')).id::text$$, 'SF409'),
    (57, 'categoria de despesa não classifica receita', 'A', 'erro', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'credito', 100, '2026-10-06', 'x', 'receita', (select id from public.categorias where nome = 'Alimentação'), 'efetivo', null, 'validacao2-cat-err')).id::text$$, '22023'),
    (58, 'valor zero é recusado', 'A', 'erro', $$select (public.movimento_criar(current_setting('val.itau')::uuid, 'debito', 0, '2026-10-06', 'x', 'nao_classificado', null, 'efetivo', null, 'validacao2-zero')).id::text$$, '23514'),
    (59, 'gravação direta em movimentos é negada', 'A', 'erro', $$insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao, classificacao) values (current_setting('val.a')::uuid, current_setting('val.itau')::uuid, 'credito', 1, '2026-10-06', 'x', 'nao_classificado')$$, '42501'),
    (60, 'muda a data-base para 05/10 com saldo de R$ 4.700', 'A', 'valor', $$select (public.conta_atualizar(current_setting('val.santander')::uuid, 1, (select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Santander'), 'Santander', 'corrente', 470000, '2026-10-05', null, null, true, true)).saldo_inicial_centavos::text$$, '470000'),
    (61, 'nova data-base: só conta o que vem depois dela (R$ 4.400)', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.santander')::uuid$$, '440000'),
    (66, 'saldo inicial não validado fica pendente', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Itaú'), 'Pendente', 'corrente', 1000, '2026-10-01', null, null, false, true, 'validacao2-c-pend')).id::text$$, 'pend'),
    (67, 'consolidado avisa a pendência', 'A', 'valor', $$select contas_pendentes || ' ' || completo from public.saldo_consolidado('2026-10-12')$$, '1 false'),
    (63, 'resumo de outubro por categoria', 'A', 'valor', $$select string_agg(classificacao || ':' || categoria || '=' || total_centavos, ', ' order by classificacao, categoria) from public.resumo_categorias('2026-10-01', '2026-10-31')$$, 'despesa:Alimentação=25000, despesa:Moradia=30000, receita:Reembolsos=5000'),
    (64, 'arquivar conta Mercado Pago', 'A', 'valor', $$select (public.conta_definir_ativa(current_setting('val.mp')::uuid, 1, false, 'validação')).ativa::text$$, 'false'),
    (65, 'conta arquivada não recebe movimento', 'A', 'erro', $$select (public.movimento_criar(current_setting('val.mp')::uuid, 'credito', 100, '2026-10-06', 'x', 'nao_classificado', null, 'efetivo', null, 'validacao2-mp-arq')).id::text$$, '22023'),
    (70, 'B não vê movimentos de A', 'B', 'valor', $$select count(*)::text from public.movimentos$$, '0'),
    (71, 'B não vê saldos de A', 'B', 'valor', $$select count(*)::text from public.saldos_por_conta()$$, '0'),
    (72, 'B não vê extrato da conta de A', 'B', 'valor', $$select count(*)::text from public.extrato_conta(current_setting('val.santander')::uuid)$$, '0'),
    (73, 'B não lança na conta de A', 'B', 'erro', $$select (public.movimento_criar(current_setting('val.santander')::uuid, 'debito', 100, '2026-10-06', 'invasão', 'nao_classificado', null, 'efetivo', null, 'validacao2-b-inv')).id::text$$, 'P0002'),
    (74, 'B não cancela movimento de A', 'B', 'erro', $$select public.movimento_cancelar(current_setting('val.m1')::uuid, 2, 'invasão')$$, 'P0002'),
    (75, 'anônimo não lê movimentos', 'anon', 'erro', $$select count(*) from public.movimentos$$, '42501'),
    (76, 'anônimo não consulta saldos', 'anon', 'erro', $$select * from public.saldos_por_conta()$$, '42501'),
    (80, 'B cria conta e movimento', 'B', 'ok', $$select (public.movimento_criar((public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Sicoob'), 'Sicoob', 'corrente', 10000, '2026-10-01', null, null, true, true, 'validacao2-b-conta')).id, 'debito', 500, '2026-10-02', 'Café', 'nao_classificado', null, 'efetivo', null, 'validacao2-b-mov')).id::text$$, 'b_mov'),
    (81, 'exportação LGPD de B inclui o movimento', 'B', 'valor', $$select jsonb_array_length(public.exportar_meus_dados() -> 'movimentos')::text$$, '1'),
    (82, 'B solicita exclusão', 'B', 'valor', format($f$select (public.exclusao_solicitar(%L)).status$f$, v_email_b), 'solicitada'),
    (83, 'servidor conclui exclusão de B (com movimentos)', 'svc', 'valor', $$select (public.exclusao_concluir(current_setting('val.b')::uuid)).status$$, 'concluida'),
    (84, 'movimentos de B removidos', 'pg', 'valor', $$select count(*)::text from public.movimentos where user_id = current_setting('val.b')::uuid$$, '0'),
    (85, 'movimentos de A intactos', 'pg', 'valor', $$select (count(*) > 0)::text from public.movimentos where user_id = current_setting('val.a')::uuid$$, 'true')
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
