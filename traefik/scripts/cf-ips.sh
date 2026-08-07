#!/usr/bin/env bash
# =============================================================================
# cf-ips.sh — check the committed Cloudflare ranges against the live list
# =============================================================================
# Cloudflare adds ranges. When it does, and your config has not been updated:
#
#   - traefik.yml trustedIPs      -> the new edge IPs are untrusted, Traefik
#                                    overwrites X-Forwarded-For, and every
#                                    backend starts seeing Cloudflare as the
#                                    client. Rate limits and IP bans silently
#                                    apply to the whole internet at once.
#   - ipallowlist-cloudflare-edge -> traffic from the new range gets a 403.
#
# Neither failure produces an error anywhere. This is the only way to notice.
#
# Deliberately reports rather than rewrites: an automatic edit to the file that
# decides who Traefik trusts is not something that should happen unattended.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

STATIC="config/traefik.yml"
DYNAMIC="config/dynamic/middlewares.yml"

fail=0
note() { printf '  \033[33m%s\033[0m %s\n' "warn" "$1"; }
bad()  { printf '  \033[31m%s\033[0m %s\n' "FAIL" "$1"; fail=1; }
ok()   { printf '  \033[32m%s\033[0m   %s\n' "ok" "$1"; }

echo "fetching cloudflare.com/ips-v4 and ips-v6 ..."
live="$(mktemp)"; trap 'rm -f "$live"' EXIT
{
  curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4
  echo
  curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6
} | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sort -u > "$live"

count=$(wc -l < "$live")
[ "$count" -gt 10 ] || { echo "refusing to compare against $count ranges — fetch looks wrong"; exit 1; }
echo "  live list: $count ranges"

# Ranges that legitimately appear in the config and are not Cloudflare's.
LOCAL='^(127\.0\.0\.1/32|::1/128|10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|fc00::/7|203\.0\.113\.)'

for f in "$STATIC" "$DYNAMIC"; do
    printf '\n%s\n' "$f"
    have="$(grep -oE '"[0-9a-fA-F:.]+/[0-9]+"' "$f" | tr -d '"' | sort -u)"

    missing=""
    while read -r cidr; do
        grep -qxF "$cidr" <<<"$have" || missing="${missing}${cidr}"$'\n'
    done < "$live"

    extra=""
    while read -r cidr; do
        [ -n "$cidr" ] || continue
        grep -qE "$LOCAL" <<<"$cidr" && continue
        grep -qxF "$cidr" "$live" || extra="${extra}${cidr}"$'\n'
    done <<<"$have"

    if [ -n "${missing//$'\n'/}" ]; then
        bad "missing $(grep -c . <<<"$missing") live Cloudflare range(s):"
        sed '/^$/d;s/^/          /' <<<"$missing"
    else
        ok "contains every live Cloudflare range"
    fi

    if [ -n "${extra//$'\n'/}" ]; then
        note "$(grep -c . <<<"$extra") range(s) present but not in the live list"
        sed '/^$/d;s/^/          /' <<<"$extra"
        echo "          (retired Cloudflare ranges, or your own additions)"
    fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then
    echo "up to date."
else
    echo "Add the missing ranges to BOTH files, then:  make restart"
    echo "  $STATIC   -> entryPoints.web.forwardedHeaders.trustedIPs (the anchor)"
    echo "  $DYNAMIC  -> ipallowlist-cloudflare-edge.sourceRange (hot-reloads)"
fi
exit "$fail"
