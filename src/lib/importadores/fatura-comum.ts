// Tipos e utilidades dos leitores de FATURA de cartão (PDF).
// O leitor só transcreve: cada lançamento da fatura vira um item; os
// pagamentos ficam à parte (só para conferência). A leitura só é aceita
// quando a soma dos itens bate com o total de lançamentos que o próprio
// banco informa na fatura.
import { dataIso, valorParaCentavos } from "./comum.ts";

/** Data AAAA-MM-DD a partir de ano, mês e dia (null se não existir). */
export const dataIsoDe = (a: number, m: number, d: number) => dataIso(a, m, d);

export type TipoItemFatura = "compra" | "encargo" | "credito";

export type ItemFatura = {
  // AAAA-MM-DD, como aparece na fatura. Em parcelas, a maioria dos bancos
  // imprime a data ORIGINAL da compra; o Nubank imprime a data da cobrança
  // neste período (o PDF dele não traz a data original). Ela vira a data da
  // compra criada; em qual fatura cada parcela cai vem do mês da fatura
  // importada, e a comparação com parcelas já lançadas não usa a data.
  data: string;
  descricao: string;             // sem o sufixo de parcela
  valor_centavos: number;        // positivo = débito (compra, encargo); negativo = crédito
  tipo: TipoItemFatura;
  subtipo?: "iof" | "juros" | "multa" | "anuidade" | "tarifa" | "outro" | null;
  parcela_atual?: number | null; // "Parcela 4/12" → 4
  parcelas_total?: number | null; // → 12
  antecipada?: boolean;          // parcela antecipada para esta fatura
  desconto_antecipacao?: boolean; // crédito de desconto por antecipação
  final?: string | null;         // final do cartão (virtual/adicional), quando a fatura mostra
};

export type FaturaLida = {
  leitor: string;
  banco: string;                 // código COMPE
  finais: string[];              // finais de cartão que aparecem na fatura
  vencimento: string;            // AAAA-MM-DD
  fechamento: string | null;     // AAAA-MM-DD
  total_lancamentos_centavos: number | null; // total dos lançamentos do período, segundo o banco
  total_a_pagar_centavos: number | null;     // "total a pagar" da fatura (inclui saldo anterior e pagamentos)
  itens: ItemFatura[];
  pagamentos: { data: string; descricao: string; valor_centavos: number }[];
  erros: { linha: number; motivo: string }[];
  avisos: string[];
};

export const MESES: Record<string, number> = { JAN: 1, FEV: 2, MAR: 3, ABR: 4, MAI: 5, JUN: 6, JUL: 7, AGO: 8, SET: 9, OUT: 10, NOV: 11, DEZ: 12 };

/** Ano de um "dia/mês" sem ano, sabendo o vencimento da fatura: meses depois do vencimento são do ano anterior. */
export function dataSemAno(dia: number, mes: number, vencimento: string): string | null {
  const [a, m] = vencimento.split("-").map(Number);
  return dataIso(mes > m ? a - 1 : a, mes, dia);
}

/** "R$ 1.234,56", "−R$ 1,08", "-R$ 4.705,32", "1.354,14", "-1.791,50", "+ 61,99" → centavos. Só o padrão brasileiro. */
export function valorBr(texto: string): number | null {
  const t = texto.replace(/−/g, "-").replace(/\s+/g, "").replace(/^\+/, "");
  const m = /^(-?)(?:R\$)?(-?)(\d{1,3}(?:\.\d{3})*,\d{2})$/.exec(t);
  if (!m) return null;
  const v = valorParaCentavos(m[3]);
  if (v === null) return null;
  return m[1] || m[2] ? -v : v;
}

/**
 * Data da COMPRA de uma parcela, quando a fatura mostra só dia e mês: a
 * compra é do ano em que a parcela n ainda cai até o vencimento desta
 * fatura (ex.: "08/10 … 12/12" numa fatura de outubro é do ano anterior).
 */
export function dataCompraParcela(dia: number, mes: number, vencimento: string, parcela: number | null): string | null {
  const base = dataSemAno(dia, mes, vencimento);
  if (!base || !parcela || parcela <= 1) return base;
  const [a, m] = base.split("-").map(Number);
  const [va, vm] = vencimento.split("-").map(Number);
  const mesesAteVencimento = (va - a) * 12 + (vm - m);
  return mesesAteVencimento < parcela - 1 ? dataIso(a - 1, mes, dia) : base;
}

/**
 * Duas ou mais parcelas da MESMA compra na mesma fatura — mesma descrição,
 * mesmo número de parcelas, mesmo dia/mês da compra e o mesmo valor (até
 * 2 centavos de arredondamento): a de menor número é a do mês; as outras
 * foram antecipadas para esta fatura. Só serve para faturas que mostram a
 * data ORIGINAL da compra (compras diferentes na mesma loja têm datas ou
 * valores diferentes e ficam separadas).
 */
export function marcarAntecipacoesNaFatura(itens: ItemFatura[]): void {
  const grupos = new Map<string, ItemFatura[]>();
  for (const i of itens) {
    if (i.tipo !== "compra" || !i.parcela_atual || i.antecipada) continue;
    const k = `${i.descricao.toLowerCase().replace(/\s+/g, " ")}|${i.parcelas_total}|${i.data.slice(5)}`;
    grupos.set(k, [...(grupos.get(k) ?? []), i]);
  }
  for (const g of grupos.values()) {
    const nums = new Set(g.map((i) => i.parcela_atual));
    if (g.length < 2 || nums.size !== g.length) continue; // números repetidos = compras diferentes
    const vals = g.map((i) => i.valor_centavos);
    if (Math.max(...vals) - Math.min(...vals) > 2) continue; // valores diferentes = compras diferentes
    const menor = Math.min(...g.map((i) => i.parcela_atual!));
    const base = g.find((i) => i.parcela_atual === menor)!;
    // a data da compra é a da parcela do mês (a das antecipadas não diz o ano)
    for (const i of g) if (i.parcela_atual !== menor) { i.antecipada = true; i.data = base.data; }
  }
}

/** Separa "Descrição - Parcela 4/12" (Nubank) ou "DESCRIÇÃO 04/12" (Itaú). */
export function separarParcela(desc: string, estilo: "nubank" | "itau"): { descricao: string; atual: number | null; total: number | null } {
  const re = estilo === "nubank" ? /^(.*?)\s*-\s*Parcela\s+(\d{1,2})\/(\d{1,2})$/i : /^(.*?)\s+(\d{2})\/(\d{2})$/;
  const m = re.exec(desc.trim());
  if (m) {
    const atual = Number(m[2]), total = Number(m[3]);
    if (atual >= 1 && total >= 2 && atual <= total && total <= 99) return { descricao: m[1].trim(), atual, total };
  }
  return { descricao: desc.trim(), atual: null, total: null };
}

/** Encargo pelo começo da descrição (IOF, juros, multa, anuidade, tarifa). */
export function subtipoEncargo(desc: string): ItemFatura["subtipo"] {
  const d = desc.toLowerCase();
  if (/^iof\b/.test(d)) return "iof";
  if (/^juros\b/.test(d)) return "juros";
  if (/^multa\b/.test(d)) return "multa";
  if (/^anuidade\b/.test(d)) return "anuidade";
  if (/^tarifa\b/.test(d)) return "tarifa";
  return null;
}

/** Confere a soma dos itens com o total do banco; diferença vira erro (a leitura é recusada). */
export function conferirTotal(f: FaturaLida, rotulo: string): void {
  const soma = f.itens.reduce((s, i) => s + i.valor_centavos, 0);
  if (f.total_lancamentos_centavos === null) {
    f.erros.push({ linha: 0, motivo: `não encontrei na fatura o ${rotulo} para conferir a leitura` });
  } else if (soma !== f.total_lancamentos_centavos) {
    const r = (c: number) => (c / 100).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    f.erros.push({ linha: 0, motivo: `a soma dos lançamentos lidos (R$ ${r(soma)}) não bate com o ${rotulo} da fatura (R$ ${r(f.total_lancamentos_centavos)})` });
  } else {
    f.avisos.push(`Conferido: a soma dos ${f.itens.length} lançamentos lidos bate com o ${rotulo} da fatura.`);
  }
  if (f.itens.length === 0) f.erros.push({ linha: 0, motivo: "nenhum lançamento encontrado na fatura" });
}
