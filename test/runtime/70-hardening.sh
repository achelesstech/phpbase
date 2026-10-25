# shellcheck shell=bash
# hardening — root-owned config, no stray sockets or log files, a runtime dir
# that is wiped at every start, and writable-hook detection. The read-only root
# filesystem is covered by boot's hardened-flags check: start() runs its
# containers with --read-only.

info "hardening"
writable=()
for d in /usr/local/etc/php/conf.d /usr/local/etc/php-fpm.d /etc/nginx /etc/nginx/conf.d /etc/nginx/server.d \
         /etc/nginx/presets /etc/php-base /etc/php-base/s6 /docker-entrypoint.d /usr/local/bin; do
    docker exec "$APP" sh -c "test ! -w '$d'" || writable+=("$d")
done
[[ ${#writable[@]} -eq 0 ]] && ok "config, preset, s6, hook and bin directories are not writable by www-data" || bad "writable by www-data: ${writable[*]}"
# $HOME is recreated at every start; 0750 keeps other uids out of dotfiles.
home_stat="$(docker exec "$APP" stat -c '%a %U:%G' /tmp/php-base/home)"
[[ "$home_stat" == "750 www-data:www-data" ]] && ok "/tmp/php-base/home is 750 www-data:www-data" || bad "/tmp/php-base/home is '${home_stat}'"
check "nginx writes no log files into the writable layer" docker exec "$APP" sh -c 'test ! -s /var/log/nginx/access.log && test ! -s /var/log/nginx/error.log'
if grep -qE <<<"$(docker logs "$APP" 2>&1)" 'could not open error log|\[emerg\]|\[alert\]'; then bad "nginx alert/emerg at startup"; else ok "no nginx alerts at startup"; fi
grep -q <<<"$(docker logs "$APP" 2>&1)" 'GET / ' && ok "nginx access log reaches stdout" || bad "no access log on stdout"

# A v1 app that still overrides the command with supervisord must fail at
# start with a message naming what to use instead (review focus 1). The
# timeout is for the failure case: a supervisord that still starts never exits.
if out="$(timeout 20 docker run --rm --label "$LABEL" "$IMAGE" supervisord -c /etc/supervisor/supervisord.conf 2>&1)"; then
    bad "a v1 'supervisord -c …' command still starts"
elif grep -q 'php-base-web' <<<"$out"; then
    ok "a v1 'supervisord -c …' command fails at start and names php-base-web"
else
    bad "the supervisord command fails without naming php-base-web: $(tail -1 <<<"$out")"
fi

# Persistence: a file planted in the runtime dir must not survive a restart.
# Plain, not hardened: a tmpfs /tmp comes back empty after `docker restart`,
# which would pass this without the entrypoint's wipe ever running.
PERSIST="$(start_plain persist "$FIXTURE_TAG")"
if wait_health "$PERSIST"; then
    docker exec "$PERSIST" sh -c 'printf "<?php function pwned() {}\n" > /tmp/evil.php; echo "auto_prepend_file = /tmp/evil.php" > /tmp/php-base/php/evil.ini'
    docker restart "$PERSIST" >/dev/null
    wait_health "$PERSIST" || true
    after="$(get "$PERSIST" || true)"
    if grep -q '^pwned:no$' <<<"$after" && docker exec "$PERSIST" test -e /tmp/evil.php \
        && docker exec "$PERSIST" test ! -e /tmp/php-base/php/evil.ini; then
        ok "an .ini planted in /tmp/php-base is wiped at restart and never loads"
    else
        bad "planted ini survived a restart"
    fi
else
    bad "persist container never became healthy"
fi

# Writable hook: warning by default, refusal under PHP_BASE_STRICT=1.
hook_file="${TMPD}/50-writable.sh"; printf '#!/bin/sh\ntrue\n' > "$hook_file"; chmod 0666 "$hook_file"
WH="$(start whook -v "${hook_file}:/docker-entrypoint.d/50-writable.sh" "$FIXTURE_TAG")"
wait_health "$WH" || true
grep -q <<<"$(docker logs "$WH" 2>&1)" 'WARNING: /docker-entrypoint.d/50-writable.sh is writable' \
    && ok "a runtime-writable hook is reported" || bad "writable hook not reported"
ST="$(start strict -e PHP_BASE_STRICT=1 -v "${hook_file}:/docker-entrypoint.d/50-writable.sh" "$FIXTURE_TAG")"
sleep 5
[[ "$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$ST")" == "exited:1" ]] \
    && ok "PHP_BASE_STRICT=1 refuses to start with a writable hook" || bad "strict mode did not refuse ($(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$ST"))"
