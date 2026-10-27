#!/usr/bin/env bash
# =============================================================================
# test/scripts/versions.test.sh — the framework matrix in versions.json
# =============================================================================
#   bash test/scripts/versions.test.sh
#
# The framework lists per line must match spec §7.10 exactly (§6b C4).
# No network, no Docker.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

want='[{"line":"8.2","frameworks":{"wordpress":["latest"]}},
 {"line":"8.3","frameworks":{"laravel":["laravel/laravel:^13.0"],"drupal":["drupal/recommended-project:^11"],"wordpress":["latest"],"moodle":["MOODLE_503_STABLE"]}},
 {"line":"8.4","frameworks":{"laravel":["laravel/laravel:^13.0"],"drupal":["drupal/recommended-project:^11"],"wordpress":["latest"],"moodle":["MOODLE_503_STABLE"]}},
 {"line":"8.5","frameworks":{"laravel":["laravel/laravel:^13.0"],"drupal":["drupal/recommended-project:^11"],"wordpress":["latest"]}}]'
want="$(jq -c . <<<"$want")"
got="$(jq -c '[.php[] | {line, frameworks}]' versions.json)"

if [[ "$got" == "$want" ]]; then
    printf '  ok    framework matrix matches spec §7.10\n'
else
    printf '  FAIL  framework matrix\n    got:  %s\n    want: %s\n' "$got" "$want"
    exit 1
fi
