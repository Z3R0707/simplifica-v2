import { useMemo, useState } from "react";
import { listar, rpc } from "../lib/api";
import { dataValida, formatarData, hoje, nomeDoMes } from "../lib/datas";
import { centavosParaCampo, formatarCentavos, lerValor } from "../lib/dinheiro";
import type {
  Cartao, Compra, FaturaPrevista, LancamentoFatura, LinhaCartao, LinhaContaAPagar, LinhaFatura, ParcelaDaCompra, SituacaoFatura, StatusParcela,
} from "../lib/tipos";
import { Alerta, Campo, Carregando, Confirmar, Dialogo, TituloPagina, Valor, useCadastros, useCarregar, useEnvio } from "../ui";
import { DialogoPagar } from "./contas-a-pagar";

// ------------------------------------------------------------ utilidades
const mesDe = (iso: string) => iso.slice(0, 7);
function somarMeses(mes: string, n: number): string {
  const [a, m] = mes.split("-").map(Number);
  const d = new Date(Date.UTC(a, m - 1 + n, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
const mesCurto = (iso: string) => {
  const [a, m] = iso.split("-").map(Number);
  return new Intl.DateTimeFormat("pt-BR", { month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(Date.UTC(a, m - 1, 1))).replace(".", "");
};
const diaMes = (iso: string) => formatarData(iso).slice(0, 5);

const SITUACAO_FATURA: Record<SituacaoFatura, { nome: string; classe: string }> = {
  aberta: { nome: "Aberta", classe: "selo-neutro" },
  fechada: { nome: "Fechada", classe: "selo-previsto" },
  vencida: { nome: "Vencida", classe: "selo-perigo" },
  paga: { nome: "Paga", classe: "selo-ok" },
  sem_saldo: { nome: "Sem valor a pagar", classe: "selo-neutro" },
};
const STATUS_PARCELA: Record<StatusParcela, string> = {
  a_cobrar: "A cobrar", cobrada: "Cobrada", quitada: "Quitada", cancelada: "Cancelada",
};
const SUBTIPOS: Record<string, string> = {
  juros: "Juros", iof: "IOF", tarifa: "Tarifa", anuidade: "Anuidade", multa: "Multa", outro: "Outro encargo",
};

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

// ============================================================ lista de cartões
export function TelaCartoes() {
  const [acao, setAcao] = useState<"novo" | "compra" | null>(null);
  const [mostrarArquivados, setMostrarArquivados] = useState(false);
  const { dados, erro, carregando, recarregar } = useCarregar(() => rpc<LinhaCartao[]>("cartoes_resumo"), []);
  const linhas = dados ?? [];
  const ativos = linhas.filter((l) => l.ativo);
  const arquivados = linhas.filter((l) => !l.ativo);
  return (
    <>
      <TituloPagina titulo="Cartões">
        {ativos.length > 0 && <button type="button" className="botao-secundario" onClick={() => setAcao("novo")}>Novo cartão</button>}
        {ativos.length > 0 && <button type="button" className="botao" onClick={() => setAcao("compra")}>Nova compra</button>}
      </TituloPagina>
      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}
      {dados && ativos.length === 0 && (
        <section className="vazio">
          <h2>Cadastre seu primeiro cartão</h2>
          <p>Informe o dia em que a fatura fecha e o dia em que vence. As compras caem sozinhas na fatura certa, e cada fatura vira uma conta a pagar.</p>
          <button type="button" className="botao" onClick={() => setAcao("novo")}>Cadastrar cartão</button>
        </section>
      )}
      {ativos.length > 0 && <ul className="lista-contas">{ativos.map((l) => <CartaoResumo key={l.cartao_id} l={l} />)}</ul>}
      {arquivados.length > 0 && (
        <div className="arquivadas">
          <button type="button" className="botao-texto" onClick={() => setMostrarArquivados((v) => !v)} aria-expanded={mostrarArquivados}>
            {mostrarArquivados ? "Ocultar cartões arquivados" : `Mostrar cartões arquivados (${arquivados.length})`}
          </button>
          {mostrarArquivados && <ul className="lista-contas">{arquivados.map((l) => <CartaoResumo key={l.cartao_id} l={l} />)}</ul>}
        </div>
      )}
      {acao === "novo" && <DialogoCartao aoFechar={() => setAcao(null)} aoConcluir={() => { setAcao(null); recarregar(); }} />}
      {acao === "compra" && <DialogoCompra cartoes={ativos} aoFechar={() => setAcao(null)} aoConcluir={() => { setAcao(null); recarregar(); }} />}
    </>
  );
}

function CartaoResumo({ l }: { l: LinhaCartao }) {
  const usoPct = l.limite_centavos ? Math.min(100, Math.max(0, (l.usado_centavos / l.limite_centavos) * 100)) : 0;
  return (
    <li>
      <a className={`cartao-conta cartao-credito${l.ativo ? "" : " cartao-arquivado"}`} href={`#/cartao/${l.cartao_id}`}>
        <div className="cartao-conta-nome">
          <strong>{l.apelido}{l.final ? ` ···· ${l.final}` : ""}</strong>
          {l.instituicao !== l.apelido && <span>{l.instituicao}</span>}
          <span className="texto-suave">Titular: {l.titular} · fecha dia {l.dia_fechamento}, vence dia {l.dia_vencimento}</span>
          {l.limite_centavos !== null && (
            <span className="limite">
              <span className="barra-trilho" aria-hidden="true"><span className="barra barra-saida" style={{ width: `${usoPct}%` }} /></span>
              <span className="texto-suave">Disponível <Valor centavos={l.disponivel_centavos ?? 0} /> de <Valor centavos={l.limite_centavos} /></span>
            </span>
          )}
        </div>
        <div className="cartao-conta-saldo">
          <span className="texto-suave">Fatura de {mesCurto(l.fatura_atual_competencia)}</span>
          <Valor centavos={l.fatura_atual_total} classe="valor-grande" />
          <span className="texto-suave">fecha {diaMes(l.fatura_atual_fechamento)} · vence {diaMes(l.fatura_atual_vencimento)}</span>
          {l.a_pagar_vencidas_centavos > 0 && <span className="selo selo-perigo">Vencida: {formatarCentavos(l.a_pagar_vencidas_centavos)}</span>}
        </div>
      </a>
    </li>
  );
}

// ============================================================ um cartão e suas faturas
type AcaoCartao =
  | { tipo: "compra" | "editar-cartao" | "arquivar" | "fatura" | "pagar" }
  | { tipo: "estornar" | "parcelas" | "cancelar" | "editar"; l: LancamentoFatura }
  | null;

export function TelaCartao({ cartaoId, mesInicial }: { cartaoId: string; mesInicial?: string }) {
  const [mes, setMes] = useState<string | null>(mesInicial ?? null);
  const [acao, setAcao] = useState<AcaoCartao>(null);
  const [mostrarCancelados, setMostrarCancelados] = useState(false);
  const cartaoQ = useCarregar(async () => {
    const [resumo, cadastro] = await Promise.all([rpc<LinhaCartao[]>("cartoes_resumo"), listar<Cartao>("cartoes", { id: `eq.${cartaoId}` })]);
    return { resumo: resumo.find((r) => r.cartao_id === cartaoId) ?? null, cadastro: cadastro.find((c) => c.id === cartaoId) ?? null, todos: resumo };
  }, [cartaoId]);
  const resumo = cartaoQ.dados?.resumo ?? null;
  const mesVisto = mes ?? (resumo ? mesDe(resumo.fatura_atual_competencia) : null);

  const faturaQ = useCarregar(async () => {
    if (!mesVisto) return null;
    const [fat] = await rpc<LinhaFatura[]>("faturas_do_cartao", { p_cartao_id: cartaoId, p_de: `${mesVisto}-01`, p_ate: `${mesVisto}-01` });
    const lancs = fat ? await rpc<LancamentoFatura[]>("lancamentos_da_fatura", { p_fatura_id: fat.fatura_id }) : [];
    return { fatura: fat ?? null, lancs };
  }, [cartaoId, mesVisto]);

  const recarregar = () => { cartaoQ.recarregar(); faturaQ.recarregar(); };
  const concluir = () => { setAcao(null); recarregar(); };
  if (cartaoQ.dados && !resumo) return <Alerta>Cartão não encontrado. <a href="#/cartoes">Voltar para cartões</a></Alerta>;

  const fatura = faturaQ.dados?.fatura ?? null;
  const lancs = faturaQ.dados?.lancs ?? [];
  const visiveis = lancs.filter((l) => mostrarCancelados || l.status !== "cancelada");
  const qtdCancelados = lancs.filter((l) => l.status === "cancelada").length;
  const ehAtual = resumo && mesVisto === mesDe(resumo.fatura_atual_competencia);

  function exportarCsv() {
    if (!fatura) return;
    const valor = (c: number) => (c < 0 ? "-" : "") + centavosParaCampo(Math.abs(c));
    const linhas = [["DATA", "DESCRIÇÃO", "PARCELA", "VALOR"], ...lancs.filter((l) => l.status !== "cancelada")
      .map((l) => [formatarData(l.data), l.descricao, l.parcela ?? "", valor(l.valor_centavos)])];
    const csv = linhas.map((cols) => cols.map((c) => (/[;"\n]/.test(c) ? `"${c.replace(/"/g, '""')}"` : c)).join(";")).join("\r\n");
    const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `fatura-${(resumo?.apelido ?? "cartao").toLowerCase().replace(/[^a-z0-9]+/g, "-")}-${mesVisto}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  return (
    <>
      <p className="trilha"><a href="#/cartoes">Cartões</a></p>
      <TituloPagina titulo={resumo ? `${resumo.apelido}${resumo.final ? ` ···· ${resumo.final}` : ""}` : "Cartão"}>
        {mesVisto && (
          <div className="seletor-mes">
            <button type="button" className="botao-secundario botao-icone" aria-label="Fatura anterior" onClick={() => setMes(somarMeses(mesVisto, -1))}>‹</button>
            <label className="seletor-data"><span>Fatura de</span>
              <input type="month" value={mesVisto} onChange={(e) => e.target.value && setMes(e.target.value)} />
            </label>
            <button type="button" className="botao-secundario botao-icone" aria-label="Próxima fatura" onClick={() => setMes(somarMeses(mesVisto, 1))}>›</button>
          </div>
        )}
        {resumo?.ativo && <a className="botao-secundario" href={`#/importar-fatura/${cartaoId}`}>Importar fatura</a>}
        {resumo?.ativo && <button type="button" className="botao" onClick={() => setAcao({ tipo: "compra" })}>Nova compra</button>}
      </TituloPagina>
      {(cartaoQ.erro || faturaQ.erro) && <Alerta>{cartaoQ.erro ?? faturaQ.erro}</Alerta>}
      {(cartaoQ.carregando && !cartaoQ.dados) && <Carregando />}

      {resumo && mesVisto && (
        <section className="totais fatura-topo" aria-label="Fatura">
          <div>
            <p className="texto-suave">
              Fatura de {nomeDoMes(mesVisto).toLowerCase()}{ehAtual ? " (atual)" : ""}{" "}
              {fatura && <span className={`selo ${SITUACAO_FATURA[fatura.situacao].classe}`}>{SITUACAO_FATURA[fatura.situacao].nome}</span>}
            </p>
            <p className="valor-destaque"><Valor centavos={fatura?.total_centavos ?? 0} /></p>
            {fatura && <p className="texto-suave">Fecha {formatarData(fatura.fechamento)} · vence {formatarData(fatura.vencimento)}</p>}
          </div>
          {fatura && fatura.pago_centavos > 0 && <div><p className="texto-suave">Pago</p><p className="valor-destaque"><Valor centavos={fatura.pago_centavos} /></p></div>}
          {fatura && fatura.total_centavos > 0 && <div><p className="texto-suave">Falta pagar</p><p className="valor-destaque"><Valor centavos={fatura.restante_centavos} /></p></div>}
          {fatura && fatura.creditos_centavos > 0 && <div><p className="texto-suave">Créditos e estornos</p><p className="valor-destaque"><Valor centavos={-fatura.creditos_centavos} /></p></div>}
          {resumo.limite_centavos !== null && <div><p className="texto-suave">Limite disponível</p><p className="valor-destaque"><Valor centavos={resumo.disponivel_centavos ?? 0} /></p></div>}
        </section>
      )}

      {fatura && (
        <div className="acoes acoes-esquerda fatura-acoes">
          {fatura.restante_centavos > 0 && fatura.obrigacao_id && <button type="button" className="botao" onClick={() => setAcao({ tipo: "pagar" })}>Pagar fatura</button>}
          <button type="button" className="botao-secundario" onClick={() => setAcao({ tipo: "fatura" })}>Datas e total do banco</button>
          {lancs.length > 0 && <button type="button" className="botao-secundario" onClick={exportarCsv}>Exportar (CSV)</button>}
        </div>
      )}
      {fatura && fatura.total_informado_centavos !== null && (
        fatura.diferenca_centavos === 0
          ? <Alerta tipo="ok">Confere com o total informado pelo banco ({formatarCentavos(fatura.total_informado_centavos)}).</Alerta>
          : (
            <Alerta tipo="aviso">
              Total informado pelo banco: {formatarCentavos(fatura.total_informado_centavos)} · calculado aqui: {formatarCentavos(fatura.total_centavos)} ·
              diferença: <strong>{formatarCentavos(fatura.diferenca_centavos ?? 0, { sinal: true })}</strong>.
              A diferença não é ajustada sozinha: confira os lançamentos e lance a compra, o encargo ou o crédito que estiver faltando.
            </Alerta>
          )
      )}

      {faturaQ.carregando && !faturaQ.dados && <Carregando />}
      {faturaQ.dados && visiveis.length === 0 && (
        <section className="vazio"><h2>Nenhum lançamento nesta fatura</h2></section>
      )}
      {visiveis.length > 0 && (
        <div className="tabela-rolagem">
          <table className="tabela extrato fatura">
            <thead><tr><th>Data</th><th>Descrição</th><th>Parcela</th><th className="num">Valor</th><th><span className="sr">Ações</span></th></tr></thead>
            <tbody>
              {visiveis.map((l) => (
                <tr key={l.parcela_id} className={l.status === "cancelada" ? "linha-cancelado" : ""}>
                  <td className="data">{formatarData(l.data)}</td>
                  <td>
                    <span className="descricao">{l.descricao}</span>
                    <span className="texto-suave">
                      {l.tipo === "encargo" ? SUBTIPOS[l.subtipo ?? "outro"] : l.tipo === "credito" ? "Crédito" : l.tipo === "estorno" ? "Estorno" : "Compra"}
                      {" · "}{l.categoria ?? "Sem categoria"}
                    </span>
                    {l.antecipada && (
                      <span className="selo selo-previsto">Antecipada (era da fatura de {l.fatura_original_competencia ? mesCurto(l.fatura_original_competencia) : "?"}){l.desconto_centavos > 0 ? `, desconto ${formatarCentavos(l.desconto_centavos)}` : ""}</span>
                    )}
                    <span className={`selo ${l.status === "quitada" ? "selo-ok" : l.status === "cobrada" ? "selo-previsto" : ""}`}>{STATUS_PARCELA[l.status]}</span>
                  </td>
                  <td className="parcela">{l.parcela ?? ""}</td>
                  <td className="num"><Valor centavos={l.valor_centavos} classe={l.valor_centavos < 0 ? "valor-entrada" : ""} /></td>
                  <td className="acoes-linha">
                    {l.status !== "cancelada" && (
                      <>
                        {l.parcelas_total > 1 && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "parcelas", l })}>Parcelas</button>}
                        {(l.tipo === "compra" || l.tipo === "encargo") && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "estornar", l })}>Estornar</button>}
                        <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar", l })}>Editar</button>
                        <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setAcao({ tipo: "cancelar", l })}>Cancelar</button>
                      </>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {qtdCancelados > 0 && (
        <button type="button" className="botao-texto" onClick={() => setMostrarCancelados((v) => !v)}>
          {mostrarCancelados ? "Ocultar cancelados" : `Mostrar cancelados (${qtdCancelados})`}
        </button>
      )}

      {resumo && (
        <section className="secao">
          <div className="titulo-secao">
            <h2>Sobre o cartão</h2>
            <span className="acoes-linha">
              <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar-cartao" })}>Editar</button>
              <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "arquivar" })}>{resumo.ativo ? "Arquivar" : "Reativar"}</button>
            </span>
          </div>
          <p className="texto-suave">
            {resumo.instituicao} · titular {resumo.titular} · fecha dia {resumo.dia_fechamento}, vence dia {resumo.dia_vencimento}.
            Compras feitas no dia do fechamento ou depois entram na fatura seguinte.
            {resumo.limite_centavos !== null && <> Limite {formatarCentavos(resumo.limite_centavos)}; em uso {formatarCentavos(resumo.usado_centavos)} (inclui parcelas futuras).</>}
          </p>
        </section>
      )}

      {acao?.tipo === "compra" && resumo && <DialogoCompra cartoes={(cartaoQ.dados?.todos ?? []).filter((c) => c.ativo)} cartaoId={cartaoId} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "editar-cartao" && cartaoQ.dados?.cadastro && <DialogoCartao cartao={cartaoQ.dados.cadastro} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "arquivar" && resumo && (
        <Confirmar titulo={resumo.ativo ? "Arquivar cartão" : "Reativar cartão"} rotuloAcao={resumo.ativo ? "Arquivar" : "Reativar"} pedirMotivo="opcional"
          texto={resumo.ativo
            ? <p>{resumo.apelido} deixa de aceitar compras novas. As faturas e o histórico continuam, inclusive as contas a pagar das faturas em aberto.</p>
            : <p>{resumo.apelido} volta a aceitar compras.</p>}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async (motivo) => { await rpc("cartao_definir_ativo", { p_id: cartaoId, p_versao_esperada: resumo.versao, p_ativo: !resumo.ativo, p_motivo: motivo || null, p_chave_idempotencia: null }); concluir(); }} />
      )}
      {acao?.tipo === "fatura" && fatura && <DialogoFatura fatura={fatura} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "pagar" && fatura && <PagarFatura fatura={fatura} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "estornar" && resumo && <DialogoEstorno l={acao.l} cartao={resumo} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "parcelas" && resumo && <DialogoParcelas l={acao.l} cartao={resumo} aoFechar={() => setAcao(null)} aoAlterar={recarregar} />}
      {acao?.tipo === "cancelar" && <DialogoCancelarCompra l={acao.l} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
      {acao?.tipo === "editar" && <DialogoEditarCompra l={acao.l} aoFechar={() => setAcao(null)} aoConcluir={concluir} />}
    </>
  );
}

// ------------------------------------------------------------ pagar fatura (mesmo diálogo de Contas a pagar)
function PagarFatura({ fatura, aoFechar, aoConcluir }: { fatura: LinhaFatura; aoFechar: () => void; aoConcluir: () => void }) {
  const { dados, erro } = useCarregar(
    () => rpc<LinhaContaAPagar[]>("contas_a_pagar", { p_inicio: fatura.vencimento, p_fim: fatura.vencimento, p_incluir_vencidas: false }),
    [fatura.fatura_id],
  );
  const linha = dados?.find((l) => l.obrigacao_id === fatura.obrigacao_id);
  if (erro) return <Dialogo titulo="Pagar fatura" aoFechar={aoFechar}><Alerta>{erro}</Alerta></Dialogo>;
  if (!linha) return <Dialogo titulo="Pagar fatura" aoFechar={aoFechar}><Carregando /></Dialogo>;
  return <DialogoPagar linha={linha} aoFechar={aoFechar} aoConcluir={aoConcluir} />;
}

// ------------------------------------------------------------ cadastro do cartão
export function DialogoCartao({ cartao, aoFechar, aoConcluir }: { cartao?: Cartao; aoFechar: () => void; aoConcluir: () => void }) {
  const { instituicoes, titulares, contas } = useCadastros();
  const [apelido, setApelido] = useState(cartao?.apelido ?? "");
  const [instituicao, setInstituicao] = useState(cartao?.instituicao_id ?? "");
  const [titular, setTitular] = useState(cartao?.titular_id ?? titulares.find((t) => t.principal)?.id ?? "");
  const [final, setFinal] = useState(cartao?.final ?? "");
  const [limite, setLimite] = useState(cartao?.limite_centavos != null ? centavosParaCampo(cartao.limite_centavos) : "");
  const [fechamento, setFechamento] = useState(cartao ? String(cartao.dia_fechamento) : "");
  const [vencimento, setVencimento] = useState(cartao ? String(cartao.dia_vencimento) : "");
  const [conta, setConta] = useState(cartao?.conta_pagamento_id ?? "");
  const { chave, enviando, erro, setErro, enviar } = useEnvio(cartao ? "cartao-editar" : "cartao-criar");
  return (
    <Dialogo titulo={cartao ? "Editar cartão" : "Novo cartão"} aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const f = Number(fechamento), v = Number(vencimento);
        const lim = limite.trim() ? lerValor(limite) : null;
        if (!apelido.trim()) return setErro("Dê um nome ao cartão, por exemplo Nubank.");
        if (!instituicao) return setErro("Escolha o banco do cartão.");
        if (!titular) return setErro("Escolha o titular.");
        if (final && !/^\d{4}$/.test(final)) return setErro("Final do cartão: os 4 últimos números (ou deixe em branco).");
        if (limite.trim() && (lim === null || lim < 0)) return setErro("Limite inválido (ex.: 5.000,00), ou deixe em branco.");
        if (!Number.isInteger(f) || f < 1 || f > 31 || !Number.isInteger(v) || v < 1 || v > 31) return setErro("Dias de fechamento e vencimento vão de 1 a 31.");
        if (f === v) return setErro("O fechamento e o vencimento precisam ser em dias diferentes.");
        void enviar(async () => {
          const comum = { p_titular_id: titular, p_instituicao_id: instituicao, p_apelido: apelido, p_final: final || null, p_limite_centavos: lim,
            p_dia_fechamento: f, p_dia_vencimento: v, p_conta_pagamento_id: conta || null, p_chave_idempotencia: chave };
          if (cartao) await rpc("cartao_atualizar", { p_id: cartao.id, p_versao_esperada: cartao.versao, ...comum });
          else await rpc("cartao_criar", comum);
          aoConcluir();
        });
      }}>
        <div className="grade-2">
          <Campo rotulo="Nome do cartão">{(id) => <input id={id} required maxLength={80} value={apelido} onChange={(e) => setApelido(e.target.value)} placeholder="Ex.: Nubank" />}</Campo>
          <Campo rotulo="Banco do cartão">
            {(id) => (
              <select id={id} value={instituicao} onChange={(e) => setInstituicao(e.target.value)} required>
                <option value="">Escolha…</option>
                {instituicoes.map((i) => <option key={i.id} value={i.id}>{i.nome}</option>)}
              </select>
            )}
          </Campo>
        </div>
        <div className="grade-2">
          <Campo rotulo="Titular">
            {(id) => (
              <select id={id} value={titular} onChange={(e) => setTitular(e.target.value)} required>
                {titulares.filter((t) => t.ativo || t.id === cartao?.titular_id).map((t) => <option key={t.id} value={t.id}>{t.nome}</option>)}
              </select>
            )}
          </Campo>
          <Campo rotulo="Final do cartão (opcional)" ajuda="Só os 4 últimos números">
            {(id) => <input id={id} inputMode="numeric" maxLength={4} value={final} onChange={(e) => setFinal(e.target.value.replace(/\D/g, ""))} />}
          </Campo>
        </div>
        <div className="grade-3">
          <Campo rotulo="Dia do fechamento">{(id) => <input id={id} type="number" min={1} max={31} required value={fechamento} onChange={(e) => setFechamento(e.target.value)} />}</Campo>
          <Campo rotulo="Dia do vencimento">{(id) => <input id={id} type="number" min={1} max={31} required value={vencimento} onChange={(e) => setVencimento(e.target.value)} />}</Campo>
          <Campo rotulo="Limite (opcional)">{(id) => <input id={id} inputMode="decimal" value={limite} onChange={(e) => setLimite(e.target.value)} placeholder="Ex.: 5.000,00" />}</Campo>
        </div>
        <p className="campo-ajuda">Compras feitas no dia do fechamento ou depois entram na fatura seguinte. Se o banco lançar diferente, dá para escolher a fatura na compra.</p>
        <Campo rotulo="Conta que paga a fatura (opcional)" ajuda="Usada para prever a saída no painel de saldos">
          {(id) => (
            <select id={id} value={conta} onChange={(e) => setConta(e.target.value)}>
              <option value="">Ainda não sei</option>
              {contas.filter((c) => c.ativa || c.id === cartao?.conta_pagamento_id).map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
            </select>
          )}
        </Campo>
        {cartao && <p className="campo-ajuda">Mudar os dias vale para as faturas novas. Uma fatura já existente tem as datas ajustadas nela mesma.</p>}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : cartao ? "Salvar alterações" : "Cadastrar cartão"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ nova compra / encargo / crédito
export function DialogoCompra({ cartoes, cartaoId, aoFechar, aoConcluir }: {
  cartoes: LinhaCartao[]; cartaoId?: string; aoFechar: () => void; aoConcluir: () => void;
}) {
  const [cartao, setCartao] = useState(cartaoId ?? cartoes[0]?.cartao_id ?? "");
  const [tipo, setTipo] = useState<"compra" | "encargo" | "credito">("compra");
  const [subtipo, setSubtipo] = useState("juros");
  const [data, setData] = useState(hoje());
  const [descricao, setDescricao] = useState("");
  const [categoria, setCategoria] = useState("");
  const [parcelado, setParcelado] = useState(false);
  const [parcelas, setParcelas] = useState("2");
  const [modoValor, setModoValor] = useState<"total" | "parcela">("total");
  const [valor, setValor] = useState("");
  const [emAndamento, setEmAndamento] = useState(false);
  const [parcelaAtual, setParcelaAtual] = useState("2");
  const [faturaEscolhida, setFaturaEscolhida] = useState("");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("compra-criar");
  const opcoes = useOpcoesDespesa();
  const n = tipo === "compra" && parcelado ? Number(parcelas) : 1;
  const atual = tipo === "compra" && parcelado && emAndamento ? Number(parcelaAtual) : 1;
  const centavos = lerValor(valor);
  const dataPrevia = atual > 1 ? hoje() : data;
  const previa = useCarregar(
    () => (cartao && dataValida(dataPrevia) ? rpc<FaturaPrevista[]>("fatura_prevista", { p_cartao_id: cartao, p_data: dataPrevia }) : Promise.resolve([])),
    [cartao, dataPrevia],
  );
  const prevista = previa.dados?.[0];
  const opcoesFatura = prevista ? [-1, 0, 1, 2].map((k) => somarMeses(mesDe(prevista.competencia), k)).filter((m) => dataValida(data) && m >= mesDe(data)) : [];
  const competencia = faturaEscolhida || (prevista ? mesDe(prevista.competencia) : "");

  let resumoValor = "";
  if (centavos && centavos > 0 && Number.isInteger(n) && n >= 1) {
    if (n === 1) resumoValor = formatarCentavos(centavos);
    else if (modoValor === "parcela") resumoValor = `${n}x de ${formatarCentavos(centavos)} = ${formatarCentavos(centavos * n)}`;
    else {
      const base = Math.floor(centavos / n), resto = centavos - base * n;
      resumoValor = `${n}x de ${formatarCentavos(base)}${resto ? ` (1ª de ${formatarCentavos(base + resto)})` : ""}`;
    }
  }

  return (
    <Dialogo titulo={tipo === "compra" ? "Nova compra no cartão" : tipo === "encargo" ? "Novo encargo no cartão" : "Novo crédito no cartão"} aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!cartao) return setErro("Escolha o cartão.");
        if (!dataValida(data) || data > hoje()) return setErro("Informe a data (hoje ou antes).");
        if (!descricao.trim()) return setErro("Escreva uma descrição.");
        if (centavos === null || centavos <= 0) return setErro("Informe o valor, maior que zero.");
        if (!Number.isInteger(n) || n < 1 || n > 99) return setErro("Número de parcelas: de 2 a 99.");
        if (!Number.isInteger(atual) || atual < 1 || atual > n) return setErro(`A parcela atual vai de 1 a ${n}.`);
        if (modoValor === "total" && centavos < n) return setErro("Valor menor que o número de parcelas.");
        void enviar(async () => {
          await rpc("compra_criar", {
            p_cartao_id: cartao, p_tipo: tipo, p_subtipo: tipo === "encargo" ? subtipo : null, p_data: data, p_descricao: descricao,
            p_categoria_id: categoria || null,
            p_valor_centavos: n > 1 && modoValor === "parcela" ? null : centavos,
            p_parcelas: n, p_valor_parcela_centavos: n > 1 && modoValor === "parcela" ? centavos : null,
            p_parcela_atual: atual, p_fatura_competencia: faturaEscolhida ? `${faturaEscolhida}-01` : null,
            p_observacao: null, p_chave_idempotencia: chave,
          });
          aoConcluir();
        });
      }}>
        <div className="grade-2">
          <Campo rotulo="Cartão">
            {(id) => (
              <select id={id} value={cartao} onChange={(e) => { setCartao(e.target.value); setFaturaEscolhida(""); }} required>
                {cartoes.map((c) => <option key={c.cartao_id} value={c.cartao_id}>{c.apelido}</option>)}
              </select>
            )}
          </Campo>
          <Campo rotulo={atual > 1 ? "Data da compra (original)" : "Data"}>
            {(id) => <input id={id} type="date" required max={hoje()} value={data} onChange={(e) => { setData(e.target.value); setFaturaEscolhida(""); }} />}
          </Campo>
        </div>
        <fieldset className="campo opcoes">
          <legend>Tipo</legend>
          <label><input type="radio" name="tipo" checked={tipo === "compra"} onChange={() => setTipo("compra")} /> Compra</label>
          <label><input type="radio" name="tipo" checked={tipo === "encargo"} onChange={() => { setTipo("encargo"); setParcelado(false); }} /> Juros, IOF, tarifa ou anuidade</label>
          <label><input type="radio" name="tipo" checked={tipo === "credito"} onChange={() => { setTipo("credito"); setParcelado(false); }} /> Crédito</label>
          <p className="campo-ajuda">
            {tipo === "compra" && "Soma na fatura. Para devolver uma compra, use “Estornar” na própria compra."}
            {tipo === "encargo" && "Cobrança do banco na fatura: soma na fatura."}
            {tipo === "credito" && "Abatimento na fatura (cashback, ajuste a favor). Para a devolução de uma compra, use “Estornar” na compra."}
          </p>
        </fieldset>
        {tipo === "encargo" && (
          <Campo rotulo="Qual encargo">
            {(id) => (
              <select id={id} value={subtipo} onChange={(e) => setSubtipo(e.target.value)}>
                {Object.entries(SUBTIPOS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            )}
          </Campo>
        )}
        <Campo rotulo="Descrição">{(id) => <input id={id} required maxLength={200} value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder={tipo === "compra" ? "Ex.: Mercado" : tipo === "encargo" ? "Ex.: IOF compra internacional" : "Ex.: Cashback"} />}</Campo>
        <Campo rotulo="Categoria">
          {(id) => (
            <select id={id} value={categoria} onChange={(e) => setCategoria(e.target.value)}>
              <option value="">Sem categoria</option>
              {opcoes.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select>
          )}
        </Campo>
        {tipo === "compra" && (
          <fieldset className="campo opcoes">
            <legend>Pagamento</legend>
            <label><input type="radio" name="parcelado" checked={!parcelado} onChange={() => setParcelado(false)} /> À vista</label>
            <label><input type="radio" name="parcelado" checked={parcelado} onChange={() => setParcelado(true)} /> Parcelado</label>
          </fieldset>
        )}
        {tipo === "compra" && parcelado && (
          <div className="bloco-saldo">
            <div className="grade-2">
              <Campo rotulo="Número de parcelas">{(id) => <input id={id} type="number" min={2} max={99} required value={parcelas} onChange={(e) => setParcelas(e.target.value)} />}</Campo>
              <fieldset className="campo opcoes">
                <legend>O valor informado é</legend>
                <label><input type="radio" name="modo" checked={modoValor === "total"} onChange={() => setModoValor("total")} /> Total da compra</label>
                <label><input type="radio" name="modo" checked={modoValor === "parcela"} onChange={() => setModoValor("parcela")} /> Valor de cada parcela</label>
              </fieldset>
            </div>
            <label className="opcao-check">
              <input type="checkbox" checked={emAndamento} onChange={(e) => setEmAndamento(e.target.checked)} />
              Compra antiga, já em andamento (só registro daqui para frente)
            </label>
            {emAndamento && (
              <Campo rotulo="Parcela que cai na fatura atual" ajuda={`As parcelas anteriores não são lançadas; as de ${Number(parcelaAtual) || "…"} a ${n || "…"} sim.`}>
                {(id) => <input id={id} type="number" min={1} max={99} value={parcelaAtual} onChange={(e) => setParcelaAtual(e.target.value)} />}
              </Campo>
            )}
          </div>
        )}
        <Campo rotulo={tipo === "compra" && parcelado ? (modoValor === "total" ? "Valor total (R$)" : "Valor da parcela (R$)") : "Valor (R$)"} ajuda={resumoValor || "Ex.: 125,90"}>
          {(id) => <input id={id} inputMode="decimal" autoComplete="off" required value={valor} onChange={(e) => setValor(e.target.value)} />}
        </Campo>
        {prevista && (
          <div className="campo">
            <label htmlFor="fatura-escolhida">{atual > 1 ? `Fatura da parcela ${atual}` : n > 1 ? "Fatura da 1ª parcela" : "Fatura"}</label>
            <select id="fatura-escolhida" value={competencia} onChange={(e) => setFaturaEscolhida(e.target.value)}>
              {opcoesFatura.map((m) => <option key={m} value={m}>Vence em {mesCurto(`${m}-01`)}{m === mesDe(prevista.competencia) ? " (pela data)" : ""}</option>)}
            </select>
            <p className="campo-ajuda">
              {competencia === mesDe(prevista.competencia)
                ? `Pela data, entra na fatura que fecha em ${formatarData(prevista.fechamento)} e vence em ${formatarData(prevista.vencimento)}.`
                : "Fatura escolhida à mão (use quando o banco tiver lançado em outra fatura)."}
            </p>
          </div>
        )}
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Lançar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ estorno
function DialogoEstorno({ l, cartao, aoFechar, aoConcluir }: { l: LancamentoFatura; cartao: LinhaCartao; aoFechar: () => void; aoConcluir: () => void }) {
  const [valor, setValor] = useState("");
  const [data, setData] = useState(hoje());
  const [motivo, setMotivo] = useState("");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("compra-estornar");
  const previa = useCarregar(() => (dataValida(data) ? rpc<FaturaPrevista[]>("fatura_prevista", { p_cartao_id: cartao.cartao_id, p_data: data }) : Promise.resolve([])), [data]);
  const p = previa.dados?.[0];
  return (
    <Dialogo titulo="Estornar compra" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const c = lerValor(valor);
        if (c === null || c <= 0) return setErro("Informe o valor estornado.");
        if (!dataValida(data) || data > hoje()) return setErro("Informe a data do estorno (hoje ou antes).");
        void enviar(async () => {
          await rpc("compra_estornar", { p_compra_id: l.compra_id, p_valor_centavos: c, p_data: data, p_fatura_competencia: null, p_motivo: motivo, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto"><strong>{l.descricao}</strong> ({formatarData(l.data)}). O estorno entra como crédito na fatura, na mesma categoria, ligado a esta compra.</p>
        <div className="grade-2">
          <Campo rotulo="Valor estornado (R$)">{(id) => <input id={id} inputMode="decimal" required value={valor} onChange={(e) => setValor(e.target.value)} />}</Campo>
          <Campo rotulo="Data do estorno">{(id) => <input id={id} type="date" required min={l.data} max={hoje()} value={data} onChange={(e) => setData(e.target.value)} />}</Campo>
        </div>
        {p && <p className="campo-ajuda">Entra na fatura que vence em {formatarData(p.vencimento)}.</p>}
        <Campo rotulo="Motivo (opcional)">{(id) => <input id={id} maxLength={200} value={motivo} onChange={(e) => setMotivo(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Lançar estorno"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ parcelas e antecipação
function DialogoParcelas({ l, cartao, aoFechar, aoAlterar }: { l: LancamentoFatura; cartao: LinhaCartao; aoFechar: () => void; aoAlterar: () => void }) {
  const { dados, erro, carregando, recarregar } = useCarregar(() => rpc<ParcelaDaCompra[]>("parcelas_da_compra", { p_compra_id: l.compra_id }), [l.compra_id]);
  const [marcadas, setMarcadas] = useState<number[]>([]);
  const [desconto, setDesconto] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const { chave, enviando, erro: erroEnvio, setErro, enviar } = useEnvio("compra-antecipar");
  const atual = cartao.fatura_atual_competencia;
  const parcelas = dados ?? [];
  const antecipaveis = parcelas.filter((p) => p.situacao === "ativa" && !p.antecipada && p.competencia > atual);
  const desfaziveis = parcelas.filter((p) => p.antecipada && p.situacao === "ativa" && p.status === "a_cobrar");
  const soma = parcelas.filter((p) => marcadas.includes(p.numero)).reduce((s, p) => s + p.valor_centavos, 0);
  const desc = desconto.trim() ? lerValor(desconto) : 0;
  const alternar = (n: number) => setMarcadas((m) => (m.includes(n) ? m.filter((x) => x !== n) : [...m, n].sort((a, b) => a - b)));

  return (
    <Dialogo titulo={`Parcelas: ${l.descricao}`} aoFechar={aoFechar} largo>
      {erro && <Alerta>{erro}</Alerta>}
      {carregando && !dados && <Carregando />}
      {msg && <Alerta tipo="ok">{msg}</Alerta>}
      {dados && (
        <form className="formulario" onSubmit={(e) => {
          e.preventDefault();
          if (marcadas.length === 0) return setErro("Marque as parcelas que vai antecipar.");
          if (desc === null || desc < 0) return setErro("Desconto inválido.");
          if (desc >= soma) return setErro("O desconto precisa ser menor que o valor antecipado.");
          void enviar(async () => {
            const n = await rpc<number>("compra_antecipar", { p_compra_id: l.compra_id, p_numeros: marcadas, p_fatura_competencia: null, p_desconto_centavos: desc, p_chave_idempotencia: `${chave}-${marcadas.join("-")}-${desc}` });
            setMsg(`${n} parcela(s) antecipada(s) para a fatura de ${mesCurto(atual)}.`);
            setMarcadas([]);
            setDesconto("");
            recarregar();
            aoAlterar();
          });
        }}>
          <ul className="lista-escolha">
            {parcelas.map((p) => {
              const pode = antecipaveis.some((a) => a.numero === p.numero);
              return (
                <li key={p.parcela_id}>
                  <label>
                    <input type="checkbox" disabled={!pode} checked={marcadas.includes(p.numero)} onChange={() => alternar(p.numero)} aria-label={`Parcela ${p.numero}`} />
                    <span className="lista-escolha-texto">
                      <strong>Parcela {p.numero}/{l.parcelas_total}</strong>
                      <span className="texto-suave">
                        Fatura de {mesCurto(p.competencia)} · {STATUS_PARCELA[p.status]}
                        {p.antecipada && p.fatura_original_competencia && ` · antecipada (era de ${mesCurto(p.fatura_original_competencia)})`}
                      </span>
                    </span>
                    <span className="num">
                      <Valor centavos={p.valor_centavos - p.desconto_centavos} />
                      {p.desconto_centavos > 0 && <span className="texto-suave">desconto {formatarCentavos(p.desconto_centavos)}</span>}
                    </span>
                  </label>
                </li>
              );
            })}
          </ul>
          {antecipaveis.length > 0 ? (
            <>
              <Campo rotulo="Desconto da antecipação (R$, opcional)" ajuda={marcadas.length ? `Antecipando ${formatarCentavos(soma)}${desc ? `; paga ${formatarCentavos(soma - desc)}` : ""}, na fatura de ${mesCurto(atual)}.` : `Marque as parcelas; elas vão para a fatura de ${mesCurto(atual)}.`}>
                {(id) => <input id={id} inputMode="decimal" value={desconto} onChange={(e) => setDesconto(e.target.value)} placeholder="0,00" />}
              </Campo>
              <p className="campo-ajuda">As parcelas antecipadas saem das faturas futuras (e das contas a pagar delas) e o histórico fica guardado.</p>
            </>
          ) : <p className="campo-ajuda">Nenhuma parcela futura para antecipar.</p>}
          {erroEnvio && <Alerta>{erroEnvio}</Alerta>}
          <div className="acoes">
            {desfaziveis.length > 0 && (
              <button type="button" className="botao-secundario" disabled={enviando} onClick={() => void enviar(async () => {
                const n = await rpc<number>("antecipacao_desfazer", { p_compra_id: l.compra_id, p_numeros: desfaziveis.map((p) => p.numero), p_motivo: "Antecipação desfeita pelo usuário" });
                setMsg(`${n} parcela(s) voltaram para as faturas originais.`);
                recarregar();
                aoAlterar();
              })}>Desfazer antecipação</button>
            )}
            <button type="button" className="botao-secundario" onClick={aoFechar}>Fechar</button>
            {antecipaveis.length > 0 && <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Antecipar"}</button>}
          </div>
        </form>
      )}
    </Dialogo>
  );
}

// ------------------------------------------------------------ cancelar / editar lançamento do cartão
function DialogoCancelarCompra({ l, aoFechar, aoConcluir }: { l: LancamentoFatura; aoFechar: () => void; aoConcluir: () => void }) {
  const [modo, setModo] = useState<"errado" | "loja">("errado");
  const [motivo, setMotivo] = useState("");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("compra-cancelar");
  const parcelado = l.parcelas_total > 1;
  return (
    <Dialogo titulo="Cancelar lançamento do cartão" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (motivo.trim().length < 3) return setErro("Escreva o motivo (pelo menos 3 letras).");
        void enviar(async () => {
          await rpc("compra_cancelar", { p_id: l.compra_id, p_versao_esperada: l.compra_versao, p_motivo: motivo, p_incluir_cobradas: modo === "errado", p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <p className="dialogo-texto"><strong>{l.descricao}</strong>{parcelado ? ` (${l.parcelas_total} parcelas)` : ""}, {formatarData(l.data)}.</p>
        <fieldset className="campo opcoes">
          <legend>O que aconteceu</legend>
          <label><input type="radio" name="modo" checked={modo === "errado"} onChange={() => setModo("errado")} /> Lancei errado: remover {parcelado ? "todas as parcelas" : "o lançamento"}</label>
          {(l.tipo === "compra" || l.tipo === "encargo") && (
            <label><input type="radio" name="modo" checked={modo === "loja"} onChange={() => setModo("loja")} /> A compra foi cancelada: remover só o que ainda não foi cobrado</label>
          )}
          <p className="campo-ajuda">
            {modo === "errado"
              ? "Nada é apagado: as parcelas ficam no histórico como canceladas e saem das faturas."
              : "Parcelas de faturas já fechadas continuam; o banco devolve essas com um estorno, que você lança em “Estornar”."}
          </p>
        </fieldset>
        <Campo rotulo="Motivo">{(id) => <input id={id} maxLength={200} value={motivo} onChange={(e) => setMotivo(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao-perigo" disabled={enviando}>{enviando ? "Salvando…" : "Cancelar lançamento"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

function DialogoEditarCompra({ l, aoFechar, aoConcluir }: { l: LancamentoFatura; aoFechar: () => void; aoConcluir: () => void }) {
  const compraQ = useCarregar(() => listar<Compra>("compras", { id: `eq.${l.compra_id}` }), [l.compra_id]);
  const compra = compraQ.dados?.[0];
  const [descricao, setDescricao] = useState(l.descricao);
  const [categoria, setCategoria] = useState(l.categoria_id ?? "");
  // valor da parcela antes do desconto de antecipação (o que o banco lista)
  const valorOriginal = l.valor_centavos + l.desconto_centavos;
  const podeMudarValor = (l.tipo === "compra" || l.tipo === "encargo") && l.status !== "cancelada";
  const [valor, setValor] = useState(centavosParaCampo(valorOriginal));
  const opcoes = useOpcoesDespesa(l.categoria_id);
  const { chave, enviando, erro, setErro, enviar } = useEnvio("compra-editar");
  const rotuloValor = l.parcelas_total > 1 ? `Valor da parcela ${l.numero}/${l.parcelas_total} (R$)` : "Valor (R$)";
  return (
    <Dialogo titulo="Editar lançamento do cartão" aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!descricao.trim()) return setErro("Escreva uma descrição.");
        if (!compra) return;
        const novoValor = podeMudarValor ? lerValor(valor) : valorOriginal;
        if (novoValor === null || novoValor <= 0) return setErro("Informe o valor, maior que zero.");
        void enviar(async () => {
          if (descricao !== l.descricao || (categoria || null) !== (l.categoria_id ?? null)) {
            await rpc("compra_atualizar", { p_id: l.compra_id, p_versao_esperada: compra.versao, p_descricao: descricao, p_categoria_id: categoria || null, p_observacao: compra.observacao, p_chave_idempotencia: chave });
          }
          if (novoValor !== valorOriginal) {
            await rpc("parcela_alterar_valor", { p_parcela_id: l.parcela_id, p_valor_centavos: novoValor, p_motivo: "Valor da parcela corrigido pelo usuário", p_chave_idempotencia: `${chave}-valor-${novoValor}` });
          }
          aoConcluir();
        });
      }}>
        <Campo rotulo="Descrição">{(id) => <input id={id} required maxLength={200} value={descricao} onChange={(e) => setDescricao(e.target.value)} />}</Campo>
        <Campo rotulo="Categoria">
          {(id) => (
            <select id={id} value={categoria} onChange={(e) => setCategoria(e.target.value)}>
              <option value="">Sem categoria</option>
              {opcoes.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select>
          )}
        </Campo>
        {podeMudarValor && (
          <Campo rotulo={rotuloValor}
            ajuda={l.parcelas_total > 1
              ? "Muda só esta parcela, nesta fatura (por exemplo, os centavos que o banco cobrou diferente). As outras parcelas continuam como estão; o total da compra acompanha."
              : "Use quando o banco cobrou um valor diferente do lançado."}>
            {(id) => <input id={id} inputMode="decimal" value={valor} onChange={(e) => setValor(e.target.value)} />}
          </Campo>
        )}
        <p className="campo-ajuda">Data e número de parcelas não mudam: se estiverem errados, cancele (“Lancei errado”) e lance de novo.</p>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando || !compra}>{enviando ? "Salvando…" : "Salvar alterações"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

// ------------------------------------------------------------ datas e total informado da fatura
function DialogoFatura({ fatura, aoFechar, aoConcluir }: { fatura: LinhaFatura; aoFechar: () => void; aoConcluir: () => void }) {
  const [fechamento, setFechamento] = useState(fatura.fechamento);
  const [vencimento, setVencimento] = useState(fatura.vencimento);
  const [informado, setInformado] = useState(fatura.total_informado_centavos !== null ? centavosParaCampo(fatura.total_informado_centavos) : "");
  const { chave, enviando, erro, setErro, enviar } = useEnvio("fatura-editar");
  return (
    <Dialogo titulo={`Fatura de ${nomeDoMes(mesDe(fatura.competencia)).toLowerCase()}`} aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        const inf = informado.trim() ? lerValor(informado) : null;
        if (!dataValida(fechamento) || !dataValida(vencimento) || fechamento >= vencimento) return setErro("O fechamento precisa ser antes do vencimento.");
        if (mesDe(vencimento) !== mesDe(fatura.competencia)) return setErro("O vencimento continua no mês da fatura.");
        if (informado.trim() && inf === null) return setErro("Total do banco inválido (ex.: 1.400,53), ou deixe em branco.");
        void enviar(async () => {
          await rpc("fatura_atualizar", { p_id: fatura.fatura_id, p_versao_esperada: fatura.versao, p_fechamento: fechamento, p_vencimento: vencimento, p_total_informado_centavos: inf, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <div className="grade-2">
          <Campo rotulo="Fechamento">{(id) => <input id={id} type="date" required value={fechamento} onChange={(e) => setFechamento(e.target.value)} />}</Campo>
          <Campo rotulo="Vencimento">{(id) => <input id={id} type="date" required value={vencimento} onChange={(e) => setVencimento(e.target.value)} />}</Campo>
        </div>
        <p className="campo-ajuda">Ajuste quando o banco mudar as datas desta fatura (feriado, fim de semana). Os lançamentos não mudam de fatura.</p>
        <Campo rotulo="Total da fatura segundo o banco (opcional)" ajuda={`Só para conferir. Calculado aqui: ${formatarCentavos(fatura.total_centavos)}. Nada é ajustado sozinho.`}>
          {(id) => <input id={id} inputMode="decimal" value={informado} onChange={(e) => setInformado(e.target.value)} placeholder="Ex.: 1.400,53" />}
        </Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Voltar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Salvar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
