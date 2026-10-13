-- =====================================================================
-- Simplifica Finanças v2 — 0001 Fundação: infraestrutura comum
-- Executar SOMENTE no projeto Supabase NOVO do Simplifica v2.
-- Rodar uma única vez, na ordem 0001 → 0002 → 0003.
-- =====================================================================

-- Esquema privado: funções internas, não expostas pela API.
create schema if not exists privado;
revoke all on schema privado from public;
-- authenticated precisa de USAGE só para as poucas funções usadas em
-- políticas de RLS; todas as demais têm EXECUTE revogado (ver 0003).
grant usage on schema privado to authenticated, service_role;

-- O Supabase concede por padrão privilégios amplos em tabelas novas do
-- schema public. Retiramos o padrão: cada tabela recebe só o necessário.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated, public;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- Marca de identificação deste banco (usada por scripts de verificação)
create table public.versao_esquema (
  sistema     text primary key,
  etapa       text not null,
  aplicado_em timestamptz not null default now()
);
alter table public.versao_esquema enable row level security;
insert into public.versao_esquema (sistema, etapa) values ('simplifica-v2', '1-fundacao-rev3');

-- ---------------------------------------------------------------------
-- Usuário corrente
-- ---------------------------------------------------------------------
create or replace function privado.uid_obrigatorio()
returns uuid
language plpgsql stable
set search_path = ''
as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'Sessão não autenticada' using errcode = '42501';
  end if;
  return v;
end $$;

-- Canal de origem (web, pwa, whatsapp, ia, importacao, cadastro...):
-- app.canal (definido pelo backend) ou cabeçalho HTTP x-canal.
create or replace function privado.canal_atual()
returns text
language sql stable
set search_path = ''
as $$
  select left(coalesce(
    nullif(current_setting('app.canal', true), ''),
    nullif((nullif(current_setting('request.headers', true), '')::json ->> 'x-canal'), ''),
    'desconhecido'
  ), 30);
$$;

-- Exige preenchimento da versão esperada em qualquer alteração
create or replace function privado.exigir_versao(p_versao integer)
returns void
language plpgsql immutable
set search_path = ''
as $$
begin
  if p_versao is null or p_versao < 1 then
    raise exception 'Versão esperada é obrigatória para alterar um registro' using errcode = '22023';
  end if;
end $$;

-- Diferencia "alterado por outro canal" de "não existe / não é seu"
create or replace function privado.falha_alteracao(p_tabela regclass, p_id uuid, p_uid uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v_existe boolean;
begin
  execute format('select exists (select 1 from %s where id = $1 and user_id = $2)', p_tabela)
    into v_existe using p_id, p_uid;
  if v_existe then
    raise exception 'O registro foi alterado em outro lugar. Recarregue e tente novamente.' using errcode = '40001';
  end if;
  raise exception 'Registro não encontrado' using errcode = 'P0002';
end $$;

-- ---------------------------------------------------------------------
-- Auditoria: toda alteração em tabela de dados gera um registro.
-- O usuário só LÊ a própria auditoria; ninguém a altera pela API.
-- ---------------------------------------------------------------------
create table public.auditoria (
  id            bigint generated always as identity primary key,
  user_id       uuid not null,
  tabela        text not null,
  registro_id   uuid,
  operacao      text not null check (operacao in ('INSERT','UPDATE','DELETE')),
  dados_antes   jsonb,
  dados_depois  jsonb,
  ator_id       uuid,
  canal         text not null,
  motivo        text,
  criado_em     timestamptz not null default now()
);
create index auditoria_user_tabela_idx on public.auditoria (user_id, tabela, registro_id, criado_em desc);
alter table public.auditoria enable row level security;
create policy auditoria_select_proprio on public.auditoria
  for select to authenticated using (user_id = auth.uid());
grant select on public.auditoria to authenticated;

create or replace function privado.registrar_auditoria()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_new  jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old  jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_user uuid  := coalesce((v_new ->> 'user_id')::uuid, (v_old ->> 'user_id')::uuid);
  v_id   uuid  := coalesce((v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid);
begin
  -- Exclusão LGPD em andamento: não recria auditoria do usuário apagado
  if current_setting('app.excluindo_usuario', true) = v_user::text then
    return coalesce(new, old);
  end if;
  -- UPDATE sem mudança real não gera registro
  if tg_op = 'UPDATE' and (v_new - 'atualizado_em' - 'versao') = (v_old - 'atualizado_em' - 'versao') then
    return new;
  end if;
  insert into public.auditoria (user_id, tabela, registro_id, operacao, dados_antes, dados_depois, ator_id, canal, motivo)
  values (v_user, tg_table_name, v_id, tg_op, v_old, v_new, auth.uid(), privado.canal_atual(),
          nullif(current_setting('app.motivo', true), ''));
  return coalesce(new, old);
end $$;

-- Versão incrementa a cada alteração; dono e id são imutáveis
create or replace function privado.antes_de_alterar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id then
    raise exception 'Não é permitido transferir registro para outro usuário' using errcode = '42501';
  end if;
  if new.id is distinct from old.id then
    raise exception 'Identificador é imutável' using errcode = '42501';
  end if;
  new.versao := old.versao + 1;
  new.atualizado_em := now();
  return new;
end $$;

create or replace function privado.aplicar_gatilhos_padrao(p_tabela regclass)
returns void
language plpgsql
set search_path = ''
as $$
declare v_nome text := (select relname from pg_class where oid = p_tabela);
begin
  execute format('create trigger %I before update on %s for each row execute function privado.antes_de_alterar()',
                 v_nome || '_versao', p_tabela);
  execute format('create trigger %I after insert or update or delete on %s for each row execute function privado.registrar_auditoria()',
                 v_nome || '_auditoria', p_tabela);
end $$;

-- ---------------------------------------------------------------------
-- Idempotência de comandos, vinculada ao CONTEÚDO do comando.
--  * mesma chave + mesmo conteúdo  -> devolve o resultado ORIGINAL
--  * mesma chave + conteúdo diferente (ou outra operação) -> erro SF409
-- O conteúdo é guardado como hash SHA-256 do JSON canônico dos parâmetros.
-- ---------------------------------------------------------------------
create table public.chaves_idempotencia (
  user_id        uuid not null,
  chave          text not null check (length(chave) between 8 and 200),
  operacao       text not null,
  hash_conteudo  text not null,
  resultado      jsonb,
  criado_em      timestamptz not null default now(),
  primary key (user_id, chave)
);
alter table public.chaves_idempotencia enable row level security;
-- Sem políticas: acesso somente pelas funções internas.

create or replace function privado.hash_conteudo(p_conteudo jsonb)
returns text
language sql immutable
set search_path = ''
as $$
  -- jsonb já é canônico: chaves ordenadas, sem espaços variáveis
  select encode(sha256(convert_to(coalesce(p_conteudo, 'null'::jsonb)::text, 'UTF8')), 'hex');
$$;

-- Retorna NULL quando o comando é novo (e reserva a chave), ou o
-- resultado original quando é repetição idêntica.
create or replace function privado.idempotencia_inicio(p_chave text, p_operacao text, p_conteudo jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_obrigatorio();
  v_hash text := privado.hash_conteudo(p_conteudo);
  v_reg  public.chaves_idempotencia;
begin
  if p_chave is null or length(btrim(p_chave)) < 8 then
    raise exception 'Chave de idempotência obrigatória (mínimo 8 caracteres)' using errcode = '22023';
  end if;
  insert into public.chaves_idempotencia (user_id, chave, operacao, hash_conteudo)
  values (v_uid, p_chave, p_operacao, v_hash)
  on conflict do nothing;
  if found then
    return null;
  end if;
  -- Se outra transação reservou a mesma chave, o INSERT acima esperou
  -- ela terminar; aqui já lemos o registro confirmado.
  select * into v_reg from public.chaves_idempotencia where user_id = v_uid and chave = p_chave;
  if v_reg.operacao <> p_operacao or v_reg.hash_conteudo <> v_hash then
    raise exception 'Chave de idempotência já usada com outro conteúdo ou operação (%)', v_reg.operacao
      using errcode = 'SF409';
  end if;
  if v_reg.resultado is null then
    raise exception 'Comando anterior com esta chave não registrou resultado' using errcode = 'SF409';
  end if;
  return v_reg.resultado;
end $$;

create or replace function privado.idempotencia_fim(p_chave text, p_resultado jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if p_chave is null then return; end if;
  update public.chaves_idempotencia set resultado = p_resultado
   where user_id = privado.uid_obrigatorio() and chave = p_chave and resultado is null;
end $$;

-- ---------------------------------------------------------------------
-- Consumo por usuário (mensagens, documentos, IA)
-- ---------------------------------------------------------------------
create table public.uso_eventos (
  id                      bigint generated always as identity primary key,
  user_id                 uuid not null,
  tipo                    text not null check (tipo in ('mensagem_whatsapp','documento','ia_tokens','erro')),
  quantidade              bigint not null default 1 check (quantidade >= 0),
  custo_estimado_centavos bigint not null default 0 check (custo_estimado_centavos >= 0),
  detalhe                 jsonb,
  criado_em               timestamptz not null default now()
);
create index uso_eventos_user_idx on public.uso_eventos (user_id, tipo, criado_em desc);
alter table public.uso_eventos enable row level security;
create policy uso_eventos_select_proprio on public.uso_eventos
  for select to authenticated using (user_id = auth.uid());
grant select on public.uso_eventos to authenticated;

create table public.limites_uso (
  user_id                uuid primary key,
  mensagens_mes          integer not null default 300  check (mensagens_mes >= 0),
  documentos_mes         integer not null default 60   check (documentos_mes >= 0),
  custo_ia_mes_centavos  bigint  not null default 2000 check (custo_ia_mes_centavos >= 0),
  atualizado_em          timestamptz not null default now()
);
alter table public.limites_uso enable row level security;
create policy limites_uso_select_proprio on public.limites_uso
  for select to authenticated using (user_id = auth.uid());
grant select on public.limites_uso to authenticated;

-- ---------------------------------------------------------------------
-- Solicitações de exclusão de conta (LGPD). Sem chave estrangeira para
-- auth.users: o registro sobrevive à exclusão como comprovante, sem
-- dados pessoais além do identificador técnico.
-- ---------------------------------------------------------------------
create table public.exclusoes_conta (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  status              text not null default 'solicitada'
                      check (status in ('solicitada','falha','concluida')),
  tentativas          integer not null default 1,
  arquivos_removidos  integer not null default 0,
  ultimo_erro         text,
  solicitada_em       timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  concluida_em        timestamptz
);
create unique index exclusoes_conta_uma_ativa on public.exclusoes_conta (user_id) where status <> 'concluida';
alter table public.exclusoes_conta enable row level security;
create policy exclusoes_select_proprio on public.exclusoes_conta
  for select to authenticated using (user_id = auth.uid());
grant select on public.exclusoes_conta to authenticated;

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
