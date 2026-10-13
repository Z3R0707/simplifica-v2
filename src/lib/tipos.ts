// Formas dos dados devolvidos pelo banco (etapas 1 e 2).

export type Instituicao = { id: string; nome: string; codigo_compe: string | null };
export type Titular = { id: string; nome: string; principal: boolean; ativo: boolean; versao: number };
export type Perfil = { id: string; nome: string; versao: number };
export type TipoConta = "corrente" | "poupanca" | "pagamento" | "investimento";
export type Conta = {
  id: string;
  titular_id: string;
  instituicao_id: string;
  apelido: string;
  tipo: TipoConta;
  agencia: string | null;
  numero: string | null;
  saldo_inicial_centavos: number;
  saldo_inicial_data: string;
  saldo_inicial_validado: boolean;
  incluir_consolidado: boolean;
  ativa: boolean;
  versao: number;
};
export type Categoria = {
  id: string;
  nome: string;
  tipo: "receita" | "despesa";
  pai_id: string | null;
  cor: string | null;
  ativa: boolean;
  versao: number;
};
export type Classificacao = "receita" | "despesa" | "nao_classificado";
export type Movimento = {
  id: string;
  conta_id: string;
  natureza: "credito" | "debito";
  valor_centavos: number;
  data_movimento: string;
  descricao: string;
  classificacao: Classificacao;
  categoria_id: string | null;
  situacao: "efetivo" | "previsto" | "cancelado";
  observacao: string | null;
  cancelado_motivo: string | null;
  estorno_de: string | null;
  versao: number;
  criado_em: string;
};
export type LinhaSaldo = {
  conta_id: string;
  apelido: string;
  instituicao: string;
  titular: string;
  tipo: TipoConta;
  ativa: boolean;
  incluir_consolidado: boolean;
  saldo_inicial_centavos: number;
  saldo_inicial_data: string;
  saldo_inicial_validado: boolean;
  movimentos_no_saldo: number;
  movimentos_anteriores_data_base: number;
  saldo_confirmado_centavos: number | null;
  previstos_pendentes_centavos: number;
  saldo_projetado_centavos: number | null;
  ultimo_movimento_em: string | null;
  situacao: "ok" | "saldo_inicial_nao_validado" | "data_anterior_a_data_base" | "conta_arquivada";
};
export type Consolidado = {
  data_referencia: string;
  saldo_confirmado_centavos: number;
  saldo_projetado_centavos: number;
  contas_somadas: number;
  contas_pendentes: number;
  completo: boolean;
};
export type LinhaExtrato = {
  movimento_id: string;
  data_movimento: string;
  descricao: string;
  natureza: "credito" | "debito";
  valor_centavos: number;
  valor_assinado_centavos: number;
  situacao: "efetivo" | "previsto" | "cancelado";
  classificacao: Classificacao;
  categoria: string | null;
  conta_no_saldo: boolean;
  saldo_apos_centavos: number | null;
  versao: number;
};
export type LinhaResumo = {
  classificacao: Classificacao;
  categoria_id: string | null;
  categoria: string;
  movimentos: number;
  total_centavos: number;
};

export const NOMES_TIPO_CONTA: Record<TipoConta, string> = {
  corrente: "Conta corrente",
  poupanca: "Poupança",
  pagamento: "Conta de pagamento",
  investimento: "Investimento",
};
