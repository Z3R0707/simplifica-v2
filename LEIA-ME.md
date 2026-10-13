# Simplifica Finanças v2 — Etapas 1 a 5 (parte 5)

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

# Etapa 4 — cartões, faturas, parcelas, antecipações e estornos

Migração **adicional** `supabase/migrations/0007_etapa4_cartoes.sql`. Roda sobre a 0006, não apaga nem recria nada e se recusa a rodar em qualquer outro estado. Tudo numa única transação.

## Regras

- **Cartão**: dia de fechamento, dia de vencimento, limite (opcional) e a conta que costuma pagar a fatura.
- **Regra de fechamento** (decisão a confirmar): compra feita **antes** do dia do fechamento entra na fatura que fecha naquele mês; **no dia do fechamento ou depois**, na seguinte. Quando o banco lançar diferente, a fatura pode ser escolhida na própria compra.
- **Fatura**: uma por cartão e mês de vencimento. O total é sempre a soma das parcelas (débitos − créditos); nunca é digitado. Datas de uma fatura podem ser ajustadas (feriado) sem mover lançamentos.
- **Lançamentos do cartão**: compra à vista ou parcelada (até 99x, informando o total ou o valor da parcela; centavos que sobram vão para a 1ª parcela), encargo (juros, IOF, tarifa, anuidade, multa, outro), crédito e estorno (ligado à compra, nunca acima do valor dela).
- **Compra já em andamento**: dá para registrar a partir da parcela atual (ex.: 3/10); as anteriores não são lançadas.
- **Estados da parcela**: a cobrar → cobrada (a fatura fechou) → quitada (a fatura foi paga por inteiro). Antecipada é marcada à parte.
- **Antecipação**: as parcelas escolhidas vão para a fatura aberta, com desconto opcional dividido entre elas; a fatura original fica guardada e as faturas futuras (e as contas a pagar delas) diminuem. Pode ser desfeita enquanto a fatura não fechar.
- **Cancelar**: "lancei errado" remove todas as parcelas; "compra cancelada na loja" remove só as ainda não cobradas (as cobradas voltam por estorno). Nada é apagado.
- **Contas a pagar**: cada fatura com valor vira **uma** conta a pagar que acompanha o total sozinha; compras e parcelas não viram contas a pagar (nada somado duas vezes). Fatura sem valor tem a conta a pagar cancelada sozinha. A conta a pagar da fatura não é editada à mão.
- **Pagar a fatura** lança a saída como **pagamento de fatura**: mexe no saldo, mas não é despesa. Uma saída já lançada como despesa, ao ser vinculada à fatura, passa a pagamento de fatura (e volta se o vínculo for desfeito).
- **Resumo por categoria** (decisão a confirmar): compras do cartão entram no mês do **vencimento da fatura**.
- **Limite usado** = tudo o que falta pagar no cartão, inclusive parcelas futuras.
- **Conferência com o banco**: o total informado pelo banco fica guardado à parte; a diferença aparece, mas nunca é ajustada sozinha.
- Operações simultâneas ficam em fila (travas: compra → faturas em ordem de vencimento → conta a pagar → lançamento).

## Instalação (projeto simplifica-v2, já com a 0006 homologada)

1. SQL Editor → New query → cole `0007_etapa4_cartoes.sql` → Run.
2. Validação: `validacao/06_validar_etapa4_no_supabase.sql` → esperado `VALIDAÇÃO APROVADA: 82 de 82`, com rollback automático.
3. Regressão: `01` (74), `03` (63), `04` (30) e `05` (77).
4. Só depois o site com a aba **Cartões** é publicado.

Evidências locais: `docs/evidencia-testes-locais.txt` (622 verificações), `docs/evidencia-mutacoes-etapa4.txt` (12 de 12 mutações detectadas), `docs/evidencia-validacao-etapa4-local.txt`, `docs/evidencia-site-local.txt` (116 verificações no navegador).

# Etapa 5, parte 1 — importação de extratos (OFX e CSV)

Migração **adicional** `supabase/migrations/0008_etapa5_importacao_extratos.sql`. Roda sobre a 0007, não apaga nem recria nada e se recusa a rodar em qualquer outro estado. Tudo numa única transação.

## Como funciona

1. Em uma conta, **Importar extrato** → escolher o arquivo **OFX** (padrão que a maioria dos bancos exporta) ou **CSV** (a pessoa indica quais colunas são data, descrição e valor; nada é presumido).
2. O **arquivo original** é guardado no Storage, na pasta do usuário, com o SHA-256 no nome. Sem o original guardado, o banco recusa a importação.
3. **Prévia**: nada entra no saldo ainda. Cada linha recebe uma sugestão:
   - *Novo* (marcado); *Já importado* (já entrou por outro arquivo); *Possível duplicado* (há lançamento com o mesmo valor até 3 dias de diferença — desmarcado, a pessoa decide); *Antes do saldo inicial*; *Data futura*; *Repetido no arquivo*.
   - Categoria sugerida pelo histórico (mesma descrição, sem acento/caixa/espaços extras). Descrição e categoria editáveis.
4. **Confirmar** cria os lançamentos (origem "importação"). **Desfazer** cancela todos os lançamentos daquela importação (nada é apagado) — recusado se algum já paga uma conta.
5. **Conferência de saldo**: quando o arquivo traz o saldo (OFX), o histórico mostra se confere com o saldo calculado na mesma data.

## Duplicidade

- O mesmo arquivo (mesmo SHA-256) não entra duas vezes, a menos que a importação anterior seja desfeita.
- Cada lançamento importado tem uma chave: o identificador do banco (FITID) quando existe; senão data + valor + descrição + nº da ocorrência no arquivo (duas compras iguais no mesmo dia continuam sendo duas). Um índice único impede a mesma chave duas vezes na conta, inclusive em importações simultâneas e em períodos sobrepostos.
- Nada legítimo é descartado sem a pessoa ver: o que é só parecido fica para ela decidir.

## O que dependia de arquivo real

Feito na parte 2 (abaixo) para o extrato do Itaú (PDF) e do Nubank (CSV). Faturas de cartão e os demais bancos: próximas partes.

## Instalação (projeto simplifica-v2, já com a 0007 homologada)

1. SQL Editor → New query → cole `0008_etapa5_importacao_extratos.sql` → Run.
2. Validação: `validacao/07_validar_etapa5_importacao_no_supabase.sql` → esperado `VALIDAÇÃO APROVADA: 49 de 49` (rollback automático; os arquivos de teste no Storage também são desfeitos).
3. Regressão: `01` (74), `03` (63), `04` (30), `05` (77) e `06` (82).
4. Só depois o site com **Importar extrato** é publicado.

Evidências locais: `docs/evidencia-testes-locais.txt` (679 verificações no banco + 14 testes dos leitores), `docs/evidencia-mutacoes-etapa5.txt` (10 de 10 mutações detectadas), `docs/evidencia-validacao-etapa5-local.txt`, `docs/evidencia-site-local.txt` (131 verificações no navegador).

# Etapa 5, parte 2 — leitores por banco (Itaú em PDF, Nubank em CSV)

Migração **adicional** `supabase/migrations/0009_etapa5_leitores_bancos.sql`. Roda sobre a 0008, não apaga nem recria nada e se recusa a rodar em qualquer outro estado. Tudo numa única transação. Muda só duas coisas no banco: a importação passa a aceitar o formato `pdf`, e o Nubank (CSV da conta) e o Itaú (PDF da conta) passam a constar como **homologados**.

Os leitores foram feitos e conferidos com os arquivos reais enviados (resumo em `docs/evidencia-leitores-arquivos-reais.txt`; os arquivos não estão no repositório).

## Extrato da conta Itaú em PDF

- O PDF é lido **no navegador** (pdf.js servido pelo próprio site, em `/assets/pdfjs-<versão>/`); nada sai do site além do que já saía. O original continua guardado no Storage.
- Cada dia é conferido com a linha **SALDO DO DIA** do próprio extrato: saldo do dia anterior + lançamentos do dia = saldo do dia. Se algum dia não fechar, **nada é importado** e a tela mostra o dia e a diferença. Única exceção: o dia em que o extrato foi emitido (ainda em andamento no banco) — vira aviso.
- O último SALDO DO DIA é o saldo informado, usado na conferência do histórico.
- Fatura de cartão em PDF é reconhecida e explicada (importação de faturas: próxima parte). PDF sem texto (digitalizado) ou com senha recebe mensagem clara.

## Extrato da conta Nubank em CSV

- Reconhecido pelo cabeçalho exato `Data,Valor,Identificador,Descrição`, sem pedir as colunas.
- Usa o **identificador** de cada lançamento do banco como chave contra duplicidade.
- Quem já importou pelo CSV genérico: no próximo arquivo, o que já entrou aparece como **possível duplicado**, desmarcado — nada entra duas vezes.

## Instalação (projeto simplifica-v2, já com a 0008 homologada)

1. SQL Editor → New query → cole `0009_etapa5_leitores_bancos.sql` → Run.
2. Validação: `validacao/08_validar_etapa5_leitores_no_supabase.sql` → esperado `VALIDAÇÃO APROVADA: 26 de 26` (rollback automático).
3. Regressão: `01` (74), `03` (63), `04` (30), `05` (77), `06` (82) e `07` (49).
4. Só depois o site é publicado (o build passa a depender do pacote `pdfjs-dist`, instalado pelo Netlify a partir do `package.json`).

Evidências locais: `docs/evidencia-testes-locais.txt` (688 verificações no banco + 24 testes dos leitores), `docs/evidencia-mutacoes-etapa5-parte2.txt` (10 de 11; a restante é equivalente), `docs/evidencia-validacao-etapa5-parte2-local.txt`, `docs/evidencia-site-local.txt` (141 verificações no navegador), `docs/evidencia-leitores-arquivos-reais.txt`.

# Etapa 5, parte 3 — importação de faturas de cartão (Nubank e Itaú, PDF)

Migração **adicional** `supabase/migrations/0010_etapa5_importacao_faturas.sql`. Roda sobre a 0009, não apaga nem recria nada e se recusa a rodar em qualquer outro estado. Tudo numa única transação.

## Como funciona

1. **Cartões → cartão → Importar fatura** → escolher o PDF da fatura. A leitura acontece no navegador e só é aceita se a soma dos lançamentos lidos bater com o total que o próprio banco imprime na fatura (Nubank: transações do portador; Itaú: "Total dos lançamentos atuais"). O banco de dados confere a soma de novo.
2. O PDF original fica guardado no Storage. A mesma fatura (mesmo arquivo) não entra duas vezes.
3. **Prévia** (nada muda ainda). Cada lançamento é comparado com o que já está no cartão:
   - *Já lançado*: a parcela n de uma compra em N vezes já está nesta fatura (mesmo valor, até R$ 0,99 de diferença de arredondamento — o valor do banco prevalece); ou o desconto de uma antecipação feita no Simplifica.
   - *Já importado*: entrou por outra importação desta fatura.
   - *Possível duplicado* (desmarcado): compra à vista parecida (mesmo valor, até 3 dias), ou a parcela está em outra fatura próxima.
   - *Antecipar*: parcela antecipada que estava numa fatura futura (ou que nasce nesta mesma importação).
   - *Novo*: compra criada a partir da parcela que aparece (ex.: 4/12 cria da 4ª à 12ª), encargo (IOF, juros…) ou crédito (estorno, desconto).
4. **Confirmar** cria as compras, antecipa as parcelas, acerta os centavos pelo valor do banco e grava na fatura as datas reais (fechamento e vencimento) e o total do banco, para a conferência. Pagamentos que aparecem na fatura não viram compras.
5. **Desfazer** cancela as compras criadas (nada é apagado), devolve as parcelas antecipadas e os centavos, e volta as datas da fatura.

Se os lançamentos do cartão mudarem entre a prévia e a confirmação (outra importação, um lançamento à mão), a confirmação é recusada e a prévia precisa ser refeita — assim nada entra em dobro.

## Instalação (projeto simplifica-v2, já com a 0009 homologada)

1. SQL Editor → New query → cole `0010_etapa5_importacao_faturas.sql` → Run.
2. Validação: `validacao/09_validar_etapa5_faturas_no_supabase.sql` → esperado `VALIDAÇÃO APROVADA: 40 de 40` (rollback automático).
3. Regressão (roteiros atualizados para aceitar a etapa 5.3): `01` (74), `03` (63), `04` (30), `05` (77), `06` (82), `07` (49) e `08` (26).
4. Só depois o site com **Importar fatura** é publicado.

Evidências locais: `docs/evidencia-testes-locais.txt` (749 verificações no banco + 34 testes dos leitores), `docs/evidencia-mutacoes-etapa5-parte3.txt` (15 de 15 no banco, 13 de 13 nos leitores), `docs/evidencia-validacao-etapa5-parte3-local.txt`, `docs/evidencia-site-local.txt` (150 verificações no navegador), `docs/evidencia-leitores-arquivos-reais.txt`.

# Etapa 5, parte 4 — corrigir o valor de uma parcela

Migração **adicional** `supabase/migrations/0011_etapa5_valor_parcela.sql` (sobre a 0010). No cartão, **Editar** um lançamento agora tem o campo **Valor da parcela n/N**: muda só aquela parcela (ex.: o banco cobra R$ 75,31 onde estava R$ 75,32); as outras continuam como estão e o total da compra acompanha. Só compras e encargos ativos; nunca abaixo de zero nem do desconto de antecipação; numa fatura já paga, o total não pode ficar abaixo do pago. A mudança fica na auditoria.

Instalação: SQL Editor → `0011_etapa5_valor_parcela.sql` → Run; validação `validacao/10_validar_etapa5_valor_parcela_no_supabase.sql` → `VALIDAÇÃO APROVADA: 15 de 15`; regressão 01 (74), 03 (63), 04 (30), 05 (77), 06 (82), 07 (49), 08 (26), 09 (40). A partir desta versão, os roteiros 03 a 09 aceitam a etapa deles **ou qualquer posterior** — não precisam de cópia nova a cada etapa.

Evidências: `docs/evidencia-etapa5-parte4-local.txt` (roteiros, 6 de 6 mutações, atualização com dados), `docs/evidencia-testes-locais.txt` (766 verificações no banco), `docs/evidencia-site-local.txt` (153 no navegador).

# Etapa 5, parte 5 — faturas de Santander, Mercado Pago, Sicredi, Sicoob e Riachuelo

Migração **adicional** `supabase/migrations/0012_etapa5_leitores_faturas.sql` (sobre a 0011): cadastra a instituição **Riachuelo (Midway)** e registra os cinco leitores de fatura em PDF, feitos e conferidos com os arquivos reais. A importação usa as mesmas regras da parte 3 (prévia, já lançado, possível duplicado, antecipação, acerto de centavos, conferência com o total do banco).

O que os leitores tratam: vários cartões (físico, adicional, virtual) na mesma fatura; pagamentos separados (inclusive quando a fatura os imprime sem sinal); encargos do rotativo; descrições quebradas em mais de uma linha; o ano da compra de parcelas antigas (ex.: 12/12 comprada no ano anterior); várias parcelas da mesma compra na mesma fatura (antecipação), sem confundir com compras diferentes na mesma loja. Cada leitor só aceita a fatura quando a soma bate com o total impresso pelo banco.

Instalação: `0012_etapa5_leitores_faturas.sql` → Run; validação `validacao/11_validar_etapa5_leitores_faturas_no_supabase.sql` → `VALIDAÇÃO APROVADA: 16 de 16`; regressão 01 (74), 03 (63), 04 (30), 05 (77), 06 (82), 07 (49), 08 (26), 09 (40), 10 (15). Nesta versão mudaram os roteiros 01, 08 e 10.

Evidências: `docs/evidencia-etapa5-parte5-local.txt` (roteiros, 15 de 15 mutações, atualização com dados), `docs/evidencia-leitores-arquivos-reais.txt`, `docs/evidencia-testes-locais.txt` (775 no banco + 42 testes dos leitores), `docs/evidencia-site-local.txt` (153 no navegador).

