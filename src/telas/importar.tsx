import { useMemo, useState } from "react";
import { guardarArquivo, rpc, sessaoAtual } from "../lib/api";
import { formatarData } from "../lib/datas";
import { formatarCentavos } from "../lib/dinheiro";
import { decodificar, sha256, type ExtratoLido } from "../lib/importadores/comum";
import { lerCsvBruto, mapearCsv, sugerirMapa, type MapaCsv } from "../lib/importadores/csv";
import { ehOfx, lerOfx } from "../lib/importadores/ofx";
import { ehNubankCsv, lerNubankCsv } from "../lib/importadores/nubank-csv";
import { lerItauExtratoPdf, reconheceItauExtrato } from "../lib/importadores/itau-extrato-pdf";
import { reconheceItauFatura } from "../lib/importadores/itau-fatura-pdf";
import { reconheceNubankFatura } from "../lib/importadores/nubank-fatura-pdf";
import { lerLinhasPdfNoNavegador } from "../lib/importadores/pdf";
import { PDFJS_BASE } from "../config";
import type { Classificacao } from "../lib/tipos";
import { Alerta, Campo, Carregando, Confirmar, TituloPagina, Valor, mensagemDeErro, useCadastros, useCarregar, useEnvio } from "../ui";

type LinhaImportacao = {
  importacao_id: string; arquivo_nome: string; formato: string; leitor: string; situacao: "previa" | "confirmada" | "cancelada";
  periodo_inicio: string | null; periodo_fim: string | null; itens_total: number; itens_importados: number; itens_duplicados: number;
  itens_ignorados: number; saldo_informado_centavos: number | null; saldo_informado_data: string | null; saldo_calculado_centavos: number | null;
  sobreposta_a: number; criado_em: string; cancelada_motivo: string | null; versao: number;
};
type Sugestao = "novo" | "ja_importado" | "possivel_duplicado" | "antes_data_base" | "data_futura" | "repetido_no_arquivo";
type ItemPrevia = {
  item_id: string; ordem: number; data: string; descricao: string; descricao_original: string; valor_centavos: number;
  identificador: string | null; sugestao: Sugestao; parecido_data: string | null; parecido_descricao: string | null;
  incluir: boolean; classificacao: Classificacao; categoria_id: string | null; situacao: string; movimento_id: string | null;
};
type Importacao = { id: string; versao: number; itens_importados: number; itens_duplicados: number; itens_ignorados: number; situacao: string };

const SUGESTAO: Record<Sugestao, { nome: string; classe: string; ajuda: string }> = {
  novo: { nome: "Novo", classe: "selo-ok", ajuda: "" },
  ja_importado: { nome: "Já importado", classe: "", ajuda: "Já entrou numa importação anterior; não será lançado de novo." },
  possivel_duplicado: { nome: "Possível duplicado", classe: "selo-previsto", ajuda: "Há um lançamento parecido; marque só se for outro." },
  antes_data_base: { nome: "Antes do saldo inicial", classe: "selo-neutro", ajuda: "Já está dentro do saldo inicial da conta." },
  data_futura: { nome: "Data futura", classe: "selo-neutro", ajuda: "Agendado no banco; entra quando acontecer." },
  repetido_no_arquivo: { nome: "Repetido no arquivo", classe: "selo-neutro", ajuda: "O próprio arquivo trouxe este lançamento duas vezes." },
};
const BLOQUEADAS: Sugestao[] = ["data_futura", "repetido_no_arquivo"];

/** Leitores próprios de banco, feitos e conferidos com arquivo real. */
const LEITORES: Record<string, string> = {
  "itau-extrato-pdf": "Extrato da conta Itaú (PDF) — leitor conferido com arquivo real; cada dia é conferido com o SALDO DO DIA do banco.",
  "nubank-csv-extrato": "Extrato da conta Nubank (CSV) — leitor conferido com arquivo real; usa o identificador de cada lançamento do banco.",
};

type Arquivo = { nome: string; bytes: Uint8Array; texto: string; extensao: string };

export function TelaImportar({ contaId }: { contaId?: string }) {
  const { contas, instituicoes } = useCadastros();
  const ativas = contas.filter((c) => c.ativa);
  const [conta, setConta] = useState(contaId && ativas.some((c) => c.id === contaId) ? contaId : ativas[0]?.id ?? "");
  const [arquivo, setArquivo] = useState<Arquivo | null>(null);
  const [linhasCsv, setLinhasCsv] = useState<string[][] | null>(null);
  const [mapa, setMapa] = useState<MapaCsv | null>(null);
  const [previa, setPrevia] = useState<{ imp: Importacao; itens: ItemPrevia[] } | null>(null);
  const [resultado, setResultado] = useState<Importacao | null>(null);
  const [erroArquivo, setErroArquivo] = useState<string | null>(null);
  const [lidoPdf, setLidoPdf] = useState<ExtratoLido | null>(null);
  const [lendo, setLendo] = useState(false);
  const historico = useCarregar(
    () => (conta ? rpc<LinhaImportacao[]>("importacoes_da_conta", { p_conta_id: conta }) : Promise.resolve([])),
    [conta, previa?.imp.id, resultado?.id],
  );
  const contaEscolhida = contas.find((c) => c.id === conta);

  const lido: ExtratoLido | null = useMemo(() => {
    if (!arquivo) return null;
    if (lidoPdf) return lidoPdf;
    if (arquivo.extensao === "pdf") return null;
    if (ehNubankCsv(arquivo.texto)) return lerNubankCsv(arquivo.texto);
    if (ehOfx(arquivo.texto)) return lerOfx(arquivo.texto);
    if (linhasCsv && mapa) return mapearCsv(linhasCsv, mapa);
    return null;
  }, [arquivo, linhasCsv, mapa, lidoPdf]);

  const avisoBanco = useMemo(() => {
    if (!lido?.banco || !contaEscolhida) return null;
    const cod = instituicoes.find((i) => i.id === contaEscolhida.instituicao_id)?.codigo_compe;
    if (!cod || Number(lido.banco.replace(/\D/g, "")) === Number(cod)) return null;
    return `O arquivo diz ser do banco ${lido.banco}, mas a conta escolhida é de outro banco (${cod}). Confira se escolheu a conta certa.`;
  }, [lido, contaEscolhida, instituicoes]);

  async function escolherArquivo(f: File | undefined) {
    setErroArquivo(null);
    setArquivo(null);
    setLinhasCsv(null);
    setMapa(null);
    setLidoPdf(null);
    if (!f) return;
    if (f.size > 10 * 1024 * 1024) return setErroArquivo("Arquivo grande demais (máximo 10 MB).");
    const bytes = new Uint8Array(await f.arrayBuffer());
    const texto = decodificar(bytes);
    const extensao = (f.name.split(".").pop() ?? "").toLowerCase();
    if (extensao === "pdf" || texto.startsWith("%PDF")) {
      setLendo(true);
      try {
        const linhas = await lerLinhasPdfNoNavegador(bytes, PDFJS_BASE);
        if (linhas.length === 0) {
          return setErroArquivo("Este PDF não tem texto (parece uma imagem ou digitalização). Baixe o extrato pelo app ou internet banking do banco.");
        }
        if (reconheceItauExtrato(linhas)) {
          setLidoPdf(lerItauExtratoPdf(linhas));
          return setArquivo({ nome: f.name, bytes, texto: "", extensao: "pdf" });
        }
        if (reconheceNubankFatura(linhas) || reconheceItauFatura(linhas)) {
          return setErroArquivo("Isto é a fatura de um cartão, não o extrato da conta. Importe pela tela do cartão: Cartões → escolha o cartão → Importar fatura.");
        }
        const topo = linhas.slice(0, 80).map((l) => l.texto.toLowerCase()).join(" ");
        if (/fatura/.test(topo) && /vencimento/.test(topo)) {
          return setErroArquivo("Isto parece uma fatura de cartão de um banco cuja fatura ainda não é lida. Por enquanto lance as compras pela tela do cartão.");
        }
        return setErroArquivo("Não reconheci este PDF. Em PDF, por enquanto, só o extrato da conta do Itaú é lido. Para outros bancos use OFX ou CSV.");
      } catch (e) {
        const msg = String((e as Error)?.name ?? "") + String((e as Error)?.message ?? "");
        return setErroArquivo(/password/i.test(msg)
          ? "Este PDF tem senha. Baixe o extrato sem senha pelo app ou internet banking."
          : "Não consegui abrir este PDF. Confira se o arquivo está inteiro e tente de novo.");
      } finally {
        setLendo(false);
      }
    }
    if (ehNubankCsv(texto)) {
      return setArquivo({ nome: f.name, bytes, texto, extensao: "csv" });
    }
    if (!ehOfx(texto)) {
      const { linhas } = lerCsvBruto(texto);
      if (linhas.length === 0 || linhas.every((l) => l.length < 2)) {
        return setErroArquivo("Não reconheci o arquivo. Envie um OFX ou um CSV (planilha separada por ponto e vírgula ou vírgula).");
      }
      setLinhasCsv(linhas);
      setMapa(sugerirMapa(linhas));
    }
    setArquivo({ nome: f.name, bytes, texto, extensao: ehOfx(texto) ? "ofx" : "csv" });
  }

  function recomecar() {
    setArquivo(null); setLinhasCsv(null); setMapa(null); setLidoPdf(null); setPrevia(null); setResultado(null); setErroArquivo(null);
  }

  return (
    <>
      {contaEscolhida && <p className="trilha"><a href={`#/conta/${contaEscolhida.id}`}>{contaEscolhida.apelido}</a></p>}
      <TituloPagina titulo="Importar extrato" />

      {!previa && !resultado && (
        <section className="secao estreita importar-passo">
          <div className="grade-2">
            <Campo rotulo="Conta">
              {(id) => (
                <select id={id} value={conta} onChange={(e) => { setConta(e.target.value); }}>
                  {ativas.map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
                </select>
              )}
            </Campo>
            <Campo rotulo="Arquivo do extrato (OFX, CSV ou PDF)">
              {(id) => <input id={id} type="file" accept=".ofx,.csv,.txt,.pdf" onChange={(e) => void escolherArquivo(e.target.files?.[0])} />}
            </Campo>
          </div>
          <p className="campo-ajuda">
            O arquivo original fica guardado. Antes de gravar, você vê a prévia e decide o que entra. O mesmo arquivo não é importado duas vezes
            e lançamentos que já entraram por outro arquivo são reconhecidos.
          </p>
          {lendo && <p className="texto-suave">Lendo o PDF…</p>}
          {erroArquivo && <Alerta>{erroArquivo}</Alerta>}
        </section>
      )}

      {arquivo && linhasCsv && mapa && !previa && !resultado && (
        <MapeamentoCsv linhas={linhasCsv} mapa={mapa} aoMudar={setMapa} />
      )}

      {arquivo && lido && !previa && !resultado && (
        <ResumoLeitura
          lido={lido} arquivo={arquivo} conta={conta} avisoBanco={avisoBanco}
          aoCriar={(imp, itens) => setPrevia({ imp, itens })}
        />
      )}

      {previa && !resultado && (
        <Previa
          previa={previa} contaSaldoInicial={contaEscolhida?.saldo_inicial_data ?? null}
          aoConfirmar={(r) => { setPrevia(null); setResultado(r); }}
          aoDescartar={recomecar}
        />
      )}

      {resultado && (
        <section className="secao estreita">
          <h2>Importação concluída</h2>
          <ul className="lista-resultado">
            <li><strong>{resultado.itens_importados}</strong> lançamento(s) importado(s)</li>
            {resultado.itens_duplicados > 0 && <li><strong>{resultado.itens_duplicados}</strong> já existiam e não foram repetidos</li>}
            {resultado.itens_ignorados > 0 && <li><strong>{resultado.itens_ignorados}</strong> deixados de fora</li>}
          </ul>
          <div className="acoes acoes-esquerda">
            {contaEscolhida && <a className="botao" href={`#/conta/${contaEscolhida.id}`}>Ver extrato da conta</a>}
            <button type="button" className="botao-secundario" onClick={recomecar}>Importar outro arquivo</button>
          </div>
        </section>
      )}

      {!previa && (
        <Historico dados={historico.dados ?? []} carregando={historico.carregando && !historico.dados} erro={historico.erro}
          aoRetomar={async (l) => {
            const itens = await rpc<ItemPrevia[]>("importacao_itens_lista", { p_importacao_id: l.importacao_id });
            setResultado(null);
            setPrevia({ imp: { id: l.importacao_id, versao: l.versao, itens_importados: 0, itens_duplicados: 0, itens_ignorados: 0, situacao: "previa" }, itens });
          }}
          aoAlterar={historico.recarregar} />
      )}
    </>
  );
}

// ------------------------------------------------------------ mapeamento de CSV
function MapeamentoCsv({ linhas, mapa, aoMudar }: { linhas: string[][]; mapa: MapaCsv; aoMudar: (m: MapaCsv) => void }) {
  const cols = Math.max(...linhas.slice(0, 20).map((l) => l.length));
  const nomes = Array.from({ length: cols }, (_, i) => (mapa.cabecalho && linhas[0][i] ? `${i + 1}: ${linhas[0][i]}` : `Coluna ${i + 1}`));
  const sel = (rotulo: string, chave: "colData" | "colDescricao" | "colValor" | "colDebito" | "colCredito") => (
    <Campo rotulo={rotulo}>
      {(id) => (
        <select id={id} value={mapa[chave]} onChange={(e) => aoMudar({ ...mapa, [chave]: Number(e.target.value) })}>
          {nomes.map((n, i) => <option key={i} value={i}>{n}</option>)}
        </select>
      )}
    </Campo>
  );
  return (
    <section className="secao importar-passo">
      <h2>Quais colunas são o quê?</h2>
      <p className="texto-suave">Confira as primeiras linhas do arquivo e indique as colunas. Nada é presumido sobre o banco.</p>
      <div className="tabela-rolagem">
        <table className="tabela tabela-compacta">
          <tbody>
            {linhas.slice(0, 6).map((l, i) => (
              <tr key={i} className={mapa.cabecalho && i === 0 ? "linha-cabecalho" : ""}>{Array.from({ length: cols }, (_, j) => <td key={j}>{l[j] ?? ""}</td>)}</tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="formulario">
        <label className="opcao-check"><input type="checkbox" checked={mapa.cabecalho} onChange={(e) => aoMudar({ ...mapa, cabecalho: e.target.checked })} /> A primeira linha é cabeçalho</label>
        <div className="grade-3">
          {sel("Data", "colData")}
          <Campo rotulo="Formato da data">
            {(id) => (
              <select id={id} value={mapa.formatoData} onChange={(e) => aoMudar({ ...mapa, formatoData: e.target.value as MapaCsv["formatoData"] })}>
                <option value="dmy">dia/mês/ano</option>
                <option value="ymd">ano-mês-dia</option>
                <option value="mdy">mês/dia/ano</option>
              </select>
            )}
          </Campo>
          {sel("Descrição", "colDescricao")}
        </div>
        <fieldset className="campo opcoes">
          <legend>O valor está em</legend>
          <label><input type="radio" name="modo-valor" checked={mapa.modoValor === "uma"} onChange={() => aoMudar({ ...mapa, modoValor: "uma" })} /> Uma coluna (com sinal)</label>
          <label><input type="radio" name="modo-valor" checked={mapa.modoValor === "duas"} onChange={() => aoMudar({ ...mapa, modoValor: "duas" })} /> Duas colunas (débito e crédito)</label>
        </fieldset>
        <div className="grade-3">
          {mapa.modoValor === "uma" ? sel("Valor", "colValor") : <>{sel("Débito (saída)", "colDebito")}{sel("Crédito (entrada)", "colCredito")}</>}
        </div>
        <label className="opcao-check"><input type="checkbox" checked={mapa.inverterSinal} onChange={(e) => aoMudar({ ...mapa, inverterSinal: e.target.checked })} /> O arquivo mostra as saídas como valor positivo (inverter o sinal)</label>
      </div>
    </section>
  );
}

// ------------------------------------------------------------ resumo da leitura e envio
function ResumoLeitura({ lido, arquivo, conta, avisoBanco, aoCriar }: {
  lido: ExtratoLido; arquivo: Arquivo; conta: string; avisoBanco: string | null; aoCriar: (imp: Importacao, itens: ItemPrevia[]) => void;
}) {
  const { chave, enviando, erro, enviar } = useEnvio("importacao-criar");
  const entradas = lido.itens.filter((i) => i.valor_centavos > 0).reduce((s, i) => s + i.valor_centavos, 0);
  const saidas = lido.itens.filter((i) => i.valor_centavos < 0).reduce((s, i) => s + i.valor_centavos, 0);
  const bloqueado = lido.tipo === "cartao" || lido.itens.length === 0 || (!!lido.estrito && lido.erros.length > 0);
  return (
    <section className="secao estreita importar-passo">
      <h2>{arquivo.nome}</h2>
      <p className="texto-suave">
        {LEITORES[lido.leitor] ?? `${lido.formato === "ofx" ? "Leitor OFX padrão" : "CSV com as colunas escolhidas"} — não homologado ainda com arquivo real deste banco: confira a prévia.`}
      </p>
      <ul className="lista-resultado">
        <li><strong>{lido.itens.length}</strong> lançamento(s) lido(s){lido.inicio && lido.fim ? `, de ${formatarData(lido.inicio)} a ${formatarData(lido.fim)}` : ""}</li>
        {lido.itens.length > 0 && <li>Entradas <Valor centavos={entradas} /> · saídas <Valor centavos={saidas} /></li>}
        {lido.saldo_centavos !== null && lido.saldo_data && <li>Saldo informado no arquivo em {formatarData(lido.saldo_data)}: <Valor centavos={lido.saldo_centavos} /></li>}
      </ul>
      {lido.avisos.map((a) => <Alerta key={a} tipo="aviso">{a}</Alerta>)}
      {avisoBanco && <Alerta tipo="aviso">{avisoBanco}</Alerta>}
      {lido.erros.length > 0 && lido.estrito && (
        <Alerta>
          A leitura não fechou com o arquivo do banco e, por segurança, nada será importado deste arquivo:
          <ul className="lista-erros">{lido.erros.slice(0, 8).map((e) => <li key={`${e.linha}-${e.motivo}`}>{e.linha ? `linha ${e.linha}: ` : ""}{e.motivo}</li>)}</ul>
          {lido.erros.length > 8 && <span>… e mais {lido.erros.length - 8}.</span>}
        </Alerta>
      )}
      {lido.erros.length > 0 && !lido.estrito && (
        <Alerta tipo="aviso">
          {lido.erros.length} linha(s) não puderam ser lidas e ficam de fora:
          <ul className="lista-erros">{lido.erros.slice(0, 8).map((e) => <li key={`${e.linha}-${e.motivo}`}>{e.linha ? `linha ${e.linha}: ` : ""}{e.motivo}</li>)}</ul>
          {lido.erros.length > 8 && <span>… e mais {lido.erros.length - 8}.</span>}
        </Alerta>
      )}
      {erro && <Alerta>{erro}</Alerta>}
      <div className="acoes acoes-esquerda">
        <button type="button" className="botao" disabled={enviando || bloqueado} onClick={() => void enviar(async () => {
          const uid = sessaoAtual()?.usuario.id;
          if (!uid) throw new Error("sessão");
          const hash = await sha256(arquivo.bytes);
          const caminho = `${uid}/importacoes/${hash}.${arquivo.extensao}`;
          await guardarArquivo(caminho, new Blob([arquivo.bytes]), { ofx: "application/x-ofx", pdf: "application/pdf" }[arquivo.extensao] ?? "text/csv");
          const imp = await rpc<Importacao>("importacao_criar", {
            p_conta_id: conta, p_formato: lido.formato, p_leitor: lido.leitor, p_arquivo_nome: arquivo.nome, p_arquivo_hash: hash,
            p_arquivo_caminho: caminho, p_arquivo_tamanho: arquivo.bytes.length, p_banco_no_arquivo: lido.banco, p_conta_no_arquivo: lido.conta,
            p_saldo_informado_centavos: lido.saldo_centavos, p_saldo_informado_data: lido.saldo_data,
            p_itens: lido.itens, p_chave_idempotencia: `${chave}-${hash.slice(0, 16)}`,
          });
          const itens = await rpc<ItemPrevia[]>("importacao_itens_lista", { p_importacao_id: imp.id });
          aoCriar(imp, itens);
        })}>{enviando ? "Preparando a prévia…" : "Ver prévia"}</button>
      </div>
    </section>
  );
}

// ------------------------------------------------------------ prévia editável
function Previa({ previa, contaSaldoInicial, aoConfirmar, aoDescartar }: {
  previa: { imp: Importacao; itens: ItemPrevia[] }; contaSaldoInicial: string | null;
  aoConfirmar: (r: Importacao) => void; aoDescartar: () => void;
}) {
  const { categorias } = useCadastros();
  const [itens, setItens] = useState(previa.itens);
  const [descartando, setDescartando] = useState(false);
  const { chave, enviando, erro, enviar } = useEnvio("importacao-confirmar");
  const original = useMemo(() => new Map(previa.itens.map((i) => [i.item_id, i])), [previa.itens]);
  const mudar = (id: string, campos: Partial<ItemPrevia>) => setItens((l) => l.map((i) => (i.item_id === id ? { ...i, ...campos } : i)));
  const incluidos = itens.filter((i) => i.incluir && !BLOQUEADAS.includes(i.sugestao));
  const soma = incluidos.reduce((s, i) => s + i.valor_centavos, 0);
  const contagem = itens.reduce<Record<string, number>>((m, i) => ({ ...m, [i.sugestao]: (m[i.sugestao] ?? 0) + 1 }), {});
  const opcoesCat = (valor: number) => categorias.filter((c) => c.ativa && c.tipo === (valor < 0 ? "despesa" : "receita"));

  return (
    <section className="importar-passo">
      <div className="totais">
        <div><p className="texto-suave">Vão entrar</p><p className="valor-destaque">{incluidos.length} de {itens.length}</p></div>
        <div><p className="texto-suave">Efeito no saldo</p><p className="valor-destaque"><Valor centavos={soma} sinal /></p></div>
        <div className="texto-suave previa-contagem">
          {(Object.keys(SUGESTAO) as Sugestao[]).filter((k) => contagem[k]).map((k) => <span key={k} className={`selo ${SUGESTAO[k].classe}`}>{SUGESTAO[k].nome}: {contagem[k]}</span>)}
        </div>
      </div>
      {contagem.possivel_duplicado > 0 && (
        <Alerta tipo="aviso">
          {contagem.possivel_duplicado} lançamento(s) parecem com algum que já está na conta (mesmo valor, até 3 dias de diferença). Eles ficaram desmarcados:
          marque só os que forem realmente outros.
        </Alerta>
      )}
      {contagem.antes_data_base > 0 && contaSaldoInicial && (
        <p className="texto-suave">Lançamentos até {formatarData(contaSaldoInicial)} já estão no saldo inicial da conta e ficaram desmarcados.</p>
      )}
      <div className="tabela-rolagem">
        <table className="tabela extrato previa">
          <thead><tr><th><span className="sr">Incluir</span></th><th>Data</th><th>Descrição</th><th className="num">Valor</th><th>Categoria</th></tr></thead>
          <tbody>
            {itens.map((i) => (
              <tr key={i.item_id} className={i.incluir && !BLOQUEADAS.includes(i.sugestao) ? "" : "linha-fora"}>
                <td><input type="checkbox" aria-label={`Incluir ${i.descricao}`} checked={i.incluir && !BLOQUEADAS.includes(i.sugestao)}
                  disabled={BLOQUEADAS.includes(i.sugestao)} onChange={(e) => mudar(i.item_id, { incluir: e.target.checked })} /></td>
                <td className="data">{formatarData(i.data)}</td>
                <td>
                  <input className="campo-inline" aria-label="Descrição" value={i.descricao} maxLength={200} onChange={(e) => mudar(i.item_id, { descricao: e.target.value })} />
                  <span className={`selo ${SUGESTAO[i.sugestao].classe}`} title={SUGESTAO[i.sugestao].ajuda}>{SUGESTAO[i.sugestao].nome}</span>
                  {i.parecido_data && i.sugestao === "possivel_duplicado" && (
                    <span className="texto-suave">Parecido com: {i.parecido_descricao} em {formatarData(i.parecido_data)}</span>
                  )}
                </td>
                <td className="num"><Valor centavos={i.valor_centavos} sinal /></td>
                <td>
                  <select aria-label="Categoria" value={i.categoria_id ?? ""} onChange={(e) => {
                    const v = e.target.value;
                    mudar(i.item_id, { categoria_id: v || null, classificacao: v ? (i.valor_centavos < 0 ? "despesa" : "receita") : "nao_classificado" });
                  }}>
                    <option value="">Sem categoria</option>
                    {opcoesCat(i.valor_centavos).map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                  </select>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {erro && <Alerta>{erro}</Alerta>}
      <div className="acoes">
        <button type="button" className="botao-secundario" onClick={() => setDescartando(true)}>Descartar prévia</button>
        <button type="button" className="botao" disabled={enviando || incluidos.length === 0} onClick={() => void enviar(async () => {
          const ajustes = itens.filter((i) => {
            const o = original.get(i.item_id)!;
            return o.incluir !== i.incluir || o.descricao !== i.descricao || o.categoria_id !== i.categoria_id || o.classificacao !== i.classificacao;
          }).map((i) => ({ id: i.item_id, incluir: i.incluir, descricao: i.descricao, classificacao: i.classificacao, categoria_id: i.categoria_id }));
          const r = await rpc<Importacao>("importacao_confirmar", { p_id: previa.imp.id, p_versao_esperada: previa.imp.versao, p_ajustes: ajustes, p_chave_idempotencia: chave });
          aoConfirmar(r);
        })}>{enviando ? "Importando…" : `Importar ${incluidos.length} lançamento(s)`}</button>
      </div>
      {descartando && (
        <Confirmar titulo="Descartar prévia" rotuloAcao="Descartar" perigo
          texto={<p>Nada desta prévia entra na conta. O arquivo original continua guardado e pode ser importado de novo depois.</p>}
          aoFechar={() => setDescartando(false)}
          aoConfirmar={async () => { await rpc("importacao_desfazer", { p_id: previa.imp.id, p_versao_esperada: previa.imp.versao, p_motivo: "Prévia descartada", p_chave_idempotencia: null }); aoDescartar(); }} />
      )}
    </section>
  );
}

// ------------------------------------------------------------ importações anteriores
function Historico({ dados, carregando, erro, aoRetomar, aoAlterar }: {
  dados: LinhaImportacao[]; carregando: boolean; erro: string | null; aoRetomar: (l: LinhaImportacao) => Promise<void>; aoAlterar: () => void;
}) {
  const [desfazendo, setDesfazendo] = useState<LinhaImportacao | null>(null);
  const [erroRetomar, setErroRetomar] = useState<string | null>(null);
  if (carregando) return <Carregando />;
  if (erro) return <Alerta>{erro}</Alerta>;
  if (dados.length === 0) return null;
  return (
    <section className="secao">
      <h2>Importações desta conta</h2>
      {erroRetomar && <Alerta>{erroRetomar}</Alerta>}
      <ul className="lista-simples">
        {dados.map((l) => {
          const dif = l.saldo_informado_centavos !== null && l.saldo_calculado_centavos !== null ? l.saldo_calculado_centavos - l.saldo_informado_centavos : null;
          return (
            <li key={l.importacao_id} className={l.situacao === "cancelada" ? "linha-arquivada" : ""}>
              <div>
                <strong>{l.arquivo_nome}</strong>
                <span className="texto-suave">
                  {l.periodo_inicio && l.periodo_fim ? `${formatarData(l.periodo_inicio)} a ${formatarData(l.periodo_fim)} · ` : ""}
                  {l.situacao === "previa" ? `prévia com ${l.itens_total} lançamento(s), não confirmada`
                    : `${l.itens_importados} importado(s), ${l.itens_duplicados} repetido(s) evitado(s), ${l.itens_ignorados} de fora`}
                  {l.sobreposta_a > 0 && " · período sobreposto a outra importação (repetidos foram evitados)"}
                </span>
                {l.situacao === "confirmada" && dif !== null && l.saldo_informado_data && (
                  <span className={`selo ${dif === 0 ? "selo-ok" : "selo-previsto"}`}>
                    {dif === 0 ? `Saldo confere com o banco em ${formatarData(l.saldo_informado_data)}`
                      : `Saldo em ${formatarData(l.saldo_informado_data)}: banco ${formatarCentavos(l.saldo_informado_centavos!)}, aqui ${formatarCentavos(l.saldo_calculado_centavos!)}`}
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
        <Confirmar titulo={desfazendo.situacao === "previa" ? "Descartar prévia" : "Desfazer importação"} rotuloAcao={desfazendo.situacao === "previa" ? "Descartar" : "Desfazer"} perigo pedirMotivo="obrigatorio"
          texto={desfazendo.situacao === "previa"
            ? <p>Nada desta prévia entra na conta.</p>
            : <p>Os {desfazendo.itens_importados} lançamento(s) criados por <strong>{desfazendo.arquivo_nome}</strong> serão cancelados e saem do saldo. Nada é apagado: ficam no histórico, com o motivo. Depois o arquivo pode ser importado de novo.</p>}
          aoFechar={() => setDesfazendo(null)}
          aoConfirmar={async (motivo) => { await rpc("importacao_desfazer", { p_id: desfazendo.importacao_id, p_versao_esperada: desfazendo.versao, p_motivo: motivo, p_chave_idempotencia: null }); setDesfazendo(null); aoAlterar(); }} />
      )}
    </section>
  );
}
