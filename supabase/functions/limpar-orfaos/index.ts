// Edge Function: limpar-orfaos (manutenção)
// Encontra arquivos do bucket "documentos" cuja pasta raiz não pertence a
// nenhum usuário existente e, se pedido, remove-os pela API do Storage.
//
// Segurança: exige o cabeçalho x-segredo-manutencao igual ao segredo
// MANUTENCAO_SEGREDO configurado nas Edge Functions. Por padrão apenas
// LISTA (simulação); só remove com {"executar": true}.
//
// Arquivo único e sem dependências externas.

type Env = {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  MANUTENCAO_SEGREDO?: string;
};
type Fetch = typeof fetch;

const MAX_LOTES = 200;
const TAMANHO_LOTE = 1000;

function json(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

function iguaisTempoConstante(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function listarOrfaos(f: Fetch, env: Env): Promise<{ bucket_id: string; nome: string }[]> {
  const svc = env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/storage_listar_orfaos`, {
    method: "POST",
    headers: { "apikey": svc, "Authorization": `Bearer ${svc}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_limite: TAMANHO_LOTE }),
  });
  if (!r.ok) throw new Error(`listagem falhou (HTTP ${r.status})`);
  return await r.json();
}

async function apagar(f: Fetch, env: Env, bucket: string, nomes: string[]): Promise<number> {
  const svc = env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await f(`${env.SUPABASE_URL}/storage/v1/object/${encodeURIComponent(bucket)}`, {
    method: "DELETE",
    headers: { "apikey": svc, "Authorization": `Bearer ${svc}`, "Content-Type": "application/json" },
    body: JSON.stringify({ prefixes: nomes }),
  });
  if (!r.ok) throw new Error(`Storage recusou a remoção (HTTP ${r.status})`);
  const removidos = await r.json();
  return Array.isArray(removidos) ? removidos.length : 0;
}

export async function tratar(req: Request, env: Env, f: Fetch = fetch): Promise<Response> {
  if (req.method !== "POST") return json(405, { erro: "metodo_nao_permitido" });
  const segredo = req.headers.get("x-segredo-manutencao") ?? "";
  if (!env.MANUTENCAO_SEGREDO || env.MANUTENCAO_SEGREDO.length < 24 || !iguaisTempoConstante(segredo, env.MANUTENCAO_SEGREDO)) {
    return json(401, { erro: "nao_autorizado" });
  }
  let executar = false;
  try {
    const corpo = await req.json();
    executar = corpo?.executar === true;
  } catch { /* corpo vazio = simulação */ }

  try {
    if (!executar) {
      const orfaos = await listarOrfaos(f, env);
      return json(200, { simulacao: true, encontrados: orfaos.length, amostra: orfaos.slice(0, 50) });
    }
    let total = 0;
    for (let lote = 0; lote < MAX_LOTES; lote++) {
      const orfaos = await listarOrfaos(f, env);
      if (orfaos.length === 0) return json(200, { simulacao: false, removidos: total, restantes: 0 });
      const nomes = orfaos.filter((o) => o.bucket_id === "documentos").map((o) => o.nome);
      const n = await apagar(f, env, "documentos", nomes);
      if (n === 0) throw new Error("Storage não removeu nenhum arquivo do lote");
      total += n;
    }
    return json(202, { simulacao: false, removidos: total, mensagem: "Limite por execução atingido; chame novamente." });
  } catch (e) {
    console.error(JSON.stringify({ funcao: "limpar-orfaos", erro: String(e) }));
    return json(502, { erro: "falha_limpeza", mensagem: String((e as Error).message ?? e) });
  }
}

// Ponto de entrada no Supabase (Deno). Acessado por globalThis para não
// redeclarar o objeto global Deno (o que pode impedir a publicação) e para que
// o mesmo arquivo possa ser importado nos testes locais em Node.
type DenoMinimo = { serve: (h: (r: Request) => Promise<Response>) => void; env: { get: (k: string) => string | undefined } };
const denoRt = (globalThis as unknown as { Deno?: DenoMinimo }).Deno;
if (denoRt) {
  denoRt.serve((req) => tratar(req, {
    SUPABASE_URL: denoRt.env.get("SUPABASE_URL") ?? "",
    SUPABASE_SERVICE_ROLE_KEY: denoRt.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    MANUTENCAO_SEGREDO: denoRt.env.get("MANUTENCAO_SEGREDO"),
  }));
}
