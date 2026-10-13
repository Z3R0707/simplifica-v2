// Cliente mínimo do Supabase (Auth + PostgREST + Edge Functions) via fetch.
// Toda regra financeira fica no banco: aqui só chamamos as funções (RPC)
// validadas nas etapas 1 e 2 e lemos tabelas protegidas por RLS.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "../config";

export type Usuario = { id: string; email: string };
export type Sessao = { access_token: string; refresh_token: string; expira_em: number; usuario: Usuario };

const CHAVE_SESSAO = "simplifica-v2.sessao";

export class ErroApi extends Error {
  status: number;
  codigo: string;
  constructor(status: number, codigo: string, mensagem: string) {
    super(mensagem);
    this.status = status;
    this.codigo = codigo;
  }
}

// ----------------------------------------------------------------- sessão
function lerSessao(): Sessao | null {
  try {
    const t = localStorage.getItem(CHAVE_SESSAO);
    return t ? (JSON.parse(t) as Sessao) : null;
  } catch {
    return null;
  }
}
let sessao: Sessao | null = lerSessao();
const ouvintes = new Set<(s: Sessao | null) => void>();

function gravarSessao(s: Sessao | null) {
  sessao = s;
  try {
    if (s) localStorage.setItem(CHAVE_SESSAO, JSON.stringify(s));
    else localStorage.removeItem(CHAVE_SESSAO);
  } catch { /* navegação privada: a sessão vale só nesta aba */ }
  ouvintes.forEach((f) => f(s));
}

export function sessaoAtual(): Sessao | null {
  return sessao;
}
export function aoMudarSessao(f: (s: Sessao | null) => void): () => void {
  ouvintes.add(f);
  return () => ouvintes.delete(f);
}

// Outra aba entrou ou saiu
if (typeof window !== "undefined") {
  window.addEventListener("storage", (e) => {
    if (e.key === CHAVE_SESSAO) {
      sessao = lerSessao();
      ouvintes.forEach((f) => f(sessao));
    }
  });
}

// ------------------------------------------------------- tradução de erros
const MENSAGENS: Record<string, string> = {
  invalid_credentials: "E-mail ou senha incorretos.",
  invalid_grant: "E-mail ou senha incorretos.",
  email_not_confirmed: "Confirme seu e-mail pelo link que enviamos antes de entrar.",
  user_already_exists: "Já existe uma conta com este e-mail.",
  email_exists: "Já existe uma conta com este e-mail.",
  weak_password: "Senha fraca. Use pelo menos 8 caracteres, misturando letras e números.",
  same_password: "A nova senha precisa ser diferente da atual.",
  over_email_send_rate_limit: "Muitos e-mails enviados em pouco tempo. Aguarde alguns minutos e tente de novo.",
  over_request_rate_limit: "Muitas tentativas em pouco tempo. Aguarde alguns minutos.",
  "40001": "Este registro foi alterado em outro lugar. Atualize a tela e tente de novo.",
  SF409: "Este envio já foi registrado com outros dados. Feche o formulário e abra de novo.",
  "23505": "Já existe um cadastro com esse nome.",
  "23514": "Algum valor está fora do permitido. Confira os campos.",
  "23503": "Este registro está ligado a outro que não foi encontrado.",
  "42501": "Você não tem permissão para esta ação.",
  "55P03": "O servidor está ocupado com outra operação desta conta. Tente de novo em instantes.",
};

function traduzir(status: number, dados: unknown): ErroApi {
  const d = (dados && typeof dados === "object" ? dados : {}) as Record<string, unknown>;
  // Auth responde {code: 400, error_code: "..."}; PostgREST responde {code: "P0001"}
  const codigo = String(d.error_code ?? (typeof d.code === "string" ? d.code : undefined) ?? d.error ?? status);
  const original = String(d.message ?? d.msg ?? d.error_description ?? d.mensagem ?? "");
  if (status === 429) return new ErroApi(status, codigo, MENSAGENS.over_request_rate_limit);
  // Mensagens do próprio banco (exceções das funções) já estão em português
  if (codigo === "P0001" || codigo === "22023" || codigo === "P0002") {
    return new ErroApi(status, codigo, original || "Operação recusada.");
  }
  const conhecida = MENSAGENS[codigo];
  if (conhecida) return new ErroApi(status, codigo, conhecida);
  if (status === 401) return new ErroApi(status, "sessao", "Sua sessão terminou. Entre novamente.");
  return new ErroApi(status, codigo, original && /[ãçéêíóôú]/i.test(original) ? original : "Não foi possível concluir. Tente de novo.");
}

// ------------------------------------------------------------- transporte
let enviarCanal = true;

async function http(metodo: string, caminho: string, opcoes: { corpo?: unknown; token?: string } = {}): Promise<unknown> {
  const headers: Record<string, string> = {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${opcoes.token ?? SUPABASE_ANON_KEY}`,
  };
  if (opcoes.corpo !== undefined) headers["Content-Type"] = "application/json";
  const comCanal = enviarCanal && caminho.startsWith("/rest/");
  if (comCanal) headers["x-canal"] = "web";
  let r: Response;
  try {
    r = await fetch(SUPABASE_URL + caminho, {
      method: metodo,
      headers,
      body: opcoes.corpo === undefined ? undefined : JSON.stringify(opcoes.corpo),
    });
  } catch {
    // Se o servidor recusar o cabeçalho de canal (CORS), segue sem ele
    if (comCanal) {
      enviarCanal = false;
      return http(metodo, caminho, opcoes);
    }
    throw new ErroApi(0, "rede", "Sem conexão com o servidor. Verifique a internet e tente de novo.");
  }
  const texto = await r.text();
  let dados: unknown = null;
  try {
    dados = texto ? JSON.parse(texto) : null;
  } catch {
    dados = texto;
  }
  if (!r.ok) throw traduzir(r.status, dados);
  return dados;
}

function sessaoDaResposta(d: Record<string, unknown>): Sessao {
  const u = (d.user ?? {}) as Record<string, unknown>;
  return {
    access_token: String(d.access_token),
    refresh_token: String(d.refresh_token ?? ""),
    expira_em: Date.now() + Number(d.expires_in ?? 3600) * 1000,
    usuario: { id: String(u.id ?? ""), email: String(u.email ?? "") },
  };
}

let renovacao: Promise<void> | null = null;
function renovar(): Promise<void> {
  if (!renovacao) {
    renovacao = (async () => {
      const atual = sessao;
      if (!atual?.refresh_token) {
        gravarSessao(null);
        throw new ErroApi(401, "sessao", "Sua sessão terminou. Entre novamente.");
      }
      try {
        const d = (await http("POST", "/auth/v1/token?grant_type=refresh_token", { corpo: { refresh_token: atual.refresh_token } })) as Record<string, unknown>;
        gravarSessao(sessaoDaResposta(d));
      } catch (e) {
        if (e instanceof ErroApi && e.codigo === "rede") throw e;
        gravarSessao(null);
        throw new ErroApi(401, "sessao", "Sua sessão terminou. Entre novamente.");
      }
    })().finally(() => {
      renovacao = null;
    });
  }
  return renovacao;
}

async function autenticado(metodo: string, caminho: string, corpo?: unknown): Promise<unknown> {
  if (!sessao) throw new ErroApi(401, "sessao", "Sua sessão terminou. Entre novamente.");
  if (Date.now() > sessao.expira_em - 60_000) await renovar();
  try {
    return await http(metodo, caminho, { corpo, token: sessao!.access_token });
  } catch (e) {
    if (e instanceof ErroApi && e.status === 401 && sessao) {
      await renovar();
      return http(metodo, caminho, { corpo, token: sessao!.access_token });
    }
    throw e;
  }
}

// ------------------------------------------------------------ autenticação
function urlDeRetorno(): string {
  return `${location.origin}/`;
}

export async function entrar(email: string, senha: string): Promise<void> {
  const d = (await http("POST", "/auth/v1/token?grant_type=password", { corpo: { email: email.trim(), password: senha } })) as Record<string, unknown>;
  gravarSessao(sessaoDaResposta(d));
}

/** Devolve true quando o e-mail precisa ser confirmado antes do primeiro acesso. */
export async function criarConta(nome: string, email: string, senha: string): Promise<boolean> {
  const d = (await http("POST", `/auth/v1/signup?redirect_to=${encodeURIComponent(urlDeRetorno())}`, {
    corpo: { email: email.trim(), password: senha, data: { nome: nome.trim() } },
  })) as Record<string, unknown>;
  if (d && d.access_token) {
    gravarSessao(sessaoDaResposta(d));
    return false;
  }
  return true;
}

export async function pedirNovaSenha(email: string): Promise<void> {
  await http("POST", `/auth/v1/recover?redirect_to=${encodeURIComponent(urlDeRetorno())}`, { corpo: { email: email.trim() } });
}

export async function definirSenha(senha: string): Promise<void> {
  await autenticado("PUT", "/auth/v1/user", { password: senha });
}

export async function sair(): Promise<void> {
  const atual = sessao;
  gravarSessao(null);
  if (atual) {
    try {
      await http("POST", "/auth/v1/logout", { token: atual.access_token });
    } catch { /* a sessão local já foi encerrada */ }
  }
}

export function encerrarSessaoLocal(): void {
  gravarSessao(null);
}

export type ResultadoLink = { tipo: string } | { erro: string } | null;

/**
 * Trata o retorno dos links enviados por e-mail (confirmação de cadastro e
 * recuperação de senha), que chegam no endereço como #access_token=...
 */
export async function tratarLinkDoEmail(hash: string): Promise<ResultadoLink> {
  const texto = hash.replace(/^#\/?/, "");
  if (!/(^|&)(access_token|error|error_description)=/.test(texto)) return null;
  const p = new URLSearchParams(texto);
  if (p.get("error") || p.get("error_description")) {
    const codigo = p.get("error_code") ?? "";
    return {
      erro: codigo === "otp_expired"
        ? "O link do e-mail expirou ou já foi usado. Peça um novo."
        : "Não foi possível validar o link do e-mail. Peça um novo.",
    };
  }
  const token = p.get("access_token")!;
  const usuario = (await http("GET", "/auth/v1/user", { token })) as Record<string, unknown>;
  gravarSessao({
    access_token: token,
    refresh_token: p.get("refresh_token") ?? "",
    expira_em: Date.now() + Number(p.get("expires_in") ?? 3600) * 1000,
    usuario: { id: String(usuario.id), email: String(usuario.email ?? "") },
  });
  return { tipo: p.get("type") ?? "login" };
}

// ------------------------------------------------------------ dados
export async function rpc<T>(nome: string, args: Record<string, unknown> = {}): Promise<T> {
  return (await autenticado("POST", `/rest/v1/rpc/${nome}`, args)) as T;
}

/** Lê uma tabela (o RLS do banco já limita aos dados do próprio usuário). */
export async function listar<T>(tabela: string, filtros: Record<string, string> = {}): Promise<T[]> {
  const q = new URLSearchParams({ select: "*", ...filtros });
  const dados = await autenticado("GET", `/rest/v1/${tabela}?${q.toString()}`);
  return Array.isArray(dados) ? (dados as T[]) : [];
}

export async function excluirMinhaConta(email: string): Promise<{ status: string; arquivos_removidos: number }> {
  const r = (await autenticado("POST", "/functions/v1/excluir-conta", { confirmacao_email: email })) as {
    status: string;
    arquivos_removidos: number;
  };
  gravarSessao(null);
  return r;
}

/** Chave única para um envio de formulário (protege contra clique duplo e reenvio). */
export function novaChave(prefixo: string): string {
  const aleatorio = typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  return `${prefixo}-${aleatorio}`;
}
