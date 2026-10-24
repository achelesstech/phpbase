#!/usr/bin/env bash
# =============================================================================
# test/run.sh — behavioural test for php-base (runtime image)
# =============================================================================
#   ./test/run.sh <base-image> [expected-php-line]
#
# Every check corresponds to something that was actually broken — in this
# image, or in an app built on it — or to a promise the README makes.
# =============================================================================
set -euo pipefail

BASE_TAG="${1:?usage: run.sh <base-image> [expected-php-line]}"
EXPECT_LINE="${2:-}"
SUFFIX="$$"
FIXTURE_TAG="php-base-fixture:test-${SUFFIX}"
NET="php-base-test-net-${SUFFIX}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Cleanup finds containers by LABEL: start() runs inside $(…), a subshell, so
# an array of names would never reach the cleanup trap.
LABEL="php-base-test=run-${SUFFIX}"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }

cleanup() {
    docker ps -aq --filter "label=${LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker rmi -f "$FIXTURE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# start NAME [docker-run-args...] — run the fixture detached, remember it.
start() {
    local name="$1-${SUFFIX}"; shift
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --label "$LABEL" --name "$name" --network "$NET" "$@" >/dev/null
    echo "$name"
}

# wait_health NAME [expected] [timeout] — wait for a terminal health state.
wait_health() {
    local name="$1" want="${2:-healthy}" timeout="${3:-60}" s
    for _ in $(seq 1 "$timeout"); do
        s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo gone)"
        [[ "$s" == "$want" ]] && return 0
        [[ "$s" == "exited" || "$s" == "gone" ]] && return 1
        sleep 1
    done
    return 1
}

get() { docker exec "$1" curl -sf "${@:2}" http://127.0.0.1:8080/; }
from_network() { local target="$1"; shift; docker run --rm --network "$NET" --entrypoint curl "$FIXTURE_TAG" -sf "$@" "http://${target}:8080/"; }

# -----------------------------------------------------------------------------
info "build"
docker build --quiet --build-arg "BASE_IMAGE=${BASE_TAG}" -t "$FIXTURE_TAG" "$HERE" >/dev/null
ok "an application image builds on the base (its vhost passes nginx-validate.sh)"
docker network create --label "$LABEL" "$NET" >/dev/null

# -----------------------------------------------------------------------------
info "boot (default role: nginx + php-fpm)"
APP="$(start app \
    -e PHP_MEMORY_LIMIT=333M \
    -e FPM_MAX_CHILDREN=7 \
    -e 'PHP_SESSION_SAVE_PATH=tcp://redis:6379?auth=s3cret&database=2' \
    -e $'PHP_INI_EXTRA=pcre.backtrack_limit = 5000000\nmbstring.language = Neutral' \
    "$FIXTURE_TAG")"
if wait_health "$APP"; then
    ok "healthcheck passes via /fpm-ping (FPM answers, not just nginx)"
else
    bad "container never became healthy"; docker logs "$APP" 2>&1 | tail -40; exit 1
fi
body="$(get "$APP")"
field() { grep -E "^$1:" <<<"$body" | head -1 | cut -d: -f2-; }

# -----------------------------------------------------------------------------
info "identity and versions"
grep -q '^php-ok:' <<<"$body" && ok "PHP executes through FastCGI ($(field php-ok))" || bad "PHP did not execute"
if [[ -n "$EXPECT_LINE" ]]; then
    [[ "$(field php-ok)" == "$EXPECT_LINE".* ]] && ok "PHP line is ${EXPECT_LINE}" || bad "expected PHP ${EXPECT_LINE}.x, got $(field php-ok)"
fi
[[ "$(field uid):$(field gid)" == "1000:1000" ]] && ok "runs as 1000:1000 (gid is not silently 82)" || bad "uid:gid is $(field uid):$(field gid)"
[[ "$(field home):$(field home_writable)" == "/home/www-data:yes" ]] \
    && ok "\$HOME exists and is writable (npm/git no longer EACCES)" || bad "HOME $(field home) writable=$(field home_writable)"
# busybox find has -user/-group but NOT -uid/-gid: with those it errors out,
# prints nothing, and a `| grep -q .` check passes vacuously. So: capture the
# output AND require find to succeed.
if orphans="$(docker run --rm --user 0 --entrypoint find "$BASE_TAG" / -xdev \( -user 82 -o -group 82 \) -print)"; then
    [[ -z "$orphans" ]] && ok "nothing in the image is owned by the deleted upstream uid/gid 82" \
        || bad "owned by the deleted uid/gid 82: $(tr '\n' ' ' <<<"$orphans")"
else
    bad "could not scan the image for uid/gid 82 files"
fi
docker exec "$APP" php-base-info --json | docker exec -i "$APP" php -r 'exit(json_decode(stream_get_contents(STDIN), true)["php"] === PHP_VERSION ? 0 : 1);' \
    && ok "php-base-info --json reports the running PHP version" || bad "php-base-info --json is wrong"
composer_v="$(docker exec "$APP" composer --version --no-ansi 2>/dev/null | awk '{print $3}')"
docker exec "$APP" php -r 'exit(version_compare($argv[1], "2.9.3", ">=") ? 0 : 1);' "$composer_v" \
    && ok "composer ${composer_v} (>= 2.9.3, Drupal's recommended minimum)" || bad "composer is ${composer_v}"

# -----------------------------------------------------------------------------
info "runtime configuration"
[[ "$(field memory_limit)" == "333M" ]] && ok "PHP_* env override applied" || bad "memory_limit=$(field memory_limit)"
[[ "$(field session_save_path)" == 'tcp://redis:6379?auth=s3cret&database=2' ]] \
    && ok "an ini value with ?, & and = survives rendering (quoted)" || bad "session.save_path=$(field session_save_path)"
[[ "$(field pcre_backtrack_limit)" == "5000000" ]] && ok "PHP_INI_EXTRA applied" || bad "PHP_INI_EXTRA not applied"
check "FPM pool override rendered into /tmp/php-base" docker exec "$APP" grep -q 'pm.max_children = 7' /tmp/php-base/fpm/zz-runtime.conf
grep -q '^hook_ran:yes$' <<<"$body" && ok "/docker-entrypoint.d hook ran despite having no exec bit" || bad "hook did not run"
if grep -q <<<"$(docker logs "$APP" 2>&1)" 'WARNING: .*writable'; then bad "root-owned hook triggered a writable-hook warning"; else ok "root-owned hook: no warning"; fi

# -----------------------------------------------------------------------------
info "production PHP defaults (no php.ini ships in the official image)"
[[ "$(field zend_assertions)" == "-1" ]] && ok "zend.assertions = -1 (compiled-in default runs every assert())" || bad "zend.assertions=$(field zend_assertions)"
[[ "$(field exception_ignore_args)" == "1" ]] && ok "zend.exception_ignore_args on (no secrets in stack traces)" || bad "exception_ignore_args=$(field exception_ignore_args)"
[[ "$(field request_order)" == "GP" ]] && ok "request_order = GP (cookies cannot shadow POST in \$_REQUEST)" || bad "request_order=$(field request_order)"
[[ "$(field upload_progress)" == "" || "$(field upload_progress)" == "0" ]] && ok "session.upload_progress disabled (PHP advisory 2026-10-23)" || bad "upload_progress=$(field upload_progress)"
[[ "$(field max_input_vars)" -ge 5000 ]] && ok "max_input_vars >= 5000 (Moodle environment check)" || bad "max_input_vars=$(field max_input_vars)"
[[ "$(field jit)" == "disable" ]] && ok "OPcache JIT off by default" || bad "jit=$(field jit)"

# -----------------------------------------------------------------------------
info "extensions — the union Laravel, Drupal, Moodle and WordPress need"
exts="$(field extensions)"
missing=()
for ext in apcu bcmath ctype curl dom exif fileinfo gd gmp iconv igbinary imagick intl ldap mbstring memcached \
           mysqli openssl pcntl pdo_mysql pdo_pgsql pdo_sqlite pgsql redis session simplexml soap sockets \
           sodium tokenizer uploadprogress xml xmlreader xmlwriter zip zlib "zend opcache"; do
    [[ ",${exts}," == *",${ext},"* ]] || missing+=("$ext")
done
[[ ${#missing[@]} -eq 0 ]] && ok "all 38 expected extensions loaded" || bad "missing: ${missing[*]}"
if grep -qiE 'warning|unable to load' <<<"$(docker exec "$APP" php -m 2>&1)"; then bad "php -m prints load warnings"; else ok "php -m loads cleanly"; fi
[[ "$(field argon2id)" == "yes" ]] && ok "argon2id password hashing (Drupal 12 default)" || bad "no argon2id"
[[ "$(field iconv_translit)" == Zlutouck* && "$(field iconv_translit)" != *'?'* ]] && ok "iconv //TRANSLIT works (GNU libiconv, not musl): $(field iconv_translit)" || bad "iconv translit: $(field iconv_translit)"
[[ "$(field intl_bdt)" == *৳* ]] && ok "intl has full ICU data (bn_BD currency: $(field intl_bdt))" || bad "intl_bdt=$(field intl_bdt)"
[[ "$(field imagick_formats)" == "JPEG,PNG,GIF,WEBP,HEIC,AVIF" ]] && ok "Imagick reads JPEG/PNG/GIF/WebP/HEIC/AVIF (WordPress HEIC uploads)" || bad "Imagick formats: $(field imagick_formats)"
[[ "$(field gd_webp_avif)" == "webp,avif" ]] && ok "GD writes WebP and AVIF" || bad "GD: $(field gd_webp_avif)"
[[ "$(field redis_codecs)" == "igbinary,zstd,lz4" ]] && ok "phpredis built with igbinary + zstd + lz4" || bad "redis codecs: $(field redis_codecs)"
[[ "$(field memcached_igbinary)" == "yes" ]] && ok "memcached built with igbinary" || bad "memcached igbinary: $(field memcached_igbinary)"

# -----------------------------------------------------------------------------
info "the HTTPS if_not_empty fix"
[[ "$(field https_isset)" == "no" ]] && ok "\$_SERVER['HTTPS'] unset on plain HTTP" || bad "HTTPS set on plain HTTP"
fwd="$(get "$APP" -H 'X-Forwarded-Proto: https')"
grep -q "^https_value:'on'\$" <<<"$fwd" && ok "X-Forwarded-Proto: https -> HTTPS=on" || bad "forwarded scheme not propagated"

# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
info "nginx body limit follows PHP post_max_size"
SMALL="$(start small -e PHP_POST_MAX_SIZE=1M -e PHP_UPLOAD_MAX_FILESIZE=1M "$FIXTURE_TAG")"
wait_health "$SMALL" || true
code_big="$(docker exec "$SMALL" sh -c 'head -c 2097152 /dev/zero | curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/octet-stream" --data-binary @- http://127.0.0.1:8080/')"
code_ok="$(docker exec "$SMALL" sh -c 'head -c 524288 /dev/zero | curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/octet-stream" --data-binary @- http://127.0.0.1:8080/')"
[[ "$code_big:$code_ok" == "413:200" ]] && ok "PHP_POST_MAX_SIZE=1M -> nginx 413 at 2M, 200 at 512K" || bad "body limit: 2M->${code_big}, 512K->${code_ok}"

# -----------------------------------------------------------------------------
info "FPM slowlog (FPM_SLOWLOG_TIMEOUT used to stop php-fpm from starting)"
SLOW="$(start slow -e FPM_SLOWLOG_TIMEOUT=1s "$FIXTURE_TAG")"
if wait_health "$SLOW"; then
    docker exec "$SLOW" curl -sf 'http://127.0.0.1:8080/index.php?sleep=2' >/dev/null || true
    sleep 1
    grep -q <<<"$(docker logs "$SLOW" 2>&1)" 'executing too slow' && ok "FPM_SLOWLOG_TIMEOUT works and traces reach the container log" || bad "no slowlog trace in logs"
else
    bad "FPM_SLOWLOG_TIMEOUT=1s: container did not become healthy"
fi

# -----------------------------------------------------------------------------
info "hardening"
writable=()
for d in /usr/local/etc/php/conf.d /usr/local/etc/php-fpm.d /etc/nginx /etc/nginx/conf.d /etc/nginx/server.d \
         /etc/nginx/presets /etc/supervisor/conf.d /docker-entrypoint.d /usr/local/bin; do
    docker exec "$APP" sh -c "test ! -w '$d'" || writable+=("$d")
done
[[ ${#writable[@]} -eq 0 ]] && ok "config, preset, hook and bin directories are not writable by www-data" || bad "writable by www-data: ${writable[*]}"
check "no supervisor control socket" docker exec "$APP" sh -c 'test -z "$(find /tmp /run -name "*.sock" 2>/dev/null)"'
check "nginx writes no log files into the writable layer" docker exec "$APP" sh -c 'test ! -s /var/log/nginx/access.log && test ! -s /var/log/nginx/error.log'
if grep -qE <<<"$(docker logs "$APP" 2>&1)" 'could not open error log|\[emerg\]|\[alert\]'; then bad "nginx alert/emerg at startup"; else ok "no nginx alerts at startup"; fi
grep -q <<<"$(docker logs "$APP" 2>&1)" 'GET / ' && ok "nginx access log reaches stdout" || bad "no access log on stdout"
if grep -q <<<"$(docker logs "$APP" 2>&1)" 'No file matches via include'; then bad "supervisord include warning"; else ok "supervisord starts without warnings"; fi

# Persistence: a file planted in the runtime dir must not survive a restart.
docker exec "$APP" sh -c 'printf "<?php function pwned() {}\n" > /tmp/evil.php; echo "auto_prepend_file = /tmp/evil.php" > /tmp/php-base/php/evil.ini'
docker restart "$APP" >/dev/null
wait_health "$APP" || true
after="$(get "$APP" || true)"
if grep -q '^pwned:no$' <<<"$after" && docker exec "$APP" test ! -e /tmp/php-base/php/evil.ini; then
    ok "an .ini planted in /tmp/php-base is wiped at restart and never loads"
else
    bad "planted ini survived a restart"
fi

# Read-only root filesystem.
RO="$(start ro --read-only --tmpfs /tmp "$FIXTURE_TAG")"
if wait_health "$RO" && grep -q '^php-ok:' <<<"$(get "$RO")"; then
    ok "read_only: true + tmpfs [/tmp] boots and serves PHP"
else
    bad "read-only root filesystem does not work"; docker logs "$RO" 2>&1 | tail -15
fi

# Writable hook: warning by default, refusal under PHP_BASE_STRICT=1.
hook_file="$(mktemp)"; printf '#!/bin/sh\ntrue\n' > "$hook_file"; chmod 0666 "$hook_file"
WH="$(start whook -v "${hook_file}:/docker-entrypoint.d/50-writable.sh" "$FIXTURE_TAG")"
wait_health "$WH" || true
grep -q <<<"$(docker logs "$WH" 2>&1)" 'WARNING: /docker-entrypoint.d/50-writable.sh is writable' \
    && ok "a runtime-writable hook is reported" || bad "writable hook not reported"
ST="$(start strict -e PHP_BASE_STRICT=1 -v "${hook_file}:/docker-entrypoint.d/50-writable.sh" "$FIXTURE_TAG")"
sleep 5
[[ "$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$ST")" == "exited:1" ]] \
    && ok "PHP_BASE_STRICT=1 refuses to start with a writable hook" || bad "strict mode did not refuse ($(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$ST"))"

# -----------------------------------------------------------------------------
info "background jobs"
SCH="$(start sched -e 'SCHEDULER_COMMAND=php -r "file_put_contents(\"/tmp/sched-ran\", time());"' -e SCHEDULER_INTERVAL=2 "$FIXTURE_TAG")"
wait_health "$SCH" || true
ran=no; for _ in $(seq 1 12); do docker exec "$SCH" test -f /tmp/sched-ran && { ran=yes; break; }; sleep 1; done
[[ "$ran" == yes ]] && ok "SCHEDULER_COMMAND runs inside the web container" || bad "scheduler never ran"

EVERY="$(start every --health-interval=2s --health-start-period=1s "$FIXTURE_TAG" php-base-every --name t 2 -- true)"
wait_health "$EVERY" healthy 20 && ok "php-base-every container: healthy via heartbeat (no compose override)" || bad "php-base-every container not healthy"
FAILING="$(start failing --health-interval=2s --health-retries=2 --health-start-period=1s -e HEALTHCHECK_MAX_AGE=3 "$FIXTURE_TAG" php-base-every --name f 1 -- false)"
wait_health "$FAILING" unhealthy 30 && ok "a job that keeps failing turns the container unhealthy" || bad "failing job stayed healthy"
WORKER="$(start worker --health-interval=2s --health-start-period=1s "$FIXTURE_TAG" sleep 300)"
wait_health "$WORKER" healthy 20 && ok "an arbitrary worker command is not falsely unhealthy" || bad "worker reported unhealthy"
t0=$(date +%s); docker stop -t 30 "$EVERY" >/dev/null; t1=$(date +%s)
[[ $((t1 - t0)) -lt 10 && "$(docker inspect -f '{{.State.ExitCode}}' "$EVERY")" == "0" ]] \
    && ok "php-base-every stops promptly and cleanly on SIGTERM ($((t1 - t0))s, exit 0)" || bad "php-base-every stop took $((t1 - t0))s exit $(docker inspect -f '{{.State.ExitCode}}' "$EVERY")"

# -----------------------------------------------------------------------------
info "shutdown and failure propagation"
t0=$(date +%s); docker stop -t 40 "$NOCF" >/dev/null; t1=$(date +%s)
[[ "$(docker inspect -f '{{.State.ExitCode}}' "$NOCF")" == "0" ]] \
    && ok "docker stop: graceful exit 0 in $((t1 - t0))s" || bad "web container exit code $(docker inspect -f '{{.State.ExitCode}}' "$NOCF") on stop"
docker exec "$APP" sh -c 'for _ in 1 2 3 4 5 6; do pkill -9 -x php-fpm 2>/dev/null || pkill -9 -f "php-fpm: master" 2>/dev/null || true; sleep 1; done' >/dev/null 2>&1 || true
for _ in $(seq 1 60); do [[ "$(docker inspect -f '{{.State.Running}}' "$APP")" == "true" ]] || break; sleep 1; done
[[ "$(docker inspect -f '{{.State.Running}}' "$APP")" == "false" ]] \
    && ok "repeatedly killing php-fpm brings the container down (FATAL listener)" || bad "php-fpm killed but container still running"

# -----------------------------------------------------------------------------
printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '\033[32m✓ %d checks passed\033[0m for %s\n' "$pass" "$BASE_TAG"
else
    printf '\033[31m✗ %d passed, %d FAILED\033[0m for %s\n' "$pass" "$fail" "$BASE_TAG"
    exit 1
fi
