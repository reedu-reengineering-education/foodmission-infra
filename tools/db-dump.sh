#!/usr/bin/env bash
# Save a pg_dump (custom format) of a FOODMISSION environment's database to
# this machine. The filename records what the dump is compatible with:
#
#   <UTC timestamp>_<env>_<db>_api-<tag>_mig-<last prisma migration>_pg<major>.dump
#   <UTC timestamp>_<env>_keycloak_kc-<tag>_pg<major>.dump
#
# e.g. 20261031T142233Z_staging_foodmission_api-1.0.0_mig-20261022120000_pg18.dump
#
# Timestamp first so a plain `ls` lists dumps chronologically.
#
# A <same name>.meta.txt next to it holds the full image refs/digests, the
# migration name, kube context, sha256 and a restore hint.
#
#   ./tools/db-dump.sh staging                    # foodmission + keycloak dbs
#   ./tools/db-dump.sh prod keycloak              # keycloak db only
#   OUT_DIR=/tmp/dumps ./tools/db-dump.sh test
#
# Read-only against the cluster: runs pg_dump on the CNPG primary via
# kubectl exec, nothing is scaled or paused.
set -euo pipefail

ENV="${1:-}"
shift || true
DBS=("$@")
[[ ${#DBS[@]} -gt 0 ]] || DBS=(foodmission keycloak)

case "$ENV" in
  staging|prod|test|pr-[0-9]*) ;;
  *) echo "usage: $0 staging|prod|test|pr-<N> [db ...]   (default: foodmission keycloak)" >&2; exit 1 ;;
esac

NS="foodmission-${ENV}"
CLUSTER="foodmission-pg-${ENV}"
RELEASE="foodmission-${ENV}"
OUT_DIR="${OUT_DIR:-$HOME/foodmission-dumps}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

PARTIAL=""
trap '[[ -n "$PARTIAL" ]] && rm -f "$PARTIAL"' EXIT

# Run SQL as postgres superuser on the primary, one value per line.
psql_val() {
  kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -q -At -d "$1" -c "$2"
}

# Full image ref of a deployment's first container.
deploy_image() {
  kubectl -n "$NS" get deploy "${RELEASE}-$1" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

# Digest of the image the running pods actually pulled (tags like latest/main move).
running_digest() {
  kubectl -n "$NS" get pod -l "app.kubernetes.io/component=$1" \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null \
    | sed -n 's/.*@sha256:\([0-9a-f]*\).*/\1/p'
}

# "<tag>" for the filename; mutable tags (no digit, e.g. latest/main) get the
# short running digest appended so the dump still pins a build.
version_label() {
  local image="$1" component="$2" tag digest
  tag="${image##*:}"
  [[ "$image" == *@* || "$tag" == "$image" || "$tag" == */* ]] && tag="untagged"
  if [[ ! "$tag" =~ [0-9] ]]; then
    digest=$(running_digest "$component")
    [[ -n "$digest" ]] && tag="${tag}-${digest:0:12}"
  fi
  printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '-'
}

# --- preflight -----------------------------------------------------------------

log "Preflight"
command -v kubectl >/dev/null || die "kubectl not found"

info "kube context : $(kubectl config current-context)"
info "namespace    : $NS"
info "cluster      : $CLUSTER"

PHASE=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}') \
  || die "CNPG cluster $CLUSTER not found in $NS"
[[ "$PHASE" == "Cluster in healthy state" ]] || info "WARNING: CNPG cluster phase: $PHASE"
PRIMARY=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
[[ -n "$PRIMARY" ]] || die "no primary for $CLUSTER"
info "primary      : $PRIMARY"

PG_VERSION=$(psql_val postgres 'SHOW server_version' | awk '{print $1}')
PG_MAJOR="${PG_VERSION%%.*}"
info "postgres     : $PG_VERSION"

API_IMAGE=$(deploy_image api)
API_LABEL=$(version_label "$API_IMAGE" api)
info "api image    : ${API_IMAGE:-<none>}"

KC_IMAGE=$(deploy_image keycloak)
KC_LABEL=$(version_label "$KC_IMAGE" keycloak)
info "kc image     : ${KC_IMAGE:-<none>}"

mkdir -p "$OUT_DIR"

# --- dumps ---------------------------------------------------------------------

for db in "${DBS[@]}"; do
  log "Dump $db"

  [[ "$(psql_val postgres "SELECT 1 FROM pg_database WHERE datname = '$db'")" == 1 ]] \
    || die "database $db does not exist on $CLUSTER"

  MIGRATION=""
  if [[ "$(psql_val "$db" "SELECT to_regclass('public._prisma_migrations') IS NOT NULL")" == t ]]; then
    MIGRATION=$(psql_val "$db" "SELECT migration_name FROM _prisma_migrations
      WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL
      ORDER BY finished_at DESC, migration_name DESC LIMIT 1")
  fi

  if [[ "$db" == keycloak ]]; then
    NAME="${TS}_${ENV}_${db}_kc-${KC_LABEL}_pg${PG_MAJOR}"
  else
    NAME="${TS}_${ENV}_${db}_api-${API_LABEL}"
    [[ -n "$MIGRATION" ]] && NAME+="_mig-${MIGRATION%%_*}"
    NAME+="_pg${PG_MAJOR}"
  fi
  FILE="$OUT_DIR/${NAME}.dump"

  PARTIAL="${FILE}.partial"
  kubectl -n "$NS" exec "$PRIMARY" -c postgres -- pg_dump -Fc -d "$db" > "$PARTIAL"
  [[ -s "$PARTIAL" && "$(head -c 5 "$PARTIAL")" == PGDMP ]] || die "pg_dump of $db is empty or not a custom-format archive"
  mv "$PARTIAL" "$FILE"
  PARTIAL=""

  SHA=$(shasum -a 256 "$FILE" | awk '{print $1}')
  cat > "$OUT_DIR/${NAME}.meta.txt" <<EOF
file            : ${NAME}.dump
sha256          : ${SHA}
size_bytes      : $(wc -c < "$FILE" | tr -d ' ')
dumped_at_utc   : ${TS}
environment     : ${ENV}
kube_context    : $(kubectl config current-context)
namespace       : ${NS}
cnpg_cluster    : ${CLUSTER}
primary_pod     : ${PRIMARY}
database        : ${db}
postgres        : ${PG_VERSION}
prisma_migration: ${MIGRATION:-<none>}
api_image       : ${API_IMAGE:-<none>}
api_digest      : sha256:$(running_digest api)
keycloak_image  : ${KC_IMAGE:-<none>}
keycloak_digest : sha256:$(running_digest keycloak)
format          : pg_dump -Fc (restore with pg_restore >= ${PG_MAJOR})

restore (into an empty db, port-forward via tools/db-connect.sh ${ENV} ${db}):
  pg_restore --no-owner --no-acl -h 127.0.0.1 -p 5432 -U <user> -d ${db} "${NAME}.dump"
EOF

  info "$FILE ($(du -h "$FILE" | awk '{print $1}'))"
  if [[ -n "$MIGRATION" ]]; then info "migration    : $MIGRATION"; fi
done

log "Done -> $OUT_DIR"
