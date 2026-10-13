-- =====================================================================
-- Simplifica Finanças v2 — ATUALIZAÇÃO da revisão 2 para a revisão 3
--
-- Use SOMENTE se você já rodou, no projeto simplifica-v2, os scripts
-- 0001–0003 da revisão 2 (simplifica-v2-etapa1-rev2.zip).
-- Instalação nova: NÃO use este arquivo; rode 0001–0003 desta revisão.
--
-- Corrige: (1) upload simultâneo à exclusão de conta e upload com token
-- antigo após a exclusão; (2) arquivamento de titular simultâneo à
-- criação, reativação ou alteração de contas.
-- Tudo roda numa única transação: se algo falhar, nada é alterado.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '1-fundacao') then
    raise exception 'ABORTADO: este banco não está na revisão 2 do Simplifica v2. Nada foi alterado.';
  end if;
  if exists (select 1 from public.contas c join public.titulares t on t.id = c.titular_id where c.ativa and not t.ativo) then
    raise exception 'ABORTADO: existem contas ativas ligadas a titulares arquivados. Me envie esta mensagem antes de continuar.';
  end if;
end $guarda$;

-- (1) Upload × exclusão de conta -------------------------------------
-- ---------------------------------------------------------------------
-- Concorrência entre exclusão de conta e operações do próprio usuário.
--
-- Cada usuário tem uma trava consultiva (advisory lock) própria:
--  * todo upload ao Storage e toda escrita de dados pega a trava em modo
--    COMPARTILHADO e a mantém até a sua transação terminar;
--  * exclusao_concluir pega a mesma trava em modo EXCLUSIVO, portanto
--    espera todos os uploads e escritas já iniciados terminarem antes de
--    conferir se restou algum arquivo. Nada iniciado antes da conclusão
--    pode ser confirmado depois dela.
-- Depois de solicitada (e também depois de concluída) a exclusão, novos
-- uploads e escritas daquele usuário são recusados — inclusive com um
-- token antigo ainda dentro da validade.
-- ---------------------------------------------------------------------
create or replace function privado.chave_trava_usuario(p_uid uuid)
returns bigint
language sql immutable
set search_path = ''
as $$
  select hashtextextended('simplifica-v2:usuario:' || p_uid::text, 0);
$$;

-- Usada na política de INSERT do Storage. VOLATILE porque pega a trava.
create or replace function privado.pode_enviar_arquivo()
returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
declare v uuid := auth.uid();
begin
  if v is null then return false; end if;
  perform pg_advisory_xact_lock_shared(privado.chave_trava_usuario(v));
  return exists (select 1 from auth.users where id = v)
     and not exists (select 1 from public.exclusoes_conta where user_id = v);
end $$;

-- Usuário corrente apto a ESCREVER: autenticado, existente e sem exclusão
create or replace function privado.uid_para_escrita()
returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare v uuid := privado.uid_obrigatorio();
begin
  perform pg_advisory_xact_lock_shared(privado.chave_trava_usuario(v));
  if exists (select 1 from public.exclusoes_conta where user_id = v)
     or not exists (select 1 from auth.users where id = v) then
    raise exception 'Conta excluída ou com exclusão em andamento: alterações bloqueadas' using errcode = '42501';
  end if;
  return v;
end $$;

drop policy if exists documentos_insert_proprio on storage.objects;
create policy documentos_insert_proprio on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos'
              and (storage.foldername(name))[1] = auth.uid()::text
              and privado.pode_enviar_arquivo());

drop function if exists privado.minha_exclusao_em_andamento();
drop function if exists public.exclusao_concluir(uuid, integer);
-- p_espera_ms: quanto tempo esperar uploads/escritas em andamento do
-- usuário terminarem (padrão 20 s). Se não terminarem, falha com 55P03
-- sem apagar nada, e a Edge Function tenta de novo.
create or replace function public.exclusao_concluir(p_user_id uuid, p_arquivos_removidos integer default 0, p_espera_ms integer default 20000)
returns public.exclusoes_conta
language plpgsql security definer
set search_path = ''
as $$
declare
  v_reg      public.exclusoes_conta;
  v_restante integer;
begin
  -- trava a solicitação para evitar duas conclusões simultâneas
  select * into v_reg from public.exclusoes_conta
   where user_id = p_user_id and status <> 'concluida'
   for update;
  if not found then
    raise exception 'Não há solicitação de exclusão ativa para este usuário' using errcode = 'P0002';
  end if;

  -- Espera (em modo exclusivo) todo upload e toda escrita do usuário que
  -- já tenham começado. Depois disso, nenhum deles pode mais confirmar.
  perform set_config('lock_timeout', greatest(100, least(coalesce(p_espera_ms, 20000), 60000))::text || 'ms', true);
  perform pg_advisory_xact_lock(privado.chave_trava_usuario(p_user_id));
  perform set_config('lock_timeout', '0', true);

  -- Contagem feita DEPOIS da trava: enxerga uploads que acabaram de confirmar
  select count(*) into v_restante from storage.objects o
   where (storage.foldername(o.name))[1] = p_user_id::text;
  if v_restante > 0 then
    raise exception 'Ainda existem % arquivo(s) do usuário no Storage; exclusão não concluída', v_restante
      using errcode = 'SF410';
  end if;

  perform set_config('app.excluindo_usuario', p_user_id::text, true);
  delete from public.auditoria           where user_id = p_user_id;
  delete from public.chaves_idempotencia where user_id = p_user_id;
  delete from public.uso_eventos         where user_id = p_user_id;
  delete from public.limites_uso         where user_id = p_user_id;
  delete from public.contas              where user_id = p_user_id;
  delete from public.categorias          where user_id = p_user_id;
  delete from public.titulares           where user_id = p_user_id;
  delete from public.perfis              where user_id = p_user_id;
  delete from auth.users                 where id = p_user_id;

  update public.exclusoes_conta
     set status = 'concluida', concluida_em = now(), atualizado_em = now(), ultimo_erro = null,
         arquivos_removidos = arquivos_removidos + coalesce(p_arquivos_removidos, 0)
   where id = v_reg.id
  returning * into v_reg;
  return v_reg;
end $$;

create or replace function public.exclusao_registrar_limpeza_tardia(p_user_id uuid, p_arquivos integer)
returns void
language sql security definer
set search_path = ''
as $$
  update public.exclusoes_conta
     set arquivos_removidos = arquivos_removidos + greatest(coalesce(p_arquivos, 0), 0),
         ultimo_erro = format('%s arquivo(s) removido(s) na conferência final', p_arquivos),
         atualizado_em = now()
   where user_id = p_user_id and status = 'concluida';
$$;

-- (2) Titular × contas -------------------------------------------------
-- ---------------------------------------------------------------------
-- INVARIANTE: nenhuma conta ativa pode estar ligada a titular arquivado.
-- Garantida no próprio banco, também sob transações simultâneas:
--  * conta ativa (criada, reativada ou alterada) trava o titular em modo
--    FOR SHARE e exige que ele esteja ativo;
--  * arquivar titular é um UPDATE (trava exclusiva da linha), que espera
--    as contas em andamento e depois confere, com leitura nova, se
--    sobrou alguma conta ativa.
-- Assim, qualquer que seja a ordem, um dos dois lados espera o outro e
-- é recusado se a regra for violada.
-- ---------------------------------------------------------------------
create or replace function privado.conta_exige_titular_ativo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.ativa then
    perform 1 from public.titulares
     where id = new.titular_id and user_id = new.user_id and ativo
       for share;
    if not found then
      raise exception 'Titular arquivado ou inexistente: a conta não pode ficar ativa' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger contas_exige_titular_ativo before insert or update on public.contas
  for each row execute function privado.conta_exige_titular_ativo();

create or replace function privado.titular_arquivar_sem_contas_ativas()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ativo and not new.ativo then
    if exists (select 1 from public.contas where titular_id = new.id and user_id = new.user_id and ativa) then
      raise exception 'Arquive antes as contas ativas deste titular' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger titulares_arquivar_sem_contas_ativas before update on public.titulares
  for each row execute function privado.titular_arquivar_sem_contas_ativas();

-- Trava o titular (FOR SHARE) e confirma que está ativo; usada pelas RPCs
-- para dar mensagem clara antes de chegar ao gatilho.
create or replace function privado.travar_titular_ativo(p_titular_id uuid, p_uid uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform 1 from public.titulares where id = p_titular_id and user_id = p_uid and ativo for share;
  if not found then
    raise exception 'Titular inexistente ou arquivado' using errcode = 'P0002';
  end if;
end $$;

create or replace function public.titular_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_nome                text,
  p_ativo               boolean,
  p_chave_idempotencia  text default null
)
returns public.titulares
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.titulares;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'titular_atualizar',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'nome', p_nome, 'ativo', p_ativo));
    if v_prev is not null then return jsonb_populate_record(null::public.titulares, v_prev); end if;
  end if;
  -- trava a linha do titular antes de conferir: espera contas sendo
  -- criadas/reativadas para ele e impede novas até o fim desta transação
  perform 1 from public.titulares where id = p_id and user_id = v_uid for update;
  if p_ativo is false and exists (select 1 from public.titulares where id = p_id and user_id = v_uid and principal) then
    raise exception 'O titular principal não pode ser arquivado' using errcode = '22023';
  end if;
  if p_ativo is false and exists (select 1 from public.contas where titular_id = p_id and user_id = v_uid and ativa) then
    raise exception 'Arquive antes as contas ativas deste titular' using errcode = '22023';
  end if;
  update public.titulares set nome = btrim(p_nome), ativo = coalesce(p_ativo, ativo)
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.titulares', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.conta_criar(
  p_titular_id              uuid,
  p_instituicao_id          uuid,
  p_apelido                 text,
  p_tipo                    text,
  p_saldo_inicial_centavos  bigint,
  p_saldo_inicial_data      date,
  p_agencia                 text,
  p_numero                  text,
  p_saldo_inicial_validado  boolean,
  p_incluir_consolidado     boolean,
  p_chave_idempotencia      text
)
returns public.contas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.contas;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'conta_criar', jsonb_build_object(
    'titular_id', p_titular_id, 'instituicao_id', p_instituicao_id, 'apelido', p_apelido, 'tipo', p_tipo,
    'saldo_inicial_centavos', p_saldo_inicial_centavos, 'saldo_inicial_data', p_saldo_inicial_data,
    'agencia', p_agencia, 'numero', p_numero, 'saldo_inicial_validado', p_saldo_inicial_validado,
    'incluir_consolidado', p_incluir_consolidado));
  if v_prev is not null then return jsonb_populate_record(null::public.contas, v_prev); end if;

  perform privado.travar_titular_ativo(p_titular_id, v_uid);
  insert into public.contas (user_id, titular_id, instituicao_id, apelido, tipo, agencia, numero,
                             saldo_inicial_centavos, saldo_inicial_data, saldo_inicial_validado, incluir_consolidado)
  values (v_uid, p_titular_id, p_instituicao_id, btrim(p_apelido), p_tipo,
          nullif(btrim(p_agencia), ''), nullif(btrim(p_numero), ''),
          coalesce(p_saldo_inicial_centavos, 0), p_saldo_inicial_data,
          coalesce(p_saldo_inicial_validado, false), coalesce(p_incluir_consolidado, true))
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.conta_atualizar(
  p_id                      uuid,
  p_versao_esperada         integer,
  p_titular_id              uuid,
  p_instituicao_id          uuid,
  p_apelido                 text,
  p_tipo                    text,
  p_saldo_inicial_centavos  bigint,
  p_saldo_inicial_data      date,
  p_agencia                 text,
  p_numero                  text,
  p_saldo_inicial_validado  boolean,
  p_incluir_consolidado     boolean,
  p_chave_idempotencia      text default null
)
returns public.contas
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.contas;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'conta_atualizar', jsonb_build_object(
      'id', p_id, 'versao', p_versao_esperada, 'titular_id', p_titular_id, 'instituicao_id', p_instituicao_id,
      'apelido', p_apelido, 'tipo', p_tipo, 'saldo_inicial_centavos', p_saldo_inicial_centavos,
      'saldo_inicial_data', p_saldo_inicial_data, 'agencia', p_agencia, 'numero', p_numero,
      'saldo_inicial_validado', p_saldo_inicial_validado, 'incluir_consolidado', p_incluir_consolidado));
    if v_prev is not null then return jsonb_populate_record(null::public.contas, v_prev); end if;
  end if;
  perform privado.travar_titular_ativo(p_titular_id, v_uid);
  update public.contas set
    titular_id = p_titular_id, instituicao_id = p_instituicao_id, apelido = btrim(p_apelido), tipo = p_tipo,
    agencia = nullif(btrim(p_agencia), ''), numero = nullif(btrim(p_numero), ''),
    saldo_inicial_centavos = coalesce(p_saldo_inicial_centavos, 0), saldo_inicial_data = p_saldo_inicial_data,
    saldo_inicial_validado = coalesce(p_saldo_inicial_validado, false),
    incluir_consolidado = coalesce(p_incluir_consolidado, true)
  where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.contas', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- ---------------------------------------------------------------------
-- Endurecimento de permissões. O PostgreSQL concede EXECUTE a PUBLIC em
-- toda função nova; retiramos de tudo e liberamos explicitamente.
-- (Bloco repetido ao fim de cada etapa.)
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as assinatura
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'privado')
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.assinatura);
  end loop;
end $$;

-- usado dentro da política do Storage (avaliada como o próprio usuário)
grant execute on function privado.pode_enviar_arquivo() to authenticated;

-- RPCs do usuário
grant execute on function public.perfil_atualizar(integer, text, text) to authenticated;
grant execute on function public.titular_criar(text, text) to authenticated;
grant execute on function public.titular_atualizar(uuid, integer, text, boolean, text) to authenticated;
grant execute on function public.conta_criar(uuid, uuid, text, text, bigint, date, text, text, boolean, boolean, text) to authenticated;
grant execute on function public.conta_atualizar(uuid, integer, uuid, uuid, text, text, bigint, date, text, text, boolean, boolean, text) to authenticated;
grant execute on function public.conta_definir_ativa(uuid, integer, boolean, text, text) to authenticated;
grant execute on function public.categoria_criar(text, text, uuid, text, text) to authenticated;
grant execute on function public.categoria_atualizar(uuid, integer, text, text, boolean, text) to authenticated;
grant execute on function public.exportar_meus_dados() to authenticated;
grant execute on function public.exclusao_solicitar(text) to authenticated;

-- RPCs exclusivas do servidor (Edge Functions com service_role)
grant execute on function public.exclusao_listar_arquivos(uuid, integer) to service_role;
grant execute on function public.exclusao_registrar_falha(uuid, text, integer) to service_role;
grant execute on function public.exclusao_concluir(uuid, integer, integer) to service_role;
grant execute on function public.storage_listar_orfaos(integer) to service_role;
grant execute on function public.exclusao_registrar_limpeza_tardia(uuid, integer) to service_role;
grant select on public.exclusoes_conta to service_role;

update public.versao_esquema set etapa = '1-fundacao-rev3', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
