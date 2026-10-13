// Teste de ponta a ponta do site, num Chromium real, contra o Supabase
// simulado que executa o SQL REAL das migrações (etapas 1 a 5).
// Uso: node --experimental-strip-types tests/navegador/e2e.mjs
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { iniciarServidor } from "./servidor_supabase_simulado.mjs";
import { CHAVES } from "../../supabase/tests/edge/supabase_simulado.mjs";

console.error = () => {};
const RAIZ = fileURLToPath(new URL("../../", import.meta.url));
const DB = process.env.TEST_DB_WEB ?? "simplifica_web_e2e";
const PORTA = Number(process.env.PORTA ?? 54329);
const PSQL = ["-h", process.env.PGHOST ?? "/tmp", "-p", process.env.PGPORT ?? "5433", "-U", process.env.PGUSER ?? "postgres"];
const CAPTURAS = RAIZ + "docs/capturas-site/";
mkdirSync(CAPTURAS, { recursive: true });

// -------------------------------------------------------------- banco limpo
const psql = (args) => execFileSync("psql", [...PSQL, "-q", "-v", "ON_ERROR_STOP=1", ...args], { stdio: ["ignore", "ignore", "pipe"] });
psql(["-d", "postgres", "-c", `drop database if exists ${DB}`, "-c", `create database ${DB}`]);
// papéis são globais no cluster: cria só se ainda não existirem
const stub = readFileSync(RAIZ + "supabase/tests/00_stub_supabase.sql", "utf8")
  .replace(/^create role (\w+) ([^;]*);/gm, "do $$$$ begin create role $1 $2; exception when duplicate_object then null; end $$$$;");
execFileSync("psql", [...PSQL, "-q", "-v", "ON_ERROR_STOP=1", "-d", DB], { input: stub, stdio: ["pipe", "ignore", "pipe"] });
for (const f of ["0001_fundacao_infra.sql", "0002_fundacao_cadastros.sql", "0003_fundacao_lgpd_storage.sql", "0004_etapa2_movimentos_saldos.sql", "0005_etapa2_cancelamento_parcial.sql", "0006_etapa3_contas_a_pagar.sql", "0007_etapa4_cartoes.sql", "0008_etapa5_importacao_extratos.sql"]) {
  psql(["-d", DB, "-f", RAIZ + "supabase/migrations/" + f]);
}

// -------------------------------------------------------------- build apontando para o simulador
execFileSync("node", ["build.mjs"], {
  cwd: RAIZ, stdio: "ignore",
  env: { ...process.env, SUPABASE_URL: `http://127.0.0.1:${PORTA}`, SUPABASE_ANON_KEY: CHAVES.ANON + "-0123456789" },
});
const srv = await iniciarServidor({ db: DB, porta: PORTA, dist: RAIZ + "dist" });

let falhas = 0, oks = 0;
const ok = (cond, nome, detalhe = "") => {
  if (cond) { oks++; console.log(`  OK: ${nome}`); } else { falhas++; console.log(`FALHOU: ${nome}${detalhe ? " — " + detalhe : ""}`); }
};

const { chromium } = await import("/opt/node22/lib/node_modules/playwright/index.mjs");
const navegador = await chromium.launch();
const ctx = await navegador.newContext({ viewport: { width: 1280, height: 900 }, locale: "pt-BR", timezoneId: "America/Sao_Paulo", acceptDownloads: true });
const p = await ctx.newPage();
const errosJs = [];
p.on("pageerror", (e) => errosJs.push(String(e)));
p.on("console", (m) => { if (m.type() === "error" && /Content Security Policy|Refused to/.test(m.text()) && !/fonts\.g/.test(m.text())) errosJs.push("CSP: " + m.text()); });

const texto = async (sel) => (await p.locator(sel).first().innerText()).replace(/\s+/g, " ").trim();
const dialogo = () => p.getByRole("dialog");
const esperarFechar = () => dialogo().waitFor({ state: "detached", timeout: 10000 });
const esperarTexto = (sel, trecho) => p.waitForFunction(([s, t]) => document.querySelector(s)?.textContent?.includes(t), [sel, trecho], { timeout: 10000 }).catch(() => {});

async function criarConta(banco, nome, saldo, data, conferido = true) {
  await p.getByRole("button", { name: "Nova conta" }).click();
  const d = dialogo();
  await d.getByLabel("Banco", { exact: true }).selectOption({ label: banco });
  await d.getByLabel("Nome da conta").fill(nome);
  await d.getByLabel("Data do saldo").fill(data);
  await d.getByLabel("Saldo no fim do dia (R$)").fill(saldo);
  if (conferido) await d.getByLabel("Conferi este saldo no extrato do banco").check();
  await d.getByRole("button", { name: "Cadastrar conta" }).click();
  await esperarFechar();
}

async function lancar({ tipo = "Despesa", sentido, valor, data, descricao, categoria, previsto = false }) {
  await p.getByRole("button", { name: "Novo lançamento" }).click();
  const d = dialogo();
  if (previsto) await d.getByRole("radio", { name: "Previsto" }).check();
  await d.getByRole("radio", { name: tipo, exact: true }).check();
  if (sentido) await d.getByRole("radio", { name: sentido }).check();
  await d.getByLabel("Valor (R$)").fill(valor);
  await d.getByLabel(previsto ? "Data prevista" : "Data", { exact: true }).fill(data);
  await d.getByLabel("Descrição").fill(descricao);
  if (categoria) await d.getByLabel("Categoria", { exact: true }).selectOption({ label: categoria });
  await d.getByRole("button", { name: "Lançar" }).click();
  await esperarFechar();
}

try {
  // ============================================================ cadastro e confirmação
  await p.goto(srv.base + "/");
  await p.getByRole("heading", { name: "Entrar" }).waitFor();
  ok(true, "tela de entrar abre");
  await p.screenshot({ path: CAPTURAS + "01-entrar.png" });

  await p.getByRole("link", { name: "Criar conta" }).click();
  await p.getByLabel("Seu nome").fill("Ana Teste");
  await p.getByLabel("E-mail").fill("ana@teste.com");
  await p.getByLabel("Senha", { exact: true }).fill("curta");
  await p.getByLabel("Repita a senha").fill("curta");
  await p.getByRole("button", { name: "Criar conta" }).click();
  ok((await texto("[role=alert]")).includes("pelo menos 8"), "senha curta recusada no cadastro");
  await p.getByLabel("Senha", { exact: true }).fill("senha-ana-123");
  await p.getByLabel("Repita a senha").fill("senha-ana-123");
  await p.getByRole("button", { name: "Criar conta" }).click();
  await p.getByRole("heading", { name: "Confirme seu e-mail" }).waitFor();
  ok(true, "cadastro pede confirmação do e-mail");

  await p.goto(srv.base + "/#/entrar");
  await p.getByLabel("E-mail").fill("ana@teste.com");
  await p.getByLabel("Senha").fill("senha-ana-123");
  await p.getByRole("button", { name: "Entrar" }).click();
  await p.locator("[role=alert]").waitFor();
  ok((await texto("[role=alert]")).includes("Confirme seu e-mail"), "login antes de confirmar é recusado com mensagem clara");

  const idAna = srv.confirmar("ana@teste.com");
  await p.goto(`${srv.base}/#access_token=usuario:${idAna}&refresh_token=refresh:${idAna}&expires_in=3600&token_type=bearer&type=signup`);
  await p.getByRole("heading", { name: "Cadastre sua primeira conta" }).waitFor();
  ok(true, "link de confirmação entra direto no sistema");
  ok(!(await p.url()).includes("access_token"), "token removido do endereço após o link");

  // ============================================================ contas (exemplo da especificação)
  await p.getByRole("link", { name: "Cadastrar conta" }).click();
  await p.getByRole("heading", { name: "Contas" }).waitFor();
  await criarConta("Santander", "Santander", "5.000,00", "2026-10-01");
  await criarConta("Sicredi", "Sicredi", "3500", "2026-10-01");
  await criarConta("Itaú", "Itaú", "2.800,00", "2026-10-01");
  await criarConta("Nubank", "Nubank", "1.200,00", "2026-10-01");
  await criarConta("Mercado Pago", "Mercado Pago", "750,00", "2026-10-01");
  await p.waitForFunction(() => document.querySelectorAll("tbody tr").length === 5, null, { timeout: 10000 }).catch(() => {});
  ok((await p.locator("tbody tr").count()) === 5, "5 contas cadastradas e listadas");

  await p.getByRole("link", { name: "Saldos" }).first().click();
  await p.locator(".consolidado-valor").waitFor();
  ok((await texto(".consolidado-valor")) === "R$ 13.250,00", "consolidado do exemplo da especificação = R$ 13.250,00", await texto(".consolidado-valor"));
  ok((await p.locator(".cartao-conta").count()) === 5, "painel mostra cada conta separada");

  // ============================================================ lançamentos e data-base
  await p.locator(".cartao-conta", { hasText: "Santander" }).click();
  await p.getByRole("heading", { name: "Santander" }).waitFor();
  const idSantander = (await p.url()).split("/conta/")[1];
  await lancar({ valor: "100,00", data: "2026-09-30", descricao: "Compra anterior", categoria: "Alimentação" });
  await lancar({ tipo: "Receita", valor: "50", data: "2026-10-01", descricao: "Reembolso no dia-base", categoria: "Reembolsos" });
  await lancar({ valor: "200,00", data: "2026-10-02", descricao: "Mercado", categoria: "Alimentação" });
  await lancar({ tipo: "Receita", valor: "1.000,00", data: "2026-10-05", descricao: "Salário", categoria: "Salário" });
  await esperarTexto(".resumo-conta .valor-destaque", "5.800,00");
  await p.locator("tr", { hasText: "Salário" }).waitFor();
  ok((await texto(".resumo-conta .valor-destaque")) === "R$ 5.800,00", "saldo = inicial + só o que vem depois da data-base (R$ 5.800,00)", await texto(".resumo-conta .valor-destaque"));
  ok((await p.getByText("Já incluído no saldo inicial").count()) === 2, "lançamentos até a data-base marcados como já incluídos");
  await p.screenshot({ path: CAPTURAS + "03-extrato.png", fullPage: true });

  // aviso no formulário para data até a data-base
  await p.getByRole("button", { name: "Novo lançamento" }).click();
  await dialogo().getByLabel("Data", { exact: true }).fill("2026-09-15");
  ok((await dialogo().innerText()).includes("não altera o saldo"), "formulário avisa que data até a data-base não altera o saldo");
  await p.screenshot({ path: CAPTURAS + "04-novo-lancamento.png" });
  await dialogo().getByRole("button", { name: "Cancelar" }).click();
  await esperarFechar();

  // previsto → efetivar
  await lancar({ valor: "300,00", data: "2026-11-10", descricao: "Aluguel", categoria: "Moradia", previsto: true });
  await esperarTexto(".resumo-conta", "Com previstos");
  ok((await texto(".resumo-conta")).includes("Com previstos") && (await texto(".resumo-conta")).includes("R$ 5.500,00"), "previsto aparece só no saldo com previstos");
  ok((await texto(".resumo-conta .valor-destaque")) === "R$ 5.800,00", "previsto não altera o saldo de hoje");
  await p.locator("tr", { hasText: "Aluguel" }).getByRole("button", { name: "Aconteceu" }).click();
  await dialogo().getByLabel("Data em que aconteceu").fill("2026-10-10");
  await dialogo().getByRole("button", { name: "Confirmar" }).click();
  await esperarFechar();
  await p.waitForFunction(() => document.querySelector(".resumo-conta .valor-destaque")?.textContent?.includes("5.500,00"));
  ok(true, "previsto efetivado entra no saldo (R$ 5.500,00)");
  ok((await p.locator("tr", { hasText: "Aluguel" }).count()) === 1, "efetivar não duplica o lançamento");

  // cancelar com motivo
  await p.locator("tr", { hasText: "Salário" }).getByRole("button", { name: "Cancelar" }).click();
  await dialogo().getByRole("button", { name: "Cancelar lançamento" }).click();
  ok((await dialogo().innerText()).includes("Escreva o motivo"), "cancelamento sem motivo é recusado");
  await dialogo().getByLabel("Motivo").fill("Lançado em duplicidade");
  await dialogo().getByRole("button", { name: "Cancelar lançamento" }).click();
  await esperarFechar();
  await p.waitForFunction(() => document.querySelector(".resumo-conta .valor-destaque")?.textContent?.includes("4.500,00"));
  ok(true, "cancelado sai do saldo (R$ 4.500,00)");
  ok((await p.locator("tr", { hasText: "Salário" }).count()) === 0, "cancelado some da lista por padrão");
  await p.getByRole("button", { name: /Mostrar cancelados/ }).click();
  ok((await texto("tr.linha-cancelado")).includes("Lançado em duplicidade"), "cancelado continua no histórico com o motivo");

  // edição
  await p.locator("tr", { hasText: "Mercado" }).getByRole("button", { name: "Editar" }).click();
  await dialogo().getByLabel("Valor (R$)").fill("250,00");
  await dialogo().getByRole("button", { name: "Salvar alterações" }).click();
  await esperarFechar();
  await p.waitForFunction(() => document.querySelector(".resumo-conta .valor-destaque")?.textContent?.includes("4.450,00"));
  ok(true, "edição de valor recalcula o saldo (R$ 4.450,00)");

  // cancelamento parcial e desfazer
  const linhaAluguel = () => p.locator("tr").filter({ has: p.locator(".descricao", { hasText: /^Aluguel$/ }) });
  await linhaAluguel().getByRole("button", { name: "Cancelar" }).click();
  await dialogo().getByRole("radio", { name: "Só uma parte" }).check();
  await dialogo().getByLabel("Valor cancelado (R$)").fill("400,00");
  await dialogo().getByLabel("Data do cancelamento").fill("2026-10-11");
  await dialogo().getByLabel("Motivo").fill("Desconto no aluguel");
  await dialogo().getByRole("button", { name: "Cancelar esta parte" }).click();
  ok((await dialogo().innerText()).includes("passa do que resta"), "cancelamento parcial acima do valor é recusado");
  await dialogo().getByLabel("Valor cancelado (R$)").fill("100,00");
  await dialogo().getByRole("button", { name: "Cancelar esta parte" }).click();
  await esperarFechar();
  await esperarTexto(".resumo-conta .valor-destaque", "4.550,00");
  ok((await texto(".resumo-conta .valor-destaque")) === "R$ 4.550,00", "cancelamento parcial devolve R$ 100 ao saldo (R$ 4.550,00)");
  ok((await texto("body")).includes("Cancelado parcialmente: R$ 100,00 de R$ 300,00"), "original mostra quanto já foi cancelado");
  ok((await p.locator("tr", { hasText: "Cancelamento parcial: Aluguel" }).count()) === 1, "cancelamento parcial aparece ligado ao original");
  await linhaAluguel().getByRole("button", { name: "Cancelar" }).click();
  ok(await dialogo().getByRole("radio", { name: "Tudo" }).isDisabled(), "com parcial ativo, não deixa cancelar tudo");
  await dialogo().getByRole("button", { name: "Voltar" }).click();
  await esperarFechar();
  await p.locator("tr", { hasText: "Cancelamento parcial: Aluguel" }).getByRole("button", { name: "Cancelar" }).click();
  await dialogo().getByLabel("Motivo").fill("Desconto não confirmado");
  await dialogo().getByRole("button", { name: "Cancelar lançamento" }).click();
  await esperarFechar();
  await esperarTexto(".resumo-conta .valor-destaque", "4.450,00");
  ok((await texto(".resumo-conta .valor-destaque")) === "R$ 4.450,00", "desfazer o cancelamento parcial volta o saldo (R$ 4.450,00)");

  // clique duplo não duplica
  await p.getByRole("button", { name: "Novo lançamento" }).click();
  await dialogo().getByRole("radio", { name: "Sem categoria" }).check();
  await dialogo().getByLabel("Valor (R$)").fill("10,00");
  await dialogo().getByLabel("Data", { exact: true }).fill("2026-10-06");
  await dialogo().getByLabel("Descrição").fill("Teste clique duplo");
  await dialogo().getByRole("button", { name: "Lançar" }).dblclick();
  await esperarFechar();
  await p.waitForTimeout(500);
  ok((await p.locator("tr", { hasText: "Teste clique duplo" }).count()) === 1, "clique duplo em Lançar grava um único lançamento");

  // despesa sempre sai, receita sempre entra: o sentido só aparece em "Sem categoria"
  await p.getByRole("button", { name: "Novo lançamento" }).click();
  ok((await dialogo().getByRole("radio", { name: "Saiu" }).count()) === 0, "despesa: não pergunta se entrou ou saiu");
  ok((await dialogo().getByRole("radio", { name: /Estorno/ }).count()) === 0, "lançamento novo não oferece estorno (despesa desfeita = cancelar)");
  await dialogo().getByRole("radio", { name: "Receita", exact: true }).check();
  ok((await dialogo().getByRole("radio", { name: "Entrou" }).count()) === 0, "receita: não pergunta se entrou ou saiu");
  await dialogo().getByRole("radio", { name: "Sem categoria" }).check();
  ok((await dialogo().getByRole("radio", { name: "Saiu" }).count()) === 1, "sem categoria: pergunta se entrou ou saiu");
  await dialogo().getByRole("button", { name: "Cancelar" }).click();
  await esperarFechar();

  // valores inválidos
  await p.getByRole("button", { name: "Novo lançamento" }).click();
  await dialogo().getByLabel("Valor (R$)").fill("12,345");
  await dialogo().getByLabel("Descrição").fill("x");
  await dialogo().getByLabel("Categoria", { exact: true }).selectOption({ label: "Lazer" });
  await dialogo().getByRole("button", { name: "Lançar" }).click();
  ok((await dialogo().innerText()).includes("valor maior que zero"), "valor inválido é recusado antes de enviar");
  await dialogo().getByLabel("Valor (R$)").fill("10");
  await dialogo().getByLabel("Data", { exact: true }).fill("2099-01-01");
  await dialogo().getByRole("button", { name: "Lançar" }).click();
  ok((await dialogo().innerText()).includes("marque como previsto"), "data futura sem marcar previsto é recusada");
  await dialogo().getByRole("button", { name: "Cancelar" }).click();
  await esperarFechar();

  // ============================================================ painel e consolidado
  await p.getByRole("link", { name: "Saldos" }).first().click();
  await p.waitForFunction(() => document.querySelector(".consolidado-valor")?.textContent?.includes("12.690,00"));
  ok(true, "consolidado reflete os lançamentos (R$ 12.690,00)");
  await p.screenshot({ path: CAPTURAS + "02-saldos.png", fullPage: true });
  await p.getByLabel("Saldo em").fill("2026-10-03");
  await p.waitForFunction(() => document.querySelector(".consolidado-valor")?.textContent?.includes("13.000,00"));
  ok(true, "saldo numa data passada (03/10 = R$ 13.000,00)");
  await p.getByLabel("Saldo em").fill("2026-09-20");
  await p.locator(".consolidado .alerta").waitFor();
  ok((await texto(".consolidado")).includes("fora da soma"), "data anterior ao saldo inicial avisa que as contas ficaram fora");

  // ============================================================ conta pendente e arquivamento
  await p.getByRole("link", { name: "Contas" }).first().click();
  await criarConta("Itaú", "Itaú poupança", "999,00", "2026-10-01", false);
  await p.locator("tr", { hasText: "Itaú poupança" }).waitFor();
  ok((await texto("tr:has-text('Itaú poupança')")).includes("Saldo inicial a confirmar"), "conta sem saldo conferido fica marcada");
  await p.locator("tr", { hasText: "Mercado Pago" }).getByRole("button", { name: "Arquivar" }).click();
  await dialogo().getByRole("button", { name: "Arquivar" }).click();
  await esperarFechar();
  await p.getByRole("link", { name: "Saldos" }).first().click();
  await p.waitForFunction(() => document.querySelector(".consolidado-valor")?.textContent?.includes("11.940,00"));
  ok(true, "conta arquivada sai do consolidado (R$ 11.940,00)");
  ok((await texto(".consolidado")).includes("1 conta ficou fora da soma"), "consolidado avisa a conta com saldo a confirmar");
  ok((await p.getByRole("button", { name: /Mostrar contas arquivadas \(1\)/ }).count()) === 1, "arquivada aparece separada");

  // ============================================================ resumo e categorias
  await p.getByRole("link", { name: "Resumo" }).first().click();
  await p.getByLabel("Mês").fill("2026-10");
  await p.locator(".totais").waitFor();
  await p.waitForFunction(() => document.querySelector(".totais")?.textContent?.includes("R$ 550,00"));
  const totais = await texto(".totais");
  ok(totais.includes("R$ 50,00") && totais.includes("R$ 550,00"), "resumo de outubro: receitas R$ 50,00 e despesas R$ 550,00 (sem o cancelado)", totais);
  ok((await texto("body")).includes("sem categoria somam"), "resumo avisa lançamentos sem categoria");
  await p.screenshot({ path: CAPTURAS + "05-resumo.png", fullPage: true });

  await p.getByRole("link", { name: "Categorias" }).first().click();
  await p.locator(".coluna-categorias").first().getByRole("button", { name: "Nova categoria" }).click();
  await dialogo().getByLabel("Nome").fill("Pet");
  await dialogo().getByRole("button", { name: "Salvar" }).click();
  await esperarFechar();
  await p.getByText("Pet", { exact: true }).waitFor();
  ok((await p.getByText("Pet", { exact: true }).count()) === 1, "categoria nova criada");


  // ============================================================ contas a pagar (Etapa 3)
  const linhaAP = (nome) => p.locator("tbody tr").filter({ has: p.locator(".descricao", { hasText: nome }) });
  const saldoItau = async () => {
    await p.getByRole("link", { name: "Saldos" }).first().click();
    await p.locator(".cartao-conta", { hasText: "Itaú" }).first().waitFor();
    return (await p.locator(".cartao-conta").filter({ has: p.locator("strong", { hasText: /^Itaú$/ }) }).locator(".valor-grande").innerText()).trim();
  };
  ok((await saldoItau()) === "R$ 2.800,00", "Itaú começa com R$ 2.800,00");
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await p.getByRole("heading", { name: "Contas a pagar" }).waitFor();
  await p.getByRole("heading", { name: "Nenhuma conta a pagar neste mês" }).waitFor();
  ok(true, "aba Contas a pagar abre vazia");

  async function novaContaAPagar({ descricao, valor, vencimento, categoria, conta, todoMes = false, ate, numerar = false }) {
    await p.getByRole("button", { name: "Nova conta a pagar" }).click();
    const d = dialogo();
    await d.getByLabel("Descrição").fill(descricao);
    await d.getByLabel("Valor (R$)").fill(valor);
    await d.getByLabel("Vencimento", { exact: true }).fill(vencimento);
    if (categoria) await d.getByLabel("Categoria", { exact: true }).selectOption({ label: categoria });
    if (conta) await d.getByLabel("Pagar pela conta (opcional)").selectOption({ label: conta });
    if (todoMes) {
      await d.getByRole("radio", { name: "Todo mês" }).check();
      await d.getByLabel("Primeiro vencimento").fill(vencimento);
      if (ate) await d.getByLabel("Até o mês (opcional)").fill(ate);
      if (numerar) await d.getByLabel(/Numerar as parcelas/).check();
    }
    await d.getByRole("button", { name: "Cadastrar" }).click();
    await esperarFechar();
  }

  await novaContaAPagar({ descricao: "Conta de luz", valor: "200,00", vencimento: "2026-10-20", categoria: "Serviços e assinaturas", conta: "Itaú" });
  await linhaAP("Conta de luz").waitFor();
  await esperarTexto(".totais", "200,00");
  ok((await texto(".totais")).includes("Vencem no mês R$ 200,00"), "conta a pagar entra nos totais do mês", await texto(".totais"));
  ok((await saldoItau()) === "R$ 2.800,00", "conta a pagar sozinha não mexe no saldo");

  // pagamento parcial
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await linhaAP("Conta de luz").getByRole("button", { name: "Pagar" }).click();
  ok((await dialogo().getByLabel("Saiu da conta").locator("option:checked").innerText()) === "Itaú", "pagar sugere a conta prevista");
  ok((await dialogo().getByLabel("Valor pago (R$)").inputValue()) === "200,00", "pagar sugere o valor que falta");
  await dialogo().getByLabel("Valor pago (R$)").fill("80,00");
  await dialogo().getByLabel("Data do pagamento").fill("2026-10-12");
  ok((await dialogo().innerText()).includes("Pagamento parcial: restam R$ 120,00"), "mostra quanto vai restar");
  await p.screenshot({ path: CAPTURAS + "10-pagar.png" });
  await dialogo().getByRole("button", { name: "Registrar pagamento" }).click();
  await esperarFechar();
  await esperarTexto("tbody", "Falta");
  ok((await texto("tbody")).includes("Paga em parte") || (await texto("tbody")).includes("Vencida"), "pagamento parcial não marca como paga");
  ok((await texto("tbody")).includes("Falta R$ 120,00"), "lista mostra o que falta (R$ 120,00)");

  // pagar a mais sem informar juros é recusado; com juros, quita
  await linhaAP("Conta de luz").getByRole("button", { name: "Pagar" }).click();
  await dialogo().getByLabel("Valor pago (R$)").fill("125,00");
  await dialogo().getByLabel("Data do pagamento").fill("2026-10-12");
  await dialogo().getByRole("button", { name: "Registrar pagamento" }).click();
  ok((await dialogo().innerText()).includes("mas faltam só R$ 120,00"), "pagar mais do que falta é recusado com explicação");
  await dialogo().getByLabel("Teve juros, multa ou desconto").check();
  await dialogo().getByLabel("Juros (R$)").fill("5,00");
  ok((await dialogo().innerText()).includes("= R$ 120,00"), "mostra o abatimento com juros");
  await dialogo().getByRole("button", { name: "Registrar pagamento" }).click();
  await esperarFechar();
  await p.waitForFunction(() => !document.querySelector("tbody")?.textContent?.includes("Conta de luz"), null, { timeout: 10000 }).catch(() => {});
  ok((await linhaAP("Conta de luz").count()) === 0, "conta quitada sai de “Em aberto”");
  await p.getByRole("button", { name: "Pagas" }).click();
  await linhaAP("Conta de luz").waitFor();
  ok((await texto("tbody")).includes("Paga") && (await texto("tbody")).includes("+ R$ 5,00 de juros/multa"), "aparece em Pagas com os juros");
  ok((await saldoItau()) === "R$ 2.595,00", "saldo do Itaú cai R$ 205 (80 + 125)", await saldoItau());

  // recorrência com parcelas numeradas
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await p.getByRole("heading", { name: "Contas a pagar" }).waitFor();
  await novaContaAPagar({ descricao: "Aluguel", valor: "1.500,00", vencimento: "2026-10-05", categoria: "Moradia", todoMes: true, ate: "2027-03", numerar: true });
  await linhaAP("Aluguel (1/6)").waitFor();
  ok(true, "recorrência cria o mês atual numerado (1/6)");
  ok((await texto("body")).includes("Contas que se repetem") && (await texto(".secao")).includes("todo dia 5"), "recorrência aparece em “Contas que se repetem”");
  await p.screenshot({ path: CAPTURAS + "09-contas-a-pagar.png", fullPage: true });
  await p.getByRole("button", { name: "Próximo mês" }).click();
  await linhaAP("Aluguel (2/6)").waitFor();
  ok(true, "próximo mês já tem a parcela 2/6");
  await p.getByRole("button", { name: "Mês anterior" }).click();
  await linhaAP("Aluguel (1/6)").waitFor();

  // vincular uma saída já lançada
  await novaContaAPagar({ descricao: "Internet", valor: "100,00", vencimento: "2026-10-15", categoria: "Serviços e assinaturas" });
  await linhaAP("Internet").waitFor();
  await p.getByRole("link", { name: "Saldos" }).first().click();
  await p.locator(".cartao-conta").filter({ has: p.locator("strong", { hasText: /^Itaú$/ }) }).click();
  await p.locator(".resumo-conta").waitFor();
  await lancar({ valor: "100,00", data: "2026-10-12", descricao: "Débito internet", categoria: "Serviços e assinaturas" });
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await linhaAP("Internet").getByRole("button", { name: "Pagar" }).click();
  await dialogo().getByRole("radio", { name: "Já lancei essa saída" }).check();
  await dialogo().getByRole("radio", { name: /Débito internet/ }).check();
  ok((await dialogo().getByLabel("Valor pago (R$)").inputValue()) === "100,00", "escolher a saída preenche o valor");
  await dialogo().getByRole("button", { name: "Vincular saída" }).click();
  await esperarFechar();
  await p.waitForFunction(() => !document.querySelector("tbody")?.textContent?.includes("Internet"), null, { timeout: 10000 }).catch(() => {});
  ok((await linhaAP("Internet").count()) === 0, "vincular quita a conta");
  ok((await saldoItau()) === "R$ 2.495,00", "vincular não lança a saída de novo (R$ 2.495,00)", await saldoItau());

  // extrato: saída que paga conta é protegida
  await p.locator(".cartao-conta").filter({ has: p.locator("strong", { hasText: /^Itaú$/ }) }).click();
  await p.locator(".resumo-conta").waitFor();
  await p.locator("tr", { hasText: "Débito internet" }).waitFor();
  ok((await p.getByText("Pagamento de conta a pagar").count()) === 3, "extrato marca as saídas que pagam contas");
  await p.locator("tr", { hasText: "Débito internet" }).getByRole("button", { name: "Cancelar" }).click();
  ok((await dialogo().innerText()).includes("paga uma conta a pagar"), "cancelar avisa que a saída paga uma conta");
  await dialogo().getByLabel("Motivo").fill("tentativa");
  await dialogo().getByRole("button", { name: "Cancelar lançamento" }).click();
  await dialogo().locator("[role=alert]").waitFor();
  ok((await dialogo().innerText()).includes("Desfaça o pagamento"), "banco recusa cancelar a saída que paga conta");
  await dialogo().getByRole("button", { name: "Voltar" }).click();
  await esperarFechar();

  // desfazer um pagamento devolve o valor
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await p.getByRole("button", { name: "Pagas" }).click();
  await linhaAP("Conta de luz").getByRole("button", { name: "Pagamentos" }).click();
  await dialogo().locator("li").first().waitFor();
  ok((await dialogo().locator("li").count()) === 2, "histórico mostra os 2 pagamentos");
  await dialogo().locator("li", { hasText: "Pago R$ 80,00" }).getByRole("button", { name: "Desfazer" }).click();
  const dd = p.getByRole("dialog", { name: "Desfazer pagamento" });
  ok(await dd.getByLabel(/Cancelar também a saída/).isChecked(), "desfazer sugere cancelar a saída criada");
  await dd.getByLabel("Motivo").fill("Paguei na conta errada");
  await dd.getByRole("button", { name: "Desfazer pagamento" }).click();
  await dd.waitFor({ state: "detached" });
  await p.getByRole("dialog").getByText("Desfeito: Paguei na conta errada").waitFor();
  ok(true, "pagamento desfeito continua no histórico com o motivo");
  await p.getByRole("dialog").getByRole("button", { name: "Fechar" }).last().click();
  await esperarFechar();
  await p.getByRole("button", { name: "Em aberto" }).click();
  await linhaAP("Conta de luz").waitFor();
  ok((await linhaAP("Conta de luz").innerText()).includes("Falta R$ 80,00"), "conta volta a ter R$ 80,00 em aberto");
  ok((await saldoItau()) === "R$ 2.575,00", "dinheiro volta ao saldo (R$ 2.575,00)", await saldoItau());
  ok((await texto(".consolidado")).includes("Contas a pagar até 31/10/2026"), "painel mostra as contas a pagar até o fim do mês", await texto(".consolidado"));
  ok((await texto(".consolidado")).includes("R$ 1.580,00"), "total a pagar no mês: R$ 1.580,00 (80 da luz + 1.500 do aluguel)");
  ok((await p.locator(".cartao-conta").filter({ has: p.locator("strong", { hasText: /^Itaú$/ }) }).innerText()).includes("A pagar até o fim do mês: R$ 80,00"), "cartão do Itaú mostra o que sai dele no mês");

  // encerrar a recorrência
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await p.locator(".secao li", { hasText: "Aluguel" }).getByRole("button", { name: "Mudar fim" }).click();
  await dialogo().getByLabel("Último mês").fill("2026-10");
  await dialogo().getByRole("button", { name: "Encerrar" }).click();
  await esperarFechar();
  await p.getByRole("button", { name: "Próximo mês" }).click();
  await p.getByRole("button", { name: "Todas" }).click();
  await linhaAP("Aluguel (2/6)").waitFor();
  ok((await linhaAP("Aluguel (2/6)").innerText()).includes("Cancelada: Recorrência encerrada"), "encerrar cancela os meses seguintes, sem apagar");
  await p.getByRole("button", { name: "Mês anterior" }).click();


  // ============================================================ cartões (Etapa 4)
  await p.getByRole("link", { name: "Cartões" }).first().click();
  await p.getByRole("heading", { name: "Cadastre seu primeiro cartão" }).waitFor();
  ok(true, "aba Cartões abre vazia");
  await p.getByRole("button", { name: "Cadastrar cartão" }).click();
  {
    const d = dialogo();
    await d.getByLabel("Nome do cartão").fill("Nubank Ana");
    await d.getByLabel("Banco do cartão").selectOption({ label: "Nubank" });
    await d.getByLabel("Dia do fechamento").fill("3");
    await d.getByLabel("Dia do vencimento").fill("10");
    await d.getByLabel("Limite (opcional)").fill("5.000,00");
    await d.getByLabel("Conta que paga a fatura (opcional)").selectOption({ label: "Itaú" });
    await d.getByRole("button", { name: "Cadastrar cartão" }).click();
    await esperarFechar();
  }
  await p.locator(".cartao-conta", { hasText: "Nubank Ana" }).waitFor();
  ok((await texto(".cartao-conta")).includes("fecha dia 3, vence dia 10"), "cartão cadastrado com fechamento e vencimento");

  async function novaCompra({ data, descricao, categoria, valor, parcelas }) {
    await p.getByRole("button", { name: "Nova compra" }).first().click();
    const d = dialogo();
    await d.getByLabel("Data", { exact: true }).fill(data);
    await d.getByLabel("Descrição").fill(descricao);
    if (categoria) await d.getByLabel("Categoria").selectOption({ label: categoria });
    if (parcelas) {
      await d.getByRole("radio", { name: "Parcelado" }).check();
      await d.getByLabel("Número de parcelas").fill(String(parcelas));
      await d.getByLabel("Valor total (R$)").fill(valor);
    } else {
      await d.getByLabel("Valor (R$)").fill(valor);
    }
    await d.locator("#fatura-escolhida").waitFor();
    return d;
  }
  let d = await novaCompra({ data: "2026-10-02", descricao: "Mercado cartão", categoria: "Alimentação", valor: "100,00" });
  await p.waitForFunction(() => document.querySelector("[role=dialog]")?.textContent?.includes("vence em 10/10/2026"), null, { timeout: 10000 }).catch(() => {});
  ok((await d.innerText()).includes("fecha em 03/10/2026 e vence em 10/10/2026"), "compra de 02/10 mostra a fatura certa (fecha 03/10, vence 10/10)");
  await d.getByRole("button", { name: "Lançar" }).click();
  await esperarFechar();
  d = await novaCompra({ data: "2026-10-05", descricao: "Televisão", categoria: "Lazer", valor: "1.000,00", parcelas: 10 });
  ok((await d.innerText()).includes("10x de R$ 100,00"), "parcelado mostra 10x de R$ 100,00");
  await p.screenshot({ path: CAPTURAS + "13-nova-compra.png" });
  await d.getByRole("button", { name: "Lançar" }).click();
  await esperarFechar();

  await p.locator(".cartao-conta", { hasText: "Nubank Ana" }).click();
  await p.locator(".fatura-topo").waitFor();
  await p.locator("tbody tr", { hasText: "Televisão" }).waitFor();
  ok((await texto("tbody tr:has-text('Televisão')")).includes("1/10"), "fatura atual mostra a parcela 1/10");
  ok((await texto(".fatura-topo")).includes("R$ 100,00"), "total da fatura atual = R$ 100,00");
  await p.getByRole("button", { name: "Fatura anterior" }).click();
  await p.locator("tbody tr", { hasText: "Mercado cartão" }).waitFor();
  ok((await texto(".fatura-topo")).includes("Vencida"), "fatura de outubro: fechada e não paga = vencida");
  ok((await texto("tbody")).includes("Cobrada"), "parcela da fatura fechada aparece como cobrada");

  // pagar a fatura
  await p.getByRole("button", { name: "Pagar fatura" }).click();
  await dialogo().getByLabel("Valor pago (R$)").waitFor();
  ok((await dialogo().innerText()).includes("como pagamento de fatura"), "pagar a fatura explica que não é despesa");
  ok((await dialogo().getByLabel("Valor pago (R$)").inputValue()) === "100,00", "pagar sugere o valor da fatura");
  await dialogo().getByRole("button", { name: "Registrar pagamento" }).click();
  await esperarFechar();
  await esperarTexto(".fatura-topo", "Paga");
  ok((await texto(".fatura-topo")).includes("Paga"), "fatura fica paga");
  await esperarTexto("tbody", "Quitada");
  ok((await texto("tbody")).includes("Quitada"), "parcela da fatura paga: quitada");
  ok((await saldoItau()) === "R$ 2.475,00", "pagamento da fatura sai do Itaú (R$ 2.475,00)", await saldoItau());

  // resumo: a compra conta uma vez, o pagamento da fatura não é despesa
  await p.getByRole("link", { name: "Resumo" }).first().click();
  await p.getByLabel("Mês").fill("2026-10");
  await p.locator(".lista-barras").first().waitFor();
  await esperarTexto(".lista-barras", "Alimentação");
  const alim = (await p.locator(".lista-barras li", { hasText: "Alimentação" }).first().innerText()).replace(/\s+/g, " ");
  ok(alim.includes("R$ 350,00"), "resumo de outubro: Alimentação = R$ 250 da conta + R$ 100 do cartão (sem somar o pagamento)", alim);

  // antecipação das parcelas 6, 7 e 8 com desconto
  await p.getByRole("link", { name: "Cartões" }).first().click();
  await p.locator(".cartao-conta", { hasText: "Nubank Ana" }).click();
  await p.locator("tbody tr", { hasText: "Televisão" }).waitFor();
  await p.locator("tbody tr", { hasText: "Televisão" }).getByRole("button", { name: "Parcelas" }).click();
  await dialogo().getByLabel("Parcela 6").waitFor();
  for (const n of [6, 7, 8]) await dialogo().getByLabel(`Parcela ${n}`, { exact: true }).check();
  await dialogo().getByLabel(/Desconto da antecipação/).fill("30,00");
  ok((await dialogo().innerText()).includes("Antecipando R$ 300,00; paga R$ 270,00"), "antecipação mostra valor e desconto");
  await p.screenshot({ path: CAPTURAS + "14-antecipar.png" });
  await dialogo().getByRole("button", { name: "Antecipar" }).click();
  await dialogo().getByText("3 parcela(s) antecipada(s)").waitFor();
  ok((await dialogo().innerText()).includes("antecipada (era de abr de 2027)"), "parcela antecipada guarda a fatura original");
  await dialogo().getByRole("button", { name: "Fechar" }).last().click();
  await esperarFechar();
  await esperarTexto(".fatura-topo", "370,00");
  ok((await texto(".fatura-topo")).includes("R$ 370,00"), "fatura atual: R$ 100 + R$ 270 antecipados = R$ 370,00");
  ok((await p.getByText(/Antecipada \(era da fatura de/).count()) === 3, "fatura lista as 3 parcelas antecipadas");

  // estorno e conferência com o banco
  await p.getByRole("button", { name: "Fatura anterior" }).click();
  await p.locator("tbody tr", { hasText: "Mercado cartão" }).getByRole("button", { name: "Estornar" }).click();
  await dialogo().getByLabel("Valor estornado (R$)").fill("20,00");
  await dialogo().getByRole("button", { name: "Lançar estorno" }).click();
  await esperarFechar();
  await p.getByRole("button", { name: "Próxima fatura" }).click();
  await p.locator("tbody tr", { hasText: "Estorno: Mercado cartão" }).waitFor();
  ok((await texto("tbody tr:has-text('Estorno: Mercado cartão')")).includes("−R$ 20,00"), "estorno entra como crédito na fatura aberta");
  await esperarTexto(".fatura-topo", "350,00");
  ok((await texto(".fatura-topo")).includes("R$ 350,00"), "fatura atual cai para R$ 350,00");
  await p.getByRole("button", { name: "Datas e total do banco" }).click();
  await dialogo().getByLabel(/Total da fatura segundo o banco/).fill("360,00");
  await dialogo().getByRole("button", { name: "Salvar" }).click();
  await esperarFechar();
  await esperarTexto(".alerta-aviso", "diferença");
  ok((await texto(".alerta-aviso")).includes("+R$ 10,00") && (await texto(".alerta-aviso")).includes("não é ajustada sozinha"), "conferência mostra a diferença com o banco sem ajustar sozinha");
  await p.screenshot({ path: CAPTURAS + "12-fatura.png", fullPage: true });
  const [csv] = await Promise.all([p.waitForEvent("download"), p.getByRole("button", { name: "Exportar (CSV)" }).click()]);
  const conteudoCsv = readFileSync(await csv.path(), "utf8");
  ok(conteudoCsv.includes("DATA;DESCRIÇÃO;PARCELA;VALOR") && conteudoCsv.includes(";1/10;100,00") && conteudoCsv.includes("-20,00"), "exportação com as 4 colunas DATA | DESCRIÇÃO | PARCELA | VALOR");

  // contas a pagar: a fatura aparece uma vez, sem editar à mão
  await p.getByRole("link", { name: "A pagar" }).first().click();
  await p.getByRole("button", { name: "Próximo mês" }).click();
  await p.locator("tbody tr", { hasText: "Fatura Nubank Ana 11/2026" }).waitFor();
  const linhaFat = p.locator("tbody tr", { hasText: "Fatura Nubank Ana 11/2026" });
  ok((await linhaFat.innerText()).includes("R$ 350,00"), "a fatura vira uma conta a pagar com o total da fatura");
  ok((await linhaFat.getByRole("button", { name: "Editar" }).count()) === 0 && (await linhaFat.getByRole("link", { name: "Ver fatura" }).count()) === 1, "conta a pagar da fatura não é editada à mão; leva à fatura");
  ok((await p.locator("tbody tr", { hasText: "Televisão" }).count()) === 0, "parcelas não viram contas a pagar separadas");
  await p.getByRole("button", { name: "Mês anterior" }).click();


  // ============================================================ importação de extrato (Etapa 5, parte 1)
  const hojeSP = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date()).replace(/-/g, "");
  const ofx = `OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\nCHARSET:1252\n\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>BRL
<BANKACCTFROM><BANKID>0341<ACCTID>1234-5</BANKACCTFROM><BANKTRANLIST><DTSTART>20260930<DTEND>${hojeSP}
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260930<TRNAMT>-10.00<FITID>T4<MEMO>TARIFA</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261003<TRNAMT>-45.00<FITID>T1<MEMO>PADARIA BOM PAO</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261010<TRNAMT>-100.00<FITID>T2<MEMO>DEBITO INTERNET</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261011<TRNAMT>1500.00<FITID>T3<MEMO>PIX RECEBIDO MARIA</STMTTRN>
</BANKTRANLIST><LEDGERBAL><BALAMT>3930.00<DTASOF>${hojeSP}</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;
  await p.getByRole("link", { name: "Saldos" }).first().click();
  await p.locator(".cartao-conta").filter({ has: p.locator("strong", { hasText: /^Itaú$/ }) }).click();
  await p.getByRole("link", { name: "Importar extrato" }).click();
  await p.getByRole("heading", { name: "Importar extrato" }).waitFor();
  await p.getByLabel("Arquivo do extrato (OFX ou CSV)").setInputFiles({ name: "itau-outubro.ofx", mimeType: "application/x-ofx", buffer: Buffer.from(ofx, "latin1") });
  await p.getByRole("button", { name: "Ver prévia" }).waitFor();
  ok((await texto(".importar-passo:has(h2)")).includes("4 lançamento(s) lido(s)"), "OFX lido: 4 lançamentos");
  ok((await texto("main")).includes("Saldo informado no arquivo"), "OFX: saldo informado pelo banco lido");
  await p.getByRole("button", { name: "Ver prévia" }).click();
  await p.locator("table.previa").waitFor();
  ok(srv.log.some((l) => l.startsWith("storage-envio:")), "arquivo original guardado no Storage antes da prévia");
  const resumoPrevia = await texto(".totais");
  ok(resumoPrevia.includes("2 de 4") && resumoPrevia.includes("Possível duplicado: 1") && resumoPrevia.includes("Antes do saldo inicial: 1"),
    "prévia: 2 novos; o débito de internet lançado à mão vira possível duplicado; a tarifa é anterior ao saldo inicial", resumoPrevia);
  const linhaPrevia = (d) => p.locator("table.previa tbody tr").filter({ has: p.locator(`input[value="${d}"]`) });
  ok((await linhaPrevia("DEBITO INTERNET").innerText()).includes("Parecido com: Débito internet"), "possível duplicado mostra o lançamento parecido");
  await linhaPrevia("PADARIA BOM PAO").getByLabel("Categoria").selectOption({ label: "Alimentação" });
  await p.screenshot({ path: CAPTURAS + "16-importar-previa.png", fullPage: true });
  await p.getByRole("button", { name: "Importar 2 lançamento(s)" }).click();
  await p.getByRole("heading", { name: "Importação concluída" }).waitFor();
  ok((await texto("main")).includes("2 lançamento(s) importado(s)"), "importação concluída: 2 lançamentos");
  await esperarTexto(".lista-simples", "Saldo confere");
  ok((await texto(".lista-simples")).includes("Saldo confere com o banco"), "conferência: saldo do arquivo confere com o saldo calculado");
  await p.getByRole("link", { name: "Ver extrato da conta" }).click();
  await esperarTexto(".resumo-conta .valor-destaque", "3.930,00");
  ok((await texto(".resumo-conta .valor-destaque")) === "R$ 3.930,00", "saldo do Itaú: R$ 2.475 − 45 + 1.500 = R$ 3.930,00", await texto(".resumo-conta .valor-destaque"));
  ok((await texto("tr:has-text('PADARIA BOM PAO')")).includes("Alimentação") && (await texto("tr:has-text('PADARIA BOM PAO')")).includes("Importado"), "lançamento importado com a categoria escolhida e a marca de importado");

  // o mesmo arquivo de novo
  await p.getByRole("link", { name: "Importar extrato" }).click();
  await p.getByLabel("Arquivo do extrato (OFX ou CSV)").setInputFiles({ name: "itau-outubro-copia.ofx", mimeType: "application/x-ofx", buffer: Buffer.from(ofx, "latin1") });
  await p.getByRole("button", { name: "Ver prévia" }).click();
  await p.locator(".importar-passo .alerta-erro").waitFor();
  ok((await texto(".importar-passo .alerta-erro")).includes("já foi importado"), "o mesmo arquivo não é importado duas vezes");

  // CSV sobreposto: o mapeamento é pedido; o que já entrou não se repete
  const csvExtrato = "Data;Histórico;Valor\n03/10/2026;PADARIA BOM PAO;-45,00\n12/10/2026;MERCADO;-30,00\n";
  await p.getByLabel("Arquivo do extrato (OFX ou CSV)").setInputFiles({ name: "itau.csv", mimeType: "text/csv", buffer: Buffer.from(csvExtrato, "utf8") });
  await p.getByRole("heading", { name: "Quais colunas são o quê?" }).waitFor();
  ok((await p.getByLabel("Descrição", { exact: true }).locator("option:checked").innerText()).includes("Histórico"), "CSV: colunas sugeridas pelo cabeçalho");
  await p.getByRole("button", { name: "Ver prévia" }).click();
  await p.locator("table.previa").waitFor();
  ok((await texto(".totais")).includes("1 de 2") && (await linhaPrevia("PADARIA BOM PAO").innerText()).includes("Possível duplicado"),
    "CSV sobreposto: a padaria já importada fica de fora; só o mercado entra");
  await p.getByRole("button", { name: "Importar 1 lançamento(s)" }).click();
  await p.getByRole("heading", { name: "Importação concluída" }).waitFor();
  await p.locator(".lista-simples li", { hasText: "itau.csv" }).waitFor();
  ok((await texto(".lista-simples")).includes("período sobreposto"), "histórico avisa o período sobreposto");
  await p.locator(".lista-simples li", { hasText: "itau.csv" }).getByRole("button", { name: "Desfazer" }).click();
  await dialogo().getByLabel("Motivo").fill("arquivo errado");
  await dialogo().getByRole("button", { name: "Desfazer" }).click();
  await esperarFechar();
  await esperarTexto(".lista-simples", "Desfeita: arquivo errado");
  ok((await texto(".lista-simples")).includes("Desfeita: arquivo errado"), "importação desfeita fica no histórico com o motivo");
  ok((await saldoItau()) === "R$ 3.930,00", "desfazer tira o mercado do saldo (R$ 3.930,00)", await saldoItau());

  // ============================================================ sessão: renovação do token
  await p.evaluate(() => {
    const s = JSON.parse(localStorage.getItem("simplifica-v2.sessao"));
    s.expira_em = Date.now() - 1000;
    localStorage.setItem("simplifica-v2.sessao", JSON.stringify(s));
  });
  await p.goto(srv.base + "/#/saldos");
  await p.reload();
  await p.locator(".consolidado-valor").waitFor();
  ok(srv.log.includes("renovou-token"), "sessão expirada é renovada sem pedir login");

  // ============================================================ exportação LGPD
  await p.getByRole("link", { name: "Minha conta" }).first().click();
  const [download] = await Promise.all([p.waitForEvent("download"), p.getByRole("button", { name: "Baixar meus dados" }).click()]);
  const exportado = JSON.parse(readFileSync(await download.path(), "utf8"));
  ok(exportado.movimentos?.length === 14 && exportado.contas?.length === 6 && exportado.importacoes?.length === 2, "exportação traz contas e lançamentos", `${exportado.movimentos?.length} mov, ${exportado.contas?.length} contas`);
  ok(exportado.contas_a_pagar?.length >= 4 && exportado.pagamentos?.length === 4 && exportado.recorrencias?.length === 1, "exportação traz contas a pagar, pagamentos e recorrências",
    `${exportado.contas_a_pagar?.length} contas a pagar, ${exportado.pagamentos?.length} pagamentos, ${exportado.recorrencias?.length} recorrências`);
  ok(exportado.cartoes?.length === 1 && exportado.compras_cartao?.length === 3 && exportado.parcelas?.length === 12, "exportação traz cartões, compras e parcelas",
    `${exportado.cartoes?.length} cartões, ${exportado.compras_cartao?.length} compras, ${exportado.parcelas?.length} parcelas`);

  // ============================================================ isolamento: outro usuário
  const ctx2 = await navegador.newContext({ viewport: { width: 390, height: 844 }, locale: "pt-BR", timezoneId: "America/Sao_Paulo" });
  const p2 = await ctx2.newPage();
  p2.on("pageerror", (e) => errosJs.push(String(e)));
  await p2.goto(srv.base + "/#/criar-conta");
  await p2.getByLabel("Seu nome").fill("Bruno");
  await p2.getByLabel("E-mail").fill("bruno@teste.com");
  await p2.getByLabel("Senha", { exact: true }).fill("senha-bruno-123");
  await p2.getByLabel("Repita a senha").fill("senha-bruno-123");
  await p2.getByRole("button", { name: "Criar conta" }).click();
  await p2.getByRole("heading", { name: "Confirme seu e-mail" }).waitFor();
  srv.confirmar("bruno@teste.com");
  await p2.goto(srv.base + "/#/entrar");
  await p2.getByLabel("E-mail").fill("bruno@teste.com");
  await p2.getByLabel("Senha").fill("senha-bruno-123");
  await p2.getByRole("button", { name: "Entrar" }).click();
  await p2.getByRole("heading", { name: "Cadastre sua primeira conta" }).waitFor();
  ok(true, "segundo usuário entra e não vê as contas do primeiro");
  await p2.screenshot({ path: CAPTURAS + "06-celular-vazio.png" });
  await p2.goto(`${srv.base}/#/conta/${idSantander}`);
  await p2.getByText("Conta não encontrada").waitFor();
  ok(true, "segundo usuário não abre o extrato da conta do primeiro pelo endereço");

  // celular com dados (Ana)
  const ctx3 = await navegador.newContext({ viewport: { width: 390, height: 844 }, locale: "pt-BR", timezoneId: "America/Sao_Paulo" });
  const p3 = await ctx3.newPage();
  await p3.goto(srv.base + "/#/entrar");
  await p3.getByLabel("E-mail").fill("ana@teste.com");
  await p3.getByLabel("Senha").fill("senha-ana-123");
  await p3.getByRole("button", { name: "Entrar" }).click();
  await p3.locator(".consolidado-valor").waitFor();
  const larguraOk = await p3.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  ok(larguraOk, "no celular a página não rola para o lado");
  await p3.screenshot({ path: CAPTURAS + "07-celular-saldos.png", fullPage: true });
  await p3.locator(".cartao-conta", { hasText: "Santander" }).click();
  await p3.locator(".resumo-conta").waitFor();
  await p3.screenshot({ path: CAPTURAS + "08-celular-extrato.png", fullPage: true });
  await p3.getByRole("link", { name: "A pagar" }).click();
  await p3.locator(".totais").waitFor();
  await p3.locator("tbody tr").first().waitFor();
  ok(await p3.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "contas a pagar no celular não rolam para o lado");
  await p3.screenshot({ path: CAPTURAS + "11-celular-contas-a-pagar.png", fullPage: true });
  await p3.getByRole("link", { name: "Cartões" }).click();
  await p3.locator(".cartao-conta").first().click();
  await p3.locator("tbody tr").first().waitFor();
  ok(await p3.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "fatura do cartão no celular não rola para o lado");
  await p3.screenshot({ path: CAPTURAS + "15-celular-fatura.png", fullPage: true });
  await ctx3.close();

  // ============================================================ exclusão de conta (Ana)
  await p.getByRole("button", { name: "Excluir minha conta" }).click();
  await dialogo().getByLabel("E-mail da conta").fill("bruno@teste.com");
  await dialogo().getByRole("button", { name: "Excluir definitivamente" }).click();
  ok((await dialogo().innerText()).includes("Digite exatamente o e-mail"), "exclusão com e-mail errado é recusada");
  await dialogo().getByLabel("E-mail da conta").fill("ana@teste.com");
  await dialogo().getByRole("button", { name: "Excluir definitivamente" }).click();
  await p.getByText("Sua conta foi excluída").waitFor({ timeout: 20000 });
  ok(true, "exclusão concluída volta para a tela de entrar com aviso");
  await p.getByLabel("E-mail").fill("ana@teste.com");
  await p.getByLabel("Senha").fill("senha-ana-123");
  await p.getByRole("button", { name: "Entrar" }).click();
  await p.locator("[role=alert]").waitFor();
  ok((await texto("[role=alert]")).includes("incorretos"), "conta excluída não entra mais");
  const resto = execFileSync("psql", [...PSQL, "-d", DB, "-tAc", `select (select count(*) from public.movimentos where user_id = '${idAna}') + (select count(*) from public.contas where user_id = '${idAna}') + (select count(*) from public.obrigacoes where user_id = '${idAna}') + (select count(*) from public.pagamentos where user_id = '${idAna}') + (select count(*) from public.recorrencias where user_id = '${idAna}') + (select count(*) from public.cartoes where user_id = '${idAna}') + (select count(*) from public.compras where user_id = '${idAna}') + (select count(*) from public.parcelas where user_id = '${idAna}') + (select count(*) from public.faturas where user_id = '${idAna}') + (select count(*) from public.importacoes where user_id = '${idAna}')`], { encoding: "utf8" }).trim();
  ok(resto === "0", "contas, lançamentos e contas a pagar da conta excluída removidos do banco");
  await p2.goto(srv.base + "/#/saldos");
  await p2.reload();
  await p2.getByRole("heading", { name: "Cadastre sua primeira conta" }).waitFor();
  ok(true, "segundo usuário continua usando normalmente");
  await ctx2.close();

  ok(errosJs.length === 0, "nenhum erro de JavaScript no navegador", errosJs.join(" | "));
} catch (e) {
  falhas++;
  console.log(`FALHOU: execução interrompida — ${String(e.message ?? e).split("\n")[0]}`);
  if (errosJs.length) console.log(`   erros no navegador: ${errosJs.join(" | ").slice(0, 600)}`);
  try { await p.screenshot({ path: CAPTURAS + "erro.png", fullPage: true }); } catch {}
} finally {
  await navegador.close();
  await srv.fechar();
}
console.log(falhas === 0 ? `== Site (navegador): ${oks} verificações aprovadas ==` : `== Site (navegador): ${falhas} FALHA(S), ${oks} OK ==`);
process.exit(falhas === 0 ? 0 : 1);
