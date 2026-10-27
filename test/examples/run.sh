#!/usr/bin/env bash
# =============================================================================
# test/examples/run.sh — run the example tests on one local base build
# =============================================================================
#   test/examples/run.sh <php-line> [test…]
#   test/examples/run.sh 8.4 laravel traefik-routing
#
# With no test named, runs every test/examples/<test>.sh. PHP_BASE_IMAGE /
# PHP_BASE_DEV_IMAGE pick the base (default local/php-base:<line>[-dev]).
#
# An app example (laravel, drupal, wordpress, moodle) is skipped on a line
# whose versions.json frameworks don't list it: that pair is not supported.
# The traefik-* tests don't use the base and run on any line.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINE="${1:?usage: run.sh <php-line> [test…]}"
shift
export PHP_BASE_IMAGE="${PHP_BASE_IMAGE:-local/php-base:${LINE}}"
export PHP_BASE_DEV_IMAGE="${PHP_BASE_DEV_IMAGE:-local/php-base:${LINE}-dev}"

frameworks="$(jq -ce --arg l "$LINE" '.php[] | select(.line == $l) | .frameworks | keys' "$HERE/../../versions.json")" \
    || { echo "PHP ${LINE} is not a line in versions.json" >&2; exit 1; }

tests=("$@")
if [[ ${#tests[@]} -eq 0 ]]; then
    for f in "$HERE"/*.sh; do
        name="$(basename "$f" .sh)"
        [[ "$name" == lib || "$name" == run ]] || tests+=("$name")
    done
fi
for name in "${tests[@]}"; do
    if [[ "$name" == lib || "$name" == run || ! -f "$HERE/${name}.sh" ]]; then
        echo "no example test named '${name}' in test/examples/" >&2
        exit 1
    fi
done

# join <item>… — "a, b, c"
join() { local out; out="$(printf '%s, ' "$@")"; printf '%s' "${out%, }"; }

passed=()
failed=()
skipped=()
for name in "${tests[@]}"; do
    if [[ "$name" != traefik-* ]] \
        && ! jq -e --arg f "$name" 'any(.[]; . == $f)' <<<"$frameworks" >/dev/null; then
        printf '\n══ skip %s: versions.json does not list it on PHP %s\n' "$name" "$LINE"
        skipped+=("$name")
        continue
    fi
    label="$name"
    [[ "$name" == traefik-* ]] || label+=" on ${PHP_BASE_IMAGE}"
    printf '\n\033[1;34m══ %s ══\033[0m\n' "$label"
    t0=$SECONDS
    if "$HERE/${name}.sh" </dev/null; then
        passed+=("$name")
    else
        failed+=("$name")
    fi
    printf '══ %s took %ds\n' "$name" "$((SECONDS - t0))"
done

if [[ ${#skipped[@]} -gt 0 ]]; then
    printf 'example tests skipped: %s\n' "$(join "${skipped[@]}")"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'example tests FAILED: %s\n' "$(join "${failed[@]}")"
    exit 1
fi
if [[ ${#passed[@]} -gt 0 ]]; then
    printf 'example tests passed: %s\n' "$(join "${passed[@]}")"
fi
