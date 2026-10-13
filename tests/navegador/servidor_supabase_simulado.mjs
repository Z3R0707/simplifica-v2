// Servidor local que imita o Supabase (Auth, PostgREST, Edge Function
// excluir-conta) usando o SQL REAL das migrações num PostgreSQL local, e
// que também serve o site montado em dist/. Usado só nos testes.
import http from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { criarSimulador, sql, CHAVES } from "../../supabase/tests/edge/supabase_simulado.mjs";
import { tratar as excluirConta } from "../../supabase/functions/excluir-conta/index.ts";

const TIPOS = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".txt": "text/plain" };

export function iniciarServidor({ db, porta, dist }) {
  const senhas = new Map();      // e-mail → senha
  const confirmados = new Set(); // ids confirmados
  const log = [];
  const sim = criarSimulador(db);
  const base = `http://127.0.0.1:${porta}`;
  const lit = (s) => `$v$${String(s).replace(/\$v\$/g, "")}$v$`;
  const comoUsuario = (uid) => `set role authenticated; set "request.jwt.claim.sub" = '${uid}'; set "request.jwt.claims" = '{"sub":"${uid}","role":"authenticated"}';`;
  const uidDoToken = (auth) => {
    const t = (auth ?? "").replace(/^Bearer\s+/i, "");
    return t.startsWith("usuario:") ? t.slice(8).replace(/[^0-9a-f-]/g, "") : null;
  };
  const sessao = (id, email) => ({ access_token: `usuario:${id}`, refresh_token: `refresh:${id}`, expires_in: 3600, token_type: "bearer", user: { id, email } });

  const servidor = http.createServer(async (req, res) => {
    const corpoTexto = await new Promise((ok) => { let d = ""; req.on("data", (c) => (d += c)); req.on("end", () => ok(d)); });
    const u = new URL(req.url, base);
    log.push(`${req.method} ${u.pathname}`);
    const enviar = (status, dados) => {
      res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(dados === undefined ? "" : JSON.stringify(dados));
    };
    try {
      if (req.method === "OPTIONS") {
        res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "*" });
        return res.end();
      }
      const corpo = corpoTexto ? JSON.parse(corpoTexto) : {};

      // ------------------------------------------------------------ Auth
      if (u.pathname === "/auth/v1/signup") {
        const email = String(corpo.email).toLowerCase();
        const existente = sql(db, `select id from auth.users where lower(email) = ${lit(email)}`);
        if (existente) return enviar(200, { id: "00000000-0000-0000-0000-000000000000", email }); // Supabase não revela
        const id = sql(db, `insert into auth.users (email, raw_user_meta_data) values (${lit(email)}, ${lit(JSON.stringify(corpo.data ?? {}))}::jsonb) returning id`);
        senhas.set(email, corpo.password);
        return enviar(200, { id, email, confirmation_sent_at: new Date().toISOString() });
      }
      if (u.pathname === "/auth/v1/token") {
        const tipo = u.searchParams.get("grant_type");
        if (tipo === "password") {
          const email = String(corpo.email).toLowerCase();
          const id = sql(db, `select id from auth.users where lower(email) = ${lit(email)}`);
          if (!id || senhas.get(email) !== corpo.password) return enviar(400, { code: 400, error_code: "invalid_credentials", msg: "Invalid login credentials" });
          if (!confirmados.has(id)) return enviar(400, { code: 400, error_code: "email_not_confirmed", msg: "Email not confirmed" });
          return enviar(200, sessao(id, email));
        }
        if (tipo === "refresh_token") {
          const id = String(corpo.refresh_token ?? "").replace(/^refresh:/, "").replace(/[^0-9a-f-]/g, "");
          const email = id && sql(db, `select email from auth.users where id = '${id}'`);
          if (!email) return enviar(400, { code: 400, error_code: "refresh_token_not_found", msg: "Invalid Refresh Token" });
          log.push("renovou-token");
          return enviar(200, sessao(id, email));
        }
      }
      if (u.pathname === "/auth/v1/recover") return enviar(200, {});
      if (u.pathname === "/auth/v1/logout") return enviar(204);
      if (u.pathname === "/auth/v1/user" && req.method === "PUT") {
        const uid = uidDoToken(req.headers.authorization);
        const email = uid && sql(db, `select email from auth.users where id = '${uid}'`);
        if (!email) return enviar(401, { code: 401, error_code: "bad_jwt", msg: "invalid JWT" });
        senhas.set(email, corpo.password);
        return enviar(200, { id: uid, email });
      }
      if (u.pathname === "/auth/v1/user") {
        const r = await sim.fetch(base + u.pathname, { method: "GET", headers: req.headers });
        return enviar(r.status, JSON.parse((await r.text()) || "null"));
      }

      // ------------------------------------------------------------ PostgREST
      if (u.pathname.startsWith("/rest/v1/rpc/")) {
        const r = await sim.fetch(base + u.pathname, { method: "POST", headers: req.headers, body: corpoTexto || "{}" });
        const t = await r.text();
        return enviar(r.status, t ? JSON.parse(t) : null);
      }
      const tabela = /^\/rest\/v1\/([a-z_]+)$/.exec(u.pathname);
      if (tabela && req.method === "GET") {
        const uid = uidDoToken(req.headers.authorization);
        const filtros = [];
        for (const [k, v] of u.searchParams) {
          if (k === "select" || k === "order") continue;
          if (!/^[a-z_]+$/.test(k) || !v.startsWith("eq.")) return enviar(400, { code: "PGRST100", message: "filtro não suportado no simulador" });
          filtros.push(`${k}::text = ${lit(v.slice(3))}`);
        }
        try {
          const papel = uid ? comoUsuario(uid) : "set role anon;";
          const saida = sql(db, `${papel} select coalesce(json_agg(t), '[]') from public.${tabela[1]} t${filtros.length ? " where " + filtros.join(" and ") : ""}`);
          return enviar(200, JSON.parse(saida));
        } catch (e) {
          return enviar(e.code === "42501" ? (uid ? 403 : 401) : 400, { code: e.code, message: e.message });
        }
      }

      // ------------------------------------------------------------ Edge Function
      if (u.pathname === "/functions/v1/excluir-conta") {
        const r = await excluirConta(new Request(base + u.pathname, { method: req.method, headers: req.headers, body: corpoTexto || undefined }),
          { SUPABASE_URL: base, SUPABASE_ANON_KEY: CHAVES.ANON, SUPABASE_SERVICE_ROLE_KEY: CHAVES.SERVICE }, sim.fetch);
        return enviar(r.status, await r.json());
      }

      // ------------------------------------------------------------ site
      if (req.method === "GET") {
        const caminho = normalize(join(dist, u.pathname === "/" ? "index.html" : u.pathname));
        if (caminho.startsWith(dist) && existsSync(caminho) && statSync(caminho).isFile()) {
          // Mesma política de segurança do netlify.toml (o Supabase local é a própria origem)
          const csp = readFileSync(join(dist, "..", "netlify.toml"), "utf8").match(/Content-Security-Policy = "([^"]+)"/)[1]
            .replace("https://*.supabase.co", "'self'");
          res.writeHead(200, { "Content-Type": TIPOS[extname(caminho)] ?? "application/octet-stream", "Content-Security-Policy": csp });
          return res.end(readFileSync(caminho));
        }
      }
      return enviar(404, { erro: "rota não simulada", rota: u.pathname });
    } catch (e) {
      return enviar(500, { erro: String(e) });
    }
  });

  return new Promise((ok) => servidor.listen(porta, "127.0.0.1", () => ok({
    base, log, servidor,
    confirmar: (email) => {
      const id = sql(db, `select id from auth.users where lower(email) = ${lit(email.toLowerCase())}`);
      confirmados.add(id);
      return id;
    },
    fechar: () => new Promise((f) => servidor.close(f)),
  })));
}
