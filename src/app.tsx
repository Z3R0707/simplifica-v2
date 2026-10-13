import { useEffect, useState } from "react";
import { aoMudarSessao, sessaoAtual, tratarLinkDoEmail, type Sessao } from "./lib/api";
import { Carregando, ProvedorCadastros, useCadastros } from "./ui";
import { TelaCriarConta, TelaEntrar, TelaEsqueciSenha, TelaNovaSenha } from "./telas/acesso";
import { TelaCategorias } from "./telas/categorias";
import { TelaContas } from "./telas/contas";
import { TelaExtrato } from "./telas/extrato";
import { TelaMinhaConta } from "./telas/minha-conta";
import { TelaResumo } from "./telas/resumo";
import { TelaSaldos } from "./telas/saldos";

function rotaAtual(): string {
  const h = location.hash.replace(/^#/, "");
  return h.startsWith("/") ? h : "/saldos";
}

function irPara(rota: string, substituir = false) {
  const url = `${location.pathname}${location.search}#${rota}`;
  if (substituir) history.replaceState(null, "", url);
  else location.hash = rota;
}

const NAVEGACAO = [
  { rota: "/saldos", nome: "Saldos" },
  { rota: "/contas", nome: "Contas" },
  { rota: "/resumo", nome: "Resumo" },
  { rota: "/categorias", nome: "Categorias" },
  { rota: "/minha-conta", nome: "Minha conta" },
];

export function App() {
  const [sessao, setSessao] = useState<Sessao | null>(sessaoAtual());
  const [rota, setRota] = useState(rotaAtual());
  const [aviso, setAviso] = useState<string | null>(null);
  const [processandoLink, setProcessandoLink] = useState(/(access_token|error_description|error)=/.test(location.hash));

  useEffect(() => aoMudarSessao(setSessao), []);
  useEffect(() => {
    const mudou = () => {
      // link do e-mail aberto numa aba onde o site já estava carregado
      if (/(access_token|error_description|error)=/.test(location.hash)) setProcessandoLink(true);
      else setRota(rotaAtual());
    };
    window.addEventListener("hashchange", mudou);
    return () => window.removeEventListener("hashchange", mudou);
  }, []);

  // Links dos e-mails (confirmação de cadastro e recuperação de senha)
  useEffect(() => {
    if (!processandoLink) return;
    tratarLinkDoEmail(location.hash).then((r) => {
      if (r && "erro" in r) { setAviso(r.erro); irPara("/entrar", true); }
      else if (r && r.tipo === "recovery") irPara("/nova-senha", true);
      else irPara("/saldos", true);
    }).catch(() => {
      setAviso("Não foi possível validar o link do e-mail. Peça um novo.");
      irPara("/entrar", true);
    }).finally(() => { setRota(rotaAtual()); setProcessandoLink(false); });
  }, [processandoLink]);

  if (processandoLink) return <main className="acesso"><Carregando texto="Validando o link…" /></main>;

  if (!sessao) {
    if (rota === "/criar-conta") return <TelaCriarConta />;
    if (rota === "/esqueci-senha") return <TelaEsqueciSenha />;
    return <TelaEntrar aviso={aviso} />;
  }
  if (rota === "/nova-senha") {
    return <TelaNovaSenha aoConcluir={() => { setAviso(null); irPara("/saldos"); }} />;
  }
  if (["/entrar", "/criar-conta", "/esqueci-senha"].includes(rota)) {
    irPara("/saldos", true);
  }
  return (
    <ProvedorCadastros key={sessao.usuario.id}>
      <Casca rota={rota} aoExcluir={() => { setAviso("Sua conta foi excluída. Obrigado por ter usado o Simplifica."); irPara("/entrar", true); }} />
    </ProvedorCadastros>
  );
}

function Casca({ rota, aoExcluir }: { rota: string; aoExcluir: () => void }) {
  const { carregando, erro, perfil } = useCadastros();
  const ativo = (r: string) => rota === r || (r === "/saldos" && rota.startsWith("/conta/"));
  useEffect(() => { window.scrollTo(0, 0); }, [rota]);

  let tela: React.ReactNode;
  const conta = /^\/conta\/([0-9a-f-]{36})$/.exec(rota);
  if (conta) tela = <TelaExtrato key={conta[1]} contaId={conta[1]} />;
  else if (rota === "/contas") tela = <TelaContas />;
  else if (rota === "/resumo") tela = <TelaResumo />;
  else if (rota === "/categorias") tela = <TelaCategorias />;
  else if (rota === "/minha-conta") tela = <TelaMinhaConta key={perfil?.versao ?? 0} aoExcluir={aoExcluir} />;
  else tela = <TelaSaldos />;

  return (
    <div className="casca">
      <a className="pular" href="#conteudo">Ir para o conteúdo</a>
      <header className="topo">
        <a className="marca" href="#/saldos"><span className="marca-simbolo" aria-hidden="true">S</span><span>Simplifica</span></a>
        <nav aria-label="Principal">
          <ul className="nav">
            {NAVEGACAO.map((n) => (
              <li key={n.rota}><a href={`#${n.rota}`} aria-current={ativo(n.rota) ? "page" : undefined}>{n.nome}</a></li>
            ))}
          </ul>
        </nav>
      </header>
      <main id="conteudo" className="conteudo">
        {carregando && !perfil ? <Carregando /> : erro && !perfil ? <p className="alerta alerta-erro" role="alert">{erro}</p> : tela}
      </main>
    </div>
  );
}
