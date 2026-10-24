#!/usr/bin/env bash
# =============================================================================
# test/frameworks/run.sh — run the smoke tests versions.json lists for a line
# =============================================================================
#   test/frameworks/run.sh <base-image> '<frameworks-json>'
#   test/frameworks/run.sh php-base:test '{"laravel":["laravel/laravel:^12.0","laravel/laravel:^13.0"],"moodle":["MOODLE_503_STABLE"]}'
#
# Each framework's value is a list of versions, one run each (a plain string
# is a list of one). Runs are labelled "<framework> (<version>)".
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${1:?usage: run.sh <base-image> <frameworks-json>}"
JSON="${2:-{\}}"

# One "<framework><TAB><version>" line per run, in versions.json order.
runs="$(jq -r 'to_entries[] | .key as $fw | .value | (if type == "array" then .[] else . end) | "\($fw)\t\(.)"' <<<"$JSON")"

# join <item>… — "a, b, c"
join() { local out; out="$(printf '%s, ' "$@")"; printf '%s' "${out%, }"; }

passed=()
failed=()
while IFS=$'\t' read -r fw spec; do
    [[ -n "$fw" ]] || continue
    label="${fw} (${spec})"
    printf '\n\033[1;34m══ %s on %s ══\033[0m\n' "$label" "$IMAGE"
    t0=$SECONDS
    if "$HERE/${fw}.sh" "$IMAGE" "$spec" </dev/null; then
        passed+=("$label")
    else
        failed+=("$label")
    fi
    printf '══ %s took %ds\n' "$label" "$((SECONDS - t0))"
done <<<"$runs"

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'framework smoke tests FAILED: %s\n' "$(join "${failed[@]}")"
    exit 1
fi
printf 'framework smoke tests passed: %s\n' "$(join "${passed[@]}")"
