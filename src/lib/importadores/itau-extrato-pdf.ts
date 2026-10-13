// Leitor do EXTRATO DA CONTA do Itaú em PDF (app/internet banking:
// "extrato conta / lançamentos"). Feito e conferido com arquivo real.
//
// Layout: colunas data | lançamentos | valor (R$) | saldo (R$). Os dias vêm
// do mais recente para o mais antigo, e cada dia tem uma linha "SALDO DO
// DIA" com o saldo na coluna da direita. O leitor confere, dia a dia:
//   saldo do dia anterior + lançamentos do dia = SALDO DO DIA.
// Se algum dia não fechar, a leitura é recusada com o dia e a diferença.
import { valorParaCentavos, type ExtratoLido, type ItemLido } from "./comum.ts";
import type { LinhaPdf } from "./pdf.ts";

const DATA = /^(\d{2})\/(\d{2})\/(\d{4})$/;
const VALOR = /^-?\d{1,3}(\.\d{3})*,\d{2}$/;

export function reconheceItauExtrato(linhas: LinhaPdf[]): boolean {
  const topo = linhas.slice(0, 40).map((l) => l.texto.toLowerCase()).join(" | ");
  return topo.includes("extrato conta / lançamentos") && topo.includes("saldo (r$)") && /período de visualização/.test(topo);
}

const reais = (c: number) => `R$ ${(c / 100).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

const iso = (d: string) => {
  const m = DATA.exec(d)!;
  return `${m[3]}-${m[2]}-${m[1]}`;
};

export function lerItauExtratoPdf(linhas: LinhaPdf[]): ExtratoLido {
  const res: ExtratoLido = {
    formato: "pdf", leitor: "itau-extrato-pdf", tipo: "extrato", banco: "341", conta: null,
    saldo_centavos: null, saldo_data: null, inicio: null, fim: null, itens: [], erros: [], avisos: [], estrito: true,
  };
  // fronteira entre as colunas "valor" e "saldo", pela posição dos títulos
  const cab = linhas.find((l) => l.celulas.some((c) => /^valor \(R\$\)$/i.test(c.texto)) && l.celulas.some((c) => /^saldo \(R\$\)$/i.test(c.texto)));
  const xValor = cab?.celulas.find((c) => /^valor/i.test(c.texto));
  const xSaldo = cab?.celulas.find((c) => /^saldo/i.test(c.texto));
  const fronteira = xValor && xSaldo ? (xValor.x2 + xSaldo.x) / 2 : 490;
  const contaCab = linhas.slice(0, 5).map((l) => /conta:\s*([\d-]+)/i.exec(l.texto)?.[1]).find(Boolean);
  res.conta = contaCab ?? null;
  const em = linhas.slice(0, 40).map((l) => /emitido em:\s*(\d{2}\/\d{2}\/\d{4})/i.exec(l.texto)?.[1]).find(Boolean);
  const emitidoEm = em ? iso(em) : null;

  const saldos = new Map<string, number>();
  const porDia = new Map<string, number>();
  let n = 0;
  for (const l of linhas) {
    const c = l.celulas;
    if (c.length < 3 || !DATA.test(c[0].texto)) continue;
    n++;
    const data = iso(c[0].texto);
    const ultima = c[c.length - 1];
    if (!VALOR.test(ultima.texto)) {
      res.erros.push({ linha: n, motivo: `valor não reconhecido: "${l.texto}"` });
      continue;
    }
    const valor = valorParaCentavos(ultima.texto)!;
    const descricao = c.slice(1, -1).map((x) => x.texto).join(" ").replace(/\s+/g, " ").trim();
    const naColunaSaldo = ultima.x2 > fronteira;
    if (/^SALDO DO DIA$/i.test(descricao)) {
      if (!naColunaSaldo) res.avisos.push(`SALDO DO DIA de ${c[0].texto} fora da coluna de saldo; conferido mesmo assim.`);
      saldos.set(data, valor);
      continue;
    }
    if (naColunaSaldo) {
      res.erros.push({ linha: n, motivo: `valor na coluna de saldo para um lançamento: "${l.texto}"` });
      continue;
    }
    if (!descricao) {
      res.erros.push({ linha: n, motivo: "lançamento sem descrição" });
      continue;
    }
    if (valor === 0) continue;
    const item: ItemLido = { data, descricao: descricao.slice(0, 200), valor_centavos: valor };
    res.itens.push(item);
    porDia.set(data, (porDia.get(data) ?? 0) + valor);
  }

  // conferência dia a dia com o SALDO DO DIA
  const dias = [...saldos.keys()].sort();
  for (const d of porDia.keys()) {
    if (!saldos.has(d)) res.erros.push({ linha: 0, motivo: `dia ${d.split("-").reverse().join("/")} sem linha de SALDO DO DIA para conferir` });
  }
  let falhas = 0;
  for (let i = 1; i < dias.length; i++) {
    const anterior = saldos.get(dias[i - 1])!;
    const esperado = anterior + (porDia.get(dias[i]) ?? 0);
    const informado = saldos.get(dias[i])!;
    if (esperado !== informado) {
      const texto = `conferência do dia ${dias[i].split("-").reverse().join("/")} não fecha: saldo anterior + lançamentos = ${reais(esperado)}, mas o banco informa ${reais(informado)} (diferença de ${reais(informado - esperado)})`;
      if (dias[i] === emitidoEm) {
        // o dia da emissão ainda está em andamento no banco: avisa, não bloqueia
        res.avisos.push(`Atenção: ${texto}. O extrato foi emitido nesse mesmo dia, que ainda estava em andamento no banco; confira o saldo depois de importar.`);
      } else {
        falhas++;
        res.erros.push({ linha: 0, motivo: texto });
      }
    }
  }
  if (dias.length >= 1) {
    const primeiro = dias[0];
    if ((porDia.get(primeiro) ?? 0) !== 0) {
      res.avisos.push(`O primeiro dia do extrato (${primeiro.split("-").reverse().join("/")}) não tem saldo anterior para conferir.`);
    }
    const ultimo = dias[dias.length - 1];
    res.saldo_centavos = saldos.get(ultimo)!;
    res.saldo_data = ultimo;
  }
  if (falhas === 0 && dias.length > 1) {
    const comAviso = res.avisos.some((a) => a.startsWith("Atenção: conferência"));
    res.avisos.push(comAviso
      ? `Os demais ${dias.length - 2} dia(s) conferem com o SALDO DO DIA do banco.`
      : `Conferido dia a dia com o SALDO DO DIA do banco (${dias.length - 1} dia(s)).`);
  }
  if (res.itens.length === 0) res.erros.push({ linha: 0, motivo: "nenhum lançamento encontrado no extrato" });
  const datas = res.itens.map((x) => x.data).sort();
  res.inicio = datas[0] ?? null;
  res.fim = datas[datas.length - 1] ?? null;
  return res;
}
