-- =====================================================================
-- Simplifica Finanças v2 — LIMPEZA da primeira entrega da Etapa 1
--
-- Use SOMENTE se você já rodou, no projeto NOVO simplifica-v2, os scripts
-- da entrega anterior (simplifica-v2-etapa1.zip). Caso contrário, ignore.
--
-- Proteções:
--  * só roda se encontrar a estrutura exata da entrega anterior;
--  * recusa rodar se existir QUALQUER usuário cadastrado (apague antes os
--    usuários de teste em Authentication → Users);
--  * recusa rodar se encontrar a versão nova já instalada.
-- O bucket "documentos" é mantido (a versão nova reaproveita).
-- =====================================================================
do $$
begin
  if to_regnamespace('privado') is null
     or to_regclass('public.contas') is null
     or to_regclass('public.auditoria') is null
     or to_regclass('public.chaves_idempotencia') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'contas' and column_name = 'saldo_inicial_centavos') then
    raise exception 'ABORTADO: não encontrei a estrutura da entrega anterior do Simplifica v2. Nada foi alterado.';
  end if;
  if to_regclass('public.versao_esquema') is not null then
    raise exception 'ABORTADO: a versão nova já está instalada neste banco. Nada foi alterado.';
  end if;
  if exists (select 1 from auth.users) then
    raise exception 'ABORTADO: existem usuários cadastrados. Apague os usuários de teste em Authentication → Users e rode de novo. Nada foi alterado.';
  end if;

  drop trigger if exists ao_criar_usuario on auth.users;
  drop policy if exists documentos_select_proprio on storage.objects;
  drop policy if exists documentos_insert_proprio on storage.objects;
  drop function if exists public.conta_salvar(uuid, uuid, text, text, bigint, date, text, text, boolean, boolean, uuid, integer, text);
  drop function if exists public.conta_definir_ativa(uuid, boolean, text);
  drop function if exists public.exportar_meus_dados();
  drop function if exists public.excluir_minha_conta(text);
  drop table if exists public.contas, public.categorias, public.titulares, public.perfis, public.instituicoes,
                       public.auditoria, public.chaves_idempotencia, public.uso_eventos, public.limites_uso;
  drop schema privado cascade;
  raise notice 'Limpeza concluída. Agora rode 0001, 0002 e 0003 da versão nova.';
end $$;
