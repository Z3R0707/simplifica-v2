-- =====================================================================
-- Simplifica Finanças v2 — 0002 Fundação: cadastros base
-- Perfis, instituições, titulares, contas e categorias.
--
-- Regra geral de escrita: usuários NÃO alteram tabelas diretamente.
-- Toda criação passa por RPC com chave de idempotência obrigatória e
-- toda alteração passa por RPC com versão esperada obrigatória.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Perfil (1:1 com auth.users), com versão e auditoria
-- ---------------------------------------------------------------------
create table public.perfis (
  id             uuid primary key references auth.users (id) on delete cascade,
  user_id        uuid not null check (user_id = id),
  nome           text not null default '' check (length(nome) <= 120),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  versao         integer not null default 1
);
alter table public.perfis enable row level security;
create policy perfis_select on public.perfis for select to authenticated using (user_id = auth.uid());
grant select on public.perfis to authenticated;
select privado.aplicar_gatilhos_padrao('public.perfis');

-- ---------------------------------------------------------------------
-- Instituições: catálogo global, somente leitura.
-- leitor_status só muda para 'homologado' após validação com arquivos
-- reais. Nenhuma instituição começa homologada.
-- ---------------------------------------------------------------------
create table public.instituicoes (
  id                    uuid primary key default gen_random_uuid(),
  codigo_compe          text unique,
  nome                  text not null unique,
  leitor_status         text not null default 'nao_implementado'
                        check (leitor_status in ('nao_implementado','em_desenvolvimento','homologado')),
  formatos_homologados  text[] not null default '{}',
  criado_em             timestamptz not null default now()
);
alter table public.instituicoes enable row level security;
create policy instituicoes_select on public.instituicoes for select to authenticated using (true);
grant select on public.instituicoes to authenticated;

insert into public.instituicoes (codigo_compe, nome) values
  ('033', 'Santander'), ('341', 'Itaú'), ('756', 'Sicoob'),
  ('260', 'Nubank'), ('323', 'Mercado Pago'), ('748', 'Sicredi'),
  (null,  'Outra instituição');

-- ---------------------------------------------------------------------
-- Titulares (pessoas donas das contas, dentro do mesmo usuário)
-- ---------------------------------------------------------------------
create table public.titulares (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  nome           text not null check (length(btrim(nome)) between 1 and 120),
  principal      boolean not null default false,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  versao         integer not null default 1,
  unique (id, user_id),
  check (ativo or not principal)          -- principal nunca é arquivado
);
create unique index titulares_um_principal on public.titulares (user_id) where principal;
create unique index titulares_nome_unico on public.titulares (user_id, lower(btrim(nome)));
alter table public.titulares enable row level security;
create policy titulares_select on public.titulares for select to authenticated using (user_id = auth.uid());
grant select on public.titulares to authenticated;
select privado.aplicar_gatilhos_padrao('public.titulares');

-- ---------------------------------------------------------------------
-- Contas bancárias: cada conta é independente, mesmo no mesmo banco.
-- ---------------------------------------------------------------------
create table public.contas (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references auth.users (id) on delete cascade,
  titular_id              uuid not null,
  instituicao_id          uuid not null references public.instituicoes (id),
  apelido                 text not null check (length(btrim(apelido)) between 1 and 80),
  tipo                    text not null check (tipo in ('corrente','poupanca','pagamento','investimento')),
  agencia                 text check (agencia ~ '^[0-9A-Za-z-]{1,10}$'),
  numero                  text check (numero  ~ '^[0-9A-Za-z-]{1,20}$'),
  saldo_inicial_centavos  bigint not null default 0,
  saldo_inicial_data      date not null,
  saldo_inicial_validado  boolean not null default false,
  incluir_consolidado     boolean not null default true,
  ativa                   boolean not null default true,
  criado_em               timestamptz not null default now(),
  atualizado_em           timestamptz not null default now(),
  versao                  integer not null default 1,
  unique (id, user_id),
  -- o titular precisa ser do MESMO usuário
  foreign key (titular_id, user_id) references public.titulares (id, user_id)
);
create unique index contas_apelido_unico on public.contas (user_id, lower(btrim(apelido)));
create unique index contas_identificacao_unica on public.contas (user_id, instituicao_id, agencia, numero)
  where agencia is not null and numero is not null;
alter table public.contas enable row level security;
create policy contas_select on public.contas for select to authenticated using (user_id = auth.uid());
grant select on public.contas to authenticated;
select privado.aplicar_gatilhos_padrao('public.contas');

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

-- ---------------------------------------------------------------------
-- Categorias (por usuário; hierarquia de um nível)
-- ---------------------------------------------------------------------
create table public.categorias (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  nome           text not null check (length(btrim(nome)) between 1 and 60),
  tipo           text not null check (tipo in ('receita','despesa')),
  pai_id         uuid,
  cor            text check (cor ~ '^#[0-9a-fA-F]{6}$'),
  ativa          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  versao         integer not null default 1,
  unique (id, user_id),
  foreign key (pai_id, user_id) references public.categorias (id, user_id)
);
create unique index categorias_nome_unico on public.categorias
  (user_id, tipo, coalesce(pai_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(nome)));
alter table public.categorias enable row level security;
create policy categorias_select on public.categorias for select to authenticated using (user_id = auth.uid());
grant select on public.categorias to authenticated;

create or replace function privado.categoria_validar_pai()
returns trigger language plpgsql set search_path = '' as $$
declare v_pai record;
begin
  if new.pai_id is not null then
    select tipo, pai_id into v_pai from public.categorias where id = new.pai_id and user_id = new.user_id;
    if v_pai.pai_id is not null then
      raise exception 'Subcategorias permitem apenas um nível' using errcode = '22023';
    end if;
    if v_pai.tipo <> new.tipo then
      raise exception 'Subcategoria deve ter o mesmo tipo da categoria-pai' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger categorias_validar_pai before insert or update on public.categorias
  for each row execute function privado.categoria_validar_pai();
select privado.aplicar_gatilhos_padrao('public.categorias');

-- ---------------------------------------------------------------------
-- Novo usuário: perfil, titular principal, limites e categorias padrão
-- ---------------------------------------------------------------------
create or replace function privado.ao_criar_usuario()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_nome text := left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''),
                                     nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Titular'), 120);
begin
  perform set_config('app.canal', 'cadastro', true);
  insert into public.perfis (id, user_id, nome) values (new.id, new.id, v_nome);
  insert into public.titulares (user_id, nome, principal) values (new.id, v_nome, true);
  insert into public.limites_uso (user_id) values (new.id);
  insert into public.categorias (user_id, nome, tipo)
  select new.id, c.nome, c.tipo
    from (values
      ('Salário','receita'), ('Rendimentos','receita'), ('Reembolsos','receita'), ('Outras receitas','receita'),
      ('Moradia','despesa'), ('Alimentação','despesa'), ('Transporte','despesa'), ('Saúde','despesa'),
      ('Educação','despesa'), ('Lazer','despesa'), ('Compras','despesa'), ('Serviços e assinaturas','despesa'),
      ('Impostos e taxas','despesa'), ('Tarifas bancárias','despesa'), ('Juros e encargos','despesa'),
      ('Outras despesas','despesa')
    ) as c(nome, tipo);
  perform set_config('app.canal', '', true);
  return new;
end $$;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function privado.ao_criar_usuario();

-- =====================================================================
-- RPCs — únicas portas de escrita
-- Padrão:
--   *_criar(..., p_chave_idempotencia)          chave obrigatória
--   *_atualizar(p_id, p_versao_esperada, ...)   versão obrigatória;
--                                                chave opcional
-- =====================================================================

-- ------------------------------------------------------------- perfil
create or replace function public.perfil_atualizar(
  p_versao_esperada     integer,
  p_nome                text,
  p_chave_idempotencia  text default null
)
returns public.perfis
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.perfis;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'perfil_atualizar',
                jsonb_build_object('versao', p_versao_esperada, 'nome', p_nome));
    if v_prev is not null then return jsonb_populate_record(null::public.perfis, v_prev); end if;
  end if;
  update public.perfis set nome = btrim(coalesce(p_nome, ''))
   where id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.perfis', v_uid, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- ----------------------------------------------------------- titulares
create or replace function public.titular_criar(p_nome text, p_chave_idempotencia text)
returns public.titulares
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.titulares;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'titular_criar', jsonb_build_object('nome', p_nome));
  if v_prev is not null then return jsonb_populate_record(null::public.titulares, v_prev); end if;
  insert into public.titulares (user_id, nome) values (v_uid, btrim(p_nome)) returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
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

-- -------------------------------------------------------------- contas
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

-- Arquiva/reativa (contas não são excluídas: preservam histórico)
create or replace function public.conta_definir_ativa(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_ativa               boolean,
  p_motivo              text default null,
  p_chave_idempotencia  text default null
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
  if p_ativa is null then raise exception 'Informe se a conta fica ativa' using errcode = '22023'; end if;
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'conta_definir_ativa',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'ativa', p_ativa, 'motivo', p_motivo));
    if v_prev is not null then return jsonb_populate_record(null::public.contas, v_prev); end if;
  end if;
  perform set_config('app.motivo', coalesce(p_motivo, ''), true);
  update public.contas set ativa = p_ativa
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.contas', p_id, v_uid); end if;
  perform set_config('app.motivo', '', true);
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

-- ---------------------------------------------------------- categorias
create or replace function public.categoria_criar(
  p_nome                text,
  p_tipo                text,
  p_pai_id              uuid,
  p_cor                 text,
  p_chave_idempotencia  text
)
returns public.categorias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.categorias;
begin
  v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'categoria_criar',
              jsonb_build_object('nome', p_nome, 'tipo', p_tipo, 'pai_id', p_pai_id, 'cor', p_cor));
  if v_prev is not null then return jsonb_populate_record(null::public.categorias, v_prev); end if;
  if p_pai_id is not null and not exists (select 1 from public.categorias where id = p_pai_id and user_id = v_uid) then
    raise exception 'Categoria-pai não encontrada' using errcode = 'P0002';
  end if;
  insert into public.categorias (user_id, nome, tipo, pai_id, cor)
  values (v_uid, btrim(p_nome), p_tipo, p_pai_id, p_cor)
  returning * into v_reg;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;

create or replace function public.categoria_atualizar(
  p_id                  uuid,
  p_versao_esperada     integer,
  p_nome                text,
  p_cor                 text,
  p_ativa               boolean,
  p_chave_idempotencia  text default null
)
returns public.categorias
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid  uuid := privado.uid_para_escrita();
  v_prev jsonb;
  v_reg  public.categorias;
begin
  perform privado.exigir_versao(p_versao_esperada);
  if p_chave_idempotencia is not null then
    v_prev := privado.idempotencia_inicio(p_chave_idempotencia, 'categoria_atualizar',
                jsonb_build_object('id', p_id, 'versao', p_versao_esperada, 'nome', p_nome, 'cor', p_cor, 'ativa', p_ativa));
    if v_prev is not null then return jsonb_populate_record(null::public.categorias, v_prev); end if;
  end if;
  update public.categorias set nome = btrim(p_nome), cor = p_cor, ativa = coalesce(p_ativa, ativa)
   where id = p_id and user_id = v_uid and versao = p_versao_esperada
  returning * into v_reg;
  if not found then perform privado.falha_alteracao('public.categorias', p_id, v_uid); end if;
  perform privado.idempotencia_fim(p_chave_idempotencia, to_jsonb(v_reg));
  return v_reg;
end $$;
