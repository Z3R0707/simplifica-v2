// Leitor da FATURA do cartão Mercado Pago em PDF. Feito e conferido com arquivo real.
//
// Layout: capa com "Resumo da fatura" (consumos, juros do mês anterior,
// tarifas e encargos, multas, pagamentos, total); "Detalhes de consumo"
// com "Movimentações na fatura" (pagamento e encargos do rotativo, sem
// cartão) e uma seção por cartão ("Cartão Visa [****1234]"), cada uma
// com o seu "Total". Lançamento: dd/mm, descrição, "Parcela N de M" (se
// houver) e "R$ 0,00". O pagamento da fatura aparece SEM sinal e é
// reconhecido pela descrição ("Pagamento da fatura de ...").
// Conferência: soma dos itens = consumos + juros do mês anterior +
// tarifas e encargos + multas (resumo do próprio banco).
import type { LinhaPdf } from "./pdf.ts";
import {
  conferirTotal, dataCompraParcela, marcarAntecipacoesNaFatura, subtipoEncargo, valorBr,
  type FaturaLida, type ItemFatura,
} from "./fatura-comum.ts";

const DATA = /^(\d{2})\/(\d{2})$/;
const VALOR = /^-?R\$ ?-?[\d.]+,\d{2}$/;
const PARCELA = /^Parcela (\d{1,2}) de (\d{1,2})$/;

export function reconheceMercadoPagoFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.map((l) => l.texto).join(" | ");
  return /Pague sua fatura pelo app Mercado Pago/.test(t) && /Detalhes de consumo/.test(t) && /Vencimento: \d{2}\/\d{2}\/\d{4}/.test(t);
}

const iso = (d: string) => d.split("/").reverse().join("-");

export function lerMercadoPagoFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "mercadopago-fatura-pdf", banco: "323", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  const todo = linhas.map((l) => l.texto).join("\n");
  const venc = /Vencimento: (\d{2}\/\d{2}\/\d{4})/.exec(todo);
  if (!venc) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  f.vencimento = iso(venc[1]);
  const fech = /Fechamento da fatura (\d{2}\/\d{2}\/\d{4})/.exec(todo);
  if (fech) f.fechamento = iso(fech[1]);

  // resumo: pares "rótulo" → "R$ valor"
  const valorDe = (re: RegExp) => {
    for (const l of linhas) {
      const i = l.celulas.findIndex((c) => re.test(c.texto));
      if (i >= 0 && l.celulas[i + 1] && VALOR.test(l.celulas[i + 1].texto)) return valorBr(l.celulas[i + 1].texto);
    }
    return null;
  };
  const consumos = valorDe(/^Consumos de \d{2}\/\d{2} a \d{2}\/\d{2}$/);
  const partes = [/^Juros do mês anterior$/, /^Tarifas e encargos$/, /^Multas por atraso$/].map(valorDe);
  f.total_lancamentos_centavos = consumos === null ? null : consumos + partes.reduce<number>((s, v) => s + (v ?? 0), 0);
  const totalLinha = linhas.find((l) => l.pagina === 1 && l.celulas.length === 2 && l.celulas[0].texto === "Total" && l.celulas[0].x > 300);
  if (totalLinha) f.total_a_pagar_centavos = valorBr(totalLinha.celulas[1].texto);

  let secao: "nenhuma" | "movimentacoes" | "cartao" = "nenhuma";
  let final: string | null = null;
  const finais = new Set<string>();
  let n = 0;
  for (const l of linhas) {
    const c = l.celulas;
    const texto = l.texto;
    if (/^Movimentações na fatura$/.test(texto)) { secao = "movimentacoes"; final = null; continue; }
    const cart = /^Cartão .*\[\**(\d{4})\]$/.exec(texto);
    if (cart) { secao = "cartao"; final = cart[1]; finais.add(final); continue; }
    if (/^Parcele a fatura/.test(texto) || /^Seu cartão de crédito/.test(texto)) { secao = "nenhuma"; continue; }
    if (secao === "nenhuma") continue;
    const md = DATA.exec(c[0]?.texto ?? "");
    if (!md) continue; // cabeçalho, "Total", detalhe de compra internacional
    n++;
    const ultima = c[c.length - 1];
    if (!VALOR.test(ultima.texto)) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${texto}"` }); continue; }
    const valor = valorBr(ultima.texto)!;
    const meio = c.slice(1, -1);
    const pc = meio.find((x) => PARCELA.test(x.texto));
    const descricao = meio.filter((x) => x !== pc).map((x) => x.texto).join(" ").replace(/\s+/g, " ").trim();
    if (!descricao) { f.erros.push({ linha: n, motivo: "lançamento sem descrição" }); continue; }
    const mp = pc ? PARCELA.exec(pc.texto)! : null;
    let atual = mp ? Number(mp[1]) : null;
    let total = mp ? Number(mp[2]) : null;
    if (atual !== null && (total! < 2 || atual > total! || atual < 1)) { atual = null; total = null; }
    const data = dataCompraParcela(Number(md[1]), Number(md[2]), f.vencimento, atual);
    if (!data) { f.erros.push({ linha: n, motivo: `data inválida: "${texto}"` }); continue; }
    if (/^Pagamento da fatura\b/i.test(descricao)) {
      f.pagamentos.push({ data, descricao: descricao.slice(0, 200), valor_centavos: -Math.abs(valor) });
      continue;
    }
    if (valor === 0) continue;
    const sub = subtipoEncargo(descricao);
    let item: ItemFatura;
    if (valor < 0) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "credito", final };
    else if (sub && atual === null) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub, final };
    else item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", parcela_atual: atual, parcelas_total: total, final };
    f.itens.push(item);
  }
  f.finais = [...finais].sort();
  marcarAntecipacoesNaFatura(f.itens);
  conferirTotal(f, "total de consumos, juros, tarifas e multas do resumo");
  return f;
}
