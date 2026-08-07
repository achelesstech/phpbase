#!/bin/sh
# =============================================================================
# nginx-validate.sh — validate the nginx config at BUILD time, leaving nothing
# =============================================================================
# Use this in application Dockerfiles instead of a bare `nginx -t`:
#
#     COPY docker/vhost.conf /etc/nginx/conf.d/vhost.conf
#     RUN nginx-validate.sh
#
# so a broken vhost fails the build instead of production.
#
# Why a wrapper: `nginx -t` has two side effects that poison the image when the
# build step runs as root, because the runtime user is www-data.
#
#   1. It CREATES the pid file. A root-owned pid file baked into a layer can
#      never be overwritten by www-data, so nginx fails to start in every
#      container from that image.
#   2. Before parsing the config, nginx opens its COMPILED-IN default error log
#      (/var/lib/nginx/logs/error.log -> /var/log/nginx/error.log), creating it
#      root-owned. Every subsequent start then logs
#      "could not open error log file ... Permission denied".
#
# `-e` redirects that pre-parse log so nothing is created, and the trap removes
# the pid file. Both must be handled — fixing only one still breaks the image.
# =============================================================================
set -eu

CONF="${1:-/etc/nginx/nginx.conf}"

# Resolve the pid path from the config so this keeps working if it moves.
PIDFILE="$(sed -n 's/^[[:space:]]*pid[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$CONF" | tail -1)"

cleanup() {
    [ -n "${PIDFILE:-}" ] && rm -f "$PIDFILE" 2>/dev/null || true
}
trap cleanup EXIT

nginx -t -e /dev/stderr -c "$CONF"
