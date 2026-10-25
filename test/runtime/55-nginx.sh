# shellcheck shell=bash
# nginx — Traefik-friendly defaults: worker count, keep-alive, no dynamic
# compression (Traefik compresses), gzip_static, open_file_cache, a quiet
# access log, the rendered FastCGI read timeout and SERVER_PORT from
# X-Forwarded-Port.

# count_workers NAME — the number of nginx worker processes in NAME.
count_workers() {
    local procs
    procs="$(docker exec "$1" ps -o args || true)"
    grep -c '^nginx: worker process' <<<"$procs" || true
}
# gzip_header NAME PATH HEADER [curl-args...] — the value of response header
# HEADER for a gzip-accepting GET of PATH.
gzip_header() {
    local headers
    headers="$(get_path "$1" "$2" -o /dev/null -D - -H 'Accept-Encoding: gzip' "${@:4}" || true)"
    grep -i "^$3:" <<<"$headers" | cut -d: -f2- | tr -d ' \r' || true
}
content_encoding() { gzip_header "$1" "$2" Content-Encoding "${@:3}"; }
# logs_contain NAME TEXT — whether NAME's log contains TEXT within 10 s (an
# access-log line reaches `docker logs` a moment after the response).
logs_contain() {
    for _ in $(seq 1 10); do
        grep -qF -- "$2" <<<"$(docker logs "$1" 2>&1)" && return 0
        sleep 1
    done
    return 1
}
# check_refused NAME=VALUE — a one-off container with this setting must exit 1
# at start, and its log must name NAME.
check_refused() {
    local out rc=0
    out="$(docker run --rm --label "$LABEL" -e "$1" "$FIXTURE_TAG" true 2>&1)" || rc=$?
    if [[ "$rc" == 1 ]] && grep -qF -- "${1%%=*}" <<<"$out"; then
        ok "$1 is refused and named"
    else
        bad "$1: exit ${rc}: $(tail -1 <<<"$out")"
    fi
}

info "nginx workers and fixed http{} settings"
workers="$(count_workers "$APP")"
[[ "$workers" == 2 ]] && ok "2 nginx worker processes by default" || bad "nginx worker processes: ${workers}, want 2"
dump="$(docker exec "$APP" nginx -T 2>&1 || true)"
missing=()
for directive in 'keepalive_timeout 120s;' 'keepalive_requests 10000;' 'open_file_cache max=10000 inactive=60s;' \
                 'open_file_cache_errors off;' 'gzip_static on;'; do
    grep -qF "$directive" <<<"$dump" || missing+=("$directive")
done
[[ ${#missing[@]} -eq 0 ]] && ok "nginx -T has keep-alive 120s/10000, open_file_cache and gzip_static" \
    || bad "nginx -T is missing: ${missing[*]}"

info "compression: Traefik compresses, nginx serves pre-compressed files only"
enc="$(content_encoding "$APP" /)"
[[ -z "$enc" ]] && ok "no dynamic gzip by default" || bad "GET / with Accept-Encoding: gzip -> Content-Encoding: ${enc}"
enc="$(content_encoding "$APP" /static.txt)"
vary="$(gzip_header "$APP" /static.txt Vary)"
[[ "$enc:$vary" == gzip:Accept-Encoding ]] && ok "gzip_static serves static.txt.gz with Vary: Accept-Encoding" \
    || bad "GET /static.txt -> Content-Encoding: '${enc}', Vary: '${vary}'; want gzip, Accept-Encoding"
# Behind a CDN the request carries Via; gzip_proxied off would skip gzip_static.
enc="$(content_encoding "$APP" /static.txt -H 'Via: 1.1 proxy')"
[[ "$enc" == gzip ]] && ok "gzip_static still applies to a proxied request (Via)" || bad "GET /static.txt with Via -> Content-Encoding: '${enc}', want gzip"

TUNED="$(start tuned -e NGINX_WORKER_PROCESSES=3 -e NGINX_GZIP=1 -e NGINX_ACCESS_LOG=main \
    -e NGINX_FASTCGI_READ_TIMEOUT=600s "$FIXTURE_TAG")"
if wait_health "$TUNED"; then
    workers="$(count_workers "$TUNED")"
    [[ "$workers" == 3 ]] && ok "NGINX_WORKER_PROCESSES=3 -> 3 workers" || bad "NGINX_WORKER_PROCESSES=3 -> ${workers} workers"
    enc="$(content_encoding "$TUNED" /)"
    [[ "$enc" == gzip ]] && ok "NGINX_GZIP=1 compresses dynamic responses" || bad "NGINX_GZIP=1: Content-Encoding '${enc}', want gzip"
else
    bad "NGINX_WORKER_PROCESSES=3 NGINX_GZIP=1 …: container never became healthy"
fi

info "access log: off by default"
for _ in 1 2 3; do get "$APP" >/dev/null; done
sleep 2   # the time a line takes to reach docker logs (logs_contain)
if grep -qF '"GET / HTTP/1.1" 200' <<<"$(docker logs "$APP" 2>&1)"; then
    bad "default: access-log lines in docker logs"
else
    ok "default: 3 requests leave no access-log line"
fi
get "$TUNED" >/dev/null || true
logs_contain "$TUNED" '"GET / HTTP/1.1" 200' \
    && ok "NGINX_ACCESS_LOG=main logs requests" || bad "NGINX_ACCESS_LOG=main: no access-log line"
JSONLOG="$(start jsonlog -e NGINX_ACCESS_LOG=json "$FIXTURE_TAG")"
if wait_health "$JSONLOG"; then
    get "$JSONLOG" >/dev/null || true
    logs_contain "$JSONLOG" '"status":200' \
        && ok "NGINX_ACCESS_LOG=json logs JSON lines" || bad "NGINX_ACCESS_LOG=json: no line with \"status\":200: $(docker logs "$JSONLOG" 2>&1 | tail -3)"
else
    bad "NGINX_ACCESS_LOG=json: container never became healthy: $(docker logs "$JSONLOG" 2>&1 | tail -3)"
fi

info "SERVER_PORT follows X-Forwarded-Port"
port_443="$(get "$APP" -H 'X-Forwarded-Port: 443' | grep '^server_port:' || true)"
port_none="$(get "$APP" | grep '^server_port:' || true)"
port_bad="$(get "$APP" -H 'X-Forwarded-Port: abc' | grep '^server_port:' || true)"
[[ "$port_443" == server_port:443 ]] && ok "X-Forwarded-Port: 443 -> SERVER_PORT=443" || bad "X-Forwarded-Port: 443 -> '${port_443}'"
[[ "$port_none:$port_bad" == server_port:8080:server_port:8080 ]] \
    && ok "no or non-numeric X-Forwarded-Port -> SERVER_PORT=8080" || bad "no header -> '${port_none}', 'abc' -> '${port_bad}'"

info "FastCGI read timeout is rendered"
check "fastcgi_read_timeout 300s by default" docker exec "$APP" grep -qx 'fastcgi_read_timeout 300s;' /tmp/php-base/nginx/http.d/10-php-base.conf
check "NGINX_FASTCGI_READ_TIMEOUT=600s -> 600s" docker exec "$TUNED" grep -qx 'fastcgi_read_timeout 600s;' /tmp/php-base/nginx/http.d/10-php-base.conf
check_refused 'NGINX_FASTCGI_READ_TIMEOUT=10 minutes'
# A zero timeout would fail every slow request at once.
check_refused 'NGINX_FASTCGI_READ_TIMEOUT=0s'
check_refused 'NGINX_WORKER_PROCESSES=two'
check_refused 'NGINX_GZIP=yes'
check "no preset sets fastcgi_read_timeout" test -z "$(grep -l fastcgi_read_timeout "$HERE"/../rootfs/etc/nginx/presets/*.conf)"

# Review focus 4: a 60 MiB POST under the default 64M post_max_size. nginx
# buffers the body on the 256m /tmp tmpfs, and PHP's php://input spills there too.
info "a 60 MiB upload fits the hardened /tmp"
upload="$(docker exec "$APP" sh -c 'head -c 62914560 /dev/zero | curl -s -w " %{http_code}" -H "Content-Type: application/octet-stream" --data-binary @- http://127.0.0.1:8080/' || true)"
[[ "$upload" == "post_bytes:62914560"$'\n'" 200" ]] && ok "a 62914560-byte POST -> 200, all bytes reach PHP" || bad "60 MiB POST: '${upload}'"
if grep -qF 'No space left' <<<"$(docker logs "$APP" 2>&1)"; then bad "'No space left' in the logs"; else ok "no 'No space left' in the logs"; fi
docker rm -f -v "$TUNED" "$JSONLOG" >/dev/null
