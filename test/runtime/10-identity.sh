# shellcheck shell=bash
# identity — PHP line, user, home, file ownership, version reporting.
# (Composer is a -dev tool now: test/run-dev.sh checks it.)
# shellcheck disable=SC2154  # body is set by 00-boot.sh.

info "identity and versions"
grep -q '^php-ok:' <<<"$body" && ok "PHP executes through FastCGI ($(field php-ok))" || bad "PHP did not execute"
if [[ -n "$LINE" ]]; then
    [[ "$(field php-ok)" == "$LINE".* ]] && ok "PHP line is ${LINE}" || bad "expected PHP ${LINE}.x, got $(field php-ok)"
fi
[[ "$(field uid):$(field gid)" == "1000:1000" ]] && ok "runs as 1000:1000 (gid is not silently 82)" || bad "uid:gid is $(field uid):$(field gid)"
[[ "$(field home):$(field home_writable)" == "/home/www-data:yes" ]] \
    && ok "\$HOME exists and is writable (npm/git no longer EACCES)" || bad "HOME $(field home) writable=$(field home_writable)"
# busybox find has -user/-group but NOT -uid/-gid: with those it errors out,
# prints nothing, and a `| grep -q .` check passes vacuously. So: capture the
# output AND require find to succeed.
if orphans="$(docker run --rm --label "$LABEL" --user 0 --entrypoint find "$IMAGE" / -xdev \( -user 82 -o -group 82 \) -print)"; then
    [[ -z "$orphans" ]] && ok "nothing in the image is owned by the deleted upstream uid/gid 82" \
        || bad "owned by the deleted uid/gid 82: $(tr '\n' ' ' <<<"$orphans")"
else
    bad "could not scan the image for uid/gid 82 files"
fi
docker exec "$APP" php-base-info --json | docker exec -i "$APP" php -r 'exit(json_decode(stream_get_contents(STDIN), true)["php"] === PHP_VERSION ? 0 : 1);' \
    && ok "php-base-info --json reports the running PHP version" || bad "php-base-info --json is wrong"
