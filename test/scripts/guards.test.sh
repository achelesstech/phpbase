#!/usr/bin/env bash
# =============================================================================
# test/scripts/guards.test.sh — unit tests for scripts/lib/guards.sh
# =============================================================================
#   bash test/scripts/guards.test.sh
#
# Pure functions, fixed dates: no network, no Docker.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=scripts/lib/guards.sh
source scripts/lib/guards.sh

pass=0
fail=0
# expect NAME ACTUAL WANT
expect() {
    if [[ "$2" == "$3" ]]; then
        printf '  ok    %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  FAIL  %s: got [%s], want [%s]\n' "$1" "$2" "$3"; fail=$((fail + 1))
    fi
}

expect same       "$(php_guard 8.4.27 8.4.27 '21 Oct 2026' 2026-10-26)"                 ok
expect lag2       "$(php_guard 8.4.26 8.4.27 '21 Oct 2026' 2026-10-23 | cut -d: -f1)"   warn
expect lag4       "$(php_guard 8.4.26 8.4.27 '21 Oct 2026' 2026-10-25 | cut -d: -f1)"   fail
expect phpnetdown "$(php_guard 8.4.27 '' '' 2026-10-25 | cut -d: -f1)"                  warn
expect alpsame    "$(alpine_guard 3.24 3.24 2026-06-09 2026-10-25)"                      ok
expect alp9days   "$(alpine_guard 3.24 3.25 2026-11-01 2026-11-10)"                      ok
expect alp19days  "$(alpine_guard 3.24 3.25 2026-11-01 2026-11-20 | cut -d: -f1)"        warn
expect tagfree    "$(next_build_tag 8.4.27-20261026)"                                     8.4.27-20261026
expect tagtaken   "$(next_build_tag 8.4.27-20261026 8.4.27-20261026)"                     8.4.27-20261026.2
expect tagtaken2  "$(next_build_tag 8.4.27-20261026 8.4.27-20261026 8.4.27-20261026.2)"   8.4.27-20261026.3

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
