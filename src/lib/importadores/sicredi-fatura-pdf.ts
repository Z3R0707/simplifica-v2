// Leitor da FATURA do cartão Sicredi em PDF. Feito e conferido com arquivo real.
//
// Layout: capa com o "Resumo da fatura" (total anterior, pagamentos |
// créditos, despesas no Brasil e no exterior, total desta fatura) e
// "Transações" por cartão ("Cartão Fulano (final 1234)", "Cartão virtual
// … (final 5678)"), cada um com "Total cartão (final …)".
// Lançamento: "14/set 22:36", cidade, tipo de compra, descrição, parcela
// "01/04", valores em dólar (se houver) e "R$ 93,49". Descrições longas
// quebram em linhas sem data, logo acima e abaixo da linha da data.
// Conferência: soma dos itens = despesas no Brasil + no exterior −
// créditos (pagamentos e créditos do resumo − pagamentos lidos).
import type { LinhaPdf } from "./pdf.ts";
import {
  MESES, conferirTotal, dataCompraParcela, marcarAntecipacoesNaFatura, separarParcela, subtipoEncargo, valorBr,
  type FaturaLida, type ItemFatura,
} from "./fatura-comum.ts";

const DATA = /^(\d{2})\/(jan|fev|mar|abr|mai|jun|jul|ago|set|out|nov|dez) \d{2}:\d{2}$/i;
const VALOR = /^-?R\$ ?-?[\d.]+,\d{2}$/;
const VALOR_RESUMO = /^-?[\d.]+,\d{2}$/;
const X_DESCRICAO = [230, 345];   // coluna "Descrição"
const X_PARCELA = [345, 385];     // coluna "Parcela"

export function reconheceSicrediFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.map((l) => l.texto).join(" | ");
  return /sicredi/i.test(t) && /Resumo da fatura/.test(t) && /Despesas atuais \| Débitos no Brasil/.test(t) && linhas.some((l) => /^Transações$/.test(l.texto));
}

const iso = (d: string) => d.split("/").reverse().join("-");

export function lerSicrediFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "sicredi-fatura-pdf", banco: "748", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  const todo = linhas.map((l) => l.texto).join("\n");
  const venc = /Vencimento (\d{2}\/\d{2}\/\d{4})/.exec(todo);
  if (!venc) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  f.vencimento = iso(venc[1]);
  const valorDe = (re: RegExp) => {
    for (const l of linhas) {
      const i = l.celulas.findIndex((c) => re.test(c.texto));
      if (i >= 0 && l.celulas[i + 1] && VALOR_RESUMO.test(l.celulas[i + 1].texto)) return valorBr(l.celulas[i + 1].texto);
    }
    return null;
  };
  f.total_a_pagar_centavos = valorDe(/^Total desta Fatura$/);
  const brasil = valorDe(/^Despesas atuais \| Débitos no Brasil$/);
  const exterior = valorDe(/^Despesas atuais \| Débitos no Exterior$/) ?? 0;
  const pagCred = valorDe(/^Pagamentos \| Créditos$/) ?? 0;

  // linhas de lançamento (com data) e pedaços de descrição sem data
  type Lanc = { pagina: number; y: number; celulas: LinhaPdf["celulas"]; final: string | null; extra: { y: number; texto: string }[] };
  const lancs: Lanc[] = [];
  const soltos: { pagina: number; y: number; texto: string }[] = [];
  let final: string | null = null;
  let emTransacoes = false;
  const finais = new Set<string>();
  for (const l of linhas) {
    if (/^Transações$/.test(l.texto)) { emTransacoes = true; continue; }
    if (/^Legenda:/.test(l.texto) || /^Opções de pagamento$/.test(l.texto)) { emTransacoes = false; continue; }
    if (!emTransacoes) continue;
    const cart = /^Cartão .*\(final (\d{4})\)$/.exec(l.texto);
    if (cart) { final = cart[1]; finais.add(final); continue; }
    if (DATA.test(l.celulas[0]?.texto ?? "")) { lancs.push({ pagina: l.pagina, y: l.y, celulas: l.celulas, final, extra: [] }); continue; }
    const d = l.celulas.filter((c) => c.x >= X_DESCRICAO[0] && c.x2 <= X_DESCRICAO[1] + 40);
    if (d.length === 1 && l.celulas.length === 1) soltos.push({ pagina: l.pagina, y: l.y, texto: d[0].texto });
  }
  for (const s of soltos) {
    const alvo = lancs.filter((x) => x.pagina === s.pagina && Math.abs(x.y - s.y) <= 8).sort((a, b) => Math.abs(a.y - s.y) - Math.abs(b.y - s.y))[0];
    if (alvo) alvo.extra.push({ y: s.y, texto: s.texto });
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
    const descricao = pedacos.map((p) => p.texto).join(" ").replace(/\s+/g, " ").trim();
    const pc = c.find((x) => x.x >= X_PARCELA[0] && x.x < X_PARCELA[1] && /^\d{2}\/\d{2}$/.test(x.texto));
    const parc = pc ? separarParcela(`X ${pc.texto}`, "itau") : { atual: null, total: null };
    const data = dataCompraParcela(Number(md[1]), MESES[md[2].toUpperCase()], f.vencimento, parc.atual);
    if (!descricao || !data) { f.erros.push({ linha: n, motivo: `lançamento incompleto: "${c.map((x) => x.texto).join(" ")}"` }); continue; }
    if (valor < 0 && /^Pagamento\b/i.test(descricao)) {
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
  const pagos = f.pagamentos.reduce((s, p) => s + Math.abs(p.valor_centavos), 0);
  const creditos = Math.abs(pagCred) - pagos;
  f.total_lancamentos_centavos = brasil === null ? null : brasil + exterior - creditos;
  if (creditos < 0) f.erros.push({ linha: 0, motivo: "os pagamentos lidos passam do total de pagamentos e créditos do resumo" });
  f.finais = [...finais].sort();
  marcarAntecipacoesNaFatura(f.itens);
  conferirTotal(f, "total de despesas menos créditos do resumo");
  return f;
}
