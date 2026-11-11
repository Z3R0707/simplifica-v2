-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA CORREÇÃO DA DATA DA COMPRA NO SUPABASE (0018)
-- Correção da data de uma compra do cartão: muda só a data; a compra
-- continua nas mesmas faturas, com os mesmos valores e parcelas.
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
  v_email_a  text := 'validacao17-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao17-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '6.1f-data-da-compra' then
    raise exception 'ABORTADO: a 0018 (data da compra) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 6.1f ou posterior', 'pg', 'valor', $$select (etapa >= '6.1f-data-da-compra')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'função nova: search_path vazio, aberta só para usuário logado', 'pg', 'valor', $$select (prosecdef and proconfig = array['search_path=""'])::text || ':' || has_function_privilege('authenticated', oid, 'execute')::text || ':' || has_function_privilege('anon', oid, 'execute')::text from pg_proc where oid = 'public.compra_alterar_data(uuid, integer, date, text)'::regprocedure$$, 'true:true:false'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 17"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A cadastra um cartão Nubank (fecha 7, vence 14)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Cartão validação', null, null, 7, 14, null, 'validacao17-cartao')).id::text$$, 'cartao'),
    (13, 'compra em 3x em 20/09/2026 (faturas 10, 11 e 12/2026)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-20', 'Loja parcelada', null, 30000, 3, null, 1, null, null, 'validacao17-compra1')).id::text$$, 'compra'),
    (14, 'parcelas nas faturas 10, 11 e 12/2026', 'A', 'valor', $$select string_agg(f.competencia::text, ',' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = current_setting('val.compra')::uuid$$, '2026-10-01,2026-11-01,2026-12-01'),

    -- corrige a data
    (20, 'corrige a data para 05/09/2026', 'A', 'valor', $$select r.data_compra::text from public.compra_alterar_data(current_setting('val.compra')::uuid, (select versao from public.compras where id = current_setting('val.compra')::uuid), '2026-09-05', 'validacao17-data1') r$$, '2026-09-05'),
    (21, 'a compra continua nas mesmas faturas, com os mesmos valores', 'A', 'valor', $$select string_agg(f.competencia::text || ':' || p.valor_centavos, ',' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = current_setting('val.compra')::uuid$$, '2026-10-01:10000,2026-11-01:10000,2026-12-01:10000'),
    (22, 'a fatura mostra a data nova', 'A', 'valor', $$select data::text from public.lancamentos_da_fatura((select id from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01')) where compra_id = current_setting('val.compra')::uuid$$, '2026-09-05'),
    (23, 'a alteração fica auditada com o motivo', 'A', 'valor', $$select motivo from public.auditoria where tabela = 'compras' and registro_id = current_setting('val.compra')::uuid and operacao = 'UPDATE' order by id desc limit 1$$, 'Data da compra corrigida'),
    (15, 'compra de hoje (a fatura dela ainda vai vencer)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, (now() at time zone 'America/Sao_Paulo')::date, 'Compra de hoje', null, 2000, 1, null, 1, null, null, 'validacao17-compra-hoje')).id::text$$, 'hoje'),
    (24, 'data no futuro é recusada (mesmo antes do vencimento da fatura)', 'A', 'erro', $$select public.compra_alterar_data(current_setting('val.hoje')::uuid, (select versao from public.compras where id = current_setting('val.hoje')::uuid), ((now() at time zone 'America/Sao_Paulo')::date + 1), 'validacao17-futuro')$$, '22023'),
    (25, 'data depois do vencimento da fatura da 1ª parcela (14/10) é recusada', 'A', 'erro', $$select public.compra_alterar_data(current_setting('val.compra')::uuid, (select versao from public.compras where id = current_setting('val.compra')::uuid), '2026-10-20', 'validacao17-depois')$$, '22023'),
    (26, 'versão antiga é recusada (alterado em outro lugar)', 'A', 'erro', $$select public.compra_alterar_data(current_setting('val.compra')::uuid, 1, '2026-09-01', 'validacao17-versao')$$, '40001'),
    (27, 'mudar a data direto na tabela continua proibido', 'pg', 'erro', $$update public.compras set data_compra = '2026-09-02' where id = current_setting('val.compra')::uuid$$, '22023'),

    -- estornos
    (30, 'estorno de R$ 50,00 em 01/10/2026', 'A', 'ok', $$select (public.compra_estornar(current_setting('val.compra')::uuid, 5000, '2026-10-01', null, 'devolução', 'validacao17-est')).id::text$$, null),
    (31, 'a compra não pode ficar depois do estorno', 'A', 'erro', $$select public.compra_alterar_data(current_setting('val.compra')::uuid, (select versao from public.compras where id = current_setting('val.compra')::uuid), '2026-10-05', 'validacao17-pos-est')$$, '22023'),
    (32, 'o estorno não pode ficar antes da compra', 'A', 'erro', $$select public.compra_alterar_data(e.id, e.versao, '2026-09-01', 'validacao17-est-antes') from public.compras e where e.estorno_de = current_setting('val.compra')::uuid$$, '22023'),
    (33, 'o estorno pode ir para 10/09/2026 (depois da compra)', 'A', 'valor', $$select (public.compra_alterar_data(e.id, e.versao, '2026-09-10', 'validacao17-est-ok')).data_compra::text from public.compras e where e.estorno_de = current_setting('val.compra')::uuid$$, '2026-09-10'),

    -- cancelado e isolamento
    (40, 'compra de R$ 10,00 que será cancelada', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-21', 'Lancei errado', null, 1000, 1, null, 1, null, null, 'validacao17-compra2')).id::text$$, 'errada'),
    (41, 'cancela a compra', 'A', 'valor', $$select (public.compra_cancelar(current_setting('val.errada')::uuid, 1, 'lancei errado', true)).situacao$$, 'cancelada'),
    (42, 'lançamento cancelado não muda de data', 'A', 'erro', $$select public.compra_alterar_data(current_setting('val.errada')::uuid, (select versao from public.compras where id = current_setting('val.errada')::uuid), '2026-09-15', 'validacao17-cancelada')$$, '22023'),
    (43, 'B não altera a data de compra de A', 'B', 'erro', $$select public.compra_alterar_data(current_setting('val.compra')::uuid, 1, '2026-09-01', 'validacao17-b')$$, 'P0002'),
    (44, 'anônimo não altera', 'anon', 'erro', $$select public.compra_alterar_data(null, 1, '2026-09-01', null)$$, '42501')
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
