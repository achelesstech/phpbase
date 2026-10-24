#!/usr/bin/env bash
# =============================================================================
# portainer-doctor.sh — diagnose a running Portainer
# =============================================================================
#   ./scripts/portainer-doctor.sh
#
# The image has no shell, no curl and no wget, so nothing here can use
# `docker exec`. Requests are made from a throwaway curl container joined to
# Portainer's network namespace, which is also the only way to reach :9000 now
# that no port is published.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; warn=$((warn+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

inside() { docker run --rm --network "container:portainer" "$CURL_IMAGE" "$@" 2>/dev/null; }

# -----------------------------------------------------------------------------
sec "process"
if [ "$(docker inspect -f '{{.State.Running}}' portainer 2>/dev/null)" = "true" ]; then
    ok "portainer is running ($(docker inspect -f '{{.Config.Image}}' portainer))"
else
    bad "portainer is not running"
    docker logs portainer 2>&1 | tail -3 | sed 's/^/        /'
    echo; echo "0 passed, 0 warnings, 1 failure"; exit 1
fi

# Portainer's fatals all happen within a few seconds of start, so a container
# that has restarted repeatedly is the signal, not the current state.
rc="$(docker inspect -f '{{.RestartCount}}' portainer 2>/dev/null)"
[ "${rc:-0}" -lt 3 ] \
    && ok "restart count is ${rc}" \
    || note "restarted ${rc} times — check 'make logs' for a fatal at startup"

sec "startup"
logs="$(docker logs portainer 2>&1 | tail -200)"
grep -q '"level":"fatal"' <<<"$logs" \
    && bad "a fatal in the log: $(grep '"level":"fatal"' <<<"$logs" | tail -1 | cut -c1-140)" \
    || ok "no fatal log lines"

grep -q 'starting HTTP server' <<<"$logs" \
    && ok "HTTP server started (Traefik routes to :9000)" \
    || bad "no HTTP server — --http-enabled is missing, so only :9443 is served
        and Traefik's plain-HTTP backend connection gets a TLS handshake"

if grep -q 'proceeding without encryption key' <<<"$logs"; then
    note "the data store is NOT encrypted at rest. It holds the JWT signing
        secret and any registry credentials. Add secrets/encryption_key —
        but back it up first: an encrypted store without its key will not open."
else
    ok "data store encryption key was loaded"
fi

grep -q 'administrator user defined' <<<"$logs" \
    && ok "admin user already exists (password file is being ignored, as designed)" \
    || grep -q 'created admin user' <<<"$logs" \
    && ok "admin user was created from the password file" \
    || note "no admin bootstrap line in the last 200 lines — probably just log rotation"

# -----------------------------------------------------------------------------
sec "exposure"
ports="$(docker inspect -f '{{json .HostConfig.PortBindings}}' portainer)"
if [ "$ports" = "{}" ] || [ "$ports" = "null" ]; then
    ok "no ports published to the host"
else
    bad "ports are published: ${ports}
        This is a second entrance that bypasses Traefik entirely — no IP
        allowlist, no basic auth, no rate limit, and Portainer's own
        self-signed certificate. Docker's iptables rules mean 'ufw status'
        will not show it. Remove the port and use the Traefik route."
fi

# What the host actually has open, as a cross-check on the above.
if command -v ss >/dev/null 2>&1; then
    open="$(ss -ltnH 2>/dev/null | grep -E ':(9000|9443|8000)\b' || true)"
    [ -z "$open" ] \
        && ok "nothing on the host is listening on 9000/9443/8000" \
        || bad "the host is listening on a Portainer port:
$(sed 's/^/        /' <<<"$open")"
fi

sock="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.RW}}{{end}}{{end}}' portainer)"
case "$sock" in
    true)  note "the Docker socket is mounted read-write. That is REQUIRED —
        creating and exec-ing into containers is POST on the Docker API — and
        it means Portainer is root-equivalent on this host. Not a defect; the
        reason the router sits behind an IP allowlist and basic auth." ;;
    false) bad "the socket is mounted read-only — Portainer will show
        environments but every action fails" ;;
    *)     bad "no docker socket mount" ;;
esac

# -----------------------------------------------------------------------------
sec "application"
code="$(inside -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9000/)"
case "$code" in
    200|30*) ok "GET / -> ${code}" ;;
    "")      bad "no response on :9000 — could not reach the UI at all" ;;
    *)       bad "GET / -> ${code}" ;;
esac

status="$(inside -s --max-time 10 http://127.0.0.1:9000/api/system/status)"
if [ -n "$status" ]; then
    v="$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('Version','?'))" "$status" 2>/dev/null)"
    ok "API answers — version ${v:-?}"
else
    note "/api/system/status returned nothing"
fi

csp="$(inside -sI --max-time 10 http://127.0.0.1:9000/ | grep -ci 'content-security-policy')"
[ "${csp:-0}" -gt 0 ] \
    && ok "Portainer is sending its own CSP (--csp)" \
    || note "no CSP header — add --csp to the command"

# -----------------------------------------------------------------------------
sec "routing"
if [ -f .env ]; then
    dom="$(grep -E '^PORTAINER_DOMAIN=' .env | cut -d= -f2- | tr -d '"'"'"' ')"
    lbl="$(docker inspect -f '{{index .Config.Labels "traefik.http.routers.portainer.rule"}}' portainer)"
    case "$lbl" in
        *"$dom"*) ok "Traefik router rule matches PORTAINER_DOMAIN (${dom})" ;;
        *)        bad "router rule is '${lbl}' but PORTAINER_DOMAIN is '${dom}'" ;;
    esac

    # The two must agree or the UI loads and then every API call 403s.
    cmd="$(docker inspect -f '{{json .Config.Cmd}}' portainer)"
    case "$cmd" in
        *"trusted-origins=${dom}"*) ok "--trusted-origins matches the router hostname" ;;
        *) bad "--trusted-origins does not match ${dom}. The UI will load and
        then every login and API call fails CSRF with a 403, which reads as
        'wrong password'." ;;
    esac
fi

mw="$(docker inspect -f '{{index .Config.Labels "traefik.http.routers.portainer.middlewares"}}' portainer)"
case "$mw" in
    *chain-admin-restricted*) ok "router is behind chain-admin-restricted@file" ;;
    *) bad "router middlewares are '${mw}' — Portainer is reachable without the
        IP allowlist and basic auth. This is the UI for root on this host." ;;
esac

# -----------------------------------------------------------------------------
sec "backup"
if [ -s secrets/encryption_key ]; then
    note "the store is encrypted. Verify your backup includes
        secrets/encryption_key, not just the volume — the volume alone is
        unrecoverable. 'make backup' tars both."
fi
last="$(ls -t portainer-backup-*.tgz 2>/dev/null | head -1)"
[ -n "$last" ] \
    && ok "most recent local backup: $last" \
    || note "no local backup found — run 'make backup' and move it off this host"

# -----------------------------------------------------------------------------
printf '\n%s passed, %s warnings, %s failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
