-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 5 (PARTE 3) NO SUPABASE (0010)
-- Importação de FATURA de cartão: prévia, parcelas já lançadas (com
-- acerto de centavos), parcela nova a partir da n-ésima, possível
-- duplicado, antecipação, conferência com o total do banco, desfazer.
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 2 usuários de teste, executa as verificações e no fim
-- DESFAZ TUDO (rollback). Nada fica gravado: nenhum usuário, arquivo,
-- cartão, compra ou importação de teste permanece, e nenhum dado real é
-- tocado. Os lançamentos usados são fictícios.
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
  v_email_a  text := 'validacao9-a-' || v_suf || '@teste.invalid';
  v_email_b  text := 'validacao9-b-' || v_suf || '@teste.invalid';
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
  if v_res <> '5.3-importacao-faturas' then
    raise exception 'ABORTADO: a Etapa 5 parte 3 (0010) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 5.3', 'pg', 'valor', $$select etapa from public.versao_esquema where sistema = 'simplifica-v2'$$, '5.3-importacao-faturas'),
    (2, 'tabelas novas instaladas, com RLS', 'pg', 'valor', $$select count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relname in ('importacoes_fatura', 'importacao_fatura_itens') and relrowsecurity$$, '2'),
    (3, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (4, 'usuário só lê (sem gravação direta) as tabelas novas', 'pg', 'valor', $$select count(*)::text from information_schema.role_table_grants where grantee in ('authenticated', 'anon') and table_name in ('importacoes_fatura', 'importacao_fatura_itens') and privilege_type <> 'SELECT'$$, '0'),
    (5, 'leitores de fatura registrados para Nubank e Itaú', 'pg', 'valor', $$select count(*)::text from public.instituicoes where codigo_compe in ('260', '341') and 'pdf-fatura' = any (formatos_homologados)$$, '2'),
    (6, 'exclusão de conta inclui importações de fatura (na ordem certa)', 'pg', 'valor', $$select (position('delete from public.importacao_fatura_itens' in d) < position('delete from public.compras ' in d) and position('delete from public.compras ' in d) < position('delete from public.importacoes_fatura ' in d) and position('delete from public.importacoes_fatura ' in d) < position('delete from public.faturas ' in d))::text from (select pg_get_functiondef('public.exclusao_concluir(uuid,integer,integer)'::regprocedure) d) x$$, 'true'),
    (10, 'cria usuário de teste A', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 9"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'cria usuário de teste B', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{}', 'authenticated', 'authenticated') returning id::text$f$, v_email_b), 'b'),
    (12, 'A guarda o PDF da fatura no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf') returning name$$, null),
    (13, 'A guarda uma cópia (outro arquivo) da mesma fatura', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('2', 64) || '.pdf') returning name$$, null),
    (20, 'A cadastra o cartão (fecha 7, vence 14)', 'A', 'ok', $$select (public.cartao_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Nubank validação', null, null, 7, 14, null, 'validacao9-cartao')).id::text$$, 'cartao'),
    (21, 'A já tinha lançado a TV em 10x (parcela 4 na fatura 10/2026)', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-06-02', 'Televisão', null, null, 10, 30000, 4, '2026-10-01', null, 'validacao9-tv')).id::text$$, 'tv'),
    (22, 'A já tinha lançado o Brinquedos em 3x de R$ 100,01', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-08-20', 'Brinquedos', null, null, 3, 10001, 1, '2026-09-01', null, 'validacao9-br')).id::text$$, 'br'),
    (23, 'A já tinha lançado uma padaria de R$ 18,95', 'A', 'ok', $$select (public.compra_criar(current_setting('val.cartao')::uuid, 'compra', null, '2026-09-12', 'Padaria', null, 1895, 1, null, 1, null, null, 'validacao9-pad')).id::text$$, null),
    (24, 'fatura 10/2026 antes: TV + Brinquedos + padaria = R$ 418,96', 'A', 'valor', $$(select coalesce(sum(p.valor_assinado_centavos), 0)::text from public.parcelas p join public.faturas f on f.id = p.fatura_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia = '2026-10-01' and p.situacao = 'ativa')$$, '41896'),
    (30, 'soma dos lançamentos diferente do total do banco: recusada', 'A', 'erro', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('1', 64), current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 82120, null, '[{"data": "2026-09-07", "descricao": "Loja Nova", "valor_centavos": 12000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 12}, {"data": "2026-09-07", "descricao": "Televisão", "valor_centavos": 30000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 10}, {"data": "2026-09-07", "descricao": "BRINQUEDOS", "valor_centavos": 9999, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-10", "descricao": "Drogaria", "valor_centavos": 8717, "tipo": "compra", "parcela_atual": 1, "parcelas_total": 3}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 3, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": -218, "tipo": "credito", "desconto_antecipacao": true}, {"data": "2026-09-09", "descricao": "IOF de compra", "valor_centavos": 399, "tipo": "encargo", "subtipo": "iof"}]', '[]', 'validacao9-x1')).id::text$$, '22023'),
    (31, 'prévia da fatura (10 lançamentos, total R$ 821,19)', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('1', 64), current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 82119, null, '[{"data": "2026-09-07", "descricao": "Loja Nova", "valor_centavos": 12000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 12}, {"data": "2026-09-07", "descricao": "Televisão", "valor_centavos": 30000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 10}, {"data": "2026-09-07", "descricao": "BRINQUEDOS", "valor_centavos": 9999, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-10", "descricao": "Drogaria", "valor_centavos": 8717, "tipo": "compra", "parcela_atual": 1, "parcelas_total": 3}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 3, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": -218, "tipo": "credito", "desconto_antecipacao": true}, {"data": "2026-09-09", "descricao": "IOF de compra", "valor_centavos": 399, "tipo": "encargo", "subtipo": "iof"}]', '[]', 'validacao9-imp1')).id::text$$, 'imp'),
    (32, 'sugestões: nova da 4ª; já lançadas (centavos −2); duplicado; padaria repetida; antecipações; desconto; IOF', 'A', 'valor', $$select string_agg(sugestao || ':' || incluir || case when ajuste_centavos <> 0 then ':' || ajuste_centavos else '' end, ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid$$, 'novo:true ja_lancado:false ja_lancado:false:-2 possivel_duplicado:false novo:true novo:true antecipar:true antecipar:true novo:true novo:true'),
    (33, 'a prévia não muda a fatura', 'A', 'valor', $$(select coalesce(sum(p.valor_assinado_centavos), 0)::text from public.parcelas p join public.faturas f on f.id = p.fatura_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia = '2026-10-01' and p.situacao = 'ativa')$$, '41896'),
    (34, 'a mesma fatura (mesmo arquivo) não entra duas vezes', 'A', 'erro', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('1', 64), current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 82119, null, '[{"data": "2026-09-07", "descricao": "Loja Nova", "valor_centavos": 12000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 12}, {"data": "2026-09-07", "descricao": "Televisão", "valor_centavos": 30000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 10}, {"data": "2026-09-07", "descricao": "BRINQUEDOS", "valor_centavos": 9999, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-10", "descricao": "Drogaria", "valor_centavos": 8717, "tipo": "compra", "parcela_atual": 1, "parcelas_total": 3}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 3, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": -218, "tipo": "credito", "desconto_antecipacao": true}, {"data": "2026-09-09", "descricao": "IOF de compra", "valor_centavos": 399, "tipo": "encargo", "subtipo": "iof"}]', '[]', 'validacao9-x2')).id::text$$, '22023'),
    (35, 'confirma: 5 lançados, 2 já existiam, 2 antecipados, 3 acertos de centavos, 1 de fora', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_lancados || ' ' || r.itens_existentes || ' ' || r.itens_antecipados || ' ' || r.itens_ajustados || ' ' || r.itens_ignorados) from public.importacao_fatura_confirmar(current_setting('val.imp')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.imp')::uuid), null, 'validacao9-conf1') r$$, 'confirmada 5 2 2 3 1'),
    (36, 'fatura 10/2026 = total do banco (R$ 821,19)', 'A', 'valor', $$(select coalesce(sum(p.valor_assinado_centavos), 0)::text from public.parcelas p join public.faturas f on f.id = p.fatura_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia = '2026-10-01' and p.situacao = 'ativa')$$, '82119'),
    (37, 'fatura recebe as datas reais e o total do banco', 'A', 'valor', $$select total_informado_centavos::text || ' ' || fechamento || ' ' || vencimento from public.faturas where cartao_id = current_setting('val.cartao')::uuid and competencia = '2026-10-01'$$, '82119 2026-10-07 2026-10-14'),
    (38, 'Drogaria: 1ª parcela criada, 2ª e 3ª antecipadas com o valor do banco', 'A', 'valor', $$select string_agg(p.numero || ':' || p.valor_centavos || ':' || to_char(f.competencia, 'MM'), ' ' order by p.numero) from public.parcelas p join public.faturas f on f.id = p.fatura_id where p.compra_id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid and ordem = 6)$$, '1:8717:10 2:8716:10 3:8716:10'),
    (39, 'Brinquedos: só a parcela desta fatura recebe o valor do banco', 'A', 'valor', $$select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = current_setting('val.br')::uuid$$, '1:10001 2:9999 3:10001'),
    (40, 'Loja Nova: compra criada da 4ª à 12ª parcela', 'A', 'valor', $$select c.parcela_inicial || '/' || c.parcelas_total || ' ' || (select count(*) from public.parcelas where compra_id = c.id) from public.compras c where c.id = (select compra_criada_id from public.importacao_fatura_itens where importacao_id = current_setting('val.imp')::uuid and ordem = 1)$$, '4/12 9'),
    (41, 'cópia da mesma fatura: tudo reconhecido (a padaria duvidosa continua duvidosa)', 'A', 'ok', $$select (public.importacao_fatura_criar(current_setting('val.cartao')::uuid, 'nubank-fatura-pdf', 'fatura.pdf', repeat('2', 64), current_setting('val.a') || '/importacoes/' || repeat('2', 64) || '.pdf', 1000, null, '2026-10-14', '2026-10-07', 82119, null, '[{"data": "2026-09-07", "descricao": "Loja Nova", "valor_centavos": 12000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 12}, {"data": "2026-09-07", "descricao": "Televisão", "valor_centavos": 30000, "tipo": "compra", "parcela_atual": 4, "parcelas_total": 10}, {"data": "2026-09-07", "descricao": "BRINQUEDOS", "valor_centavos": 9999, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-13", "descricao": "PADARIA", "valor_centavos": 1895, "tipo": "compra"}, {"data": "2026-09-10", "descricao": "Drogaria", "valor_centavos": 8717, "tipo": "compra", "parcela_atual": 1, "parcelas_total": 3}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 3, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": 8716, "tipo": "compra", "parcela_atual": 2, "parcelas_total": 3, "antecipada": true}, {"data": "2026-09-17", "descricao": "Drogaria", "valor_centavos": -218, "tipo": "credito", "desconto_antecipacao": true}, {"data": "2026-09-09", "descricao": "IOF de compra", "valor_centavos": 399, "tipo": "encargo", "subtipo": "iof"}]', '[]', 'validacao9-imp2')).id::text$$, 'imp2'),
    (42, 'sugestões da cópia', 'A', 'valor', $$select string_agg(sugestao, ' ' order by ordem) from public.importacao_fatura_itens where importacao_id = current_setting('val.imp2')::uuid$$, 'ja_lancado ja_lancado ja_lancado possivel_duplicado ja_importado ja_lancado ja_lancado ja_lancado ja_importado ja_importado'),
    (43, 'descarta a prévia da cópia', 'A', 'valor', $$select (public.importacao_fatura_desfazer(current_setting('val.imp2')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.imp2')::uuid), 'cópia')).situacao$$, 'cancelada'),
    (50, 'B não vê importações de fatura de A', 'B', 'valor', $$select ((select count(*) from public.importacoes_fatura) + (select count(*) from public.importacao_fatura_itens))::text$$, '0'),
    (51, 'B não desfaz importação de A', 'B', 'erro', $$select public.importacao_fatura_desfazer(current_setting('val.imp')::uuid, 9, 'invasão')$$, 'P0002'),
    (52, 'anônimo não consulta importações de fatura', 'anon', 'erro', $$select public.importacoes_fatura_do_cartao(current_setting('val.cartao')::uuid)$$, '42501'),
    (53, 'fora da importação, o valor da parcela não muda', 'pg', 'erro', $$update public.parcelas set valor_centavos = valor_centavos + 1 where compra_id = current_setting('val.tv')::uuid and numero = 6$$, '22023'),
    (54, 'histórico mostra a conferência (banco = Simplifica)', 'A', 'valor', $$select (total_lancamentos_centavos = total_fatura_centavos)::text from public.importacoes_fatura_do_cartao(current_setting('val.cartao')::uuid) where importacao_id = current_setting('val.imp')::uuid$$, 'true'),
    (55, 'exportação inclui importações de fatura e itens', 'A', 'valor', $$select (jsonb_array_length(d->'importacoes_fatura') = 2 and jsonb_array_length(d->'importacao_fatura_itens') = 20)::text from (select public.exportar_meus_dados() as d) x$$, 'true'),
    (60, 'desfaz a importação', 'A', 'valor', $$select (public.importacao_fatura_desfazer(current_setting('val.imp')::uuid, (select versao from public.importacoes_fatura where id = current_setting('val.imp')::uuid), 'validação')).situacao$$, 'cancelada'),
    (61, 'fatura 10/2026 volta a R$ 418,96', 'A', 'valor', $$(select coalesce(sum(p.valor_assinado_centavos), 0)::text from public.parcelas p join public.faturas f on f.id = p.fatura_id where f.cartao_id = current_setting('val.cartao')::uuid and f.competencia = '2026-10-01' and p.situacao = 'ativa')$$, '41896'),
    (62, 'acerto de centavos desfeito', 'A', 'valor', $$select string_agg(numero || ':' || valor_centavos, ' ' order by numero) from public.parcelas where compra_id = current_setting('val.br')::uuid$$, '1:10001 2:10001 3:10001'),
    (63, 'compras criadas pela importação canceladas (nada apagado)', 'A', 'valor', $$select count(*)::text || ' ' || count(*) filter (where situacao = 'ativa') from public.compras where importacao_fatura_id = current_setting('val.imp')::uuid$$, '5 0'),
    (70, 'INVARIANTE: nenhuma chave de importação repetida no mesmo cartão', 'pg', 'valor', $$select count(*)::text from (select 1 from public.compras where chave_importacao is not null and situacao = 'ativa' group by user_id, cartao_id, chave_importacao having count(*) > 1) x$$, '0')
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
