import { useState } from "react";
import { rpc } from "../lib/api";
import { formatarData, hoje, limitesDoMes, mesAtual } from "../lib/datas";
import type { APagarPorConta, Consolidado, LinhaSaldo } from "../lib/tipos";
import { Alerta, Carregando, TituloPagina, Valor, useCarregar } from "../ui";
import { DialogoLancamento } from "./lancamento";

const SITUACAO: Record<LinhaSaldo["situacao"], string> = {
  ok: "",
  saldo_inicial_nao_validado: "Saldo inicial a confirmar",
  data_anterior_a_data_base: "Data anterior ao saldo inicial",
  conta_arquivada: "Conta arquivada",
};

export function TelaSaldos() {
  const [data, setData] = useState(hoje());
  const [mostrarArquivadas, setMostrarArquivadas] = useState(false);
  const [lancando, setLancando] = useState(false);
  const fimDoMes = limitesDoMes(mesAtual())[1];
  const { dados, erro, carregando, recarregar } = useCarregar(async () => {
    const [linhas, consolidado, aPagar] = await Promise.all([
      rpc<LinhaSaldo[]>("saldos_por_conta", { p_data: data, p_projetar_ate: null }),
      rpc<Consolidado[]>("saldo_consolidado", { p_data: data }),
      rpc<APagarPorConta[]>("contas_a_pagar_por_conta", { p_ate: fimDoMes }),
    ]);
    return { linhas, total: consolidado[0], aPagar };
  }, [data]);

  const linhas = dados?.linhas ?? [];
  const ativas = linhas.filter((l) => l.ativa);
  const arquivadas = linhas.filter((l) => !l.ativa);
  const total = dados?.total;
  const ehHoje = data === hoje();
  const aPagar = dados?.aPagar ?? [];
  const totalAPagar = aPagar.reduce((s, l) => s + l.restante_centavos, 0);
  const vencidas = aPagar.reduce((s, l) => s + l.vencidas_centavos, 0);
  const aPagarDa = (conta: string) => aPagar.find((l) => l.conta_prevista_id === conta)?.restante_centavos ?? 0;

  return (
    <>
      <TituloPagina titulo="Saldos por conta">
        <label className="seletor-data">
          <span>Saldo em</span>
          <input type="date" value={data} max="2100-12-31" onChange={(e) => e.target.value && setData(e.target.value)} />
        </label>
        {ativas.length > 0 && <a className="botao-secundario" href="#/importar">Importar extrato</a>}
        {ativas.length > 0 && <button type="button" className="botao" onClick={() => setLancando(true)}>Novo lançamento</button>}
      </TituloPagina>

      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}

      {total && ativas.length > 0 && (
        <section className="consolidado" aria-label="Saldo consolidado">
          <p className="consolidado-rotulo">{ehHoje ? "Você tem hoje, somando as contas" : `Você tinha em ${formatarData(data)}, somando as contas`}</p>
          <p className="consolidado-valor"><Valor centavos={total.saldo_confirmado_centavos} /></p>
          <div className="consolidado-detalhes">
            {total.saldo_projetado_centavos !== total.saldo_confirmado_centavos && (
              <p>Com os previstos já lançados: <Valor centavos={total.saldo_projetado_centavos} /></p>
            )}
            <p>{total.contas_somadas === 1 ? "1 conta somada" : `${total.contas_somadas} contas somadas`}</p>
          </div>
          {totalAPagar > 0 && (
            <p className="a-pagar-resumo">
              <a href="#/a-pagar">Contas a pagar até {formatarData(fimDoMes)}: <Valor centavos={totalAPagar} /></a>
              {vencidas > 0 && <> · <span className="valor-saida">vencidas: <Valor centavos={vencidas} classe="valor-saida" /></span></>}
            </p>
          )}
          {!total.completo && (
            <Alerta tipo="aviso">
              {total.contas_pendentes === 1 ? "1 conta ficou" : `${total.contas_pendentes} contas ficaram`} fora da soma porque o saldo inicial ainda não foi confirmado
              ou a data escolhida é anterior a ele. Confira em <a href="#/contas">Contas</a>.
            </Alerta>
          )}
        </section>
      )}

      {dados && ativas.length === 0 && (
        <section className="vazio">
          <h2>Cadastre sua primeira conta</h2>
          <p>Informe o saldo do extrato em uma data. A partir dela, o Simplifica soma os lançamentos e mostra o saldo de cada conta.</p>
          <a className="botao" href="#/contas">Cadastrar conta</a>
        </section>
      )}

      {ativas.length > 0 && (
        <ul className="lista-contas">
          {ativas.map((l) => <CartaoConta key={l.conta_id} linha={l} aPagar={aPagarDa(l.conta_id)} />)}
        </ul>
      )}

      {arquivadas.length > 0 && (
        <div className="arquivadas">
          <button type="button" className="botao-texto" onClick={() => setMostrarArquivadas((v) => !v)} aria-expanded={mostrarArquivadas}>
            {mostrarArquivadas ? "Ocultar contas arquivadas" : `Mostrar contas arquivadas (${arquivadas.length})`}
          </button>
          {mostrarArquivadas && <ul className="lista-contas">{arquivadas.map((l) => <CartaoConta key={l.conta_id} linha={l} />)}</ul>}
        </div>
      )}

      {lancando && <DialogoLancamento aoFechar={() => setLancando(false)} aoConcluir={() => { setLancando(false); recarregar(); }} />}
    </>
  );
}

function CartaoConta({ linha, aPagar = 0 }: { linha: LinhaSaldo; aPagar?: number }) {
  const pendente = linha.saldo_confirmado_centavos === null;
  return (
    <li>
      <a className={`cartao-conta${linha.ativa ? "" : " cartao-arquivado"}`} href={`#/conta/${linha.conta_id}`}>
        <div className="cartao-conta-nome">
          <strong>{linha.apelido}</strong>
          {linha.instituicao !== linha.apelido && <span>{linha.instituicao}</span>}
          <span className="texto-suave">Titular: {linha.titular}</span>
        </div>
        <div className="cartao-conta-saldo">
          {pendente ? (
            <span className="selo selo-aviso">{SITUACAO[linha.situacao]}</span>
          ) : (
            <Valor centavos={linha.saldo_confirmado_centavos!} classe="valor-grande" />
          )}
          {!pendente && linha.saldo_projetado_centavos !== null && linha.saldo_projetado_centavos !== linha.saldo_confirmado_centavos && (
            <span className="texto-suave">Com previstos: <Valor centavos={linha.saldo_projetado_centavos} /></span>
          )}
          {aPagar > 0 && <span className="texto-suave">A pagar até o fim do mês: <Valor centavos={aPagar} /></span>}
          <span className="texto-suave">
            Saldo inicial em {formatarData(linha.saldo_inicial_data)}
            {!linha.incluir_consolidado && ", fora da soma"}
          </span>
        </div>
      </a>
    </li>
  );
}
