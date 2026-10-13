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
import { MESES, conferirTotal, dataSemAno, separarParcela, subtipoEncargo, valorBr, type FaturaLida, type ItemFatura } from "./fatura-comum.ts";

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
  const finais = new Set<string>();
  let n = 0;
  for (const l of linhas) {
    const c = l.celulas;
    if (/^TRANSAÇÕES$/.test(c[0]?.texto ?? "")) { emTransacoes = true; continue; }
    if (!emTransacoes) continue;
    if (/^\d+ de \d+$/.test(l.texto) || /^FATURA \d{2} [A-Z]{3} \d{4}/.test(c[0]?.texto ?? "") || c.length === 1 && /^[A-ZÀ-Ú ]+$/.test(c[0].texto) && c[0].x > 300) continue;
    const ultima = c[c.length - 1];
    const temValor = c.length >= 2 && VALOR.test(ultima.texto);
    const md = DATA.exec(c[0]?.texto ?? "");
    if (!md) {
      // sem data: subtotal de portador, cabeçalho de pagamentos, ou detalhe (conversão de moeda)
      if (temValor && /^Pagamentos e Financiamentos$/i.test(c.slice(0, -1).map((x) => x.texto).join(" "))) { emPagamentos = true; continue; }
      if (temValor && c.length === 2 && !emPagamentos) {
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
      f.pagamentos.push({ data, descricao: bruta.slice(0, 200), valor_centavos: valor });
      continue;
    }
    if (valor === 0) continue;
    let item: ItemFatura;
    const ant = /^Antecipada - (.*)$/i.exec(bruta);
    const desc = /^Desconto Antecipação (.*)$/i.exec(bruta);
    if (desc && valor < 0) {
      item = { data, descricao: desc[1].trim().slice(0, 200), valor_centavos: valor, tipo: "credito", desconto_antecipacao: true, final };
    } else {
      const p = separarParcela(ant ? ant[1] : bruta, "nubank");
      const sub = subtipoEncargo(p.descricao);
      if (valor < 0) {
        item = { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "credito", final };
      } else if (sub && p.atual === null) {
        item = { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub, final };
      } else {
        item = { data, descricao: p.descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", final,
                 parcela_atual: p.atual, parcelas_total: p.total, antecipada: !!ant };
        if (ant && p.atual === null) f.erros.push({ linha: n, motivo: `antecipação sem número de parcela: "${bruta}"` });
      }
    }
    f.itens.push(item);
  }
  f.finais = [...finais].sort();
  f.total_lancamentos_centavos = achouSubtotal ? subtotais : null;
  conferirTotal(f, "total de transações dos portadores");
  return f;
}
