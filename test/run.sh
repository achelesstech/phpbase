#!/usr/bin/env bash
# =============================================================================
# test/run.sh — behavioural smoke test for php-base
# =============================================================================
#   ./test/run.sh <base-image-tag>
#
# The previous revision's `make test` booted a base image containing no
# application and asserted that a static nginx `return 200` answered. It could
# not fail for any real reason. Every check here corresponds to something that
# was actually broken and shipped.
# =============================================================================
set -euo pipefail

BASE_TAG="${1:?usage: run.sh <base-image-tag>}"
FIXTURE_TAG="php-base-fixture:test"
NAME="php-base-test"
NET="php-base-test-net"
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0
fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
info "building fixture app image on ${BASE_TAG}"
docker build --quiet --build-arg "BASE_IMAGE=${BASE_TAG}" -t "$FIXTURE_TAG" "$HERE" >/dev/null
ok "an application image builds on the base (and its vhost passes nginx -t)"

# -----------------------------------------------------------------------------
info "booting"
docker network create "$NET" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network "$NET" \
    -e PHP_MEMORY_LIMIT=333M \
    -e FPM_MAX_CHILDREN=7 \
    -e PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    "$FIXTURE_TAG" >/dev/null

for _ in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo starting)"
    [[ "$status" == "healthy" || "$status" == "unhealthy" ]] && break
    sleep 1
done

if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" == "healthy" ]]; then
    ok "healthcheck passes via /fpm-ping (proves FPM answers, not just nginx)"
else
    bad "container never became healthy"
    docker logs "$NAME" 2>&1 | tail -30
    exit 1
fi

body="$(docker exec "$NAME" curl -sf http://127.0.0.1:8080/)"

# -----------------------------------------------------------------------------
info "runtime behaviour"

grep -q 'php-ok:' <<<"$body" \
    && ok "PHP executes through FastCGI" \
    || bad "PHP did not execute"

if grep -q '^uid:1000$' <<<"$body" && grep -q '^gid:1000$' <<<"$body"; then
    ok "runs as 1000:1000 — gid is not silently 82 (delgroup fix)"
else
    bad "wrong uid/gid: $(grep -E '^(uid|gid):' <<<"$body" | tr '\n' ' ')"
fi

grep -q '^memory_limit:333M$' <<<"$body" \
    && ok "runtime PHP ini override applied via PHP_INI_SCAN_DIR" \
    || bad "runtime PHP override missing: $(grep '^memory_limit:' <<<"$body")"

docker exec "$NAME" grep -q 'pm.max_children = 7' /usr/local/etc/php-fpm.d/zz-runtime.conf \
    && ok "runtime FPM pool override rendered (was build-arg-only before)" \
    || bad "FPM pool override not rendered"

grep -q '^hook_ran:yes$' <<<"$body" \
    && ok "/docker-entrypoint.d hook ran despite having no exec bit" \
    || bad "entrypoint hook did not run"

grep -q '^jit:disable$' <<<"$body" \
    && ok "OPcache JIT is off by default" \
    || bad "unexpected JIT setting: $(grep '^jit:' <<<"$body")"

# -----------------------------------------------------------------------------
info "the HTTPS if_not_empty fix"
# On plain HTTP the HTTPS param must be ABSENT, not present-and-empty.
grep -q '^https_isset:no$' <<<"$body" \
    && ok "\$_SERVER['HTTPS'] unset on plain HTTP (if_not_empty works)" \
    || bad "HTTPS is set on plain HTTP: $(grep '^https_' <<<"$body")"

fwd="$(docker exec "$NAME" curl -sf -H 'X-Forwarded-Proto: https' http://127.0.0.1:8080/)"
grep -q "^https_value:'on'\$" <<<"$fwd" \
    && ok "X-Forwarded-Proto: https maps to HTTPS=on" \
    || bad "forwarded scheme not propagated: $(grep '^https_' <<<"$fwd")"

# -----------------------------------------------------------------------------
info "real client IP behind a proxy"
# These must come from the DOCKER NETWORK, not loopback — that is how Traefik
# actually reaches the container, and loopback is intentionally untrusted.
from_network() {
    docker run --rm --network "$NET" --entrypoint curl "$FIXTURE_TAG" \
        -sf "$@" "http://${NAME}:8080/"
}

# Without set_real_ip_from, REMOTE_ADDR is the proxy's address for every
# request — which breaks Moodle login throttling, Drupal flood control and
# Laravel rate limiting, all silently.
rip="$(from_network -H 'X-Forwarded-For: 203.0.113.9')"
grep -q '^remote_addr:203.0.113.9$' <<<"$rip" \
    && ok "REMOTE_ADDR is the client, not the proxy (rate limiting works)" \
    || bad "real_ip not applied: $(grep '^remote_addr:' <<<"$rip")"

# The real chain is Cloudflare -> Traefik -> nginx. real_ip_recursive must skip
# the trusted hops right-to-left and land on the original client.
chain="$(from_network -H 'X-Forwarded-For: 203.0.113.9, 172.18.0.5, 10.1.2.3')"
grep -q '^remote_addr:203.0.113.9$' <<<"$chain" \
    && ok "real_ip_recursive walks a multi-hop X-Forwarded-For chain" \
    || bad "recursive real_ip failed: $(grep '^remote_addr:' <<<"$chain")"

# Loopback must NOT be trusted, or a forged header defeats the /fpm-ping ACL.
spoof="$(docker exec "$NAME" curl -sf -H 'X-Forwarded-For: 203.0.113.9' http://127.0.0.1:8080/)"
grep -q '^remote_addr:127.0.0.1$' <<<"$spoof" \
    && ok "X-Forwarded-For over loopback is ignored (ACLs stay sound)" \
    || bad "loopback is trusted for XFF: $(grep '^remote_addr:' <<<"$spoof")"

docker exec "$NAME" nginx -V 2>&1 | grep -q 'http_realip_module' \
    && ok "nginx built with http_realip_module" \
    || bad "nginx lacks http_realip_module — set_real_ip_from is a no-op"

# -----------------------------------------------------------------------------
info "extensions (the union — no INSTALL_* toggles)"
missing=()
for ext in apcu bcmath curl exif gd imagick intl ldap mbstring mysqli \
           opcache pcntl pdo_mysql pdo_pgsql pgsql redis soap sodium xml zip; do
    grep -q "\b${ext}\b" <<<"$(grep '^extensions:' <<<"$body")" || missing+=("$ext")
done
[[ ${#missing[@]} -eq 0 ]] \
    && ok "all 20 expected extensions present" \
    || bad "missing extensions: ${missing[*]}"

# -----------------------------------------------------------------------------
info "hardening"
docker exec "$NAME" sh -c 'test ! -w /usr/local/etc/php/conf.d' \
    && ok "php conf.d not writable by www-data (no auto_prepend_file persistence)" \
    || bad "php conf.d is writable by the runtime user"

docker exec "$NAME" sh -c 'test ! -e /tmp/supervisor.sock' \
    && ok "no supervisor control socket (no RCE process-spawn channel)" \
    || bad "supervisor control socket present"

docker exec "$NAME" sh -c 'test ! -f /var/log/nginx/access.log' \
    && ok "nginx writes no unrotated log files into the writable layer" \
    || bad "nginx is logging to a file"

# Regression guard: `nginx -t` creates the pid file. If a build step ran it as
# root, a root-owned pid is baked into the image and www-data can never
# overwrite it — nginx fails to start in every container. nginx-validate.sh
# exists to clean up after itself; this proves it did.
# Regression guards for build-time `nginx -t` side effects. Both of these were
# real: a root-owned pid file (nginx cannot start at all) and a root-owned
# default error.log (permission alert on every start).
docker exec "$NAME" sh -c '
    for f in /tmp/nginx.pid /var/tmp/run/nginx.pid; do
        [ -e "$f" ] || continue
        [ -O "$f" ] || exit 1
    done' \
    && ok "no foreign-owned pid file baked into the image" \
    || bad "a pid file owned by another uid is present — nginx cannot start"

docker exec "$NAME" sh -c '
    find /var/log/nginx /var/lib/nginx -mindepth 1 ! -user www-data 2>/dev/null | grep -q . && exit 1
    exit 0' \
    && ok "no foreign-owned files under nginx's prefix or log dir" \
    || bad "foreign-owned files under /var/log/nginx or /var/lib/nginx"

docker logs "$NAME" 2>&1 | grep -q 'could not open error log' \
    && bad "nginx logs 'could not open error log file' on startup" \
    || ok "no error-log permission alert at startup"

docker logs "$NAME" 2>&1 | grep -q 'GET /' \
    && ok "nginx access log reaches container stdout" \
    || bad "nginx access log not on stdout"

# -----------------------------------------------------------------------------
info "failure propagation"
# Kill PHP-FPM harder than supervisor's startretries can recover from, and
# assert the container actually exits instead of sitting there returning 502s.
docker exec "$NAME" sh -c '
    for _ in 1 2 3 4 5 6; do
        pkill -9 -x php-fpm 2>/dev/null || pkill -9 -f "php-fpm: master" 2>/dev/null || true
        sleep 1
    done' >/dev/null 2>&1 || true

for _ in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == "true" ]] || break
    sleep 1
done

if [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == "false" ]]; then
    ok "repeatedly killing php-fpm brings the container down (FATAL listener)"
else
    bad "php-fpm was killed but the container is still running"
    docker logs "$NAME" 2>&1 | tail -20
fi

# -----------------------------------------------------------------------------
printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '\033[32m✓ %d checks passed\033[0m for %s\n' "$pass" "$BASE_TAG"
else
    printf '\033[31m✗ %d passed, %d FAILED\033[0m for %s\n' "$pass" "$fail" "$BASE_TAG"
    exit 1
fi
