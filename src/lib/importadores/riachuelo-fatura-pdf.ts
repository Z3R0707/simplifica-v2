// Leitor da FATURA do Cartão Riachuelo (Midway) em PDF. Feito e conferido com arquivo real.
//
// Layout: cabeçalho com "Vencimento" e "Saldo à Pagar (R$)"; "Resumo de
// movimentações (R$)" (saldo anterior, pagamentos/créditos, encargos,
// despesas no Brasil e no exterior, saldo desta fatura); "Histórico de
// Despesas": "28/02/26 438" (data com ano + código da loja), descrição,
// valor TOTAL da compra, parcela "08/10" e o valor da parcela "+ 61,99".
// O pagamento aparece como "- 195,12".
// Conferência: soma dos itens = despesas no Brasil + no exterior +
// encargos − créditos (pagamentos/créditos do resumo − pagamentos lidos).
import type { LinhaPdf } from "./pdf.ts";
import { conferirTotal, dataIsoDe, marcarAntecipacoesNaFatura, separarParcela, subtipoEncargo, valorBr, type FaturaLida, type ItemFatura } from "./fatura-comum.ts";

const DATA = /^(\d{2})\/(\d{2})\/(\d{2})(?: \d+)?$/;
const VALOR = /^[-+]? ?[\d.]+,\d{2}$/;
const FIM_HISTORICO = /^(Encargos|Informações Importantes)$/;

export function reconheceRiachueloFatura(linhas: LinhaPdf[]): boolean {
  const t = linhas.map((l) => l.texto).join(" | ");
  return /MIDWAY/i.test(t) && /Histórico de Despesas/.test(t) && /Resumo de movimentações/.test(t);
}

const iso = (d: string) => d.split("/").reverse().join("-");

export function lerRiachueloFaturaPdf(linhas: LinhaPdf[]): FaturaLida {
  const f: FaturaLida = {
    leitor: "riachuelo-fatura-pdf", banco: "", finais: [], vencimento: "", fechamento: null,
    total_lancamentos_centavos: null, total_a_pagar_centavos: null, itens: [], pagamentos: [], erros: [], avisos: [],
  };
  for (let i = 0; i < linhas.length && !f.vencimento; i++) {
    const tit = linhas[i].celulas.find((c) => c.texto === "Vencimento");
    if (!tit) continue;
    const abaixo = linhas.slice(i + 1, i + 4).filter((l) => l.pagina === linhas[i].pagina && linhas[i].y - l.y < 25).flatMap((l) => l.celulas);
    const v = abaixo.find((c) => /^\d{2}\/\d{2}\/\d{4}$/.test(c.texto) && Math.abs(c.x - tit.x) < 25);
    if (v) f.vencimento = iso(v.texto);
  }
  if (!f.vencimento) {
    f.erros.push({ linha: 0, motivo: "não encontrei a data de vencimento da fatura" });
    return f;
  }
  const valorDe = (re: RegExp) => {
    for (const l of linhas) {
      const i = l.celulas.findIndex((c) => re.test(c.texto));
      if (i >= 0 && l.celulas[i + 1] && VALOR.test(l.celulas[i + 1].texto)) return valorBr(l.celulas[i + 1].texto);
    }
    return null;
  };
  f.total_a_pagar_centavos = valorDe(/^Saldo desta Fatura$/);
  const brasil = valorDe(/^Despesas\/Débitos no Brasil$/);
  const exterior = valorDe(/^Despesas\/Débitos no Exterior$/) ?? 0;
  const encargos = valorDe(/^Encargos$/) ?? 0;
  const pagCred = valorDe(/^Pagamentos\/Créditos$/) ?? 0;

  // O histórico pode continuar na página seguinte (com cabeçalho repetido):
  // termina no quadro de "Encargos" (taxas) ou em "Informações Importantes".
  const ini = linhas.findIndex((l) => /^Histórico de Despesas$/.test(l.texto));
  let n = 0;
  for (const l of ini >= 0 ? linhas.slice(ini + 1) : []) {
    if (FIM_HISTORICO.test(l.texto)) break;
    const c = l.celulas;
    const md = DATA.exec(c[0]?.texto ?? "");
    if (!md) continue;
    n++;
    const ultima = c[c.length - 1];
    if (!VALOR.test(ultima.texto)) { f.erros.push({ linha: n, motivo: `valor não reconhecido: "${l.texto}"` }); continue; }
    const valor = valorBr(ultima.texto)!;
    const data = dataIsoDe(Number(`20${md[3]}`), Number(md[2]), Number(md[1]));
    const pc = c.find((x) => /^\d{2}\/\d{2}$/.test(x.texto) && x.x > 440 && x !== ultima);
    const descCel = c.slice(1, -1).filter((x) => x !== pc && !(VALOR.test(x.texto) && x.x > 380));
    const descricao = descCel.map((x) => x.texto).join(" ").replace(/\s+/g, " ").trim();
    if (!descricao || !data) { f.erros.push({ linha: n, motivo: `lançamento incompleto: "${l.texto}"` }); continue; }
    if (valor < 0 && /^PAGAMENTO\b/i.test(descricao)) {
      f.pagamentos.push({ data, descricao: descricao.slice(0, 200), valor_centavos: valor });
      continue;
    }
    if (valor === 0) continue;
    const parc = pc ? separarParcela(`X ${pc.texto}`, "itau") : { atual: null, total: null };
    const sub = subtipoEncargo(descricao);
    let item: ItemFatura;
    if (valor < 0) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "credito" };
    else if (sub && parc.atual === null) item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "encargo", subtipo: sub };
    else item = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, tipo: "compra", parcela_atual: parc.atual, parcelas_total: parc.total };
    f.itens.push(item);
  }
  const pagos = f.pagamentos.reduce((s, p) => s + Math.abs(p.valor_centavos), 0);
  const creditos = Math.abs(pagCred) - pagos;
  f.total_lancamentos_centavos = brasil === null ? null : brasil + exterior + encargos - creditos;
  if (creditos < 0) f.erros.push({ linha: 0, motivo: "os pagamentos lidos passam do total de pagamentos e créditos do resumo" });
  marcarAntecipacoesNaFatura(f.itens);
  conferirTotal(f, "total de despesas e encargos menos créditos do resumo");
  return f;
}
