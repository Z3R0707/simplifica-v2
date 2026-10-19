import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { ErroApi, listar, novaChave } from "./lib/api";
import { formatarCentavos } from "./lib/dinheiro";
import type { Categoria, Conta, Instituicao, Perfil, Titular } from "./lib/tipos";

// ------------------------------------------------------------ carregamento
export function useCarregar<T>(funcao: () => Promise<T>, deps: unknown[]) {
  const [estado, setEstado] = useState<{ dados: T | null; erro: string | null; carregando: boolean }>({
    dados: null, erro: null, carregando: true,
  });
  const [versao, setVersao] = useState(0);
  const depsAnteriores = useRef<unknown[] | null>(null);
  useEffect(() => {
    let vivo = true;
    // Numa recarga (mesmas deps), um erro passageiro mantém os dados já mostrados.
    // Se as deps mudaram, os dados antigos são de outra consulta e não podem ficar.
    const antes = depsAnteriores.current;
    const mesmasDeps = antes !== null && antes.length === deps.length && deps.every((d, i) => Object.is(d, antes[i]));
    depsAnteriores.current = deps;
    setEstado((e) => ({ ...e, carregando: true, erro: null }));
    funcao().then(
      (dados) => vivo && setEstado({ dados, erro: null, carregando: false }),
      (e) => vivo && setEstado((atual) => ({ dados: mesmasDeps ? atual.dados : null, erro: mensagemDeErro(e), carregando: false })),
    );
    return () => { vivo = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, versao]);
  const recarregar = useCallback(() => setVersao((v) => v + 1), []);
  return { ...estado, recarregar };
}

export function mensagemDeErro(e: unknown): string {
  if (e instanceof ErroApi) return e.message;
  return "Algo deu errado. Atualize a página e tente de novo.";
}

// --------------------------------------------------------- cadastros base
type Cadastros = {
  instituicoes: Instituicao[];
  titulares: Titular[];
  contas: Conta[];
  categorias: Categoria[];
  perfil: Perfil | null;
  carregando: boolean;
  erro: string | null;
  recarregar: () => void;
};
const CadastrosCtx = createContext<Cadastros | null>(null);

const porNome = <T extends { nome?: string; apelido?: string }>(a: T, b: T) =>
  (a.nome ?? a.apelido ?? "").localeCompare(b.nome ?? b.apelido ?? "", "pt-BR");

export function ProvedorCadastros({ children }: { children: ReactNode }) {
  const { dados, erro, carregando, recarregar } = useCarregar(async () => {
    const [instituicoes, titulares, contas, categorias, perfis] = await Promise.all([
      listar<Instituicao>("instituicoes"),
      listar<Titular>("titulares"),
      listar<Conta>("contas"),
      listar<Categoria>("categorias"),
      listar<Perfil>("perfis"),
    ]);
    return {
      instituicoes: instituicoes.sort((a, b) => (a.nome === "Outra instituição" ? 1 : b.nome === "Outra instituição" ? -1 : porNome(a, b))),
      titulares: titulares.sort((a, b) => Number(b.principal) - Number(a.principal) || porNome(a, b)),
      contas: contas.sort(porNome),
      categorias: categorias.sort(porNome),
      perfil: perfis[0] ?? null,
    };
  }, []);
  const valor: Cadastros = {
    instituicoes: dados?.instituicoes ?? [],
    titulares: dados?.titulares ?? [],
    contas: dados?.contas ?? [],
    categorias: dados?.categorias ?? [],
    perfil: dados?.perfil ?? null,
    carregando, erro, recarregar,
  };
  return <CadastrosCtx.Provider value={valor}>{children}</CadastrosCtx.Provider>;
}

export function useCadastros(): Cadastros {
  const c = useContext(CadastrosCtx);
  if (!c) throw new Error("ProvedorCadastros ausente");
  return c;
}

// ---------------------------------------------------------------- envio
/** Estado de um formulário: chave de idempotência fixa por formulário aberto. */
export function useEnvio(prefixo: string) {
  const chave = useRef(novaChave(prefixo)).current;
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const enviar = useCallback(async (acao: () => Promise<void>) => {
    if (enviando) return;
    setEnviando(true);
    setErro(null);
    try {
      await acao();
    } catch (e) {
      setErro(mensagemDeErro(e));
    } finally {
      setEnviando(false);
    }
  }, [enviando]);
  return { chave, enviando, erro, setErro, enviar };
}

// ------------------------------------------------------------ componentes
export function Valor({ centavos, sinal, classe }: { centavos: number; sinal?: boolean; classe?: string }) {
  const tom = centavos < 0 ? "valor-saida" : centavos > 0 && sinal ? "valor-entrada" : "";
  return <span className={`valor ${tom} ${classe ?? ""}`}>{formatarCentavos(centavos, { sinal })}</span>;
}

export function Campo({ rotulo, ajuda, erro, children }: { rotulo: string; ajuda?: ReactNode; erro?: string | null; children: (id: string) => ReactNode }) {
  const id = useId();
  return (
    <div className={`campo${erro ? " campo-com-erro" : ""}`}>
      <label htmlFor={id}>{rotulo}</label>
      {children(id)}
      {ajuda && <p className="campo-ajuda">{ajuda}</p>}
      {erro && <p className="campo-erro">{erro}</p>}
    </div>
  );
}

export function Alerta({ tipo = "erro", children }: { tipo?: "erro" | "aviso" | "ok"; children: ReactNode }) {
  return <div className={`alerta alerta-${tipo}`} role={tipo === "erro" ? "alert" : "status"}>{children}</div>;
}

export function Carregando({ texto = "Carregando…" }: { texto?: string }) {
  return <p className="carregando" role="status">{texto}</p>;
}

// Diálogos abertos, do mais antigo ao mais novo. Só o do topo responde ao teclado.
const pilhaDialogos: object[] = [];
const FOCAVEIS = "a[href], input, select, textarea, button, [tabindex]:not([tabindex='-1'])";

export function Dialogo({ titulo, aoFechar, children, largo }: { titulo: string; aoFechar: () => void; children: ReactNode; largo?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const idTitulo = useId();
  // As telas passam aoFechar como função nova a cada render; guardar numa ref
  // evita refazer o efeito (e devolver o foco ao primeiro campo) a cada tecla.
  const aoFecharRef = useRef(aoFechar);
  useEffect(() => { aoFecharRef.current = aoFechar; });
  useEffect(() => {
    const eu = {};
    pilhaDialogos.push(eu);
    const noTopo = () => pilhaDialogos[pilhaDialogos.length - 1] === eu;
    const anterior = document.activeElement as HTMLElement | null;
    const primeiro = ref.current?.querySelector<HTMLElement>("input, select, textarea, button:not(.dialogo-fechar)");
    (primeiro ?? ref.current)?.focus();
    const tecla = (e: KeyboardEvent) => {
      if (!noTopo()) return;
      if (e.key === "Escape") { e.preventDefault(); aoFecharRef.current(); return; }
      const caixa = ref.current;
      if (e.key !== "Tab" || !caixa) return;
      const focaveis = Array.from(caixa.querySelectorAll<HTMLElement>(FOCAVEIS))
        .filter((el) => !el.hasAttribute("disabled") && el.offsetParent !== null);
      if (focaveis.length === 0) { e.preventDefault(); caixa.focus(); return; }
      const inicio = focaveis[0];
      const fim = focaveis[focaveis.length - 1];
      const ativo = document.activeElement;
      const fora = !caixa.contains(ativo);
      if (e.shiftKey && (ativo === inicio || fora)) { e.preventDefault(); fim.focus(); }
      else if (!e.shiftKey && (ativo === fim || fora)) { e.preventDefault(); inicio.focus(); }
    };
    document.addEventListener("keydown", tecla);
    document.body.classList.add("sem-rolagem");
    return () => {
      document.removeEventListener("keydown", tecla);
      const i = pilhaDialogos.indexOf(eu);
      if (i >= 0) pilhaDialogos.splice(i, 1);
      if (pilhaDialogos.length === 0) document.body.classList.remove("sem-rolagem");
      anterior?.focus?.();
    };
  }, []);
  return (
    <div className="dialogo-fundo" onMouseDown={(e) => { if (e.target === e.currentTarget) aoFechar(); }}>
      <div className={`dialogo${largo ? " dialogo-largo" : ""}`} role="dialog" aria-modal="true" aria-labelledby={idTitulo} ref={ref} tabIndex={-1}>
        <div className="dialogo-topo">
          <h2 id={idTitulo}>{titulo}</h2>
          <button type="button" className="dialogo-fechar" onClick={aoFechar} aria-label="Fechar">×</button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function Confirmar({ titulo, texto, rotuloAcao, pedirMotivo, perigo, aoConfirmar, aoFechar }: {
  titulo: string;
  texto: ReactNode;
  rotuloAcao: string;
  pedirMotivo?: "obrigatorio" | "opcional";
  perigo?: boolean;
  aoConfirmar: (motivo: string) => Promise<void>;
  aoFechar: () => void;
}) {
  const [motivo, setMotivo] = useState("");
  const { enviando, erro, setErro, enviar } = useEnvio("confirmar");
  return (
    <Dialogo titulo={titulo} aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (pedirMotivo === "obrigatorio" && motivo.trim().length < 3) { setErro("Escreva o motivo (pelo menos 3 letras)."); return; }
        void enviar(() => aoConfirmar(motivo.trim()));
      }}>
        <div className="dialogo-texto">{texto}</div>
        {pedirMotivo && (
          <Campo rotulo={pedirMotivo === "obrigatorio" ? "Motivo" : "Motivo (opcional)"}>
            {(id) => <input id={id} value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={200} />}
          </Campo>
        )}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className={perigo ? "botao-perigo" : "botao"} disabled={enviando}>{enviando ? "Aguarde…" : rotuloAcao}</button>
        </div>
      </form>
    </Dialogo>
  );
}

export function TituloPagina({ titulo, children }: { titulo: string; children?: ReactNode }) {
  useEffect(() => { document.title = `${titulo} — Simplifica Finanças`; }, [titulo]);
  return (
    <div className="titulo-pagina">
      <h1>{titulo}</h1>
      {children && <div className="titulo-acoes">{children}</div>}
    </div>
  );
}
