// Importação da FATURA de um cartão (PDF): leitura no navegador com
// conferência do total, prévia no banco (o que já está lançado, o que é
// novo, antecipações e ajustes de centavos), confirmação e histórico.
import { useMemo, useState } from "react";
import { guardarArquivo, listar, rpc, sessaoAtual } from "../lib/api";
import { PDFJS_BASE } from "../config";
import { formatarData } from "../lib/datas";
import { formatarCentavos } from "../lib/dinheiro";
import { sha256 } from "../lib/importadores/comum";
import type { FaturaLida } from "../lib/importadores/fatura-comum";
import { LEITORES_FATURA } from "../lib/importadores/faturas";
import { reconheceItauExtrato } from "../lib/importadores/itau-extrato-pdf";
import { lerLinhasPdfNoNavegador } from "../lib/importadores/pdf";
import type { Cartao, LinhaCartao } from "../lib/tipos";
import { Alerta, Campo, Carregando, Confirmar, TituloPagina, Valor, mensagemDeErro, useCadastros, useCarregar, useEnvio } from "../ui";

type Sugestao = "novo" | "ja_importado" | "ja_lancado" | "possivel_duplicado" | "antecipar";
type ImportacaoFatura = {
  id: string; versao: number; situacao: string; fatura_id: string; vencimento: string; itens_total: number;
  itens_lancados: number; itens_existentes: number; itens_antecipados: number; itens_ajustados: number; itens_ignorados: number;
};
type ItemFatura = {
  item_id: string; ordem: number; data: string; descricao: string; descricao_original: string; valor_centavos: number;
  tipo: "compra" | "encargo" | "credito"; parcela_atual: number | null; parcelas_total: number | null; antecipada: boolean; final: string | null;
  sugestao: Sugestao; ajuste_centavos: number; existente_descricao: string | null; existente_data: string | null; existente_competencia: string | null;
  vinculo_ordem: number | null; incluir: boolean; categoria_id: string | null; situacao: string;
};
type LinhaHistorico = {
  importacao_id: string; arquivo_nome: string; leitor: string; situacao: "previa" | "confirmada" | "cancelada"; competencia: string; vencimento: string;
  total_lancamentos_centavos: number; total_fatura_centavos: number; itens_total: number; itens_lancados: number; itens_existentes: number;
  itens_antecipados: number; itens_ajustados: number; itens_ignorados: number; criado_em: string; cancelada_motivo: string | null; versao: number;
};

const SUGESTAO: Record<Sugestao, { nome: string; classe: string }> = {
  novo: { nome: "Novo", classe: "selo-ok" },
  ja_importado: { nome: "Já importado", classe: "" },
  ja_lancado: { nome: "Já lançado", classe: "" },
  possivel_duplicado: { nome: "Possível duplicado", classe: "selo-previsto" },
  antecipar: { nome: "Antecipar", classe: "selo-neutro" },
};
const TRAVADAS: Sugestao[] = ["ja_importado", "ja_lancado"];
const LEITORES: Record<string, string> = Object.fromEntries(
  LEITORES_FATURA.map((l) => [l.id, `Fatura do cartão ${l.banco} (PDF) — leitor conferido com arquivo real.`]),
);
const mesAno = (iso: string) => `${iso.slice(5, 7)}/${iso.slice(0, 4)}`;

type Arquivo = { nome: string; bytes: Uint8Array };

export function TelaImportarFatura({ cartaoId }: { cartaoId: string }) {
  const { instituicoes } = useCadastros();
  const cartaoQ = useCarregar(async () => {
    const [cad] = await listar<Cartao>("cartoes", { id: `eq.${cartaoId}` });
    const resumo = (await rpc<LinhaCartao[]>("cartoes_resumo")).find((r) => r.cartao_id === cartaoId) ?? null;
    return { cad: cad ?? null, resumo };
  }, [cartaoId]);
  const [arquivo, setArquivo] = useState<Arquivo | null>(null);
  const [lida, setLida] = useState<FaturaLida | null>(null);
  const [lendo, setLendo] = useState(false);
  const [erroArquivo, setErroArquivo] = useState<string | null>(null);
  const [previa, setPrevia] = useState<{ imp: ImportacaoFatura; itens: ItemFatura[] } | null>(null);
  const [resultado, setResultado] = useState<ImportacaoFatura | null>(null);
  const historico = useCarregar(() => rpc<LinhaHistorico[]>("importacoes_fatura_do_cartao", { p_cartao_id: cartaoId }), [cartaoId, previa?.imp.id, resultado?.id]);
  const cartao = cartaoQ.dados?.cad ?? null;
  const nome = cartaoQ.dados?.resumo?.apelido ?? cartao?.apelido ?? "Cartão";

  const avisos = useMemo(() => {
    if (!lida || !cartao) return [];
    const a: string[] = [];
    const cod = instituicoes.find((i) => i.id === cartao.instituicao_id)?.codigo_compe;
    if (cod && lida.banco && Number(cod) !== Number(lida.banco)) a.push(`A fatura é do banco ${lida.banco}, mas este cartão está cadastrado em outro banco (${cod}). Confira se escolheu o cartão certo.`);
    if (cartao.final && lida.finais.length > 0 && !lida.finais.includes(cartao.final)) {
      a.push(`A fatura mostra os finais ${lida.finais.join(", ")}; o cadastro deste cartão diz ${cartao.final}. Confira (cartões virtuais têm outro final).`);
    }
    const dia = Number(lida.vencimento.slice(8, 10));
    if (dia !== cartao.dia_vencimento) {
      a.push(`A fatura vence no dia ${dia}, mas o cadastro do cartão diz dia ${cartao.dia_vencimento}. A fatura importada fica com as datas do banco; corrija o cadastro em "Editar" para as próximas compras caírem na fatura certa.`);
    }
    return a;
  }, [lida, cartao, instituicoes]);

  async function escolher(f: File | undefined) {
    setErroArquivo(null); setLida(null); setArquivo(null);
    if (!f) return;
    if (f.size > 10 * 1024 * 1024) return setErroArquivo("Arquivo grande demais (máximo 10 MB).");
    const bytes = new Uint8Array(await f.arrayBuffer());
    if (!(f.name.toLowerCase().endsWith(".pdf") || new TextDecoder("latin1").decode(bytes.slice(0, 5)) === "%PDF-")) {
      return setErroArquivo("Escolha a fatura em PDF, baixada do app ou do site do banco.");
    }
    setLendo(true);
    try {
      const linhas = await lerLinhasPdfNoNavegador(bytes, PDFJS_BASE);
      if (linhas.length === 0) return setErroArquivo("Este PDF não tem texto (parece uma imagem ou digitalização). Baixe a fatura pelo app do banco.");
      const leitor = LEITORES_FATURA.find((l) => l.reconhece(linhas));
      if (!leitor) {
        return setErroArquivo(reconheceItauExtrato(linhas)
          ? "Isto é o extrato da conta, não a fatura do cartão. Importe pela conta (Saldos → conta → Importar extrato)."
          : `Não reconheci esta fatura. São lidas as faturas em PDF de: ${LEITORES_FATURA.map((l) => l.banco).join(", ")}.`);
      }
      setLida(leitor.ler(linhas));
      setArquivo({ nome: f.name, bytes });
    } catch (e) {
      const msg = String((e as Error)?.name ?? "") + String((e as Error)?.message ?? "");
      setErroArquivo(/password/i.test(msg) ? "Este PDF tem senha. Baixe a fatura sem senha pelo app ou site do banco." : "Não consegui abrir este PDF. Confira se o arquivo está inteiro.");
    } finally {
      setLendo(false);
    }
  }

  function recomecar() { setArquivo(null); setLida(null); setPrevia(null); setResultado(null); setErroArquivo(null); }

  if (cartaoQ.carregando && !cartaoQ.dados) return <Carregando />;
  if (cartaoQ.erro) return <Alerta>{cartaoQ.erro}</Alerta>;
  if (!cartao) return <Alerta>Cartão não encontrado. <a href="#/cartoes">Voltar para cartões</a></Alerta>;

  return (
    <>
      <p className="trilha"><a href="#/cartoes">Cartões</a> · <a href={`#/cartao/${cartaoId}`}>{nome}</a></p>
      <TituloPagina titulo="Importar fatura" />
      {!previa && !resultado && (
        <section className="secao estreita importar-passo">
          <Campo rotulo="Fatura do cartão (PDF)">
            {(id) => <input id={id} type="file" accept=".pdf,application/pdf" onChange={(e) => void escolher(e.target.files?.[0])} />}
          </Campo>
          <p className="campo-ajuda">
            Cada lançamento da fatura é comparado com o que já está no cartão: parcelas já lançadas não se repetem, e os centavos de
            arredondamento ficam como o banco cobrou. Pagamentos da fatura não viram compras. Nada muda antes de você confirmar a prévia.
          </p>
          {lendo && <p className="texto-suave">Lendo o PDF…</p>}
          {erroArquivo && <Alerta>{erroArquivo}</Alerta>}
        </section>
      )}
      {arquivo && lida && !previa && !resultado && (
        <ResumoFatura lida={lida} arquivo={arquivo} cartaoId={cartaoId} avisos={avisos} aoCriar={(imp, itens) => setPrevia({ imp, itens })} />
      )}
      {previa && !resultado && (
        <PreviaFatura previa={previa} aoConfirmar={(r) => { setPrevia(null); setResultado(r); }} aoDescartar={recomecar} />
      )}
      {resultado && (
        <section className="secao estreita">
          <h2>Fatura importada</h2>
          <ul className="lista-resultado">
            <li><strong>{resultado.itens_lancados}</strong> lançamento(s) novo(s)</li>
            {resultado.itens_existentes > 0 && <li><strong>{resultado.itens_existentes}</strong> já estavam no cartão e não foram repetidos</li>}
            {resultado.itens_antecipados > 0 && <li><strong>{resultado.itens_antecipados}</strong> parcela(s) antecipada(s) para esta fatura</li>}
            {resultado.itens_ajustados > 0 && <li><strong>{resultado.itens_ajustados}</strong> parcela(s) com centavos acertados pelo valor do banco</li>}
            {resultado.itens_ignorados > 0 && <li><strong>{resultado.itens_ignorados}</strong> deixado(s) de fora</li>}
          </ul>
          <div className="acoes acoes-esquerda">
            <a className="botao" href={`#/cartao/${cartaoId}/${resultado.vencimento.slice(0, 7)}`}>Ver a fatura</a>
            <button type="button" className="botao-secundario" onClick={recomecar}>Importar outra fatura</button>
          </div>
        </section>
      )}
      {!previa && (
        <HistoricoFatura dados={historico.dados ?? []} carregando={historico.carregando && !historico.dados} erro={historico.erro}
          aoRetomar={async (l) => {
            const itens = await rpc<ItemFatura[]>("importacao_fatura_itens_lista", { p_importacao_id: l.importacao_id });
            setResultado(null);
            setPrevia({ imp: { id: l.importacao_id, versao: l.versao, situacao: "previa", fatura_id: "", vencimento: l.vencimento, itens_total: l.itens_total,
              itens_lancados: 0, itens_existentes: 0, itens_antecipados: 0, itens_ajustados: 0, itens_ignorados: 0 }, itens });
          }}
          aoAlterar={historico.recarregar} />
      )}
    </>
  );
}

// ------------------------------------------------------------ resumo da leitura
function ResumoFatura({ lida, arquivo, cartaoId, avisos, aoCriar }: {
  lida: FaturaLida; arquivo: Arquivo; cartaoId: string; avisos: string[]; aoCriar: (imp: ImportacaoFatura, itens: ItemFatura[]) => void;
}) {
  const { chave, enviando, erro, enviar } = useEnvio("importacao-fatura-criar");
  const bloqueado = lida.erros.length > 0 || lida.itens.length === 0;
  const compras = lida.itens.filter((i) => i.valor_centavos > 0).reduce((s, i) => s + i.valor_centavos, 0);
  const creditos = lida.itens.filter((i) => i.valor_centavos < 0).reduce((s, i) => s + i.valor_centavos, 0);
  return (
    <section className="secao estreita importar-passo">
      <h2>{arquivo.nome}</h2>
      <p className="texto-suave">{LEITORES[lida.leitor] ?? lida.leitor}</p>
      <ul className="lista-resultado">
        <li>Fatura de <strong>{mesAno(lida.vencimento)}</strong>: vence em {formatarData(lida.vencimento)}{lida.fechamento ? `, fechou em ${formatarData(lida.fechamento)}` : ""}</li>
        <li><strong>{lida.itens.length}</strong> lançamento(s) · compras e encargos <Valor centavos={compras} /> · créditos <Valor centavos={creditos} /></li>
        {lida.total_lancamentos_centavos !== null && <li>Total dos lançamentos segundo o banco: <Valor centavos={lida.total_lancamentos_centavos} /></li>}
        {lida.total_a_pagar_centavos !== null && lida.total_a_pagar_centavos !== lida.total_lancamentos_centavos && (
          <li className="texto-suave">Total a pagar da fatura: {formatarCentavos(lida.total_a_pagar_centavos)} (inclui saldo anterior e pagamentos feitos antes do vencimento)</li>
        )}
        {lida.pagamentos.length > 0 && (
          <li className="texto-suave">Pagamentos na fatura (não viram compras): {lida.pagamentos.map((p) => `${formatarData(p.data)} ${formatarCentavos(p.valor_centavos)}`).join(" · ")}</li>
        )}
      </ul>
      {lida.avisos.map((a) => <Alerta key={a} tipo="aviso">{a}</Alerta>)}
      {avisos.map((a) => <Alerta key={a} tipo="aviso">{a}</Alerta>)}
      {lida.erros.length > 0 && (
        <Alerta>
          A leitura não fechou com a fatura do banco e, por segurança, nada será importado deste arquivo:
          <ul className="lista-erros">{lida.erros.slice(0, 8).map((e) => <li key={`${e.linha}-${e.motivo}`}>{e.linha ? `lançamento ${e.linha}: ` : ""}{e.motivo}</li>)}</ul>
        </Alerta>
      )}
      {erro && <Alerta>{erro}</Alerta>}
      <div className="acoes acoes-esquerda">
        <button type="button" className="botao" disabled={enviando || bloqueado} onClick={() => void enviar(async () => {
          const uid = sessaoAtual()?.usuario.id;
          if (!uid) throw new Error("sessão");
          const hash = await sha256(arquivo.bytes);
          const caminho = `${uid}/importacoes/${hash}.pdf`;
          await guardarArquivo(caminho, new Blob([arquivo.bytes]), "application/pdf");
          const imp = await rpc<ImportacaoFatura>("importacao_fatura_criar", {
            p_cartao_id: cartaoId, p_leitor: lida.leitor, p_arquivo_nome: arquivo.nome, p_arquivo_hash: hash, p_arquivo_caminho: caminho,
            p_arquivo_tamanho: arquivo.bytes.length, p_finais: lida.finais.join(",") || null, p_vencimento: lida.vencimento, p_fechamento: lida.fechamento,
            p_total_lancamentos_centavos: lida.total_lancamentos_centavos, p_total_a_pagar_centavos: lida.total_a_pagar_centavos,
            p_itens: lida.itens, p_pagamentos: lida.pagamentos, p_chave_idempotencia: `${chave}-${hash.slice(0, 16)}`,
          });
          const itens = await rpc<ItemFatura[]>("importacao_fatura_itens_lista", { p_importacao_id: imp.id });
          aoCriar(imp, itens);
        })}>{enviando ? "Preparando a prévia…" : "Ver prévia"}</button>
      </div>
    </section>
  );
}

// ------------------------------------------------------------ prévia
function detalhe(i: ItemFatura, itens: ItemFatura[]): string | null {
  const parc = i.parcela_atual ? `${i.parcela_atual}/${i.parcelas_total}` : "";
  const dif = i.ajuste_centavos !== 0 ? ` · centavos acertados para o valor do banco (${i.ajuste_centavos > 0 ? "+" : "−"}${formatarCentavos(Math.abs(i.ajuste_centavos))})` : "";
  switch (i.sugestao) {
    case "ja_lancado":
      return i.parcela_atual ? `Parcela ${parc} já lançada: ${i.existente_descricao}${dif}`
        : `Desconto já lançado na antecipação de: ${i.existente_descricao}`;
    case "ja_importado": return "Já entrou por outra importação desta fatura";
    case "possivel_duplicado":
      return i.parcela_atual
        ? `Parcela ${parc} de "${i.existente_descricao}" já está na fatura de ${i.existente_competencia ? mesAno(i.existente_competencia) : "outro mês"}`
        : `Parecido com: ${i.existente_descricao}${i.existente_data ? ` em ${formatarData(i.existente_data)}` : ""}`;
    case "antecipar": {
      if (i.vinculo_ordem) {
        const base = itens.find((x) => x.ordem === i.vinculo_ordem);
        return `Antecipa a parcela ${parc} da compra "${base?.descricao ?? i.descricao}" desta mesma fatura`;
      }
      return `Antecipa a parcela ${parc} de "${i.existente_descricao}", que estava na fatura de ${i.existente_competencia ? mesAno(i.existente_competencia) : "outro mês"}${dif}`;
    }
    case "novo":
      if (i.antecipada) return `Parcela ${parc} antecipada sem a compra no Simplifica: entra como lançamento único`;
      if (i.parcela_atual) return i.parcela_atual === 1 ? `Compra em ${i.parcelas_total}x (as próximas parcelas vão para as faturas seguintes)`
        : `Compra em ${i.parcelas_total}x lançada a partir da parcela ${i.parcela_atual}`;
      if (i.tipo === "encargo") return "Encargo";
      if (i.tipo === "credito") return "Crédito na fatura";
      return null;
  }
}

function PreviaFatura({ previa, aoConfirmar, aoDescartar }: {
  previa: { imp: ImportacaoFatura; itens: ItemFatura[] }; aoConfirmar: (r: ImportacaoFatura) => void; aoDescartar: () => void;
}) {
  const { categorias } = useCadastros();
  const [itens, setItens] = useState(previa.itens);
  const [descartando, setDescartando] = useState(false);
  const { chave, enviando, erro, enviar } = useEnvio("importacao-fatura-confirmar");
  const original = useMemo(() => new Map(previa.itens.map((i) => [i.item_id, i])), [previa.itens]);
  const mudar = (id: string, campos: Partial<ItemFatura>) => setItens((l) => l.map((i) => (i.item_id === id ? { ...i, ...campos } : i)));
  const entram = itens.filter((i) => i.incluir && !TRAVADAS.includes(i.sugestao));
  const contagem = itens.reduce<Record<string, number>>((m, i) => ({ ...m, [i.sugestao]: (m[i.sugestao] ?? 0) + 1 }), {});
  const despesas = categorias.filter((c) => c.ativa && c.tipo === "despesa");
  return (
    <section className="importar-passo">
      <div className="totais">
        <div><p className="texto-suave">Vão entrar</p><p className="valor-destaque">{entram.length} de {itens.length}</p></div>
        <div><p className="texto-suave">Fatura de</p><p className="valor-destaque">{mesAno(previa.imp.vencimento)}</p></div>
        <div className="texto-suave previa-contagem">
          {(Object.keys(SUGESTAO) as Sugestao[]).filter((k) => contagem[k]).map((k) => <span key={k} className={`selo ${SUGESTAO[k].classe}`}>{SUGESTAO[k].nome}: {contagem[k]}</span>)}
        </div>
      </div>
      {contagem.possivel_duplicado > 0 && (
        <Alerta tipo="aviso">
          {contagem.possivel_duplicado} lançamento(s) parecem com algum que já está no cartão e ficaram desmarcados: marque só os que forem realmente outros.
        </Alerta>
      )}
      <div className="tabela-rolagem">
        <table className="tabela extrato previa">
          <thead><tr><th><span className="sr">Incluir</span></th><th>Data</th><th>Descrição</th><th className="num">Valor</th><th>Categoria</th></tr></thead>
          <tbody>
            {itens.map((i) => {
              const travado = TRAVADAS.includes(i.sugestao);
              const marcado = i.incluir && !travado;
              const d = detalhe(i, itens);
              return (
                <tr key={i.item_id} className={marcado ? "" : "linha-fora"}>
                  <td><input type="checkbox" aria-label={`Incluir ${i.descricao}`} checked={marcado} disabled={travado}
                    onChange={(e) => mudar(i.item_id, { incluir: e.target.checked })} /></td>
                  <td className="data">{formatarData(i.data)}</td>
                  <td>
                    <input className="campo-inline" aria-label="Descrição" value={i.descricao} maxLength={200} disabled={travado}
                      onChange={(e) => mudar(i.item_id, { descricao: e.target.value })} />
                    {i.parcela_atual && <span className="selo selo-neutro">{i.antecipada ? "Antecipada " : ""}{i.parcela_atual}/{i.parcelas_total}</span>}
                    <span className={`selo ${SUGESTAO[i.sugestao].classe}`}>{SUGESTAO[i.sugestao].nome}</span>
                    {d && <span className="texto-suave">{d}</span>}
                  </td>
                  <td className="num"><Valor centavos={i.valor_centavos} /></td>
                  <td>
                    {!travado && i.sugestao !== "antecipar" && (
                      <select aria-label="Categoria" value={i.categoria_id ?? ""} onChange={(e) => mudar(i.item_id, { categoria_id: e.target.value || null })}>
                        <option value="">Sem categoria</option>
                        {despesas.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                      </select>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {erro && <Alerta>{erro}</Alerta>}
      <div className="acoes">
        <button type="button" className="botao-secundario" onClick={() => setDescartando(true)}>Descartar prévia</button>
        <button type="button" className="botao" disabled={enviando} onClick={() => void enviar(async () => {
          const ajustes = itens.filter((i) => {
            const o = original.get(i.item_id)!;
            return o.incluir !== i.incluir || o.descricao !== i.descricao || o.categoria_id !== i.categoria_id;
          }).map((i) => ({ id: i.item_id, incluir: i.incluir, descricao: i.descricao, categoria_id: i.categoria_id }));
          const r = await rpc<ImportacaoFatura>("importacao_fatura_confirmar", { p_id: previa.imp.id, p_versao_esperada: previa.imp.versao, p_ajustes: ajustes, p_chave_idempotencia: chave });
          aoConfirmar(r);
        })}>{enviando ? "Importando…" : "Importar fatura"}</button>
      </div>
      {descartando && (
        <Confirmar titulo="Descartar prévia" rotuloAcao="Descartar" perigo
          texto={<p>Nada desta prévia entra no cartão. O PDF continua guardado e pode ser importado de novo depois.</p>}
          aoFechar={() => setDescartando(false)}
          aoConfirmar={async () => { await rpc("importacao_fatura_desfazer", { p_id: previa.imp.id, p_versao_esperada: previa.imp.versao, p_motivo: "Prévia descartada", p_chave_idempotencia: null }); aoDescartar(); }} />
      )}
    </section>
  );
}

// ------------------------------------------------------------ histórico
function HistoricoFatura({ dados, carregando, erro, aoRetomar, aoAlterar }: {
  dados: LinhaHistorico[]; carregando: boolean; erro: string | null; aoRetomar: (l: LinhaHistorico) => Promise<void>; aoAlterar: () => void;
}) {
  const [desfazendo, setDesfazendo] = useState<LinhaHistorico | null>(null);
  const [erroRetomar, setErroRetomar] = useState<string | null>(null);
  if (carregando) return <Carregando />;
  if (erro) return <Alerta>{erro}</Alerta>;
  if (dados.length === 0) return null;
  return (
    <section className="secao">
      <h2>Faturas importadas deste cartão</h2>
      {erroRetomar && <Alerta>{erroRetomar}</Alerta>}
      <ul className="lista-simples">
        {dados.map((l) => {
          const dif = l.total_fatura_centavos - l.total_lancamentos_centavos;
          return (
            <li key={l.importacao_id} className={l.situacao === "cancelada" ? "linha-arquivada" : ""}>
              <div>
                <strong>Fatura de {mesAno(l.competencia)}</strong> <span className="texto-suave">{l.arquivo_nome}</span>
                <span className="texto-suave">
                  {l.situacao === "previa" ? `prévia com ${l.itens_total} lançamento(s), não confirmada`
                    : `${l.itens_lancados} novo(s), ${l.itens_existentes} já lançado(s), ${l.itens_antecipados} antecipado(s), ${l.itens_ajustados} ajuste(s) de centavos, ${l.itens_ignorados} de fora`}
                </span>
                {l.situacao === "confirmada" && (
                  <span className={`selo ${dif === 0 ? "selo-ok" : "selo-previsto"}`}>
                    {dif === 0 ? `Fatura confere com o banco (${formatarCentavos(l.total_lancamentos_centavos)})`
                      : `Banco ${formatarCentavos(l.total_lancamentos_centavos)}, aqui ${formatarCentavos(l.total_fatura_centavos)}`}
                  </span>
                )}
                {l.situacao === "cancelada" && <span className="selo">Desfeita{l.cancelada_motivo ? `: ${l.cancelada_motivo}` : ""}</span>}
              </div>
              <span className="acoes-linha">
                {l.situacao === "previa" && <button type="button" className="botao-texto" onClick={() => { setErroRetomar(null); aoRetomar(l).catch((e) => setErroRetomar(mensagemDeErro(e))); }}>Continuar prévia</button>}
                {l.situacao !== "cancelada" && <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setDesfazendo(l)}>{l.situacao === "previa" ? "Descartar" : "Desfazer"}</button>}
              </span>
            </li>
          );
        })}
      </ul>
      {desfazendo && (
        <Confirmar titulo={desfazendo.situacao === "previa" ? "Descartar prévia" : "Desfazer importação da fatura"} rotuloAcao={desfazendo.situacao === "previa" ? "Descartar" : "Desfazer"}
          perigo pedirMotivo="obrigatorio"
          texto={desfazendo.situacao === "previa" ? <p>Nada desta prévia entra no cartão.</p>
            : <p>As compras criadas por esta importação são canceladas (ficam no histórico, com o motivo), as parcelas antecipadas voltam para as faturas de origem
              e os centavos acertados voltam ao valor anterior. O que já estava lançado continua como estava.</p>}
          aoFechar={() => setDesfazendo(null)}
          aoConfirmar={async (motivo) => { await rpc("importacao_fatura_desfazer", { p_id: desfazendo.importacao_id, p_versao_esperada: desfazendo.versao, p_motivo: motivo, p_chave_idempotencia: null }); setDesfazendo(null); aoAlterar(); }} />
      )}
    </section>
  );
}
