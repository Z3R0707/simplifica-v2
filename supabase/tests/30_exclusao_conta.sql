-- Exclusão de conta (LGPD) sem arquivos órfãos — parte executada no banco.
-- A remoção física dos arquivos é feita pela API do Storage (Edge Function);
-- aqui ela é simulada removendo as linhas de storage.objects como o Storage faz.
\set QUIET on
\o /dev/null
insert into teste.ids values ('davi', teste.novo_usuario('Davi.Lima@Exemplo.com', 'Davi'));
insert into storage.buckets (id, name, public) values ('outro-bucket', 'outro-bucket', false);
select teste.como(teste.id('davi'));
insert into teste.ids select 'titular_davi', id from public.titulares where principal;
select public.conta_criar(teste.id('titular_davi'), (select id from public.instituicoes where nome = 'Nubank'),
  'Nubank', 'pagamento', 120000, '2026-10-01', null, null, true, true, 'davi-conta-0001');
insert into storage.objects (bucket_id, name) values
  ('documentos', teste.id('davi')::text || '/extrato.ofx'),
  ('documentos', teste.id('davi')::text || '/faturas/2026/09.pdf');
reset role;
-- arquivo do Davi em outro bucket (criado pelo servidor): também precisa sumir
insert into storage.objects (bucket_id, name) values ('outro-bucket', teste.id('davi')::text || '/anexo.png');
select teste.como(teste.id('davi'));
\o

-- ----------------------------------------------- confirmação: NULL, vazio, divergente
select teste.erro($q$ select public.exclusao_solicitar(null) $q$, '22023', 'confirmação NULL é rejeitada');
select teste.erro($q$ select public.exclusao_solicitar('') $q$, '22023', 'confirmação vazia é rejeitada');
select teste.erro($q$ select public.exclusao_solicitar('   ') $q$, '22023', 'confirmação só com espaços é rejeitada');
select teste.erro($q$ select public.exclusao_solicitar('davi@exemplo.co') $q$, '22023', 'e-mail divergente é rejeitado');
select teste.erro($q$ select public.exclusao_solicitar('ana@exemplo.com') $q$, '22023', 'e-mail de outro usuário é rejeitado');
select teste.igual((select count(*) from public.exclusoes_conta)::int, 0, 'nenhuma solicitação criada pelas tentativas inválidas');
select teste.igual((select count(*) from public.contas)::int, 1, 'dados intactos após tentativas inválidas');

-- -------------------------------------------------------- solicitação válida
select teste.igual((public.exclusao_solicitar('  davi.lima@exemplo.COM ')).status, 'solicitada', 'e-mail correto (sem diferenciar maiúsculas/espaços) registra a solicitação');
select teste.igual((public.exclusao_solicitar('davi.lima@exemplo.com')).tentativas, 2, 'nova solicitação reaproveita a ativa (sem duplicar)');
select teste.igual((select count(*) from public.exclusoes_conta)::int, 1, 'apenas uma solicitação ativa');

-- a partir daqui o usuário fica bloqueado para escrita e envio de arquivos
select teste.erro(format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/novo.pdf') $q$, teste.id('davi')), '42501', 'envio de arquivo bloqueado durante a exclusão');
select teste.erro($q$ select public.titular_criar('Novo', 'davi-titular-001') $q$, '42501', 'criação de dados bloqueada durante a exclusão');
select teste.erro($q$ select public.perfil_atualizar(1, 'Outro') $q$, '42501', 'alteração de dados bloqueada durante a exclusão');
select teste.igual(jsonb_array_length(public.exportar_meus_dados()->'documentos'), 2, 'exportação ainda funciona (2 documentos)');

-- funções do servidor não são acessíveis ao usuário
select teste.erro(format($q$ select public.exclusao_concluir('%s') $q$, teste.id('davi')), '42501', 'usuário não executa exclusao_concluir');
select teste.erro(format($q$ select * from public.exclusao_listar_arquivos('%s') $q$, teste.id('ana')), '42501', 'usuário não lista arquivos de ninguém');
select teste.erro($q$ select * from public.storage_listar_orfaos() $q$, '42501', 'usuário não lista órfãos');

-- ============================================================ como SERVIDOR
reset role;
set role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false) \g /dev/null
select set_config('request.jwt.claim.sub', '', false) \g /dev/null

select teste.igual((select count(*) from public.exclusao_listar_arquivos(teste.id('davi')))::int, 3, 'lista os 3 arquivos do usuário (inclui subpasta e outro bucket)');
select teste.erro(format($q$ select public.exclusao_concluir('%s') $q$, teste.id('davi')), 'SF410', 'conclusão RECUSADA enquanto restarem arquivos');
select teste.igual((select count(*) from auth.users where id = teste.id('davi'))::int, 1, 'login preservado após recusa');
select teste.igual((select count(*) from public.contas where user_id = teste.id('davi'))::int, 1, 'dados preservados após recusa');

-- falha parcial: remove só 1 arquivo e registra a falha (ex.: queda de rede)
reset role;
delete from storage.objects where name = teste.id('davi')::text || '/extrato.ofx';
set role service_role;
select public.exclusao_registrar_falha(teste.id('davi'), 'simulação: rede caiu', 1) \g /dev/null
select teste.igual((select status from public.exclusoes_conta where user_id = teste.id('davi')), 'falha', 'falha registrada para retomada');
select teste.erro(format($q$ select public.exclusao_concluir('%s') $q$, teste.id('davi')), 'SF410', 'ainda recusa com 2 arquivos restantes');

-- retomada pelo usuário: volta para "solicitada" e continua bloqueado
reset role;
\o /dev/null
select teste.como(teste.id('davi'));
\o
select teste.igual((public.exclusao_solicitar('davi.lima@exemplo.com')).status, 'solicitada', 'usuário pode retomar a exclusão após falha');
select teste.erro(format($q$ insert into storage.objects (bucket_id, name) values ('documentos', '%s/x.pdf') $q$, teste.id('davi')), '42501', 'continua bloqueado durante a retomada');

-- Storage remove os arquivos restantes
reset role;
delete from storage.objects where (string_to_array(name, '/'))[1] = teste.id('davi')::text;
set role service_role;
select teste.igual((public.exclusao_concluir(teste.id('davi'), 2)).status, 'concluida', 'conclusão aceita quando não resta nenhum arquivo');
reset role;
select teste.igual((select count(*) from auth.users where id = teste.id('davi'))::int, 0, 'login removido');
select teste.igual((select count(*) from public.perfis where id = teste.id('davi'))
                 + (select count(*) from public.titulares where user_id = teste.id('davi'))
                 + (select count(*) from public.contas where user_id = teste.id('davi'))
                 + (select count(*) from public.categorias where user_id = teste.id('davi'))
                 + (select count(*) from public.limites_uso where user_id = teste.id('davi'))
                 + (select count(*) from public.chaves_idempotencia where user_id = teste.id('davi')), 0::bigint, 'todos os dados do usuário removidos');
select teste.igual((select count(*) from public.auditoria where user_id = teste.id('davi'))::int, 0, 'auditoria do usuário removida (sem recriar registros)');
select teste.igual((select count(*) from storage.objects where name like teste.id('davi')::text || '/%')::int, 0, 'nenhum arquivo órfão do usuário');
select teste.igual((select arquivos_removidos from public.exclusoes_conta where user_id = teste.id('davi')), 3, 'comprovante registra 3 arquivos removidos');
set role service_role;
select teste.erro(format($q$ select public.exclusao_concluir('%s') $q$, teste.id('davi')), 'P0002', 'concluir de novo não tem efeito');
select teste.erro(format($q$ select public.exclusao_concluir('%s') $q$, teste.id('ana')), 'P0002', 'não conclui exclusão sem solicitação do próprio usuário');
reset role;
select teste.igual((select count(*) from public.contas where user_id = teste.id('ana'))::int, 2, 'dados de outros usuários intactos');
select teste.igual((select count(*) from storage.objects where name like teste.id('ana')::text || '/%')::int, 1, 'arquivos de outros usuários intactos');

-- ---------------------------------------------------------------- órfãos
insert into storage.objects (bucket_id, name) values ('documentos', '00000000-0000-0000-0000-00000000dead/perdido.pdf');
set role service_role;
select teste.igual((select array_agg(nome) from public.storage_listar_orfaos()), array['00000000-0000-0000-0000-00000000dead/perdido.pdf'], 'varredura encontra só o arquivo órfão');
reset role;
\echo '== 30_exclusao_conta: concluído =='
