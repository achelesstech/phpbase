#!/usr/bin/env bash
# =============================================================================
# test/run-dev.sh — checks specific to the :X.Y-dev image
# =============================================================================
#   ./test/run-dev.sh <dev-image>
#
# The dev image is the runtime plus what building needs: Composer, git, the
# PHP sources and headers, and the docker-php-* helpers. It is also the
# `composer install` stage of every app image.
# =============================================================================
set -euo pipefail

IMG="${1:?usage: run-dev.sh <dev-image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Every container carries LABEL, so an interrupted run leaves nothing behind.
LABEL="php-base-test=dev-$$"
cleanup() {
    docker ps -aq --filter "label=${LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=${LABEL}" | xargs -r docker volume rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
# php_ [docker-run-args…] IMAGE CMD… — stdout only. The entrypoint logs its
# "[entrypoint] …" lines to stderr; they are not part of any result here.
php_() { docker run --rm --label "$LABEL" "$@" 2>/dev/null; }
# php_all — stdout and stderr, without the entrypoint's own lines: for checks
# that look for warnings PHP prints on stderr.
php_all() { docker run --rm --label "$LABEL" "$@" 2>&1 | { grep -v '^\[entrypoint\] ' || true; }; }

printf '\n\033[1mdev image %s\033[0m\n' "$IMG"
line="$(php_ "$IMG" php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
# Pre-release lines may lack the debugger and the coverage driver (their
# configure refuses an unreleased PHP); versions.json says which lines those are.
prerelease="$(jq -r --arg l "$line" '.php[] | select(.line == $l) | .prerelease // false' "$HERE/../versions.json")"
labels="$(docker image inspect "$IMG" --format '{{json .Config.Labels}}')"
label() { jq -r --arg k "$1" '.[$k] // ""' <<<"$labels"; }
# Capture first: `cmd | grep -q` under pipefail fails when grep exits early.
mods="$(php_ "$IMG" php -m)"

if grep -qx 'Xdebug' <<<"$mods"; then
    [[ "$(php_ "$IMG" php -r 'echo implode(",", xdebug_info("mode"));')" == "" ]] \
        && ok "Xdebug loaded, mode off by default (no slowdown until asked)" || bad "Xdebug is active by default"
    [[ "$(php_ -e XDEBUG_MODE=debug,coverage "$IMG" php -r '$m = xdebug_info("mode"); sort($m); echo implode(",", $m);')" == "coverage,debug" ]] \
        && ok "XDEBUG_MODE env switches it on" || bad "XDEBUG_MODE ignored"
elif [[ "$prerelease" == true ]]; then
    ok "Xdebug absent on prerelease PHP ${line} (allowed)"
else
    bad "Xdebug missing"
fi
if grep -qx 'pcov' <<<"$mods"; then
    [[ "$(php_ "$IMG" php -r 'echo ini_get("pcov.enabled");')" == "0" ]] && ok "PCOV loaded, disabled by default" || bad "PCOV enabled by default"
    [[ "$(php_ "$IMG" php -d pcov.enabled=1 -r 'echo ini_get("pcov.enabled");')" == "1" ]] \
        && ok "PCOV switches on with -d pcov.enabled=1" || bad "PCOV cannot be switched on"
elif [[ "$prerelease" == true ]]; then
    ok "PCOV absent on prerelease PHP ${line} (allowed)"
else
    bad "PCOV missing"
fi
[[ "$(php_ "$IMG" php -r 'echo ini_get("zend.assertions");')" == "1" ]] && ok "assertions on" || bad "assertions not on"
[[ "$(php_ "$IMG" php -r 'echo ini_get("opcache.validate_timestamps");')" == "1" ]] && ok "OPcache revalidates (code edits show up)" || bad "validate_timestamps off"

composer_v="$(php_ "$IMG" composer --version --no-ansi | awk '{print $3}')" || true
php_ "$IMG" php -r 'exit(version_compare($argv[1], "2.9.3", ">=") ? 0 : 1);' "$composer_v" \
    && ok "composer ${composer_v} (>= 2.9.3, Drupal's recommended minimum)" || bad "composer is '${composer_v}'"
php_ "$IMG" git --version >/dev/null && ok "git runs (composer VCS repositories)" || bad "no git"
php_ "$IMG" unzip -v >/dev/null && ok "unzip runs (composer dist archives)" || bad "no unzip"

# The image builds an extension the way the official image does.
# shellcheck disable=SC2016  # $PHPIZE_DEPS expands inside the container.
if out="$(docker run --rm --label "$LABEL" --user 0 "$IMG" sh -c 'apk add --no-cache $PHPIZE_DEPS >/dev/null && docker-php-ext-install calendar >/dev/null && php -r "exit(extension_loaded(\"calendar\") ? 0 : 1);"' 2>&1)"; then
    ok "docker-php-ext-install builds and enables an extension (calendar)"
else
    bad "docker-php-ext-install calendar failed"; tail -20 <<<"$out"
fi
# Same package list as upstream's PHPIZE_DEPS, compared as words: upstream
# separates them with tabs.
words() { tr -s '[:space:]' '\n' <<<"$1" | sed '/^$/d' | paste -sd' '; }
upstream="$(label io.github.achelesstech.php-base.upstream-image)@$(label io.github.achelesstech.php-base.upstream-digest)"
# shellcheck disable=SC2016  # $PHPIZE_DEPS expands inside the container.
ours="$(words "$(php_ "$IMG" sh -c 'echo "$PHPIZE_DEPS"' || true)")"
# The upstream image's amd64 Env: from the local image cache when the build
# left that exact digest there (no Docker Hub round trip, so no 429s), else
# from the registry. Sets env_json (or the error) and env_source.
upstream_env() {
    local config
    env_json="$(docker image inspect -f '{{if eq .Architecture "amd64"}}{{json .Config.Env}}{{end}}' "$upstream" 2>/dev/null)" || env_json=""
    if [[ -n "$env_json" ]]; then
        env_source="local image cache"; return 0
    fi
    env_source="registry"
    config="$(docker buildx imagetools inspect "$upstream" --format '{{json .Image}}' 2>&1)" || { env_json="$config"; return 1; }
    env_json="$(jq -c '.["linux/amd64"].config.Env' <<<"$config")"
}
env_json=""; env_source=""
if upstream_env \
    && theirs="$(jq -r '.[] | select(startswith("PHPIZE_DEPS=")) | sub("^PHPIZE_DEPS="; "")' <<<"$env_json")"; then
    theirs="$(words "$theirs")"
    [[ -n "$ours" && "$ours" == "$theirs" ]] && ok "PHPIZE_DEPS matches ${upstream%%@*} (${ours}; from the ${env_source})" \
        || bad "PHPIZE_DEPS is '${ours}', upstream has '${theirs}' (from the ${env_source})"
else
    bad "could not read PHPIZE_DEPS from '${upstream}' (${env_source}): $(head -1 <<<"$env_json")"
fi

[[ "$(label io.github.achelesstech.php-base.variant)" == dev ]] && ok "variant label is dev" \
    || bad "variant label is '$(label io.github.achelesstech.php-base.variant)'"
[[ "$(php_ "$IMG" php-base-info --short)" == *"dev;"* ]] && ok "php-base-info reports the dev variant" || bad "php-base-info variant wrong"
if grep -qiE 'warning|unable to load' <<<"$(php_all "$IMG" php -m)"; then bad "load warnings"; else ok "php -m loads cleanly"; fi

printf '\n'
if [[ $fail -eq 0 ]]; then printf '\033[32m✓ %d dev checks passed\033[0m for %s\n' "$pass" "$IMG"; else printf '\033[31m✗ %d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
