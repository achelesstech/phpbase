# shellcheck shell=bash
# status — /fpm-ping, /fpm-status and /nginx-status live only on the internal
# 127.0.0.1:8081 listener, never on the public port, and the image
# HEALTHCHECK probes them every 2 s while the container starts.

# internal NAME PATH — fetch PATH from the internal status listener, inside NAME.
internal() { docker exec "$1" curl -sf "http://127.0.0.1:8081${2}"; }
# no_status_page TEXT — TEXT is neither the FPM nor the nginx status page.
no_status_page() { [[ "$1" != *"pool:"* && "$1" != *"Active connections"* ]]; }

info "status pages: internal listener only"
for path in /fpm-status /nginx-status; do
    public="$(get_path "$APP" "$path" || true)"
    no_status_page "$public" && ok "${path} on 8080 is not the status page" \
        || bad "${path} on 8080 serves the status page"
done
fpm_status="$(internal "$APP" /fpm-status || true)"
[[ "$fpm_status" == *"pool:"* ]] && ok "127.0.0.1:8081/fpm-status is the FPM status page" \
    || bad "127.0.0.1:8081/fpm-status: ${fpm_status:-no answer}"
nginx_status="$(internal "$APP" /nginx-status || true)"
[[ "$nginx_status" == *"Active connections"* ]] && ok "127.0.0.1:8081/nginx-status is the nginx status page" \
    || bad "127.0.0.1:8081/nginx-status: ${nginx_status:-no answer}"
ping="$(internal "$APP" /fpm-ping || true)"
[[ "$ping" == pong ]] && ok "127.0.0.1:8081/fpm-ping answers pong (through FastCGI)" \
    || bad "127.0.0.1:8081/fpm-ping: ${ping:-no answer}"
spoofed="$(from_network_url "http://${APP}:8080/fpm-status" -H 'X-Forwarded-For: 127.0.0.1' || true)"
no_status_page "$spoofed" && ok "X-Forwarded-For: 127.0.0.1 from the network does not reach the FPM status" \
    || bad "a forged X-Forwarded-For reaches the FPM status page"
rc=0
from_network_url "http://${APP}:8081/fpm-ping" -o /dev/null --max-time 5 2>/dev/null || rc=$?
# curl exit 7: could not connect. Anything else means something answered.
[[ "$rc" == 7 ]] && ok "8081 is unreachable from the network" || bad "8081 from the network: curl exit ${rc}, not 7"

info "image healthcheck: fast while starting"
hc_json="$(docker image inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")"
# Durations are in nanoseconds.
hc="$(jq -r '"\(.Interval) \(.Timeout) \(.StartPeriod) \(.StartInterval) \(.Retries)"' <<<"$hc_json")"
[[ "$hc" == "30000000000 5000000000 60000000000 2000000000 3" ]] \
    && ok "HEALTHCHECK: interval 30s, timeout 5s, start period 60s, start interval 2s, 3 retries" \
    || bad "HEALTHCHECK is ${hc_json}"
started=$SECONDS
FAST="$(start fast "$FIXTURE_TAG")"
if wait_health "$FAST" healthy 30 && (( SECONDS - started <= 15 )); then
    ok "a new container is healthy within 15 s ($((SECONDS - started)) s)"
else
    bad "a new container was not healthy within 15 s ($((SECONDS - started)) s)"
fi
