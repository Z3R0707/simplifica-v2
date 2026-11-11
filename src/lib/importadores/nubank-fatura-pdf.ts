// Leitor da FATURA do cartão Nubank em PDF. Feito e conferido com arquivo real.
//
// Layout: capa com "Data de vencimento: 14 OUT 2026" e "Período vigente:
// 07 SET a 07 OUT"; páginas "TRANSAÇÕES DE 07 SET A 07 OUT" com linhas
//   07 SET  •••• 4321  Descrição - Parcela 4/12      R$ 100,00
// agrupadas por portador ("Fulano  R$ 5.228,96" = subtotal) e, ao fim,
// "Pagamentos e Financiamentos" (pagamentos, não são lançamentos).
// Antecipação: "Antecipada - Loja - Parcela 3/3" (débito) e
// "Desconto Antecipação Loja" (crédito).
// Conferência: a soma dos itens precisa bater com a soma dos subtotais
// dos portadores (= compras + IOF + outros lançamentos do resumo).
import type { LinhaPdf } from "./pdf.ts";
import { MESES, ajustarArredondamentoCambio, conferirTotal, dataSemAno, separarParcela, subtipoEncargo, valorBr, type FaturaLida, type ItemFatura } from "./fatura-comum.ts";

const DATA = /^(\d{2}) (JAN|FEV|MAR|ABR|MAI|JUN|JUL|AGO|SET|OUT|NOV|DEZ)$/;
const VALOR = /^[-−]?R\$ ?[\d.]+,\d{2}$|^R\$ ?[-−][\d.]+,\d{2}$/;

export function reconheceNubankFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.slice(0, 60).map((l) => l.texto).join(" | ");
  return /Data de vencimento: \d{2} [A-Z]{3} \d{4}/.test(t) && /Período vigente:/.test(t) && linhas.some((l) => /^TRANSAÇÕES DE /.test(l.texto));
}

function dataCompleta(d: string, mes: string, ano: string): string | null {
  const m = MESES[mes];
  return m ? `${ano}-${String(m).padStart(2, "0")}-${d}` : null;
}

export function lerNubankFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "nubank-fatura-pdf", banco: "260", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  const todo = linhas.map((l) => l.texto).join("\n");
  const venc = /Data de vencimento: (\d{2}) ([A-Z]{3}) (\d{4})/.exec(todo);
  if (!venc || !dataCompleta(venc[1], venc[2], venc[3])) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  f.vencimento = dataCompleta(venc[1], venc[2], venc[3])!;
  const per = /Período vigente: (\d{2}) ([A-Z]{3}) a (\d{2}) ([A-Z]{3})/.exec(todo);
  if (per) f.fechamento = dataSemAno(Number(per[3]), MESES[per[4]], f.vencimento);
  const total = linhas.find((l) => /^Total a pagar R\$ ?[\d.]+,\d{2}$/.test(l.texto));
  if (total) f.total_a_pagar_centavos = valorBr(total.celulas[total.celulas.length - 1].texto);

  let emTransacoes = false;
  let emPagamentos = false;
  let subtotais = 0;
  let achouSubtotal = false;
  let comprasEmMoeda = 0; // linhas "Conversão: …" (compra em moeda estrangeira)
  let financiamentos = 0; // Pix no Crédito, na seção de pagamentos
  const finais = new Set<string>();
  let n = 0;
  for (let iL = 0; iL < linhas.length; iL++) {
    const l = linhas[iL];
    const c = l.celulas;
    if (/^TRANSAÇÕES$/.test(c[0]?.texto ?? "")) { emTransacoes = true; continue; }
    if (!emTransacoes) continue;
    if (/^\d+ de \d+$/.test(l.texto) || /^FATURA \d{2} [A-Z]{3} \d{4}/.test(c[0]?.texto ?? "") || c.length === 1 && /^[A-ZÀ-Ú ]+$/.test(c[0].texto) && c[0].x > 300) continue;
    const ultima = c[c.length - 1];
    const temValor = c.length >= 2 && VALOR.test(ultima.texto);
    const md = DATA.exec(c[0]?.texto ?? "");
    if (!md) {
      // sem data: subtotal de portador, cabeçalho de pagamentos, ou detalhe (conversão de moeda)
      if (!emPagamentos && /^Conversão:/i.test(l.texto)) { comprasEmMoeda++; continue; }
      if (temValor && /^Pagamentos e Financiamentos$/i.test(c.slice(0, -1).map((x) => x.texto).join(" "))) { emPagamentos = true; continue; }
      // nome + valor = subtotal de portador; se vier depois dos pagamentos,
      // é outro portador e a seção de pagamentos acabou
      if (temValor && c.length === 2) {
        emPagamentos = false;
        subtotais += valorBr(ultima.texto) ?? 0;
        achouSubtotal = true;
      }
      continue;
    }
    n++;
    const data = dataSemAno(Number(md[1]), MESES[md[2]], f.vencimento);
    if (!temValor || !data) { f.erros.push({ linha: n, motivo: `linha não reconhecida: "${l.texto}"` }); continue; }
    const valor = valorBr(ultima.texto);
    if (valor === null) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${ultima.texto}"` }); continue; }
    let meio = c.slice(1, -1);
    let final: string | null = null;
    const cartao = /^•+ ?(\d{4})$/.exec(meio[0]?.texto ?? "");
    if (cartao) { final = cartao[1]; finais.add(final); meio = meio.slice(1); }
    const bruta = meio.map((x) => x.texto).join(" ").replace(/\s+/g, " ").trim();
    if (!bruta) { f.erros.push({ linha: n, motivo: "lançamento sem descrição" }); continue; }
    if (emPagamentos) {
      // Pix no Crédito: linha positiva seguida do detalhe "Total a pagar: R$ … (valor da
      // transação …)". É cobrança, não pagamento: entra na fatura e na conferência (o
      // subtotal dos portadores não a inclui). Saldo restante e estorno de pagamento
      // continuam como pagamentos.
      if (valor > 0 && /^Total a pagar: R\$ ?[\d.]+,\d{2} \(valor da transa/i.test(linhas[iL + 1]?.texto ?? "")) {
        financiamentos += valor;
        f.itens.push({ data, descricao: (/^pix no cr[eé]dito/i.test(bruta) ? bruta : `Pix no Crédito - ${bruta}`).slice(0, 200), valor_centavos: valor, tipo: "compra", final });
      } else {
        f.pagamentos.push({ data, descricao: bruta.slice(0, 200), valor_centavos: valor });
      }
      continue;
    }
    if (valor === 0) continue;
    const r = itemNubank(data, bruta, valor, final);
    if (r.erro) f.erros.push({ linha: n, motivo: r.erro });
    f.itens.push(r.item);
  }
  f.finais = [...finais].sort();
  if (f.itens.some((i) => (i.parcela_atual ?? 0) > 1 && !i.antecipada)) {
    f.avisos.push("O Nubank não mostra na fatura a data original das compras parceladas: nas parcelas a partir da 2ª, a data da compra lançada será a da cobrança nesta fatura. Os valores e as faturas de cada parcela não mudam.");
  }
  f.total_lancamentos_centavos = achouSubtotal ? subtotais + financiamentos : null;
  ajustarArredondamentoCambio(f, comprasEmMoeda);
  conferirTotal(f, "total de transações dos portadores");
  return f;
}

/**
 * Classifica um lançamento da fatura Nubank pela descrição e pelo sinal (o
 * mesmo para o PDF e o CSV): desconto de antecipação, crédito, encargo (IOF,
 * juros…) ou compra, com parcela e antecipação.
 */
export function itemNubank(data: string, bruta: string, valor: number, final: string | null): { item: ItemFatura; erro?: string } {
  const ant = /^Antecipada - (.*)$/i.exec(bruta);
  const desc = /^Desconto Antecipação (.*)$/i.exec(bruta);
  if (desc && valor < 0) {
    return { item: { data, descricao: desc[1].trim().slice(0, 200), valor_centavos: valor, tipo: "credito", desconto_antecipacao: true, final } };
  }
  const p = separarParcela(ant ? ant[1] : bruta, "nubank");
  const sub = subtipoEncargo(p.descricao);
  if (valor < 0) return { item: { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "credito", final } };
  if (sub && p.atual === null) return { item: { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub, final } };
  return {
    item: { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", final,
            parcela_atual: p.atual, parcelas_total: p.total, antecipada: !!ant },
    erro: ant && p.atual === null ? `antecipação sem número de parcela: "${bruta}"` : undefined,
  };
}
