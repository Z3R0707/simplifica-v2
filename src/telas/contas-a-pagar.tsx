import { useMemo, useState } from "react";
import { rpc, listar } from "../lib/api";
import { dataValida, formatarData, hoje, limitesDoMes, mesAtual, nomeDoMes } from "../lib/datas";
import { centavosParaCampo, formatarCentavos, lerValor } from "../lib/dinheiro";
import type { LinhaContaAPagar, LinhaPagamento, MovimentoVinculavel, Recorrencia, StatusContaAPagar } from "../lib/tipos";
import { Alerta, Campo, Carregando, Confirmar, Dialogo, TituloPagina, Valor, useCadastros, useCarregar, useEnvio } from "../ui";

const STATUS: Record<StatusContaAPagar, { nome: string; classe: string }> = {
  a_vencer: { nome: "A vencer", classe: "selo-neutro" },
  parcial: { nome: "Paga em parte", classe: "selo-previsto" },
  vencida: { nome: "Vencida", classe: "selo-perigo" },
  paga: { nome: "Paga", classe: "selo-ok" },
  cancelada: { nome: "Cancelada", classe: "" },
};

type Filtro = "abertas" | "pagas" | "todas";
type Acao =
  | { tipo: "nova" }
  | { tipo: "editar" | "pagar" | "detalhes" | "cancelar" | "reabrir"; linha: LinhaContaAPagar }
  | { tipo: "editar-rec" | "encerrar-rec" | "retomar-rec"; rec: Recorrencia }
  | null;

function somarMeses(mes: string, n: number): string {
  const [a, m] = mes.split("-").map(Number);
  const d = new Date(Date.UTC(a, m - 1 + n, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
const mesDe = (iso: string) => iso.slice(0, 7);
const nomeCurtoDoMes = (iso: string) => {
  const [a, m] = iso.split("-").map(Number);
  return new Intl.DateTimeFormat("pt-BR", { month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(a, m - 1, 1))).replace(".", "");
};

export function TelaContasAPagar() {
  const { contas } = useCadastros();
  const [mes, setMes] = useState(mesAtual());
  const [filtro, setFiltro] = useState<Filtro>("abertas");
  const [acao, setAcao] = useState<Acao>(null);
  const ehMesAtual = mes === mesAtual();

  const { dados, erro, carregando, recarregar } = useCarregar(async () => {
    const [inicio, fim] = limitesDoMes(mes);
    // meses das recorrências são criados quando você chega neles
    if (mes >= mesAtual()) await rpc<number>("recorrencias_gerar", { p_ate: fim });
    const [linhas, recorrencias] = await Promise.all([
      rpc<LinhaContaAPagar[]>("contas_a_pagar", { p_inicio: inicio, p_fim: fim, p_incluir_vencidas: mes === mesAtual() }),
      listar<Recorrencia>("recorrencias"),
    ]);
    // faturas de cartão (para o link "Ver fatura") e contas com algum pagamento, mesmo desfeito
    const [faturas, pagamentos] = await Promise.all([
      listar<{ obrigacao_id: string | null; cartao_id: string; competencia: string }>("faturas"),
      listar<{ obrigacao_id: string }>("pagamentos"),
    ]);
    const faturaDe = new Map(faturas.filter((f) => f.obrigacao_id).map((f) => [f.obrigacao_id as string, f]));
    const comHistorico = new Set(pagamentos.map((p) => p.obrigacao_id));
    return { linhas, recorrencias, inicio, faturaDe, comHistorico };
  }, [mes]);

  const linhas = dados?.linhas ?? [];
  const doMes = linhas.filter((l) => dados && l.vencimento >= dados.inicio && l.situacao === "aberta");
  const anteriores = linhas.filter((l) => dados && l.vencimento < dados.inicio);
  const totalMes = doMes.reduce((s, l) => s + l.valor_centavos, 0);
  const pagoMes = doMes.reduce((s, l) => s + l.abatido_centavos, 0);
  const faltaPagar = linhas.filter((l) => l.situacao === "aberta").reduce((s, l) => s + l.restante_centavos, 0);
  const vencidas = linhas.filter((l) => l.status === "vencida").reduce((s, l) => s + l.restante_centavos, 0);

  const visiveis = useMemo(() => linhas.filter((l) => {
    if (filtro === "abertas") return l.status === "a_vencer" || l.status === "parcial" || l.status === "vencida";
    if (filtro === "pagas") return l.status === "paga";
    return true;
  }), [linhas, filtro]);

  const recorrencias = (dados?.recorrencias ?? []).slice().sort((a, b) => a.descricao.localeCompare(b.descricao, "pt-BR"));
  const recPorId = new Map(recorrencias.map((r) => [r.id, r]));
  const concluir = () => { setAcao(null); recarregar(); };
  const temContas = contas.some((c) => c.ativa);

  return (
    <>
      <TituloPagina titulo="Contas a pagar">
        <div className="seletor-mes">
          <button type="button" className="botao-secundario botao-icone" aria-label="Mês anterior" onClick={() => setMes(somarMeses(mes, -1))}>‹</button>
          <label className="seletor-data"><span>Mês</span>
            <input type="month" value={mes} onChange={(e) => e.target.value && setMes(e.target.value)} />
          </label>
          <button type="button" className="botao-secundario botao-icone" aria-label="Próximo mês" onClick={() => setMes(somarMeses(mes, 1))}>›</button>
        </div>
        <button type="button" className="botao" onClick={() => setAcao({ tipo: "nova" })}>Nova conta a pagar</button>
      </TituloPagina>
      <p className="texto-suave">
        {nomeDoMes(mes)}. Uma conta a pagar não mexe no saldo; o saldo muda quando você registra o pagamento.
      </p>

      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}

      {dados && (
        <section className="totais" aria-label="Totais do mês">
          <div><p className="texto-suave">Vencem no mês</p><p className="valor-destaque"><Valor centavos={totalMes} /></p></div>
          <div><p className="texto-suave">Já pago</p><p className="valor-destaque"><Valor centavos={pagoMes} /></p></div>
          <div><p className="texto-suave">{anteriores.length > 0 ? "Falta pagar (com atrasadas)" : "Falta pagar"}</p><p className="valor-destaque"><Valor centavos={faltaPagar} /></p></div>
          {vencidas > 0 && <div><p className="texto-suave">Vencidas</p><p className="valor-destaque valor-saida"><Valor centavos={vencidas} classe="valor-saida" /></p></div>}
        </section>
      )}

      {dados && (
        <div className="filtros" role="group" aria-label="Mostrar">
          {(["abertas", "pagas", "todas"] as Filtro[]).map((f) => (
            <button key={f} type="button" className="filtro" aria-pressed={filtro === f} onClick={() => setFiltro(f)}>
              {f === "abertas" ? "Em aberto" : f === "pagas" ? "Pagas" : "Todas"}
            </button>
          ))}
        </div>
      )}

      {dados && visiveis.length === 0 && (
        <section className="vazio">
          <h2>{linhas.length === 0 ? "Nenhuma conta a pagar neste mês" : filtro === "abertas" ? "Tudo pago neste mês" : "Nada para mostrar com este filtro"}</h2>
          {linhas.length === 0 && <p>Cadastre aluguel, escola, luz, parcelas… Para o que se repete, marque “Todo mês”.</p>}
        </section>
      )}

      {visiveis.length > 0 && (
        <div className="tabela-rolagem">
          <table className="tabela extrato contas-pagar">
            <thead>
              <tr><th>Vencimento</th><th>Descrição</th><th className="num">Valor</th><th><span className="sr">Ações</span></th></tr>
            </thead>
            <tbody>
              {visiveis.map((l) => {
                const rec = l.recorrencia_id ? recPorId.get(l.recorrencia_id) : undefined;
                const fat = l.origem === "fatura" ? dados?.faturaDe.get(l.obrigacao_id) : undefined;
                return (
                  <tr key={l.obrigacao_id} className={l.situacao === "cancelada" ? "linha-cancelado" : l.status === "vencida" ? "linha-vencida" : ""}>
                    <td className="data">{formatarData(l.vencimento)}</td>
                    <td>
                      <span className="descricao">{l.descricao}</span>
                      <span className="texto-suave">
                        {l.origem === "fatura" ? "Fatura de cartão" : l.categoria ?? "Sem categoria"}{l.conta_prevista ? ` · pagar pelo ${l.conta_prevista}` : ""}{rec ? " · repete todo mês" : ""}
                      </span>
                      <span className={`selo ${STATUS[l.status].classe}`}>{STATUS[l.status].nome}{l.status === "cancelada" && l.cancelada_motivo ? `: ${l.cancelada_motivo}` : ""}</span>
                      {l.vencimento < (dados?.inicio ?? "") && <span className="selo selo-neutro">De {nomeCurtoDoMes(l.competencia)}</span>}
                    </td>
                    <td className="num">
                      <Valor centavos={l.valor_centavos} />
                      {l.abatido_centavos > 0 && l.restante_centavos > 0 && (
                        <span className="texto-suave">Falta <Valor centavos={l.restante_centavos} /></span>
                      )}
                      {l.juros_centavos + l.multa_centavos > 0 && (
                        <span className="texto-suave">+ {formatarCentavos(l.juros_centavos + l.multa_centavos)} de juros/multa</span>
                      )}
                      {l.desconto_centavos > 0 && <span className="texto-suave">− {formatarCentavos(l.desconto_centavos)} de desconto</span>}
                    </td>
                    <td className="acoes-linha">
                      {l.situacao === "aberta" && l.restante_centavos > 0 && (
                        <button type="button" className="botao-texto" disabled={!temContas} onClick={() => setAcao({ tipo: "pagar", linha: l })}>Pagar</button>
                      )}
                      {fat && <a className="botao-texto" href={`#/cartao/${fat.cartao_id}/${fat.competencia.slice(0, 7)}`}>Ver fatura</a>}
                      {(l.pagamentos > 0 || dados?.comHistorico.has(l.obrigacao_id)) && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "detalhes", linha: l })}>Pagamentos</button>}
                      {l.situacao === "aberta" && l.origem !== "fatura" && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar", linha: l })}>Editar</button>}
                      {l.situacao === "aberta" && l.pagamentos === 0 && l.origem !== "fatura" && (
                        <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setAcao({ tipo: "cancelar", linha: l })}>Cancelar</button>
                      )}
                      {l.situacao === "cancelada" && l.origem !== "fatura" && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "reabrir", linha: l })}>Reabrir</button>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {ehMesAtual && anteriores.length > 0 && (
        <p className="texto-suave">Contas de meses anteriores ainda em aberto aparecem aqui até serem pagas ou canceladas.</p>
      )}

      {recorrencias.length > 0 && (
        <section className="secao">
          <h2>Contas que se repetem</h2>
          <ul className="lista-simples">
            {recorrencias.map((r) => {
              const encerrada = r.fim !== null && r.fim < `${mesAtual()}-01`;
              return (
                <li key={r.id} className={encerrada ? "linha-arquivada" : ""}>
                  <div>
                    <strong>{r.descricao}</strong>
                    <span className="texto-suave">
                      {formatarCentavos(r.valor_centavos)} todo dia {r.dia_vencimento}
                      {" · "}{r.fim ? `de ${nomeCurtoDoMes(r.inicio)} a ${nomeCurtoDoMes(r.fim)}` : `desde ${nomeCurtoDoMes(r.inicio)}, sem fim`}
                      {encerrada && " · encerrada"}
                    </span>
                  </div>
                  <div className="acoes-linha">
                    <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar-rec", rec: r })}>Editar</button>
                    {r.fim === null || !encerrada
                      ? <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setAcao({ tipo: "encerrar-rec", rec: r })}>{r.fim ? "Mudar fim" : "Encerrar"}</button>
                      : null}
                    {r.fim !== null && !r.numerar_parcelas && (
                      <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "retomar-rec", rec: r })}>Repetir sem fim</button>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {acao?.tipo === "nova" && <DialogoContaAPagar mesSugerido={mes} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "editar" && (
        <DialogoContaAPagar linha={acao.linha} recorrencia={acao.linha.recorrencia_id ? recPorId.get(acao.linha.recorrencia_id) : undefined}
          aoFechar={() => setAcao(null)} aoConcluir={concluir} />
      )}
      {acao?.tipo === "pagar" && <DialogoPagar linha={acao.linha} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "detalhes" && <DialogoPagamentos linha={acao.linha} aoFechar={() => setAcao(null)} aoAlterar={recarregar} />}
      {acao?.tipo === "cancelar" && (
        <Confirmar titulo="Cancelar conta a pagar" perigo pedirMotivo="obrigatorio" rotuloAcao="Cancelar conta"
          texto={<p><strong>{acao.linha.descricao}</strong>, {formatarCentavos(acao.linha.valor_centavos)} com vencimento em {formatarData(acao.linha.vencimento)}. Ela sai da lista de contas em aberto e fica no histórico; nada é apagado. Dá para reabrir depois.</p>}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async (motivo) => { await rpc("obrigacao_cancelar", { p_id: acao.linha.obrigacao_id, p_versao_esperada: acao.linha.versao, p_motivo: motivo, p_chave_idempotencia: null }); concluir(); }} />
      )}
      {acao?.tipo === "reabrir" && (
        <Confirmar titulo="Reabrir conta a pagar" rotuloAcao="Reabrir"
          texto={<p><strong>{acao.linha.descricao}</strong> volta a ficar em aberto.</p>}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async () => { await rpc("obrigacao_reabrir", { p_id: acao.linha.obrigacao_id, p_versao_esperada: acao.linha.versao, p_chave_idempotencia: null }); concluir(); }} />
      )}
      {acao?.tipo === "editar-rec" && <DialogoRecorrencia rec={acao.rec} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "encerrar-rec" && <DialogoEncerrar rec={acao.rec} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "retomar-rec" && (
        <Confirmar titulo="Repetir sem fim" rotuloAcao="Repetir sem fim"
          texto={<p><strong>{acao.rec.descricao}</strong> volta a se repetir todo mês. Os meses que tinham sido cancelados pelo encerramento voltam a ficar em aberto.</p>}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async () => { await rpc("recorrencia_definir_fim", { p_id: acao.rec.id, p_versao_esperada: acao.rec.versao, p_ultimo_mes: null, p_chave_idempotencia: null }); concluir(); }} />
      )}
    </>
  );
}

// ------------------------------------------------------------ campos comuns
function useOpcoesDespesa(atual?: string | null) {
  const { categorias } = useCadastros();
  return useMemo(() => {
    const doTipo = categorias.filter((c) => c.tipo === "despesa" && (c.ativa || c.id === atual));
    const pais = doTipo.filter((c) => !c.pai_id);
    return pais.flatMap((p) => [
      { id: p.id, nome: p.nome },
      ...doTipo.filter((f) => f.pai_id === p.id).map((f) => ({ id: f.id, nome: `${p.nome} › ${f.nome}` })),
    ]);
  }, [categorias, atual]);
}

function CamposCategoriaConta({ categoria, setCategoria, conta, setConta, atualCategoria, atualConta }: {
  categoria: string; setCategoria: (v: string) => void; conta: string; setConta: (v: string) => void;
  atualCategoria?: string | null; atualConta?: string | null;
}) {
  const { contas } = useCadastros();
  const opcoes = useOpcoesDespesa(atualCategoria);
  return (
    <div className="grade-2">
      <Campo rotulo="Categoria">
        {(id) => (
          <select id={id} value={categoria} onChange={(e) => setCategoria(e.target.value)}>
            <option value="">Sem categoria</option>
            {opcoes.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
          </select>
        )}
      </Campo>
      <Campo rotulo="Pagar pela conta (opcional)">
        {(id) => (
          <select id={id} value={conta} onChange={(e) => setConta(e.target.value)}>
            <option value="">Ainda não sei</option>
            {contas.filter((c) => c.ativa || c.id === atualConta).map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
          </select>
        )}
      </Campo>
    </div>
  );
}

// ------------------------------------------------------------ nova / editar
export function DialogoContaAPagar({ linha, recorrencia, mesSugerido, aoFechar, aoConcluir }: {
  linha?: LinhaContaAPagar; recorrencia?: Recorrencia; mesSugerido?: string; aoFechar: () => void; aoConcluir: () => void;
}) {
  const editando = Boolean(linha);
  const vencimentoInicial = linha?.vencimento ?? (mesSugerido && mesSugerido !== mesAtual() ? `${mesSugerido}-10` : hoje());
  const [descricao, setDescricao] = useState(linha?.descricao ?? "");
  const [valor, setValor] = useState(linha ? centavosParaCampo(linha.valor_centavos) : "");
  const [vencimento, setVencimento] = useState(vencimentoInicial);
  const [categoria, setCategoria] = useState(linha?.categoria_id ?? "");
  const [conta, setConta] = useState(linha?.conta_prevista_id ?? "");
  const [observacao, setObservacao] = useState(linha?.observacao ?? "");
  const [repete, setRepete] = useState(false);
  const [ate, setAte] = useState("");
  const [numerar, setNumerar] = useState(false);
  const { chave, enviando, erro, setErro, enviar } = useEnvio(editando ? "apagar-editar" : "apagar-criar");
  const centavos = lerValor(valor);
  const parcelas = repete && ate && dataValida(vencimento) && ate >= mesDe(vencimento)
    ? (Number(ate.slice(0, 4)) - Number(vencimento.slice(0, 4))) * 12 + Number(ate.slice(5, 7)) - Number(vencimento.slice(5, 7)) + 1
    : null;

  return (
    <Dialogo titulo={editando ? "Editar conta a pagar" : "Nova conta a pagar"} aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!descricao.trim()) return setErro("Escreva uma descrição, por exemplo Aluguel.");
        if (centavos === null || centavos <= 0) return setErro("Informe o valor, por exemplo 1.500,00.");
        if (!dataValida(vencimento)) return setErro("Informe o vencimento.");
        if (linha && centavos < linha.abatido_centavos) return setErro(`O valor não pode ficar menor que o já pago (${formatarCentavos(linha.abatido_centavos)}).`);
        if (repete && ate && ate < mesDe(vencimento)) return setErro("O último mês não pode ser antes do primeiro vencimento.");
        if (repete && numerar && !ate) return setErro("Para numerar as parcelas, informe o último mês.");
        void enviar(async () => {
          const comum = { p_descricao: descricao, p_categoria_id: categoria || null, p_conta_prevista_id: conta || null, p_observacao: observacao };
          if (linha) {
            await rpc("obrigacao_atualizar", { p_id: linha.obrigacao_id, p_versao_esperada: linha.versao, ...comum,
              p_valor_centavos: centavos, p_vencimento: vencimento, p_chave_idempotencia: chave });
          } else if (repete) {
            await rpc("recorrencia_criar", { ...comum, p_valor_centavos: centavos, p_dia_vencimento: Number(vencimento.slice(8, 10)),
              p_inicio: `${mesDe(vencimento)}-01`, p_fim: ate ? `${ate}-01` : null, p_numerar_parcelas: numerar, p_chave_idempotencia: chave });
          } else {
            await rpc("obrigacao_criar", { ...comum, p_valor_centavos: centavos, p_vencimento: vencimento, p_chave_idempotencia: chave });
          }
          aoConcluir();
        });
      }}>
        <Campo rotulo="Descrição">
          {(id) => <input id={id} required maxLength={200} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Ex.: Aluguel" />}
        </Campo>
        <div className="grade-2">
          <Campo rotulo="Valor (R$)" ajuda={linha && linha.abatido_centavos > 0 ? `Já pago: ${formatarCentavos(linha.abatido_centavos)}` : "Ex.: 1.500,00"}>
            {(id) => <input id={id} inputMode="decimal" autoComplete="off" required value={valor} onChange={(e) => setValor(e.target.value)} />}
          </Campo>
          <Campo rotulo={repete ? "Primeiro vencimento" : "Vencimento"}>
            {(id) => <input id={id} type="date" required value={vencimento} onChange={(e) => setVencimento(e.target.value)} />}
          </Campo>
        </div>
        <CamposCategoriaConta categoria={categoria} setCategoria={setCategoria} conta={conta} setConta={setConta}
          atualCategoria={linha?.categoria_id} atualConta={linha?.conta_prevista_id} />

        {!editando && (
          <fieldset className="campo opcoes">
            <legend>Repetição</legend>
            <label><input type="radio" name="repete" checked={!repete} onChange={() => setRepete(false)} /> Só uma vez</label>
            <label><input type="radio" name="repete" checked={repete} onChange={() => setRepete(true)} /> Todo mês</label>
          </fieldset>
        )}
        {repete && (
          <div className="bloco-saldo">
            <div className="grade-2">
              <Campo rotulo="Até o mês (opcional)" ajuda={parcelas ? `${parcelas} ${parcelas === 1 ? "mês" : "meses"}` : "Deixe em branco para repetir sem fim"}>
                {(id) => <input id={id} type="month" value={ate} min={dataValida(vencimento) ? mesDe(vencimento) : undefined} onChange={(e) => setAte(e.target.value)} />}
              </Campo>
              <label className="opcao-check">
                <input type="checkbox" checked={numerar} disabled={!ate} onChange={(e) => setNumerar(e.target.checked)} />
                Numerar as parcelas (1/{parcelas ?? "N"}, 2/{parcelas ?? "N"}…)
              </label>
            </div>
            <p className="campo-ajuda">
              Vence todo dia {dataValida(vencimento) ? Number(vencimento.slice(8, 10)) : "…"} (em meses mais curtos, no último dia).
              Cada mês vira uma conta a pagar que pode ser ajustada sozinha, como uma conta de luz com valor diferente.
            </p>
          </div>
        )}
        {recorrencia && (
          <Alerta tipo="aviso">Esta conta é de “{recorrencia.descricao}”, que se repete todo mês. A alteração vale só para este mês; para mudar os próximos, edite a repetição em “Contas que se repetem”.</Alerta>
        )}
        <Campo rotulo="Observação (opcional)">
          {(id) => <textarea id={id} rows={2} maxLength={500} value={observacao} onChange={(e) => setObservacao(e.target.value)} />}
        </Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : editando ? "Salvar alterações" : "Cadastrar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ pagar
function CamposEncargos({ juros, setJuros, multa, setMulta, desconto, setDesconto }: Record<"juros" | "multa" | "desconto", string> & {
  setJuros: (v: string) => void; setMulta: (v: string) => void; setDesconto: (v: string) => void;
}) {
  return (
    <div className="grade-3">
      <Campo rotulo="Juros (R$)">{(id) => <input id={id} inputMode="decimal" value={juros} onChange={(e) => setJuros(e.target.value)} placeholder="0,00" />}</Campo>
      <Campo rotulo="Multa (R$)">{(id) => <input id={id} inputMode="decimal" value={multa} onChange={(e) => setMulta(e.target.value)} placeholder="0,00" />}</Campo>
      <Campo rotulo="Desconto (R$)">{(id) => <input id={id} inputMode="decimal" value={desconto} onChange={(e) => setDesconto(e.target.value)} placeholder="0,00" />}</Campo>
    </div>
  );
}

const lerOpcional = (t: string) => (t.trim() === "" ? 0 : lerValor(t));

export function DialogoPagar({ linha, aoFechar, aoConcluir }: { linha: LinhaContaAPagar; aoFechar: () => void; aoConcluir: () => void }) {
  const { contas } = useCadastros();
  const ativas = contas.filter((c) => c.ativa);
  const [modo, setModo] = useState<"pagar" | "vincular">("pagar");
  const [conta, setConta] = useState(ativas.some((c) => c.id === linha.conta_prevista_id) ? linha.conta_prevista_id! : ativas[0]?.id ?? "");
  const [data, setData] = useState(hoje());
  const [valor, setValor] = useState(centavosParaCampo(linha.restante_centavos));
  const [encargos, setEncargos] = useState(false);
  const [juros, setJuros] = useState("");
  const [multa, setMulta] = useState("");
  const [desconto, setDesconto] = useState("");
  const [movimento, setMovimento] = useState("");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("apagar-pagar");
  const candidatos = useCarregar(
    () => (modo === "vincular" ? rpc<MovimentoVinculavel[]>("movimentos_para_vincular", { p_obrigacao_id: linha.obrigacao_id }) : Promise.resolve([])),
    [modo, linha.obrigacao_id],
  );

  const pago = lerValor(valor);
  const j = encargos ? lerOpcional(juros) : 0;
  const m = encargos ? lerOpcional(multa) : 0;
  const d = encargos ? lerOpcional(desconto) : 0;
  const abate = pago !== null && j !== null && m !== null && d !== null ? pago - j - m + d : null;
  const restaDepois = abate !== null ? linha.restante_centavos - abate : null;
  const escolhido = candidatos.dados?.find((c) => c.movimento_id === movimento);

  function escolher(c: MovimentoVinculavel) {
    setMovimento(c.movimento_id);
    setValor(centavosParaCampo(Math.min(c.livre_centavos, linha.restante_centavos)));
  }

  return (
    <Dialogo titulo="Pagar conta" aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (pago === null || pago <= 0) return setErro("Informe o valor pago, maior que zero.");
        if (j === null || m === null || d === null) return setErro("Confira juros, multa e desconto (ex.: 12,50).");
        if (abate === null || abate <= 0) return setErro("Juros e multa não podem ser maiores que o valor pago.");
        if (abate > linha.restante_centavos) {
          return setErro(`Este pagamento abate ${formatarCentavos(abate)}, mas faltam só ${formatarCentavos(linha.restante_centavos)}. Se pagou a mais, informe a diferença como juros ou multa.`);
        }
        if (modo === "pagar") {
          if (!conta) return setErro("Escolha a conta de onde saiu o dinheiro.");
          if (!dataValida(data) || data > hoje()) return setErro("Informe a data do pagamento (hoje ou antes).");
        } else {
          if (!escolhido) return setErro("Escolha a saída que pagou esta conta.");
          if (pago > escolhido.livre_centavos) return setErro(`Essa saída tem só ${formatarCentavos(escolhido.livre_centavos)} livres.`);
        }
        void enviar(async () => {
          if (modo === "pagar") {
            await rpc("obrigacao_pagar", { p_obrigacao_id: linha.obrigacao_id, p_conta_id: conta, p_data: data, p_valor_pago_centavos: pago,
              p_juros_centavos: j, p_multa_centavos: m, p_desconto_centavos: d, p_observacao: null, p_chave_idempotencia: chave });
          } else {
            await rpc("obrigacao_vincular_movimento", { p_obrigacao_id: linha.obrigacao_id, p_movimento_id: movimento, p_valor_pago_centavos: pago,
              p_juros_centavos: j, p_multa_centavos: m, p_desconto_centavos: d, p_chave_idempotencia: chave });
          }
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto">
          <strong>{linha.descricao}</strong>, vence em {formatarData(linha.vencimento)}.{" "}
          {linha.abatido_centavos > 0 ? <>Já pago {formatarCentavos(linha.abatido_centavos)}; faltam <strong>{formatarCentavos(linha.restante_centavos)}</strong>.</> : <>Valor: <strong>{formatarCentavos(linha.valor_centavos)}</strong>.</>}
        </p>
        <fieldset className="campo opcoes">
          <legend>Como foi pago</legend>
          <label><input type="radio" name="modo" checked={modo === "pagar"} onChange={() => setModo("pagar")} /> Registrar o pagamento agora</label>
          <label><input type="radio" name="modo" checked={modo === "vincular"} onChange={() => { setModo("vincular"); setMovimento(""); }} /> Já lancei essa saída</label>
        </fieldset>

        {modo === "pagar" && (
          <>
            <div className="grade-2">
              <Campo rotulo="Saiu da conta">
                {(id) => (
                  <select id={id} value={conta} onChange={(e) => setConta(e.target.value)} required>
                    {ativas.map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
                  </select>
                )}
              </Campo>
              <Campo rotulo="Data do pagamento">
                {(id) => <input id={id} type="date" required max={hoje()} value={data} onChange={(e) => setData(e.target.value)} />}
              </Campo>
            </div>
            <p className="campo-ajuda">
              {linha.origem === "fatura"
                ? "O Simplifica lança a saída nessa conta como pagamento de fatura. Ela mexe no saldo, mas não é despesa: as despesas são as compras do cartão."
                : <>O Simplifica lança a saída nessa conta{linha.categoria ? `, na categoria ${linha.categoria}` : ""}. Não lance esta despesa de novo.</>}
            </p>
          </>
        )}

        {modo === "vincular" && (
          <div className="campo">
            <span className="rotulo-campo">Saída que pagou esta conta</span>
            {candidatos.carregando && <Carregando texto="Procurando saídas próximas do vencimento…" />}
            {candidatos.erro && <Alerta>{candidatos.erro}</Alerta>}
            {candidatos.dados && candidatos.dados.length === 0 && (
              <p className="campo-ajuda">Nenhuma saída livre até 60 dias antes ou depois do vencimento. Use “Registrar o pagamento agora”.</p>
            )}
            {linha.origem === "fatura" && (
              <p className="campo-ajuda">A saída escolhida passa a contar como pagamento de fatura e sai do resumo de despesas (as despesas são as compras do cartão). Se o vínculo for desfeito, ela volta a ser como era.</p>
            )}
            {candidatos.dados && candidatos.dados.length > 0 && (
              <ul className="lista-escolha">
                {candidatos.dados.map((c) => (
                  <li key={c.movimento_id}>
                    <label>
                      <input type="radio" name="movimento" checked={movimento === c.movimento_id} onChange={() => escolher(c)} />
                      <span className="lista-escolha-texto">
                        <strong>{c.descricao}</strong>
                        <span className="texto-suave">{formatarData(c.data_movimento)} · {c.conta}{c.categoria ? ` · ${c.categoria}` : ""}</span>
                      </span>
                      <span className="num">
                        <Valor centavos={-c.valor_centavos} />
                        {c.livre_centavos !== c.valor_centavos && <span className="texto-suave">livre {formatarCentavos(c.livre_centavos)}</span>}
                      </span>
                    </label>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        <Campo rotulo="Valor pago (R$)" ajuda={restaDepois === null ? "Ex.: 150,00" : restaDepois === 0 ? "Quita a conta." : restaDepois > 0 ? `Pagamento parcial: restam ${formatarCentavos(restaDepois)}.` : "Passa do que falta pagar."}>
          {(id) => <input id={id} inputMode="decimal" required value={valor} onChange={(e) => setValor(e.target.value)} />}
        </Campo>
        <label className="opcao-check">
          <input type="checkbox" checked={encargos} onChange={(e) => setEncargos(e.target.checked)} /> Teve juros, multa ou desconto
        </label>
        {encargos && (
          <>
            <CamposEncargos juros={juros} setJuros={setJuros} multa={multa} setMulta={setMulta} desconto={desconto} setDesconto={setDesconto} />
            <p className="campo-ajuda">
              Abate da conta: valor pago − juros − multa + desconto{abate !== null ? ` = ${formatarCentavos(abate)}` : ""}.
            </p>
          </>
        )}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : modo === "pagar" ? "Registrar pagamento" : "Vincular saída"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ pagamentos (histórico e desfazer)
function DialogoPagamentos({ linha, aoFechar, aoAlterar }: { linha: LinhaContaAPagar; aoFechar: () => void; aoAlterar: () => void }) {
  const { dados, erro, carregando, recarregar } = useCarregar(
    () => rpc<LinhaPagamento[]>("pagamentos_da_obrigacao", { p_obrigacao_id: linha.obrigacao_id }), [linha.obrigacao_id]);
  const [desfazendo, setDesfazendo] = useState<LinhaPagamento | null>(null);
  return (
    <Dialogo titulo={`Pagamentos: ${linha.descricao}`} aoFechar={aoFechar} largo>
      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}
      {dados && (
        <ul className="lista-simples">
          {dados.map((p) => (
            <li key={p.pagamento_id} className={p.situacao === "desfeito" ? "linha-arquivada" : ""}>
              <div>
                <strong>{formatarData(p.data_pagamento)} · {p.conta}</strong>
                <span className="texto-suave">
                  Pago {formatarCentavos(p.valor_pago_centavos)}
                  {p.juros_centavos > 0 && ` · juros ${formatarCentavos(p.juros_centavos)}`}
                  {p.multa_centavos > 0 && ` · multa ${formatarCentavos(p.multa_centavos)}`}
                  {p.desconto_centavos > 0 && ` · desconto ${formatarCentavos(p.desconto_centavos)}`}
                  {" · abateu "}{formatarCentavos(p.abatido_centavos)}
                  {p.origem === "vinculo" && " · saída já lançada"}
                </span>
                {p.situacao === "desfeito" && <span className="selo">Desfeito{p.desfeito_motivo ? `: ${p.desfeito_motivo}` : ""}</span>}
              </div>
              {p.situacao === "ativo" && (
                <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setDesfazendo(p)}>Desfazer</button>
              )}
            </li>
          ))}
        </ul>
      )}
      <div className="acoes"><button type="button" className="botao-secundario" onClick={aoFechar}>Fechar</button></div>
      {desfazendo && (
        <DialogoDesfazer pagamento={desfazendo} aoFechar={() => setDesfazendo(null)}
          aoConcluir={() => { setDesfazendo(null); recarregar(); aoAlterar(); }} />
      )}
    </Dialogo>
  );
}

function DialogoDesfazer({ pagamento, aoFechar, aoConcluir }: { pagamento: LinhaPagamento; aoFechar: () => void; aoConcluir: () => void }) {
  const [motivo, setMotivo] = useState("");
  const [cancelarSaida, setCancelarSaida] = useState(pagamento.origem === "pagamento");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("apagar-desfazer");
  return (
    <Dialogo titulo="Desfazer pagamento" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (motivo.trim().length < 3) return setErro("Escreva o motivo (pelo menos 3 letras).");
        void enviar(async () => {
          await rpc("pagamento_desfazer", { p_id: pagamento.pagamento_id, p_versao_esperada: pagamento.versao, p_motivo: motivo,
            p_cancelar_lancamento: cancelarSaida, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto">Pagamento de {formatarCentavos(pagamento.valor_pago_centavos)} em {formatarData(pagamento.data_pagamento)} ({pagamento.conta}). A conta a pagar volta a ter {formatarCentavos(pagamento.abatido_centavos)} em aberto.</p>
        {pagamento.origem === "pagamento" ? (
          <label className="opcao-check">
            <input type="checkbox" checked={cancelarSaida} onChange={(e) => setCancelarSaida(e.target.checked)} />
            Cancelar também a saída lançada (o dinheiro volta ao saldo da conta)
          </label>
        ) : (
          <p className="campo-ajuda">A saída foi lançada antes e continua no extrato; só o vínculo é desfeito.</p>
        )}
        <Campo rotulo="Motivo">{(id) => <input id={id} value={motivo} maxLength={200} onChange={(e) => setMotivo(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao-perigo" disabled={enviando}>{enviando ? "Aguarde…" : "Desfazer pagamento"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ recorrências
function DialogoRecorrencia({ rec, aoFechar, aoConcluir }: { rec: Recorrencia; aoFechar: () => void; aoConcluir: () => void }) {
  const [descricao, setDescricao] = useState(rec.descricao);
  const [valor, setValor] = useState(centavosParaCampo(rec.valor_centavos));
  const [dia, setDia] = useState(String(rec.dia_vencimento));
  const [categoria, setCategoria] = useState(rec.categoria_id ?? "");
  const [conta, setConta] = useState(rec.conta_prevista_id ?? "");
  const [observacao, setObservacao] = useState(rec.observacao ?? "");
  const [aplicar, setAplicar] = useState(true);
  const { chave, enviando, erro, setErro, enviar } = useEnvio("rec-editar");
  return (
    <Dialogo titulo="Editar conta que se repete" aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const centavos = lerValor(valor);
        const d = Number(dia);
        if (!descricao.trim()) return setErro("Escreva uma descrição.");
        if (centavos === null || centavos <= 0) return setErro("Informe o valor.");
        if (!Number.isInteger(d) || d < 1 || d > 31) return setErro("O dia do vencimento vai de 1 a 31.");
        void enviar(async () => {
          await rpc("recorrencia_atualizar", { p_id: rec.id, p_versao_esperada: rec.versao, p_descricao: descricao, p_valor_centavos: centavos,
            p_dia_vencimento: d, p_categoria_id: categoria || null, p_conta_prevista_id: conta || null, p_observacao: observacao,
            p_aplicar_em_abertas: aplicar, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <Campo rotulo="Descrição">{(id) => <input id={id} required maxLength={200} value={descricao} onChange={(e) => setDescricao(e.target.value)} />}</Campo>
        <div className="grade-2">
          <Campo rotulo="Valor (R$)">{(id) => <input id={id} inputMode="decimal" required value={valor} onChange={(e) => setValor(e.target.value)} />}</Campo>
          <Campo rotulo="Dia do vencimento">{(id) => <input id={id} type="number" min={1} max={31} required value={dia} onChange={(e) => setDia(e.target.value)} />}</Campo>
        </div>
        <CamposCategoriaConta categoria={categoria} setCategoria={setCategoria} conta={conta} setConta={setConta}
          atualCategoria={rec.categoria_id} atualConta={rec.conta_prevista_id} />
        <Campo rotulo="Observação (opcional)">{(id) => <textarea id={id} rows={2} maxLength={500} value={observacao} onChange={(e) => setObservacao(e.target.value)} />}</Campo>
        <label className="opcao-check">
          <input type="checkbox" checked={aplicar} onChange={(e) => setAplicar(e.target.checked)} />
          Aplicar também às contas já criadas, deste mês em diante, que estão em aberto e sem pagamento
        </label>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Salvar alterações"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

function DialogoEncerrar({ rec, aoFechar, aoConcluir }: { rec: Recorrencia; aoFechar: () => void; aoConcluir: () => void }) {
  const [ultimo, setUltimo] = useState(rec.fim ? mesDe(rec.fim) : mesAtual() < mesDe(rec.inicio) ? mesDe(rec.inicio) : mesAtual());
  const { chave, enviando, erro, setErro, enviar } = useEnvio("rec-encerrar");
  return (
    <Dialogo titulo="Encerrar repetição" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!/^\d{4}-\d{2}$/.test(ultimo)) return setErro("Escolha o último mês.");
        if (ultimo < somarMeses(mesDe(rec.inicio), -1)) return setErro("O último mês não pode ser antes do início.");
        void enviar(async () => {
          await rpc("recorrencia_definir_fim", { p_id: rec.id, p_versao_esperada: rec.versao, p_ultimo_mes: `${ultimo}-01`, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto"><strong>{rec.descricao}</strong> deixa de se repetir depois do mês escolhido.</p>
        <Campo rotulo="Último mês" ajuda="Os meses seguintes que já estavam na lista, em aberto e sem pagamento, ficam cancelados (nada é apagado). Os que têm pagamento continuam.">
          {(id) => <input id={id} type="month" required value={ultimo} onChange={(e) => setUltimo(e.target.value)} />}
        </Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao-perigo" disabled={enviando}>{enviando ? "Salvando…" : "Encerrar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
