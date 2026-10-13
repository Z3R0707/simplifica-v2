// Teste da página de validação (02_validar_exclusao_no_navegador.html) num
// navegador real (Chromium/Playwright) contra um servidor que simula as APIs
// do Supabase executando o SQL REAL das migrações num PostgreSQL local, e a
// Edge Function excluir-conta real.
import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { criarSimulador, sql, CHAVES } from "../edge/supabase_simulado.mjs";
import { tratar as excluirConta } from "../../functions/excluir-conta/index.ts";

console.error = () => {};
const DB = process.env.TEST_DB ?? "simplifica_teste_local";
const q = (c) => sql(DB, c);
const raiz = fileURLToPath(new URL("../../../", import.meta.url));
const pagina = readFileSync(raiz + "validacao/02_validar_exclusao_no_navegador.html", "utf8");

const senhas = new Map();
const idA = q(`select teste.novo_usuario('gabi@exemplo.com', 'Gabi')`);
const idB = q(`select teste.novo_usuario('heitor@exemplo.com', 'Heitor')`);
senhas.set("gabi@exemplo.com", "senha-a-123"); senhas.set("heitor@exemplo.com", "senha-b-123");

const lit = (s) => `$v$${String(s).replace(/\$v\$/g, "")}$v$`;
const comoUsuario = (uid) => `set role authenticated; set "request.jwt.claim.sub" = '${uid}'; set "request.jwt.claims" = '{"sub":"${uid}","role":"authenticated"}';`;

let base = "";
const sim = criarSimulador(DB);
const env = () => ({ SUPABASE_URL: base, SUPABASE_ANON_KEY: CHAVES.ANON, SUPABASE_SERVICE_ROLE_KEY: CHAVES.SERVICE });

const servidor = http.createServer(async (req, res) => {
  const corpo = await new Promise((ok) => { let d = ""; req.on("data", (c) => d += c); req.on("end", () => ok(d)); });
  const u = new URL(req.url, base);
  const token = (req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
  const uid = token.startsWith("usuario:") ? token.slice(8).replace(/[^0-9a-f-]/g, "") : null;
  const enviar = (status, dados, tipo = "application/json") => {
    res.writeHead(status, { "Content-Type": tipo });
    res.end(typeof dados === "string" && tipo !== "application/json" ? dados : JSON.stringify(dados));
  };
  try {
    if (u.pathname === "/" ) return enviar(200, pagina, "text/html; charset=utf-8");
    if (u.pathname === "/auth/v1/token") {
      const { email, password } = JSON.parse(corpo);
      const id = q(`select id from auth.users where email = ${lit(email)}`);
      if (!id || senhas.get(email) !== password) return enviar(400, { error: "invalid_grant", error_description: "Invalid login credentials" });
      return enviar(200, { access_token: `usuario:${id}`, user: { id, email } });
    }
    const tabela = u.pathname.match(/^\/rest\/v1\/([a-z_]+)$/);
    if (tabela) {
      if (req.method === "GET") {
        try { return enviar(200, JSON.parse(q(`${comoUsuario(uid)} select coalesce(json_agg(t), '[]') from public.${tabela[1]} t`))); }
        catch (e) { return enviar(e.code === "42501" ? 403 : 400, { code: e.code, message: e.message }); }
      }
      if (req.method === "PATCH") {
        try { q(`${comoUsuario(uid)} update public.${tabela[1]} set nome = 'x' where id = '${u.searchParams.get("id")?.slice(3)}'`); return enviar(204, ""); }
        catch (e) { return enviar(e.code === "42501" ? 403 : 400, { code: e.code, message: e.message }); }
      }
    }
    if (u.pathname.startsWith("/rest/v1/rpc/") || u.pathname === "/auth/v1/user" || (u.pathname === "/storage/v1/object/documentos" && token === CHAVES.SERVICE)) {
      const r = await sim.fetch(base + u.pathname + u.search, { method: req.method, headers: req.headers, body: corpo || undefined });
      const t = await r.text();
      return enviar(r.status, t ? JSON.parse(t) : null);
    }
    if (u.pathname === "/storage/v1/object/documentos" && req.method === "DELETE") {
      const nomes = JSON.parse(corpo).prefixes.map(lit).join(",");
      return enviar(200, JSON.parse(q(`${comoUsuario(uid)} with d as (delete from storage.objects where bucket_id = 'documentos' and name = any(array[${nomes}]) returning name) select coalesce(json_agg(json_build_object('name', name)), '[]') from d`)));
    }
    if (u.pathname === "/storage/v1/object/list/documentos") {
      const { prefix } = JSON.parse(corpo);
      const nomes = JSON.parse(q(`${comoUsuario(uid)} select coalesce(json_agg(name), '[]') from storage.objects where bucket_id = 'documentos' and name like ${lit(prefix)} || '%'`));
      const itens = new Map();
      for (const n of nomes) {
        const resto = n.slice(prefix.length); const seg = resto.split("/")[0];
        itens.set(seg, resto.includes("/") ? { name: seg, id: null } : { name: seg, id: "obj" });
      }
      return enviar(200, [...itens.values()]);
    }
    const obj = u.pathname.match(/^\/storage\/v1\/object\/(authenticated\/)?documentos\/(.+)$/);
    if (obj && req.method === "POST") {
      try { q(`${comoUsuario(uid)} insert into storage.objects (bucket_id, name) values ('documentos', ${lit(decodeURIComponent(obj[2]))})`); return enviar(200, { Key: "documentos/" + obj[2] }); }
      catch (e) { return enviar(400, { statusCode: "403", error: "Unauthorized", message: "new row violates row-level security policy" }); }
    }
    if (obj && req.method === "GET") {
      const existe = q(`${comoUsuario(uid)} select count(*) from storage.objects where bucket_id = 'documentos' and name = ${lit(decodeURIComponent(obj[2]))}`);
      return existe === "1" ? enviar(200, "conteúdo", "text/plain") : enviar(400, { statusCode: "404", error: "not_found" });
    }
    if (u.pathname === "/functions/v1/excluir-conta") {
      const r = await excluirConta(new Request(base + u.pathname, { method: req.method, headers: req.headers, body: corpo || undefined }), env(), sim.fetch);
      return enviar(r.status, await r.json());
    }
    return enviar(404, { erro: "rota não simulada", rota: u.pathname });
  } catch (e) {
    return enviar(500, { erro: String(e) });
  }
});
await new Promise((ok) => servidor.listen(0, "127.0.0.1", ok));
base = `http://127.0.0.1:${servidor.address().port}`;

const { chromium } = await import("/opt/node22/lib/node_modules/playwright/index.mjs");
const navegador = await chromium.launch();
const aba = await navegador.newPage();
aba.on("dialog", (d) => d.accept());
await aba.goto(base + "/");
await aba.fill("#url", base);
await aba.fill("#chave", CHAVES.ANON);
await aba.fill("#ea", "gabi@exemplo.com"); await aba.fill("#sa", "senha-a-123");
await aba.fill("#eb", "heitor@exemplo.com"); await aba.fill("#sb", "senha-b-123");
await aba.click("#ir");
await aba.waitForFunction(() => /^VALIDAÇÃO/.test(document.getElementById("resumo").textContent), null, { timeout: 60000 });
const resumo = await aba.textContent("#resumo");
const itens = await aba.$$eval("#res li", (lis) => lis.map((l) => `${l.className === "ok" ? "  OK:" : "FALHOU:"} ${l.innerText.replace(/\n/g, " — ").replace(/^[✓✗]\s*(—\s*)?/, "")}`));
await aba.screenshot({ path: raiz + "docs/evidencia-pagina-validacao.png", fullPage: true });
await navegador.close();
servidor.close();

console.log(itens.join("\n"));
const restantes = q(`select count(*) from storage.objects where name like '${idA}/%'`);
const login = q(`select count(*) from auth.users where id = '${idA}'`);
const okBanco = restantes === "0" && login === "0";
console.log(okBanco ? "  OK: banco confirma: 0 arquivos e login removido" : `FALHOU: banco: ${restantes} arquivos, ${login} login`);
console.log(`== Página de validação: ${resumo} ==`);
process.exit(/APROVADA/.test(resumo) && okBanco ? 0 : 1);
