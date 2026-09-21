#!/usr/bin/env bash
# Open a local port-forward to the FOODMISSION CNPG primary and print
# ready-to-paste connection details.
#
#   ./tools/db-connect.sh                  # staging, db foodmission, port 5433
#   ./tools/db-connect.sh prod             # prod
#   ./tools/db-connect.sh staging keycloak # keycloak db
#   PORT=5555 ./tools/db-connect.sh
set -euo pipefail

ENV="${1:-staging}"
DB="${2:-foodmission}"
PORT="${PORT:-5432}"

case "$ENV" in
  staging) NS="foodmission-staging"; CLUSTER="foodmission-pg-staging" ;;
  prod)    NS="foodmission-prod";    CLUSTER="foodmission-pg-prod" ;;
  test)    NS="foodmission-test";    CLUSTER="foodmission-pg-test" ;;
  *) echo "unknown env: $ENV (use staging|prod|test)" >&2; exit 1 ;;
esac

SECRET="foodmission-secrets"

# Percent-encode only the characters that are reserved in a URL userinfo
# field; unreserved characters stay readable.
urlencode() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *)               out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

USER=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.password}' | base64 -d)
ENC_PASS=$(urlencode "$PASS")

# Clients that take one URL (Prisma, psql, DBeaver URL mode) — password encoded:
echo "DATABASE_URL=\"postgresql://${USER}:${ENC_PASS}@127.0.0.1:${PORT}/${DB}?sslmode=disable&schema=public\""
echo
# Clients with separate fields (Beekeeper Studio, TablePlus) — password RAW, not encoded:
echo "host      : 127.0.0.1"
echo "port      : ${PORT}"
echo "user      : ${USER}"
echo "password  : ${PASS}"
echo "database  : ${DB}"
echo "namespace : ${NS}"
echo
echo "port-forward on :${PORT} — Ctrl-C to stop"
echo

# kubectl port-forward tears down the whole tunnel whenever any single
# connection errors (e.g. a GUI client reaping an idle pooled socket).
# Restart it until the user interrupts.
trap 'echo; echo "stopped."; exit 0' INT TERM

while true; do
  kubectl -n "$NS" port-forward "svc/${CLUSTER}-rw" "${PORT}:5432" || true
  echo "port-forward dropped, reconnecting in 1s..." >&2
  sleep 1
done
