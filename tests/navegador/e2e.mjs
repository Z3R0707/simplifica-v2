// Teste de ponta a ponta do site, num Chromium real, contra o Supabase
// simulado que executa o SQL REAL das migrações (etapas 1 e 2).
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
for (const f of ["0001_fundacao_infra.sql", "0002_fundacao_cadastros.sql", "0003_fundacao_lgpd_storage.sql", "0004_etapa2_movimentos_saldos.sql"]) {
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
  ok(exportado.movimentos?.length === 6 && exportado.contas?.length === 6, "exportação traz contas e lançamentos", `${exportado.movimentos?.length} mov, ${exportado.contas?.length} contas`);

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
  const resto = execFileSync("psql", [...PSQL, "-d", DB, "-tAc", `select (select count(*) from public.movimentos where user_id = '${idAna}') + (select count(*) from public.contas where user_id = '${idAna}')`], { encoding: "utf8" }).trim();
  ok(resto === "0", "contas e lançamentos da conta excluída removidos do banco");
  await p2.goto(srv.base + "/#/saldos");
  await p2.reload();
  await p2.getByRole("heading", { name: "Cadastre sua primeira conta" }).waitFor();
  ok(true, "segundo usuário continua usando normalmente");
  await ctx2.close();

  ok(errosJs.length === 0, "nenhum erro de JavaScript no navegador", errosJs.join(" | "));
} catch (e) {
  falhas++;
  console.log(`FALHOU: execução interrompida — ${String(e.message ?? e).split("\n")[0]}`);
  try { await p.screenshot({ path: CAPTURAS + "erro.png", fullPage: true }); } catch {}
} finally {
  await navegador.close();
  await srv.fechar();
}
console.log(falhas === 0 ? `== Site (navegador): ${oks} verificações aprovadas ==` : `== Site (navegador): ${falhas} FALHA(S), ${oks} OK ==`);
process.exit(falhas === 0 ? 0 : 1);
