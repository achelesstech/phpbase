#!/usr/bin/env bash
# =============================================================================
# check-config.sh — validate before starting
# =============================================================================
# Every check here maps to a failure seen while building this: a fatal that
# only appears seconds after `up -d` and leaves an exited container, or a
# misconfiguration that starts fine and locks you out of the UI.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
TRAEFIK_MW="../traefik/config/dynamic/middlewares.yml"

fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }

echo "== environment =="
if [ ! -f .env ]; then
    bad ".env missing — run: make init"
else
    dom="$(grep -E '^PORTAINER_DOMAIN=' .env | cut -d= -f2- | tr -d '"'"'"' ')"
    if [ -z "$dom" ]; then
        bad "PORTAINER_DOMAIN is empty"
    elif [[ "$dom" == *"://"* || "$dom" == */* || "$dom" == *:* ]]; then
        bad "PORTAINER_DOMAIN is '$dom' — it must be a BARE HOSTNAME.
        Portainer's --trusted-origins rejects a scheme, a trailing slash or a
        port with 'fatal: invalid url for trusted origin', and the container
        exits a few seconds after 'up -d'."
    elif [[ "$dom" == *example.com ]]; then
        bad "PORTAINER_DOMAIN is still the placeholder ($dom)"
    else
        ok "PORTAINER_DOMAIN=$dom (bare hostname)"
    fi
fi

echo "== secrets =="
for f in secrets/encryption_key secrets/admin_password; do
    if [ -s "$f" ]; then
        m="$(stat -c '%a' "$f")"
        [ "$m" = "600" ] && ok "$f (0600)" || bad "$f is $m — chmod 600 it"
    else
        bad "$f missing or empty — run: make init"
    fi
done

# Portainer reads the password file verbatim. A trailing newline becomes part
# of the password, and you get "invalid credentials" against a password you
# are certain is right.
if [ -s secrets/admin_password ]; then
    if [ "$(tail -c1 secrets/admin_password | wc -l)" -eq 0 ]; then
        ok "admin password has no trailing newline"
    else
        bad "secrets/admin_password ends in a newline — it becomes part of the
        password, and the login you set will not work. Rewrite with:
          printf '%s' 'yourpassword' > secrets/admin_password"
    fi
    [ "$(wc -c < secrets/admin_password)" -ge 12 ] \
        && ok "admin password is 12+ characters" \
        || bad "Portainer requires 12+ characters and will refuse to create the user"
fi

echo "== compose =="
if out="$($COMPOSE config 2>&1 >/dev/null)"; then
    ok "compose config resolves"
else
    bad "compose config failed:"; sed 's/^/        /' <<<"$out"
fi

# Regression guard. Republishing a port is exactly the thing this setup exists
# to remove, and it is one careless line away.
if $COMPOSE config 2>/dev/null | grep -qE '^\s+published:'; then
    bad "a port is published. That is a second front door to a service with
        root on this host, bypassing Traefik's allowlist, auth and rate limit —
        and 'ufw status' will not show it as open."
else
    ok "no published ports (Traefik is the only way in)"
fi

$COMPOSE config 2>/dev/null | grep -q '/var/run/docker.sock' \
    && ok "docker socket is mounted (Portainer cannot work without it)" \
    || bad "no docker socket mount — Portainer will start with no environment"

echo "== traefik side =="
if docker network inspect proxy >/dev/null 2>&1; then
    ok "the 'proxy' network exists"
else
    bad "no 'proxy' network — start Traefik first"
fi

if [ -f "$TRAEFIK_MW" ]; then
    for mw in chain-admin-restricted noindex; do
        grep -qE "^\s+${mw}:" "$TRAEFIK_MW" \
            && ok "middleware '${mw}' is defined in the Traefik config" \
            || bad "the router references ${mw}@file but Traefik does not define
        it. The router will never become healthy and every request 404s while
        'docker ps' shows everything up."
    done
    # The allowlist is private-ranges-only as shipped, which is correct but
    # means the UI is unreachable from a browser until you decide otherwise.
    grep -qE '^\s*- "203\.0\.113\.' "$TRAEFIK_MW" \
        && ok "ipallowlist-admin has a public source range" \
        || note "ipallowlist-admin allows private ranges only — Portainer will
        be reachable through a VPN or 'ssh -L', not from a browser on the
        internet. Intentional default; add your egress IP to change it."
else
    note "Traefik config not found at $TRAEFIK_MW — cannot verify the
        middlewares this router references actually exist"
fi

echo
[ "$fail" -eq 0 ] && echo "ready to start." || echo "NOT ready."
exit "$fail"
