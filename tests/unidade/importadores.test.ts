// Leitores de extrato: OFX (padrão) e CSV mapeado. Arquivos de exemplo
// SINTÉTICOS, no formato do padrão OFX — não substituem a homologação com
// arquivo real de cada banco.
import { test } from "node:test";
import assert from "node:assert/strict";
import { decodificar, valorParaCentavos } from "../../src/lib/importadores/comum.ts";
import { lerOfx, valorOfx } from "../../src/lib/importadores/ofx.ts";
import { dataCsv, lerCsvBruto, mapearCsv, sugerirMapa } from "../../src/lib/importadores/csv.ts";

const OFX_SGML = `OFXHEADER:100
DATA:OFXSGML
VERSION:102
ENCODING:USASCII
CHARSET:1252

<OFX>
<BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>BRL
<BANKACCTFROM><BANKID>0341<ACCTID>12345-6<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><DTSTART>20261001000000[-3:BRT]<DTEND>20261010000000[-3:BRT]
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261003120000[-3:BRT]<TRNAMT>-80.00<FITID>A1<MEMO>SUPERMERCADO &amp; CIA</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261005<TRNAMT>5000,5<FITID>A2<NAME>SALARIO<MEMO>SALARIO</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261006<TRNAMT>-12.3400<FITID>A3<NAME>TARIFA<MEMO>PACOTE</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261006<TRNAMT>15.00<FITID>A4<MEMO>DEBITO POSITIVO</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261399<TRNAMT>-1.00<FITID>A5<MEMO>DATA RUIM</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261007<TRNAMT>-1.234<FITID>A6<MEMO>VALOR RUIM</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>1234.56<DTASOF>20261010</LEDGERBAL>
</STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;

test("OFX 1.x (SGML): lê conta, período, saldo e lançamentos; erros ficam visíveis", () => {
  const r = lerOfx(OFX_SGML);
  assert.equal(r.tipo, "extrato");
  assert.equal(r.banco, "0341");
  assert.equal(r.conta, "12345-6");
  assert.equal(r.inicio, "2026-10-01");
  assert.equal(r.fim, "2026-10-10");
  assert.equal(r.saldo_centavos, 123456);
  assert.equal(r.saldo_data, "2026-10-10");
  assert.deepEqual(r.itens.map((i) => [i.data, i.valor_centavos, i.descricao, i.identificador]), [
    ["2026-10-03", -8000, "SUPERMERCADO & CIA", "A1"],
    ["2026-10-05", 500050, "SALARIO", "A2"],
    ["2026-10-06", -1234, "TARIFA · PACOTE", "A3"],
    ["2026-10-06", 1500, "DEBITO POSITIVO", "A4"],
  ]);
  assert.deepEqual(r.erros.map((e) => e.linha), [5, 6]);
  assert.match(r.avisos.join(" "), /1 lançamento\(s\) marcados como débito vieram com valor positivo/);
});

test("OFX 2.x (XML) e OFX de cartão de crédito", () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?><?OFX OFXHEADER="200" VERSION="220"?>
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKACCTFROM><BANKID>260</BANKID><ACCTID>999</ACCTID></BANKACCTFROM>
<BANKTRANLIST><STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20261002</DTPOSTED><TRNAMT>10.00</TRNAMT><FITID>X1</FITID><MEMO>Pix recebido - João</MEMO></STMTTRN></BANKTRANLIST>
</STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;
  const r = lerOfx(xml);
  assert.deepEqual(r.itens, [{ data: "2026-10-02", valor_centavos: 1000, descricao: "Pix recebido - João", data_operacao: null, identificador: "X1", documento: null }]);
  const cartao = lerOfx(xml.replace("<STMTRS>", "<CCSTMTRS>"));
  assert.equal(cartao.tipo, "cartao");
});

test("valor OFX não aceita separador de milhar nem casas significativas além da 2ª", () => {
  assert.equal(valorOfx("-80.00"), -8000);
  assert.equal(valorOfx("80"), 8000);
  assert.equal(valorOfx("-80,5"), -8050);
  assert.equal(valorOfx("-80.0000"), -8000);
  assert.equal(valorOfx("1.234,56"), null);
  assert.equal(valorOfx("-1.234"), null);
});

test("arquivo em Windows-1252 é lido com acentos corretos", () => {
  const bytes = new Uint8Array([...new TextEncoder().encode("CHARSET:1252\n<MEMO>PADARIA S"), 0xc3, 0x4f, 0x20, 0x4a, 0x4f, 0xc3, 0x4f]);
  assert.match(decodificar(bytes), /PADARIA SÃO JOÃO/);
  const utf8 = new TextEncoder().encode("Descrição");
  assert.equal(decodificar(utf8), "Descrição");
});

test("valores de CSV em formatos brasileiros e americanos", () => {
  assert.equal(valorParaCentavos("1.234,56"), 123456);
  assert.equal(valorParaCentavos("-1.234,56"), -123456);
  assert.equal(valorParaCentavos("1,234.56"), 123456);
  assert.equal(valorParaCentavos("R$ 80,00"), 8000);
  assert.equal(valorParaCentavos("80,00-"), -8000);
  assert.equal(valorParaCentavos("(80,00)"), -8000);
  assert.equal(valorParaCentavos("12.5"), 1250);
  assert.equal(valorParaCentavos("abc"), null);
  assert.equal(valorParaCentavos("1,2,3"), null);
});

test("datas de CSV", () => {
  assert.equal(dataCsv("03/10/2026", "dmy"), "2026-10-03");
  assert.equal(dataCsv("03/10/26", "dmy"), "2026-10-03");
  assert.equal(dataCsv("2026-10-03", "ymd"), "2026-10-03");
  assert.equal(dataCsv("10/03/2026", "mdy"), "2026-10-03");
  assert.equal(dataCsv("31/02/2026", "dmy"), null);
  assert.equal(dataCsv("2026-10-03 14:00", "ymd"), "2026-10-03");
});

test("CSV com cabeçalho, aspas e ponto e vírgula; mapeamento sugerido e linhas inválidas apontadas", () => {
  const texto = 'Data;Histórico;Valor\r\n03/10/2026;"Mercado; filial 2";-80,00\r\n05/10/2026;Salário;5.000,00\r\n;Saldo do dia;\r\n06/10/2026;Pix "João";-12,34\r\n';
  const { separador, linhas } = lerCsvBruto(texto);
  assert.equal(separador, ";");
  const mapa = sugerirMapa(linhas);
  assert.deepEqual([mapa.cabecalho, mapa.colData, mapa.colDescricao, mapa.colValor, mapa.formatoData, mapa.modoValor], [true, 0, 1, 2, "dmy", "uma"]);
  const r = mapearCsv(linhas, mapa);
  assert.deepEqual(r.itens.map((i) => [i.data, i.descricao, i.valor_centavos]), [
    ["2026-10-03", "Mercado; filial 2", -8000],
    ["2026-10-05", "Salário", 500000],
    ["2026-10-06", 'Pix "João"', -1234],
  ]);
  assert.deepEqual(r.erros.map((e) => e.linha), [4]);
});

test("CSV com débito e crédito em colunas separadas, e sinal invertido", () => {
  const { linhas } = lerCsvBruto("data,descricao,debito,credito\n2026-10-03,Mercado,80.00,\n2026-10-05,Salario,,5000.00\n");
  const mapa = sugerirMapa(linhas);
  assert.equal(mapa.modoValor, "duas");
  assert.equal(mapa.formatoData, "ymd");
  assert.deepEqual(mapearCsv(linhas, mapa).itens.map((i) => i.valor_centavos), [-8000, 500000]);
  const { linhas: l2 } = lerCsvBruto("03/10/2026;Compra;80,00\n");
  const m2 = { ...sugerirMapa(l2), inverterSinal: true };
  assert.equal(m2.cabecalho, false);
  assert.deepEqual(mapearCsv(l2, m2).itens.map((i) => i.valor_centavos), [-8000]);
});
