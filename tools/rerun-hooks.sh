#!/usr/bin/env bash
# Re-run the chart's hook Jobs (migrate -> seed -> translations) for a
# FOODMISSION environment through an ArgoCD hook sync, and check that they
# really ran.
#
#   ./tools/rerun-hooks.sh staging          # asks for confirmation
#   ./tools/rerun-hooks.sh prod --yes       # no prompt (used by reset-env.sh)
#
# Why not a plain "Sync" in the UI or `argocd app sync`: Argo CD (seen on
# v3.4.1) merges a new operation into the previous status.operationState. A
# leftover partial self-heal sync (sync.resources) or completed hook Jobs from
# an earlier sync make Argo skip the hooks while still reporting Succeeded.
# This script clears both first, then checks the result afterwards.
set -euo pipefail

ENV="${1:-}"
MODE="${2:-}"

case "$ENV" in
  staging|prod|test) ;;
  *) echo "usage: $0 staging|prod|test [--yes]" >&2; exit 1 ;;
esac
case "$MODE" in
  "")    CONFIRM=true ;;
  --yes) CONFIRM=false ;;
  *) echo "unknown option: $MODE" >&2; exit 1 ;;
esac

NS="foodmission-${ENV}"
CLUSTER="foodmission-pg-${ENV}"
RELEASE="foodmission-${ENV}"   # ArgoCD app name == Helm release name
APP_DB="foodmission"
ARGO_NS="argocd"
HOOK_SELECTOR='app.kubernetes.io/component in (db-migration,db-seed,db-translations)'
TIMEOUT_MIN="${TIMEOUT_MIN:-90}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

argo_app() { kubectl -n "$ARGO_NS" get application "$RELEASE" -o json; }

# --- preflight -----------------------------------------------------------------

log "Preflight"
for bin in kubectl jq; do
  command -v "$bin" >/dev/null || die "$bin not found"
done

info "kube context : $(kubectl config current-context)"
info "argo app     : $ARGO_NS/$RELEASE"
APP=$(argo_app) || die "ArgoCD application $RELEASE not found"
info "revision     : $(jq -r '.status.sync.revisions // [.status.sync.revision] | join(", ")' <<<"$APP")"
info "auto-sync    : $(jq -c '.spec.syncPolicy.automated // "off"' <<<"$APP")"
[[ "$(jq -r '.operation // empty' <<<"$APP")" == "" ]] || die "an operation is already queued on $RELEASE"
[[ "$(jq -r '.status.operationState.phase // ""' <<<"$APP")" != "Running" ]] \
  || die "a sync is already running on $RELEASE, wait for it to finish"

PRIMARY=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
[[ -n "$PRIMARY" ]] || die "no CNPG primary for $CLUSTER"

info "hook jobs to replace:"
kubectl -n "$NS" get job -l "$HOOK_SELECTOR" 2>&1 | sed 's/^/      /'

if $CONFIRM; then
  printf '\nRe-runs migrate, seed and translations against %s.\n' "$ENV"
  read -r -p "Type 'rerun ${ENV}' to continue: " ANSWER
  [[ "$ANSWER" == "rerun ${ENV}" ]] || die "aborted"
fi

# --- sync ----------------------------------------------------------------------

log "ArgoCD hook sync (migrate -> deploy -> seed -> translations)"
kubectl -n "$NS" delete job -l "$HOOK_SELECTOR" --ignore-not-found --wait=true
kubectl -n "$ARGO_NS" patch application "$RELEASE" --type merge \
  -p '{"status":{"operationState":null}}' >/dev/null
kubectl -n "$ARGO_NS" patch application "$RELEASE" --type merge -p '{
  "operation": {
    "initiatedBy": {"username": "tools/rerun-hooks.sh"},
    "sync": {"prune": false, "syncStrategy": {"hook": {}}}
  }
}' >/dev/null

# With operationState cleared, the first startedAt seen belongs to our sync
OPHASE=""
for _ in $(seq 1 $((TIMEOUT_MIN * 4))); do
  sleep 15
  STATE=$(argo_app | jq -c '.status.operationState // {}')
  [[ -z "$(jq -r '.startedAt // ""' <<<"$STATE")" ]] && continue
  if jq -e '.operation.sync.resources // empty' <<<"$STATE" >/dev/null; then
    die "Argo turned this into a partial sync, hooks will not run: $(jq -c .operation.sync.resources <<<"$STATE")"
  fi
  OPHASE=$(jq -r '.phase // ""' <<<"$STATE")
  case "$OPHASE" in
    Succeeded) break ;;
    Failed|Error) die "Argo sync $OPHASE: $(jq -r .message <<<"$STATE")" ;;
  esac
  info "sync ${OPHASE}: $(jq -r '.message // ""' <<<"$STATE" | head -c 120)"
done
[[ "$OPHASE" == "Succeeded" ]] || die "Argo sync did not finish in ${TIMEOUT_MIN}m"

# --- verify --------------------------------------------------------------------

log "Verify"
TABLES=$(kubectl -n "$NS" exec -i "$PRIMARY" -c postgres -- \
  psql -X -q -At -d "$APP_DB" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")
(( TABLES > 0 )) || die "Argo sync succeeded but ${APP_DB}.public is empty: hooks did not run"
# Hook Jobs were deleted above, so any that exist now ran in this sync
for c in db-migration db-seed; do
  kubectl -n "$NS" get job -l "app.kubernetes.io/component=$c" -o name | grep -q . \
    || die "Argo sync succeeded but the $c hook did not run"
done
info "${TABLES} tables in ${APP_DB}.public"
kubectl -n "$NS" get job -l "$HOOK_SELECTOR" | sed 's/^/    /'
log "Done. Hooks re-ran on ${ENV}."
