# Simplifica Finanças v2 — Etapas 1, 2 e 3

Base do novo sistema: banco, permissões, auditoria, idempotência, versão e exclusão
de conta (LGPD) sem arquivos órfãos. Tudo vai num projeto Supabase **novo e separado**.
Nada aqui toca o banco atual, o projeto `simplifica-teste` ou o site atual.

**Situação:** Etapa 1 HOMOLOGADA (12/10/2026; 74/74 no banco, 28/28 no navegador). Etapa 2 HOMOLOGADA (12/10/2026; 63/63 + regressão 74/74). Detalhes em `docs/`.

## O que mudou nesta revisão

| Ponto | Problema encontrado | Correção |
|---|---|---|
| Upload em andamento × conclusão da exclusão | Um upload cuja transação começou antes da solicitação podia confirmar **depois** da conclusão e virar arquivo órfão. | Cada usuário tem uma trava no banco. Upload e escrita de dados pegam a trava em modo compartilhado; a conclusão pega em modo exclusivo. Assim ela **espera** todo upload já iniciado terminar e só então confere se restou arquivo. Se restou, recusa, e a Edge Function apaga e tenta de novo. Se o upload demorar mais que 20 s, a conclusão desiste sem apagar nada e tenta de novo. |
| Token antigo depois da exclusão | Na revisão 2 o bloqueio valia só *durante* a exclusão. Um token ainda válido conseguia enviar arquivo depois de concluída, gerando órfão. | Upload e escrita passam a exigir usuário existente e sem nenhuma solicitação de exclusão, inclusive concluída. |
| Conferência final | — | Depois de concluir, a Edge Function procura de novo arquivos daquele usuário, remove e registra no comprovante o que encontrar. |
| Arquivar titular × criar, reativar ou alterar conta | As duas operações conferiam o estado sem travar. Em paralelo, as duas passavam e deixavam conta ativa com titular arquivado. A reativação nem conferia o titular. | Gatilhos no banco garantem a regra em qualquer caminho. Conta ativa trava o titular (`FOR SHARE`) e exige que ele esteja ativo. Arquivar o titular trava a linha e confere de novo, com leitura nova. Uma operação sempre espera a outra e a que violaria a regra é recusada. |

## Conteúdo

```
supabase/
  migrations/0001…0003                  instalação NOVA (revisão 3 completa)
  ATUALIZAR_DA_REVISAO_2_PARA_3.sql     só para quem já rodou a revisão 2
  SOMENTE_SE_JA_RODOU_A_VERSAO_ANTERIOR.sql  só para quem rodou a 1ª entrega
  functions/excluir-conta/index.ts      exclusão de conta sem órfãos
  functions/limpar-orfaos/index.ts      manutenção: acha e remove arquivos sem dono
  tests/                                testes locais (não vão para o Supabase)
    40_concorrencia.sql                 transações simultâneas reais (conexões paralelas)
validacao/
  01_validar_banco_no_supabase.sql      74 verificações no projeto real, com rollback
  02_validar_exclusao_no_navegador.html 28 verificações reais, incluindo cenários em paralelo
docs/                                   evidências de execução
```

## Instalação — escolha UM caminho

Confira no topo do painel que você está no projeto **simplifica-v2**.

**A) Projeto novo, nada rodado ainda:** SQL Editor → New query → rode, nesta ordem:
`0001_fundacao_infra.sql`, `0002_fundacao_cadastros.sql`, `0003_fundacao_lgpd_storage.sql`.

**B) Já rodou a revisão 2 neste projeto:** rode apenas
`ATUALIZAR_DA_REVISAO_2_PARA_3.sql`. Ele confere que o banco está na revisão 2 e aplica
tudo numa única transação; se algo falhar, nada muda.

**C) Já rodou a 1ª entrega (antes da revisão 2):**
1. Apague os usuários de teste.
2. Rode `SOMENTE_SE_JA_RODOU_A_VERSAO_ANTERIOR.sql`.
3. Siga o caminho A.

**Depois, em qualquer caminho:**
1. Edge Functions → Deploy a new function → Via Editor.
   - Nome `excluir-conta`: cole `functions/excluir-conta/index.ts` → Deploy. Se ela já existe, abra e substitua o código.
   - Repita com o nome `limpar-orfaos` e o arquivo `functions/limpar-orfaos/index.ts`.
   - Abra cada função → Settings → deixe **Verify JWT with legacy secret** DESLIGADO e salve (a função valida a sessão no próprio código).
   - O editor precisa ter UM único arquivo, `index.ts`; não use "Add File". Se o .ts abrir como vídeo no Windows, use Abrir com → Bloco de Notas.
2. Edge Functions → Secrets → `MANUTENCAO_SEGREDO` = frase longa e aleatória (mínimo 24 caracteres). Deixe `ORIGENS_PERMITIDAS` sem configurar por enquanto.
3. Authentication → Providers → Email: e-mail e senha ativos, **Confirm email** ligado.

## Validação no projeto real (obrigatória para homologar)

**Roteiro 1 — banco, sem gravar nada.**
1. SQL Editor → cole `validacao/01_validar_banco_no_supabase.sql` → Run.
2. O resultado aparece como mensagem de erro de propósito, porque é ela que desfaz os testes.
   - `VALIDAÇÃO APROVADA: 74 de 74` → certo.
   - Qualquer outro resultado → me envie a mensagem inteira.

**Roteiro 2 — Storage e exclusão de verdade, com operações em paralelo.**
1. Authentication → Users → Add user → crie dois usuários de teste, marcando **Auto Confirm User**.
2. Abra `validacao/02_validar_exclusao_no_navegador.html` no navegador (duplo clique).
3. Preencha:
   - a URL e a chave pública (Settings → API);
   - e-mail e senha dos dois usuários. O usuário A **será excluído**.
4. Executar validação → Copiar resultado → me envie. A página roda:
   - 10 rodadas de "arquivar titular" ao mesmo tempo que "criar conta";
   - a exclusão disparada junto com 5 uploads de 1 MB;
   - um upload com o token antigo depois da exclusão.
5. Rode as duas linhas de SQL que a página mostra no final. O resultado esperado é 0 arquivos e status `concluida`. Me envie também esse resultado.

O roteiro 2 é o único que exercita o serviço de Storage real, e é por ele que saberemos se um upload em andamento pode gravar depois da conclusão.

**Depois de aprovado (recomendado):** agende a varredura de órfãos como rede de segurança.
1. Abra Integrations → Cron.
2. Crie um job do tipo Edge Function para `limpar-orfaos`:
   - método POST;
   - cabeçalho `x-segredo-manutencao` com o segredo;
   - corpo `{"executar": true}`;
   - execução a cada hora.

## Testes locais

```
PGHOST=... PGPORT=... PGUSER=postgres ./supabase/tests/rodar_testes.sh
```
Requer PostgreSQL com a extensão `dblink`, que é usada só nos testes de concorrência, e Node 22.

---

# Etapa 2 — movimentos, receitas, despesas e saldos por conta

Migração **adicional** `supabase/migrations/0004_etapa2_movimentos_saldos.sql`. Ela roda sobre a fundação homologada, não apaga nem recria nada e se recusa a rodar fora da Etapa 1 revisão 3. Tudo acontece numa única transação.

## Regra do saldo (data-base)

- O **saldo inicial** de cada conta é o saldo **ao final do dia** da data-base, como aparece no extrato daquele dia.
- **Saldo confirmado** numa data D = saldo inicial validado + movimentos **efetivos** com data **depois** da data-base e até D.
- Movimentos com data **até a data-base (inclusive)** continuam registrados e aparecem nos relatórios por categoria, mas **não entram no saldo**, porque já fazem parte do saldo inicial. Assim nada é contado duas vezes.
- Saldo inicial **não validado**: a conta aparece com o saldo pendente e fica fora do consolidado. O consolidado avisa que está incompleto.
- **Saldo projetado** = confirmado + previstos pendentes posteriores à data-base.
- **Consolidado** = soma dos saldos confirmados das contas ativas marcadas para o total.
- Datas são consideradas no fuso de Brasília.

## O que entra

| Item | Como funciona |
|---|---|
| Movimentos | Crédito ou débito em centavos, efetivo ou previsto. Só **efetivo** altera o saldo. Efetivo não pode ter data futura; previsto precisa ser posterior à data-base. |
| Receitas e despesas | Classificação + categoria do mesmo tipo. Estorno (crédito classificado como despesa) reduz a despesa. |
| Escrita | Só por RPC: `movimento_criar` (chave de idempotência obrigatória), `movimento_atualizar`, `movimento_efetivar`, `movimento_cancelar` (versão obrigatória; cancelamento exige motivo e nada é apagado). |
| Leitura | `saldos_por_conta(data)` (painel), `saldo_consolidado(data)`, `extrato_conta(conta)`, `resumo_categorias(início, fim)`. |
| Concorrência | Lançar trava a conta em modo compartilhado. Arquivar a conta ou mudar a data-base espera os lançamentos em andamento, e vice-versa. |
| LGPD | A exportação inclui os movimentos; a exclusão de conta apaga os movimentos antes das contas. |

## Instalação (projeto simplifica-v2, já com a Etapa 1 homologada)

1. SQL Editor → New query → cole `0004_etapa2_movimentos_saldos.sql` → Run.
2. Validação: cole `validacao/03_validar_etapa2_no_supabase.sql` → Run. O esperado é `VALIDAÇÃO APROVADA: 63 de 63`, com rollback automático, sem gravar nada.
3. Regressão: rode de novo `validacao/01_validar_banco_no_supabase.sql`. O esperado é `74 de 74`.

# Etapa 3 — contas a pagar, recorrências e pagamentos parciais

Migração **adicional** `supabase/migrations/0006_etapa3_contas_a_pagar.sql`. Roda sobre a 0005 (cancelamento parcial), não apaga nem recria nada e se recusa a rodar em qualquer outro estado. Tudo numa única transação. As consultas de saldo da Etapa 2 não mudam.

## Regras

- **Conta a pagar não mexe no saldo.** O saldo muda quando o pagamento é registrado.
- **Pagar** cria a saída na conta escolhida, como despesa na categoria da conta a pagar, e liga a saída à conta a pagar. Não é preciso (nem se deve) lançar a despesa de novo.
- **Já lancei a saída** (débito automático, Pix lançado antes, futura importação): o pagamento só *vincula* a saída existente; nada é lançado de novo.
- **Pagamento parcial**: uma conta pode ter vários pagamentos; um lançamento pode pagar várias contas.
  - abatido = valor pago − juros − multa + desconto;
  - falta pagar = valor da conta − abatido dos pagamentos ativos;
  - a conta só fica **paga** quando falta zero; vencer não a torna paga.
- **Proteções no banco**: o abatido nunca passa do valor da conta; o que um lançamento paga nunca passa do valor dele (descontados cancelamentos parciais); lançamento que paga conta não pode ser cancelado, mudar de sentido nem ficar menor que o usado; conta com pagamento não pode ser cancelada nem ficar menor que o pago. Para mudar, **desfaz-se o pagamento** (com motivo, auditado); quem criou a saída pode cancelá-la junto.
- **Recorrências** (aluguel, escola, parcelas): cada mês vira uma conta a pagar própria, ajustável sozinha. Os meses são criados até o mês seguinte ao atual, e quando você navega até eles (no máximo 24 meses à frente). Dia 31 vira o último dia em meses mais curtos. Parcelas podem ser numeradas (1/10, 2/10…). Encerrar cancela os meses seguintes ainda sem pagamento, sem apagar; repetir sem fim reabre esses meses.
- Operações simultâneas (web × WhatsApp, duas abas) ficam em fila: travas sempre na ordem conta a pagar → lançamento.

## Escrita e leitura

| Item | Funções |
|---|---|
| Contas a pagar | `obrigacao_criar` (chave obrigatória), `obrigacao_atualizar`, `obrigacao_cancelar` (motivo), `obrigacao_reabrir` |
| Pagamentos | `obrigacao_pagar`, `obrigacao_vincular_movimento` (chave obrigatória), `pagamento_desfazer` (motivo; versão obrigatória) |
| Recorrências | `recorrencia_criar`, `recorrencia_atualizar` (opção de aplicar nas contas em aberto), `recorrencia_definir_fim`, `recorrencias_gerar` |
| Leitura | `contas_a_pagar(início, fim)`, `pagamentos_da_obrigacao`, `movimentos_para_vincular`, `contas_a_pagar_por_conta(até)` |
| LGPD | A exportação inclui contas a pagar, pagamentos e recorrências; a exclusão de conta apaga tudo antes dos lançamentos. |

No site: aba **A pagar** (mês, totais, filtros, pagar, histórico de pagamentos, desfazer, recorrências); o painel de saldos mostra quanto falta pagar até o fim do mês; o extrato marca as saídas que pagam contas.

## Instalação (projeto simplifica-v2, já com a 0005 homologada)

1. SQL Editor → New query → cole `0006_etapa3_contas_a_pagar.sql` → Run. Esperado: `Success. No rows returned`.
2. Validação: cole `validacao/05_validar_etapa3_no_supabase.sql` → Run. Esperado: `VALIDAÇÃO APROVADA: 77 de 77`, com rollback automático: os 2 usuários de teste e tudo o que eles criaram são desfeitos; nenhum dado real é tocado.
3. Regressão: rode de novo `01` (74), `03` (63) e `04` (30).
4. Só depois disso o site com a aba **A pagar** é publicado (envio para `main` no GitHub → Netlify).

Evidências locais: `docs/evidencia-testes-locais.txt` (487 verificações), `docs/evidencia-mutacoes-etapa3.txt` (10 de 10 mutações detectadas), `docs/evidencia-validacao-etapa3-local.txt`, `docs/evidencia-site-local.txt` (89 verificações no navegador).

