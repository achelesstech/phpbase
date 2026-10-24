#!/usr/bin/env bash
# =============================================================================
# traefik-doctor.sh — check the things that fail silently
# =============================================================================
#   ./scripts/traefik-doctor.sh
#   ./scripts/traefik-doctor.sh https://lms.example.com   # + live spoof test
#
# Traefik's failure modes are mostly not errors. A wrong trustedIPs list, a
# rate-limit depth that yields an empty source, an ipAllowList checking the
# wrong address — all of them start up cleanly, log nothing, and serve
# traffic. They only show up as "the login throttle never triggers" months
# later. Each check below corresponds to one of those.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

COMPOSE="${COMPOSE:-docker compose}"
STATIC="config/traefik.yml"
MW="config/dynamic/middlewares.yml"
PUBLIC_URL="${1:-}"

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; warn=$((warn+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# -----------------------------------------------------------------------------
sec "process"
state="$($COMPOSE ps --format '{{.Name}} {{.State}} {{.Status}}' 2>/dev/null)"
if grep -q '^traefik .*running' <<<"$state"; then
    ok "traefik is running"
    grep -q '^traefik .*healthy' <<<"$state" \
        && ok "healthcheck passing (the ping entryPoint answers)" \
        || note "container is not reporting healthy yet — check 'make logs'"
else
    bad "traefik is not running"
fi
grep -q '^traefik-socket-proxy .*running' <<<"$state" \
    && ok "socket-proxy is running" \
    || bad "socket-proxy is not running — the docker provider has no data,
        so every container-routed site is down while file-routed ones work"

sec "startup errors"
errs="$($COMPOSE logs --tail=500 traefik 2>/dev/null \
        | grep -ciE '"level":"(error|fatal)"' || true)"
if [ "${errs:-0}" -eq 0 ]; then
    ok "no error/fatal lines in the last 500 log lines"
else
    bad "$errs error/fatal log lines — run: make logs"
fi

# -----------------------------------------------------------------------------
sec "secrets and permissions"
if [ -s secrets/cf_dns_api_token ]; then
    ok "Cloudflare token file present"
    m="$(stat -c '%a' secrets/cf_dns_api_token 2>/dev/null)"
    [ "$m" = "600" ] && ok "token is 0600" || bad "token is $m — chmod 600 it"
    grep -q '[[:space:]]$' secrets/cf_dns_api_token \
        && bad "token file ends in whitespace — lego sends it verbatim and
        Cloudflare returns 'Invalid request headers', which Traefik reports
        only as a DNS challenge timeout" \
        || ok "token has no trailing whitespace"
else
    bad "secrets/cf_dns_api_token missing or empty — run: make token"
fi

if [ -s secrets/.htpasswd ]; then
    ok "basic-auth file present ($(grep -c . secrets/.htpasswd) user(s))"
    grep -qE '^[^:]+:\$2[aby]\$' secrets/.htpasswd \
        && ok "hashes are bcrypt" \
        || note "hashes are not bcrypt — regenerate with 'make htpasswd USER=...'"
else
    bad "secrets/.htpasswd missing — the dashboard router will 500 on every
        request, because basic-auth cannot load its user file"
fi

[ -d certs ] && ok "certs/ exists" || bad "certs/ missing — run: make init"
for f in certs/acme-*.json; do
    [ -e "$f" ] || continue
    m="$(stat -c '%a' "$f")"
    [ "$m" = "600" ] \
        && ok "$(basename "$f") is 0600" \
        || bad "$(basename "$f") is $m — it contains your private keys"
done

# -----------------------------------------------------------------------------
sec "config invariants"

# The one that silently disables per-IP rate limiting.
if grep -qE '^\s*depth:\s*1\s*$' "$MW" && ! grep -qE '^\s*depth:\s*[02-9]' "$MW"; then
    ok "every ipStrategy.depth is 1 (correct for client -> Cloudflare -> Traefik)"
else
    bad "an ipStrategy.depth is not 1. If depth exceeds the number of entries
        in X-Forwarded-For, Traefik yields an EMPTY source and every request
        shares one rate-limit bucket. Behind Cloudflare the header has exactly
        one entry, so depth must be 1."
fi

grep -q 'trustedIPs: &trusted_proxies' "$STATIC" && grep -q 'trustedIPs: \*trusted_proxies' "$STATIC" \
    && ok "both entryPoints share one trustedIPs list (anchor + alias)" \
    || note "the two entryPoints have separate trustedIPs lists — they will drift"

grep -qE '^\s*- "2400:cb00::/32"' "$STATIC" \
    && ok "Cloudflare IPv6 ranges are trusted" \
    || bad "no Cloudflare IPv6 in trustedIPs. If the origin has an AAAA record
        Cloudflare will connect over v6, be untrusted, and Traefik will
        overwrite X-Forwarded-For with Cloudflare's own address."

grep -q 'exposedByDefault: false' "$STATIC" \
    && ok "exposedByDefault is false (routing is opt-in)" \
    || bad "exposedByDefault is true — every container on the proxy network is
        published the moment it gets a Host rule"

grep -qE '^[[:space:]]*insecure:[[:space:]]*true' "$STATIC" \
    && bad "api.insecure is true — the dashboard is on :8080 with no auth" \
    || ok "api.insecure is false"

# Anchored to a real setting line. Unanchored, this matched the comment
# directly above the endpoint that explains why the raw socket is not used —
# a check that reports the exact problem it was written to rule out.
if grep -qE '^[[:space:]]*endpoint:.*unix:///var/run/docker\.sock' "$STATIC"; then
    note "the docker provider uses the raw socket. Even :ro that is full
        Docker API access, i.e. root on the host, held by your most exposed
        process. Point it at socket-proxy instead."
else
    ok "docker provider goes through the socket proxy"
fi

grep -qE '^\s*readTimeout: 600s' "$STATIC" \
    && ok "websecure readTimeout raised for large uploads" \
    || note "websecure readTimeout is the 60s default — Moodle backups and
        other large uploads will be cut off mid-transfer with no app-side error"

if grep -q 'contentSecurityPolicy' "$MW" \
   && sed -n '/^\s*security-headers:/,/^\s*[a-z-]*:\s*$/p' "$MW" | grep -q 'contentSecurityPolicy'; then
    note "a CSP is set on the shared security-headers middleware. CSP is
        per-application; a shared one breaks Moodle, WordPress and Drupal
        editors as blank panels with nothing in the server log."
else
    ok "no CSP on the shared header middleware (opt in with csp-strict@file)"
fi

grep -qE '^[[:space:]]*stsPreload:[[:space:]]*true' "$MW" \
    && note "stsPreload is on. Only correct if you have actually submitted the
        domain at hstspreload.org — it is baked into browsers and covers every
        subdomain, including ones that do not exist yet." \
    || ok "HSTS preload not asserted"

# -----------------------------------------------------------------------------
sec "placeholders"
# Shipped placeholders that fail quietly rather than loudly.
grep -q 'admin@example.com' "$STATIC" \
    && bad "the ACME email is still the placeholder admin@example.com —
        Let's Encrypt expiry warnings go nowhere, and it may reject the account" \
    || ok "ACME email has been set"

# -F, not a regex: the value in the file is an escaped-for-YAML regex
# (example\\.com), and matching backslashes through two levels of quoting is how
# a check ends up silently never firing.
if grep -q 'accessControlAllowOriginListRegex' "$MW" \
   && grep -qF 'example\\.com' "$MW"; then
    note "the CORS origin regex is still example.com. It fails CLOSED, so every
        cross-origin request on chain-api is rejected with no logged reason."
else
    ok "CORS origin regex has been set"
fi

if grep -qE '^\s*- "203\.0\.113\.' "$MW"; then
    ok "ipallowlist-admin has a public source range"
else
    note "ipallowlist-admin allows private ranges only — reachable via VPN or an
        SSH tunnel, not from a browser on the internet. Intentional default;
        add your egress address if you want browser access."
fi

sec "network wiring"
if docker network inspect proxy >/dev/null 2>&1; then
    ok "the 'proxy' network exists"
    n="$(docker ps --filter label=traefik.enable=true --format '{{.Names}}' | wc -l)"
    ok "$n container(s) carry traefik.enable=true"
    docker ps --filter label=traefik.enable=true --format '{{.Names}}' | sed 's/^/        /'
else
    bad "no 'proxy' network — run: make init"
fi

# Backends must not publish ports of their own.
exposed="$(docker ps --filter label=traefik.enable=true --format '{{.Names}} {{.Ports}}' \
           | grep -E '0\.0\.0\.0:|:::' || true)"
if [ -n "$exposed" ]; then
    note "these routed containers also publish ports directly to the host,
        which bypasses Traefik, TLS and every middleware:"
    sed 's/^/        /' <<<"$exposed"
else
    ok "no routed container publishes its own ports"
fi

# -----------------------------------------------------------------------------
sec "certificates"
./scripts/acme-certs.sh 2>/dev/null | sed 's/^/        /' || true

# -----------------------------------------------------------------------------
sec "live spoofing test"
if [ -z "$PUBLIC_URL" ]; then
    note "skipped — pass a public URL to run it:
        ./scripts/traefik-doctor.sh https://lms.example.com"
else
    probe="/__doctor-$RANDOM$RANDOM"
    # Send a forged X-Forwarded-For from the open internet. Traefik must
    # discard it, because our public IP is not in trustedIPs. If it does not,
    # every IP-based control in every backend is bypassable with one header.
    curl -s -o /dev/null --max-time 15 \
         -H 'X-Forwarded-For: 198.51.100.77' \
         "${PUBLIC_URL%/}${probe}" || true
    sleep 2
    line="$($COMPOSE logs --since 2m traefik 2>/dev/null | grep -F "$probe" | tail -1)"
    if [ -z "$line" ]; then
        note "the probe request did not appear in the access log. Either the
        request never reached this Traefik, or accessLog has a statusCodes
        filter hiding it."
    else
        client="$(python3 -c '
import sys,json,re
m=re.search(r"\{.*\}", sys.stdin.read())
print(json.loads(m.group(0)).get("ClientHost","?") if m else "?")' <<<"$line")"
        if [ "$client" = "198.51.100.77" ]; then
            bad "Traefik recorded the FORGED address ($client) as the client.
        X-Forwarded-For is trusted from the internet. Every rate limit, login
        throttle and IP ban on this host is bypassable. Fix trustedIPs."
        else
            ok "forged X-Forwarded-For ignored — recorded client was $client"
            echo "        (if that is a Cloudflare address rather than yours,"
            echo "         the edge is not forwarding the client IP)"
        fi
    fi
fi

# -----------------------------------------------------------------------------
printf '\n%s passed, %s warnings, %s failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
