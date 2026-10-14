-- =====================================================================
-- Simplifica Finanças v2 — 0013 Etapa 6 (parte 1): conciliação bancária
--
-- Migração ADICIONAL sobre a 0012 (etapa "5.5-leitores-faturas"). Não apaga
-- nem recria nada. Tudo numa única transação.
--
-- A conciliação usa o que já existe: o vínculo lançamento ↔ conta a pagar
-- (obrigacao_vincular_movimento / pagamento_desfazer) e a classificação do
-- lançamento (movimento_atualizar). Esta migração acrescenta:
--   * consultas: situação de cada lançamento (conciliado por pagamento,
--     classificado ou pendente), sugestões de vínculo, divergências,
--     resumo por conta e histórico de vínculos (inclusive desfeitos);
--   * uma operação: trocar um pagamento registrado à mão (que criou um
--     lançamento) pelo lançamento que veio no extrato importado — a saída
--     deixa de contar duas vezes, sem apagar nada.
-- Sugestão nunca quita nada sozinha: só o usuário confirma.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '5.5-leitores-faturas') then
    raise exception 'ABORTADO: este banco não está na Etapa 5 parte 5 (0012) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- Lançamentos com a situação de conciliação
--   pagamento   → paga (ou ajuda a pagar) conta a pagar / fatura
--   classificado→ receita ou despesa com classificação
--   pendente    → sem classificação e sem vínculo
-- =====================================================================
create or replace function public.conciliacao_lancamentos(p_conta_id uuid, p_de date, p_ate date)
returns table (
  movimento_id      uuid,
  conta_id          uuid,
  conta             text,
  data_movimento    date,
  descricao         text,
  valor_centavos    bigint,
  origem            text,
  classificacao     text,
  categoria         text,
  conciliacao       text,
  pagamentos        text,
  categoria_id      uuid,
  observacao        text,
  versao            integer
)
language sql stable security invoker
set search_path = ''
as $$
  select m.id, m.conta_id, c.apelido, m.data_movimento, m.descricao, m.valor_assinado_centavos, m.origem, m.classificacao, cat.nome,
         case when exists (select 1 from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo') then 'pagamento'
              when m.classificacao = 'nao_classificado' then 'pendente'
              else 'classificado' end,
         (select string_agg(o.descricao, ' · ' order by o.vencimento) from public.pagamentos p join public.obrigacoes o on o.id = p.obrigacao_id
           where p.movimento_id = m.id and p.situacao = 'ativo'),
         m.categoria_id, m.observacao, m.versao
    from public.movimentos m
    join public.contas c on c.id = m.conta_id
    left join public.categorias cat on cat.id = m.categoria_id
   where m.user_id = auth.uid() and m.situacao = 'efetivo' and m.estorno_de is null
     and (p_conta_id is null or m.conta_id = p_conta_id)
     and m.data_movimento between coalesce(p_de, '1900-01-01') and coalesce(p_ate, '2999-12-31')
   order by m.data_movimento desc, m.criado_em desc;
$$;

-- =====================================================================
-- Sugestões: lançamento de saída (sem vínculo) × conta a pagar aberta com
-- o MESMO valor restante, vencimento até 20 dias antes ou depois. Mais
-- pontos para data mais próxima e para nome do banco/cartão/conta na
-- descrição. Cada lançamento e cada conta a pagar aparecem uma vez só.
-- Fatura importada: vale também o "total a pagar" impresso pelo banco,
-- quando menor que o restante (pagamento feito antes do fechamento já
-- descontado pelo banco) — o vínculo é pelo valor cobrado e a fatura
-- continua aberta pelo resto, até o outro pagamento ser vinculado.
-- =====================================================================
create or replace function public.conciliacao_sugestoes(p_conta_id uuid)
returns table (
  movimento_id      uuid,
  conta_id          uuid,
  conta             text,
  data_movimento    date,
  descricao         text,
  valor_centavos    bigint,
  obrigacao_id      uuid,
  obrigacao         text,
  vencimento        date,
  restante_centavos bigint,
  valor_vincular_centavos bigint,
  e_fatura          boolean,
  pontos            integer,
  motivo            text
)
language sql stable security invoker
set search_path = ''
as $$
  with mov as (
    select m.*, m.valor_centavos
             - coalesce((select sum(e.valor_centavos) from public.movimentos e where e.estorno_de = m.id and e.situacao <> 'cancelado'), 0)
             - coalesce((select sum(p.valor_pago_centavos) from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo'), 0) as livre,
           regexp_replace(btrim(translate(lower(coalesce(m.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g') as norm
      from public.movimentos m
     where m.user_id = auth.uid() and m.situacao = 'efetivo' and m.natureza = 'debito' and m.estorno_de is null
       and (p_conta_id is null or m.conta_id = p_conta_id)
       and m.data_movimento >= privado.hoje() - 400
       and not exists (select 1 from public.pagamentos p where p.movimento_id = m.id and p.situacao = 'ativo')
  ),
  obr as (
    select o.*, o.valor_centavos - coalesce((select sum(p.abatido_centavos) from public.pagamentos p where p.obrigacao_id = o.id and p.situacao = 'ativo'), 0) as restante,
           (select regexp_replace(btrim(translate(lower(coalesce(i.nome || ' ' || k.apelido, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g')
              from public.faturas f join public.cartoes k on k.id = f.cartao_id join public.instituicoes i on i.id = k.instituicao_id
             where f.obrigacao_id = o.id) as nome_cartao,
           (select i.total_a_pagar_centavos from public.importacoes_fatura i join public.faturas f on f.id = i.fatura_id
             where f.obrigacao_id = o.id and i.situacao = 'confirmada' order by i.confirmada_em desc limit 1) as cobrado
      from public.obrigacoes o
     where o.user_id = auth.uid() and o.situacao = 'aberta'
  ),
  par as (
    select mov.id as mid, obr.id as oid, mov.conta_id, mov.data_movimento, mov.descricao as mdesc, mov.valor_centavos, obr.descricao as odesc,
           obr.vencimento, obr.restante, obr.origem = 'fatura' as e_fatura,
           mov.livre <> obr.restante as pelo_cobrado,
           abs(mov.data_movimento - obr.vencimento) as dias,
           exists (select 1 from regexp_split_to_table(coalesce(obr.nome_cartao, '') || ' ' || regexp_replace(btrim(translate(lower(coalesce(obr.descricao, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g'), '[^a-z0-9]+') t
                    where length(t) >= 4 and t not in ('fatura', 'conta', 'pagamento', 'boleto', 'cartao') and position(t in mov.norm) > 0) as nome_bate,
           obr.conta_prevista_id = mov.conta_id as conta_prevista
      from mov join obr on obr.restante > 0
                       and (obr.restante = mov.livre or (obr.cobrado > 0 and obr.cobrado < obr.restante and obr.restante = obr.valor_centavos and obr.cobrado = mov.livre))
     where abs(mov.data_movimento - obr.vencimento) <= 20
  ),
  pont as (
    select par.*, (100 - least(dias, 20) * 2 + case when nome_bate then 30 else 0 end + case when conta_prevista then 10 else 0 end)::int as pontos
      from par
  ),
  rank as (
    select pont.*, row_number() over (partition by mid order by pontos desc, dias, oid) as rm,
           row_number() over (partition by oid order by pontos desc, dias, mid) as ro
      from pont
  )
  select r.mid, r.conta_id, c.apelido, r.data_movimento, r.mdesc, r.valor_centavos, r.oid, r.odesc, r.vencimento, r.restante,
         case when r.pelo_cobrado then r.valor_centavos else r.restante end, r.e_fatura, r.pontos,
         concat_ws(' · ', case when r.pelo_cobrado then 'valor cobrado pelo banco na fatura (pagamento antecipado já descontado)' else 'mesmo valor' end,
                   case when r.dias = 0 then 'mesmo dia do vencimento' else r.dias || ' dia(s) do vencimento' end,
                   case when r.nome_bate then 'nome na descrição' end,
                   case when r.conta_prevista then 'conta prevista para o pagamento' end)
    from rank r join public.contas c on c.id = r.conta_id
   where r.rm = 1 and r.ro = 1
   order by r.data_movimento desc, r.pontos desc;
$$;

-- =====================================================================
-- Divergências
--   pagamento_duplicado: conta paga com "Pagar" (o Simplifica criou o
--     lançamento) e, na mesma conta, um lançamento IMPORTADO do extrato,
--     sem vínculo, com o mesmo valor e até 7 dias de diferença — a saída
--     está contando duas vezes.
--   saldo_importacao: importação de extrato cujo saldo informado pelo
--     banco não bate com o saldo calculado na mesma data.
-- =====================================================================
create or replace function public.conciliacao_divergencias(p_conta_id uuid)
returns table (
  tipo                  text,
  conta_id              uuid,
  conta                 text,
  data                  date,
  descricao             text,
  valor_centavos        bigint,
  pagamento_id          uuid,
  pagamento_versao      integer,
  obrigacao             text,
  movimento_importado_id uuid,
  importado_descricao   text,
  importado_data        date,
  importacao_id         uuid,
  saldo_informado       bigint,
  saldo_calculado       bigint
)
language sql stable security invoker
set search_path = ''
as $$
  select 'pagamento_duplicado', m.conta_id, c.apelido, m.data_movimento, m.descricao, m.valor_centavos, p.id, p.versao, o.descricao,
         imp.id, imp.descricao, imp.data_movimento, null::uuid, null::bigint, null::bigint
    from public.pagamentos p
    join public.movimentos m on m.id = p.movimento_id
    join public.obrigacoes o on o.id = p.obrigacao_id
    join public.contas c on c.id = m.conta_id
    cross join lateral (
      select i.* from public.movimentos i
       where i.user_id = p.user_id and i.conta_id = m.conta_id and i.origem = 'importacao' and i.situacao = 'efetivo'
         and i.natureza = 'debito' and i.estorno_de is null and i.valor_centavos = m.valor_centavos
         and abs(i.data_movimento - m.data_movimento) <= 7
         and not exists (select 1 from public.pagamentos q where q.movimento_id = i.id and q.situacao = 'ativo')
       order by abs(i.data_movimento - m.data_movimento), i.criado_em limit 1) imp
   where p.user_id = auth.uid() and p.situacao = 'ativo' and p.origem = 'pagamento' and m.situacao = 'efetivo'
     and m.valor_centavos = p.valor_pago_centavos
     and (p_conta_id is null or m.conta_id = p_conta_id)
  union all
  select 'saldo_importacao', c.id, c.apelido, i.saldo_informado_data, i.arquivo_nome, null::bigint, null::uuid, null::integer, null::text,
         null::uuid, null::text, null::date, i.importacao_id, i.saldo_informado_centavos, i.saldo_calculado_centavos
    from public.contas c
    cross join lateral public.importacoes_da_conta(c.id) i
   where c.user_id = auth.uid() and (p_conta_id is null or c.id = p_conta_id)
     and i.situacao = 'confirmada' and i.saldo_informado_centavos is not null and i.saldo_calculado_centavos is not null
     and i.saldo_informado_centavos <> i.saldo_calculado_centavos
     -- só a importação mais recente de cada conta (as antigas já foram superadas)
     and i.importacao_id = (select x.importacao_id from public.importacoes_da_conta(c.id) x
                             where x.situacao = 'confirmada' and x.saldo_informado_centavos is not null
                             order by x.saldo_informado_data desc, x.criado_em desc limit 1);
$$;

-- Resumo por conta (painel de saldos e tela de conciliação)
create or replace function public.conciliacao_resumo()
returns table (
  conta_id      uuid,
  pendentes     integer,
  sugestoes     integer,
  divergencias  integer,
  conciliados   integer
)
language sql stable security invoker
set search_path = ''
as $$
  select c.id,
         (select count(*)::int from public.conciliacao_lancamentos(c.id, null, null) l where l.conciliacao = 'pendente'),
         (select count(*)::int from public.conciliacao_sugestoes(c.id)),
         (select count(*)::int from public.conciliacao_divergencias(c.id)),
         (select count(*)::int from public.conciliacao_lancamentos(c.id, null, null) l where l.conciliacao <> 'pendente')
    from public.contas c
   where c.user_id = auth.uid() and c.ativa
   order by c.apelido;
$$;

-- Histórico de vínculos (ativos e desfeitos) dos lançamentos de uma conta
create or replace function public.conciliacao_historico(p_conta_id uuid)
returns table (
  pagamento_id    uuid,
  situacao        text,
  origem          text,
  data_movimento  date,
  descricao       text,
  valor_centavos  bigint,
  obrigacao       text,
  vencimento      date,
  criado_em       timestamptz,
  desfeito_em     timestamptz,
  desfeito_motivo text,
  versao          integer
)
language sql stable security invoker
set search_path = ''
as $$
  select p.id, p.situacao, p.origem, m.data_movimento, m.descricao, p.valor_pago_centavos, o.descricao, o.vencimento,
         p.criado_em, p.desfeito_em, p.desfeito_motivo, p.versao
    from public.pagamentos p
    join public.movimentos m on m.id = p.movimento_id
    join public.obrigacoes o on o.id = p.obrigacao_id
   where p.user_id = auth.uid() and (p_conta_id is null or m.conta_id = p_conta_id)
   order by coalesce(p.desfeito_em, p.criado_em) desc
   limit 200;
$$;

-- =====================================================================
-- Trocar o pagamento feito à mão pelo lançamento do extrato (atômico):
-- desfaz o pagamento e cancela o lançamento que ele criou; vincula o
-- lançamento importado à mesma conta a pagar, com os mesmos valores.
-- =====================================================================
create or replace function public.conciliacao_trocar_pagamento(
  p_pagamento_id        uuid,
  p_versao_esperada     integer,
  p_movimento_id        uuid,
  p_chave_idempotencia  text
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_pag  public.pagamentos;
  v_m1   public.movimentos;
  v_m2   public.movimentos;
  v_novo public.pagamentos;
begin
  perform privado.exigir_versao(p_versao_esperada);
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'conciliacao_trocar_pagamento', jsonb_build_object(
    'pagamento_id', p_pagamento_id, 'versao', p_versao_esperada, 'movimento_id', p_movimento_id));
  if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;

  select * into v_pag from public.pagamentos where id = p_pagamento_id and user_id = v_uid;
  if not found then
    raise exception 'Pagamento não encontrado' using errcode = 'P0002';
  end if;
  perform 1 from public.obrigacoes where id = v_pag.obrigacao_id for update;
  select * into v_pag from public.pagamentos where id = p_pagamento_id for update;
  if v_pag.versao <> p_versao_esperada then
    perform privado.falha_alteracao('public.pagamentos', p_pagamento_id, v_uid);
  end if;
  if v_pag.situacao <> 'ativo' or v_pag.origem <> 'pagamento' then
    raise exception 'Só um pagamento ativo registrado pelo Simplifica pode ser trocado pelo lançamento do extrato' using errcode = '22023';
  end if;
  select * into v_m1 from public.movimentos where id = v_pag.movimento_id;
  select * into v_m2 from public.movimentos where id = p_movimento_id and user_id = v_uid for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;
  if v_m2.id = v_m1.id or v_m2.situacao <> 'efetivo' or v_m2.natureza <> 'debito' or v_m2.estorno_de is not null
     or v_m2.conta_id <> v_m1.conta_id or v_m2.valor_centavos <> v_m1.valor_centavos
     or exists (select 1 from public.pagamentos q where q.movimento_id = v_m2.id and q.situacao = 'ativo') then
    raise exception 'O lançamento do extrato precisa ser uma saída efetiva da mesma conta, com o mesmo valor e sem outro vínculo' using errcode = '22023';
  end if;

  perform public.pagamento_desfazer(v_pag.id, v_pag.versao, 'Trocado pelo lançamento do extrato importado', true, null);
  v_novo := public.obrigacao_vincular_movimento(v_pag.obrigacao_id, v_m2.id, v_pag.valor_pago_centavos, v_pag.juros_centavos,
                                                v_pag.multa_centavos, v_pag.desconto_centavos, p_chave_idempotencia || '-v');
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_novo));
  return v_novo;
end $$;

-- =====================================================================
-- Permissões
-- =====================================================================
revoke all on function public.conciliacao_lancamentos(uuid, date, date) from public, anon;
revoke all on function public.conciliacao_sugestoes(uuid) from public, anon;
revoke all on function public.conciliacao_divergencias(uuid) from public, anon;
revoke all on function public.conciliacao_resumo() from public, anon;
revoke all on function public.conciliacao_historico(uuid) from public, anon;
revoke all on function public.conciliacao_trocar_pagamento(uuid, integer, uuid, text) from public, anon;
grant execute on function public.conciliacao_lancamentos(uuid, date, date) to authenticated;
grant execute on function public.conciliacao_sugestoes(uuid) to authenticated;
grant execute on function public.conciliacao_divergencias(uuid) to authenticated;
grant execute on function public.conciliacao_resumo() to authenticated;
grant execute on function public.conciliacao_historico(uuid) to authenticated;
grant execute on function public.conciliacao_trocar_pagamento(uuid, integer, uuid, text) to authenticated;

update public.versao_esquema set etapa = '6.1-conciliacao', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
