#!/usr/bin/env bash
# =============================================================================
# test/run.sh — behavioural test for php-base (runtime image)
# =============================================================================
#   ./test/run.sh <base-image> [expected-php-line]
#   TEST_ONLY=defaults,proxy ./test/run.sh <base-image> [expected-php-line]
#
# Builds the fixture app on the base, then sources test/runtime/00-boot.sh and
# every other test/runtime/NN-*.sh in order. TEST_ONLY takes section names
# without the number prefix; boot always runs. Helpers are in test/lib.sh.
#
# Every check corresponds to something that was actually broken — in this
# image, or in an app built on it — or to a promise the README makes.
# =============================================================================
set -euo pipefail

IMAGE="${1:?usage: run.sh <base-image> [expected-php-line]}"
# shellcheck disable=SC2034  # read by test/runtime/10-identity.sh.
LINE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$HERE/lib.sh"

# Pick the sections. Names are the file names without "NN-" and ".sh".
TEST_ONLY="${TEST_ONLY:-}"
sections=()
names=()
skipped=()
for f in "$HERE"/runtime/[0-9][0-9]-*.sh; do
    name="$(basename "$f" .sh)"; name="${name#[0-9][0-9]-}"
    names+=("$name")
    if [[ "$name" == boot || -z "$TEST_ONLY" || ",${TEST_ONLY}," == *",${name},"* ]]; then
        sections+=("$f")
    else
        skipped+=("$name")
    fi
done
if [[ -n "$TEST_ONLY" ]]; then
    # A typo must not silently run boot alone and report success.
    IFS=, read -ra wanted <<<"$TEST_ONLY"
    for w in "${wanted[@]}"; do
        [[ " ${names[*]} " == *" ${w} "* ]] || { echo "TEST_ONLY: no section named '${w}' (have: ${names[*]})" >&2; exit 2; }
    done
    info "TEST_ONLY=${TEST_ONLY}: skipping ${skipped[*]:-nothing}"
fi

# -----------------------------------------------------------------------------
info "build"
docker build --quiet --build-arg "BASE_IMAGE=${IMAGE}" -t "$FIXTURE_TAG" "$HERE" >/dev/null
ok "an application image builds on the base (its vhost passes nginx-validate.sh)"
docker network create --label "$LABEL" "$NET" >/dev/null

for f in "${sections[@]}"; do
    # shellcheck source=/dev/null
    . "$f"
done

finish
