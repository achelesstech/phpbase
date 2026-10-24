# shellcheck shell=bash
# contents — the runtime image is PHP, nginx and their libraries on a clean
# Alpine: no compiler inputs, no Composer, no setuid files, and labels that say
# exactly which upstream bytes it came from.

info "contents (runtime on a clean Alpine)"

# Build tooling, sources and Composer belong to the -dev image only.
tooling=(
    /usr/local/bin/composer /usr/src/php.tar.xz /usr/local/include
    /usr/local/bin/phpize /usr/local/bin/php-config /usr/local/bin/docker-php-ext-install
    /usr/local/bin/pecl /usr/local/bin/pear /usr/local/bin/php-cgi /usr/local/bin/phpdbg
    /usr/local/lib/php/build /usr/local/php/man
)
# shellcheck disable=SC2016  # $p expands inside the container.
present="$(docker exec "$APP" sh -c 'for p; do if [ -e "$p" ] || [ -L "$p" ]; then echo "$p"; fi; done' sh "${tooling[@]}")"
[[ -z "$present" ]] && ok "no build tooling, PHP sources or Composer in the runtime image" \
    || bad "build tooling in the runtime image: $(tr '\n' ' ' <<<"$present")"

# As root, so that no directory is unreadable; and find must succeed, or an
# empty result proves nothing.
if setid="$(docker run --rm --label "$LABEL" --user 0 --entrypoint find "$IMAGE" / -xdev -type f -perm /6000 -print)"; then
    [[ -z "$setid" ]] && ok "no setuid or setgid files" || bad "setuid/setgid files: $(tr '\n' ' ' <<<"$setid")"
else
    bad "could not scan the image for setuid/setgid files"
fi

labels="$(docker image inspect "$IMAGE" --format '{{json .Config.Labels}}')"
label() { jq -r --arg k "$1" '.[$k] // ""' <<<"$labels"; }
php_v="$(docker exec "$APP" php -r 'echo PHP_VERSION;')"
alpine_v="$(docker exec "$APP" cat /etc/alpine-release)"
line="${LINE:-$(cut -d. -f1,2 <<<"$php_v")}"
# Pre-release lines come from the -rc tag (versions.json, as the resolver reads it).
if [[ "$(jq -r --arg l "$line" '.php[] | select(.line == $l) | .prerelease // false' "$HERE/../versions.json")" == true ]]; then
    want_upstream="php:${line}-rc-fpm-alpine"
else
    want_upstream="php:${line}-fpm-alpine"
fi
p=io.github.achelesstech.php-base
[[ "$(label org.opencontainers.image.base.name)" == docker.io/library/alpine:* ]] \
    && ok "base.name is the Alpine image ($(label org.opencontainers.image.base.name))" \
    || bad "base.name is '$(label org.opencontainers.image.base.name)'"
[[ "$(label "$p.upstream-image")" == "$want_upstream" ]] && ok "upstream-image is ${want_upstream}" \
    || bad "upstream-image is '$(label "$p.upstream-image")', expected ${want_upstream}"
[[ "$(label "$p.upstream-digest")" == sha256:* ]] && ok "upstream-digest is a digest" \
    || bad "upstream-digest is '$(label "$p.upstream-digest")'"
[[ "$(label "$p.php-version")" == "$php_v" ]] && ok "php-version label matches the running PHP (${php_v})" \
    || bad "php-version label is '$(label "$p.php-version")', PHP is ${php_v}"
# The label is the pinned Alpine base; `apk upgrade` may be a point release ahead.
alpine_l="$(label "$p.alpine-version")"
if [[ "${alpine_l%.*}" == "${alpine_v%.*}" && "$(printf '%s\n' "$alpine_l" "$alpine_v" | sort -V | head -1)" == "$alpine_l" ]]; then
    ok "alpine-version label ${alpine_l} is the runtime's minor, not past /etc/alpine-release (${alpine_v})"
else
    bad "alpine-version label is '${alpine_l}', Alpine is ${alpine_v}"
fi
[[ "$(label "$p.variant")" == runtime ]] && ok "variant label is runtime" \
    || bad "variant label is '$(label "$p.variant")'"
