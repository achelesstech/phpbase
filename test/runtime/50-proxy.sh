# shellcheck shell=bash
# proxy — the scheme and client IP an app sees behind a reverse proxy.
# shellcheck disable=SC2154  # body is set by 00-boot.sh.

info "the HTTPS if_not_empty fix"
[[ "$(field https_isset)" == "no" ]] && ok "\$_SERVER['HTTPS'] unset on plain HTTP" || bad "HTTPS set on plain HTTP"
fwd="$(get "$APP" -H 'X-Forwarded-Proto: https')"
grep -q "^https_value:'on'\$" <<<"$fwd" && ok "X-Forwarded-Proto: https -> HTTPS=on" || bad "forwarded scheme not propagated"

info "real client IP behind a proxy"
rip="$(from_network "$APP" -H 'X-Forwarded-For: 203.0.113.9')"
grep -q '^remote_addr:203.0.113.9$' <<<"$rip" && ok "REMOTE_ADDR is the client, not the proxy" || bad "real_ip not applied: $(grep '^remote_addr:' <<<"$rip")"
chain="$(from_network "$APP" -H 'X-Forwarded-For: 203.0.113.9, 172.18.0.5, 10.1.2.3')"
grep -q '^remote_addr:203.0.113.9$' <<<"$chain" && ok "real_ip_recursive walks a multi-hop private chain" || bad "recursive real_ip failed"
# Cloudflare -> Traefik -> nginx: Traefik appends the Cloudflare edge address.
cf="$(from_network "$APP" -H 'X-Forwarded-For: 203.0.113.9, 173.245.48.5')"
grep -q '^remote_addr:203.0.113.9$' <<<"$cf" && ok "a Cloudflare edge hop is skipped (visitor IP, not Cloudflare's)" || bad "Cloudflare hop not trusted: $(grep '^remote_addr:' <<<"$cf")"
spoof="$(get "$APP" -H 'X-Forwarded-For: 203.0.113.9')"
grep -q '^remote_addr:127.0.0.1$' <<<"$spoof" && ok "X-Forwarded-For over loopback is ignored (ACLs stay sound)" || bad "loopback trusted for XFF"
NOCF="$(start nocf -e NGINX_TRUST_CLOUDFLARE=0 "$FIXTURE_TAG")"
wait_health "$NOCF" || true
cf0="$(from_network "$NOCF" -H 'X-Forwarded-For: 203.0.113.9, 173.245.48.5')"
grep -q '^remote_addr:173.245.48.5$' <<<"$cf0" && ok "NGINX_TRUST_CLOUDFLARE=0 stops at the Cloudflare hop" || bad "NGINX_TRUST_CLOUDFLARE=0 ignored"
