import { useState } from "react";
import { rpc } from "../lib/api";
import type { Categoria } from "../lib/tipos";
import { Alerta, Campo, Confirmar, Dialogo, TituloPagina, useCadastros, useEnvio } from "../ui";

type Acao = { tipo: "nova"; categoriaTipo: "receita" | "despesa" } | { tipo: "editar" | "arquivar"; categoria: Categoria } | null;

export function TelaCategorias() {
  const { categorias, erro, recarregar } = useCadastros();
  const [acao, setAcao] = useState<Acao>(null);
  const concluir = () => { setAcao(null); recarregar(); };

  const coluna = (tipo: "receita" | "despesa", titulo: string) => {
    const doTipo = categorias.filter((c) => c.tipo === tipo);
    const pais = doTipo.filter((c) => !c.pai_id).sort((a, b) => Number(b.ativa) - Number(a.ativa) || a.nome.localeCompare(b.nome, "pt-BR"));
    return (
      <section className="secao coluna-categorias">
        <div className="titulo-secao">
          <h2>{titulo}</h2>
          <button type="button" className="botao-secundario" onClick={() => setAcao({ tipo: "nova", categoriaTipo: tipo })}>Nova categoria</button>
        </div>
        <ul className="lista-simples">
          {pais.map((p) => (
            <li key={p.id} className="item-categoria">
              <Linha categoria={p} aoAgir={setAcao} />
              {doTipo.filter((f) => f.pai_id === p.id).map((f) => (
                <div key={f.id} className="subcategoria"><Linha categoria={f} aoAgir={setAcao} /></div>
              ))}
            </li>
          ))}
        </ul>
      </section>
    );
  };

  return (
    <>
      <TituloPagina titulo="Categorias" />
      {erro && <Alerta>{erro}</Alerta>}
      <div className="grade-colunas">
        {coluna("despesa", "Despesas")}
        {coluna("receita", "Receitas")}
      </div>
      {acao?.tipo === "nova" && <DialogoCategoria tipo={acao.categoriaTipo} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "editar" && <DialogoCategoria tipo={acao.categoria.tipo} categoria={acao.categoria} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "arquivar" && (
        <Confirmar
          titulo={acao.categoria.ativa ? "Arquivar categoria" : "Reativar categoria"}
          texto={acao.categoria.ativa
            ? <p>{acao.categoria.nome} deixa de aparecer em novos lançamentos. Os lançamentos antigos continuam com ela.</p>
            : <p>{acao.categoria.nome} volta a aparecer nos lançamentos.</p>}
          rotuloAcao={acao.categoria.ativa ? "Arquivar" : "Reativar"}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async () => {
            const c = acao.categoria;
            await rpc("categoria_atualizar", { p_id: c.id, p_versao_esperada: c.versao, p_nome: c.nome, p_cor: c.cor, p_ativa: !c.ativa, p_chave_idempotencia: null });
            concluir();
          }}
        />
      )}
    </>
  );
}

function Linha({ categoria, aoAgir }: { categoria: Categoria; aoAgir: (a: Acao) => void }) {
  return (
    <div className={`linha-categoria${categoria.ativa ? "" : " linha-arquivada"}`}>
      <span>{categoria.nome}{!categoria.ativa && <span className="selo">Arquivada</span>}</span>
      <span className="acoes-linha">
        {categoria.ativa && <button type="button" className="botao-texto" onClick={() => aoAgir({ tipo: "editar", categoria })}>Renomear</button>}
        <button type="button" className="botao-texto" onClick={() => aoAgir({ tipo: "arquivar", categoria })}>{categoria.ativa ? "Arquivar" : "Reativar"}</button>
      </span>
    </div>
  );
}

function DialogoCategoria({ tipo, categoria, aoFechar, aoConcluir }: { tipo: "receita" | "despesa"; categoria?: Categoria; aoFechar: () => void; aoConcluir: () => void }) {
  const { categorias } = useCadastros();
  const [nome, setNome] = useState(categoria?.nome ?? "");
  const [pai, setPai] = useState("");
  const { chave, enviando, erro, setErro, enviar } = useEnvio(categoria ? "categoria-editar" : "categoria-criar");
  const pais = categorias.filter((c) => c.tipo === tipo && !c.pai_id && c.ativa);
  return (
    <Dialogo titulo={categoria ? "Renomear categoria" : tipo === "despesa" ? "Nova categoria de despesa" : "Nova categoria de receita"} aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!nome.trim()) return setErro("Escreva o nome.");
        void enviar(async () => {
          if (categoria) {
            await rpc("categoria_atualizar", { p_id: categoria.id, p_versao_esperada: categoria.versao, p_nome: nome, p_cor: categoria.cor, p_ativa: categoria.ativa, p_chave_idempotencia: chave });
          } else {
            await rpc("categoria_criar", { p_nome: nome, p_tipo: tipo, p_pai_id: pai || null, p_cor: null, p_chave_idempotencia: chave });
          }
          aoConcluir();
        });
      }}>
        <Campo rotulo="Nome">{(id) => <input id={id} required maxLength={60} value={nome} onChange={(e) => setNome(e.target.value)} />}</Campo>
        {!categoria && (
          <Campo rotulo="Dentro de (opcional)" ajuda="Para criar uma subcategoria, por exemplo Moradia › Condomínio.">
            {(id) => (
              <select id={id} value={pai} onChange={(e) => setPai(e.target.value)}>
                <option value="">Nenhuma (categoria principal)</option>
                {pais.map((p) => <option key={p.id} value={p.id}>{p.nome}</option>)}
              </select>
            )}
          </Campo>
        )}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Cancelar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Salvar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
