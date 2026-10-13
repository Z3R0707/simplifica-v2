import { useState } from "react";
import { rpc } from "../lib/api";
import { limitesDoMes, mesAtual, nomeDoMes } from "../lib/datas";
import type { LinhaResumo } from "../lib/tipos";
import { Alerta, Carregando, TituloPagina, Valor, useCadastros, useCarregar } from "../ui";

export function TelaResumo() {
  const { contas } = useCadastros();
  const [mes, setMes] = useState(mesAtual());
  const [conta, setConta] = useState("");
  const { dados, erro, carregando } = useCarregar(async () => {
    const [inicio, fim] = limitesDoMes(mes);
    return rpc<LinhaResumo[]>("resumo_categorias", { p_inicio: inicio, p_fim: fim, p_conta_id: conta || null });
  }, [mes, conta]);

  const linhas = dados ?? [];
  const receitas = linhas.filter((l) => l.classificacao === "receita");
  const despesas = linhas.filter((l) => l.classificacao === "despesa");
  const semCategoria = linhas.filter((l) => l.classificacao === "nao_classificado");
  const soma = (ls: LinhaResumo[]) => ls.reduce((s, l) => s + l.total_centavos, 0);
  const totalReceitas = soma(receitas);
  const totalDespesas = soma(despesas);

  return (
    <>
      <TituloPagina titulo="Receitas e despesas">
        <label className="seletor-data"><span>Mês</span>
          <input type="month" value={mes} onChange={(e) => e.target.value && setMes(e.target.value)} />
        </label>
        <label className="seletor-data"><span>Conta</span>
          <select value={conta} onChange={(e) => setConta(e.target.value)}>
            <option value="">Todas</option>
            {contas.map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
          </select>
        </label>
      </TituloPagina>
      <p className="texto-suave">{nomeDoMes(mes)}. Considera só o que já aconteceu; previstos e cancelados ficam de fora. Compras no cartão entram no mês em que a fatura vence; o pagamento da fatura não conta como despesa.</p>
      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}

      {dados && (
        <>
          <section className="totais">
            <div><p className="texto-suave">Receitas</p><p className="valor-destaque"><Valor centavos={totalReceitas} /></p></div>
            <div><p className="texto-suave">Despesas</p><p className="valor-destaque"><Valor centavos={totalDespesas} /></p></div>
            <div><p className="texto-suave">Resultado</p><p className="valor-destaque"><Valor centavos={totalReceitas - totalDespesas} sinal /></p></div>
          </section>
          {linhas.length === 0 && <section className="vazio"><h2>Nenhum lançamento neste mês</h2></section>}
          <div className="grade-colunas">
            {despesas.length > 0 && <Grupo titulo="Despesas por categoria" linhas={despesas} total={totalDespesas} classe="barra-saida" />}
            {receitas.length > 0 && <Grupo titulo="Receitas por categoria" linhas={receitas} total={totalReceitas} classe="barra-entrada" />}
          </div>
          {semCategoria.length > 0 && (
            <Alerta tipo="aviso">
              {semCategoria[0].movimentos === 1 ? "1 lançamento" : `${semCategoria[0].movimentos} lançamentos`} sem categoria somam <Valor centavos={semCategoria[0].total_centavos} sinal />.
              Edite-os no extrato da conta para entrarem no resumo.
            </Alerta>
          )}
        </>
      )}
    </>
  );
}

function Grupo({ titulo, linhas, total, classe }: { titulo: string; linhas: LinhaResumo[]; total: number; classe: string }) {
  const maior = Math.max(...linhas.map((l) => Math.abs(l.total_centavos)), 1);
  return (
    <section className="secao">
      <h2>{titulo}</h2>
      <ul className="lista-barras">
        {[...linhas].sort((a, b) => b.total_centavos - a.total_centavos).map((l) => (
          <li key={l.categoria_id ?? l.categoria}>
            <div className="barra-rotulo">
              <span>{l.categoria}</span>
              <Valor centavos={l.total_centavos} />
            </div>
            <div className="barra-trilho" aria-hidden="true">
              <div className={`barra ${classe}`} style={{ width: `${Math.max(2, (Math.abs(l.total_centavos) / maior) * 100)}%` }} />
            </div>
            <span className="texto-suave">{l.movimentos === 1 ? "1 lançamento" : `${l.movimentos} lançamentos`}{total > 0 ? `, ${Math.round((l.total_centavos / total) * 100)}% do total` : ""}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
