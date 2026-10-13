-- =====================================================================
-- Simplifica Finanças v2 — 0012 Etapa 5 (parte 5): mais leitores de fatura
--
-- Migração ADICIONAL sobre a 0011 (etapa "5.4-valor-parcela"). Não apaga
-- nem recria nada. Tudo numa única transação.
--
-- O QUE MUDA
--   * Nova instituição "Riachuelo (Midway)", para cadastrar o Cartão
--     Riachuelo (não tem código de banco).
--   * Registra os leitores de FATURA em PDF feitos e conferidos com
--     arquivos REAIS: Santander, Mercado Pago, Sicredi, Sicoob e
--     Riachuelo (além de Nubank e Itaú, da 0010). A leitura acontece no
--     navegador; a importação usa as mesmas funções da 0010.
-- =====================================================================
begin;

do $guarda$
begin
  if to_regclass('public.versao_esquema') is null
     or not exists (select 1 from public.versao_esquema where sistema = 'simplifica-v2' and etapa = '5.4-valor-parcela') then
    raise exception 'ABORTADO: este banco não está na Etapa 5 parte 4 (0011) do Simplifica v2. Nada foi alterado.';
  end if;
end $guarda$;

insert into public.instituicoes (codigo_compe, nome) values (null, 'Riachuelo (Midway)')
on conflict (nome) do nothing;

update public.instituicoes
   set leitor_status = 'homologado',
       formatos_homologados = (select array(select distinct unnest(formatos_homologados || array['pdf-fatura']) order by 1))
 where codigo_compe in ('033', '323', '748', '756') or nome = 'Riachuelo (Midway)';

update public.versao_esquema set etapa = '5.5-leitores-faturas', aplicado_em = now() where sistema = 'simplifica-v2';
commit;
