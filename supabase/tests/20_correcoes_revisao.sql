-- Correções pedidas na revisão da Etapa 1:
--  (a) versão esperada obrigatória em toda alteração
--  (b) idempotência vinculada ao conteúdo, preservando o resultado original
--  (c) perfil com versão e auditoria
\set QUIET on
\o /dev/null
insert into teste.ids values ('clara', teste.novo_usuario('clara@exemplo.com', 'Clara'));
select teste.como(teste.id('clara'));
insert into teste.ids select 'titular_clara', id from public.titulares where principal;
insert into teste.ids select 'itau', id from public.instituicoes where nome = 'Itaú';
insert into teste.ids select 'conta_c', (public.conta_criar(teste.id('titular_clara'), teste.id('itau'),
  'Itaú corrente', 'corrente', 280000, '2026-10-01', null, null, true, true, 'clara-conta-0001')).id;
insert into teste.ids select 'cat_c', id from public.categorias where nome = 'Lazer';
\o

-- ------------------------------------------------------------ (a) versão obrigatória
select teste.erro($q$ select public.conta_atualizar(teste.id('conta_c'), null, teste.id('titular_clara'), teste.id('itau'), 'X', 'corrente', 0, '2026-10-01', null, null, false, true) $q$,
  '22023', 'conta_atualizar sem versão é recusada');
select teste.erro($q$ select public.conta_definir_ativa(teste.id('conta_c'), null, false) $q$, '22023', 'conta_definir_ativa sem versão é recusada');
select teste.erro($q$ select public.titular_atualizar(teste.id('titular_clara'), null, 'Clara', true) $q$, '22023', 'titular_atualizar sem versão é recusada');
select teste.erro($q$ select public.categoria_atualizar(teste.id('cat_c'), null, 'Lazer', null, true) $q$, '22023', 'categoria_atualizar sem versão é recusada');
select teste.erro($q$ select public.perfil_atualizar(null, 'Clara') $q$, '22023', 'perfil_atualizar sem versão é recusada');
select teste.erro($q$ select public.perfil_atualizar(0, 'Clara') $q$, '22023', 'versão zero é recusada');
select teste.igual((select count(*) from public.contas where id = teste.id('conta_c') and versao = 1 and apelido = 'Itaú corrente')::int, 1, 'nada foi alterado pelas tentativas sem versão');

select teste.igual((public.conta_atualizar(teste.id('conta_c'), 1, teste.id('titular_clara'), teste.id('itau'),
  'Itaú principal', 'corrente', 280000, '2026-10-01', null, null, true, true)).versao, 2, 'alteração com versão correta aplica e incrementa');
select teste.erro($q$ select public.conta_atualizar(teste.id('conta_c'), 1, teste.id('titular_clara'), teste.id('itau'), 'Edição atrasada', 'corrente', 1, '2026-10-01', null, null, false, true) $q$,
  '40001', 'versão antiga (outro canal alterou antes) é recusada');
select teste.erro($q$ select public.conta_definir_ativa(teste.id('conta_c'), 1, false) $q$, '40001', 'arquivar com versão antiga é recusado');
select teste.igual((select apelido from public.contas where id = teste.id('conta_c')), 'Itaú principal', 'valor vigente preservado após conflito');

-- --------------------------------------------- (b) idempotência ligada ao conteúdo
\o /dev/null
create temp table orig as select * from public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'clara-cat-viagens');
\o
select teste.igual((select nome from public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'clara-cat-viagens')), 'Viagens', 'repetição idêntica é aceita');
select teste.igual((select id from public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'clara-cat-viagens')), (select id from orig), 'repetição idêntica devolve o MESMO registro');
select teste.igual((select count(*) from public.categorias where nome = 'Viagens')::int, 1, 'repetição idêntica não duplica');
select teste.erro($q$ select public.categoria_criar('Viagens', 'despesa', null, '#000000', 'clara-cat-viagens') $q$, 'SF409', 'mesma chave com cor diferente é recusada');
select teste.erro($q$ select public.categoria_criar('Férias', 'despesa', null, '#aa5500', 'clara-cat-viagens') $q$, 'SF409', 'mesma chave com nome diferente é recusada');
select teste.erro($q$ select public.titular_criar('Viagens', 'clara-cat-viagens') $q$, 'SF409', 'mesma chave em outra operação é recusada');
select teste.erro($q$ select public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'curta') $q$, '22023', 'chave curta demais é recusada');

-- resultado original preservado mesmo depois de o registro mudar
\o /dev/null
select public.categoria_atualizar((select id from orig), 1, 'Viagens e passeios', '#aa5500', true);
\o
select teste.igual((select nome from public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'clara-cat-viagens')), 'Viagens', 'repetição devolve o resultado ORIGINAL (não o estado atual)');
select teste.igual((select versao from public.categoria_criar('Viagens', 'despesa', null, '#aa5500', 'clara-cat-viagens')), 1, 'resultado original mantém a versão original');
select teste.igual((select nome from public.categorias where id = (select id from orig)), 'Viagens e passeios', 'repetição não desfaz a alteração posterior');

-- alterações com chave: repetição devolve o resultado, sem conflito de versão
\o /dev/null
create temp table upd as select * from public.conta_atualizar(teste.id('conta_c'), 2, teste.id('titular_clara'), teste.id('itau'),
  'Itaú salário', 'corrente', 280000, '2026-10-01', null, null, true, true, 'clara-upd-conta-01');
\o
select teste.igual((select versao from public.conta_atualizar(teste.id('conta_c'), 2, teste.id('titular_clara'), teste.id('itau'),
  'Itaú salário', 'corrente', 280000, '2026-10-01', null, null, true, true, 'clara-upd-conta-01')), 3, 'reenvio de alteração devolve o resultado original');
select teste.igual((select versao from public.contas where id = teste.id('conta_c')), 3, 'reenvio de alteração não aplica duas vezes');
select teste.erro($q$ select public.conta_atualizar(teste.id('conta_c'), 2, teste.id('titular_clara'), teste.id('itau'), 'Outro nome', 'corrente', 280000, '2026-10-01', null, null, true, true, 'clara-upd-conta-01') $q$,
  'SF409', 'mesma chave de alteração com dados diferentes é recusada');

-- comando que falha não "queima" a chave
select teste.erro($q$ select public.conta_criar(teste.id('titular_clara'), teste.id('itau'), 'Itaú salário', 'corrente', 0, '2026-10-01', null, null, false, true, 'clara-conta-0002') $q$,
  '23505', 'conta com apelido repetido falha');
select teste.igual((select apelido from public.conta_criar(teste.id('titular_clara'), teste.id('itau'), 'Itaú reserva', 'corrente', 0, '2026-10-01', null, null, false, true, 'clara-conta-0003')), 'Itaú reserva', 'nova chave funciona após falha');
reset role;
select teste.igual((select count(*) from public.chaves_idempotencia where chave = 'clara-conta-0002')::int, 0, 'chave do comando que falhou não ficou reservada');
select teste.igual((select count(*) from public.chaves_idempotencia where chave = 'clara-cat-viagens' and hash_conteudo ~ '^[0-9a-f]{64}$')::int, 1, 'chave guarda hash SHA-256 do conteúdo');

-- ------------------------------------------------------------- (c) perfil
\o /dev/null
select teste.como(teste.id('clara'));
\o
select teste.igual((select versao from public.perfis), 1, 'perfil começa na versão 1');
select teste.igual((public.perfil_atualizar(1, 'Clara Mendes')).versao, 2, 'perfil: versão incrementa');
select teste.erro($q$ select public.perfil_atualizar(1, 'Clara M.') $q$, '40001', 'perfil: versão antiga recusada');
select teste.igual((select dados_antes->>'nome' || ' -> ' || (dados_depois->>'nome') from public.auditoria where tabela = 'perfis' and operacao = 'UPDATE'),
  'Clara -> Clara Mendes', 'perfil: alteração auditada com antes e depois');
select teste.igual((select count(*) from public.auditoria where tabela = 'perfis')::int, 2, 'perfil: criação e alteração auditadas');
reset role;
select teste.erro($q$ update public.perfis set user_id = teste.id('ana') where id = teste.id('clara') $q$, '42501', 'perfil não pode apontar para outro dono');
\echo '== 20_correcoes_revisao: concluído =='
