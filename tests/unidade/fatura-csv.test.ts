// Fatura Nubank em CSV. Dados SINTÉTICOS no layout do arquivo real
// (date,title,amount; valor pt-BR entre aspas) — nenhum dado real do usuário.
import { test } from "node:test";
import assert from "node:assert/strict";
import { lerNubankFaturaCsv, reconheceNubankFaturaCsv, vencimentoDoNome } from "../../src/lib/importadores/nubank-fatura-csv.ts";

const CSV = [
  "date,title,amount",
  '2026-10-07,Loja Boa - Parcela 4/12,"393,26"',
  '2026-10-09,Pagamento recebido,"- 4.928,97"',
  '2026-10-10,"IOF de ""Assinatura""","3,98"',
  '2026-10-10,Assinatura,"113,95"',
  '2026-10-12,Mercado,"1.204,50"',
  '2026-10-17,Antecipada - Farmácia - Parcela 3/3,"87,16"',
  '2026-10-17,Desconto Antecipação Farmácia,"- 2,18"',
  '2026-10-17,Pix no Crédito - Fulano de Tal,"31,26"',
  '2026-10-20,Estorno de compra,"- 10,00"',
  '2026-10-26,Pagamento recebido,"- 110,00"',
  "",
].join("\n");

test("Fatura CSV Nubank: reconhece o cabeçalho, e não o extrato da conta", () => {
  assert.equal(reconheceNubankFaturaCsv(CSV), true);
  assert.equal(reconheceNubankFaturaCsv("﻿date,title,amount\n"), true);
  assert.equal(reconheceNubankFaturaCsv("Data,Valor,Identificador,Descrição\n01/10/2026,-10.00,abc,Pix"), false);
});

test("Fatura CSV Nubank: vencimento pelo nome do arquivo", () => {
  assert.equal(vencimentoDoNome("Nubank_2026-11-14.csv"), "2026-11-14");
  assert.equal(vencimentoDoNome("Nubank_2026-02-30.csv"), null, "data que não existe");
  assert.equal(vencimentoDoNome("fatura.csv"), null);
});

test("Fatura CSV Nubank: classifica como o PDF e separa os pagamentos", () => {
  const f = lerNubankFaturaCsv(CSV, "2026-11-14");
  assert.deepEqual(f.erros, []);
  assert.equal(f.leitor, "nubank-fatura-csv");
  assert.equal(f.itens.length, 8, "os 2 pagamentos não viram itens");
  assert.deepEqual(f.pagamentos, [
    { data: "2026-10-09", descricao: "Pagamento recebido", valor_centavos: -492897 },
    { data: "2026-10-26", descricao: "Pagamento recebido", valor_centavos: -11000 },
  ]);
  const por = (d: string) => f.itens.find((i) => i.descricao === d)!;
  assert.deepEqual([por("Loja Boa").parcela_atual, por("Loja Boa").parcelas_total, por("Loja Boa").valor_centavos], [4, 12, 39326]);
  assert.deepEqual([por('IOF de "Assinatura"').tipo, por('IOF de "Assinatura"').subtipo], ["encargo", "iof"], "aspas dentro do campo");
  assert.equal(por("Mercado").valor_centavos, 120450, "milhar com ponto");
  assert.deepEqual([por("Farmácia").antecipada, por("Farmácia").parcela_atual], [true, 3]);
  assert.ok(f.itens.some((i) => i.tipo === "credito" && i.desconto_antecipacao && i.valor_centavos === -218));
  assert.deepEqual([por("Pix no Crédito - Fulano de Tal").tipo, por("Pix no Crédito - Fulano de Tal").valor_centavos], ["compra", 3126]);
  assert.deepEqual([por("Estorno de compra").tipo, por("Estorno de compra").valor_centavos], ["credito", -1000]);
  // sem total do banco no arquivo: o total é a soma lida (a tela pede a conferência)
  assert.equal(f.total_lancamentos_centavos, 39326 + 398 + 11395 + 120450 + 8716 - 218 + 3126 - 1000);
});

test("Fatura CSV Nubank: sem vencimento, valor ou data inválidos, ou lançamento depois do vencimento são erro", () => {
  assert.ok(lerNubankFaturaCsv(CSV, null).erros.some((e) => /vencimento/.test(e.motivo)));
  const ruim = lerNubankFaturaCsv('date,title,amount\n2026-10-07,Loja,"12,5x"\n07/10/2026,Loja,"1,00"\n2026-12-01,Depois,"1,00"', "2026-11-14");
  assert.ok(ruim.erros.some((e) => /valor não reconhecido/.test(e.motivo)));
  assert.ok(ruim.erros.some((e) => /linha não reconhecida/.test(e.motivo)));
  assert.ok(ruim.erros.some((e) => /depois do vencimento/.test(e.motivo)));
  assert.ok(lerNubankFaturaCsv("date,title,amount\n", "2026-11-14").erros.some((e) => /nenhum lançamento/.test(e.motivo)));
});

test("Fatura CSV Nubank: aceita também o formato antigo de valor (ponto decimal, sem aspas)", () => {
  const f = lerNubankFaturaCsv("date,title,amount\n2026-10-07,Loja,133.49\n2026-10-08,Crédito,-2.18", "2026-11-14");
  assert.deepEqual(f.erros, []);
  assert.deepEqual(f.itens.map((i) => i.valor_centavos), [13349, -218]);
});

test("Fatura CSV Nubank: reconhece parcelas antecipadas (o CSV não escreve \"Antecipada\")", () => {
  const f = lerNubankFaturaCsv([
    "date,title,amount",
    '2026-09-10,Farmácia - Parcela 1/3,"87,17"',
    '2026-09-17,Farmácia - Parcela 3/3,"87,16"',
    '2026-09-17,Farmácia - Parcela 2/3,"87,16"',
    '2026-09-17,Desconto Antecipação Farmácia,"- 2,18"',
    '2026-09-11,Loja - Parcela 1/2,"129,95"',
    '2026-09-17,Loja - Parcela 2/2,"129,95"',
    '2026-09-17,Ótica - Parcela 5/6,"50,00"',
    '2026-09-17,Desconto Antecipação Ótica,"- 1,00"',
    '2026-09-07,Curso - Parcela 4/12,"393,26"',
  ].join("\n"), "2026-10-14");
  assert.deepEqual(f.erros, []);
  const marca = (d: string, n: number) => f.itens.find((i) => i.descricao === d && i.parcela_atual === n)!.antecipada;
  assert.deepEqual([marca("Farmácia", 1), marca("Farmácia", 2), marca("Farmácia", 3)], [false, true, true], "a menor é a do mês; as outras foram antecipadas");
  assert.deepEqual([marca("Loja", 1), marca("Loja", 2)], [false, true], "sem desconto, pela parcela repetida");
  assert.equal(marca("Ótica", 5), true, "parcela de compra antiga antecipada com desconto no mesmo dia");
  assert.equal(marca("Curso", 4), false, "parcela normal do mês");
});
