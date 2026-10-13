import { useMemo, useState } from "react";
import { rpc } from "../lib/api";
import { hoje, dataValida, formatarData } from "../lib/datas";
import { centavosParaCampo, formatarCentavos, lerValor } from "../lib/dinheiro";
import type { Classificacao, Movimento } from "../lib/tipos";
import { Alerta, Campo, Dialogo, useCadastros, useEnvio } from "../ui";

type Props = {
  contaId?: string;
  movimento?: Movimento;
  aoFechar: () => void;
  aoConcluir: () => void;
};

// Tipo escolhido na tela. Despesa sempre sai e receita sempre entra; o
// sentido só é livre em "Sem categoria". Estorno (despesa que volta) é uma
// escolha explícita, para não acontecer por engano.
type TipoTela = "despesa" | "receita" | "estorno" | "devolucao_receita" | "sem_categoria";
const MAPA_TIPO: Record<Exclude<TipoTela, "sem_categoria">, { classificacao: Classificacao; natureza: "debito" | "credito" }> = {
  despesa: { classificacao: "despesa", natureza: "debito" },
  receita: { classificacao: "receita", natureza: "credito" },
  estorno: { classificacao: "despesa", natureza: "credito" },
  devolucao_receita: { classificacao: "receita", natureza: "debito" },
};
function tipoDoMovimento(m?: Movimento): TipoTela {
  if (!m) return "despesa";
  if (m.classificacao === "nao_classificado") return "sem_categoria";
  if (m.classificacao === "despesa") return m.natureza === "credito" ? "estorno" : "despesa";
  return m.natureza === "debito" ? "devolucao_receita" : "receita";
}

export function DialogoLancamento({ contaId, movimento, aoFechar, aoConcluir }: Props) {
  const { contas, categorias } = useCadastros();
  const editando = Boolean(movimento);
  const contasAtivas = contas.filter((c) => c.ativa || c.id === movimento?.conta_id);
  const [conta, setConta] = useState(movimento?.conta_id ?? contaId ?? contasAtivas[0]?.id ?? "");
  const [tipo, setTipo] = useState<TipoTela>(tipoDoMovimento(movimento));
  const [naturezaLivre, setNaturezaLivre] = useState<"debito" | "credito">(movimento?.natureza ?? "debito");
  const classificacao: Classificacao = tipo === "sem_categoria" ? "nao_classificado" : MAPA_TIPO[tipo].classificacao;
  const natureza: "debito" | "credito" = tipo === "sem_categoria" ? naturezaLivre : MAPA_TIPO[tipo].natureza;
  const [valor, setValor] = useState(movimento ? centavosParaCampo(movimento.valor_centavos) : "");
  const [data, setData] = useState(movimento?.data_movimento ?? hoje());
  const [situacao, setSituacao] = useState<"efetivo" | "previsto">(movimento?.situacao === "previsto" ? "previsto" : "efetivo");
  const [descricao, setDescricao] = useState(movimento?.descricao ?? "");
  const [categoria, setCategoria] = useState(movimento?.categoria_id ?? "");
  const [observacao, setObservacao] = useState(movimento?.observacao ?? "");
  const { chave, enviando, erro, setErro, enviar } = useEnvio(editando ? "mov-editar" : "mov-criar");

  const contaEscolhida = contas.find((c) => c.id === conta);
  const opcoesCategoria = useMemo(() => {
    if (classificacao === "nao_classificado") return [];
    const doTipo = categorias.filter((c) => c.tipo === classificacao && (c.ativa || c.id === movimento?.categoria_id));
    const pais = doTipo.filter((c) => !c.pai_id);
    return pais.flatMap((p) => [
      { id: p.id, nome: p.nome },
      ...doTipo.filter((f) => f.pai_id === p.id).map((f) => ({ id: f.id, nome: `${p.nome} › ${f.nome}` })),
    ]);
  }, [categorias, classificacao, movimento?.categoria_id]);

  function trocarTipo(t: TipoTela) {
    const antes = tipo === "sem_categoria" ? "nao_classificado" : MAPA_TIPO[tipo].classificacao;
    const depois = t === "sem_categoria" ? "nao_classificado" : MAPA_TIPO[t].classificacao;
    setTipo(t);
    if (antes !== depois) setCategoria("");
  }

  function validar(): { centavos: number } | null {
    const centavos = lerValor(valor);
    if (!conta) return setErro("Escolha a conta."), null;
    if (centavos === null || centavos <= 0) return setErro("Informe um valor maior que zero, por exemplo 125,90."), null;
    if (!dataValida(data)) return setErro("Informe uma data válida."), null;
    if (!descricao.trim()) return setErro("Escreva uma descrição."), null;
    if (classificacao !== "nao_classificado" && !categoria) return setErro("Escolha a categoria."), null;
    if (!editando && situacao === "efetivo" && data > hoje()) {
      return setErro("Para uma data futura, marque como previsto."), null;
    }
    if (!editando && situacao === "previsto" && contaEscolhida && data <= contaEscolhida.saldo_inicial_data) {
      return setErro(`O previsto precisa ser depois de ${formatarData(contaEscolhida.saldo_inicial_data)}, a data do saldo inicial da conta.`), null;
    }
    return { centavos };
  }

  return (
    <Dialogo titulo={editando ? "Editar lançamento" : "Novo lançamento"} aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const ok = validar();
        if (!ok) return;
        void enviar(async () => {
          const categoriaId = classificacao === "nao_classificado" ? null : categoria;
          if (movimento) {
            await rpc("movimento_atualizar", {
              p_id: movimento.id, p_versao_esperada: movimento.versao, p_natureza: natureza,
              p_valor_centavos: ok.centavos, p_data: data, p_descricao: descricao,
              p_classificacao: classificacao, p_categoria_id: categoriaId, p_observacao: observacao,
              p_chave_idempotencia: chave,
            });
          } else {
            await rpc("movimento_criar", {
              p_conta_id: conta, p_natureza: natureza, p_valor_centavos: ok.centavos, p_data: data,
              p_descricao: descricao, p_classificacao: classificacao, p_categoria_id: categoriaId,
              p_situacao: situacao, p_observacao: observacao, p_chave_idempotencia: chave,
            });
          }
          aoConcluir();
        });
      }}>
        <div className="grade-2">
          <Campo rotulo="Conta">
            {(id) => (
              <select id={id} value={conta} onChange={(e) => setConta(e.target.value)} disabled={editando} required>
                {contasAtivas.length === 0 && <option value="">Cadastre uma conta primeiro</option>}
                {contasAtivas.map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
              </select>
            )}
          </Campo>
          {!editando && (
            <fieldset className="campo opcoes">
              <legend>Situação</legend>
              <label><input type="radio" name="situacao" checked={situacao === "efetivo"} onChange={() => setSituacao("efetivo")} /> Já aconteceu</label>
              <label><input type="radio" name="situacao" checked={situacao === "previsto"} onChange={() => setSituacao("previsto")} /> Previsto</label>
            </fieldset>
          )}
        </div>

        <fieldset className="campo opcoes">
          <legend>Tipo</legend>
          <label><input type="radio" name="tipo" checked={tipo === "despesa"} onChange={() => trocarTipo("despesa")} /> Despesa</label>
          <label><input type="radio" name="tipo" checked={tipo === "receita"} onChange={() => trocarTipo("receita")} /> Receita</label>
          <label><input type="radio" name="tipo" checked={tipo === "estorno"} onChange={() => trocarTipo("estorno")} /> Estorno de despesa</label>
          {tipo === "devolucao_receita" && (
            <label><input type="radio" name="tipo" checked onChange={() => trocarTipo("devolucao_receita")} /> Devolução de receita</label>
          )}
          <label><input type="radio" name="tipo" checked={tipo === "sem_categoria"} onChange={() => trocarTipo("sem_categoria")} /> Sem categoria</label>
          <p className="campo-ajuda">
            {tipo === "despesa" && "Dinheiro que saiu da conta."}
            {tipo === "receita" && "Dinheiro que entrou na conta."}
            {tipo === "estorno" && "Dinheiro que voltou para a conta por uma despesa desfeita (compra cancelada, reembolso). Entra na conta e reduz o total gasto na categoria."}
            {tipo === "devolucao_receita" && "Dinheiro que saiu da conta por uma receita devolvida. Reduz o total recebido na categoria."}
            {tipo === "sem_categoria" && "Escolha abaixo se o dinheiro entrou ou saiu. Não entra no resumo por categoria."}
          </p>
        </fieldset>

        {tipo === "sem_categoria" && (
          <fieldset className="campo opcoes">
            <legend>Na conta, o dinheiro</legend>
            <label><input type="radio" name="natureza" checked={naturezaLivre === "debito"} onChange={() => setNaturezaLivre("debito")} /> Saiu</label>
            <label><input type="radio" name="natureza" checked={naturezaLivre === "credito"} onChange={() => setNaturezaLivre("credito")} /> Entrou</label>
          </fieldset>
        )}

        <div className="grade-2">
          <Campo rotulo="Valor (R$)" ajuda={lerValor(valor) ? `${natureza === "credito" ? "Entra" : "Sai"} ${formatarCentavos(lerValor(valor)!)}` : "Ex.: 125,90"}>
            {(id) => <input id={id} inputMode="decimal" autoComplete="off" required value={valor} onChange={(e) => setValor(e.target.value)} />}
          </Campo>
          <Campo rotulo={situacao === "previsto" && !editando ? "Data prevista" : "Data"}>
            {(id) => <input id={id} type="date" required value={data} onChange={(e) => setData(e.target.value)} />}
          </Campo>
        </div>

        <Campo rotulo="Descrição">
          {(id) => <input id={id} required maxLength={200} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Ex.: Supermercado" />}
        </Campo>

        {classificacao !== "nao_classificado" && (
          <Campo rotulo="Categoria">
            {(id) => (
              <select id={id} required value={categoria} onChange={(e) => setCategoria(e.target.value)}>
                <option value="">Escolha…</option>
                {opcoesCategoria.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
              </select>
            )}
          </Campo>
        )}

        <Campo rotulo="Observação (opcional)">
          {(id) => <textarea id={id} rows={2} maxLength={500} value={observacao} onChange={(e) => setObservacao(e.target.value)} />}
        </Campo>

        {contaEscolhida && data <= contaEscolhida.saldo_inicial_data && situacao === "efetivo" && (
          <Alerta tipo="aviso">
            Esta data é igual ou anterior a {formatarData(contaEscolhida.saldo_inicial_data)}, a data do saldo inicial da conta.
            O lançamento fica registrado e entra nos relatórios, mas não altera o saldo, porque já está dentro do saldo inicial.
          </Alerta>
        )}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Cancelar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : editando ? "Salvar alterações" : "Lançar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

export function DialogoEfetivar({ movimento, aoFechar, aoConcluir }: { movimento: Movimento; aoFechar: () => void; aoConcluir: () => void }) {
  const [data, setData] = useState(movimento.data_movimento <= hoje() ? movimento.data_movimento : hoje());
  const [valor, setValor] = useState(centavosParaCampo(movimento.valor_centavos));
  const { chave, enviando, erro, setErro, enviar } = useEnvio("mov-efetivar");
  return (
    <Dialogo titulo="Confirmar que aconteceu" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const centavos = lerValor(valor);
        if (centavos === null || centavos <= 0) { setErro("Informe um valor maior que zero."); return; }
        if (!dataValida(data) || data > hoje()) { setErro("Informe a data em que aconteceu (hoje ou antes)."); return; }
        void enviar(async () => {
          await rpc("movimento_efetivar", {
            p_id: movimento.id, p_versao_esperada: movimento.versao, p_data_efetiva: data,
            p_valor_centavos: centavos === movimento.valor_centavos ? null : centavos, p_chave_idempotencia: chave,
          });
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto">{movimento.descricao}: o previsto passa a contar no saldo da conta. Nenhum lançamento novo é criado.</p>
        <div className="grade-2">
          <Campo rotulo="Data em que aconteceu">{(id) => <input id={id} type="date" required value={data} max={hoje()} onChange={(e) => setData(e.target.value)} />}</Campo>
          <Campo rotulo="Valor efetivo (R$)">{(id) => <input id={id} inputMode="decimal" required value={valor} onChange={(e) => setValor(e.target.value)} />}</Campo>
        </div>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Confirmar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
