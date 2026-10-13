-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 5 (PARTE 5) NO SUPABASE (0012)
-- Leitores de fatura de mais bancos: instituição Riachuelo e importação no
-- formato do Santander (parcelas da mesma compra na mesma fatura).
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
  v_email_a  text := 'validacao11-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao11-b-' || v_suf || '@teste.invalid';
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
  if v_res is null or v_res < '5.5-leitores-faturas' then
    raise exception 'ABORTADO: a Etapa 5 parte 5 (0012) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 5.5 ou posterior', 'pg', 'valor', $$select (etapa >= '5.5-leitores-faturas')::text from public.versao_esquema where sistema = 'simplifica-v2'$$, 'true'),
    (2, 'instituição Riachuelo (Midway) cadastrada', 'pg', 'valor', $$select count(*)::text from public.instituicoes where nome = 'Riachuelo (Midway)'$$, '1'),
    (3, 'leitores de fatura conferidos com arquivo real: 7 bancos', 'pg', 'valor', $$select string_agg(nome, ', ' order by nome) from public.instituicoes where 'pdf-fatura' = any (formatos_homologados) and leitor_status = 'homologado'$$, 'Itaú, Mercado Pago, Nubank, Riachuelo (Midway), Santander, Sicoob, Sicredi'),
    (4, 'nenhum banco homologado sem formato conferido', 'pg', 'valor', $$select count(*)::text from public.instituicoes where leitor_status = 'homologado' and cardinality(formatos_homologados) = 0$$, '0'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 11"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o PDF da fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('7', 64) || '.pdf') returning name$$, null),
    (13, 'A cadastra um cartão Riachuelo (instituição nova)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where nome = 'Riachuelo (Midway)'), 'Riachuelo validação', null, null, 6, 13, null, 'validacao11-cartao-r')).id::text$$, null),
    (14, 'A cadastra um cartão Santander (fecha 1, vence 8)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '033'), 'Santander validação', null, null, 1, 8, null, 'validacao11-cartao-s')).id::text$$, 'cartao'),
    (20, 'prévia de uma fatura no formato do Santander', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'santander-fatura-pdf', 'santander.pdf', repeat('7', 64), current_setting('val.a') || '/importacoes/' || repeat('7', 64) || '.pdf', 1000, '1234', '2026-10-08', '2026-10-01', 24925, 24925, '[{"data":"2026-10-01","descricao":"ANUIDADE","valor_centavos":2750,"tipo":"compra","parcela_atual":4,"parcelas_total":12},{"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":4,"parcelas_total":6},{"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":5,"parcelas_total":6,"antecipada":true},{"data":"2026-06-06","descricao":"LOJA PRESENTES","valor_centavos":5725,"tipo":"compra","parcela_atual":6,"parcelas_total":6,"antecipada":true},{"data":"2026-08-17","descricao":"QUADROS","valor_centavos":-2,"tipo":"credito"},{"data":"2026-09-15","descricao":"ASSINATURA","valor_centavos":4900,"tipo":"compra"},{"data":"2025-10-08","descricao":"LOJA ANTIGA","valor_centavos":102,"tipo":"compra","parcela_atual":12,"parcelas_total":12}]', '[]', 'validacao11-imp')).id::text$$, 'imp'),
    (21, 'parcelas 5 e 6 da mesma compra apontam para a 4 desta fatura', 'A', 'valor', $$select string_agg(sugestao || coalesce(':' || vinculo_ordem, ''), ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid$$, 'novo novo antecipar:2 antecipar:2 novo novo novo'),
    (22, 'confirma a importação', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_lancados || ' ' || r.itens_antecipados) from public.importacao_fatura_confirmar(current_setting('val.imp')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.imp')::uuid), null, 'validacao11-conf') r$$, 'confirmada 5 2'),
    (23, 'a compra fica com as 3 parcelas nesta fatura e nada nas seguintes', 'A', 'valor', $$select string_agg(p.numero || ':' || to_char(f.competencia, 'MM/YY'), ' ' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid and ordem = 2) and p.situacao = 'ativa'$$, '4:10/26 5:10/26 6:10/26'),
    (24, 'fatura no Simplifica = total do banco', 'A', 'valor', $$select (total_lancamentos_centavos = total_fatura_centavos)::text from public.importacoes_fatura_do_cartao(current_setting('val.cartao')::uuid) where importacao_id = current_setting('val.imp')::uuid$$, 'true'),
    (25, 'compra antiga (12/12 do ano anterior) entra só com a última parcela', 'A', 'valor', $$select data_compra::text || ' ' || parcela_inicial || '/' || parcelas_total from public.compras where id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid and ordem = 7)$$, '2025-10-08 12/12'),
    (30, 'B não vê a importação de A', 'B', 'valor', $$select count(*)::text from public.importacoes_fatura$$, '0')
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
