// Edge Function: excluir-conta
// Exclui a conta do usuário autenticado SEM deixar arquivos órfãos.
//
//  1. Confere a sessão do usuário (token enviado pelo app).
//  2. Chama exclusao_solicitar como o próprio usuário: o banco confere o
//     e-mail (rejeita NULL, vazio e divergente) e bloqueia novas escritas
//     e novos envios de arquivos.
//  3. Lista os arquivos do usuário e apaga cada lote pela API do Storage,
//     até não restar nenhum.
//  4. Chama exclusao_concluir, que ESPERA uploads já iniciados terminarem,
//     RECUSA concluir se ainda existir arquivo e só então apaga dados e
//     login numa única transação. Recusa por upload tardio → volta ao 3.
//  5. Conferência final: remove qualquer arquivo que apareça depois.
//  Qualquer falha fica registrada e a exclusão pode ser retomada chamando
//  a função novamente.
//
//  Tempo: a Edge Function é encerrada pelo Supabase depois de 150 s (plano
//  gratuito). Cada chamada externa tem prazo próprio e a execução inteira
//  tem um orçamento menor que esse limite, com uma sobra reservada para
//  registrar a falha. Assim a exclusão nunca morre sem registro, parada em
//  "em andamento".
//
// Arquivo único e sem dependências externas, para poder ser colado no
// editor de Edge Functions do painel do Supabase.

type Env = {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ORIGENS_PERMITIDAS?: string; // ex.: "https://simplifica-v2.netlify.app,http://localhost:5173"
  ESPERA_ENTRE_TENTATIVAS_MS?: number;
  ORCAMENTO_MS?: number;       // só para testes; padrão ORCAMENTO_MS
  PRAZO_CHAMADA_MS?: number;   // só para testes; padrão PRAZO_CHAMADA_MS
};
type Fetch = typeof fetch;

const MAX_LOTES = 200;          // até 200 mil arquivos por execução
const TAMANHO_LOTE = 1000;      // limite da API do Storage por chamada
const MAX_TENTATIVAS_CONCLUSAO = 5;
const ESPERA_CONCLUSAO_MS = 20000; // quanto o banco espera uploads em andamento

const ORCAMENTO_MS = 120_000;       // execução inteira (o Supabase encerra em 150 s)
const PRAZO_CHAMADA_MS = 15_000;    // cada chamada ao Auth, ao Storage ou ao banco
const FOLGA_CONCLUSAO_MS = 25_000;  // além da espera: apagar os dados no banco
const RESERVA_REGISTRO_MS = 8_000;  // guardada para registrar a falha
const ESPERA_MINIMA_MS = 2_000;     // abaixo disso não vale tentar concluir

const esperar = (ms: number) => new Promise((ok) => setTimeout(ok, ms));

type Prazo = { restante: () => number };
function criarPrazo(totalMs: number): Prazo {
  const fim = Date.now() + totalMs;
  return { restante: () => fim - Date.now() };
}

const tempoEsgotado = () =>
  new ErroHttp(503, "tempo_esgotado", "O tempo desta execução acabou; chame novamente para continuar.");

// fetch com prazo: no máximo `limiteMs` por chamada e nunca além do
// orçamento (menos a reserva para registrar a falha).
function comPrazo(f: Fetch, prazo: Prazo, limiteMs: number): Fetch {
  return (async (url: string | URL | Request, init?: RequestInit) => {
    const ms = Math.min(limiteMs, prazo.restante() - RESERVA_REGISTRO_MS);
    if (ms <= 0) throw tempoEsgotado();
    try {
      return await f(url, { ...init, signal: AbortSignal.timeout(ms) });
    } catch (e) {
      const nome = (e as { name?: string })?.name;
      if (nome === "TimeoutError" || nome === "AbortError") {
        throw new ErroHttp(504, "sem_resposta", `Um serviço do Supabase não respondeu em ${Math.round(ms / 1000)} s.`);
      }
      throw e;
    }
  }) as Fetch;
}


class ErroHttp extends Error {
  status: number;
  codigo: string;
  constructor(status: number, codigo: string, mensagem: string) {
    super(mensagem);
    this.status = status;
    this.codigo = codigo;
  }
}

function cabecalhosCors(req: Request, env: Env): Record<string, string> {
  const origem = req.headers.get("origin") ?? "";
  const permitidas = (env.ORIGENS_PERMITIDAS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const liberada = permitidas.length === 0 || permitidas.includes(origem) ? (origem || "*") : permitidas[0];
  return {
    "Access-Control-Allow-Origin": liberada,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-canal",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function resposta(req: Request, env: Env, status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...cabecalhosCors(req, env) },
  });
}

async function rpc(f: Fetch, env: Env, nome: string, args: Record<string, unknown>, token: string, chave: string) {
  const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      "apikey": chave,
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "x-canal": "exclusao-conta",
    },
    body: JSON.stringify(args),
  });
  const texto = await r.text();
  const dados = texto ? JSON.parse(texto) : null;
  if (!r.ok) {
    throw new ErroHttp(r.status, dados?.code ?? "erro_rpc", dados?.message ?? `Falha em ${nome}`);
  }
  return dados;
}

async function usuarioDoToken(f: Fetch, env: Env, token: string): Promise<{ id: string }> {
  const r = await f(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: { "apikey": env.SUPABASE_ANON_KEY, "Authorization": `Bearer ${token}` },
  });
  if (!r.ok) throw new ErroHttp(401, "sessao_invalida", "Sessão inválida ou expirada. Entre novamente.");
  const u = await r.json();
  if (!u?.id) throw new ErroHttp(401, "sessao_invalida", "Sessão inválida ou expirada. Entre novamente.");
  return { id: u.id };
}

async function apagarLote(f: Fetch, env: Env, bucket: string, nomes: string[]): Promise<number> {
  const r = await f(`${env.SUPABASE_URL}/storage/v1/object/${encodeURIComponent(bucket)}`, {
    method: "DELETE",
    headers: {
      "apikey": env.SUPABASE_SERVICE_ROLE_KEY,
      "Authorization": `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ prefixes: nomes }),
  });
  if (!r.ok) throw new ErroHttp(502, "falha_storage", `Storage recusou a remoção (HTTP ${r.status})`);
  const removidos = await r.json();
  return Array.isArray(removidos) ? removidos.length : 0;
}

// Remove todos os arquivos cujo primeiro nível de pasta é o usuário.
// Exportada para reutilização pela varredura de órfãos.
export async function removerArquivos(
  f: Fetch, env: Env,
  listar: () => Promise<{ bucket_id: string; nome: string }[]>,
  progresso: { removidos: number },
): Promise<number> {
  for (let lote = 0; lote < MAX_LOTES; lote++) {
    const arquivos = await listar();
    if (arquivos.length === 0) return progresso.removidos;
    const porBucket = new Map<string, string[]>();
    for (const a of arquivos) {
      const lista = porBucket.get(a.bucket_id) ?? [];
      lista.push(a.nome);
      porBucket.set(a.bucket_id, lista);
    }
    let removidosNesteLote = 0;
    for (const [bucket, nomes] of porBucket) {
      for (let i = 0; i < nomes.length; i += TAMANHO_LOTE) {
        const n = await apagarLote(f, env, bucket, nomes.slice(i, i + TAMANHO_LOTE));
        removidosNesteLote += n;
        progresso.removidos += n; // contado já, para não se perder se o próximo lote falhar
      }
    }
    if (removidosNesteLote === 0) {
      throw new ErroHttp(502, "sem_progresso", "O Storage não removeu nenhum arquivo do lote; nova tentativa necessária.");
    }
  }
  throw new ErroHttp(502, "limite_lotes", "Muitos arquivos para uma única execução; chame novamente para continuar.");
}

export async function tratar(req: Request, env: Env, f: Fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cabecalhosCors(req, env) });
  if (req.method !== "POST") return resposta(req, env, 405, { erro: "metodo_nao_permitido" });

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return resposta(req, env, 401, { erro: "sessao_ausente", mensagem: "Entre na sua conta para excluí-la." });

  let corpo: { confirmacao_email?: unknown } = {};
  try {
    corpo = await req.json();
  } catch {
    return resposta(req, env, 400, { erro: "corpo_invalido", mensagem: "Envie {\"confirmacao_email\": \"...\"}." });
  }
  const email = typeof corpo?.confirmacao_email === "string" ? corpo.confirmacao_email : null;

  let userId = "";
  const progresso = { removidos: 0 };
  const prazo = criarPrazo(env.ORCAMENTO_MS ?? ORCAMENTO_MS);
  const limiteChamada = env.PRAZO_CHAMADA_MS ?? PRAZO_CHAMADA_MS;
  const fc = comPrazo(f, prazo, limiteChamada);
  try {
    const usuario = await usuarioDoToken(fc, env, token);
    userId = usuario.id;

    // Passo 2: validação do e-mail e bloqueio — feitos pelo banco, como o usuário
    try {
      await rpc(fc, env, "exclusao_solicitar", { p_confirmacao_email: email }, token, env.SUPABASE_ANON_KEY);
    } catch (e) {
      if (e instanceof ErroHttp && e.status < 500) throw new ErroHttp(400, e.codigo, e.message);
      throw e;
    }

    // Passos 3 e 4, em ciclo: remove os arquivos e tenta concluir.
    // A conclusão espera uploads já iniciados terminarem (trava por
    // usuário no banco). Se um deles confirmar nesse meio-tempo, o banco
    // recusa (SF410) e o ciclo recomeça; se demorar demais, desiste sem
    // apagar nada (55P03) e o ciclo recomeça.
    const svc = env.SUPABASE_SERVICE_ROLE_KEY;
    const listar = () => rpc(fc, env, "exclusao_listar_arquivos", { p_user_id: userId, p_limite: TAMANHO_LOTE }, svc, svc);
    let fim: { status?: string } | null = null;
    for (let tentativa = 1; tentativa <= MAX_TENTATIVAS_CONCLUSAO; tentativa++) {
      await removerArquivos(fc, env, listar, progresso);
      // a espera pelos uploads encolhe para caber no tempo que sobra
      const espera = Math.min(ESPERA_CONCLUSAO_MS, prazo.restante() - RESERVA_REGISTRO_MS - FOLGA_CONCLUSAO_MS);
      if (espera < ESPERA_MINIMA_MS) throw tempoEsgotado();
      try {
        fim = await rpc(comPrazo(f, prazo, espera + FOLGA_CONCLUSAO_MS), env, "exclusao_concluir",
          { p_user_id: userId, p_arquivos_removidos: progresso.removidos, p_espera_ms: espera }, svc, svc);
        break; // conclusão recusada é desfeita no banco: o total acumulado é enviado inteiro
      } catch (e) {
        const repetir = e instanceof ErroHttp && (e.codigo === "SF410" || e.codigo === "55P03");
        if (!repetir || tentativa === MAX_TENTATIVAS_CONCLUSAO) throw e;
        await esperar(env.ESPERA_ENTRE_TENTATIVAS_MS ?? 1000);
      }
    }

    // Conferência final: se algum arquivo do usuário surgiu depois da
    // conclusão (ex.: gravação tardia feita pelo próprio serviço de
    // Storage), ele é removido agora e registrado no comprovante.
    const tardios = await removerArquivos(fc, env, listar, { removidos: 0 });
    if (tardios > 0) {
      await rpc(fc, env, "exclusao_registrar_limpeza_tardia", { p_user_id: userId, p_arquivos: tardios }, svc, svc);
    }
    return resposta(req, env, 200, {
      status: fim?.status ?? "concluida",
      arquivos_removidos: progresso.removidos + tardios,
    });
  } catch (e) {
    const erro = e instanceof ErroHttp ? e : new ErroHttp(500, "erro_interno", "Erro inesperado na exclusão.");
    // Falha depois de a solicitação existir: registra para retomada
    // (usa a reserva de tempo guardada para isto, com prazo próprio).
    // Se a conclusão chegou a terminar no banco e só a resposta se perdeu,
    // o registro não altera nada: o banco ignora exclusões já concluídas.
    if (userId && erro.status !== 400 && erro.status !== 401) {
      try {
        const svc = env.SUPABASE_SERVICE_ROLE_KEY;
        const fr = comPrazo(f, { restante: () => RESERVA_REGISTRO_MS * 2 }, RESERVA_REGISTRO_MS - 1000);
        await rpc(fr, env, "exclusao_registrar_falha",
          { p_user_id: userId, p_erro: `${erro.codigo}: ${erro.message}`, p_arquivos_removidos: progresso.removidos }, svc, svc);
      } catch { /* o registro de falha não pode mascarar o erro original */ }
    }
    console.error(JSON.stringify({ funcao: "excluir-conta", codigo: erro.codigo, status: erro.status }));
    const status = erro.status >= 500 || erro.codigo === "SF410" ? 503 : erro.status;
    const mensagem = status === 503
      ? "A exclusão foi iniciada mas não terminou. Seus dados continuam bloqueados; tente novamente em alguns minutos."
      : erro.message;
    return resposta(req, env, status, { erro: erro.codigo, mensagem, arquivos_removidos: progresso.removidos });
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
    SUPABASE_ANON_KEY: denoRt.env.get("SUPABASE_ANON_KEY") ?? "",
    SUPABASE_SERVICE_ROLE_KEY: denoRt.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    ORIGENS_PERMITIDAS: denoRt.env.get("ORIGENS_PERMITIDAS"),
  }));
}
