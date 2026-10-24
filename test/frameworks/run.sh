#!/usr/bin/env bash
# =============================================================================
# test/frameworks/run.sh — run the smoke tests versions.json lists for a line
# =============================================================================
#   test/frameworks/run.sh <base-image> '<frameworks-json>'
#   test/frameworks/run.sh php-base:test '{"laravel":"laravel/laravel:^13.0","moodle":"MOODLE_503_STABLE"}'
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${1:?usage: run.sh <base-image> <frameworks-json>}"
JSON="${2:-{\}}"

failed=()
for fw in $(jq -r 'keys[]' <<<"$JSON"); do
    spec="$(jq -r --arg f "$fw" '.[$f]' <<<"$JSON")"
    printf '\n\033[1;34m══ %s (%s) on %s ══\033[0m\n' "$fw" "$spec" "$IMAGE"
    "$HERE/${fw}.sh" "$IMAGE" "$spec" || failed+=("$fw")
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "framework smoke tests FAILED: ${failed[*]}"
    exit 1
fi
echo "framework smoke tests passed: $(jq -r 'keys | join(", ")' <<<"$JSON")"
