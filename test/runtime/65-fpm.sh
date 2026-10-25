# shellcheck shell=bash
# fpm — the Unix-socket listener, FPM_MAX_CHILDREN=auto sizing, the request
# terminate timeout, security.limit_extensions and PHP_DISABLE_FUNCTIONS.

info "PHP-FPM listener and pool"
# /proc/net/tcp{,6}: local_address is HEX_IP:HEX_PORT, st 0A is LISTEN.
listen_9000="$(docker exec "$APP" cat /proc/net/tcp /proc/net/tcp6 | awk '$2 ~ /:2328$/ && $4 == "0A"')"
[[ -z "$listen_9000" ]] && ok "nothing listens on TCP 9000" || bad "something listens on 9000: ${listen_9000}"
sock="$(docker exec "$APP" stat -c '%A %U' /tmp/php-base/php-fpm.sock 2>&1 || true)"
[[ "$sock" == "srw-rw---- www-data" ]] && ok "FPM listens on /tmp/php-base/php-fpm.sock (0660, www-data)" || bad "php-fpm.sock: '${sock}'"

pool="$(docker exec "$APP" cat /tmp/php-base/fpm/zz-runtime.conf)"
grep -qx 'request_terminate_timeout = 300s' <<<"$pool" \
    && ok "request_terminate_timeout defaults to 300s" || bad "no 'request_terminate_timeout = 300s' in the rendered pool"
check "php-fpm -t passes with the rendered pool" docker exec "$APP" php-fpm -t
# -tt dumps the parsed config at NOTICE, which the image's log_level=warning
# hides, so a throwaway wrapper config lowers the level after the real one.
fpm_dump="$(docker exec "$APP" sh -c 'f="$(mktemp)"; printf "include = /usr/local/etc/php-fpm.conf\n[global]\nlog_level = notice\n" > "$f"; php-fpm -tt -y "$f" 2>&1; rm -f "$f"' || true)"
grep -qE 'security\.limit_extensions = \.php$' <<<"$fpm_dump" \
    && ok "security.limit_extensions = .php" || bad "php-fpm -tt does not report 'security.limit_extensions = .php'"

# auto under the hardened flags: 1024M − (256M OPcache + 64M + 256M tmpfs) = 448M → 7.
AUTO="$(start auto "$FIXTURE_TAG")"
wait_health "$AUTO" || true
grep -qF 'fpm: max_children=7 (limit 1024M, worker 64M, reserve 576M)' <<<"$(docker logs "$AUTO" 2>&1)" \
    && ok "FPM_MAX_CHILDREN=auto: 7 workers under 1g with a 256m tmpfs, and says why" || bad "auto (1g, 256m tmpfs): $(grep 'fpm:' <<<"$(docker logs "$AUTO" 2>&1)" || echo 'no fpm: line')"
check "auto renders pm.max_children = 7" docker exec "$AUTO" grep -qx 'pm.max_children = 7' /tmp/php-base/fpm/zz-runtime.conf

# The OPcache size accepts a unit, as PHP does: 1024M − (128M + 64M + 256M) = 576M → 9.
opcache_out="$(docker run --rm --label "$LABEL" "${HARDENED[@]}" -e PHP_OPCACHE_MEMORY=128M "$FIXTURE_TAG" true 2>&1 || true)"
grep -qF 'fpm: max_children=9 (limit 1024M, worker 64M, reserve 448M)' <<<"$opcache_out" \
    && ok "PHP_OPCACHE_MEMORY=128M counts as 128M in the reserve" || bad "PHP_OPCACHE_MEMORY=128M: $(tail -1 <<<"$opcache_out")"

# A leading zero is not a worker count (08 would also break shell arithmetic).
if zero_out="$(docker run --rm --label "$LABEL" -e FPM_MAX_CHILDREN=08 "$FIXTURE_TAG" true 2>&1)"; then
    bad "FPM_MAX_CHILDREN=08 was accepted"
else
    grep -qF 'FPM_MAX_CHILDREN must be' <<<"$zero_out" \
        && ok "FPM_MAX_CHILDREN=08 is refused with a clear error" || bad "FPM_MAX_CHILDREN=08: $(tail -1 <<<"$zero_out")"
fi

# Review focus 3: no memory limit, or /tmp that is not a tmpfs, never errors.
no_memory=()
for flag in "${HARDENED[@]}"; do [[ "$flag" == --memory || "$flag" == 1g ]] || no_memory+=("$flag"); done
UNLIMITED="$(start_plain unlimited "${no_memory[@]}" "$FIXTURE_TAG")"
wait_health "$UNLIMITED" || true
grep -qF 'fpm: max_children=12 (no memory limit)' <<<"$(docker logs "$UNLIMITED" 2>&1)" \
    && ok "auto without a memory limit: 12 workers" || bad "auto (no limit): $(grep 'fpm:' <<<"$(docker logs "$UNLIMITED" 2>&1)" || echo 'no fpm: line')"

tmp_volume="php-base-test-tmp-${SUFFIX}"
docker volume create --label "$LABEL" "$tmp_volume" >/dev/null
no_tmpfs=()
for flag in "${HARDENED[@]}"; do [[ "$flag" == --tmpfs || "$flag" == /tmp:* ]] || no_tmpfs+=("$flag"); done
TMPVOL="$(start_plain tmpvol "${no_tmpfs[@]}" -v "${tmp_volume}:/tmp" "$FIXTURE_TAG")"
wait_health "$TMPVOL" || true
tmpvol_line="$(grep 'fpm:' <<<"$(docker logs "$TMPVOL" 2>&1)" || echo 'no fpm: line')"
[[ "$tmpvol_line" == *'max_children=11 '* && "$tmpvol_line" == *'reserve 320M'* ]] \
    && ok "auto with a volume on /tmp: no tmpfs reserve, 11 workers" || bad "auto (/tmp volume): ${tmpvol_line}"

# disable_functions applies to web requests only; the CLI keeps exec().
NOEXEC="$(start noexec -e PHP_DISABLE_FUNCTIONS=exec,shell_exec "$FIXTURE_TAG")"
wait_health "$NOEXEC" || true
web_exec="$(get_path "$NOEXEC" '/index.php?exec=1' || true)"
cli_exec="$(docker exec "$NOEXEC" php -r 'echo function_exists("exec") ? "yes" : "no";' 2>&1 || true)"
[[ "$web_exec" == "exec:disabled" ]] && ok "PHP_DISABLE_FUNCTIONS disables exec() for web requests" || bad "web exec(): '${web_exec}'"
[[ "$cli_exec" == "yes" ]] && ok "PHP_DISABLE_FUNCTIONS leaves the CLI alone" || bad "CLI function_exists(exec): '${cli_exec}'"
