import { useState } from "react";
import { definirSenha, excluirMinhaConta, rpc, sair, sessaoAtual } from "../lib/api";
import { hoje } from "../lib/datas";
import { Alerta, Campo, Dialogo, TituloPagina, useCadastros, useEnvio } from "../ui";

export function TelaMinhaConta({ aoExcluir }: { aoExcluir: () => void }) {
  const { perfil, recarregar } = useCadastros();
  const email = sessaoAtual()?.usuario.email ?? "";
  const [nome, setNome] = useState(perfil?.nome ?? "");
  const [okNome, setOkNome] = useState(false);
  const envioNome = useEnvio("perfil");
  const [senha, setSenha] = useState("");
  const [repetir, setRepetir] = useState("");
  const [okSenha, setOkSenha] = useState(false);
  const envioSenha = useEnvio("senha");
  const envioExportar = useEnvio("exportar");
  const [excluindo, setExcluindo] = useState(false);

  return (
    <>
      <TituloPagina titulo="Minha conta" />
      <section className="secao estreita">
        <h2>Dados de acesso</h2>
        <p>E-mail: <strong>{email}</strong></p>
        <form className="formulario" onSubmit={(e) => {
          e.preventDefault();
          if (!perfil) return;
          setOkNome(false);
          void envioNome.enviar(async () => {
            await rpc("perfil_atualizar", { p_versao_esperada: perfil.versao, p_nome: nome, p_chave_idempotencia: envioNome.chave + "-" + perfil.versao });
            setOkNome(true);
            recarregar();
          });
        }}>
          <Campo rotulo="Seu nome">{(id) => <input id={id} maxLength={120} value={nome} onChange={(e) => setNome(e.target.value)} />}</Campo>
          {envioNome.erro && <Alerta>{envioNome.erro}</Alerta>}
          {okNome && <Alerta tipo="ok">Nome salvo.</Alerta>}
          <div className="acoes acoes-esquerda"><button type="submit" className="botao-secundario" disabled={envioNome.enviando || !perfil}>Salvar nome</button></div>
        </form>
      </section>

      <section className="secao estreita">
        <h2>Trocar senha</h2>
        <form className="formulario" onSubmit={(e) => {
          e.preventDefault();
          setOkSenha(false);
          if (senha.length < 8) return envioSenha.setErro("A senha precisa ter pelo menos 8 caracteres.");
          if (senha !== repetir) return envioSenha.setErro("As duas senhas estão diferentes.");
          void envioSenha.enviar(async () => { await definirSenha(senha); setSenha(""); setRepetir(""); setOkSenha(true); });
        }}>
          <div className="grade-2">
            <Campo rotulo="Nova senha">{(id) => <input id={id} type="password" autoComplete="new-password" value={senha} onChange={(e) => setSenha(e.target.value)} />}</Campo>
            <Campo rotulo="Repita a nova senha">{(id) => <input id={id} type="password" autoComplete="new-password" value={repetir} onChange={(e) => setRepetir(e.target.value)} />}</Campo>
          </div>
          {envioSenha.erro && <Alerta>{envioSenha.erro}</Alerta>}
          {okSenha && <Alerta tipo="ok">Senha trocada.</Alerta>}
          <div className="acoes acoes-esquerda"><button type="submit" className="botao-secundario" disabled={envioSenha.enviando}>Trocar senha</button></div>
        </form>
      </section>

      <section className="secao estreita">
        <h2>Seus dados</h2>
        <p>Baixe uma cópia de tudo o que está guardado na sua conta: contas, lançamentos, categorias e histórico de alterações.</p>
        {envioExportar.erro && <Alerta>{envioExportar.erro}</Alerta>}
        <div className="acoes acoes-esquerda">
          <button type="button" className="botao-secundario" disabled={envioExportar.enviando} onClick={() => void envioExportar.enviar(async () => {
            const dados = await rpc<unknown>("exportar_meus_dados");
            const blob = new Blob([JSON.stringify(dados, null, 2)], { type: "application/json" });
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = `simplifica-meus-dados-${hoje()}.json`;
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(() => URL.revokeObjectURL(url), 1000);
          })}>{envioExportar.enviando ? "Preparando…" : "Baixar meus dados"}</button>
          <button type="button" className="botao-secundario" onClick={() => void sair()}>Sair</button>
        </div>
      </section>

      <section className="secao estreita zona-perigo">
        <h2>Excluir conta</h2>
        <p>Apaga definitivamente seu acesso, todas as contas, lançamentos e documentos. Não é possível desfazer.</p>
        <div className="acoes acoes-esquerda"><button type="button" className="botao-perigo" onClick={() => setExcluindo(true)}>Excluir minha conta</button></div>
      </section>

      {excluindo && <DialogoExcluir email={email} aoFechar={() => setExcluindo(false)} aoConcluir={aoExcluir} />}
    </>
  );
}

function DialogoExcluir({ email, aoFechar, aoConcluir }: { email: string; aoFechar: () => void; aoConcluir: () => void }) {
  const [confirmacao, setConfirmacao] = useState("");
  const { enviando, erro, setErro, enviar } = useEnvio("excluir");
  return (
    <Dialogo titulo="Excluir conta definitivamente" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (confirmacao.trim().toLowerCase() !== email.toLowerCase()) return setErro("Digite exatamente o e-mail da conta para confirmar.");
        void enviar(async () => { await excluirMinhaConta(confirmacao); aoConcluir(); });
      }}>
        <div className="dialogo-texto">
          <p>Serão apagados seu acesso, perfil, titulares, contas, lançamentos, categorias, documentos e histórico. Recomendamos baixar seus dados antes.</p>
          <p>Para confirmar, digite <strong>{email}</strong>.</p>
        </div>
        <Campo rotulo="E-mail da conta">{(id) => <input id={id} type="email" autoComplete="off" value={confirmacao} onChange={(e) => setConfirmacao(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao-perigo" disabled={enviando}>{enviando ? "Excluindo…" : "Excluir definitivamente"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
