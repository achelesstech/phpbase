# shellcheck shell=bash
# =============================================================================
# test/lib.sh — helpers shared by test/run.sh and the test/runtime/ sections
# =============================================================================
# Sourced, never executed. The caller sets `set -euo pipefail`, $IMAGE and
# $HERE first. Every container, volume and network a test creates carries
# $LABEL, and the EXIT trap removes everything carrying it.
# =============================================================================

SUFFIX="$$"
FIXTURE_TAG="php-base-fixture:test-${SUFFIX}"
NET="php-base-test-net-${SUFFIX}"
# Cleanup finds containers by LABEL: start() runs inside $(…), a subshell, so
# an array of names would never reach the cleanup trap.
LABEL="php-base-test=run-${SUFFIX}"
# Host-side scratch space (background-job output, bind-mounted files).
TMPD="$(mktemp -d)"

# The production run flags from the README; start() applies them to every
# container, so every check runs the way the image is meant to be run.
# shellcheck disable=SC2054  # the commas are tmpfs mount options.
HARDENED=(
    --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m --cap-drop ALL
    --security-opt no-new-privileges --pids-limit 256 --memory 1g
)

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }

cleanup() {
    docker ps -aq --filter "label=${LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=${LABEL}" | xargs -r docker volume rm -f >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker rmi -f "$FIXTURE_TAG" >/dev/null 2>&1 || true
    # Images derived from the fixture (test/runtime/70-hardening.sh hook_image).
    docker image ls --filter "reference=${FIXTURE_TAG}-*" --format '{{.Repository}}:{{.Tag}}' \
        | xargs -r docker rmi -f >/dev/null 2>&1 || true
    rm -rf "$TMPD"
}
trap cleanup EXIT

# start_plain NAME [docker-run-args...] — run a labelled container detached on
# $NET and print its name.
start_plain() {
    local name="$1-${SUFFIX}"; shift
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --label "$LABEL" --name "$name" --network "$NET" "$@" >/dev/null
    echo "$name"
}

# start NAME [docker-run-args...] — start_plain with the hardened run flags.
start() {
    local name="$1"; shift
    start_plain "$name" "${HARDENED[@]}" "$@"
}

# wait_health NAME [expected] [timeout] — wait for a terminal health state.
wait_health() {
    local name="$1" want="${2:-healthy}" timeout="${3:-60}" s
    for _ in $(seq 1 "$timeout"); do
        s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo gone)"
        [[ "$s" == "$want" ]] && return 0
        [[ "$s" == "exited" || "$s" == "gone" ]] && return 1
        sleep 1
    done
    return 1
}

# get NAME [curl-args...] / get_path NAME PATH [curl-args...] — fetch from
# inside the container, over loopback.
get_path() { docker exec "$1" curl -sf "${@:3}" "http://127.0.0.1:8080${2}"; }
get() { get_path "$1" / "${@:2}"; }

# from_network_url URL [curl-args...] / from_network TARGET [curl-args...] —
# fetch from a throwaway container on $NET, i.e. not over loopback.
from_network_url() {
    local url="$1"; shift
    docker run --rm --label "$LABEL" --network "$NET" --entrypoint curl "$FIXTURE_TAG" -sf "$@" "$url"
}
from_network() { from_network_url "http://${1}:8080/" "${@:2}"; }

# field KEY — the value of the "KEY:" line in $body (the fixture's index.php).
# shellcheck disable=SC2154  # body is set by test/runtime/00-boot.sh.
field() { grep -E "^$1:" <<<"$body" | head -1 | cut -d: -f2-; }

# finish — print the summary; exit 1 if any check failed.
finish() {
    printf '\n'
    if [[ $fail -eq 0 ]]; then
        printf '\033[32m✓ %d checks passed\033[0m for %s\n' "$pass" "$IMAGE"
    else
        printf '\033[31m✗ %d passed, %d FAILED\033[0m for %s\n' "$pass" "$fail" "$IMAGE"
        exit 1
    fi
}
