import { useMemo, useState } from "react";
import { listar, rpc } from "../lib/api";
import { formatarData, hoje } from "../lib/datas";
import { formatarCentavos } from "../lib/dinheiro";
import type { LinhaExtrato, LinhaSaldo, Movimento, PagamentoAtivo } from "../lib/tipos";
import { Alerta, Carregando, TituloPagina, Valor, useCadastros, useCarregar } from "../ui";
import { DialogoCancelar, DialogoEfetivar, DialogoLancamento } from "./lancamento";

type Acao = { tipo: "novo" } | { tipo: "editar" | "efetivar" | "cancelar"; mov: Movimento } | null;

export function TelaExtrato({ contaId }: { contaId: string }) {
  const { contas } = useCadastros();
  const conta = contas.find((c) => c.id === contaId);
  const [acao, setAcao] = useState<Acao>(null);
  const [mostrarCancelados, setMostrarCancelados] = useState(false);
  const { dados, erro, carregando, recarregar } = useCarregar(async () => {
    const [linhas, movimentos, saldos, pagamentos] = await Promise.all([
      rpc<LinhaExtrato[]>("extrato_conta", { p_conta_id: contaId, p_inicio: null, p_fim: null }),
      listar<Movimento>("movimentos", { conta_id: `eq.${contaId}` }),
      rpc<LinhaSaldo[]>("saldos_por_conta", { p_data: hoje(), p_projetar_ate: null }),
      listar<PagamentoAtivo>("pagamentos", { situacao: "eq.ativo" }),
    ]);
    const pagaConta = new Set(pagamentos.filter((p) => p.situacao === "ativo").map((p) => p.movimento_id));
    const daConta = movimentos.filter((m) => m.conta_id === contaId);
    const porId = new Map(daConta.map((m) => [m.id, m]));
    const parciais = new Map<string, number>();
    for (const m of daConta) {
      if (m.estorno_de && m.situacao !== "cancelado") parciais.set(m.estorno_de, (parciais.get(m.estorno_de) ?? 0) + m.valor_centavos);
    }
    return { linhas, porId, parciais, pagaConta, saldo: saldos.find((s) => s.conta_id === contaId) ?? null };
  }, [contaId]);

  const visiveis = useMemo(
    () => (dados?.linhas ?? []).filter((l) => mostrarCancelados || l.situacao !== "cancelado").slice().reverse(),
    [dados, mostrarCancelados],
  );
  const qtdCancelados = (dados?.linhas ?? []).filter((l) => l.situacao === "cancelado").length;

  if (!conta && !carregando) {
    return <Alerta>Conta não encontrada. <a href="#/saldos">Voltar para saldos</a></Alerta>;
  }
  const saldo = dados?.saldo;
  const concluir = () => { setAcao(null); recarregar(); };

  return (
    <>
      <p className="trilha"><a href="#/saldos">Saldos</a></p>
      <TituloPagina titulo={conta?.apelido ?? "Conta"}>
        {conta?.ativa && <button type="button" className="botao" onClick={() => setAcao({ tipo: "novo" })}>Novo lançamento</button>}
      </TituloPagina>

      {saldo && (
        <section className="resumo-conta">
          <div>
            <p className="texto-suave">Saldo hoje</p>
            {saldo.saldo_confirmado_centavos === null
              ? <p className="selo selo-aviso">Saldo inicial a confirmar</p>
              : <p className="valor-destaque"><Valor centavos={saldo.saldo_confirmado_centavos} /></p>}
          </div>
          {saldo.saldo_projetado_centavos !== null && saldo.saldo_projetado_centavos !== saldo.saldo_confirmado_centavos && (
            <div><p className="texto-suave">Com previstos</p><p className="valor-destaque"><Valor centavos={saldo.saldo_projetado_centavos} /></p></div>
          )}
          <div>
            <p className="texto-suave">Saldo inicial em {formatarData(saldo.saldo_inicial_data)}</p>
            <p className="valor-destaque"><Valor centavos={saldo.saldo_inicial_centavos} /></p>
          </div>
        </section>
      )}

      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}

      {dados && dados.linhas.length === 0 && (
        <section className="vazio">
          <h2>Nenhum lançamento nesta conta</h2>
          <p>Registre entradas e saídas para acompanhar o saldo.</p>
        </section>
      )}

      {visiveis.length > 0 && (
        <div className="tabela-rolagem">
          <table className="tabela extrato">
            <thead>
              <tr><th>Data</th><th>Descrição</th><th className="num">Valor</th><th className="num">Saldo após</th><th><span className="sr">Ações</span></th></tr>
            </thead>
            <tbody>
              {visiveis.map((l) => {
                const mov = dados!.porId.get(l.movimento_id);
                return (
                  <tr key={l.movimento_id} className={`linha-${l.situacao}${!l.conta_no_saldo && l.situacao === "efetivo" ? " linha-fora" : ""}`}>
                    <td className="data">{formatarData(l.data_movimento)}</td>
                    <td>
                      <span className="descricao">{l.descricao}</span>
                      <span className="texto-suave">{l.categoria ?? "Sem categoria"}</span>
                      {l.situacao === "previsto" && <span className="selo selo-previsto">Previsto</span>}
                      {l.situacao === "cancelado" && <span className="selo">Cancelado{mov?.cancelado_motivo ? `: ${mov.cancelado_motivo}` : ""}</span>}
                      {l.situacao === "efetivo" && !l.conta_no_saldo && <span className="selo selo-neutro">Já incluído no saldo inicial</span>}
                      {mov?.estorno_de && dados!.porId.get(mov.estorno_de) && (
                        <span className="selo selo-neutro">Cancelamento parcial do lançamento de {formatarData(dados!.porId.get(mov.estorno_de)!.data_movimento)}</span>
                      )}
                      {l.situacao !== "cancelado" && dados!.pagaConta.has(l.movimento_id) && (
                        <a className="selo selo-ok" href="#/a-pagar">Pagamento de conta a pagar</a>
                      )}
                      {mov && !mov.estorno_de && (dados!.parciais.get(mov.id) ?? 0) > 0 && (
                        <span className="selo selo-neutro">Cancelado parcialmente: {formatarCentavos(dados!.parciais.get(mov.id)!)} de {formatarCentavos(mov.valor_centavos)}</span>
                      )}
                    </td>
                    <td className="num"><Valor centavos={l.valor_assinado_centavos} sinal /></td>
                    <td className="num saldo-apos">{l.saldo_apos_centavos !== null ? <><span className="rotulo-celular">Saldo após </span><Valor centavos={l.saldo_apos_centavos} /></> : ""}</td>
                    <td className="acoes-linha">
                      {mov && l.situacao !== "cancelado" && conta?.ativa && (
                        <>
                          {l.situacao === "previsto" && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "efetivar", mov })}>Aconteceu</button>}
                          <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar", mov })}>Editar</button>
                          <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setAcao({ tipo: "cancelar", mov })}>Cancelar</button>
                        </>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {qtdCancelados > 0 && (
        <button type="button" className="botao-texto" onClick={() => setMostrarCancelados((v) => !v)}>
          {mostrarCancelados ? "Ocultar cancelados" : `Mostrar cancelados (${qtdCancelados})`}
        </button>
      )}

      {acao?.tipo === "novo" && <DialogoLancamento contaId={contaId} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "editar" && <DialogoLancamento movimento={acao.mov} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "efetivar" && <DialogoEfetivar movimento={acao.mov} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "cancelar" && (
        <DialogoCancelar
          movimento={acao.mov}
          jaCancelado={dados?.parciais.get(acao.mov.id) ?? 0}
          pagaConta={dados?.pagaConta.has(acao.mov.id) ?? false}
          aoFechar={() => setAcao(null)}
          aoConcluir={concluir}
        />
      )}
    </>
  );
}
