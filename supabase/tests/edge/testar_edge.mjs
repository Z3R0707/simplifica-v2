// Testes das Edge Functions excluir-conta e limpar-orfaos contra o SQL real
// das migrações (PostgreSQL local) e APIs do Supabase simuladas.
// Uso: node --experimental-strip-types tests/edge/testar_edge.mjs
import { criarSimulador, sql, CHAVES } from "./supabase_simulado.mjs";
import { tratar as excluirConta } from "../../functions/excluir-conta/index.ts";
import { tratar as limparOrfaos } from "../../functions/limpar-orfaos/index.ts";

console.error = () => {}; // registros das funções não poluem a saída do teste
const DB = process.env.TEST_DB ?? "simplifica_teste_local";
let falhas = 0, oks = 0;
function igual(obtido, esperado, nome) {
  if (JSON.stringify(obtido) !== JSON.stringify(esperado)) {
    falhas++;
    console.log(`FALHOU: ${nome} — esperado ${JSON.stringify(esperado)}, obtido ${JSON.stringify(obtido)}`);
  } else { oks++; console.log(`  OK: ${nome}`); }
}
const q = (c) => sql(DB, c);
const n = (c) => Number(q(c));

const env = { SUPABASE_URL: "http://supabase.local", SUPABASE_ANON_KEY: CHAVES.ANON, SUPABASE_SERVICE_ROLE_KEY: CHAVES.SERVICE };
const pedido = (token, corpo, metodo = "POST") => new Request("http://fn.local/excluir-conta", {
  method: metodo,
  headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), "Content-Type": "application/json", Origin: "http://localhost:5173" },
  body: metodo === "POST" ? (typeof corpo === "string" ? corpo : JSON.stringify(corpo)) : undefined,
});

// ------------------------------------------------------------------ preparação
const eva = q(`select teste.novo_usuario('eva@exemplo.com', 'Eva')`);
const fabio = q(`select teste.novo_usuario('fabio@exemplo.com', 'Fabio')`);
// 1.500 arquivos da Eva (exige mais de um lote de 1.000) em subpastas + 1 em outro bucket
q(`insert into storage.objects (bucket_id, name)
   select 'documentos', '${eva}/' || case when i % 2 = 0 then 'faturas/' else 'extratos/2026/' end || 'arq-' || i || '.pdf'
     from generate_series(1, 1500) i`);
q(`insert into storage.objects (bucket_id, name) values ('outro-bucket', '${eva}/anexo.png')`);
q(`insert into storage.objects (bucket_id, name) values ('documentos', '${fabio}/manter.pdf')`);
const arquivosEva = () => n(`select count(*) from storage.objects where name like '${eva}/%'`);
igual(arquivosEva(), 1501, "preparação: Eva com 1.501 arquivos");

// ------------------------------------------------------------- excluir-conta
{
  const sim = criarSimulador(DB);
  let r = await excluirConta(new Request("http://fn.local", { method: "OPTIONS", headers: { Origin: "http://localhost:5173" } }), env, sim.fetch);
  igual(r.status, 204, "CORS: preflight respondido");

  r = await excluirConta(pedido(null, { confirmacao_email: "eva@exemplo.com" }), env, sim.fetch);
  igual(r.status, 401, "sem sessão: 401");
  r = await excluirConta(pedido("token-falso", { confirmacao_email: "eva@exemplo.com" }), env, sim.fetch);
  igual(r.status, 401, "token inválido: 401");
  r = await excluirConta(pedido(`usuario:${eva}`, "{nao-json"), env, sim.fetch);
  igual(r.status, 400, "corpo inválido: 400");

  for (const [corpo, nome] of [
    [{}, "campo ausente (NULL)"], [{ confirmacao_email: null }, "NULL explícito"],
    [{ confirmacao_email: "" }, "vazio"], [{ confirmacao_email: "   " }, "só espaços"],
    [{ confirmacao_email: 123 }, "tipo errado"], [{ confirmacao_email: "eva@exemplo.co" }, "divergente"],
    [{ confirmacao_email: "fabio@exemplo.com" }, "e-mail de outro usuário"],
  ]) {
    r = await excluirConta(pedido(`usuario:${eva}`, corpo), env, sim.fetch);
    igual(r.status, 400, `confirmação ${nome}: rejeitada (400)`);
  }
  igual(n(`select count(*) from public.exclusoes_conta where user_id = '${eva}'`), 0, "nenhuma solicitação criada pelas confirmações inválidas");
  igual(sim.estado.chamadasStorage, 0, "nenhum arquivo tocado pelas confirmações inválidas");
  igual(arquivosEva(), 1501, "arquivos intactos após confirmações inválidas");
}

// Falha do Storage no meio: nada é apagado do banco, solicitação fica em falha
{
  const sim = criarSimulador(DB, { falharStorageNaChamada: 2 });
  const r = await excluirConta(pedido(`usuario:${eva}`, { confirmacao_email: "Eva@Exemplo.com" }), env, sim.fetch);
  const corpo = await r.json();
  igual(r.status, 503, "falha do Storage no 2º lote: 503 (exclusão pendente)");
  igual(corpo.arquivos_removidos, 1000, "1º lote (1.000 arquivos) removido antes da falha");
  igual(q(`select status from public.exclusoes_conta where user_id = '${eva}'`), "falha", "solicitação registrada como falha");
  igual(n(`select arquivos_removidos from public.exclusoes_conta where user_id = '${eva}'`), 1000, "progresso parcial registrado");
  igual(n(`select count(*) from auth.users where id = '${eva}'`), 1, "login preservado (não há órfãos: dono ainda existe)");
  igual(n(`select count(*) from public.titulares where user_id = '${eva}'`), 1, "dados preservados após falha");
  igual(arquivosEva(), 501, "501 arquivos restantes aguardando retomada");
  // durante a pendência, a Eva não envia novos arquivos
  let bloqueado = false;
  try { q(`set role authenticated; set "request.jwt.claim.sub" = '${eva}'; insert into storage.objects (bucket_id, name) values ('documentos', '${eva}/novo.pdf')`); }
  catch (e) { bloqueado = e.code === "42501"; }
  igual(bloqueado, true, "novos envios bloqueados enquanto a exclusão está pendente");
}

// Retomada: conclui, remove tudo, sem órfãos
{
  const sim = criarSimulador(DB);
  const r = await excluirConta(pedido(`usuario:${eva}`, { confirmacao_email: "eva@exemplo.com" }), env, sim.fetch);
  const corpo = await r.json();
  igual(r.status, 200, "retomada: 200");
  igual(corpo, { status: "concluida", arquivos_removidos: 501 }, "retomada remove os 501 restantes e conclui");
  igual(arquivosEva(), 0, "NENHUM arquivo da Eva restante (todos os buckets)");
  igual(n(`select count(*) from auth.users where id = '${eva}'`), 0, "login da Eva removido");
  igual(n(`select (select count(*) from public.perfis where id = '${eva}') + (select count(*) from public.titulares where user_id = '${eva}')
             + (select count(*) from public.categorias where user_id = '${eva}') + (select count(*) from public.auditoria where user_id = '${eva}')`), 0,
        "dados e auditoria da Eva removidos");
  igual(q(`select status || ':' || arquivos_removidos from public.exclusoes_conta where user_id = '${eva}'`), "concluida:1501", "comprovante: concluída com 1.501 arquivos removidos");
  igual(n(`select count(*) from storage.objects where name like '${fabio}/%'`), 1, "arquivo de outro usuário intacto");
  igual(n(`select count(*) from auth.users where id = '${fabio}'`), 1, "outro usuário intacto");

  const r2 = await excluirConta(pedido(`usuario:${eva}`, { confirmacao_email: "eva@exemplo.com" }), env, sim.fetch);
  igual(r2.status, 401, "token antigo após exclusão: 401");
}

// ------------------------------------------------------------- limpar-orfaos
{
  const segredo = "segredo-de-manutencao-com-32-caracteres!";
  const envM = { SUPABASE_URL: env.SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY: CHAVES.SERVICE, MANUTENCAO_SEGREDO: segredo };
  q(`insert into storage.objects (bucket_id, name) select 'documentos', '11111111-2222-3333-4444-555555555555/perdido-' || i || '.pdf' from generate_series(1, 3) i`);
  const antes = n(`select count(*) from storage.objects`);
  const req = (s, corpo) => new Request("http://fn.local/limpar-orfaos", { method: "POST",
    headers: s ? { "x-segredo-manutencao": s } : {}, body: corpo ? JSON.stringify(corpo) : undefined });
  const sim = criarSimulador(DB);

  let r = await limparOrfaos(req(null), envM, sim.fetch);
  igual(r.status, 401, "órfãos: sem segredo, 401");
  r = await limparOrfaos(req("errado"), envM, sim.fetch);
  igual(r.status, 401, "órfãos: segredo errado, 401");
  r = await limparOrfaos(req(segredo), { ...envM, MANUTENCAO_SEGREDO: "curto" }, sim.fetch);
  igual(r.status, 401, "órfãos: segredo fraco configurado é recusado");

  r = await limparOrfaos(req(segredo), envM, sim.fetch);
  const sim1 = await r.json();
  igual([r.status, sim1.simulacao, sim1.encontrados], [200, true, 4], "órfãos: simulação lista 4 (3 novos + 1 do teste SQL) sem apagar");
  igual(n(`select count(*) from storage.objects`), antes, "órfãos: simulação não apaga nada");

  r = await limparOrfaos(req(segredo, { executar: true }), envM, sim.fetch);
  const exec = await r.json();
  igual([r.status, exec.removidos], [200, 4], "órfãos: execução remove os 4");
  igual(n(`select count(*) from storage.objects`), antes - 4, "órfãos: só os órfãos foram removidos");
  igual(n(`select count(*) from storage.objects where name like '${fabio}/%'`), 1, "órfãos: arquivo de usuário existente preservado");
}

console.log(falhas === 0 ? `== Edge Functions: ${oks} verificações aprovadas ==` : `== Edge Functions: ${falhas} FALHA(S) ==`);
process.exit(falhas === 0 ? 0 : 1);
