#!/bin/bash
# Step 1 of the nightly db-dump CronJob (templates/db-dump-cronjob.yaml).
# Runs in the CNPG postgres image, so pg_dump always matches the server major.
#
# Writes one pg_dump -Fc archive per database plus a .meta.txt to $WORK_DIR.
# Same naming as tools/db-dump.sh:
#   <UTC ts>_<env>_<db>_api-<tag>_mig-<last prisma migration>_pg<major>.dump
#   <UTC ts>_<env>_keycloak_kc-<tag>_pg<major>.dump
#
# Env: PGHOST PGUSER PGPASSWORD DATABASES ENV_NAME API_IMAGE KEYCLOAK_IMAGE WORK_DIR
set -euo pipefail

: "${PGHOST:?}" "${PGUSER:?}" "${PGPASSWORD:?}" "${DATABASES:?}" "${ENV_NAME:?}" "${WORK_DIR:?}"
export PGCONNECT_TIMEOUT=10

TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Tag of an image ref for the filename ("untagged" for digests or no tag).
image_tag() {
  local image="$1" tag
  tag="${image##*:}"
  [[ -z "$image" || "$image" == *@* || "$tag" == "$image" || "$tag" == */* ]] && tag="untagged"
  printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '-'
}

psql_val() {
  psql -X -q -At -d "$1" -c "$2"
}

PG_VERSION="$(psql_val postgres 'SHOW server_version' | awk '{print $1}')"
PG_MAJOR="${PG_VERSION%%.*}"
IN_RECOVERY="$(psql_val postgres 'SELECT pg_is_in_recovery()')"
echo "host=$PGHOST postgres=$PG_VERSION standby=$IN_RECOVERY"

for db in $DATABASES; do
  MIGRATION=""
  if [[ "$(psql_val "$db" "SELECT to_regclass('public._prisma_migrations') IS NOT NULL")" == t ]]; then
    MIGRATION="$(psql_val "$db" "SELECT migration_name FROM _prisma_migrations
      WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL
      ORDER BY finished_at DESC, migration_name DESC LIMIT 1")"
  fi

  if [[ "$db" == keycloak ]]; then
    NAME="${TS}_${ENV_NAME}_${db}_kc-$(image_tag "${KEYCLOAK_IMAGE:-}")_pg${PG_MAJOR}"
  else
    NAME="${TS}_${ENV_NAME}_${db}_api-$(image_tag "${API_IMAGE:-}")"
    [[ -n "$MIGRATION" ]] && NAME+="_mig-${MIGRATION%%_*}"
    NAME+="_pg${PG_MAJOR}"
  fi
  FILE="$WORK_DIR/${NAME}.dump"

  pg_dump -Fc -d "$db" -f "$FILE"
  # Fails on a truncated or corrupt archive.
  pg_restore --list "$FILE" > /dev/null

  cat > "$WORK_DIR/${NAME}.meta.txt" <<EOF
file            : ${NAME}.dump.age  (age-encrypted pg_dump -Fc)
sha256          : $(sha256sum "$FILE" | awk '{print $1}')  (of the decrypted .dump)
size_bytes      : $(stat -c %s "$FILE")
dumped_at_utc   : ${TS}
environment     : ${ENV_NAME}
host            : ${PGHOST} (standby: ${IN_RECOVERY})
database        : ${db}
postgres        : ${PG_VERSION}
prisma_migration: ${MIGRATION:-<none>}
api_image       : ${API_IMAGE:-<none>}
keycloak_image  : ${KEYCLOAK_IMAGE:-<none>}

restore:
  age -d -i <private key file> ${NAME}.dump.age > ${NAME}.dump
  pg_restore --no-owner --no-acl -h 127.0.0.1 -p 5432 -U <user> -d ${db} ${NAME}.dump
EOF

  echo "dumped $db -> ${NAME}.dump ($(stat -c %s "$FILE") bytes)"
done
