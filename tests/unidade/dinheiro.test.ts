import { test } from "node:test";
import assert from "node:assert/strict";
import { centavosParaCampo, formatarCentavos, lerValor } from "../../src/lib/dinheiro.ts";
import { dataValida, formatarData, hoje, limitesDoMes } from "../../src/lib/datas.ts";

test("lerValor: formatos brasileiros", () => {
  const casos: [string, number | null][] = [
    ["1.234,56", 123456], ["1234,56", 123456], ["1234,5", 123450], ["0,01", 1], [",5", 50],
    ["R$ 10", 1000], ["R$1.000,00", 100000], ["1.234", 123400], ["12.5", 1250], ["12.50", 1250],
    ["1.000.000,00", 100000000], ["  250  ", 25000], ["-1.000,00", -100000], ["−50,00", -5000],
    ["1283,53", 128353], ["1.400,53", 140053], ["166,44", 16644],
  ];
  for (const [texto, esperado] of casos) assert.equal(lerValor(texto), esperado, texto);
});

test("lerValor: entradas inválidas", () => {
  for (const t of ["", "abc", "1,2,3", "12,345", "1.23.4", "1.2345", "12.345,6.7", "R$", "1e5", "--1"]) {
    assert.equal(lerValor(t), null, t);
  }
});

test("lerValor: sem perda por ponto flutuante", () => {
  assert.equal(lerValor("0,29"), 29);
  assert.equal(lerValor("1.005,57"), 100557);
  assert.equal(lerValor("99.999.999.999,99"), 9999999999999);
});

test("formatarCentavos", () => {
  assert.equal(formatarCentavos(0), "R$ 0,00");
  assert.equal(formatarCentavos(5), "R$ 0,05");
  assert.equal(formatarCentavos(123456), "R$ 1.234,56");
  assert.equal(formatarCentavos(1325000), "R$ 13.250,00");
  assert.equal(formatarCentavos(-100000), "−R$ 1.000,00");
  assert.equal(formatarCentavos(2500, { sinal: true }), "+R$ 25,00");
  assert.equal(formatarCentavos(100000000), "R$ 1.000.000,00");
});

test("ida e volta campo ↔ centavos", () => {
  for (const c of [0, 1, 99, 100, 128353, -128353, 9999999999999]) {
    assert.equal(lerValor(centavosParaCampo(c)), c);
  }
});

test("datas", () => {
  assert.equal(formatarData("2026-10-05"), "05/10/2026");
  assert.deepEqual(limitesDoMes("2026-02"), ["2026-02-01", "2026-02-28"]);
  assert.deepEqual(limitesDoMes("2028-02"), ["2028-02-01", "2028-02-29"]);
  assert.deepEqual(limitesDoMes("2026-12"), ["2026-12-01", "2026-12-31"]);
  assert.equal(dataValida("2026-02-30"), false);
  assert.equal(dataValida("2026-10-12"), true);
  // 02:30 UTC de 13/10 ainda é 12/10 em Brasília (UTC−3)
  assert.equal(hoje(new Date("2026-10-13T02:30:00Z")), "2026-10-12");
  assert.equal(hoje(new Date("2026-10-13T03:30:00Z")), "2026-10-13");
});
