// Tipos e utilidades comuns aos leitores de extrato (OFX e CSV).
// Os leitores só TRANSCREVEM o arquivo: nada é inventado. O que não puder
// ser lido com segurança vira erro na linha, para o usuário ver.

export type ItemLido = {
  data: string;                 // AAAA-MM-DD (data do lançamento no extrato)
  data_operacao?: string | null;
  descricao: string;
  valor_centavos: number;       // positivo = entrou na conta; negativo = saiu
  identificador?: string | null; // identificador do banco (FITID), quando existe
  documento?: string | null;
};

export type ExtratoLido = {
  formato: "ofx" | "csv";
  leitor: string;
  tipo: "extrato" | "cartao";
  banco: string | null;
  conta: string | null;
  saldo_centavos: number | null;
  saldo_data: string | null;
  inicio: string | null;
  fim: string | null;
  itens: ItemLido[];
  erros: { linha: number; motivo: string }[];
  avisos: string[];
};

/** Texto do arquivo: UTF-8 quando válido; senão Windows-1252 (comum em bancos brasileiros). */
export function decodificar(bytes: Uint8Array): string {
  const inicio = new TextDecoder("latin1").decode(bytes.slice(0, 400));
  if (/CHARSET:\s*(1252|ISO-8859-1|ISO8859-1)/i.test(inicio) || /encoding="(windows-1252|iso-8859-1)"/i.test(inicio)) {
    return new TextDecoder("windows-1252").decode(bytes);
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes).replace(/^﻿/, "");
  } catch {
    return new TextDecoder("windows-1252").decode(bytes);
  }
}

/** SHA-256 do arquivo, em hexadecimal (identidade do arquivo). */
export async function sha256(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Valor monetário de um arquivo para centavos, sem ponto flutuante.
 * Aceita "1234.56", "1234,56", "1.234,56", "1,234.56", "-80", "80,00-",
 * "(80,00)", "R$ 80,00", "+80.00". Devolve null se for ambíguo ou inválido.
 */
export function valorParaCentavos(texto: string): number | null {
  let t = (texto ?? "").trim().replace(/^R\$\s*/i, "").replace(/\s/g, "");
  if (!t) return null;
  let negativo = false;
  if (/^\(.*\)$/.test(t)) { negativo = true; t = t.slice(1, -1); }
  if (t.endsWith("-")) { negativo = !negativo; t = t.slice(0, -1); }
  if (t.startsWith("-") || t.startsWith("−")) { negativo = !negativo; t = t.slice(1); }
  else if (t.startsWith("+")) t = t.slice(1);
  t = t.replace(/^R\$/i, "");
  if (!/^[\d.,]+$/.test(t)) return null;
  const ultimoPonto = t.lastIndexOf(".");
  const ultimaVirgula = t.lastIndexOf(",");
  let inteiro: string;
  let fracao = "";
  if (ultimoPonto >= 0 && ultimaVirgula >= 0) {
    const dec = ultimoPonto > ultimaVirgula ? "." : ",";
    const mil = dec === "." ? "," : ".";
    const [a, b] = t.split(dec);
    if (t.split(dec).length !== 2 || !/^\d{1,3}([.,]\d{3})*$/.test(a) || a.includes(dec)) return null;
    inteiro = a.split(mil).join("");
    fracao = b;
  } else if (ultimoPonto >= 0 || ultimaVirgula >= 0) {
    const sep = ultimoPonto >= 0 ? "." : ",";
    const partes = t.split(sep);
    if (partes.length === 2 && partes[1].length !== 3) {
      [inteiro, fracao] = partes;
    } else if (partes.length >= 2 && partes.slice(1).every((p) => p.length === 3) && /^\d{1,3}$/.test(partes[0])) {
      // "1.234" ou "1,234": separador de milhar
      inteiro = partes.join("");
    } else if (partes.length === 2) {
      [inteiro, fracao] = partes; // "12,345"? 3 casas: tratado abaixo
    } else return null;
  } else {
    inteiro = t;
  }
  if (inteiro === "") inteiro = "0";
  if (!/^\d+$/.test(inteiro) || !/^\d*$/.test(fracao)) return null;
  // casas além da 2ª só são aceitas se forem zeros (ex.: "-80.0000")
  if (fracao.length > 2) {
    if (!/^0*$/.test(fracao.slice(2))) return null;
    fracao = fracao.slice(0, 2);
  }
  const c = Number(inteiro) * 100 + Number((fracao + "00").slice(0, 2));
  if (!Number.isSafeInteger(c)) return null;
  return negativo ? -c : c;
}

/** Data AAAA-MM-DD válida? */
export function dataIso(a: number, m: number, d: number): string | null {
  if (a < 1900 || a > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(a, m - 1, d));
  if (dt.getUTCFullYear() !== a || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return `${a}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}
