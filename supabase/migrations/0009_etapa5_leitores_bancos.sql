-- =====================================================================
-- Simplifica Finanças v2 — 0009 Etapa 5 (parte 2): leitores por banco
--
-- Migração ADICIONAL sobre a 0008 (etapa "5.1-importacao-extratos").
-- Não apaga nem recria nada. Tudo numa única transação.
--
-- O QUE MUDA
--   * Importação aceita o formato 'pdf' (a leitura do PDF acontece no
--     navegador; o banco recebe os lançamentos lidos, como no OFX/CSV,
--     e o PDF original fica guardado no Storage).
--   * Registra os leitores feitos e conferidos com arquivos REAIS:
--       Nubank — extrato da conta em CSV  ('csv-extrato')
--       Itaú   — extrato da conta em PDF  ('pdf-extrato'), com conferência
--                dia a dia pelo "SALDO DO DIA" do próprio extrato
--     Os demais bancos continuam sem leitor homologado.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '5.1-importacao-extratos') then
    raise exception 'ABORTADO: este banco não está na Etapa 5 parte 1 (0008) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

-- formato: ofx, csv e agora pdf
do $formato$
declare
  v_nome text;
begin
  for v_nome in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.importacoes'::regclass and c.contype = 'c'
       and pg_get_constraintdef(c.oid) ilike '%formato%'
  loop
    execute format('alter table public.importacoes drop constraint %I', v_nome);
  end loop;
end $formato$;
alter table public.importacoes add constraint importacoes_formato_check check (formato in ('ofx', 'csv', 'pdf'));

-- leitores homologados com arquivo real
update public.instituicoes
   set leitor_status = 'homologado',
       formatos_homologados = (select array(select distinct unnest(formatos_homologados || array['csv-extrato']) order by 1))
 where codigo_compe = '260';
update public.instituicoes
   set leitor_status = 'homologado',
       formatos_homologados = (select array(select distinct unnest(formatos_homologados || array['pdf-extrato']) order by 1))
 where codigo_compe = '341';

update public.versao_esquema set etapa = '5.2-leitores-bancos', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
