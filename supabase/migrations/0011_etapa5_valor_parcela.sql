-- =====================================================================
-- Simplifica Finanças v2 — 0011 Etapa 5 (parte 4): corrigir o valor de UMA parcela
--
-- Migração ADICIONAL sobre a 0010 (etapa "5.3-importacao-faturas"). Não
-- apaga nem recria nada. Tudo numa única transação.
--
-- Para quando o banco cobra numa parcela um valor diferente do lançado
-- (ex.: centavos de arredondamento: R$ 75,32 na 1ª e R$ 75,31 nas outras).
--   * Muda só a parcela escolhida; o total da compra acompanha.
--   * Só parcelas ativas de compras e encargos (débitos); crédito/estorno não.
--   * O valor fica acima de zero e não abaixo do desconto de antecipação.
--   * Se a fatura já tiver pagamentos e o total ficar abaixo do pago, recusa
--     (mesma regra de sempre da fatura).
--   * Fica na auditoria, com o motivo.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '5.3-importacao-faturas') then
    raise exception 'ABORTADO: este banco não está na Etapa 5 parte 3 (0010) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

create or replace function public.parcela_alterar_valor(
  p_parcela_id          uuid,
  p_valor_centavos      bigint,
  p_motivo              text,
  p_chave_idempotencia  text
)
returns public.parcelas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_p    public.parcelas;
  v_c    public.compras;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'parcela_alterar_valor', jsonb_build_object(
    'parcela_id', p_parcela_id, 'valor', p_valor_centavos, 'motivo', p_motivo));
  if v_prev is not null then return jsonb_populate_record(null::public.parcelas, v_prev); end if;

  select * into v_p from public.parcelas where id = p_parcela_id and user_id = v_uid;
  if not found then
    raise exception 'Parcela não encontrada' using errcode = 'P0002';
  end if;
  -- mesma ordem de travas da importação de fatura: cartão, fatura, parcela
  perform 1 from public.cartoes where id = v_p.cartao_id for update;
  perform 1 from public.faturas where id = v_p.fatura_id for update;
  select * into v_p from public.parcelas where id = p_parcela_id for update;
  select * into v_c from public.compras where id = v_p.compra_id for update;
  if v_p.situacao <> 'ativa' or v_c.situacao <> 'ativa' then
    raise exception 'Parcela cancelada não muda de valor' using errcode = '22023';
  end if;
  if v_p.natureza <> 'debito' then
    raise exception 'Só compras e encargos têm o valor da parcela corrigido; para crédito ou estorno, cancele e lance de novo' using errcode = '22023';
  end if;
  if p_valor_centavos is null or p_valor_centavos <= 0 or p_valor_centavos > 10000000000000 then
    raise exception 'Informe o valor da parcela, maior que zero' using errcode = '22023';
  end if;
  if p_valor_centavos < v_p.desconto_centavos then
    raise exception 'O valor não pode ser menor que o desconto da antecipação (%)', privado.reais(v_p.desconto_centavos) using errcode = '22023';
  end if;
  if p_valor_centavos <> v_p.valor_centavos then
    perform set_config('app.ajuste_importacao', 'on', true);
    perform set_config('app.motivo', left(coalesce(nullif(btrim(p_motivo), ''), 'Valor da parcela corrigido'), 500), true);
    update public.compras set valor_total_centavos = valor_total_centavos + (p_valor_centavos - v_p.valor_centavos) where id = v_c.id;
    update public.parcelas set valor_centavos = p_valor_centavos where id = v_p.id returning * into v_p;
    perform set_config('app.ajuste_importacao', '', true);
    perform set_config('app.motivo', '', true);
  end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_p));
  return v_p;
end $$;

revoke all on function public.parcela_alterar_valor(uuid, bigint, text, text) from public, anon;
grant execute on function public.parcela_alterar_valor(uuid, bigint, text, text) to authenticated;

update public.versao_esquema set etapa = '5.4-valor-parcela', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
