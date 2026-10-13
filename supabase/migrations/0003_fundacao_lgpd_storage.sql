-- =====================================================================
-- Simplifica Finanças v2 — 0003 Fundação: LGPD, armazenamento privado
-- e exclusão de conta sem arquivos órfãos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Exportação dos dados do próprio usuário (LGPD, art. 18)
-- As etapas seguintes acrescentam suas tabelas a esta função.
-- ---------------------------------------------------------------------
create or replace function public.exportar_meus_dados()
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := privado.uid_obrigatorio();
begin
  return jsonb_build_object(
    'gerado_em',   now(),
    'perfil',      (select to_jsonb(p) from public.perfis p where p.id = v_uid),
    'titulares',   coalesce((select jsonb_agg(t order by t.criado_em) from public.titulares t where t.user_id = v_uid), '[]'),
    'contas',      coalesce((select jsonb_agg(c order by c.criado_em) from public.contas c where c.user_id = v_uid), '[]'),
    'categorias',  coalesce((select jsonb_agg(c order by c.criado_em) from public.categorias c where c.user_id = v_uid), '[]'),
    'documentos',  coalesce((select jsonb_agg(jsonb_build_object('arquivo', o.name, 'criado_em', o.created_at) order by o.name)
                               from storage.objects o
                              where o.bucket_id = 'documentos' and (storage.foldername(o.name))[1] = v_uid::text), '[]'),
    'auditoria',   coalesce((select jsonb_agg(a order by a.id) from public.auditoria a where a.user_id = v_uid), '[]')
  );
end $$;

-- =====================================================================
-- EXCLUSÃO DE CONTA — fluxo em 3 passos, sem arquivos órfãos
--
--  1. exclusao_solicitar(e-mail)  [usuário]
--     Confere o e-mail (rejeita NULL, vazio e divergente), registra a
--     solicitação e, a partir daí, BLOQUEIA novos envios ao Storage e
--     qualquer alteração de dados do usuário.
--  2. Edge Function "excluir-conta" [service_role]
--     Lista os arquivos do usuário (exclusao_listar_arquivos) e apaga
--     cada um pela API do Storage, repetindo até não sobrar nenhum.
--  3. exclusao_concluir(user_id) [service_role]
--     Espera terminar qualquer upload/escrita do usuário já iniciado
--     (trava exclusiva por usuário) e RECUSA concluir se ainda existir
--     qualquer arquivo dele.
--     Só então apaga os dados e o login, numa única transação.
--  Se algo falhar, a solicitação fica em 'falha' e pode ser retomada;
--  o usuário continua bloqueado para escrita e envio de arquivos, antes e
--  depois da conclusão (um token antigo ainda válido não consegue enviar).
-- =====================================================================

create or replace function public.exclusao_solicitar(p_confirmacao_email text)
returns public.exclusoes_conta
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid   uuid := privado.uid_obrigatorio();
  v_email text;
  v_reg   public.exclusoes_conta;
begin
  if p_confirmacao_email is null or btrim(p_confirmacao_email) = '' then
    raise exception 'Digite o e-mail da conta para confirmar a exclusão' using errcode = '22023';
  end if;
  select email into v_email from auth.users where id = v_uid;
  if v_email is null or btrim(v_email) = '' then
    raise exception 'Conta sem e-mail cadastrado: exclusão exige atendimento' using errcode = '22023';
  end if;
  if lower(btrim(p_confirmacao_email)) is distinct from lower(btrim(v_email)) then
    raise exception 'Confirmação não confere com o e-mail da conta' using errcode = '22023';
  end if;

  -- Retomada: reaproveita a solicitação ativa (inclusive após falha)
  update public.exclusoes_conta
     set status = 'solicitada', tentativas = tentativas + 1, atualizado_em = now()
   where user_id = v_uid and status <> 'concluida'
  returning * into v_reg;
  if not found then
    insert into public.exclusoes_conta (user_id) values (v_uid) returning * into v_reg;
  end if;
  return v_reg;
end $$;

-- [service_role] Lista arquivos remanescentes do usuário em QUALQUER
-- bucket cujo primeiro nível de pasta seja o id dele.
create or replace function public.exclusao_listar_arquivos(p_user_id uuid, p_limite integer default 1000)
returns table (bucket_id text, nome text)
language sql stable security definer
set search_path = ''
as $$
  select o.bucket_id, o.name
    from storage.objects o
   where (storage.foldername(o.name))[1] = p_user_id::text
   order by o.bucket_id, o.name
   limit greatest(1, least(coalesce(p_limite, 1000), 1000));
$$;

-- [service_role] Registra falha para retomada posterior
create or replace function public.exclusao_registrar_falha(p_user_id uuid, p_erro text, p_arquivos_removidos integer default 0)
returns void
language sql security definer
set search_path = ''
as $$
  update public.exclusoes_conta
     set status = 'falha', ultimo_erro = left(p_erro, 500),
         arquivos_removidos = arquivos_removidos + coalesce(p_arquivos_removidos, 0),
         atualizado_em = now()
   where user_id = p_user_id and status <> 'concluida';
$$;

-- [service_role] Conclusão: só apaga dados e login se não restar arquivo
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

-- [service_role] Conferência final: registra arquivos que apareceram
-- depois da conclusão e foram removidos pela Edge Function.
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

-- [service_role] Arquivos órfãos: pasta raiz que não pertence a nenhum
-- usuário existente (ex.: falha de rede no meio de uma exclusão antiga).
create or replace function public.storage_listar_orfaos(p_limite integer default 1000)
returns table (bucket_id text, nome text)
language sql stable security definer
set search_path = ''
as $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id = 'documentos'
     and not exists (select 1 from auth.users u where u.id::text = (storage.foldername(o.name))[1])
   order by o.name
   limit greatest(1, least(coalesce(p_limite, 1000), 1000));
$$;

-- ---------------------------------------------------------------------
-- Storage: bucket privado "documentos". Cada usuário só acessa a pasta
-- <user_id>/. Sem UPDATE/DELETE pelo usuário: o original é preservado.
-- Envio bloqueado quando há exclusão de conta em andamento.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do update set public = false;

create policy documentos_select_proprio on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy documentos_insert_proprio on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos'
              and (storage.foldername(name))[1] = auth.uid()::text
              and privado.pode_enviar_arquivo());

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
