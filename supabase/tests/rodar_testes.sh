#!/usr/bin/env bash
# Recria um banco de teste local, aplica as migrações na ordem e roda os testes.
# Uso: PGHOST=/tmp PGPORT=5433 PGUSER=postgres ./rodar_testes.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="${TEST_DB:-simplifica_teste_local}"
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
# papéis são globais no cluster: recria do zero
psql -q -d postgres -c "drop role if exists anon" -c "drop role if exists authenticated" -c "drop role if exists service_role" 2>/dev/null || true
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$DIR/tests/00_stub_supabase.sql"
for f in "$DIR"/migrations/*.sql; do
  echo "-- aplicando $(basename "$f")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" > /dev/null
done
falhas=0
for t in $(ls "$DIR"/tests/*.sql | grep -v 00_stub | sort); do
  echo "-- testes $(basename "$t")"
  if saida=$(psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$t" 2>&1); then st=0; else st=$?; falhas=1; fi
  echo "$saida" | grep -E "OK:|FALHOU|ERROR|ERRO|==" | sed "s/^psql:[^ ]* NOTICE:  /  /" || true
  [ $st -ne 0 ] && echo "!! $(basename "$t") interrompido com erro (código $st)"
done
echo "-- testes Edge Functions (node + SQL real)"
if ! TEST_DB="$DB" node --experimental-strip-types --no-warnings "$DIR/tests/edge/testar_edge.mjs"; then falhas=1; fi
echo "-- teste da página de validação (Chromium + SQL real)"
if [ -d "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}" ]; then
  if ! PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}" TEST_DB="$DB" node --experimental-strip-types --no-warnings "$DIR/tests/navegador/testar_pagina.mjs"; then falhas=1; fi
else
  echo "   (pulado: navegador Playwright não instalado neste computador)"
fi
if [ $falhas -ne 0 ]; then echo "== RESULTADO: FALHOU =="; exit 1; fi
echo "== RESULTADO: todos os testes passaram =="
