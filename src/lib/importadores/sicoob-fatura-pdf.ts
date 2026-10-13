// Leitor da FATURA do cartão Sicoob em PDF. Feito e conferido com arquivo real.
//
// Layout: capa com "VENCIMENTO 11 OUT 2026"; páginas com "REF 1 SET A
// 1 OUT"; "LANÇAMENTOS - SICOOB …" com "MOVIMENTAÇÕES DA CONTA" (saldo
// anterior, pagamento, anuidade, estornos, tarifas) e uma seção por
// portador ("FULANO  1234"), até o "TOTAL" da fatura.
// Cada lançamento tem a data ("13 FEV") e o valor ("R$ 310,32") numa
// linha; a descrição e a parcela ("06/10") podem estar na mesma linha ou
// quebradas logo acima/abaixo dela.
// Conferência: soma dos itens = TOTAL − SALDO ANTERIOR − pagamentos lidos.
import type { LinhaPdf } from "./pdf.ts";
import {
  MESES, conferirTotal, dataCompraParcela, dataSemAno, marcarAntecipacoesNaFatura, separarParcela, subtipoEncargo, valorBr,
  type FaturaLida, type ItemFatura,
} from "./fatura-comum.ts";

const DATA = /^(\d{2}) (JAN|FEV|MAR|ABR|MAI|JUN|JUL|AGO|SET|OUT|NOV|DEZ)$/;
const VALOR = /^-?R\$ ?-?[\d.]+,\d{2}$/;
const X_DESCRICAO = [60, 160];

export function reconheceSicoobFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.map((l) => l.texto).join(" | ");
  return /SICOOB/i.test(t) && /LANÇAMENTOS - SICOOB/.test(t) && /REF \d{1,2} [A-Z]{3} A \d{1,2} [A-Z]{3}/.test(t);
}

export function lerSicoobFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "sicoob-fatura-pdf", banco: "756", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  const vl = linhas.find((l) => l.celulas.some((c) => c.texto === "VENCIMENTO") && l.celulas.some((c) => /^\d{2} [A-Z]{3} \d{4}$/.test(c.texto)));
  const vm = vl ? /^(\d{2}) ([A-Z]{3}) (\d{4})$/.exec(vl.celulas.find((c) => /^\d{2} [A-Z]{3} \d{4}$/.test(c.texto))!.texto) : null;
  if (!vm || !MESES[vm[2]]) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  f.vencimento = `${vm[3]}-${String(MESES[vm[2]]).padStart(2, "0")}-${vm[1]}`;
  const ref = linhas.map((l) => /^REF \d{1,2} [A-Z]{3} A (\d{1,2}) ([A-Z]{3})$/.exec(l.texto)).find(Boolean);
  if (ref && MESES[ref[2]]) f.fechamento = dataSemAno(Number(ref[1]), MESES[ref[2]], f.vencimento);

  const ini = linhas.findIndex((l) => /^LANÇAMENTOS - SICOOB/.test(l.texto));
  const fim = linhas.findIndex((l, i) => i > ini && l.celulas.length === 2 && l.celulas[0].texto === "TOTAL" && VALOR.test(l.celulas[1].texto));
  if (ini < 0 || fim < 0) {
    f.erros.push({ linha: 0, motivo: "não encontrei a lista de lançamentos ou o TOTAL da fatura" });
    return f;
  }
  const totalFatura = valorBr(linhas[fim].celulas[1].texto)!;
  f.total_a_pagar_centavos = totalFatura;
  let saldoAnterior = 0;

  type Lanc = { pagina: number; y: number; celulas: LinhaPdf["celulas"]; final: string | null; extra: { y: number; texto: string }[] };
  const lancs: Lanc[] = [];
  const soltos: { pagina: number; y: number; textos: string[] }[] = [];
  let final: string | null = null;
  const finais = new Set<string>();
  for (const l of linhas.slice(ini + 1, fim)) {
    const c = l.celulas;
    if (/^SALDO ANTERIOR$/.test(c[0]?.texto ?? "") && VALOR.test(c[c.length - 1].texto)) { saldoAnterior = valorBr(c[c.length - 1].texto)!; continue; }
    if (/^(MOVIMENTAÇÕES DA CONTA|DATA DESCRIÇÃO CIDADE VALOR EM R\$)$/.test(l.texto) || /^TOTAL DE /.test(l.texto)) continue;
    if (c.length === 2 && /^\d{4}$/.test(c[1].texto) && !DATA.test(c[0].texto)) { final = c[1].texto; finais.add(final); continue; }
    if (DATA.test(c[0]?.texto ?? "")) { lancs.push({ pagina: l.pagina, y: l.y, celulas: c, final, extra: [] }); continue; }
    const d = c.filter((x) => x.x >= X_DESCRICAO[0] && x.x < X_DESCRICAO[1]).map((x) => x.texto);
    if (d.length) soltos.push({ pagina: l.pagina, y: l.y, textos: d });
  }
  for (const s of soltos) {
    const alvo = lancs.filter((x) => x.pagina === s.pagina && Math.abs(x.y - s.y) <= 8).sort((a, b) => Math.abs(a.y - s.y) - Math.abs(b.y - s.y))[0];
    if (alvo) for (const t of s.textos) alvo.extra.push({ y: s.y, texto: t });
  }

  let n = 0;
  for (const lc of lancs) {
    n++;
    const c = lc.celulas;
    const md = DATA.exec(c[0].texto)!;
    const ultima = c[c.length - 1];
    if (!VALOR.test(ultima.texto)) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${c.map((x) => x.texto).join(" ")}"` }); continue; }
    const valor = valorBr(ultima.texto)!;
    const pedacos = [...c.filter((x) => x.x >= X_DESCRICAO[0] && x.x < X_DESCRICAO[1]).map((x) => ({ y: lc.y, texto: x.texto })), ...lc.extra]
      .sort((a, b) => b.y - a.y);
    const pc = pedacos.find((p) => /^\d{2}\/\d{2}$/.test(p.texto));
    const descricao = pedacos.filter((p) => p !== pc).map((p) => p.texto).join(" ").replace(/\s+/g, " ").trim();
    const parc = pc ? separarParcela(`X ${pc.texto}`, "itau") : { atual: null, total: null };
    const data = dataCompraParcela(Number(md[1]), MESES[md[2]], f.vencimento, parc.atual);
    if (!descricao || !data) { f.erros.push({ linha: n, motivo: `lançamento incompleto: "${c.map((x) => x.texto).join(" ")}"` }); continue; }
    if (valor < 0 && /^PAGAMENTO\b/i.test(descricao)) {
      f.pagamentos.push({ data, descricao: descricao.slice(0, 200), valor_centavos: valor });
      continue;
    }
    if (valor === 0) continue;
    const sub = subtipoEncargo(descricao);
    let item: ItemFatura;
    if (valor < 0) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "credito", final: lc.final };
    else if (sub && parc.atual === null) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub, final: lc.final };
    else item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", parcela_atual: parc.atual, parcelas_total: parc.total, final: lc.final };
    f.itens.push(item);
  }
  const pagos = f.pagamentos.reduce((s, p) => s + p.valor_centavos, 0);
  f.total_lancamentos_centavos = totalFatura - saldoAnterior - pagos;
  f.finais = [...finais].sort();
  marcarAntecipacoesNaFatura(f.itens);
  conferirTotal(f, "total da fatura (descontados saldo anterior e pagamentos)");
  return f;
}
