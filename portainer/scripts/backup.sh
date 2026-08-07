#!/usr/bin/env bash
# =============================================================================
# backup.sh — the data volume AND the encryption key, together
# =============================================================================
# Backing up only the volume is worse than useless when the store is
# encrypted: you get a file that cannot be opened and no warning until you try
# to restore. Verified failure mode:
#   fatal: The portainer database is encrypted, but no secret was loaded
#
# Portainer is stopped for the duration. BoltDB is memory-mapped, and a tar of
# a live database is a copy of an inconsistent one — it usually restores, which
# is the worst property a backup can have.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
VOLUME="${VOLUME:-portainer_data}"
STAMP="$(date +%F-%H%M)"
OUT="portainer-backup-${STAMP}.tgz"

docker volume inspect "$VOLUME" >/dev/null 2>&1 \
    || { echo "no volume named ${VOLUME}"; exit 1; }

was_running=false
if [ "$(docker inspect -f '{{.State.Running}}' portainer 2>/dev/null)" = "true" ]; then
    was_running=true
    echo "stopping portainer for a consistent copy..."
    $COMPOSE stop portainer >/dev/null
fi
# `if`, not `&&` — under `set -e` a false `&&` chain makes the trap return
# non-zero, which is a confusing way for a successful backup to look failed.
restart() {
    if [ "$was_running" = true ]; then
        echo "restarting portainer..."
        $COMPOSE start portainer >/dev/null
    fi
}
trap restart EXIT

work="$(mktemp -d "$PWD/.backup.XXXXXX")"
# NOT /tmp: Docker Desktop only bind-mounts host paths it has been told to
# share, and /tmp is usually not one of them.
cleanup() { rm -rf "$work"; }

# INT and TERM as well as EXIT. Without them, a Ctrl-C or a broken pipe part
# way through leaves Portainer stopped — which is how a backup script becomes
# an outage. (Observed: piping this script to `head` killed it with SIGPIPE and
# the container stayed down.)
trap 'cleanup; restart' EXIT
trap 'cleanup; restart; exit 130' INT
trap 'cleanup; restart; exit 143' TERM

echo "archiving volume ${VOLUME}..."
docker run --rm \
    -v "${VOLUME}:/data:ro" \
    -v "${work}:/out" \
    alpine:3.21 tar czf /out/volume.tgz -C /data .

mkdir -p "${work}/secrets"
cp -a secrets/. "${work}/secrets/" 2>/dev/null || true
cp -a .env "${work}/" 2>/dev/null || true

tar czf "$OUT" -C "$work" .
chmod 600 "$OUT"

echo
echo "wrote ${OUT} ($(du -h "$OUT" | cut -f1))"
echo
echo "It contains the data store, the encryption key and the admin password."
echo "Encrypt it and move it OFF this host — a backup sitting next to the"
echo "thing it backs up protects you from exactly nothing."
echo
# The scratch dir is inside the project, not /tmp — see the mktemp note above.
# Verified end to end: volume and secrets destroyed, restored with exactly
# these commands, encrypted store opened and the original password
# authenticated.
cat <<RESTORE

Restore:
  docker compose down
  mkdir -p .restore && tar xzf ${OUT} -C .restore
  docker volume create ${VOLUME}
  docker run --rm -v ${VOLUME}:/data -v "\$PWD/.restore:/in:ro" alpine:3.21 \\
      tar xzf /in/volume.tgz -C /data
  cp -a .restore/secrets/. ./secrets/
  make up && rm -rf .restore
RESTORE
