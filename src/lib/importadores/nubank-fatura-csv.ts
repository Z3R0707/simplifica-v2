// Leitor da FATURA do cartão Nubank em CSV (app/site → fatura → exportar).
// Feito e conferido com arquivos reais.
//
// Layout: cabeçalho "date,title,amount"; data AAAA-MM-DD; valor em reais entre
// aspas ("4.405,32", "- 300,00" para créditos e pagamentos). O arquivo se chama
// Nubank_AAAA-MM-DD.csv, com a data de vencimento da fatura.
//
// Diferenças em relação ao PDF:
//  * NÃO traz o total da fatura: não há conferência automática da soma. A tela
//    mostra a soma e pede para a pessoa confirmar que confere com o app.
//  * não traz vencimento nem fechamento: o vencimento vem do nome do arquivo
//    (ou é informado na tela); o fechamento fica em branco.
//  * "Pagamento recebido" vem junto com as compras: vai para a lista de
//    pagamentos, como no PDF. "Pix no Crédito" é compra.
//  * o IOF de compra em moeda estrangeira pode vir 1 centavo diferente do PDF
//    (o banco arredonda diferente em cada arquivo).
import { valorParaCentavos } from "./comum.ts";
import { lerCsvBruto } from "./csv.ts";
import { valorBr, type FaturaLida, type ItemFatura } from "./fatura-comum.ts";
import { itemNubank } from "./nubank-fatura-pdf.ts";

export function reconheceNubankFaturaCsv(texto: string): boolean {
  const primeira = texto.replace(/^﻿/, "").split(/\r?\n/).find((l) => l.trim()) ?? "";
  return /^\s*date\s*,\s*title\s*,\s*amount\s*$/i.test(primeira);
}

/** Vencimento a partir do nome do arquivo (Nubank_2026-11-14.csv → 2026-11-14). */
export function vencimentoDoNome(nome: string): string | null {
  const m = /(\d{4})-(\d{2})-(\d{2})/.exec(nome);
  if (!m) return null;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]) ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

// "133,49", "- 4.405,32" (formato atual) ou "133.49" / "-4405.32" (formato antigo)
function valorCsv(t: string): number | null {
  const br = valorBr(t);
  if (br !== null) return br;
  const s = t.replace(/\s+/g, "");
  if (!/^-?\d+(\.\d{1,2})?$/.test(s)) return null;
  const v = valorParaCentavos(s.replace("-", "").replace(".", ","));
  return v === null ? null : s.startsWith("-") ? -v : v;
}

/**
 * O PDF escreve "Antecipada - Loja - Parcela 3/3"; o CSV só "Loja - Parcela 3/3".
 * Sem a marca, a parcela antecipada viraria compra nova e as parcelas que ela
 * antecipou continuariam previstas nas faturas seguintes (cobradas duas vezes).
 * A antecipação é reconhecida por dois sinais do próprio arquivo:
 *  1. "Desconto Antecipação Loja" no mesmo dia da parcela (o Nubank dá o
 *     desconto ao antecipar);
 *  2. a mesma compra com mais de uma parcela nesta fatura: a de menor número é
 *     a do mês; as outras foram antecipadas.
 */
function marcarAntecipadas(itens: ItemFatura[]): void {
  const chave = (i: ItemFatura) => `${i.descricao.toLowerCase()}|${i.parcelas_total}`;
  const parceladas = itens.filter((i) => i.tipo === "compra" && i.parcela_atual && i.parcelas_total && !i.antecipada);
  const descontos = new Set(itens.filter((i) => i.desconto_antecipacao).map((i) => `${i.descricao.toLowerCase()}|${i.data}`));
  const menor = new Map<string, number>();
  for (const i of parceladas) menor.set(chave(i), Math.min(menor.get(chave(i)) ?? Infinity, i.parcela_atual!));
  for (const i of parceladas) {
    const comDesconto = i.parcela_atual! > 1 && descontos.has(`${i.descricao.toLowerCase()}|${i.data}`);
    const naoEhAMenor = i.parcela_atual! > menor.get(chave(i))!;
    if (comDesconto || naoEhAMenor) i.antecipada = true;
  }
}

export function lerNubankFaturaCsv(texto: string, vencimento: string | null): FaturaLida {
  const f: FaturaLida = {
    leitor: "nubank-fatura-csv", banco: "260", finais: [], vencimento: vencimento ?? "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  if (!vencimento) {
    f.erros.push({ linha: 0, motivo: "informe a data de vencimento da fatura (o CSV não traz)" });
    return f;
  }
  const { linhas } = lerCsvBruto(texto.replace(/^﻿/, ""));
  const corpo = linhas.slice(1);
  corpo.forEach((cols, i) => {
    const n = i + 2; // linha do arquivo (a 1ª é o cabeçalho)
    const [data, descricao, valorTexto] = cols;
    if (cols.length < 3 || !/^\d{4}-\d{2}-\d{2}$/.test(data ?? "")) { f.erros.push({ linha: n, motivo: `linha não reconhecida: "${cols.join(",")}"` }); return; }
    const valor = valorCsv(valorTexto ?? "");
    if (valor === null) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${valorTexto}"` }); return; }
    const bruta = (descricao ?? "").replace(/\s+/g, " ").trim();
    if (!bruta) { f.erros.push({ linha: n, motivo: "lançamento sem descrição" }); return; }
    if (data > vencimento) { f.erros.push({ linha: n, motivo: `lançamento de ${data} depois do vencimento (${vencimento}): confira o vencimento` }); return; }
    if (/^pagamento recebido$/i.test(bruta)) {
      f.pagamentos.push({ data, descricao: bruta, valor_centavos: valor });
      return;
    }
    if (valor === 0) return;
    const r = itemNubank(data, bruta, valor, null);
    if (r.erro) f.erros.push({ linha: n, motivo: r.erro });
    f.itens.push(r.item);
  });
  marcarAntecipadas(f.itens);
  if (corpo.length === 0 || f.itens.length === 0) f.erros.push({ linha: 0, motivo: "nenhum lançamento encontrado no CSV" });
  // sem total do banco no arquivo: a soma lida vira o total, e a tela pede a confirmação
  f.total_lancamentos_centavos = f.itens.reduce((s, i) => s + i.valor_centavos, 0);
  if (f.itens.some((i) => (i.parcela_atual ?? 0) > 1 && !i.antecipada)) {
    f.avisos.push("O Nubank não mostra a data original das compras parceladas: nas parcelas a partir da 2ª, a data da compra lançada será a da cobrança nesta fatura. Os valores e as faturas de cada parcela não mudam.");
  }
  return f;
}
