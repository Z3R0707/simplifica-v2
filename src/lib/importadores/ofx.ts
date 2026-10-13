// Leitor OFX genérico (padrão OFX 1.x em SGML e 2.x em XML).
// Não é homologado para nenhum banco específico: cada banco só passa a
// "homologado" depois de testado com arquivo real dele.
import { dataIso, type ExtratoLido, type ItemLido } from "./comum.ts";

const ENTIDADES: Record<string, string> = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'", "&nbsp;": " " };
const limpar = (t: string) => t.replace(/&(amp|lt|gt|quot|apos|nbsp);/g, (e) => ENTIDADES[e]).replace(/\s+/g, " ").trim();

/** Valor de uma tag (SGML sem fechamento ou XML com fechamento). */
function tag(bloco: string, nome: string): string | null {
  const m = new RegExp(`<${nome}>([^<\\r\\n]*)`, "i").exec(bloco);
  return m ? limpar(m[1]) || null : null;
}

/**
 * Valor OFX: só ponto (ou vírgula) decimal, sem separador de milhar.
 * "-80.00", "80", "-80,5", "-80.0000" ok; casas além da 2ª precisam ser zero.
 */
export function valorOfx(t: string | null): number | null {
  const s = (t ?? "").trim().replace(",", ".");
  const m = /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) return null;
  let fracao = m[3] ?? "";
  if (fracao.length > 2) {
    if (!/^0*$/.test(fracao.slice(2))) return null;
    fracao = fracao.slice(0, 2);
  }
  const c = Number(m[2]) * 100 + Number((fracao + "00").slice(0, 2));
  if (!Number.isSafeInteger(c)) return null;
  return m[1] === "-" ? -c : c;
}

/** "20261003120000[-3:BRT]" → "2026-10-03" */
export function dataOfx(t: string | null): string | null {
  if (!t) return null;
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(t.trim());
  return m ? dataIso(Number(m[1]), Number(m[2]), Number(m[3])) : null;
}

export function ehOfx(texto: string): boolean {
  return /OFXHEADER|<OFX>/i.test(texto.slice(0, 2000));
}

export function lerOfx(texto: string): ExtratoLido {
  const res: ExtratoLido = {
    formato: "ofx", leitor: "ofx-generico", tipo: "extrato", banco: null, conta: null,
    saldo_centavos: null, saldo_data: null, inicio: null, fim: null, itens: [], erros: [], avisos: [],
  };
  if (!ehOfx(texto)) {
    res.erros.push({ linha: 0, motivo: "O arquivo não parece ser OFX." });
    return res;
  }
  if (/<CCSTMTRS>/i.test(texto)) {
    res.tipo = "cartao";
    res.avisos.push("Este OFX é de cartão de crédito. A importação de faturas chega na próxima parte da etapa; use a aba Cartões por enquanto.");
  }
  res.banco = tag(texto, "BANKID");
  res.conta = tag(texto, "ACCTID");
  res.inicio = dataOfx(tag(texto, "DTSTART"));
  res.fim = dataOfx(tag(texto, "DTEND"));
  const saldo = /<LEDGERBAL>([\s\S]*?)(<\/LEDGERBAL>|<AVAILBAL>|<\/STMTRS>|$)/i.exec(texto);
  if (saldo) {
    const v = valorOfx(tag(saldo[1], "BALAMT"));
    const d = dataOfx(tag(saldo[1], "DTASOF"));
    if (v !== null && d) { res.saldo_centavos = v; res.saldo_data = d; }
  }

  const blocos = texto.split(/<STMTTRN>/i).slice(1).map((b) => b.split(/<\/STMTTRN>|<\/BANKTRANLIST>/i)[0]);
  let sinalSuspeito = 0;
  blocos.forEach((b, i) => {
    const n = i + 1;
    const data = dataOfx(tag(b, "DTPOSTED"));
    const valor = valorOfx(tag(b, "TRNAMT"));
    const nome = tag(b, "NAME");
    const memo = tag(b, "MEMO");
    const descricao = [nome, memo].filter((x, k, arr) => x && arr.indexOf(x) === k).join(" · ");
    if (!data) return void res.erros.push({ linha: n, motivo: "data (DTPOSTED) ausente ou inválida" });
    if (valor === null) return void res.erros.push({ linha: n, motivo: `valor (TRNAMT) inválido: ${tag(b, "TRNAMT") ?? "vazio"}` });
    if (valor === 0) return void res.erros.push({ linha: n, motivo: "valor zero" });
    if (!descricao) return void res.erros.push({ linha: n, motivo: "sem descrição (NAME/MEMO)" });
    const tipo = (tag(b, "TRNTYPE") ?? "").toUpperCase();
    if (valor > 0 && ["DEBIT", "PAYMENT", "FEE", "SRVCHG", "ATM", "POS", "CHECK"].includes(tipo)) sinalSuspeito++;
    const item: ItemLido = {
      data, valor_centavos: valor, descricao: descricao.slice(0, 200),
      data_operacao: dataOfx(tag(b, "DTUSER")),
      identificador: tag(b, "FITID"),
      documento: tag(b, "CHECKNUM") ?? tag(b, "REFNUM"),
    };
    res.itens.push(item);
  });
  if (blocos.length === 0) res.erros.push({ linha: 0, motivo: "Nenhum lançamento (STMTTRN) encontrado no arquivo." });
  if (sinalSuspeito > 0) {
    res.avisos.push(`${sinalSuspeito} lançamento(s) marcados como débito vieram com valor positivo no arquivo. Confira o sinal na prévia.`);
  }
  const datas = res.itens.map((x) => x.data).sort();
  if (!res.inicio && datas.length) res.inicio = datas[0];
  if (!res.fim && datas.length) res.fim = datas[datas.length - 1];
  return res;
}
