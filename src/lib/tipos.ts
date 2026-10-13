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

// ------------------------------------------------ Etapa 3: contas a pagar
export type StatusContaAPagar = "cancelada" | "paga" | "vencida" | "parcial" | "a_vencer";
export type LinhaContaAPagar = {
  obrigacao_id: string;
  descricao: string;
  vencimento: string;
  competencia: string;
  valor_centavos: number;
  categoria_id: string | null;
  categoria: string | null;
  conta_prevista_id: string | null;
  conta_prevista: string | null;
  origem: "avulsa" | "recorrencia" | "fatura";
  recorrencia_id: string | null;
  situacao: "aberta" | "cancelada";
  cancelada_motivo: string | null;
  observacao: string | null;
  pago_centavos: number;
  juros_centavos: number;
  multa_centavos: number;
  desconto_centavos: number;
  abatido_centavos: number;
  restante_centavos: number;
  pagamentos: number;
  ultimo_pagamento_em: string | null;
  status: StatusContaAPagar;
  versao: number;
};
export type LinhaPagamento = {
  pagamento_id: string;
  movimento_id: string;
  data_pagamento: string;
  conta_id: string;
  conta: string;
  valor_pago_centavos: number;
  juros_centavos: number;
  multa_centavos: number;
  desconto_centavos: number;
  abatido_centavos: number;
  origem: "pagamento" | "vinculo";
  situacao: "ativo" | "desfeito";
  desfeito_motivo: string | null;
  movimento_situacao: string;
  observacao: string | null;
  versao: number;
};
export type MovimentoVinculavel = {
  movimento_id: string;
  conta_id: string;
  conta: string;
  data_movimento: string;
  descricao: string;
  valor_centavos: number;
  livre_centavos: number;
  categoria: string | null;
};
export type Recorrencia = {
  id: string;
  descricao: string;
  categoria_id: string | null;
  conta_prevista_id: string | null;
  valor_centavos: number;
  dia_vencimento: number;
  inicio: string;
  fim: string | null;
  numerar_parcelas: boolean;
  observacao: string | null;
  versao: number;
};
export type APagarPorConta = {
  conta_prevista_id: string | null;
  quantidade: number;
  restante_centavos: number;
  vencidas_centavos: number;
};
export type PagamentoAtivo = { id: string; movimento_id: string; obrigacao_id: string; situacao: string };

export const NOMES_TIPO_CONTA: Record<TipoConta, string> = {
  corrente: "Conta corrente",
  poupanca: "Poupança",
  pagamento: "Conta de pagamento",
  investimento: "Investimento",
};
