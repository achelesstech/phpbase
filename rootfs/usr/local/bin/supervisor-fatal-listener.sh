#!/bin/sh
# =============================================================================
# supervisor-fatal-listener.sh — make a dead daemon kill the container.
# =============================================================================
# Supervisor's default behaviour is to give up on a program after `startretries`
# and leave it in FATAL while supervisord itself keeps running happily. The
# container stays "up", the orchestrator never restarts it, and every request
# 502s. This listener subscribes to PROCESS_STATE_FATAL and shuts supervisord
# down, so `restart: unless-stopped` / the orchestrator can do its job.
#
# Supervisor's eventlistener protocol on stdout:
#   1. announce "READY\n"
#   2. read one header line, then exactly `len` bytes of payload
#   3. answer "RESULT 2\nOK"
# stdout is the protocol channel — never log to it. Diagnostics go to stderr.
# =============================================================================

printf 'READY\n'

while IFS= read -r header; do
    len="$(printf '%s' "$header" | sed -n 's/.*len:\([0-9]\{1,\}\).*/\1/p')"

    payload=''
    if [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null; then
        payload="$(dd bs=1 count="$len" 2>/dev/null)"
    fi

    printf 'RESULT 2\nOK'

    echo "[supervisor] FATAL: ${payload} — shutting the container down" >&2

    # $PPID is supervisord (it forked us). Fall back to PID 1 (tini), which
    # forwards SIGTERM to supervisord.
    kill -TERM "${PPID:-1}" 2>/dev/null || kill -TERM 1 2>/dev/null || true

    printf 'READY\n'
done
