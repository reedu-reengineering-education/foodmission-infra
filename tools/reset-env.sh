#!/usr/bin/env bash
# Reset a FOODMISSION environment to a fresh state: empty app database
# (re-migrated + re-seeded) and no Keycloak realm users.
#
#   ./tools/reset-env.sh staging            # dry run: show what would be wiped
#   ./tools/reset-env.sh prod               # dry run against prod
#   ./tools/reset-env.sh prod --execute     # actually do it (asks for confirmation)
#
# What --execute does, in order:
#   1. On-demand CNPG backup to S3 (skipped if the cluster has no barman-cloud
#      plugin, e.g. test) + local pg_dump of foodmission and keycloak
#   2. Pause ArgoCD auto-sync (selfHeal would undo step 3)
#   3. Scale api + dashboard to 0
#   4. Delete all Keycloak users in the realm, except service-account-* users,
#      and clear the realm's login/admin event history
#   5. DROP SCHEMA public CASCADE on the foodmission database
#   6. FLUSHALL on Valkey
#   7. ArgoCD sync via tools/rerun-hooks.sh: PreSync migrate, deployments back,
#      PostSync seed + translations
#   8. Restore ArgoCD auto-sync
#
# Kept: CNPG cluster + replicas + backup chain, keycloak database (realm,
# clients, keys), the service-account user, master realm admin.
#
# If the script dies after step 2, auto-sync stays paused on purpose so Argo
# does not bring the API back against a half-reset database. The exit message
# says how to resume.
set -euo pipefail

ENV="${1:-}"
MODE="${2:-}"

case "$ENV" in
  staging|prod|test) ;;
  *) echo "usage: $0 staging|prod|test [--execute]" >&2; exit 1 ;;
esac
case "$MODE" in
  "")        EXECUTE=false ;;
  --execute) EXECUTE=true ;;
  *) echo "unknown option: $MODE" >&2; exit 1 ;;
esac

NS="foodmission-${ENV}"
CLUSTER="foodmission-pg-${ENV}"
RELEASE="foodmission-${ENV}"   # ArgoCD app name == Helm release name
APP_DB="foodmission"
KC_DB="keycloak"
SECRET="foodmission-secrets"
ARGO_NS="argocd"
KC_PORT="${KC_PORT:-18080}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$HOME/foodmission-reset/${ENV}-${TS}}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- cleanup / failure handling ------------------------------------------------

PF_PID=""
ARGO_PAUSED=false
DONE=false

on_exit() {
  local rc=$?
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  if $ARGO_PAUSED && ! $DONE; then
    cat >&2 <<EOF

!!! Script stopped with ArgoCD auto-sync PAUSED for ${RELEASE} (exit ${rc}).
!!! API/dashboard may be scaled to 0. Fix the cause, then either re-run, or
!!! resume manually:
!!!   kubectl -n ${ARGO_NS} patch application ${RELEASE} --type merge \\
!!!     -p '{"spec":{"syncPolicy":{"automated":$(cat "$OUT_DIR/argo-automated.json" 2>/dev/null || echo '{"prune":false,"selfHeal":true}')}}}'
!!! Backups are in ${OUT_DIR}
EOF
  fi
}
trap on_exit EXIT

# --- helpers -------------------------------------------------------------------

secret_val() {
  kubectl -n "$NS" get secret "$SECRET" -o jsonpath="{.data.$1}" | base64 -d
}

# Run SQL from stdin as postgres superuser on the current primary.
psql_exec() {
  kubectl -n "$NS" exec -i "$PRIMARY" -c postgres -- \
    psql -X -q -v ON_ERROR_STOP=1 -At -d "$1"
}

kc_token() {
  curl -sf \
    -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=${KC_ADMIN_USER}" \
    --data-urlencode "password=${KC_ADMIN_PASS}" \
    "http://127.0.0.1:${KC_PORT}/realms/master/protocol/openid-connect/token" \
    | jq -r .access_token
}

kc_get() {
  curl -sf -H "Authorization: Bearer $(kc_token)" "http://127.0.0.1:${KC_PORT}/admin/realms/${KC_REALM}$1"
}

start_kc_port_forward() {
  kubectl -n "$NS" port-forward "deploy/${RELEASE}-keycloak" "${KC_PORT}:8080" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:${KC_PORT}/realms/master" && return 0
    sleep 1
  done
  die "Keycloak port-forward on :${KC_PORT} did not come up"
}

argo_app() { kubectl -n "$ARGO_NS" get application "$RELEASE" -o json; }

# --- preflight -----------------------------------------------------------------

log "Preflight"
for bin in kubectl jq curl; do
  command -v "$bin" >/dev/null || die "$bin not found"
done

info "kube context : $(kubectl config current-context)"
info "namespace    : $NS"
info "cluster      : $CLUSTER"
info "argo app     : $ARGO_NS/$RELEASE"

PHASE=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}')
[[ "$PHASE" == "Cluster in healthy state" ]] || die "CNPG cluster not healthy: $PHASE"
PRIMARY=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
info "primary      : $PRIMARY"

# S3 backup only if the cluster archives through the barman-cloud plugin
if kubectl -n "$NS" get cluster "$CLUSTER" -o json \
  | jq -e '.spec.plugins[]? | select(.name == "barman-cloud.cloudnative-pg.io")' >/dev/null; then
  HAS_S3_BACKUP=true
else
  HAS_S3_BACKUP=false
fi
info "s3 backup    : $HAS_S3_BACKUP$($HAS_S3_BACKUP || echo ' (local pg_dump only)')"

argo_app >/dev/null || die "ArgoCD application $RELEASE not found"
ARGO_AUTOMATED=$(argo_app | jq -c '.spec.syncPolicy.automated // empty')
info "argo auto    : ${ARGO_AUTOMATED:-<none>}"

KC_REALM=$(kubectl -n "$NS" get configmap "${RELEASE}-config" \
  -o jsonpath='{.data.KEYCLOAK_REALM}' 2>/dev/null)
[[ -n "$KC_REALM" ]] || KC_REALM=$(secret_val KEYCLOAK_REALM)   # pre-ConfigMap deploys
KC_ADMIN_USER=$(kubectl -n "$NS" get deploy "${RELEASE}-keycloak" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KEYCLOAK_ADMIN")].value}')
KC_ADMIN_PASS=$(secret_val KEYCLOAK_ADMIN_PASSWORD)
[[ -n "$KC_REALM" && -n "$KC_ADMIN_USER" && -n "$KC_ADMIN_PASS" ]] || die "Keycloak realm/admin credentials missing"
info "kc realm     : $KC_REALM (admin user: $KC_ADMIN_USER)"

SCALE_SELECTOR='app.kubernetes.io/component in (api,dashboard)'
SCALE_TARGETS=$(kubectl -n "$NS" get deploy -l "$SCALE_SELECTOR" -o name)
info "will scale 0 : $(echo $SCALE_TARGETS)"

VALKEY_STS="${RELEASE}-valkey-primary"
if kubectl -n "$NS" get sts "$VALKEY_STS" >/dev/null 2>&1; then HAS_VALKEY=true; else HAS_VALKEY=false; fi
info "valkey       : $HAS_VALKEY"

# --- inventory: what would be wiped --------------------------------------------

log "App database '${APP_DB}': tables with rows (estimated)"
psql_exec "$APP_DB" <<'SQL' | sed 's/^/    /'
SELECT relname || ': ' || n_live_tup FROM pg_stat_user_tables
WHERE schemaname = 'public' AND n_live_tup > 0 ORDER BY n_live_tup DESC;
SQL

EXTENSIONS_BEFORE=$(psql_exec "$APP_DB" <<'SQL'
SELECT string_agg(extname, ' ' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql';
SQL
)
info "extensions: ${EXTENSIONS_BEFORE:-<none>}"
info "(DROP SCHEMA CASCADE drops extensions living in public; migrations must recreate them)"

log "Keycloak realm '${KC_REALM}': users to delete"
start_kc_port_forward
kc_token >/dev/null || die "Keycloak admin login failed"
KC_COUNT=$(kc_get "/users/count")
KC_USERS_JSON=$(kc_get "/users?first=0&max=100000&briefRepresentation=true")
[[ "$(jq length <<<"$KC_USERS_JSON")" -ge "$KC_COUNT" ]] || die "user listing truncated ($KC_COUNT users)"
DELETE_IDS=$(jq -r '.[] | select(.username | startswith("service-account-") | not) | .id' <<<"$KC_USERS_JSON")
jq -r '.[] | (if (.username | startswith("service-account-")) then "KEEP   " else "DELETE " end) + .username + "  <" + (.email // "") + ">"' \
  <<<"$KC_USERS_JSON" | sed 's/^/    /'
info "total: $(grep -c . <<<"$DELETE_IDS" || true) to delete"

if ! $EXECUTE; then
  log "Dry run only. Nothing changed. Re-run with --execute to reset ${ENV}."
  DONE=true
  exit 0
fi

# --- confirmation --------------------------------------------------------------

printf '\n\033[31mThis permanently deletes all app data and Keycloak users in %s.\033[0m\n' "$ENV"
read -r -p "Type 'reset ${ENV}' to continue: " CONFIRM
[[ "$CONFIRM" == "reset ${ENV}" ]] || die "aborted"

mkdir -p "$OUT_DIR"

# --- 1. backups ----------------------------------------------------------------

BACKUP_NAME="pre-reset-${TS}"
if $HAS_S3_BACKUP; then
  log "1/8 Backups -> S3 + ${OUT_DIR}"
  kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${NS}
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: ${CLUSTER}
EOF
else
  log "1/8 Backups -> ${OUT_DIR} (no S3 backup configured for ${CLUSTER})"
fi

for db in "$APP_DB" "$KC_DB"; do
  info "pg_dump $db"
  kubectl -n "$NS" exec "$PRIMARY" -c postgres -- pg_dump -Fc -d "$db" > "$OUT_DIR/${db}.dump"
  [[ -s "$OUT_DIR/${db}.dump" ]] || die "pg_dump of $db is empty"
done
ls -lh "$OUT_DIR" | sed 's/^/    /'

if $HAS_S3_BACKUP; then
  info "waiting for S3 backup ${BACKUP_NAME}"
  for _ in $(seq 1 180); do
    BPHASE=$(kubectl -n "$NS" get backup "$BACKUP_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$BPHASE" in
      completed) break ;;
      failed) die "S3 backup failed: $(kubectl -n "$NS" get backup "$BACKUP_NAME" -o jsonpath='{.status.error}')" ;;
    esac
    sleep 10
  done
  [[ "$BPHASE" == "completed" ]] || die "S3 backup not completed after 30m (phase: ${BPHASE:-none})"
  info "S3 backup completed"
fi

# --- 2. pause argo --------------------------------------------------------------

log "2/8 Pause ArgoCD auto-sync"
echo "${ARGO_AUTOMATED:-null}" > "$OUT_DIR/argo-automated.json"
ARGO_PAUSED=true
kubectl -n "$ARGO_NS" patch application "$RELEASE" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null

# --- 3. scale down --------------------------------------------------------------

log "3/8 Scale api/dashboard to 0"
if [[ -n "$SCALE_TARGETS" ]]; then
  kubectl -n "$NS" scale $SCALE_TARGETS --replicas=0
  for _ in $(seq 1 36); do
    [[ -z "$(kubectl -n "$NS" get pod -l "$SCALE_SELECTOR" -o name)" ]] && break
    sleep 5
  done
  [[ -z "$(kubectl -n "$NS" get pod -l "$SCALE_SELECTOR" -o name)" ]] || die "api/dashboard pods still running"
fi

# --- 4. keycloak users -----------------------------------------------------------

log "4/8 Delete Keycloak users"
n=0; failed=0
TOKEN=""
while read -r id; do
  [[ -z "$id" ]] && continue
  # master admin tokens live ~60s; refresh often
  (( n % 20 == 0 )) && TOKEN=$(kc_token)
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "http://127.0.0.1:${KC_PORT}/admin/realms/${KC_REALM}/users/${id}")
  [[ "$code" == "204" ]] || { failed=$((failed + 1)); info "delete $id -> HTTP $code"; }
  n=$((n + 1))
done <<<"$DELETE_IDS"
info "deleted $((n - failed))/$n users"
(( failed == 0 )) || die "$failed Keycloak deletions failed"

TOKEN=$(kc_token)
curl -sf -X DELETE -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${KC_PORT}/admin/realms/${KC_REALM}/events"
curl -sf -X DELETE -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${KC_PORT}/admin/realms/${KC_REALM}/admin-events"
info "cleared login + admin events"

# --- 5. wipe app schema ---------------------------------------------------------

log "5/8 Wipe ${APP_DB}.public"
APP_OWNER=$(psql_exec "$APP_DB" <<<"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database();")
psql_exec "$APP_DB" <<SQL
DROP SCHEMA public CASCADE;
CREATE SCHEMA public AUTHORIZATION "${APP_OWNER}";
SQL
info "public schema recreated, owner ${APP_OWNER}"

# --- 6. valkey ------------------------------------------------------------------

log "6/8 Flush Valkey"
if $HAS_VALKEY; then
  kubectl -n "$NS" exec "sts/${VALKEY_STS}" -- valkey-cli FLUSHALL
else
  info "no valkey, skipped"
fi

# --- 7. argo sync (migrate, deploy, seed) ---------------------------------------

log "7/8 ArgoCD sync (migrate -> deploy -> seed -> translations)"
# Argo auto-sync stays paused; rerun-hooks.sh triggers its own hook sync
"$(dirname "$0")/rerun-hooks.sh" "$ENV" --yes

# --- 8. restore argo ------------------------------------------------------------

log "8/8 Restore ArgoCD auto-sync"
kubectl -n "$ARGO_NS" patch application "$RELEASE" --type merge \
  -p "{\"spec\":{\"syncPolicy\":{\"automated\":${ARGO_AUTOMATED:-null}}}}" >/dev/null
ARGO_PAUSED=false

# --- verify ---------------------------------------------------------------------

log "Verify"
for d in $SCALE_TARGETS; do
  kubectl -n "$NS" rollout status "$d" --timeout=300s
done

EXTENSIONS_AFTER=$(psql_exec "$APP_DB" <<'SQL'
SELECT string_agg(extname, ' ' ORDER BY extname) FROM pg_extension WHERE extname <> 'plpgsql';
SQL
)
if [[ "$EXTENSIONS_AFTER" != "$EXTENSIONS_BEFORE" ]]; then
  info "WARNING extensions differ. before: '${EXTENSIONS_BEFORE}' after: '${EXTENSIONS_AFTER}'"
else
  info "extensions match: ${EXTENSIONS_AFTER:-<none>}"
fi
info "keycloak users left: $(kc_get "/users/count")"

DONE=true
log "Done. ${ENV} reset. Backups: ${OUT_DIR}$($HAS_S3_BACKUP && echo " + S3 backup ${BACKUP_NAME}")"
