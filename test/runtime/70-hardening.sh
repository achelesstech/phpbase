# shellcheck shell=bash
# hardening — root-owned config, no stray sockets or log files, a runtime dir
# that is wiped at every start, and hook owner/mode checks. The read-only root
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
# Traefik logs every request; NGINX_ACCESS_LOG=main|json turns nginx's on (55-nginx.sh).
if grep -q <<<"$(docker logs "$APP" 2>&1)" '"GET / '; then bad "nginx access log is on by default"; else ok "nginx access log is off by default"; fi

# PHP-FPM's socket is the only one: nothing else under /tmp accepts connections.
tmp_sockets="$(docker exec "$APP" find /tmp -type s 2>&1 || true)"
[[ "$tmp_sockets" == "/tmp/php-base/php-fpm.sock" ]] \
    && ok "the only socket under /tmp is /tmp/php-base/php-fpm.sock" || bad "sockets under /tmp: '${tmp_sockets}'"

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

# Hook owner and mode, baked into an image: built FROM the fixture with
# COPY --chown/--chmod, so host file ownership plays no part.
# hook_image NAME LINE... — build the fixture plus these Dockerfile lines (with
# hook.sh in the context); print its tag. lib.sh's cleanup removes the tag.
hook_image() {
    local ctx="${TMPD}/hook-$1" tag="${FIXTURE_TAG}-hook-$1"
    mkdir -p "$ctx"
    printf '#!/bin/sh\ntrue\n' > "${ctx}/hook.sh"
    printf '%s\n' "FROM ${FIXTURE_TAG}" "${@:2}" > "${ctx}/Dockerfile"
    docker build --quiet -t "$tag" "$ctx" >/dev/null
    echo "$tag"
}
uid_image="$(hook_image uid 'COPY --chown=1000:1000 --chmod=0555 hook.sh /docker-entrypoint.d/50-x.sh')"
mode_image="$(hook_image mode 'COPY --chown=0:0 --chmod=0666 hook.sh /docker-entrypoint.d/50-x.sh')"
# The Kubernetes ConfigMap/Secret layout: the hook is a symlink (mode 777 as
# lstat sees it) to a root-owned 0644 file. The target is what runs. mkdir
# first: COPY --chmod would give the new ..data directory mode 0644 as well.
link_image="$(hook_image link 'USER root' \
    'RUN mkdir -m 0755 /docker-entrypoint.d/..data' \
    'COPY --chmod=0644 hook.sh /docker-entrypoint.d/..data/50-x.sh' \
    'RUN ln -s ..data/50-x.sh /docker-entrypoint.d/50-x.sh' \
    'USER www-data')"
HU="$(start hookuid "$uid_image")"
wait_health "$HU" || true
grep -q <<<"$(docker logs "$HU" 2>&1)" 'WARNING: /docker-entrypoint.d/50-x.sh is not root-owned' \
    && ok "a hook not owned by root is reported" || bad "non-root-owned hook not reported"
HUS="$(start hookuidstrict -e PHP_BASE_STRICT=1 "$uid_image")"
sleep 5
[[ "$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$HUS")" == "exited:1" ]] \
    && ok "PHP_BASE_STRICT=1 refuses to start with a non-root-owned hook" \
    || bad "strict mode did not refuse a non-root-owned hook ($(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$HUS"))"
HM="$(start hookmode "$mode_image")"
wait_health "$HM" || true
grep -q <<<"$(docker logs "$HM" 2>&1)" 'WARNING: /docker-entrypoint.d/50-x.sh is writable by group or others' \
    && ok "a root-owned, group/other-writable hook is reported" || bad "group/other-writable hook not reported"
if grep -q <<<"$(docker logs "$APP" 2>&1)" 'WARNING: /docker-entrypoint.d/10-fixture.sh'; then
    bad "the fixture's root-owned 0644 hook triggered a warning"
else
    ok "the fixture's root-owned 0644 hook: no warning"
fi
HL="$(start hooklink -e PHP_BASE_STRICT=1 "$link_image")"
wait_health "$HL" && ok "PHP_BASE_STRICT=1 starts with a hook symlinked to a root-owned 0644 file" \
    || bad "strict mode refused a hook symlinked to a root-owned 0644 file"
hl_logs="$(docker logs "$HL" 2>&1)"
if grep -q <<<"$hl_logs" 'WARNING: /docker-entrypoint.d/50-x.sh'; then
    bad "a hook symlinked to a root-owned 0644 file triggered a warning"
elif ! grep -q <<<"$hl_logs" 'running /docker-entrypoint.d/50-x.sh'; then
    bad "the symlinked hook never ran, so the no-warning check proves nothing"
else
    ok "a hook symlinked to a root-owned 0644 file runs with no warning"
fi
docker rm -f -v "$HU" "$HUS" "$HM" "$HL" >/dev/null
