-- =====================================================================
-- Simplifica Finanças v2 — 0015 Etapa 6 (parte 1c): desfazer vínculo de
-- lançamento com fatura devolve a classificação original
--
-- Migração ADICIONAL sobre a 0014 (etapa "6.1b-pagamentos-fatura"). Não
-- apaga nada, não cria tabelas e não altera dados. Tudo numa única
-- transação.
--
--   * pagamento_desfazer: quando o ÚLTIMO vínculo ativo de um lançamento
--     é desfeito, a classificação volta pela guardada no vínculo mais
--     recente que a guardou — e não só pela do vínculo sendo desfeito.
--     Antes, um lançamento vinculado a duas faturas ficava para sempre
--     como "pagamento de fatura": o 2º vínculo não guarda nada (o
--     lançamento já era pagamento de fatura) e o 1º, desfeito antes, não
--     devolvia porque ainda havia outro vínculo ativo.
--   * a linha do lançamento é travada antes de conferir se ainda há
--     vínculo ativo: dois vínculos desfeitos ao mesmo tempo não ficam
--     cada um esperando pelo outro para devolver. Ordem das travas igual
--     à de obrigacao_vincular_movimento (conta a pagar → lançamento).
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '6.1b-pagamentos-fatura') then
    raise exception 'ABORTADO: este banco não está na Etapa 6 parte 1b (0014) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- =====================================================================
-- Desfazer pagamento / vínculo
-- =====================================================================
create or replace function public.pagamento_desfazer(
  p_id                   uuid,
  p_versao_esperada      integer,
  p_motivo               text,
  p_cancelar_lancamento  boolean,
  p_chave_idempotencia   text default null
)
returns public.pagamentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := privado.uid_para_escrita();
  v_prev    jsonb;
  v_reg     public.pagamentos;
  v_cls     text;
  v_cat_ant uuid;
  v_cat     uuid;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo' using errcode = '22023';
  end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'pagamento_desfazer', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'motivo', p_motivo, 'cancelar_lancamento', p_cancelar_lancamento));
    if v_prev is not null then return jsonb_populate_record(null::public.pagamentos, v_prev); end if;
  end if;
  perform 1 from public.obrigacoes o
   where o.id = (select p.obrigacao_id from public.pagamentos p where p.id = p_id and p.user_id = v_uid)
     for update;
  perform set_config('app.motivo', btrim(p_motivo), true);
  update public.pagamentos set situacao = 'desfeito', desfeito_motivo = btrim(p_motivo), desfeito_em = now()
   where id = p_id and user_id = v_uid and versao = p_versao_esperada and situacao = 'ativo'
  returning * into v_reg;
  if not found then
    if exists (select 1 from public.pagamentos where id = p_id and user_id = v_uid and situacao = 'desfeito') then
      raise exception 'Pagamento já foi desfeito' using errcode = '22023';
    end if;
    perform privado.falha_alteracao('public.pagamentos', p_id, v_uid);
  end if;
  if coalesce(p_cancelar_lancamento, false) then
    if v_reg.origem <> 'pagamento' then
      raise exception 'Este pagamento só vinculou um lançamento existente; para cancelar o lançamento, use o extrato da conta' using errcode = '22023';
    end if;
    update public.movimentos set situacao = 'cancelado', cancelado_motivo = btrim(p_motivo), cancelado_em = now()
     where id = v_reg.movimento_id and user_id = v_uid and situacao <> 'cancelado';
  else
    -- trava o lançamento: outro vínculo dele desfeito ao mesmo tempo espera
    -- aqui e, ao seguir, já enxerga este como desfeito
    perform 1 from public.movimentos where id = v_reg.movimento_id and user_id = v_uid for update;
    if not exists (select 1 from public.pagamentos where movimento_id = v_reg.movimento_id and situacao = 'ativo') then
      -- último vínculo com fatura desfeito: o lançamento volta à
      -- classificação guardada no vínculo mais recente que a guardou (um
      -- 2º vínculo do mesmo lançamento não guarda nada, porque ele já era
      -- pagamento de fatura). Sem categoria, se ela tiver sido arquivada.
      select p.classificacao_anterior, p.categoria_anterior into v_cls, v_cat_ant
        from public.pagamentos p
       where p.movimento_id = v_reg.movimento_id and p.user_id = v_uid and p.classificacao_anterior is not null
       order by p.criado_em desc
       limit 1;
      if found then
        select id into v_cat from public.categorias where id = v_cat_ant and ativa;
        update public.movimentos
           set classificacao = case when v_cat is null then 'nao_classificado' else v_cls end,
               categoria_id = v_cat
         where id = v_reg.movimento_id and user_id = v_uid and classificacao = 'pagamento_fatura';
      end if;
    end if;
  end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;


-- =====================================================================
-- Permissões
-- =====================================================================
revoke all on function public.pagamento_desfazer(uuid, integer, text, boolean, text) from public, anon;
grant execute on function public.pagamento_desfazer(uuid, integer, text, boolean, text) to authenticated;

update public.versao_esquema set etapa = '6.1c-desfazer-vinculo', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
