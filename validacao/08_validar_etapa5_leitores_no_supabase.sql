-- =====================================================================
-- Simplifica Finanças v2 — VALIDAÇÃO DA ETAPA 5 (PARTE 2) NO SUPABASE (0009)
-- Leitores por banco: formato PDF aceito, Nubank (CSV da conta) e Itaú
-- (PDF da conta) registrados como homologados, e a troca do CSV genérico
-- pelo leitor do Nubank sem lançar nada em duplicidade.
--
-- Como usar: SQL Editor do projeto simplifica-v2 → cole tudo → Run.
--
-- O script cria 1 usuário de teste, executa as verificações e no fim
-- DESFAZ TUDO (rollback). Nada fica gravado: nenhum usuário, arquivo,
-- importação ou lançamento de teste permanece, e nenhum dado real é tocado.
-- Os lançamentos usados são fictícios.
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
  v_email_a  text := 'validacao8-a-' || v_suf || '@teste.invalid';
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
  if v_res <> '5.2-leitores-bancos' then
    raise exception 'ABORTADO: a Etapa 5 parte 2 (0009) ainda não está instalada (etapa atual: %). Nenhuma verificação foi executada.', v_res;
  end if;

  for c in
    select * from (values
    (1, 'versão do esquema: 5.2', 'pg', 'valor', $$select etapa from public.versao_esquema where sistema = 'simplifica-v2'$$, '5.2-leitores-bancos'),
    (2, 'formato aceita ofx, csv e pdf', 'pg', 'valor', $$select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.importacoes'::regclass and conname = 'importacoes_formato_check'$$, 'CHECK ((formato = ANY (ARRAY[''ofx''::text, ''csv''::text, ''pdf''::text])))'),
    (3, 'homologados: só Nubank (CSV da conta) e Itaú (PDF da conta)', 'pg', 'valor', $$select string_agg(nome || ':' || leitor_status || ':' || array_to_string(formatos_homologados, ','), ' | ' order by nome) from public.instituicoes where leitor_status <> 'nao_implementado'$$, 'Itaú:homologado:pdf-extrato | Nubank:homologado:csv-extrato'),
    (4, 'anon não executa nenhuma função do public', 'pg', 'valor', $$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')$$, '0'),
    (10, 'cria usuário de teste', 'pg', 'ok', format($f$insert into auth.users (id, email, raw_user_meta_data, aud, role) values (gen_random_uuid(), %L, '{"nome":"Validação 8"}', 'authenticated', 'authenticated') returning id::text$f$, v_email_a), 'a'),
    (11, 'guarda um PDF original no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf') returning name$$, null),
    (12, 'guarda o CSV antigo (genérico) no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('2', 64) || '.csv') returning name$$, null),
    (13, 'guarda o CSV novo (Nubank) no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('3', 64) || '.csv') returning name$$, null),
    (14, 'guarda um arquivo .xls no Storage', 'A', 'ok', $$insert into storage.objects (bucket_id, name) values ('documentos', current_setting('val.a') || '/importacoes/' || repeat('4', 64) || '.xls') returning name$$, null),
    (20, 'cadastra conta Itaú (R$ 183,95 em 12/09)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '341'), 'Itaú', 'corrente', 18395, '2026-09-12', null, null, true, true, 'validacao8-conta-it')).id::text$$, 'itau'),
    (21, 'cadastra conta Nubank (R$ 1.000 em 01/10)', 'A', 'ok', $$select (public.conta_criar((select id from public.titulares where principal), (select id from public.instituicoes where codigo_compe = '260'), 'Nubank', 'corrente', 100000, '2026-10-01', null, null, true, true, 'validacao8-conta-nu')).id::text$$, 'nu'),
    (22, 'formato desconhecido continua recusado', 'A', 'erro', $$select public.importacao_criar(current_setting('val.itau')::uuid, 'xls', 'x', 'a.xls', repeat('4', 64), current_setting('val.a') || '/importacoes/' || repeat('4', 64) || '.xls', 10, null, null, null, null, '[{"data":"2026-09-14","descricao":"x","valor_centavos":-100}]', 'validacao8-imp-x1')$$, '23514'),
    (30, 'prévia de um extrato do Itaú em PDF (saldo do dia R$ 93,95)', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.itau')::uuid, 'pdf', 'itau-extrato-pdf', 'extrato-itau.pdf', repeat('1', 64), current_setting('val.a') || '/importacoes/' || repeat('1', 64) || '.pdf', 90000, '341', '01234-5', 9395, '2026-09-14', '[{"data":"2026-09-14","descricao":"PIX TRANSF FULANO 14/09","valor_centavos":-12000},{"data":"2026-09-14","descricao":"PIX TRANSF LIA 14/09","valor_centavos":1800},{"data":"2026-09-14","descricao":"PIX TRANSF LIA 14/09","valor_centavos":1800},{"data":"2026-09-14","descricao":"PAY PADARIA 14/09","valor_centavos":-11600},{"data":"2026-09-14","descricao":"PIX TRANSF LIA 2 14/09","valor_centavos":12000},{"data":"2026-09-14","descricao":"PIX TRANSF BELTRANO 12/09","valor_centavos":-1000}]', 'validacao8-imp-pdf')).id::text$$, 'pdf'),
    (31, 'importação em PDF registrada com o leitor do Itaú', 'A', 'valor', $$select formato || ' ' || leitor || ' ' || itens_total from public.importacoes where id = current_setting('val.pdf')::uuid$$, 'pdf itau-extrato-pdf 6'),
    (32, 'dois PIX iguais no mesmo dia continuam sendo dois', 'A', 'valor', $$select count(*)::text from public.importacao_itens where importacao_id = current_setting('val.pdf')::uuid and sugestao = 'novo'$$, '6'),
    (33, 'confirma a importação do PDF', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_importados) from public.importacao_confirmar(current_setting('val.pdf')::uuid, (select versao from public.importacoes where id = current_setting('val.pdf')::uuid), null, 'validacao8-conf-pdf') r$$, 'confirmada 6'),
    (34, 'saldo do PDF (SALDO DO DIA) = saldo calculado', 'A', 'valor', $$select saldo_informado_centavos::text || ' = ' || saldo_calculado_centavos::text from public.importacoes_da_conta(current_setting('val.itau')::uuid) where importacao_id = current_setting('val.pdf')::uuid$$, '9395 = 9395'),
    (40, 'importa um CSV pelo leitor genérico (sem identificador)', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.nu')::uuid, 'csv', 'csv-mapeado', 'extrato nubank.csv', repeat('2', 64), current_setting('val.a') || '/importacoes/' || repeat('2', 64) || '.csv', 300, null, null, null, null, '[{"data":"2026-10-02","descricao":"Transferência recebida pelo Pix - FULANA","valor_centavos":900},{"data":"2026-10-02","descricao":"Transferência enviada pelo Pix - EMPRESA","valor_centavos":-19600}]', 'validacao8-imp-gen')).id::text$$, 'gen'),
    (41, 'confirma o CSV genérico', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_importados) from public.importacao_confirmar(current_setting('val.gen')::uuid, (select versao from public.importacoes where id = current_setting('val.gen')::uuid), null, 'validacao8-conf-gen') r$$, 'confirmada 2'),
    (42, 'novo arquivo pelo leitor do Nubank cobrindo os mesmos dias', 'A', 'ok', $$select (public.importacao_criar(current_setting('val.nu')::uuid, 'csv', 'nubank-csv-extrato', 'NU_2026-10.csv', repeat('3', 64), current_setting('val.a') || '/importacoes/' || repeat('3', 64) || '.csv', 400, '260', null, null, null, '[{"data":"2026-10-02","descricao":"Transferência recebida pelo Pix - FULANA","valor_centavos":900,"identificador":"11111111-1111-4111-8111-111111111111"},{"data":"2026-10-02","descricao":"Transferência enviada pelo Pix - EMPRESA","valor_centavos":-19600,"identificador":"22222222-2222-4222-8222-222222222222"},{"data":"2026-10-03","descricao":"Compra no débito - PADARIA","valor_centavos":-1250,"identificador":"33333333-3333-4333-8333-333333333333"}]', 'validacao8-imp-nu')).id::text$$, 'nuimp'),
    (43, 'o que já entrou pelo CSV genérico vira possível duplicado, desmarcado', 'A', 'valor', $$select string_agg(sugestao || ':' || incluir, ',' order by ordem) from public.importacao_itens where importacao_id = current_setting('val.nuimp')::uuid$$, 'possivel_duplicado:false,possivel_duplicado:false,novo:true'),
    (44, 'confirma o arquivo do Nubank', 'A', 'valor', $$select (r.situacao || ' ' || r.itens_importados) from public.importacao_confirmar(current_setting('val.nuimp')::uuid, (select versao from public.importacoes where id = current_setting('val.nuimp')::uuid), null, 'validacao8-conf-nu') r$$, 'confirmada 1'),
    (45, 'na troca de leitor nada é lançado duas vezes', 'A', 'valor', $$select count(*)::text from public.movimentos where conta_id = current_setting('val.nu')::uuid and situacao <> 'cancelado'$$, '3'),
    (46, 'leitor do Nubank usa o identificador do banco como chave', 'A', 'valor', $$select chave_importacao from public.movimentos where conta_id = current_setting('val.nu')::uuid and descricao like 'Compra no débito%'$$, 'id:33333333-3333-4333-8333-333333333333'),
    (47, 'saldo do Nubank: 1.000 + 9 − 196 − 12,50', 'A', 'valor', $$select saldo_confirmado_centavos::text from public.saldos_por_conta('2026-10-12') where conta_id = current_setting('val.nu')::uuid$$, '80050'),
    (50, 'INVARIANTE: nenhuma chave de importação repetida na mesma conta', 'pg', 'valor', $$select count(*)::text from (select 1 from public.movimentos m where m.chave_importacao is not null and m.situacao <> 'cancelado' group by m.user_id, m.conta_id, m.chave_importacao having count(*) > 1) x$$, '0')
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
