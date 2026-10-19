// Prazos da Edge Function excluir-conta: nenhuma chamada fica pendurada e,
// quando o tempo acaba, a falha é registrada antes de a função terminar.
import { test } from "node:test";
import assert from "node:assert/strict";
import { tratar } from "../../supabase/functions/excluir-conta/index.ts";

type Chamada = { url: string; corpo: unknown; comPrazo: boolean };

function supabaseFalso(opcoes: { storageTrava?: boolean; arquivos?: number } = {}) {
  const chamadas: Chamada[] = [];
  let arquivos = opcoes.arquivos ?? 0;
  const f = (async (entrada: string | URL | Request, init?: RequestInit) => {
    const url = String(entrada);
    const corpo = init?.body ? JSON.parse(String(init.body)) : null;
    chamadas.push({ url, corpo, comPrazo: init?.signal instanceof AbortSignal });
    const json = (dados: unknown, status = 200) => new Response(JSON.stringify(dados), { status });
    if (url.endsWith("/auth/v1/user")) return json({ id: "u1" });
    if (url.endsWith("/rpc/exclusao_solicitar")) return json({ status: "solicitada" });
    if (url.endsWith("/rpc/exclusao_listar_arquivos")) {
      return json(Array.from({ length: arquivos }, (_, i) => ({ bucket_id: "documentos", nome: `u1/a${i}.pdf` })));
    }
    if (url.includes("/storage/v1/object/")) {
      if (opcoes.storageTrava) {
        // nunca responde: só termina quando o prazo da chamada aborta
        return await new Promise<Response>((_, falha) => {
          init?.signal?.addEventListener("abort", () => falha(init.signal!.reason));
        });
      }
      const n = arquivos;
      arquivos = 0;
      return json(Array.from({ length: n }, () => ({})));
    }
    if (url.endsWith("/rpc/exclusao_concluir")) return json({ status: "concluida" });
    if (url.endsWith("/rpc/exclusao_registrar_falha")) return json(null);
    return json({ message: "rota desconhecida" }, 404);
  }) as typeof fetch;
  return { f, chamadas };
}

const pedido = () => new Request("http://fn.local/excluir-conta", {
  method: "POST",
  headers: { Authorization: "Bearer token", "Content-Type": "application/json" },
  body: JSON.stringify({ confirmacao_email: "eva@exemplo.com" }),
});
const env = { SUPABASE_URL: "http://supabase.local", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "svc" };

test("caminho normal: toda chamada tem prazo e a conclusão espera 20 s pelos uploads", async () => {
  const { f, chamadas } = supabaseFalso({ arquivos: 3 });
  const r = await tratar(pedido(), env, f);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { status: "concluida", arquivos_removidos: 3 });
  assert.ok(chamadas.every((c) => c.comPrazo), "alguma chamada saiu sem prazo");
  const concluir = chamadas.find((c) => c.url.endsWith("/rpc/exclusao_concluir"));
  assert.equal((concluir?.corpo as { p_espera_ms: number }).p_espera_ms, 20000);
});

test("Storage que não responde: a chamada é abortada e a falha fica registrada", async () => {
  const { f, chamadas } = supabaseFalso({ arquivos: 2, storageTrava: true });
  const inicio = Date.now();
  const r = await tratar(pedido(), { ...env, ORCAMENTO_MS: 30_000, PRAZO_CHAMADA_MS: 300 }, f);
  assert.ok(Date.now() - inicio < 5_000, "a função ficou pendurada");
  assert.equal(r.status, 503);
  const falha = chamadas.find((c) => c.url.endsWith("/rpc/exclusao_registrar_falha"));
  assert.ok(falha, "a falha não foi registrada");
  assert.match((falha.corpo as { p_erro: string }).p_erro, /^sem_resposta:/);
  assert.ok(!chamadas.some((c) => c.url.endsWith("/rpc/exclusao_concluir")), "não podia tentar concluir");
});

test("tempo insuficiente para esperar os uploads: não tenta concluir e registra a falha", async () => {
  const { f, chamadas } = supabaseFalso({ arquivos: 1 });
  const r = await tratar(pedido(), { ...env, ORCAMENTO_MS: 20_000 }, f);
  assert.equal(r.status, 503);
  assert.equal((await r.json()).erro, "tempo_esgotado");
  assert.ok(!chamadas.some((c) => c.url.endsWith("/rpc/exclusao_concluir")), "não podia tentar concluir");
  const falha = chamadas.find((c) => c.url.endsWith("/rpc/exclusao_registrar_falha"));
  assert.match((falha?.corpo as { p_erro: string }).p_erro, /^tempo_esgotado:/);
  assert.equal((falha?.corpo as { p_arquivos_removidos: number }).p_arquivos_removidos, 1);
});

test("orçamento apertado: a espera pelos uploads encolhe para caber", async () => {
  const { f, chamadas } = supabaseFalso();
  const r = await tratar(pedido(), { ...env, ORCAMENTO_MS: 45_000 }, f);
  assert.equal(r.status, 200);
  const espera = (chamadas.find((c) => c.url.endsWith("/rpc/exclusao_concluir"))?.corpo as { p_espera_ms: number }).p_espera_ms;
  assert.ok(espera >= 2_000 && espera <= 12_000, `espera fora do esperado: ${espera}`);
});
