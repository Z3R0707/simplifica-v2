// Leitores de fatura: Santander, Mercado Pago, Sicredi, Sicoob e Riachuelo.
// Dados SINTÉTICOS no layout das faturas reais (nenhum dado real aqui).
import { test } from "node:test";
import assert from "node:assert/strict";
import type { LinhaPdf } from "../../src/lib/importadores/pdf.ts";
import { LEITORES_FATURA } from "../../src/lib/importadores/faturas.ts";
import { lerSantanderFaturaPdf, reconheceSantanderFatura } from "../../src/lib/importadores/santander-fatura-pdf.ts";
import { lerMercadoPagoFaturaPdf, reconheceMercadoPagoFatura } from "../../src/lib/importadores/mercadopago-fatura-pdf.ts";
import { lerSicrediFaturaPdf, reconheceSicrediFatura } from "../../src/lib/importadores/sicredi-fatura-pdf.ts";
import { lerSicoobFaturaPdf, reconheceSicoobFatura } from "../../src/lib/importadores/sicoob-fatura-pdf.ts";
import { lerRiachueloFaturaPdf, reconheceRiachueloFatura } from "../../src/lib/importadores/riachuelo-fatura-pdf.ts";

type C = { x: number; x2: number; texto: string };
const c = (texto: string, x: number): C => ({ x, x2: x + texto.length * 4, texto });
let pg = 1, yy = 800;
const pagina = (n: number) => { pg = n; yy = 800; };
const L = (...cs: C[]): LinhaPdf => ({ pagina: pg, y: (yy -= 10), celulas: cs, texto: cs.map((x) => x.texto).join(" ") });
const at = (y: number, ...cs: C[]): LinhaPdf => ({ pagina: pg, y, celulas: cs, texto: cs.map((x) => x.texto).join(" ") });
const descs = (f: { itens: { descricao: string; valor_centavos: number; parcela_atual?: number | null; antecipada?: boolean }[] }) =>
  f.itens.map((i) => `${i.descricao}|${i.valor_centavos}|${i.parcela_atual ?? ""}${i.antecipada ? "a" : ""}`);

// ---------------------------------------------------------------- Santander
function santander(desp = "205,96"): LinhaPdf[] {
  pagina(2);
  const a = [
    L(c("Olá, Fulana! Esta é a fatura do seu cartão SANTANDER", 19)),
    L(c("Total a Pagar", 313), c("Vencimento", 412), c("Seu limite é", 511)),
    L(c("01/10.", 19)),
    L(c("R$ 117,00", 308), c("08/10/2026", 401), c("R$5.000,00", 500)),
    L(c("OUT.", 289), c("R$ 117,00", 331), c("01/09/26 a 01/10/26", 503)),
  ];
  pagina(3);
  const b = [
    L(c("Detalhamento da Fatura", 14)),
    L(c("FULANA - 1234 XXXX XXXX 1111", 9)),
    L(c("Pagamento e Demais Créditos", 10), c("Resumo da Fatura", 303)),
    L(c("Compra", 10), c("Data", 35), c("Descrição", 52), c("Parcela", 166), c("R$", 219), c("US$", 242)),
    L(c("08/09 PAGAMENTO DE FATURA-INTERNET", 33), c("-500,00", 201), c("Saldo Anterior", 326), c("500,00", 495)),
    L(c("(+) Total Despesas/Débitos no Brasil", 326), c(desp, 496)),
    L(c("(+) Total Despesas/Débitos no Exterior", 326), c("0,00", 507)),
    L(c("Despesas", 10), c("(-) Total de pagamentos", 326), c("500,00", 496)),
    L(c("(-) Total de créditos", 326), c("0,02", 507)),
    L(c("01/10 ANUIDADE DIFERENCIADA", 33), c("04/12", 168), c("27,50", 211)),
    L(c("VALOR TOTAL", 34), c("27,50", 211), c("0,00", 241)),
    L(c("@ FULANA - 4411 XXXX XXXX 2222", 9)),
    L(c("Pagamento e Demais Créditos", 10)),
    L(c("17/08 PG *QUADROS", 33), c("-0,02", 212)),
    L(c("Parcelamentos", 10)),
    L(c("2", 16), c("06/06 LOJA PRESENTES", 33), c("04/06", 168), c("57,25", 211)),
    L(c("3", 17), c("06/06 LOJA PRESENTES", 33), c("05/06", 168), c("57,25", 209)),
    L(c("2", 16), c("08/10 LOJA ANTIGA", 33), c("12/12", 168), c("14,96", 211)),
    L(c("Despesas", 10)),
    L(c("15/09 ASSINATURA", 33), c("49,00", 209)),
  ];
  return [...a, ...b];
}
test("Santander: cartões, seções, parcelas antigas, antecipação e conferência pelo resumo", () => {
  const l = santander();
  assert.equal(reconheceSantanderFatura(l), true);
  const f = lerSantanderFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.fechamento, f.total_lancamentos_centavos, f.total_a_pagar_centavos], ["2026-10-08", "2026-10-01", 20594, 11700]);
  assert.deepEqual(f.finais, ["1111", "2222"]);
  assert.deepEqual(descs(f), ["ANUIDADE DIFERENCIADA|2750|4", "PG *QUADROS|-2|", "LOJA PRESENTES|5725|4", "LOJA PRESENTES|5725|5a", "LOJA ANTIGA|1496|12", "ASSINATURA|4900|"]);
  assert.equal(f.itens.find((i) => i.descricao === "LOJA ANTIGA")!.data, "2025-10-08", "12/12 de outubro é do ano anterior");
  assert.equal(f.itens[0].data, "2026-10-01", "anuidade fica com a data da cobrança");
  assert.equal(f.itens[3].data, "2026-06-06");
  assert.deepEqual(f.pagamentos.map((p) => p.valor_centavos), [-50000]);
  assert.match(lerSantanderFaturaPdf(santander("215,96")).erros[0].motivo, /não bate/);
});

// ---------------------------------------------------------------- Mercado Pago
function mercadoPago(consumos = "R$ 150,00"): LinhaPdf[] {
  pagina(1);
  const a = [
    L(c("Resumo da fatura", 32)),
    L(c("Consumos de 10/09 a 09/10", 44), c(consumos, 217), c("Juros do mês anterior", 323), c("R$ 10,00", 512)),
    L(c("Tarifas e encargos", 44), c("R$ 2,00", 237), c("Pagamentos e créditos devolvidos", 323), c("R$ 300,00", 499)),
    L(c("Multas por atraso", 44), c("R$ 3,00", 235)),
    L(c("Total", 335), c("R$ 165,00", 481)),
    L(c("Pague sua fatura pelo app Mercado Pago", 238)),
  ];
  pagina(2);
  const b = [
    L(c("Vencimento: 14/10/2026", 435)),
    L(c("Detalhes de consumo", 32)),
    L(c("Movimentações na fatura", 40)),
    L(c("Data", 40), c("Movimentações", 94), c("Valor em R$", 498)),
    L(c("17/09", 40), c("Pagamento da fatura de setembro/2026", 94), c("R$ 300,00", 500)),
    L(c("10/10", 40), c("Juros do rotativo", 94), c("R$ 10,00", 514)),
    L(c("10/10", 40), c("IOF do rotativo", 94), c("R$ 2,00", 517)),
    L(c("10/10", 40), c("Multa por atraso", 94), c("R$ 3,00", 515)),
    L(c("Cartão Visa [************1234]", 40)),
    L(c("19/09", 40), c("LOJA BRINQUEDOS", 94), c("Parcela 1 de 4", 399), c("R$ 50,00", 513)),
    L(c("09/03", 40), c("BICICLETA", 94), c("Parcela 19 de 21", 390), c("R$ 60,00", 508)),
    L(c("Total", 40), c("R$ 110,00", 502)),
    L(c("Cartão Visa [************5678]", 40)),
    L(c("19/09", 40), c("Compra internacional em LOJA", 94), c("R$ 40,00", 515)),
    L(c("USD 1 = R$ 5.16", 94), c("USD 7.75", 507)),
    L(c("Total", 40), c("R$ 40,00", 509)),
  ];
  pagina(6);
  return [...a, ...b, L(c("Fechamento da fatura", 40), c("09/10/2026", 227))];
}
test("Mercado Pago: encargos do rotativo, pagamento sem sinal, cartões e conferência pelo resumo", () => {
  const l = mercadoPago();
  assert.equal(reconheceMercadoPagoFatura(l), true);
  const f = lerMercadoPagoFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.fechamento, f.total_lancamentos_centavos, f.total_a_pagar_centavos], ["2026-10-14", "2026-10-09", 16500, 16500]);
  assert.deepEqual(f.finais, ["1234", "5678"]);
  assert.deepEqual(descs(f), ["Juros do rotativo|1000|", "IOF do rotativo|200|", "Multa por atraso|300|", "LOJA BRINQUEDOS|5000|1", "BICICLETA|6000|19", "Compra internacional em LOJA|4000|"]);
  assert.deepEqual(f.itens.slice(0, 3).map((i) => i.subtipo), ["juros", "iof", "multa"]);
  assert.equal(f.itens[4].data, "2025-03-09", "19/21 de março é do ano anterior");
  assert.deepEqual(f.pagamentos.map((p) => p.valor_centavos), [-30000], "pagamento sem sinal na fatura vira pagamento (negativo)");
  assert.match(lerMercadoPagoFaturaPdf(mercadoPago("R$ 151,00")).erros[0].motivo, /não bate/);
});

// ---------------------------------------------------------------- Sicredi
function sicredi(brasil = "250,00"): LinhaPdf[] {
  pagina(1);
  const a = [
    L(c("Total fatura de outubro", 170), c("R$ 250,00", 258)),
    L(c("Resumo da fatura", 36)),
    L(c("Pagamentos | Créditos", 37), c("-110,00", 234), c("0,00", 303)),
    L(c("Despesas atuais | Débitos no Brasil", 37), c(brasil, 234)),
    L(c("Despesas atuais | Débitos no Exterior", 37), c("0,00", 246), c("0,00", 303)),
    L(c("Total desta Fatura", 37), c("240,00", 233)),
    L(c("Mastercard Internacional sicredi", 170)),
  ];
  pagina(2);
  const b = [
    L(c("Vencimento", 476), c("10/10/2026", 520)),
    L(c("Transações", 42)),
    L(c("Cartão Fulana (final 1111)", 32)),
    L(c("Data e hora", 47), c("Cidade", 113), c("Compra", 171), c("Descrição", 238), c("Parcela", 348), c("Valor em reais", 503)),
    L(c("14/set 22:36", 44), c("Cidade", 100), c("Online", 173), c("Lanchonete", 237), c("R$ 90,00", 516)),
    L(c("08/set 02:54", 43), c("Pagamento 123", 237), c("-R$ 100,00", 513)),
    L(c("26/ago 21:12", 44), c("Cidade", 107), c("Presencial", 167), c("Loja Esportes", 237), c("01/04", 353), c("R$ 111,00", 516)),
    L(c("27/ago 10:00", 44), c("Loja Devolução", 237), c("-R$ 10,00", 516)),
    L(c("Total cartão (final 1111)", 414), c("R$ 191,00", 509)),
    L(c("Cartão virtual Fulana (final 2222)", 32)),
    at(309, c("Assinatura Longa Nome San", 237)),
    at(305, c("24/set 21:18", 45), c("Online", 173), c("BRL 49,00 = US$ 0,00", 387), c("R$ 0,00", 467), c("R$ 49,00", 516)),
    at(300, c("Francisc", 237)),
    at(280, c("Legenda:", 32)),
  ];
  return [...a, ...b];
}
test("Sicredi: data com hora, descrição em duas linhas, pagamento, crédito e conferência", () => {
  const l = sicredi();
  assert.equal(reconheceSicrediFatura(l), true);
  const f = lerSicrediFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.total_lancamentos_centavos, f.total_a_pagar_centavos], ["2026-10-10", 24000, 24000]);
  assert.deepEqual(f.finais, ["1111", "2222"]);
  assert.deepEqual(descs(f), ["Lanchonete|9000|", "Loja Esportes|11100|1", "Loja Devolução|-1000|", "Assinatura Longa Nome San Francisc|4900|"]);
  assert.deepEqual(f.pagamentos.map((p) => p.valor_centavos), [-10000]);
  assert.match(lerSicrediFaturaPdf(sicredi("260,00")).erros[0].motivo, /não bate/);
});

// ---------------------------------------------------------------- Sicoob
function sicoob(total = "R$ 223,00"): LinhaPdf[] {
  pagina(1);
  const a = [L(c("SICOOB UNICENTRO", 233)), L(c("VENCIMENTO", 248), c("11 OUT 2026", 351))];
  pagina(4);
  const b = [
    at(789, c("REF 1 SET A 1 OUT", 60)),
    at(757, c("LANÇAMENTOS - SICOOB MASTERCARD", 21)),
    at(731, c("MOVIMENTAÇÕES DA CONTA", 26)),
    at(710, c("SALDO ANTERIOR", 68), c("R$ 300,00", 238)),
    at(696, c("EST ANUIDADE", 68)),
    at(692, c("01 DEZ", 28), c("-R$ 30,00", 241)),
    at(688, c("MASTERCARD", 68)),
    at(674, c("01 DEZ", 28), c("ANUIDADE MASTERCARD", 68), c("R$ 30,00", 242)),
    at(624, c("PAGAMENTO-BOLETO", 68)),
    at(620, c("08 SET", 28), c("-R$ 300,00", 237)),
    at(616, c("BANCARIO", 68)),
    at(602, c("22 SET", 28), c("PROTEÇÃO", 68), c("R$ 3,00", 244)),
    at(581, c("DATA", 28), c("DESCRIÇÃO", 68), c("CIDADE", 176), c("VALOR EM R$", 231)),
    at(564, c("FULANA", 26), c("1111", 246)),
    at(543, c("13 FEV", 28), c("LojaFevereiro", 68), c("08/10", 127), c("CIDADE", 163), c("R$ 100,00", 240)),
    at(511, c("HOSPEDAGEM ONLINE", 68)),
    at(507, c("20 ABR", 28), c("SAO PAULO", 172), c("R$ 120,00", 240)),
    at(503, c("06/10", 68)),
    at(411, c("TOTAL DE FULANA", 26), c("R$ 220,00", 235)),
    at(391, c("TOTAL", 26), c(total, 235)),
  ];
  return [...a, ...b];
}
test("Sicoob: descrição e parcela em linhas separadas, estornos, pagamento e conferência pelo TOTAL", () => {
  const l = sicoob();
  assert.equal(reconheceSicoobFatura(l), true);
  const f = lerSicoobFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.fechamento, f.total_lancamentos_centavos, f.total_a_pagar_centavos], ["2026-10-11", "2026-10-01", 22300, 22300]);
  assert.deepEqual(f.finais, ["1111"]);
  assert.deepEqual(descs(f), ["EST ANUIDADE MASTERCARD|-3000|", "ANUIDADE MASTERCARD|3000|", "PROTEÇÃO|300|", "LojaFevereiro|10000|8", "HOSPEDAGEM ONLINE|12000|6"]);
  assert.equal(f.itens[0].data, "2025-12-01");
  assert.deepEqual(f.pagamentos.map((p) => [p.descricao, p.valor_centavos]), [["PAGAMENTO-BOLETO BANCARIO", -30000]]);
  assert.match(lerSicoobFaturaPdf(sicoob("R$ 224,00")).erros[0].motivo, /não bate/);
});

// ---------------------------------------------------------------- Riachuelo
function riachuelo(desp = "+ 183,30"): LinhaPdf[] {
  pagina(1);
  return [
    L(c("Saldo à Pagar (R$)", 164), c("Melhor data", 295)),
    L(c("Vencimento", 62)),
    L(c("13/10/2026", 52), c("183,30", 179), c("07/10/2026", 283)),
    L(c("Resumo de movimentações (R$)", 135)),
    L(c("Saldo Anterior", 43), c("100,00", 345)),
    L(c("Pagamentos/Créditos", 43), c("- 100,00", 340)),
    L(c("Encargos", 43), c("+ 0,00", 347)),
    L(c("Despesas/Débitos no Brasil", 43), c(desp, 335)),
    L(c("Despesas/Débitos no Exterior", 43), c("+ 0,00", 345)),
    L(c("Saldo desta Fatura", 43), c("183,30", 342)),
    L(c("Histórico de Despesas", 250)),
    L(c("28/02/26 438", 43), c("LOJA - SHOPPING A [CASA]", 90), c("619,90", 427), c("08/10", 472), c("+ 61,99", 531)),
    L(c("05/09/26 295", 43), c("LOJA - SHOPPING B", 90), c("279,96", 427), c("02/03", 472), c("+ 93,32", 531)),
    L(c("18/09/26 295", 43), c("LOJA - SHOPPING B", 90), c("83,97", 427), c("01/03", 472), c("+ 27,99", 531)),
    L(c("08/09/26 001", 43), c("PAGAMENTO", 90), c("- 100,00", 530)),
    L(c("MIDWAY SA", 44)),
  ];
}
test("Riachuelo: data com ano, valor total da compra, compras diferentes na mesma loja e conferência", () => {
  const l = riachuelo();
  assert.equal(reconheceRiachueloFatura(l), true);
  const f = lerRiachueloFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.total_lancamentos_centavos, f.total_a_pagar_centavos, f.banco], ["2026-10-13", 18330, 18330, ""]);
  assert.deepEqual(descs(f), ["LOJA - SHOPPING A [CASA]|6199|8", "LOJA - SHOPPING B|9332|2", "LOJA - SHOPPING B|2799|1"], "duas compras na mesma loja não viram antecipação");
  assert.deepEqual(f.itens.map((i) => i.data), ["2026-02-28", "2026-09-05", "2026-09-18"]);
  assert.deepEqual(f.pagamentos.map((p) => p.valor_centavos), [-10000]);
  assert.match(lerRiachueloFaturaPdf(riachuelo("+ 190,00")).erros[0].motivo, /não bate/);
});

test("cada leitor reconhece só a própria fatura", () => {
  const amostras: Record<string, LinhaPdf[]> = {
    "santander-fatura-pdf": santander(), "mercadopago-fatura-pdf": mercadoPago(), "sicredi-fatura-pdf": sicredi(),
    "sicoob-fatura-pdf": sicoob(), "riachuelo-fatura-pdf": riachuelo(),
  };
  for (const [id, linhas] of Object.entries(amostras)) {
    assert.deepEqual(LEITORES_FATURA.filter((l) => l.reconhece(linhas)).map((l) => l.id), [id], id);
  }
});

test("Riachuelo: histórico que continua na página seguinte é lido até o quadro de Encargos", () => {
  const p1 = riachuelo("+ 233,30").filter((x) => !x.texto.startsWith("MIDWAY"));
  pagina(2);
  const p2 = [
    L(c("Cartão Riachuelo", 250)),
    L(c("Valor", 266), c("Juros", 311), c("Ult. venc.", 377), c("Nº", 472), c("Lançamento", 503)),
    L(c("Data", 43), c("Loja Descrição", 72), c("IOF", 347), c("Valor", 427)),
    L(c("20/09/26 438", 43), c("LOJA - SHOPPING C", 90), c("100,00", 427), c("01/02", 472), c("+ 50,00", 531)),
    L(c("Encargos", 278)),
    L(c("Descrição", 43), c("Taxa de Juros", 321)),
    L(c("21/09/26 001", 43), c("NÃO É LANÇAMENTO", 90), c("+ 9,99", 531)),
    L(c("Informações Importantes", 243)),
  ];
  const f = lerRiachueloFaturaPdf([...p1, ...p2]);
  assert.deepEqual(f.erros, []);
  assert.equal(f.total_lancamentos_centavos, 23330);
  assert.deepEqual(descs(f).slice(-1), ["LOJA - SHOPPING C|5000|1"]);
  assert.equal(f.itens.length, 4);
});

test("Riachuelo: estorno (crédito que não é pagamento) entra e é descontado na conferência", () => {
  const l = riachuelo().map((x) => x);
  const i = l.findIndex((x) => x.texto.startsWith("Pagamentos/Créditos"));
  l[i] = { ...l[i], celulas: [l[i].celulas[0], { ...l[i].celulas[1], texto: "- 120,00" }], texto: "Pagamentos/Créditos - 120,00" };
  const j = l.findIndex((x) => x.texto.includes("PAGAMENTO"));
  const est = { ...l[j], y: l[j].y - 1, celulas: [{ x: 43, x2: 90, texto: "10/09/26 295" }, { x: 90, x2: 200, texto: "ESTORNO LOJA" }, { x: 528, x2: 553, texto: "- 20,00" }], texto: "10/09/26 295 ESTORNO LOJA - 20,00" };
  l.splice(j + 1, 0, est);
  const f = lerRiachueloFaturaPdf(l);
  assert.deepEqual(f.erros, []);
  assert.equal(f.total_lancamentos_centavos, 16330);
  assert.deepEqual(f.itens.filter((x) => x.tipo === "credito").map((x) => x.valor_centavos), [-2000]);
});
