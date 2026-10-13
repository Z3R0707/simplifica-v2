-- =====================================================================
-- Simplifica Finanças v2 — 0005 Etapa 2: cancelamento parcial
--
-- Migração ADICIONAL sobre a 0004 (etapa "2-movimentos"). Não apaga nem
-- recria nada. Tudo numa única transação.
--
-- Cancelamento parcial: o lançamento original NÃO é alterado. É criado
-- um lançamento de sentido contrário, mesma conta, mesma classificação e
-- mesma categoria, ligado ao original (coluna estorno_de).
--   Compra R$ 100 + cancelamento parcial R$ 30 = saldo −70; categoria 70.
-- Garantias no banco (valem também para operações simultâneas):
--   * a soma dos cancelamentos parciais ativos nunca passa do original;
--   * o original não pode ter o valor reduzido abaixo do já cancelado,
--     nem mudar sentido, classificação, categoria ou conta enquanto tiver
--     cancelamentos parciais ativos;
--   * o original só pode ser cancelado por completo depois que os
--     cancelamentos parciais forem desfeitos;
--   * o vínculo é imutável e um cancelamento parcial não pode ter outro.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '2-movimentos') then
    raise exception 'ABORTADO: este banco não está na Etapa 2 (0004) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

alter table public.movimentos add column estorno_de uuid;
alter table public.movimentos
  add constraint movimentos_estorno_de_fk foreign key (estorno_de, user_id) references public.movimentos (id, user_id),
  add constraint movimentos_estorno_nao_proprio check (estorno_de is null or estorno_de <> id);
create index movimentos_estorno_de_idx on public.movimentos (estorno_de) where estorno_de is not null;

-- ---------------------------------------------------------------------
-- Regras do vínculo (gatilho; roda depois da validação geral da 0004)
-- ---------------------------------------------------------------------
create or replace function privado.movimento_regras_estorno()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pai       public.movimentos;
  v_ja        bigint;
begin
  if tg_op = 'UPDATE' and new.estorno_de is distinct from old.estorno_de then
    raise exception 'O vínculo de um cancelamento parcial não pode ser alterado' using errcode = '22023';
  end if;

  -- (a) este lançamento É um cancelamento parcial
  if new.estorno_de is not null and new.situacao <> 'cancelado' then
    -- trava o original: dois cancelamentos parciais simultâneos ficam em fila
    select * into v_pai from public.movimentos
     where id = new.estorno_de and user_id = new.user_id
       for update;
    if not found then
      raise exception 'Lançamento original não encontrado' using errcode = 'P0002';
    end if;
    if v_pai.estorno_de is not null then
      raise exception 'Um cancelamento parcial não pode ser cancelado parcialmente' using errcode = '22023';
    end if;
    if v_pai.situacao <> 'efetivo' then
      raise exception 'Só é possível cancelar parcialmente um lançamento que já aconteceu e não está cancelado' using errcode = '22023';
    end if;
    if new.situacao <> 'efetivo' then
      raise exception 'Cancelamento parcial precisa estar como já acontecido' using errcode = '22023';
    end if;
    if new.conta_id <> v_pai.conta_id or new.natureza = v_pai.natureza
       or new.classificacao <> v_pai.classificacao or new.categoria_id is distinct from v_pai.categoria_id then
      raise exception 'Cancelamento parcial precisa ser da mesma conta e categoria, no sentido contrário ao original' using errcode = '22023';
    end if;
    if new.data_movimento < v_pai.data_movimento then
      raise exception 'Cancelamento parcial não pode ter data anterior ao lançamento original (%)', to_char(v_pai.data_movimento, 'DD/MM/YYYY') using errcode = '22023';
    end if;
    select coalesce(sum(valor_centavos), 0) into v_ja from public.movimentos
     where estorno_de = v_pai.id and situacao <> 'cancelado' and id <> new.id;
    if v_ja + new.valor_centavos > v_pai.valor_centavos then
      raise exception 'Valor maior que o restante do lançamento (restam % centavos)', v_pai.valor_centavos - v_ja using errcode = '22023';
    end if;
  end if;

  -- (b) este lançamento é um ORIGINAL com cancelamentos parciais ativos
  if tg_op = 'UPDATE' and new.estorno_de is null then
    select coalesce(sum(valor_centavos), 0) into v_ja from public.movimentos
     where estorno_de = new.id and situacao <> 'cancelado';
    if v_ja > 0 then
      if new.situacao = 'cancelado' then
        raise exception 'Este lançamento tem cancelamentos parciais. Desfaça-os antes de cancelar o restante por completo, ou cancele parcialmente o valor que falta.' using errcode = '22023';
      end if;
      if new.valor_centavos < v_ja then
        raise exception 'O valor não pode ficar menor que o total já cancelado parcialmente' using errcode = '22023';
      end if;
      if new.natureza <> old.natureza or new.classificacao <> old.classificacao
         or new.categoria_id is distinct from old.categoria_id or new.conta_id <> old.conta_id
         or new.data_movimento > (select min(data_movimento) from public.movimentos where estorno_de = new.id and situacao <> 'cancelado') then
        raise exception 'Com cancelamentos parciais ativos, só é possível alterar descrição, observação e aumentar o valor' using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger movimentos_regras_estorno before insert or update on public.movimentos
  for each row execute function privado.movimento_regras_estorno();

-- ---------------------------------------------------------------------
-- RPC: cancelamento parcial
-- ---------------------------------------------------------------------
create or replace function public.movimento_cancelar_parcial(
  p_id                  uuid,
  p_valor_centavos      bigint,
  p_data                date,
  p_motivo              text,
  p_chave_idempotencia  text
)
returns public.movimentos
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_pai  public.movimentos;
  v_reg  public.movimentos;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'movimento_cancelar_parcial', jsonb_build_object(
    'id', p_id, 'valor', p_valor_centavos, 'data', p_data, 'motivo', p_motivo));
  if v_prev is not null then return jsonb_populate_record(null::public.movimentos, v_prev); end if;

  if p_motivo is null or length(btrim(p_motivo)) < 3 then
    raise exception 'Informe o motivo do cancelamento' using errcode = '22023';
  end if;
  if p_valor_centavos is null or p_valor_centavos <= 0 then
    raise exception 'Informe um valor maior que zero' using errcode = '22023';
  end if;
  if p_data is null then
    raise exception 'Informe a data do cancelamento' using errcode = '22023';
  end if;
  select * into v_pai from public.movimentos where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'Lançamento não encontrado' using errcode = 'P0002';
  end if;

  perform set_config('app.motivo', btrim(p_motivo), true);
  insert into public.movimentos (user_id, conta_id, natureza, valor_centavos, data_movimento, descricao,
                                 classificacao, categoria_id, situacao, origem, observacao, estorno_de)
  values (v_uid, v_pai.conta_id,
          case when v_pai.natureza = 'debito' then 'credito' else 'debito' end,
          p_valor_centavos, p_data,
          left('Cancelamento parcial: ' || v_pai.descricao, 200),
          v_pai.classificacao, v_pai.categoria_id, 'efetivo', 'manual', left(btrim(p_motivo), 500), v_pai.id)
  returning * into v_reg;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

revoke all on function privado.movimento_regras_estorno() from public, anon, authenticated, service_role;
revoke all on function public.movimento_cancelar_parcial(uuid, bigint, date, text, text) from public, anon;
grant execute on function public.movimento_cancelar_parcial(uuid, bigint, date, text, text) to authenticated;

update public.versao_esquema set etapa = '2.1-cancelamento-parcial', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
