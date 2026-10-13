// Datas como texto ISO "AAAA-MM-DD", sempre no fuso de Brasília,
// igual ao banco (privado.hoje()).

const FUSO = "America/Sao_Paulo";

export function hoje(agora: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: FUSO, year: "numeric", month: "2-digit", day: "2-digit" }).format(agora);
}

export function mesAtual(agora: Date = new Date()): string {
  return hoje(agora).slice(0, 7);
}

/** "2026-10-05" → "05/10/2026" */
export function formatarData(iso: string | null | undefined): string {
  if (!iso) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : iso;
}

/** "2026-02" → ["2026-02-01", "2026-02-28"] */
export function limitesDoMes(mes: string): [string, string] {
  const m = /^(\d{4})-(\d{2})$/.exec(mes);
  if (!m) throw new Error("Mês inválido");
  const ano = Number(m[1]);
  const numero = Number(m[2]);
  const ultimo = new Date(Date.UTC(ano, numero, 0)).getUTCDate();
  return [`${m[1]}-${m[2]}-01`, `${m[1]}-${m[2]}-${String(ultimo).padStart(2, "0")}`];
}

export function nomeDoMes(mes: string): string {
  const [ano, numero] = mes.split("-").map(Number);
  const nome = new Intl.DateTimeFormat("pt-BR", { month: "long", timeZone: "UTC" }).format(new Date(Date.UTC(ano, numero - 1, 1)));
  return `${nome.charAt(0).toUpperCase()}${nome.slice(1)} de ${ano}`;
}

export function dataValida(iso: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}
