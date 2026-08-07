#!/bin/sh
# Proves /docker-entrypoint.d/*.sh hooks run, and that a hook copied without
# the exec bit is still executed (via sh) — read-only mounts often lose it.
set -eu
touch /tmp/fixture-hook-ran
echo "[fixture] hook ran"
