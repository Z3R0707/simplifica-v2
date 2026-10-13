// Extração de texto de PDF com posição (pdf.js), em linhas e células.
// O pdf.js é carregado só quando um PDF é escolhido (arquivo próprio em
// /assets/pdfjs-<versão>, servido pelo próprio site — nada vai para fora).
// A leitura acontece no navegador; os leitores de cada banco recebem as
// linhas já montadas e só aceitam o que conseguem conferir.

export type Celula = { x: number; x2: number; texto: string };
export type LinhaPdf = { pagina: number; y: number; celulas: Celula[]; texto: string };

type ItemPdf = { str: string; transform: number[]; width: number };
type PaginaPdf = { getTextContent: () => Promise<{ items: unknown[] }> };
type DocumentoPdf = { numPages: number; getPage: (n: number) => Promise<PaginaPdf> };
export type ModuloPdfjs = {
  getDocument: (o: Record<string, unknown>) => { promise: Promise<DocumentoPdf> };
  GlobalWorkerOptions?: { workerSrc: string };
};

/** Monta as linhas do PDF: itens na mesma altura (±2pt) viram uma linha, ordenada da esquerda para a direita. */
export async function extrairLinhas(pdfjs: ModuloPdfjs, bytes: Uint8Array): Promise<LinhaPdf[]> {
  const doc = await pdfjs.getDocument({ data: bytes.slice(), isEvalSupported: false, disableFontFace: true }).promise;
  const linhas: LinhaPdf[] = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const pagina = await doc.getPage(n);
    const { items } = await pagina.getTextContent();
    const celulas = (items as ItemPdf[])
      .filter((i) => typeof i.str === "string" && i.str.trim() !== "")
      .map((i) => ({ x: i.transform[4], x2: i.transform[4] + i.width, y: i.transform[5], texto: i.str.replace(/\s+/g, " ").trim() }))
      .sort((a, b) => b.y - a.y || a.x - b.x);
    const daPagina: LinhaPdf[] = [];
    for (const c of celulas) {
      const linha = daPagina.find((l) => Math.abs(l.y - c.y) <= 2);
      if (linha) linha.celulas.push({ x: c.x, x2: c.x2, texto: c.texto });
      else daPagina.push({ pagina: n, y: c.y, celulas: [{ x: c.x, x2: c.x2, texto: c.texto }], texto: "" });
    }
    for (const l of daPagina) {
      l.celulas.sort((a, b) => a.x - b.x);
      l.texto = l.celulas.map((c) => c.texto).join(" ");
    }
    linhas.push(...daPagina.sort((a, b) => b.y - a.y));
  }
  return linhas;
}

/** Carrega o pdf.js do próprio site (só quando necessário) e extrai as linhas. */
export async function lerLinhasPdfNoNavegador(bytes: Uint8Array, base: string): Promise<LinhaPdf[]> {
  const caminho = `${base}pdf.min.js`;
  const pdfjs = (await import(/* carregado em tempo de execução */ caminho)) as ModuloPdfjs;
  if (pdfjs.GlobalWorkerOptions) pdfjs.GlobalWorkerOptions.workerSrc = `${base}pdf.worker.min.js`;
  return extrairLinhas(pdfjs, bytes);
}
