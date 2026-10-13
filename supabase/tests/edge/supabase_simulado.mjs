// Simulação local das APIs do Supabase usadas pelas Edge Functions
// (Auth /user, PostgREST /rpc, Storage DELETE), executando o SQL REAL das
// migrações num PostgreSQL local. Usada apenas nos testes.
import { execFileSync } from "node:child_process";

const PG = ["-h", process.env.PGHOST ?? "/tmp", "-p", process.env.PGPORT ?? "5433", "-U", process.env.PGUSER ?? "postgres"];
export const CHAVES = { ANON: "chave-anon-teste", SERVICE: "chave-service-teste" };

export function sql(db, comando) {
  try {
    return execFileSync("psql", [...PG, "-d", db, "-tAq", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose", "-c", comando],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (e) {
    const msg = String(e.stderr ?? e.message);
    const m = msg.match(/ERROR:\s+([0-9A-Z]{5}):\s+([^\n]*)/);
    const erro = new Error(m ? m[2] : msg);
    erro.code = m ? m[1] : "XX000";
    throw erro;
  }
}

function literal(v) {
  if (v === null || v === undefined) return "NULL";
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  // como o PostgREST: lista JSON vira array do PostgreSQL
  // (lista de objetos ou objeto = parâmetro jsonb; lista simples = array, como int[])
  const s = Array.isArray(v) && v.every((x) => typeof x !== "object" || x === null)
    ? `{${v.map((x) => (typeof x === "number" ? String(x) : `"${String(x).replace(/["\\]/g, "")}"`)).join(",")}}`
    : typeof v === "object" ? JSON.stringify(v) : String(v);
  if (s.includes("$v$")) throw new Error("valor inválido para o simulador");
  return `$v$${s}$v$`;
}

const FUNCOES_SETOF = new Set(["exclusao_listar_arquivos", "storage_listar_orfaos", "saldos_por_conta", "saldo_consolidado", "extrato_conta", "resumo_categorias",
  "contas_a_pagar", "pagamentos_da_obrigacao", "movimentos_para_vincular", "contas_a_pagar_por_conta",
  "faturas_do_cartao", "lancamentos_da_fatura", "parcelas_da_compra", "cartoes_resumo", "fatura_prevista",
  "importacoes_da_conta", "importacao_itens_lista", "importacoes_fatura_do_cartao", "importacao_fatura_itens_lista"]);
const STATUS_POSTGREST = { "42501": 403, "P0002": 404, "40001": 409, "23505": 409 };

export function criarSimulador(db, opcoes = {}) {
  const estado = { chamadasStorage: 0, falharStorageNaChamada: opcoes.falharStorageNaChamada ?? 0, log: [] };

  function papel(authorization) {
    const token = (authorization ?? "").replace(/^Bearer\s+/i, "");
    if (token === CHAVES.SERVICE) return "set role service_role;";
    if (token.startsWith("usuario:")) {
      const uid = token.slice(8).replace(/[^0-9a-f-]/g, "");
      return `set role authenticated; set "request.jwt.claim.sub" = '${uid}'; set "request.jwt.claims" = '{"sub":"${uid}","role":"authenticated"}';`;
    }
    return "set role anon;";
  }

  const resp = (status, corpo) => new Response(corpo === undefined ? "" : JSON.stringify(corpo), { status });

  async function fetchSimulado(url, init = {}) {
    const u = new URL(url);
    const h = new Headers(init.headers ?? {});
    const metodo = init.method ?? "GET";
    estado.log.push(`${metodo} ${u.pathname}`);

    if (u.pathname === "/auth/v1/user") {
      const token = (h.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
      if (!token.startsWith("usuario:")) return resp(401, { msg: "invalid JWT" });
      const uid = token.slice(8).replace(/[^0-9a-f-]/g, "");
      const linha = sql(db, `select json_build_object('id', id, 'email', email) from auth.users where id = '${uid}'`);
      return linha ? resp(200, JSON.parse(linha)) : resp(401, { msg: "User from sub claim in JWT does not exist" });
    }

    const rpc = u.pathname.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/);
    if (rpc && metodo === "POST") {
      const nome = rpc[1];
      const args = JSON.parse(init.body ?? "{}");
      const lista = Object.entries(args).map(([k, v]) => `${k.replace(/[^a-z_]/g, "")} => ${literal(v)}`).join(", ");
      const consulta = FUNCOES_SETOF.has(nome)
        ? `select coalesce(json_agg(r), '[]') from public.${nome}(${lista}) r`
        : `select to_json(r) from public.${nome}(${lista}) r`;
      try {
        const saida = sql(db, `${papel(h.get("authorization"))} ${consulta}`);
        return resp(200, saida ? JSON.parse(saida) : null);
      } catch (e) {
        return resp(STATUS_POSTGREST[e.code] ?? 400, { code: e.code, message: e.message });
      }
    }

    const st = u.pathname.match(/^\/storage\/v1\/object\/([^/]+)$/);
    if (st && metodo === "DELETE") {
      estado.chamadasStorage++;
      if (h.get("authorization") !== `Bearer ${CHAVES.SERVICE}`) return resp(403, { error: "Unauthorized" });
      if (estado.chamadasStorage === estado.falharStorageNaChamada) return resp(500, { error: "falha simulada" });
      const bucket = decodeURIComponent(st[1]).replace(/'/g, "");
      const nomes = JSON.parse(init.body).prefixes;
      const arr = `array[${nomes.map(literal).join(",")}]::text[]`;
      const saida = sql(db, `with d as (delete from storage.objects where bucket_id = '${bucket}' and name = any(${arr}) returning name)
                             select coalesce(json_agg(json_build_object('name', name)), '[]') from d`);
      return resp(200, JSON.parse(saida));
    }
    return resp(404, { erro: "rota não simulada", rota: u.pathname });
  }

  return { fetch: fetchSimulado, estado };
}
