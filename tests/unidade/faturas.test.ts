// Leitores de FATURA (Etapa 5 parte 3). Dados SINTÉTICOS no layout das
// faturas reais — nenhum dado real do usuário fica no repositório.
import { test } from "node:test";
import assert from "node:assert/strict";
import type { LinhaPdf } from "../../src/lib/importadores/pdf.ts";
import { dataSemAno, separarParcela, valorBr } from "../../src/lib/importadores/fatura-comum.ts";
import { lerNubankFaturaPdf, reconheceNubankFatura } from "../../src/lib/importadores/nubank-fatura-pdf.ts";
import { lerItauFaturaPdf, reconheceItauFatura } from "../../src/lib/importadores/itau-fatura-pdf.ts";

const cel = (texto: string, x: number) => ({ x, x2: x + texto.length * 5, texto });
let yy = 800;
const L = (pagina: number, ...celulas: ReturnType<typeof cel>[]): LinhaPdf => ({ pagina, y: (yy -= 10), celulas, texto: celulas.map((c) => c.texto).join(" ") });

test("utilidades: valores, parcelas e ano das datas", () => {
  assert.equal(valorBr("R$ 1.234,56"), 123456);
  assert.equal(valorBr("−R$ 1,08"), -108);
  assert.equal(valorBr("-R$ 4.705,32"), -470532);
  assert.equal(valorBr("-1.791,50"), -179150);
  assert.equal(valorBr("12.5"), null);
  assert.deepEqual(separarParcela("Loja Boa - Parcela 4/12", "nubank"), { descricao: "Loja Boa", atual: 4, total: 12 });
  assert.deepEqual(separarParcela("MERCADOLIVRE*M 01/04", "itau"), { descricao: "MERCADOLIVRE*M", atual: 1, total: 4 });
  assert.deepEqual(separarParcela("LOJA 13/05", "itau"), { descricao: "LOJA 13/05", atual: null, total: null }, "parcela maior que o total não é parcela");
  assert.equal(dataSemAno(15, 12, "2027-01-14"), "2026-12-15", "dezembro numa fatura de janeiro é do ano anterior");
  assert.equal(dataSemAno(11, 5, "2026-10-13"), "2026-05-11");
});

// ---------------------------------------------------------------- Nubank
function nubank(transacoes: LinhaPdf[], subtotal: string): LinhaPdf[] {
  yy = 800;
  return [
    L(1, cel("Olá, Fulana.", 138)),
    L(1, cel("Data de vencimento: 14 OUT 2026", 138)),
    L(1, cel("Período vigente: 07 SET a 07 OUT", 138)),
    L(2, cel("Parcelar em 3", 400), cel("Parcelar em 6", 483)),
    L(2, cel("Total a pagar", 318), cel("R$ 6.062,33", 395), cel("R$ 7.011,84", 478)),
    L(4, cel("RESUMO DA FATURA ATUAL", 50)),
    L(4, cel("Total a pagar", 140), cel("R$ 900,00", 455)),
    L(5, cel("FULANA DE TAL", 327)),
    L(5, cel("FATURA 14 OUT 2026", 327), cel("EMISSÃO E ENVIO 07 OUT 2026", 440)),
    L(5, cel("TRANSAÇÕES", 50), cel("DE 07 SET A 07 OUT", 130)),
    L(5, cel("Fulana de Tal", 119), cel(subtotal, 490)),
    ...transacoes,
    L(5, cel("5 de 7", 528)),
  ];
}
const T = (d: string, desc: string, v: string, final: string | null = "1234") =>
  final ? L(5, cel(d, 123), cel(`•••• ${final}`, 172), cel(desc, 214), cel(v, 497)) : L(5, cel(d, 123), cel(desc, 185), cel(v, 497));
const NU = [
  T("07 SET", "Loja Boa - Parcela 4/12", "R$ 100,00"),
  T("09 SET", 'IOF de "Assinatura"', "R$ 3,99", null),
  T("09 SET", "Assinatura", "R$ 114,08"),
  L(5, cel("BRL 110.00 = USD 21.57", 214)),
  T("10 SET", "Farmácia - Parcela 1/3", "R$ 87,17"),
  T("12 SET", "Lavanderia", "R$ 18,95"),
  T("12 SET", "Lavanderia", "R$ 18,95"),
  T("17 SET", "Desconto Antecipação Farmácia", "−R$ 2,18", null),
  T("17 SET", "Antecipada - Farmácia - Parcela 3/3", "R$ 87,16"),
  T("17 SET", "Antecipada - Farmácia - Parcela 2/3", "R$ 87,16"),
  T("20 SET", "Estorno de compra", "−R$ 10,00", null),
  L(6, cel("Pagamentos e Financiamentos", 119), cel("-R$ 500,00", 487)),
  T("08 SET", "Pagamento em 08 SET", "−R$ 500,00", null),
];
// 100,00 + 3,99 + 114,08 + 87,17 + 18,95 + 18,95 − 2,18 + 87,16 + 87,16 − 10,00 = 505,28

test("Nubank: reconhece a fatura (e não outros PDFs)", () => {
  assert.equal(reconheceNubankFatura(nubank(NU, "R$ 505,28")), true);
  assert.equal(reconheceNubankFatura([L(1, cel("extrato conta / lançamentos", 28))]), false);
});

test("Nubank: lê lançamentos, parcelas, antecipação, IOF, créditos e pagamentos", () => {
  const f = lerNubankFaturaPdf(nubank(NU, "R$ 505,28"));
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.fechamento, f.total_lancamentos_centavos, f.total_a_pagar_centavos, f.banco], ["2026-10-14", "2026-10-07", 50528, 90000, "260"]);
  assert.deepEqual(f.finais, ["1234"]);
  assert.equal(f.itens.length, 10);
  assert.deepEqual(f.itens[0], { data: "2026-09-07", descricao: "Loja Boa", valor_centavos: 10000, tipo: "compra", final: "1234", parcela_atual: 4, parcelas_total: 12, antecipada: false });
  assert.deepEqual([f.itens[1].tipo, f.itens[1].subtipo], ["encargo", "iof"]);
  assert.deepEqual(f.itens.filter((i) => i.antecipada).map((i) => `${i.descricao} ${i.parcela_atual}/${i.parcelas_total} ${i.valor_centavos}`), ["Farmácia 3/3 8716", "Farmácia 2/3 8716"]);
  assert.deepEqual(f.itens.filter((i) => i.tipo === "credito").map((i) => [i.descricao, i.valor_centavos, !!i.desconto_antecipacao]), [["Farmácia", -218, true], ["Estorno de compra", -1000, false]]);
  assert.equal(f.itens.filter((i) => i.descricao === "Lavanderia").length, 2, "duas compras iguais no mesmo dia continuam duas");
  assert.deepEqual(f.pagamentos, [{ data: "2026-09-08", descricao: "Pagamento em 08 SET", valor_centavos: -50000 }]);
  assert.ok(f.avisos.some((a) => /Conferido/.test(a)));
});

test("Nubank: soma diferente do subtotal do banco bloqueia (lançamento faltando)", () => {
  const f = lerNubankFaturaPdf(nubank(NU.filter((l) => !l.texto.includes("Assinatura") || l.texto.includes("IOF")), "R$ 505,28"));
  assert.equal(f.erros.length, 1);
  assert.match(f.erros[0].motivo, /não bate/);
});

test("Nubank: linha com data e sem valor reconhecível é erro", () => {
  const f = lerNubankFaturaPdf(nubank([...NU.slice(0, 1), L(5, cel("08 SET", 123), cel("Loja", 214), cel("R$ 1O,00", 497))], "R$ 100,00"));
  assert.ok(f.erros.some((e) => /não reconhecida/.test(e.motivo)));
});

test("Nubank: portador listado depois dos pagamentos continua sendo compra", () => {
  const f = lerNubankFaturaPdf(nubank([
    ...NU,
    L(6, cel("Beltrano de Tal", 119), cel("R$ 150,00", 490)),
    T("11 SET", "Mercado", "R$ 120,00", "5678"),
    T("15 SET", "Padaria", "R$ 30,00", "5678"),
  ], "R$ 505,28"));
  assert.deepEqual(f.erros, []);
  assert.equal(f.total_lancamentos_centavos, 65528, "soma os subtotais dos dois portadores");
  assert.deepEqual(f.finais, ["1234", "5678"]);
  assert.deepEqual(f.itens.filter((i) => i.final === "5678").map((i) => [i.descricao, i.tipo, i.valor_centavos]), [["Mercado", "compra", 12000], ["Padaria", "compra", 3000]]);
  assert.deepEqual(f.pagamentos, [{ data: "2026-09-08", descricao: "Pagamento em 08 SET", valor_centavos: -50000 }]);
});

// ---------------------------------------------------------------- Itaú
function itau(esq: LinhaPdf[], dir: LinhaPdf[] = []): LinhaPdf[] {
  yy = 800;
  const capa = [
    L(1, cel("Resumo da fatura em R$", 451)),
    L(1, cel("Vencimento: 13/10/2026", 233), cel("=", 358), cel("Total desta fatura", 365), cel("455,00", 531)),
    L(1, cel("Emissão: 03/10/2026", 242)),
    L(1, cel("Cartão", 69), cel("1111.XXXX.XXXX.9876", 96)),
  ];
  // página 2: as duas colunas lado a lado, na mesma altura
  yy = 800;
  const n = Math.max(esq.length, dir.length);
  const pag2: LinhaPdf[] = [];
  for (let i = 0; i < n; i++) {
    const c = [...(esq[i]?.celulas ?? []), ...(dir[i]?.celulas ?? [])];
    pag2.push(L(2, ...c));
  }
  return [...capa, ...pag2];
}
const E = (...c: ReturnType<typeof cel>[]) => ({ pagina: 2, y: 0, celulas: c, texto: "" }) as LinhaPdf;
const ESQ = [
  E(cel("Pagamentos efetuados", 133)),
  E(cel("04/09", 133), cel("Pagamento via conta", 161), cel("-1.791,50", 305)),
  E(cel("P", 127), cel("Total dos pagamentos", 133), cel("-1.791,50", 301)),
  E(cel("Lançamentos: compras e saques", 133)),
  E(cel("FULANA DE TAL", 133)),
  E(cel("DATA", 133), cel("ESTABELECIMENTO", 161), cel("VALOR EM R$", 289)),
  E(cel("11/05", 133), cel("LOJA CASA 05/10", 161), cel("200,00", 310)),
  E(cel("04/09", 133), cel("ACADEMIA", 161), cel("18,00", 315)),
  E(cel("lazer CIDADE", 161)),
  E(cel("05/09", 133), cel("MERCADO*M 01/04", 161), cel("75,32", 315)),
  E(cel("05/09", 133), cel("MERCADO*M 01/04", 161), cel("72,00", 315)),
  E(cel("06/09", 133), cel("DEVOLUCAO LOJA", 161), cel("-10,32", 312)),
  E(cel("06/09", 133), cel("IOF COMPRA INTERNACIONAL", 161), cel("100,00", 312)),
  E(cel("Lançamentos no cartão", 133), cel("455,00", 304)),
  E(cel("L", 127), cel("Total dos lançamentos atuais", 133), cel("455,00", 304)),
  E(cel("Compras parceladas - próximas faturas", 133)),
  E(cel("11/05", 133), cel("LOJA CASA 06/10", 161), cel("200,00", 310)),
];
// continuação das "próximas faturas" no alto da coluna da direita: não é lançamento desta fatura
const DIR = [E(cel("05/09", 351), cel("MERCADO*M 02/04", 379), cel("72,00", 533)), E(cel("Próxima fatura", 351), cel("272,00", 526))];

test("Itaú: reconhece a fatura (e não o extrato)", () => {
  assert.equal(reconheceItauFatura(itau(ESQ, DIR)), true);
  assert.equal(reconheceItauFatura([L(1, cel("extrato conta / lançamentos", 28))]), false);
});

test("Itaú: lê a coluna da esquerda e depois a da direita, só a seção de lançamentos", () => {
  const f = lerItauFaturaPdf(itau(ESQ, DIR));
  assert.deepEqual(f.erros, []);
  assert.deepEqual([f.vencimento, f.fechamento, f.total_lancamentos_centavos, f.total_a_pagar_centavos, f.banco], ["2026-10-13", "2026-10-03", 45500, 45500, "341"]);
  assert.deepEqual(f.finais, ["9876"]);
  assert.deepEqual(f.itens.map((i) => [i.data, i.descricao, i.valor_centavos, i.tipo, i.parcela_atual ?? null]), [
    ["2026-05-11", "LOJA CASA", 20000, "compra", 5],
    ["2026-09-04", "ACADEMIA", 1800, "compra", null],
    ["2026-09-05", "MERCADO*M", 7532, "compra", 1],
    ["2026-09-05", "MERCADO*M", 7200, "compra", 1],
    ["2026-09-06", "DEVOLUCAO LOJA", -1032, "credito", null],
    ["2026-09-06", "IOF COMPRA INTERNACIONAL", 10000, "encargo", null],
  ]);
  assert.deepEqual(f.pagamentos, [{ data: "2026-09-04", descricao: "Pagamento via conta", valor_centavos: -179150 }]);
});

test("Itaú: soma diferente do total dos lançamentos atuais bloqueia", () => {
  const f = lerItauFaturaPdf(itau(ESQ.filter((l) => !l.celulas.some((c) => c.texto === "ACADEMIA")), DIR));
  assert.ok(f.erros.some((e) => /não bate/.test(e.motivo)));
});

test("Itaú: sem o total dos lançamentos não há conferência, e a leitura é recusada", () => {
  const f = lerItauFaturaPdf(itau(ESQ.filter((l) => !l.celulas.some((c) => /^Total dos lançamentos/.test(c.texto))), DIR));
  assert.ok(f.erros.some((e) => /não encontrei/.test(e.motivo)));
});

test("Itaú: 'próximas faturas' encerra os lançamentos mesmo quando o total vem depois (na outra coluna)", () => {
  const esq = [
    E(cel("Lançamentos: compras e saques", 133)),
    E(cel("04/09", 133), cel("ACADEMIA", 161), cel("455,00", 315)),
    E(cel("Compras parceladas - próximas faturas", 133)),
    E(cel("11/05", 133), cel("LOJA CASA 06/10", 161), cel("200,00", 310)),
  ];
  const dir = [E(cel("Total dos lançamentos atuais", 351), cel("455,00", 526))];
  const f = lerItauFaturaPdf(itau(esq, dir));
  assert.deepEqual(f.erros, []);
  assert.deepEqual(f.itens.map((i) => i.descricao), ["ACADEMIA"]);
});

test("data da compra de parcela antiga e parcelas da mesma compra na mesma fatura", async () => {
  const { dataCompraParcela, marcarAntecipacoesNaFatura } = await import("../../src/lib/importadores/fatura-comum.ts");
  assert.equal(dataCompraParcela(8, 10, "2026-10-08", 12), "2025-10-08", "12/12 comprada em 08/10 é do ano anterior");
  assert.equal(dataCompraParcela(11, 5, "2026-10-13", 5), "2026-05-11", "5/10 comprada em maio é deste ano");
  assert.equal(dataCompraParcela(9, 3, "2026-10-14", 19), "2025-03-09", "19/21 comprada em março é do ano anterior");
  assert.equal(dataCompraParcela(30, 12, "2026-10-14", 10), "2025-12-30");
  assert.equal(dataCompraParcela(5, 9, "2026-10-14", null), "2026-09-05");
  const it = (d: string, n: number, data = "2026-06-06", t = 6) => ({ data, descricao: d, valor_centavos: 5725, tipo: "compra" as const, parcela_atual: n, parcelas_total: t });
  const itens = [it("LOJA PRESENTES", 4), it("LOJA PRESENTES", 5), it("LOJA PRESENTES", 6, "2025-06-06"), it("OUTRA", 2), it("REPETIDA", 2), it("REPETIDA", 2)];
  marcarAntecipacoesNaFatura(itens);
  assert.deepEqual(itens.map((i) => !!(i as { antecipada?: boolean }).antecipada), [false, true, true, false, false, false]);
  assert.equal(itens[2].data, "2026-06-06", "antecipada recebe a data da compra da parcela do mês");
  // mesma loja, compras diferentes (outra data ou outro valor): não é antecipação
  const loja = [
    { data: "2026-09-05", descricao: "LOJA SHOPPING", valor_centavos: 9332, tipo: "compra" as const, parcela_atual: 2, parcelas_total: 3 },
    { data: "2026-09-18", descricao: "LOJA SHOPPING", valor_centavos: 8998, tipo: "compra" as const, parcela_atual: 1, parcelas_total: 3 },
    { data: "2026-06-06", descricao: "OUTRA LOJA", valor_centavos: 5000, tipo: "compra" as const, parcela_atual: 1, parcelas_total: 3 },
    { data: "2026-06-06", descricao: "OUTRA LOJA", valor_centavos: 7000, tipo: "compra" as const, parcela_atual: 2, parcelas_total: 3 },
    { data: "2026-08-05", descricao: "MESMO VALOR", valor_centavos: 5000, tipo: "compra" as const, parcela_atual: 2, parcelas_total: 3 },
    { data: "2026-08-18", descricao: "MESMO VALOR", valor_centavos: 5000, tipo: "compra" as const, parcela_atual: 1, parcelas_total: 3 },
  ];
  marcarAntecipacoesNaFatura(loja);
  assert.deepEqual(loja.map((i) => !!(i as { antecipada?: boolean }).antecipada), [false, false, false, false, false, false]);
  assert.equal(loja[0].data, "2026-09-05", "data não muda");
});
