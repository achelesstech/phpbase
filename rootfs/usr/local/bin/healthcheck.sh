#!/bin/sh
# =============================================================================
# healthcheck.sh — one image HEALTHCHECK for web, worker and scheduler roles
# =============================================================================
# HEALTHCHECK_MODE (default auto):
#   auto       web role -> fpm; a php-base-every container -> heartbeat;
#              any other command -> none (no false "unhealthy" on workers)
#   fpm        GET /fpm-ping through FastCGI must answer "pong". This fails
#              when PHP-FPM is dead, unlike a static nginx `return 200`.
#              It is on the internal status listener, 127.0.0.1:8081
#              (HEALTHCHECK_PORT, HEALTHCHECK_PATH override it).
#              HEALTHCHECK_URL, if set, is probed as well (e.g.
#              http://127.0.0.1:8080/up for Laravel's health route).
#   http       only HEALTHCHECK_URL
#   tcp        something listens on 127.0.0.1:HEALTHCHECK_PORT (e.g. Reverb)
#   heartbeat  the last SUCCESSFUL php-base-every run is no older than
#              HEALTHCHECK_MAX_AGE seconds (default 3 x interval + 30)
#   none       always healthy
# =============================================================================
set -eu

RUNTIME=/tmp/php-base
MODE="${HEALTHCHECK_MODE:-auto}"

if [ "$MODE" = auto ]; then
    role="$(cat "$RUNTIME/role" 2>/dev/null || echo web)"
    if [ "$role" = web ]; then
        MODE=fpm
    elif ls "$RUNTIME"/heartbeat.* >/dev/null 2>&1; then
        MODE=heartbeat
    else
        MODE=none
    fi
fi

fail() { echo "healthcheck(${MODE}): $*" >&2; exit 1; }

# The Dockerfile's HEALTHCHECK --timeout is 5s: one probe gets 4 s, two in a
# row (fpm mode with HEALTHCHECK_URL) get 2 s each.
probe_url() {   # probe_url URL [max seconds]
    curl -fsS -o /dev/null --max-time "${2:-4}" "$1" 2>/dev/null || fail "${1} did not return 2xx/3xx"
}

case "$MODE" in
    fpm)
        url="http://127.0.0.1:${HEALTHCHECK_PORT:-8081}${HEALTHCHECK_PATH:-/fpm-ping}"
        response="$(curl -fsS --max-time 2 "$url" 2>/dev/null)" || fail "no answer from ${url}"
        case "$response" in *pong*) ;; *) fail "unexpected answer from ${url}: ${response}" ;; esac
        [ -z "${HEALTHCHECK_URL:-}" ] || probe_url "$HEALTHCHECK_URL" 2
        ;;
    http)
        probe_url "${HEALTHCHECK_URL:?HEALTHCHECK_URL is required for HEALTHCHECK_MODE=http}"
        ;;
    tcp)
        port="${HEALTHCHECK_PORT:?HEALTHCHECK_PORT is required for HEALTHCHECK_MODE=tcp}"
        php -r '$s = @fsockopen("127.0.0.1", (int) $argv[1], $e, $m, 3); exit($s ? 0 : 1);' "$port" \
            || fail "nothing listening on 127.0.0.1:${port}"
        ;;
    heartbeat)
        now="$(date +%s)"
        newest=0
        max_age="${HEALTHCHECK_MAX_AGE:-}"
        for f in "$RUNTIME"/heartbeat.*; do
            [ -f "$f" ] || continue
            t="$(stat -c %Y "$f")"
            [ "$t" -le "$newest" ] || newest="$t"
            if [ -z "$max_age" ]; then
                interval="$(cat "$f" 2>/dev/null || echo 60)"
                max_age=$((interval * 3 + 30))
            fi
        done
        [ "$newest" -gt 0 ] || fail "no heartbeat file in ${RUNTIME}"
        age=$((now - newest))
        [ "$age" -le "$max_age" ] || fail "last successful run ${age}s ago (limit ${max_age}s)"
        ;;
    none)
        exit 0
        ;;
    *)
        fail "unknown HEALTHCHECK_MODE"
        ;;
esac
