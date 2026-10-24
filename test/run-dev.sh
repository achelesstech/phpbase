#!/usr/bin/env bash
# =============================================================================
# test/run-dev.sh — checks specific to the :X.Y-dev image
# =============================================================================
#   ./test/run-dev.sh <dev-image>
# =============================================================================
set -euo pipefail

IMG="${1:?usage: run-dev.sh <dev-image>}"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
php_() { docker run --rm "$@"; }

printf '\n\033[1mdev image %s\033[0m\n' "$IMG"
line="$(php_ "$IMG" php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
# Capture first: `cmd | grep -q` under pipefail fails when grep exits early.
mods="$(php_ "$IMG" php -m)"

if grep -qx 'Xdebug' <<<"$mods"; then
    [[ "$(php_ "$IMG" php -r 'echo implode(",", xdebug_info("mode"));')" == "" ]] \
        && ok "Xdebug loaded, mode off by default (no slowdown until asked)" || bad "Xdebug is active by default"
    [[ "$(php_ -e XDEBUG_MODE=debug,coverage "$IMG" php -r '$m = xdebug_info("mode"); sort($m); echo implode(",", $m);')" == "coverage,debug" ]] \
        && ok "XDEBUG_MODE env switches it on" || bad "XDEBUG_MODE ignored"
else
    case "$line" in 8.6) ok "Xdebug absent on prerelease PHP ${line} (allowed)";; *) bad "Xdebug missing";; esac
fi
if grep -qx 'pcov' <<<"$mods"; then
    [[ "$(php_ "$IMG" php -r 'echo ini_get("pcov.enabled");')" == "0" ]] && ok "PCOV loaded, disabled by default" || bad "PCOV enabled by default"
else
    bad "PCOV missing"
fi
[[ "$(php_ "$IMG" php -r 'echo ini_get("zend.assertions");')" == "1" ]] && ok "assertions on" || bad "assertions not on"
[[ "$(php_ "$IMG" php -r 'echo ini_get("opcache.validate_timestamps");')" == "1" ]] && ok "OPcache revalidates (code edits show up)" || bad "validate_timestamps off"
php_ "$IMG" git --version >/dev/null && ok "git available (composer VCS repositories)" || bad "no git"
[[ "$(php_ "$IMG" php-base-info --short)" == *"dev;"* ]] && ok "php-base-info reports the dev variant" || bad "variant label wrong"
if grep -qiE 'warning|unable to load' <<<"$(php_ "$IMG" php -m 2>&1)"; then bad "load warnings"; else ok "php -m loads cleanly"; fi

printf '\n'
if [[ $fail -eq 0 ]]; then printf '\033[32m✓ %d dev checks passed\033[0m for %s\n' "$pass" "$IMG"; else printf '\033[31m✗ %d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
