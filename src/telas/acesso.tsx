import { useState } from "react";
import { criarConta, definirSenha, entrar, pedirNovaSenha } from "../lib/api";
import { Alerta, Campo, useEnvio } from "../ui";

function Moldura({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <main className="acesso">
      <div className="acesso-marca">
        <span className="marca-simbolo" aria-hidden="true">S</span>
        <span>Simplifica Finanças</span>
      </div>
      <section className="acesso-cartao">
        <h1>{titulo}</h1>
        {children}
      </section>
    </main>
  );
}

export function TelaEntrar({ aviso }: { aviso?: string | null }) {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const { enviando, erro, enviar } = useEnvio("entrar");
  return (
    <Moldura titulo="Entrar">
      {aviso && <Alerta tipo="aviso">{aviso}</Alerta>}
      <form className="formulario" onSubmit={(e) => { e.preventDefault(); void enviar(() => entrar(email, senha)); }}>
        <Campo rotulo="E-mail">{(id) => <input id={id} type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Campo>
        <Campo rotulo="Senha">{(id) => <input id={id} type="password" autoComplete="current-password" required value={senha} onChange={(e) => setSenha(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <button type="submit" className="botao botao-largo" disabled={enviando}>{enviando ? "Entrando…" : "Entrar"}</button>
      </form>
      <p className="acesso-links">
        <a href="#/criar-conta">Criar conta</a>
        <a href="#/esqueci-senha">Esqueci a senha</a>
      </p>
    </Moldura>
  );
}

export function TelaCriarConta() {
  const [nome, setNome] = useState("");
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [repetir, setRepetir] = useState("");
  const [enviadoPara, setEnviadoPara] = useState<string | null>(null);
  const { enviando, erro, setErro, enviar } = useEnvio("cadastro");

  if (enviadoPara) {
    return (
      <Moldura titulo="Confirme seu e-mail">
        <p>Enviamos um link de confirmação para <strong>{enviadoPara}</strong>. Abra o e-mail e clique no link para ativar a conta.</p>
        <p className="texto-suave">Não chegou? Confira a caixa de spam ou tente de novo em alguns minutos.</p>
        <p className="acesso-links"><a href="#/entrar">Voltar para entrar</a></p>
      </Moldura>
    );
  }
  return (
    <Moldura titulo="Criar conta">
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (senha.length < 8) { setErro("A senha precisa ter pelo menos 8 caracteres."); return; }
        if (senha !== repetir) { setErro("As duas senhas estão diferentes."); return; }
        void enviar(async () => {
          const precisaConfirmar = await criarConta(nome, email, senha);
          if (precisaConfirmar) setEnviadoPara(email.trim());
        });
      }}>
        <Campo rotulo="Seu nome">{(id) => <input id={id} autoComplete="name" required maxLength={120} value={nome} onChange={(e) => setNome(e.target.value)} />}</Campo>
        <Campo rotulo="E-mail">{(id) => <input id={id} type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Campo>
        <Campo rotulo="Senha" ajuda="Pelo menos 8 caracteres.">{(id) => <input id={id} type="password" autoComplete="new-password" required value={senha} onChange={(e) => setSenha(e.target.value)} />}</Campo>
        <Campo rotulo="Repita a senha">{(id) => <input id={id} type="password" autoComplete="new-password" required value={repetir} onChange={(e) => setRepetir(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <button type="submit" className="botao botao-largo" disabled={enviando}>{enviando ? "Criando…" : "Criar conta"}</button>
      </form>
      <p className="acesso-links"><a href="#/entrar">Já tenho conta</a></p>
    </Moldura>
  );
}

export function TelaEsqueciSenha() {
  const [email, setEmail] = useState("");
  const [enviado, setEnviado] = useState(false);
  const { enviando, erro, enviar } = useEnvio("recuperar");
  return (
    <Moldura titulo="Recuperar senha">
      {enviado ? (
        <p>Se houver uma conta com <strong>{email.trim()}</strong>, enviamos um link para criar uma nova senha. O link vale por pouco tempo.</p>
      ) : (
        <form className="formulario" onSubmit={(e) => { e.preventDefault(); void enviar(async () => { await pedirNovaSenha(email); setEnviado(true); }); }}>
          <Campo rotulo="E-mail da conta">{(id) => <input id={id} type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Campo>
          {erro && <Alerta>{erro}</Alerta>}
          <button type="submit" className="botao botao-largo" disabled={enviando}>{enviando ? "Enviando…" : "Enviar link"}</button>
        </form>
      )}
      <p className="acesso-links"><a href="#/entrar">Voltar para entrar</a></p>
    </Moldura>
  );
}

export function TelaNovaSenha({ aoConcluir }: { aoConcluir: () => void }) {
  const [senha, setSenha] = useState("");
  const [repetir, setRepetir] = useState("");
  const { enviando, erro, setErro, enviar } = useEnvio("nova-senha");
  return (
    <Moldura titulo="Criar nova senha">
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (senha.length < 8) { setErro("A senha precisa ter pelo menos 8 caracteres."); return; }
        if (senha !== repetir) { setErro("As duas senhas estão diferentes."); return; }
        void enviar(async () => { await definirSenha(senha); aoConcluir(); });
      }}>
        <Campo rotulo="Nova senha" ajuda="Pelo menos 8 caracteres.">{(id) => <input id={id} type="password" autoComplete="new-password" required value={senha} onChange={(e) => setSenha(e.target.value)} />}</Campo>
        <Campo rotulo="Repita a nova senha">{(id) => <input id={id} type="password" autoComplete="new-password" required value={repetir} onChange={(e) => setRepetir(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <button type="submit" className="botao botao-largo" disabled={enviando}>{enviando ? "Salvando…" : "Salvar nova senha"}</button>
      </form>
    </Moldura>
  );
}
