import { useState } from "react";
import { rpc } from "../lib/api";
import { dataValida, formatarData, hoje } from "../lib/datas";
import { centavosParaCampo, formatarCentavos, lerValor } from "../lib/dinheiro";
import { NOMES_TIPO_CONTA, type Conta, type TipoConta, type Titular } from "../lib/tipos";
import { Alerta, Campo, Carregando, Confirmar, Dialogo, TituloPagina, Valor, useCadastros, useEnvio } from "../ui";

type Acao =
  | { tipo: "nova-conta" } | { tipo: "editar-conta"; conta: Conta } | { tipo: "arquivar-conta"; conta: Conta }
  | { tipo: "novo-titular" } | { tipo: "editar-titular"; titular: Titular } | { tipo: "arquivar-titular"; titular: Titular }
  | null;

export function TelaContas() {
  const { contas, titulares, instituicoes, carregando, erro, recarregar } = useCadastros();
  const [acao, setAcao] = useState<Acao>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const concluir = (msg?: string) => { setAcao(null); setAviso(msg ?? null); recarregar(); };
  const nomeInst = (id: string) => instituicoes.find((i) => i.id === id)?.nome ?? "";
  const nomeTit = (id: string) => titulares.find((t) => t.id === id)?.nome ?? "";
  const ordenadas = [...contas].sort((a, b) => Number(b.ativa) - Number(a.ativa));

  return (
    <>
      <TituloPagina titulo="Contas">
        <button type="button" className="botao" onClick={() => setAcao({ tipo: "nova-conta" })}>Nova conta</button>
      </TituloPagina>
      {erro && <Alerta>{erro}</Alerta>}
      {aviso && <Alerta tipo="ok">{aviso}</Alerta>}
      {carregando && contas.length === 0 && <Carregando />}

      {!carregando && contas.length === 0 && (
        <section className="vazio">
          <h2>Nenhuma conta cadastrada</h2>
          <p>Cada conta bancária fica separada, mesmo quando duas são do mesmo banco.</p>
          <button type="button" className="botao" onClick={() => setAcao({ tipo: "nova-conta" })}>Cadastrar conta</button>
        </section>
      )}

      {contas.length > 0 && (
        <div className="tabela-rolagem">
          <table className="tabela">
            <thead>
              <tr><th>Conta</th><th>Titular</th><th className="num">Saldo inicial</th><th>Situação</th><th><span className="sr">Ações</span></th></tr>
            </thead>
            <tbody>
              {ordenadas.map((c) => (
                <tr key={c.id} className={c.ativa ? "" : "linha-arquivada"}>
                  <td>
                    <a className="descricao" href={`#/conta/${c.id}`}>{c.apelido}</a>
                    <span className="texto-suave">{nomeInst(c.instituicao_id)}, {NOMES_TIPO_CONTA[c.tipo].toLowerCase()}{c.numero ? `, nº ${c.numero}` : ""}</span>
                  </td>
                  <td>{nomeTit(c.titular_id)}</td>
                  <td className="num">
                    <Valor centavos={c.saldo_inicial_centavos} />
                    <span className="texto-suave">em {formatarData(c.saldo_inicial_data)}</span>
                  </td>
                  <td>
                    {!c.ativa && <span className="selo">Arquivada</span>}
                    {c.ativa && !c.saldo_inicial_validado && <span className="selo selo-aviso">Saldo inicial a confirmar</span>}
                    {c.ativa && c.saldo_inicial_validado && <span className="selo selo-ok">Saldo confirmado</span>}
                    {c.ativa && !c.incluir_consolidado && <span className="selo selo-neutro">Fora da soma</span>}
                  </td>
                  <td className="acoes-linha">
                    {c.ativa && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar-conta", conta: c })}>Editar</button>}
                    <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "arquivar-conta", conta: c })}>{c.ativa ? "Arquivar" : "Reativar"}</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <section className="secao">
        <div className="titulo-secao">
          <h2>Titulares</h2>
          <button type="button" className="botao-secundario" onClick={() => setAcao({ tipo: "novo-titular" })}>Novo titular</button>
        </div>
        <p className="texto-suave">Pessoas donas das contas, como você e seu cônjuge. Os dados continuam todos na sua conta de acesso.</p>
        <ul className="lista-simples">
          {titulares.map((t) => (
            <li key={t.id} className={t.ativo ? "" : "linha-arquivada"}>
              <span>{t.nome}{t.principal && <span className="selo selo-neutro">Principal</span>}{!t.ativo && <span className="selo">Arquivado</span>}</span>
              <span className="acoes-linha">
                {t.ativo && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "editar-titular", titular: t })}>Renomear</button>}
                {!t.principal && <button type="button" className="botao-texto" onClick={() => setAcao({ tipo: "arquivar-titular", titular: t })}>{t.ativo ? "Arquivar" : "Reativar"}</button>}
              </span>
            </li>
          ))}
        </ul>
      </section>

      {(acao?.tipo === "nova-conta" || acao?.tipo === "editar-conta") && (
        <DialogoConta conta={acao.tipo === "editar-conta" ? acao.conta : undefined} aoFechar={() => setAcao(null)}
          aoConcluir={() => concluir(acao.tipo === "nova-conta" ? "Conta cadastrada." : "Conta atualizada.")} />
      )}
      {acao?.tipo === "arquivar-conta" && (
        <Confirmar
          titulo={acao.conta.ativa ? "Arquivar conta" : "Reativar conta"}
          texto={acao.conta.ativa
            ? <p>{acao.conta.apelido} sai da soma e deixa de aceitar lançamentos. O histórico continua guardado e a conta pode ser reativada.</p>
            : <p>{acao.conta.apelido} volta a aceitar lançamentos e a entrar na soma, se estiver marcada para isso.</p>}
          rotuloAcao={acao.conta.ativa ? "Arquivar" : "Reativar"}
          pedirMotivo="opcional"
          aoFechar={() => setAcao(null)}
          aoConfirmar={async (motivo) => {
            await rpc("conta_definir_ativa", { p_id: acao.conta.id, p_versao_esperada: acao.conta.versao, p_ativa: !acao.conta.ativa, p_motivo: motivo || null, p_chave_idempotencia: null });
            concluir(acao.conta.ativa ? "Conta arquivada." : "Conta reativada.");
          }}
        />
      )}
      {(acao?.tipo === "novo-titular" || acao?.tipo === "editar-titular") && (
        <DialogoTitular titular={acao.tipo === "editar-titular" ? acao.titular : undefined} aoFechar={() => setAcao(null)} aoConcluir={() => concluir()} />
      )}
      {acao?.tipo === "arquivar-titular" && (
        <Confirmar
          titulo={acao.titular.ativo ? "Arquivar titular" : "Reativar titular"}
          texto={acao.titular.ativo
            ? <p>Só é possível arquivar {acao.titular.nome} se nenhuma conta ativa estiver no nome dele.</p>
            : <p>{acao.titular.nome} volta a poder receber contas.</p>}
          rotuloAcao={acao.titular.ativo ? "Arquivar" : "Reativar"}
          aoFechar={() => setAcao(null)}
          aoConfirmar={async () => {
            await rpc("titular_atualizar", { p_id: acao.titular.id, p_versao_esperada: acao.titular.versao, p_nome: acao.titular.nome, p_ativo: !acao.titular.ativo, p_chave_idempotencia: null });
            concluir();
          }}
        />
      )}
    </>
  );
}

function DialogoConta({ conta, aoFechar, aoConcluir }: { conta?: Conta; aoFechar: () => void; aoConcluir: () => void }) {
  const { titulares, instituicoes } = useCadastros();
  const opcoesTitular = titulares.filter((t) => t.ativo || t.id === conta?.titular_id);
  const [titular, setTitular] = useState(conta?.titular_id ?? opcoesTitular[0]?.id ?? "");
  const [instituicao, setInstituicao] = useState(conta?.instituicao_id ?? "");
  const [apelido, setApelido] = useState(conta?.apelido ?? "");
  const [tipo, setTipo] = useState<TipoConta>(conta?.tipo ?? "corrente");
  const [agencia, setAgencia] = useState(conta?.agencia ?? "");
  const [numero, setNumero] = useState(conta?.numero ?? "");
  const [saldo, setSaldo] = useState(conta ? centavosParaCampo(conta.saldo_inicial_centavos) : "");
  const [dataBase, setDataBase] = useState(conta?.saldo_inicial_data ?? hoje());
  const [validado, setValidado] = useState(conta?.saldo_inicial_validado ?? false);
  const [consolidado, setConsolidado] = useState(conta?.incluir_consolidado ?? true);
  const { chave, enviando, erro, setErro, enviar } = useEnvio(conta ? "conta-editar" : "conta-criar");
  const saldoLido = lerValor(saldo);

  return (
    <Dialogo titulo={conta ? "Editar conta" : "Nova conta"} aoFechar={aoFechar} largo>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!titular) return setErro("Escolha o titular.");
        if (!instituicao) return setErro("Escolha o banco.");
        if (!apelido.trim()) return setErro("Dê um nome para a conta, por exemplo Itaú salário.");
        if (saldoLido === null) return setErro("Informe o saldo inicial, por exemplo 1.250,00 (use - para saldo negativo).");
        if (!dataValida(dataBase)) return setErro("Informe a data do saldo inicial.");
        if (dataBase > hoje()) return setErro("A data do saldo inicial não pode ser futura.");
        if (agencia && !/^[0-9A-Za-z-]{1,10}$/.test(agencia.trim())) return setErro("Agência: use só números, letras e hífen (até 10).");
        if (numero && !/^[0-9A-Za-z-]{1,20}$/.test(numero.trim())) return setErro("Número da conta: use só números, letras e hífen (até 20).");
        void enviar(async () => {
          const comum = {
            p_titular_id: titular, p_instituicao_id: instituicao, p_apelido: apelido, p_tipo: tipo,
            p_saldo_inicial_centavos: saldoLido, p_saldo_inicial_data: dataBase,
            p_agencia: agencia.trim() || null, p_numero: numero.trim() || null,
            p_saldo_inicial_validado: validado, p_incluir_consolidado: consolidado, p_chave_idempotencia: chave,
          };
          if (conta) await rpc("conta_atualizar", { p_id: conta.id, p_versao_esperada: conta.versao, ...comum });
          else await rpc("conta_criar", comum);
          aoConcluir();
        });
      }}>
        <div className="grade-2">
          <Campo rotulo="Banco">
            {(id) => (
              <select id={id} required value={instituicao} onChange={(e) => setInstituicao(e.target.value)}>
                <option value="">Escolha…</option>
                {instituicoes.map((i) => <option key={i.id} value={i.id}>{i.nome}</option>)}
              </select>
            )}
          </Campo>
          <Campo rotulo="Tipo">
            {(id) => (
              <select id={id} value={tipo} onChange={(e) => setTipo(e.target.value as TipoConta)}>
                {(Object.keys(NOMES_TIPO_CONTA) as TipoConta[]).map((t) => <option key={t} value={t}>{NOMES_TIPO_CONTA[t]}</option>)}
              </select>
            )}
          </Campo>
        </div>
        <div className="grade-2">
          <Campo rotulo="Nome da conta" ajuda="Como você quer ver a conta na lista.">
            {(id) => <input id={id} required maxLength={80} value={apelido} onChange={(e) => setApelido(e.target.value)} placeholder="Ex.: Itaú salário" />}
          </Campo>
          <Campo rotulo="Titular">
            {(id) => (
              <select id={id} required value={titular} onChange={(e) => setTitular(e.target.value)}>
                {opcoesTitular.map((t) => <option key={t.id} value={t.id}>{t.nome}</option>)}
              </select>
            )}
          </Campo>
        </div>
        <div className="grade-2">
          <Campo rotulo="Agência (opcional)">{(id) => <input id={id} maxLength={10} value={agencia} onChange={(e) => setAgencia(e.target.value)} />}</Campo>
          <Campo rotulo="Número da conta (opcional)">{(id) => <input id={id} maxLength={20} value={numero} onChange={(e) => setNumero(e.target.value)} />}</Campo>
        </div>

        <fieldset className="bloco-saldo">
          <legend>Saldo inicial</legend>
          <p className="campo-ajuda">
            Use o saldo do fim do dia, como aparece no extrato. Lançamentos até essa data já estão dentro desse saldo e não serão somados de novo.
          </p>
          <div className="grade-2">
            <Campo rotulo="Data do saldo">{(id) => <input id={id} type="date" required max={hoje()} value={dataBase} onChange={(e) => setDataBase(e.target.value)} />}</Campo>
            <Campo rotulo="Saldo no fim do dia (R$)" ajuda={saldoLido !== null ? formatarCentavos(saldoLido) : "Ex.: 1.250,00"}>
              {(id) => <input id={id} inputMode="decimal" required value={saldo} onChange={(e) => setSaldo(e.target.value)} />}
            </Campo>
          </div>
          <label className="opcao-check">
            <input type="checkbox" checked={validado} onChange={(e) => setValidado(e.target.checked)} />
            Conferi este saldo no extrato do banco
          </label>
          {!validado && <p className="campo-ajuda">Enquanto não for conferido, a conta aparece com saldo a confirmar e fica fora da soma.</p>}
          {conta && (conta.saldo_inicial_data !== dataBase || conta.saldo_inicial_centavos !== saldoLido) && (
            <Alerta tipo="aviso">Ao mudar o saldo inicial, o saldo da conta é recalculado a partir da nova data. Nenhum lançamento é apagado.</Alerta>
          )}
        </fieldset>

        <label className="opcao-check">
          <input type="checkbox" checked={consolidado} onChange={(e) => setConsolidado(e.target.checked)} />
          Somar esta conta no saldo total
        </label>

        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Cancelar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : conta ? "Salvar alterações" : "Cadastrar conta"}</button>
        </div>
      </form>
    </Dialogo>
  );
}

function DialogoTitular({ titular, aoFechar, aoConcluir }: { titular?: Titular; aoFechar: () => void; aoConcluir: () => void }) {
  const [nome, setNome] = useState(titular?.nome ?? "");
  const { chave, enviando, erro, setErro, enviar } = useEnvio(titular ? "titular-editar" : "titular-criar");
  return (
    <Dialogo titulo={titular ? "Renomear titular" : "Novo titular"} aoFechar={aoFechar}>
      <form className="formulario" onSubmit={(e) => {
        e.preventDefault();
        if (!nome.trim()) return setErro("Escreva o nome.");
        void enviar(async () => {
          if (titular) await rpc("titular_atualizar", { p_id: titular.id, p_versao_esperada: titular.versao, p_nome: nome, p_ativo: titular.ativo, p_chave_idempotencia: chave });
          else await rpc("titular_criar", { p_nome: nome, p_chave_idempotencia: chave });
          aoConcluir();
        });
      }}>
        <Campo rotulo="Nome">{(id) => <input id={id} required maxLength={120} value={nome} onChange={(e) => setNome(e.target.value)} />}</Campo>
        {erro && <Alerta>{erro}</Alerta>}
        <div className="acoes">
          <button type="button" className="botao-secundario" onClick={aoFechar}>Cancelar</button>
          <button type="submit" className="botao" disabled={enviando}>{enviando ? "Salvando…" : "Salvar"}</button>
        </div>
      </form>
    </Dialogo>
  );
}
