// Leitores próprios de banco (Etapa 5 parte 2). Dados SINTÉTICOS no
// layout dos arquivos reais — nenhum dado real do usuário fica no repositório.
import { test } from "node:test";
import assert from "node:assert/strict";
import { extrairLinhas, type LinhaPdf, type ModuloPdfjs } from "../../src/lib/importadores/pdf.ts";
import { lerItauExtratoPdf, reconheceItauExtrato } from "../../src/lib/importadores/itau-extrato-pdf.ts";
import { ehNubankCsv, lerNubankCsv } from "../../src/lib/importadores/nubank-csv.ts";

// ---------------------------------------------------------------- PDF → linhas
test("extrairLinhas agrupa itens na mesma altura e ordena da esquerda para a direita", async () => {
  const item = (str: string, x: number, y: number, width = 40) => ({ str, transform: [1, 0, 0, 1, x, y], width });
  const falso: ModuloPdfjs = {
    getDocument: () => ({
      promise: Promise.resolve({
        numPages: 2,
        getPage: async (n: number) => ({
          getTextContent: async () => ({
            items: n === 1
              ? [item("-60,00", 426, 553.4), item("13/10/2026", 31, 553), item("PIX   TRANSF", 96, 552.2), item(" ", 200, 553), item("título", 31, 600)]
              : [item("12/10/2026", 31, 700), item("SALDO DO DIA", 96, 700), item("10,00", 530, 700)],
          }),
        }),
      }),
    }),
  };
  const linhas = await extrairLinhas(falso, new Uint8Array([1, 2, 3]));
  assert.deepEqual(linhas.map((l) => [l.pagina, l.texto]), [
    [1, "título"],
    [1, "13/10/2026 PIX TRANSF -60,00"],
    [2, "12/10/2026 SALDO DO DIA 10,00"],
  ]);
  assert.equal(linhas[1].celulas[2].x, 426);
});

// ---------------------------------------------------------------- Itaú extrato (PDF)
const cel = (texto: string, x: number, larg = 0) => ({ x, x2: x + (larg || texto.length * 5), texto });
const linha = (y: number, ...celulas: ReturnType<typeof cel>[]): LinhaPdf => ({ pagina: 1, y, celulas, texto: celulas.map((c) => c.texto).join(" ") });
const valor = (t: string) => cel(t, 460 - t.length * 5, t.length * 5);   // alinhado à direita em 460 (coluna valor)
const saldo = (t: string) => cel(t, 565 - t.length * 5, t.length * 5);   // alinhado à direita em 565 (coluna saldo)
const lanc = (y: number, d: string, desc: string, v: string) => linha(y, cel(d, 31, 54), cel(desc, 96), valor(v));
const sdia = (y: number, d: string, v: string) => linha(y, cel(d, 31, 54), cel("SALDO DO DIA", 96, 73), saldo(v));
function itau(corpo: LinhaPdf[], emitido = "20/10/2026"): LinhaPdf[] {
  return [
    linha(770, cel("FULANO DE TAL", 232), cel("agência: 0001", 446), cel("conta: 01234-5", 507)),
    linha(723, cel("saldo em conta", 31)),
    linha(645, cel("extrato conta / lançamentos", 28)),
    linha(630, cel("período de visualização: 01/10/2026 até 20/10/2026", 28)),
    linha(628, cel(`emitido em: ${emitido}`, 436), cel("10:00:00", 539)),
    linha(597, cel("data", 31, 22), cel("lançamentos", 96, 64), cel("valor (R$)", 413, 47), cel("saldo (R$)", 516, 49)),
    ...corpo,
  ];
}
// dias do mais recente para o mais antigo, como no banco; SALDO DO DIA no meio do dia também acontece
const CORPO = [
  lanc(570, "15/10/2026", "PIX TRANSF FULANO 15/10", "-1.200,00"),
  sdia(560, "15/10/2026", "2.355,50"),
  lanc(550, "15/10/2026", "PAG BOLETO LUZ", "-44,50"),
  lanc(540, "14/10/2026", "REND PAGO APLIC AUT APR", "0,06"),
  lanc(530, "14/10/2026", "PIX TRANSF EMPRESA 14/10", "3.000,00"),
  lanc(520, "14/10/2026", "PIX TRANSF EMPRESA 14/10", "3.000,00"),
  sdia(510, "14/10/2026", "3.600,00"),
  lanc(500, "14/10/2026", "PAY MERCADO 14/10", "-2.400,06"),
  sdia(490, "10/10/2026", "0,00"),
];

test("Itaú: reconhece o extrato e ignora outros PDFs", () => {
  assert.equal(reconheceItauExtrato(itau(CORPO)), true);
  assert.equal(reconheceItauExtrato([linha(700, cel("Resumo da fatura em R$", 300)), linha(690, cel("Vencimento: 13/10/2026", 300))]), false);
});

test("Itaú: lê os lançamentos e confere cada dia com o SALDO DO DIA", () => {
  const r = lerItauExtratoPdf(itau(CORPO));
  assert.deepEqual(r.erros, []);
  assert.equal(r.estrito, true);
  assert.equal(r.formato, "pdf");
  assert.equal(r.banco, "341");
  assert.equal(r.conta, "01234-5");
  assert.equal(r.itens.length, 6);
  assert.deepEqual(r.itens.filter((i) => i.descricao === "PIX TRANSF EMPRESA 14/10").length, 2, "dois lançamentos iguais continuam dois");
  assert.deepEqual([r.saldo_centavos, r.saldo_data, r.inicio, r.fim], [235550, "2026-10-15", "2026-10-14", "2026-10-15"]);
  assert.ok(r.avisos.some((a) => /Conferido dia a dia/.test(a)));
  assert.ok(!r.itens.some((i) => /SALDO DO DIA/.test(i.descricao)), "SALDO DO DIA não vira lançamento");
});

test("Itaú: dia que não fecha bloqueia a leitura (lançamento faltando ou valor errado)", () => {
  const semUm = CORPO.filter((l) => !l.texto.includes("PAG BOLETO LUZ"));
  const r = lerItauExtratoPdf(itau(semUm));
  assert.equal(r.erros.length, 1);
  assert.match(r.erros[0].motivo, /dia 15\/10\/2026 não fecha.*R\$ 2\.400,00.*R\$ 2\.355,50.*diferença de R\$ -44,50/);
});

test("Itaú: diferença só no dia da emissão (dia ainda aberto no banco) vira aviso, não erro", () => {
  const semUm = CORPO.filter((l) => !l.texto.includes("PAG BOLETO LUZ"));
  const r = lerItauExtratoPdf(itau(semUm, "15/10/2026"));
  assert.deepEqual(r.erros, []);
  assert.ok(r.avisos.some((a) => /15\/10\/2026 não fecha.*emitido nesse mesmo dia/.test(a)));
});

test("Itaú: valor na coluna de saldo para um lançamento é erro; dia sem SALDO DO DIA é erro", () => {
  const torto = [...CORPO.slice(0, 2), linha(555, cel("15/10/2026", 31, 54), cel("ESTRANHO", 96), saldo("-1,00")), ...CORPO.slice(2)];
  assert.ok(lerItauExtratoPdf(itau(torto)).erros.some((e) => /coluna de saldo/.test(e.motivo)));
  const semSaldo = [...CORPO, lanc(480, "11/10/2026", "PAY X", "-1,00")];
  assert.ok(lerItauExtratoPdf(itau(semSaldo)).erros.some((e) => /11\/10\/2026 sem linha de SALDO DO DIA/.test(e.motivo)));
});

test("Itaú: valor fora do padrão é erro de leitura", () => {
  const ruim = [...CORPO.slice(0, 1), lanc(565, "15/10/2026", "PIX X", "12.5"), ...CORPO.slice(1)];
  assert.ok(lerItauExtratoPdf(itau(ruim)).erros.some((e) => /valor não reconhecido/.test(e.motivo)));
});

// ---------------------------------------------------------------- Nubank extrato (CSV)
const NU = [
  "Data,Valor,Identificador,Descrição",
  "02/10/2026,9.00,11111111-1111-4111-8111-111111111111,Transferência recebida pelo Pix - FULANA - •••.000.000-•• - BANCO X",
  "02/10/2026,-196.00,22222222-2222-4222-8222-222222222222,Transferência enviada pelo Pix - EMPRESA - 00.000.000/0001-00",
  "03/10/2026,3542.79,33333333-3333-4333-8333-333333333333,Compra, com vírgula, na descrição",
  "",
].join("\n");

test("Nubank: reconhece o cabeçalho exato (com ou sem BOM)", () => {
  assert.equal(ehNubankCsv(NU), true);
  assert.equal(ehNubankCsv("﻿" + NU.replace(/\n/g, "\r\n")), true);
  assert.equal(ehNubankCsv("Data;Descrição;Valor\n01/10/2026;x;1,00"), false);
});

test("Nubank: lê valores com ponto decimal, identificador e descrição com vírgula", () => {
  const r = lerNubankCsv(NU);
  assert.deepEqual(r.erros, []);
  assert.equal(r.estrito, true);
  assert.equal(r.banco, "260");
  assert.equal(r.leitor, "nubank-csv-extrato");
  assert.deepEqual(r.itens.map((i) => [i.data, i.valor_centavos, i.identificador]), [
    ["2026-10-02", 900, "11111111-1111-4111-8111-111111111111"],
    ["2026-10-02", -19600, "22222222-2222-4222-8222-222222222222"],
    ["2026-10-03", 354279, "33333333-3333-4333-8333-333333333333"],
  ]);
  assert.equal(r.itens[2].descricao, "Compra, com vírgula, na descrição");
  assert.deepEqual([r.inicio, r.fim, r.saldo_centavos], ["2026-10-02", "2026-10-03", null]);
});

test("Nubank: fora do padrão é erro (vírgula decimal, identificador inválido ou repetido, data)", () => {
  const ruim = [
    "Data,Valor,Identificador,Descrição",
    "02/10/2026,9,00,11111111-1111-4111-8111-111111111111,X",
    "02/10/2026,9.00,abc,X",
    "02/10/2026,1.00,11111111-1111-4111-8111-111111111111,A",
    "02/10/2026,2.00,11111111-1111-4111-8111-111111111111,B",
    "31/02/2026,2.00,44444444-4444-4444-8444-444444444444,C",
  ].join("\n");
  const r = lerNubankCsv(ruim);
  assert.equal(r.itens.length, 1);
  assert.deepEqual(r.erros.map((e) => e.linha), [2, 3, 5, 6]);
  assert.match(r.erros[2].motivo, /repetido/);
});
