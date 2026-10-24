#!/usr/bin/env bash
# =============================================================================
# test/examples/traefik-acme-certs.sh — certificate expiry, resolvers, pins
# =============================================================================
#   test/examples/traefik-acme-certs.sh
#
# Builds an ACME store in Traefik's format holding two self-signed
# certificates, one expiring in 10 days and one in 60 (made with openssl in an
# Alpine container), and asserts that
#   - acme-certs.sh --warn-days 21 exits 1 and names the 10-day domain;
#   - with only the 60-day certificate it exits 0.
#
# Then the static checks that go with it:
#   - traefik.yml sets the backend idleConnTimeout to 90s;
#   - nothing claims Let's Encrypt sends expiry warnings (it stopped in 2025);
#   - the Portainer router's resolver is cloudflare by default and follows
#     PORTAINER_CERT_RESOLVER;
#   - the Traefik image is pinned by tag and digest, and make check boots the
#     same image that compose runs.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TRAEFIK="$ROOT/examples/traefik"
PORTAINER="$ROOT/examples/portainer"

ALPINE_IMAGE="alpine:3.24"
LABEL="php-base-test=traefik-acme-certs-$$-${RANDOM}"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

workdir="$(mktemp -d)"
cleanup() {
    docker ps -aq --filter "label=${LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=${LABEL}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
info "fixture: ACME store with certificates expiring in 10 and 60 days"
# -----------------------------------------------------------------------------
# One line per certificate on stdout: <domain> <base64 of the PEM>, the same
# encoding Traefik uses for the "certificate" field.
docker run --rm --label "$LABEL" "$ALPINE_IMAGE" sh -euc '
    apk add --no-cache --quiet openssl >/dev/null
    for pair in soon.example.test:10 later.example.test:60; do
        domain="${pair%%:*}"
        days="${pair##*:}"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -keyout /tmp/key.pem -out /tmp/cert.pem \
            -days "$days" -subj "/CN=$domain" 2>/dev/null
        printf "%s %s\n" "$domain" "$(base64 -w0 /tmp/cert.pem)"
    done
' >"$workdir/certs.txt"

python3 - "$workdir" <<'PY'
import json, sys

workdir = sys.argv[1]
certs = dict(line.split() for line in open(f"{workdir}/certs.txt"))

def store(domains):
    return {"cloudflare": {
        "Account": {"Email": "admin@example.com"},
        "Certificates": [
            {"domain": {"main": d}, "certificate": certs[d], "key": "", "Store": "default"}
            for d in domains
        ],
    }}

json.dump(store(["soon.example.test", "later.example.test"]),
          open(f"{workdir}/acme-both.json", "w"))
json.dump(store(["later.example.test"]), open(f"{workdir}/acme-later.json", "w"))
PY
ok "fixture built"

# -----------------------------------------------------------------------------
info "acme-certs.sh --warn-days 21"
# -----------------------------------------------------------------------------
rc=0
out="$("$TRAEFIK/scripts/acme-certs.sh" --warn-days 21 "$workdir/acme-both.json" 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then
    ok "exits 1 when a certificate expires within 21 days"
else
    bad "exit status $rc with a 10-day certificate, expected 1"
fi
if grep -Eq 'within 21 days.*soon\.example\.test' <<<"$out"; then
    ok "names the expiring domain"
else
    bad "the warning does not name soon.example.test:"
    sed 's/^/        /' <<<"$out"
fi

rc=0
out="$("$TRAEFIK/scripts/acme-certs.sh" --warn-days 21 "$workdir/acme-later.json" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "exits 0 when only the 60-day certificate is present"
else
    bad "exit status $rc with only a 60-day certificate, expected 0:"
    sed 's/^/        /' <<<"$out"
fi

# -----------------------------------------------------------------------------
info "acme-certs.sh fails closed on a store it cannot read"
# -----------------------------------------------------------------------------
# Traefik creates the store empty before the first issuance: that is fine.
: >"$workdir/acme-empty.json"
rc=0
out="$("$TRAEFIK/scripts/acme-certs.sh" --warn-days 21 "$workdir/acme-empty.json" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
    ok "exits 0 on an empty store (nothing issued yet)"
else
    bad "exit status $rc on an empty store, expected 0:"
    sed 's/^/        /' <<<"$out"
fi

# A corrupt store, and one it has no permission to read (Traefik writes them
# as root, mode 0600), must not look like "nothing expiring".
printf 'garbage\n' >"$workdir/acme-corrupt.json"
cp "$workdir/acme-later.json" "$workdir/acme-noperm.json"
chmod 000 "$workdir/acme-noperm.json"
stores=(acme-corrupt.json)
if [ "$(id -u)" -eq 0 ]; then
    printf '  skip  mode-000 store: root can read it anyway\n'
else
    stores+=(acme-noperm.json)
fi
for store in "${stores[@]}"; do
    rc=0
    out="$("$TRAEFIK/scripts/acme-certs.sh" --warn-days 21 "$workdir/$store" 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -Fq "could not be read" <<<"$out" && grep -Fq "$store" <<<"$out"; then
        ok "exits 1 and names $store"
    else
        bad "exit status $rc on $store, expected 1 naming the file:"
        sed 's/^/        /' <<<"$out"
    fi
done
chmod 600 "$workdir/acme-noperm.json"

# -----------------------------------------------------------------------------
info "static configuration"
# -----------------------------------------------------------------------------
if grep -n 'idleConnTimeout: 90s' "$TRAEFIK/config/traefik.yml" >/dev/null; then
    ok "serversTransport idleConnTimeout is 90s"
else
    bad "no 'idleConnTimeout: 90s' in config/traefik.yml"
fi

stale="$(grep -rniE 'sends? expiry warn' "$TRAEFIK" || true)"
if [ -z "$stale" ]; then
    ok "no claim that Let's Encrypt sends expiry warnings"
else
    bad "stale expiry-warning claim:"
    sed 's/^/        /' <<<"$stale"
fi

# -----------------------------------------------------------------------------
info "Portainer certificate resolver"
# -----------------------------------------------------------------------------
portainer_resolver() {
    docker compose --env-file "$PORTAINER/.env.example" -f "$PORTAINER/compose.yml" config 2>&1 \
        | sed -n 's/.*traefik\.http\.routers\.portainer\.tls\.certresolver: *//p'
}
got="$(unset PORTAINER_CERT_RESOLVER; portainer_resolver)"
if [ "$got" = "cloudflare" ]; then
    ok "default is cloudflare"
else
    bad "default resolver is '$got', expected cloudflare"
fi
got="$(PORTAINER_CERT_RESOLVER=letsencrypt portainer_resolver)"
if [ "$got" = "letsencrypt" ]; then
    ok "PORTAINER_CERT_RESOLVER=letsencrypt selects letsencrypt"
else
    bad "with PORTAINER_CERT_RESOLVER=letsencrypt the resolver is '$got'"
fi

# -----------------------------------------------------------------------------
info "Traefik image pin"
# -----------------------------------------------------------------------------
image="$(sed -n 's/^ *image: *\(traefik:[^ ]*\).*/\1/p' "$TRAEFIK/compose.yml")"
if [[ "$image" =~ ^traefik:v3\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
    ok "compose pins $image"
else
    bad "compose image '$image' is not traefik:v3.X.Y@sha256:<digest>"
fi
check_image="$(grep -E '^IMAGE=' "$TRAEFIK/scripts/check-config.sh" || true)"
if grep -Fq 'compose.yml' <<<"$check_image"; then
    ok "make check boots the image compose.yml pins"
else
    bad "check-config.sh does not take its image from compose.yml: $check_image"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
