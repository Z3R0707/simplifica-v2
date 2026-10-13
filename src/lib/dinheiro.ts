// Valores sempre em CENTAVOS inteiros. Nada de ponto flutuante em cálculo.

/**
 * Lê um valor digitado no padrão brasileiro e devolve centavos, ou null se
 * o texto for inválido. Aceita: "1.234,56", "1234,56", "1234,5", "R$ 10",
 * "1.234" (mil e duzentos e trinta e quatro reais), "12.5" (doze e cinquenta).
 */
export function lerValor(texto: string): number | null {
  let t = (texto ?? "").trim().replace(/^R\$/i, "").replace(/\s/g, "");
  if (!t) return null;
  let negativo = false;
  if (t.startsWith("-") || t.startsWith("−")) {
    negativo = true;
    t = t.slice(1);
  }
  let inteiro = "";
  let fracao = "";
  if (t.includes(",")) {
    const partes = t.split(",");
    if (partes.length !== 2) return null;
    const [esq, dir] = partes;
    if (esq.includes(".") && !/^\d{1,3}(\.\d{3})+$/.test(esq)) return null;
    inteiro = esq.replace(/\./g, "");
    fracao = dir;
  } else if (/^\d+\.\d{1,2}$/.test(t)) {
    [inteiro, fracao] = t.split(".");
  } else {
    if (t.includes(".") && !/^\d{1,3}(\.\d{3})+$/.test(t)) return null;
    inteiro = t.replace(/\./g, "");
  }
  if (inteiro === "") inteiro = "0";
  if (!/^\d+$/.test(inteiro) || !/^\d{0,2}$/.test(fracao)) return null;
  const centavos = Number(inteiro) * 100 + Number((fracao + "00").slice(0, 2));
  if (!Number.isSafeInteger(centavos)) return null;
  return negativo ? -centavos : centavos;
}

/** Formata centavos como "R$ 1.234,56" (negativo: "−R$ 1.234,56"). */
export function formatarCentavos(centavos: number, opcoes: { sinal?: boolean } = {}): string {
  const c = Math.trunc(centavos);
  const abs = Math.abs(c);
  const reais = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const cent = String(abs % 100).padStart(2, "0");
  const base = `R$ ${reais},${cent}`;
  if (c < 0) return `−${base}`;
  if (opcoes.sinal && c > 0) return `+${base}`;
  return base;
}

/** Centavos → texto para preencher um campo de edição ("1234,56"). */
export function centavosParaCampo(centavos: number): string {
  const abs = Math.abs(Math.trunc(centavos));
  const txt = `${Math.floor(abs / 100)},${String(abs % 100).padStart(2, "0")}`;
  return centavos < 0 ? `-${txt}` : txt;
}
