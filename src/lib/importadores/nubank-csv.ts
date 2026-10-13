// Leitor do EXTRATO DA CONTA do Nubank em CSV (exportação do app).
// Feito e conferido com arquivo real. Layout exato:
//   Data,Valor,Identificador,Descrição
//   01/01/2026,-10.00,11111111-…,Transferência enviada pelo Pix - …
// Data dd/mm/aaaa; valor com ponto decimal e sinal (saída negativa);
// identificador único do banco por lançamento (usado contra duplicidade).
// A descrição é a última coluna: se tiver vírgula, as partes são reunidas.
import { dataIso, type ExtratoLido, type ItemLido } from "./comum.ts";

const CABECALHO = /^data,valor,identificador,descri(ç|c)ão\s*$/i;
const VALOR = /^(-?)(\d+)\.(\d{2})$/;
const DATA = /^(\d{2})\/(\d{2})\/(\d{4})$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function ehNubankCsv(texto: string): boolean {
  const primeira = texto.replace(/^\uFEFF/, "").split(/\r?\n/, 1)[0] ?? "";
  return CABECALHO.test(primeira.trim());
}

export function lerNubankCsv(texto: string): ExtratoLido {
  const res: ExtratoLido = {
    formato: "csv", leitor: "nubank-csv-extrato", tipo: "extrato", banco: "260", conta: null,
    saldo_centavos: null, saldo_data: null, inicio: null, fim: null, itens: [], erros: [], avisos: [], estrito: true,
  };
  const linhas = texto.replace(/^\uFEFF/, "").split(/\r?\n/);
  const vistos = new Set<string>();
  linhas.slice(1).forEach((bruta, i) => {
    const n = i + 2;
    if (!bruta.trim()) return;
    const partes = bruta.split(",");
    if (partes.length < 4) return void res.erros.push({ linha: n, motivo: `linha com ${partes.length} coluna(s); esperado 4` });
    const [d, v, id] = partes.slice(0, 3).map((p) => p.trim());
    const resto = partes.slice(3);
    const md = DATA.exec(d);
    const data = md ? dataIso(Number(md[3]), Number(md[2]), Number(md[1])) : null;
    if (!data) return void res.erros.push({ linha: n, motivo: `data inválida: "${d}"` });
    const mv = VALOR.exec(v);
    if (!mv) return void res.erros.push({ linha: n, motivo: `valor fora do padrão do Nubank: "${v}"` });
    const valor = (Number(mv[2]) * 100 + Number(mv[3])) * (mv[1] ? -1 : 1);
    if (!Number.isSafeInteger(valor)) return void res.erros.push({ linha: n, motivo: "valor grande demais" });
    if (valor === 0) return void res.erros.push({ linha: n, motivo: "valor zero" });
    if (!UUID.test(id)) return void res.erros.push({ linha: n, motivo: `identificador fora do padrão do Nubank: "${id}"` });
    if (vistos.has(id.toLowerCase())) return void res.erros.push({ linha: n, motivo: "identificador repetido no arquivo" });
    vistos.add(id.toLowerCase());
    const descricao = resto.join(",").replace(/\s+/g, " ").trim();
    if (!descricao) return void res.erros.push({ linha: n, motivo: "sem descrição" });
    const item: ItemLido = { data, descricao: descricao.slice(0, 200), valor_centavos: valor, identificador: id.toLowerCase() };
    res.itens.push(item);
  });
  if (res.itens.length === 0 && res.erros.length === 0) res.erros.push({ linha: 0, motivo: "nenhum lançamento no arquivo" });
  const datas = res.itens.map((x) => x.data).sort();
  res.inicio = datas[0] ?? null;
  res.fim = datas[datas.length - 1] ?? null;
  res.avisos.push("O CSV do Nubank não traz saldo: confira o saldo da conta com o app depois de importar.");
  return res;
}
