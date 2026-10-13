# Simplifica Finanças V2

Gestão financeira pessoal: Supabase (PostgreSQL, Auth, RLS, Edge Functions) + site React/TypeScript publicado no Netlify.

## Estrutura

```
src/                  site (React + TypeScript, montado com esbuild)
  lib/api.ts          cliente do Supabase (login, RPC, tabelas) via fetch
  lib/dinheiro.ts     valores em centavos (leitura e formatação pt-BR)
  lib/importadores/   leitores de extrato (OFX, CSV, CSV do Nubank, PDF do Itaú) e de fatura (PDF Nubank e Itaú)
  telas/              entrar, saldos, extrato, importar extrato e fatura, contas a pagar, cartões, contas, categorias, resumo, minha conta
supabase/migrations/  banco, na ordem 0001 → 0011 (etapas 1 a 5.4)
supabase/functions/   Edge Functions excluir-conta e limpar-orfaos
validacao/            roteiros de validação no projeto Supabase real
tests/                testes do site (unidade e navegador)
docs/                 evidências de teste e homologação, capturas de tela
```

Regras financeiras ficam no banco; o site só chama as funções validadas.

## Publicação (Netlify)

O Netlify monta o site a cada envio para `main` (`npm run build`, pasta `dist`, Node 22).
Variáveis obrigatórias em **Project configuration → Environment variables**:

| Nome | Valor |
|---|---|
| `SUPABASE_URL` | `https://<projeto>.supabase.co` |
| `SUPABASE_ANON_KEY` | chave pública **anon** (Settings → API Keys → Legacy) |

Sem elas o build para com uma mensagem explicando o que falta.

## Testes locais

```
npm test                                              # dinheiro e datas
node --experimental-strip-types tests/navegador/e2e.mjs   # site num Chromium real (PostgreSQL local)
./supabase/tests/rodar_testes.sh                      # banco
```
