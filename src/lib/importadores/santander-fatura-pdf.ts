// Leitor da FATURA do cartão Santander em PDF. Feito e conferido com arquivo real.
//
// Layout: página "Detalhamento da Fatura" em DUAS colunas — à esquerda os
// lançamentos, por cartão ("FULANO - 1234 XXXX XXXX 5678"; "@" = adicional
// ou virtual) e por seção ("Pagamento e Demais Créditos", "Despesas",
// "Parcelamentos"); à direita o "Resumo da Fatura".
// Cada lançamento: "dd/mm DESCRIÇÃO" numa célula, a parcela "NN/NN" noutra,
// o valor em R$ e o valor em US$. O ano da compra vem do vencimento e do
// número da parcela.
// Conferência: soma dos itens = Total Despesas/Débitos no Brasil + no
// Exterior − Total de créditos (do resumo do próprio banco).
import type { LinhaPdf } from "./pdf.ts";
import {
  conferirTotal, dataCompraParcela, marcarAntecipacoesNaFatura, separarParcela, subtipoEncargo, valorBr,
  type FaturaLida, type ItemFatura,
} from "./fatura-comum.ts";

const COLUNA_DIREITA = 300;
const DATA_DESC = /^(\d{2})\/(\d{2}) (.+)$/;
const PARCELA = /^(\d{2})\/(\d{2})$/;
const VALOR = /^-?[\d.]+,\d{2}$/;

export function reconheceSantanderFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.map((l) => l.texto).join(" | ");
  return /fatura do seu cartão SANTANDER/i.test(t) && /Detalhamento da Fatura/.test(t) && /Resumo da Fatura/.test(t);
}

const iso = (d: string) => d.split("/").reverse().join("-");

export function lerSantanderFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "santander-fatura-pdf", banco: "033", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  // vencimento: valor abaixo do título "Vencimento" do quadro "Total a Pagar | Vencimento | Seu limite"
  for (let i = 0; i < linhas.length - 1 && !f.vencimento; i++) {
    const tit = linhas[i].celulas.find((c) => c.texto === "Vencimento");
    if (!tit || !linhas[i].celulas.some((c) => c.texto === "Total a Pagar")) continue;
    const abaixo = linhas.slice(i + 1, i + 4).filter((l) => l.pagina === linhas[i].pagina && linhas[i].y - l.y < 25).flatMap((l) => l.celulas);
    const v = abaixo.find((c) => /^\d{2}\/\d{2}\/\d{4}$/.test(c.texto) && Math.abs(c.x - tit.x) < 20);
    const tot = abaixo.find((c) => /^R\$ ?[\d.]+,\d{2}$/.test(c.texto) && c.x < tit.x && c.x > tit.x - 150);
    if (v) f.vencimento = iso(v.texto);
    if (tot) f.total_a_pagar_centavos = valorBr(tot.texto);
  }
  if (!f.vencimento) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  // fechamento: fim do período de compras mais próximo antes do vencimento ("01/09/26 a 01/10/26")
  const periodos = linhas.flatMap((l) => l.celulas.map((c) => /^\d{2}\/\d{2}\/\d{2} a (\d{2})\/(\d{2})\/(\d{2})$/.exec(c.texto)).filter(Boolean)) as RegExpExecArray[];
  const fins = periodos.map((m) => `20${m[3]}-${m[2]}-${m[1]}`).filter((d) => d < f.vencimento).sort();
  f.fechamento = fins[fins.length - 1] ?? null;

  // resumo (coluna da direita)
  const resumo = (re: RegExp) => {
    for (const l of linhas) {
      const dir = l.celulas.filter((c) => c.x >= COLUNA_DIREITA);
      const i = dir.findIndex((c) => re.test(c.texto));
      if (i >= 0 && dir[i + 1] && VALOR.test(dir[i + 1].texto)) return valorBr(dir[i + 1].texto);
    }
    return null;
  };
  const brasil = resumo(/^\(\+\) Total Despesas\/Débitos no Brasil$/);
  const exterior = resumo(/^\(\+\) Total Despesas\/Débitos no Exterior$/) ?? 0;
  const creditos = resumo(/^\(-\) Total de créditos$/) ?? 0;
  f.total_lancamentos_centavos = brasil === null ? null : brasil + exterior - creditos;

  // lançamentos (coluna da esquerda, a partir do "Detalhamento da Fatura")
  const ini = linhas.findIndex((l) => l.celulas.some((c) => c.texto === "Detalhamento da Fatura"));
  let secao: "nenhuma" | "creditos" | "despesas" = "nenhuma";
  let final: string | null = null;
  const finais = new Set<string>();
  let n = 0;
  for (const l of ini >= 0 ? linhas.slice(ini) : []) {
    const c = l.celulas.filter((x) => x.x < COLUNA_DIREITA && !(x.x < 30 && /^\d$/.test(x.texto))); // sem a marca numérica da margem
    if (!c.length) continue;
    const texto = c.map((x) => x.texto).join(" ");
    const cart = /XXXX XXXX (\d{4})$/.exec(texto);
    if (cart) { final = cart[1]; finais.add(final); continue; }
    if (/^Pagamento e Demais Créditos$/.test(texto)) { secao = "creditos"; continue; }
    if (/^(Despesas|Parcelamentos)$/.test(texto)) { secao = "despesas"; continue; }
    if (/^Juros e Custo Efetivo/.test(texto)) { secao = "nenhuma"; continue; }
    const md = DATA_DESC.exec(c[0].texto);
    if (secao === "nenhuma" || !md) continue; // cabeçalhos, "VALOR TOTAL"
    n++;
    const valorCel = c.find((x) => VALOR.test(x.texto) && x.x2 > 190 && x.x2 < 235);
    const parcCel = c.find((x) => PARCELA.test(x.texto) && x.x > 150 && x.x2 < 195);
    if (!valorCel) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${texto}"` }); continue; }
    const valor = valorBr(valorCel.texto)!;
    const descricao = md[3].replace(/\s+/g, " ").trim();
    const parc = parcCel ? separarParcela(`X ${parcCel.texto}`, "itau") : { atual: null, total: null };
    // anuidade parcelada vem com a data da cobrança, não a da "compra"
    const data = dataCompraParcela(Number(md[1]), Number(md[2]), f.vencimento, /^ANUIDADE\b/i.test(descricao) ? null : parc.atual);
    if (!data) { f.erros.push({ linha: n, motivo: `data inválida: "${texto}"` }); continue; }
    if (secao === "creditos" && /^PAGAMENTO\b/i.test(descricao)) {
      f.pagamentos.push({ data, descricao: descricao.slice(0, 200), valor_centavos: valor });
      continue;
    }
    if (valor === 0) continue;
    let item: ItemFatura;
    const sub = subtipoEncargo(descricao);
    if (valor < 0) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "credito", final };
    else if (sub && parc.atual === null) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub, final };
    else item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", parcela_atual: parc.atual, parcelas_total: parc.total, final };
    f.itens.push(item);
  }
  f.finais = [...finais].sort();
  marcarAntecipacoesNaFatura(f.itens);
  conferirTotal(f, "total de despesas menos créditos do resumo");
  return f;
}
