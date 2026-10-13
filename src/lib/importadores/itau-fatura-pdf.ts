// Leitor da FATURA do cartão Itaú em PDF. Feito e conferido com arquivo real.
//
// Layout: capa com "Vencimento: 13/10/2026", "Emissão: 03/10/2026",
// "Cartão 1234.XXXX.XXXX.5678" e o resumo ("Total desta fatura").
// As páginas de lançamentos têm DUAS colunas: a da esquerda segue até o
// pé da página e continua no alto da coluna da direita. Seções:
//   "Pagamentos efetuados"          → pagamentos (só conferência)
//   "Lançamentos: compras e saques" → itens (DATA dd/mm, ESTABELECIMENTO, VALOR)
//   "Lançamentos no cartão  1.354,14" → subtotal do cartão
//   "Total dos lançamentos atuais 1.354,14" → total para conferência
//   "Compras parceladas - próximas faturas" → ignorado (é previsão)
// A segunda linha de cada compra (ramo e cidade) não tem data e é ignorada.
// Parcela: sufixo "NN/NN" no estabelecimento ("MERCADOLIVRE*M 01/04").
import type { LinhaPdf } from "./pdf.ts";
import { conferirTotal, dataCompraParcela, separarParcela, subtipoEncargo, valorBr, type FaturaLida, type ItemFatura } from "./fatura-comum.ts";

const DATA = /^(\d{2})\/(\d{2})$/;
const VALOR = /^-?[\d.]+,\d{2}$/;
const COLUNA_DIREITA = 340; // x que separa as duas colunas das páginas de lançamentos

export function reconheceItauFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.slice(0, 80).map((l) => l.texto).join(" | ");
  return /Resumo da fatura em R\$/.test(t) && /Vencimento: \d{2}\/\d{2}\/\d{4}/.test(t) && /Total desta fatura/.test(t)
    && linhas.some((l) => /Lançamentos: compras e saques/.test(l.texto));
}

const iso = (d: string) => d.split("/").reverse().join("-");

export function lerItauFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "itau-fatura-pdf", banco: "341", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  const todo = linhas.map((l) => l.texto).join("\n");
  const venc = /Vencimento: (\d{2}\/\d{2}\/\d{4})/.exec(todo);
  if (!venc) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  f.vencimento = iso(venc[1]);
  const emis = /Emissão: (\d{2}\/\d{2}\/\d{4})/.exec(todo);
  if (emis) f.fechamento = iso(emis[1]);
  f.finais = [...new Set([...todo.matchAll(/Cartão \d{4}\.XXXX\.XXXX\.(\d{4})/g)].map((m) => m[1]))].sort();
  const totalFat = linhas.find((l) => /Total desta fatura/.test(l.texto));
  if (totalFat) f.total_a_pagar_centavos = valorBr(totalFat.celulas[totalFat.celulas.length - 1].texto);

  // fluxo de leitura: em cada página, a coluna da esquerda e depois a da direita
  type Pedaco = { pagina: number; y: number; celulas: LinhaPdf["celulas"] };
  const fluxo: Pedaco[] = [];
  const paginas = [...new Set(linhas.map((l) => l.pagina))].sort((a, b) => a - b);
  for (const p in paginas) {
    const daPag = linhas.filter((l) => l.pagina === paginas[p]);
    for (const lado of ["esq", "dir"] as const) {
      for (const l of daPag) {
        const cel = l.celulas.filter((c) => (lado === "esq" ? c.x < COLUNA_DIREITA : c.x >= COLUNA_DIREITA));
        if (cel.length) fluxo.push({ pagina: l.pagina, y: l.y, celulas: cel });
      }
    }
  }

  let secao: "nenhuma" | "pagamentos" | "lancamentos" | "outra" = "nenhuma";
  let n = 0;
  for (const p of fluxo) {
    const c = p.celulas.filter((x) => !/^[PLS=]$/.test(x.texto)); // letras de marcação da margem
    if (!c.length) continue;
    const texto = c.map((x) => x.texto).join(" ");
    if (/^Pagamentos efetuados$/.test(texto)) { secao = "pagamentos"; continue; }
    if (/^Lançamentos: /.test(texto)) { secao = "lancamentos"; continue; }
    if (/^Compras parceladas - próximas faturas/.test(texto) || /^Encargos cobrados nesta fatura/.test(texto) || /^Limites de crédito/.test(texto)) { secao = "outra"; continue; }
    const tot = /^Total dos lançamentos atuais$/.test(c.slice(0, -1).map((x) => x.texto).join(" "));
    if (tot && VALOR.test(c[c.length - 1].texto)) { f.total_lancamentos_centavos = valorBr(c[c.length - 1].texto); secao = "outra"; continue; }
    if (/^Lançamentos no cartão/.test(texto) || /^Total dos pagamentos/.test(texto)) continue;
    if (secao !== "pagamentos" && secao !== "lancamentos") continue;
    const md = DATA.exec(c[0].texto);
    if (!md) continue; // cabeçalho da tabela, nome do portador, ramo/cidade
    n++;
    const ultima = c[c.length - 1];
    const bruta = c.slice(1, -1).map((x) => x.texto).join(" ").replace(/\s+/g, " ").trim();
    const data = dataCompraParcela(Number(md[1]), Number(md[2]), f.vencimento, separarParcela(bruta, "itau").atual);
    if (c.length < 3 || !VALOR.test(ultima.texto) || !data) { f.erros.push({ linha: n, motivo: `linha não reconhecida: "${texto}"` }); continue; }
    const valor = valorBr(ultima.texto)!;
    if (secao === "pagamentos") {
      f.pagamentos.push({ data, descricao: bruta.slice(0, 200), valor_centavos: valor });
      continue;
    }
    if (valor === 0) continue;
    const parc = separarParcela(bruta, "itau");
    const sub = subtipoEncargo(parc.descricao);
    let item: ItemFatura;
    if (valor < 0) item = { data, descricao: parc.descricao.slice(0, 200), valor_centavos: valor, tipo: "credito" };
    else if (sub && parc.atual === null) item = { data, descricao: parc.descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub };
    else item = { data, descricao: parc.descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", parcela_atual: parc.atual, parcelas_total: parc.total };
    f.itens.push(item);
  }
  conferirTotal(f, "total dos lançamentos atuais");
  return f;
}
