#!/bin/sh
# Step 2 of the nightly db-dump CronJob (templates/db-dump-cronjob.yaml).
# Encrypts the dumps from step 1 to the age recipients (public keys only, the
# cluster can't decrypt), uploads them to S3 and prunes old ones there.
#
# Env: WORK_DIR AGE_RECIPIENTS DESTINATION RETENTION_DAYS
#      RCLONE_CONFIG_DEST_* (S3 remote "dest", set by the CronJob)
set -eu

: "${WORK_DIR:?}" "${AGE_RECIPIENTS:?}" "${DESTINATION:?}" "${RETENTION_DAYS:?}"

apk add --no-cache age rclone > /dev/null

# s3://bucket/prefix -> dest:bucket/prefix
REMOTE="dest:${DESTINATION#s3://}"

printf '%s\n' "$AGE_RECIPIENTS" > /tmp/recipients

set -- "$WORK_DIR"/*.dump
[ -e "$1" ] || { echo "no dumps in $WORK_DIR" >&2; exit 1; }

for f in "$@"; do
  age -R /tmp/recipients -o "$f.age" "$f"
  rm -f "$f"
done

# Dumps first, meta last: a .meta.txt on S3 means its dump is complete.
rclone copy "$WORK_DIR" "$REMOTE" --include '*.dump.age' --s3-no-check-bucket -v
rclone copy "$WORK_DIR" "$REMOTE" --include '*.meta.txt' --s3-no-check-bucket -v

rclone delete "$REMOTE" --min-age "${RETENTION_DAYS}d" \
  --include '*.dump.age' --include '*.meta.txt' -v

echo "uploaded to $DESTINATION:"
rclone lsl "$REMOTE" --max-age 1d
