// Leitor CSV com mapeamento de colunas feito pelo usuário. Não presume o
// layout de nenhum banco: a pessoa diz qual coluna é data, descrição e valor.
import { dataIso, valorParaCentavos, type ExtratoLido, type ItemLido } from "./comum.ts";

/** Divide o CSV em linhas e colunas (aspas, separador ; , ou tabulação). */
export function lerCsvBruto(texto: string): { separador: string; linhas: string[][] } {
  const primeira = texto.split(/\r?\n/).find((l) => l.trim()) ?? "";
  const contar = (s: string) => (primeira.match(new RegExp(s === "\t" ? "\\t" : `\\${s}`, "g")) ?? []).length;
  const separador = [";", "\t", ","].sort((a, b) => contar(b) - contar(a))[0];
  const linhas: string[][] = [];
  let linha: string[] = [];
  let campo = "";
  let aspas = false;
  for (let i = 0; i < texto.length; i++) {
    const c = texto[i];
    if (aspas) {
      if (c === '"' && texto[i + 1] === '"') { campo += '"'; i++; }
      else if (c === '"') aspas = false;
      else campo += c;
    } else if (c === '"' && campo.trim() === "") { aspas = true; campo = ""; }
    else if (c === separador) { linha.push(campo); campo = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && texto[i + 1] === "\n") i++;
      linha.push(campo);
      if (linha.some((x) => x.trim())) linhas.push(linha.map((x) => x.trim()));
      linha = []; campo = "";
    } else campo += c;
  }
  linha.push(campo);
  if (linha.some((x) => x.trim())) linhas.push(linha.map((x) => x.trim()));
  return { separador, linhas };
}

export type MapaCsv = {
  cabecalho: boolean;
  colData: number;
  colDescricao: number;
  modoValor: "uma" | "duas";   // uma coluna com sinal, ou débito e crédito separados
  colValor: number;
  colDebito: number;
  colCredito: number;
  formatoData: "dmy" | "ymd" | "mdy";
  inverterSinal: boolean;      // quando o arquivo traz saída positiva
};

export function dataCsv(t: string, formato: MapaCsv["formatoData"]): string | null {
  const s = (t ?? "").trim().split(/[ T]/)[0];
  const p = s.split(/[/.-]/).map((x) => x.trim());
  if (p.length !== 3 || p.some((x) => !/^\d+$/.test(x))) return null;
  let [a, m, d] = [0, 0, 0];
  if (formato === "ymd") [a, m, d] = [Number(p[0]), Number(p[1]), Number(p[2])];
  else if (formato === "dmy") [d, m, a] = [Number(p[0]), Number(p[1]), Number(p[2])];
  else [m, d, a] = [Number(p[0]), Number(p[1]), Number(p[2])];
  if (p[formato === "ymd" ? 0 : 2].length === 2) a += 2000;
  return dataIso(a, m, d);
}

/** Sugere o mapeamento olhando o cabeçalho (o usuário confirma na tela). */
export function sugerirMapa(linhas: string[][]): MapaCsv {
  const cab = (linhas[0] ?? []).map((c) => c.toLowerCase());
  const temCabecalho = cab.some((c) => /data|descri|hist|valor|lan[cç]amento|d[ée]bito|cr[ée]dito/.test(c));
  const achar = (re: RegExp) => cab.findIndex((c) => re.test(c));
  const colDebito = achar(/d[ée]bito|sa[ií]da/);
  const colCredito = achar(/cr[ée]dito|entrada/);
  const amostra = linhas[temCabecalho ? 1 : 0] ?? [];
  const colDataSug = temCabecalho ? Math.max(0, achar(/data/)) : Math.max(0, amostra.findIndex((c) => /^\d{1,4}[/.-]\d{1,2}[/.-]\d{1,4}/.test(c)));
  const dataAmostra = amostra[colDataSug] ?? "";
  return {
    cabecalho: temCabecalho,
    colData: colDataSug,
    colDescricao: temCabecalho ? Math.max(0, achar(/descri|hist|lan[cç]amento|estabelec/)) : 1,
    modoValor: colDebito >= 0 && colCredito >= 0 ? "duas" : "uma",
    colValor: temCabecalho ? Math.max(0, achar(/valor|quantia|montante/)) : Math.max(0, amostra.length - 1),
    colDebito: Math.max(0, colDebito),
    colCredito: Math.max(0, colCredito),
    formatoData: /^\d{4}/.test(dataAmostra) ? "ymd" : "dmy",
    inverterSinal: false,
  };
}

export function mapearCsv(linhas: string[][], mapa: MapaCsv): ExtratoLido {
  const res: ExtratoLido = {
    formato: "csv", leitor: "csv-mapeado", tipo: "extrato", banco: null, conta: null,
    saldo_centavos: null, saldo_data: null, inicio: null, fim: null, itens: [], erros: [], avisos: [],
  };
  linhas.slice(mapa.cabecalho ? 1 : 0).forEach((l, i) => {
    const n = i + 1 + (mapa.cabecalho ? 1 : 0);
    const data = dataCsv(l[mapa.colData] ?? "", mapa.formatoData);
    const descricao = (l[mapa.colDescricao] ?? "").replace(/\s+/g, " ").trim();
    let valor: number | null;
    if (mapa.modoValor === "uma") {
      valor = valorParaCentavos(l[mapa.colValor] ?? "");
    } else {
      const deb = (l[mapa.colDebito] ?? "").trim() ? valorParaCentavos(l[mapa.colDebito]) : 0;
      const cred = (l[mapa.colCredito] ?? "").trim() ? valorParaCentavos(l[mapa.colCredito]) : 0;
      valor = deb === null || cred === null ? null : Math.abs(cred) - Math.abs(deb);
    }
    if (!data) return void res.erros.push({ linha: n, motivo: `data inválida: "${l[mapa.colData] ?? ""}"` });
    if (valor === null) return void res.erros.push({ linha: n, motivo: "valor inválido" });
    if (valor === 0) return void res.erros.push({ linha: n, motivo: "valor zero (linha de saldo ou informativa?)" });
    if (!descricao) return void res.erros.push({ linha: n, motivo: "sem descrição" });
    const item: ItemLido = { data, descricao: descricao.slice(0, 200), valor_centavos: mapa.inverterSinal ? -valor : valor };
    res.itens.push(item);
  });
  const datas = res.itens.map((x) => x.data).sort();
  res.inicio = datas[0] ?? null;
  res.fim = datas[datas.length - 1] ?? null;
  return res;
}
