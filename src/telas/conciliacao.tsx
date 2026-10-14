// Conciliação bancária: sugestões de vínculo (lançamento do extrato ×
// conta a pagar/fatura), lançamentos pendentes de classificação,
// divergências (pagamento contado duas vezes, saldo do extrato diferente),
// conciliados e histórico com desfazer. Nada é quitado sem confirmação.
import { useMemo, useState } from "react";
import { rpc } from "../lib/api";
import { formatarData } from "../lib/datas";
import { formatarCentavos } from "../lib/dinheiro";
import { Alerta, Carregando, Confirmar, Dialogo, TituloPagina, Valor, useCadastros, useCarregar, useEnvio } from "../ui";

type Resumo = { conta_id: string; pendentes: number; sugestoes: number; divergencias: number; conciliados: number };
type Sugestao = {
  movimento_id: string; conta_id: string; conta: string; data_movimento: string; descricao: string; valor_centavos: number;
  obrigacao_id: string; obrigacao: string; vencimento: string; restante_centavos: number; valor_vincular_centavos: number; e_fatura: boolean; pontos: number; motivo: string;
};
type Lancamento = {
  movimento_id: string; conta_id: string; conta: string; data_movimento: string; descricao: string; valor_centavos: number; origem: string;
  classificacao: string; categoria: string | null; conciliacao: "pagamento" | "classificado" | "pendente"; pagamentos: string | null;
  categoria_id: string | null; observacao: string | null; versao: number;
};
type Divergencia = {
  tipo: "pagamento_duplicado" | "saldo_importacao"; conta_id: string; conta: string; data: string | null; descricao: string; valor_centavos: number | null;
  pagamento_id: string | null; pagamento_versao: number | null; obrigacao: string | null; movimento_importado_id: string | null;
  importado_descricao: string | null; importado_data: string | null; importacao_id: string | null; saldo_informado: number | null; saldo_calculado: number | null;
};
type Historico = {
  pagamento_id: string; situacao: "ativo" | "desfeito"; origem: "pagamento" | "vinculo"; data_movimento: string; descricao: string; valor_centavos: number;
  obrigacao: string; vencimento: string; criado_em: string; desfeito_em: string | null; desfeito_motivo: string | null; versao: number;
};
type AbertaAPagar = { obrigacao_id: string; descricao: string; vencimento: string; restante_centavos: number; origem: string };
type Aba = "sugestoes" | "pendentes" | "divergencias" | "conciliados" | "historico";

const ABAS: { id: Aba; nome: string }[] = [
  { id: "sugestoes", nome: "Sugestões" }, { id: "pendentes", nome: "Pendentes" }, { id: "divergencias", nome: "Divergências" },
  { id: "conciliados", nome: "Conciliados" }, { id: "historico", nome: "Histórico" },
];

export function TelaConciliacao({ contaId }: { contaId?: string }) {
  const { contas } = useCadastros();
  const ativas = contas.filter((c) => c.ativa);
  const [conta, setConta] = useState<string>(contaId && ativas.some((c) => c.id === contaId) ? contaId : "");
  const [aba, setAba] = useState<Aba>("sugestoes");
  const [versao, setVersao] = useState(0);
  const recarregar = () => setVersao((v) => v + 1);
  const p = conta || null;
  const q = useCarregar(async () => {
    const [resumo, sugestoes, divergencias, lancamentos, historico] = await Promise.all([
      rpc<Resumo[]>("conciliacao_resumo"),
      rpc<Sugestao[]>("conciliacao_sugestoes", { p_conta_id: p }),
      rpc<Divergencia[]>("conciliacao_divergencias", { p_conta_id: p }),
      rpc<Lancamento[]>("conciliacao_lancamentos", { p_conta_id: p, p_de: null, p_ate: null }),
      rpc<Historico[]>("conciliacao_historico", { p_conta_id: p }),
    ]);
    return { resumo, sugestoes, divergencias, lancamentos, historico };
  }, [p, versao]);
  const d = q.dados;
  const pendentes = (d?.lancamentos ?? []).filter((l) => l.conciliacao === "pendente");
  const conciliados = (d?.lancamentos ?? []).filter((l) => l.conciliacao !== "pendente").slice(0, 200);
  const contagem: Record<Aba, number | null> = {
    sugestoes: d?.sugestoes.length ?? null, pendentes: d ? pendentes.length : null, divergencias: d?.divergencias.length ?? null,
    conciliados: null, historico: null,
  };

  return (
    <>
      <TituloPagina titulo="Conciliação bancária">
        <label className="seletor-data">
          <span>Conta</span>
          <select aria-label="Conta" value={conta} onChange={(e) => setConta(e.target.value)}>
            <option value="">Todas as contas</option>
            {ativas.map((c) => <option key={c.id} value={c.id}>{c.apelido}</option>)}
          </select>
        </label>
      </TituloPagina>
      <p className="texto-suave">
        Aqui os lançamentos do extrato encontram as contas a pagar e as faturas. Uma sugestão só vale depois que você confirma;
        confirmar não mexe no saldo (a saída já está na conta), só marca a conta como paga. Tudo pode ser desfeito.
      </p>
      <div className="abas" role="tablist">
        {ABAS.map((a) => (
          <button key={a.id} type="button" role="tab" aria-selected={aba === a.id} className={`aba${aba === a.id ? " aba-ativa" : ""}`} onClick={() => setAba(a.id)}>
            {a.nome}{contagem[a.id] !== null && contagem[a.id]! > 0 ? ` (${contagem[a.id]})` : ""}
          </button>
        ))}
      </div>
      {q.erro && <Alerta>{q.erro}</Alerta>}
      {q.carregando && !d && <Carregando />}
      {d && aba === "sugestoes" && <Sugestoes lista={d.sugestoes} aoMudar={recarregar} />}
      {d && aba === "pendentes" && <Pendentes lista={pendentes} aoMudar={recarregar} />}
      {d && aba === "divergencias" && <Divergencias lista={d.divergencias} aoMudar={recarregar} />}
      {d && aba === "conciliados" && <Conciliados lista={conciliados} />}
      {d && aba === "historico" && <HistoricoLista lista={d.historico} aoMudar={recarregar} />}
    </>
  );
}

// ------------------------------------------------------------ sugestões
function Sugestoes({ lista, aoMudar }: { lista: Sugestao[]; aoMudar: () => void }) {
  const { chave, enviando, erro, enviar } = useEnvio("conciliacao-confirmar");
  if (lista.length === 0) return <p className="vazio">Nenhuma sugestão agora. Importe um extrato ou cadastre as contas a pagar para o sistema encontrar os pares.</p>;
  const confirmar = (s: Sugestao) => rpc("obrigacao_vincular_movimento", {
    p_obrigacao_id: s.obrigacao_id, p_movimento_id: s.movimento_id, p_valor_pago_centavos: s.valor_vincular_centavos,
    p_juros_centavos: 0, p_multa_centavos: 0, p_desconto_centavos: 0, p_chave_idempotencia: `${chave}-${s.movimento_id.slice(0, 8)}-${s.obrigacao_id.slice(0, 8)}`,
  });
  return (
    <section className="secao">
      {erro && <Alerta>{erro}</Alerta>}
      <ul className="lista-simples lista-conciliacao">
        {lista.map((s) => (
          <li key={s.movimento_id}>
            <div>
              <strong>{s.descricao}</strong>
              <span className="texto-suave">{formatarData(s.data_movimento)} · {s.conta} · <Valor centavos={-s.valor_centavos} sinal /></span>
              <span>→ paga <strong>{s.obrigacao}</strong> (vence {formatarData(s.vencimento)}){s.e_fatura ? " · fatura do cartão" : ""}
                {s.valor_vincular_centavos < s.restante_centavos ? ` · a fatura soma ${formatarCentavos(s.restante_centavos)}; o resto foi pago antes e fica para vincular` : ""}</span>
              <span className="selo selo-neutro">{s.motivo}</span>
            </div>
            <span className="acoes-linha">
              <button type="button" className="botao" disabled={enviando} onClick={() => void enviar(async () => { await confirmar(s); aoMudar(); })}>Confirmar</button>
            </span>
          </li>
        ))}
      </ul>
      {lista.length > 1 && (
        <div className="acoes acoes-esquerda">
          <button type="button" className="botao-secundario" disabled={enviando}
            onClick={() => void enviar(async () => { for (const s of lista) await confirmar(s); aoMudar(); })}>
            {enviando ? "Confirmando…" : `Confirmar as ${lista.length} sugestões`}
          </button>
        </div>
      )}
    </section>
  );
}

// ------------------------------------------------------------ pendentes
function Pendentes({ lista, aoMudar }: { lista: Lancamento[]; aoMudar: () => void }) {
  const [vinculando, setVinculando] = useState<Lancamento | null>(null);
  if (lista.length === 0) return <p className="vazio">Nenhum lançamento pendente. Tudo classificado ou vinculado.</p>;
  return (
    <section className="secao">
      <p className="texto-suave">
        Lançamentos sem classificação. Escolha a categoria (receita, despesa, tarifa…) ou vincule a uma conta a pagar.
        Transferência entre contas suas fica para a próxima parte.
      </p>
      <ul className="lista-simples lista-conciliacao">
        {lista.map((l) => <LinhaPendente key={l.movimento_id} l={l} aoMudar={aoMudar} aoVincular={() => setVinculando(l)} />)}
      </ul>
      {vinculando && <DialogoVincular l={vinculando} aoFechar={() => setVinculando(null)} aoConcluir={() => { setVinculando(null); aoMudar(); }} />}
    </section>
  );
}

function LinhaPendente({ l, aoMudar, aoVincular }: { l: Lancamento; aoMudar: () => void; aoVincular: () => void }) {
  const { categorias } = useCadastros();
  const [cat, setCat] = useState("");
  const { chave, enviando, erro, enviar } = useEnvio("conciliacao-classificar");
  const tipo = l.valor_centavos < 0 ? "despesa" : "receita";
  const opcoes = categorias.filter((c) => c.ativa && c.tipo === tipo);
  return (
    <li>
      <div>
        <strong>{l.descricao}</strong>
        <span className="texto-suave">{formatarData(l.data_movimento)} · {l.conta}{l.origem === "importacao" ? " · do extrato" : ""}</span>
        {erro && <Alerta>{erro}</Alerta>}
      </div>
      <span className="acoes-linha acoes-pendente">
        <Valor centavos={l.valor_centavos} sinal />
        <select aria-label={`Categoria de ${l.descricao}`} value={cat} onChange={(e) => setCat(e.target.value)}>
          <option value="">Classificar como…</option>
          {opcoes.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
        </select>
        <button type="button" className="botao" disabled={!cat || enviando} onClick={() => void enviar(async () => {
          await rpc("movimento_atualizar", {
            p_id: l.movimento_id, p_versao_esperada: l.versao, p_natureza: l.valor_centavos < 0 ? "debito" : "credito",
            p_valor_centavos: Math.abs(l.valor_centavos), p_data: l.data_movimento, p_descricao: l.descricao,
            p_classificacao: tipo, p_categoria_id: cat, p_observacao: l.observacao, p_chave_idempotencia: chave,
          });
          aoMudar();
        })}>Salvar</button>
        {l.valor_centavos < 0 && <button type="button" className="botao-texto" onClick={aoVincular}>Vincular a conta a pagar</button>}
      </span>
    </li>
  );
}

function DialogoVincular({ l, aoFechar, aoConcluir }: { l: Lancamento; aoFechar: () => void; aoConcluir: () => void }) {
  const [a, m] = l.data_movimento.split("-").map(Number);
  const de = new Date(Date.UTC(a, m - 3, 1)).toISOString().slice(0, 10);
  const ate = new Date(Date.UTC(a, m + 1, 0)).toISOString().slice(0, 10);
  const q = useCarregar(() => rpc<AbertaAPagar[]>("contas_a_pagar", { p_inicio: de, p_fim: ate, p_incluir_vencidas: true }), [de, ate]);
  const abertas = useMemo(() => (q.dados ?? []).filter((o) => o.restante_centavos > 0)
    .sort((x, y) => Math.abs(x.restante_centavos + l.valor_centavos) - Math.abs(y.restante_centavos + l.valor_centavos)), [q.dados, l.valor_centavos]);
  const { chave, enviando, erro, enviar } = useEnvio("conciliacao-vincular");
  const valor = -l.valor_centavos;
  return (
    <Dialogo titulo="Vincular a uma conta a pagar" aoFechar={aoFechar}>
      <p><strong>{l.descricao}</strong> · {formatarData(l.data_movimento)} · {formatarCentavos(valor)}</p>
      {q.carregando && <Carregando />}
      {q.erro && <Alerta>{q.erro}</Alerta>}
      {!q.carregando && abertas.length === 0 && <p className="vazio">Nenhuma conta a pagar aberta nesse período.</p>}
      <ul className="lista-simples">
        {abertas.map((o) => (
          <li key={o.obrigacao_id}>
            <div>
              <strong>{o.descricao}</strong>
              <span className="texto-suave">vence {formatarData(o.vencimento)} · falta {formatarCentavos(o.restante_centavos)}{o.origem === "fatura" ? " · fatura do cartão" : ""}</span>
            </div>
            <span className="acoes-linha">
              <button type="button" className="botao-secundario" disabled={enviando} onClick={() => void enviar(async () => {
                await rpc("obrigacao_vincular_movimento", {
                  p_obrigacao_id: o.obrigacao_id, p_movimento_id: l.movimento_id, p_valor_pago_centavos: Math.min(valor, o.restante_centavos),
                  p_juros_centavos: 0, p_multa_centavos: 0, p_desconto_centavos: 0, p_chave_idempotencia: `${chave}-${o.obrigacao_id.slice(0, 8)}`,
                });
                aoConcluir();
              })}>Vincular</button>
            </span>
          </li>
        ))}
      </ul>
      {erro && <Alerta>{erro}</Alerta>}
      <p className="campo-ajuda">Se o valor do lançamento for menor que o que falta, a conta fica parcialmente paga.</p>
    </Dialogo>
  );
}

// ------------------------------------------------------------ divergências
function Divergencias({ lista, aoMudar }: { lista: Divergencia[]; aoMudar: () => void }) {
  const { chave, enviando, erro, enviar } = useEnvio("conciliacao-trocar");
  if (lista.length === 0) return <p className="vazio">Nenhuma divergência encontrada.</p>;
  return (
    <section className="secao">
      {erro && <Alerta>{erro}</Alerta>}
      <ul className="lista-simples lista-conciliacao">
        {lista.map((d, i) => d.tipo === "pagamento_duplicado" ? (
          <li key={`p-${d.pagamento_id}`}>
            <div>
              <strong>Saída contada duas vezes: {d.obrigacao}</strong>
              <span className="texto-suave">
                Você registrou o pagamento no Simplifica ({formatarData(d.data!)}, {formatarCentavos(d.valor_centavos!)}, em {d.conta}) e o extrato
                importado traz "{d.importado_descricao}" em {formatarData(d.importado_data!)} com o mesmo valor.
              </span>
              <span className="texto-suave">Usar o lançamento do extrato cancela o que foi registrado à mão (fica no histórico) e mantém a conta paga.</span>
            </div>
            <span className="acoes-linha">
              <button type="button" className="botao" disabled={enviando} onClick={() => void enviar(async () => {
                await rpc("conciliacao_trocar_pagamento", { p_pagamento_id: d.pagamento_id, p_versao_esperada: d.pagamento_versao, p_movimento_id: d.movimento_importado_id, p_chave_idempotencia: `${chave}-${d.pagamento_id!.slice(0, 8)}` });
                aoMudar();
              })}>Usar o lançamento do extrato</button>
            </span>
          </li>
        ) : (
          <li key={`s-${d.importacao_id}-${i}`}>
            <div>
              <strong>Saldo do extrato diferente: {d.conta}</strong>
              <span className="texto-suave">
                Em {formatarData(d.data!)} o banco informa {formatarCentavos(d.saldo_informado!)} e o Simplifica calcula {formatarCentavos(d.saldo_calculado!)}
                {" "}(diferença de {formatarCentavos(d.saldo_calculado! - d.saldo_informado!)}). Arquivo: {d.descricao}.
              </span>
            </div>
            <span className="acoes-linha"><a className="botao-texto" href={`#/conta/${d.conta_id}`}>Ver extrato</a></span>
          </li>
        ))}
      </ul>
    </section>
  );
}

// ------------------------------------------------------------ conciliados e histórico
function Conciliados({ lista }: { lista: Lancamento[] }) {
  if (lista.length === 0) return <p className="vazio">Nada conciliado ainda.</p>;
  return (
    <section className="secao">
      <ul className="lista-simples lista-conciliacao">
        {lista.map((l) => (
          <li key={l.movimento_id}>
            <div>
              <strong>{l.descricao}</strong>
              <span className="texto-suave">{formatarData(l.data_movimento)} · {l.conta}</span>
              <span className={`selo ${l.conciliacao === "pagamento" ? "selo-ok" : "selo-neutro"}`}>
                {l.conciliacao === "pagamento" ? `Paga: ${l.pagamentos}` : l.categoria ?? "Classificado"}
              </span>
            </div>
            <span className="acoes-linha"><Valor centavos={l.valor_centavos} sinal /></span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function HistoricoLista({ lista, aoMudar }: { lista: Historico[]; aoMudar: () => void }) {
  const [desfazendo, setDesfazendo] = useState<Historico | null>(null);
  if (lista.length === 0) return <p className="vazio">Nenhum vínculo registrado ainda.</p>;
  return (
    <section className="secao">
      <ul className="lista-simples lista-conciliacao">
        {lista.map((h) => (
          <li key={h.pagamento_id} className={h.situacao === "desfeito" ? "linha-arquivada" : ""}>
            <div>
              <strong>{h.descricao}</strong> <span className="texto-suave">→ {h.obrigacao}</span>
              <span className="texto-suave">
                {formatarData(h.data_movimento)} · {formatarCentavos(h.valor_centavos)} · {h.origem === "vinculo" ? "vínculo com lançamento existente" : "pagamento registrado no Simplifica"}
              </span>
              {h.situacao === "desfeito" && <span className="selo">Desfeito{h.desfeito_motivo ? `: ${h.desfeito_motivo}` : ""}</span>}
            </div>
            <span className="acoes-linha">
              {h.situacao === "ativo" && h.origem === "vinculo" && (
                <button type="button" className="botao-texto botao-texto-perigo" onClick={() => setDesfazendo(h)}>Desfazer</button>
              )}
            </span>
          </li>
        ))}
      </ul>
      {desfazendo && (
        <Confirmar titulo="Desfazer conciliação" rotuloAcao="Desfazer" perigo pedirMotivo="obrigatorio"
          texto={<p>O lançamento <strong>{desfazendo.descricao}</strong> deixa de pagar <strong>{desfazendo.obrigacao}</strong>, que volta a ficar em aberto. O lançamento continua na conta; nada é apagado e o desfazer fica no histórico.</p>}
          aoFechar={() => setDesfazendo(null)}
          aoConfirmar={async (motivo) => {
            await rpc("pagamento_desfazer", { p_id: desfazendo.pagamento_id, p_versao_esperada: desfazendo.versao, p_motivo: motivo, p_cancelar_lancamento: false, p_chave_idempotencia: null });
            setDesfazendo(null);
            aoMudar();
          }} />
      )}
    </section>
  );
}
