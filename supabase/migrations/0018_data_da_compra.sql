-- =====================================================================
-- Simplifica Finanças v2 — 0018 Corrigir a data de uma compra do cartão
--
-- Migração ADICIONAL sobre a 0017 (etapa "6.1e-pagamento-sem-conta"). Não
-- apaga nada, não cria tabelas e não altera dados já gravados. Tudo numa
-- única transação.
--
--   * compra_alterar_data: corrige a data de um lançamento do cartão (ex.:
--     parcela do Nubank que veio com a data da cobrança). Muda SÓ a data:
--     a compra continua nas mesmas faturas, com os mesmos valores e parcelas.
--     Conferências: não pode ser no futuro, nem depois do vencimento da
--     fatura da 1ª parcela, nem depois de um estorno dela; um estorno não
--     pode ficar antes da compra estornada.
--   * compra_validar: a data só muda por essa função (antes não mudava nunca).
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '6.1e-pagamento-sem-conta') then
    raise exception 'ABORTADO: este banco não está na 0017 (pagamento sem conta) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- a data só muda por compra_alterar_data (substitui a da 0010; muda só a linha da data)
create or replace function privado.compra_validar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.situacao <> 'ativa' then
      raise exception 'Lançamento do cartão não pode nascer cancelado' using errcode = '22023';
    end if;
    perform 1 from public.cartoes where id = new.cartao_id and user_id = new.user_id and ativo for share;
    if not found then
      raise exception 'Cartão inexistente ou arquivado' using errcode = '22023';
    end if;
  else
    if new.cartao_id <> old.cartao_id or new.tipo <> old.tipo or new.subtipo is distinct from old.subtipo
       or (new.valor_total_centavos <> old.valor_total_centavos and coalesce(current_setting('app.ajuste_importacao', true), '') <> 'on')
       or new.parcelas_total <> old.parcelas_total
       or new.parcela_inicial <> old.parcela_inicial
       or (new.data_compra <> old.data_compra and coalesce(current_setting('app.ajuste_data_compra', true), '') <> 'on')
       or new.estorno_de is distinct from old.estorno_de then
      raise exception 'Valor, data, parcelas e tipo do lançamento do cartão não mudam: cancele e lance de novo' using errcode = '22023';
    end if;
    if old.situacao = 'cancelada' and new.situacao <> 'cancelada' then
      raise exception 'Lançamento cancelado não volta a valer' using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' or new.categoria_id is distinct from old.categoria_id then
    perform privado.exigir_categoria_despesa(new.user_id, new.categoria_id);
  end if;
  return new;
end $$;

create or replace function public.compra_alterar_data(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_data                date,
  p_chave_idempotencia  text default null
)
returns public.compras
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_c    public.compras;
  v_venc date;
  v_est  date;
  v_pai  date;
  v_reg  public.compras;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'compra_alterar_data', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'data', p_data));
    if v_prev is not null then return jsonb_populate_record(null::public.compras, v_prev); end if;
  end if;
  if p_data is null then
    raise exception 'Informe a data' using errcode = '22023';
  end if;
  if p_data > privado.hoje() then
    raise exception 'A data da compra não pode ser no futuro' using errcode = '22023';
  end if;

  select * into v_c from public.compras where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;
  if v_c.situacao <> 'ativa' then
    raise exception 'Lançamento cancelado não pode ser alterado' using errcode = '22023';
  end if;
  -- a compra não muda de fatura: a data não pode passar do vencimento da fatura da 1ª parcela
  select f.vencimento into v_venc
    from public.parcelas p join public.faturas f on f.id = p.fatura_id
   where p.compra_id = v_c.id and p.situacao <> 'cancelada'
   order by p.numero limit 1;
  if v_venc is not null and p_data > v_venc then
    raise exception 'A data não pode ser depois do vencimento da fatura em que o lançamento está (%)', to_char(v_venc, 'DD/MM/YYYY')
      using errcode = '22023';
  end if;
  select min(e.data_compra) into v_est from public.compras e where e.estorno_de = v_c.id and e.situacao = 'ativa';
  if v_est is not null and p_data > v_est then
    raise exception 'Esta compra tem estorno em %: a data da compra não pode ficar depois dele', to_char(v_est, 'DD/MM/YYYY')
      using errcode = '22023';
  end if;
  if v_c.estorno_de is not null then
    select data_compra into v_pai from public.compras where id = v_c.estorno_de;
    if p_data < v_pai then
      raise exception 'O estorno não pode ficar antes da compra estornada (%)', to_char(v_pai, 'DD/MM/YYYY') using errcode = '22023';
    end if;
  end if;

  perform set_config('app.ajuste_data_compra', 'on', true);
  perform set_config('app.motivo', 'Data da compra corrigida', true);
  update public.compras set data_compra = p_data
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then
    perform privado.falha_alteracao('public.compras', p_id, v_uid);
  end if;
  perform set_config('app.ajuste_data_compra', '', true);
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

revoke all on function public.compra_alterar_data(uuid, integer, date, text) from public, anon;
grant execute on function public.compra_alterar_data(uuid, integer, date, text) to authenticated;

update public.versao_esquema set etapa = '6.1f-data-da-compra', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
