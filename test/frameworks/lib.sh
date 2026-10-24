#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers for the framework smoke tests
# =============================================================================
# Each <framework>.sh builds a REAL app image on the candidate base, the same
# way an app repo would (root-owned code, a preset vhost, nginx-validate.sh),
# boots it next to its database, installs the site and asserts behaviour.
# =============================================================================
set -euo pipefail

FW_SUFFIX="$$"
FW_NET="fw-net-${FW_SUFFIX}"
# Containers are found again by LABEL at cleanup. (Recording names in an array
# does not work: fw_run is called as $(fw_run …), i.e. in a subshell, so the
# append never reaches the parent and every container leaked.)
FW_LABEL="php-base-test=fw-${FW_SUFFIX}"
FW_IMAGES=()
fw_pass=0
fw_fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; fw_pass=$((fw_pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fw_fail=$((fw_fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

fw_cleanup() {
    docker ps -aq --filter "label=${FW_LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    for i in "${FW_IMAGES[@]}"; do docker rmi -f "$i" >/dev/null 2>&1 || true; done
    docker network rm "$FW_NET" >/dev/null 2>&1 || true
}
trap fw_cleanup EXIT
docker network create --label "$FW_LABEL" "$FW_NET" >/dev/null

# fw_build <tag> <context-dir> [--build-arg …]
fw_build() {
    local tag="$1" dir="$2"; shift 2
    FW_IMAGES+=("$tag")
    if docker build --quiet "$@" -t "$tag" "$dir" >/dev/null; then
        ok "app image builds (root-owned code, preset vhost, nginx-validate.sh)"
    else
        bad "app image build failed"; docker build "$@" -t "$tag" "$dir" 2>&1 | tail -30; exit 1
    fi
}

# fw_run <name> [docker run args…] — detached, on the test network
fw_run() {
    local name="$1-${FW_SUFFIX}"; shift
    docker run -d --label "$FW_LABEL" --name "$name" --network "$FW_NET" --network-alias "${name%-"${FW_SUFFIX}"}" "$@" >/dev/null
    echo "$name"
}

fw_wait_healthy() {
    local name="$1" timeout="${2:-120}" s
    for _ in $(seq 1 "$timeout"); do
        s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo gone)"
        [[ "$s" == healthy ]] && return 0
        [[ "$s" == exited || "$s" == gone || "$s" == unhealthy ]] && break
        sleep 1
    done
    docker logs "$name" 2>&1 | tail -40
    return 1
}

# fw_get <container> <path> [curl args…] — prints "<status> <body>" via loopback
fw_get() {
    local name="$1" path="$2"; shift 2
    docker exec "$name" curl -s -o /tmp/fw-body -w '%{http_code}' "$@" "http://127.0.0.1:8080${path}" 2>/dev/null || echo 000
}
fw_body() { docker exec "$1" cat /tmp/fw-body 2>/dev/null || true; }

# expect <container> <path> <status-regex> [body-must-contain] [message]
expect() {
    local name="$1" path="$2" want="$3" needle="${4:-}" msg="${5:-}" code
    code="$(fw_get "$name" "$path")"
    msg="${msg:-GET ${path} -> ${want}${needle:+ containing \"${needle}\"}}"
    if [[ "$code" =~ ^(${want})$ ]] && { [[ -z "$needle" ]] || fw_body "$name" | grep -qF -- "$needle"; }; then
        ok "$msg"
    else
        bad "${msg} (got ${code})"
        fw_body "$name" | head -c 600; echo
    fi
}

# not_executed <container> <path> — a planted .php must be a 404, never code
not_executed() {
    local name="$1" path="$2" code
    code="$(fw_get "$name" "$path")"
    if [[ "$code" == 404 ]] && ! fw_body "$name" | grep -q EXECUTED; then
        ok "planted ${path} is a 404, not executed"
    else
        bad "planted ${path} returned ${code}$(fw_body "$name" | grep -q EXECUTED && echo ' AND EXECUTED')"
    fi
}

# not_nginx_404 <container> <path> — the app, not nginx, answered a missing file
app_handles_missing() {
    local name="$1" path="$2" code
    code="$(fw_get "$name" "$path")"
    if fw_body "$name" | grep -q '<center>nginx</center>'; then
        bad "GET ${path}: nginx answered (${code}) instead of falling through to the app"
    else
        ok "GET ${path} falls through to the application (${code})"
    fi
}

fw_exec_ok() {   # fw_exec_ok <message> <container> <cmd…>
    local msg="$1" name="$2"; shift 2
    local out
    if out="$(docker exec "$name" "$@" 2>&1)"; then ok "$msg"; else bad "$msg"; printf '%s\n' "$out" | tail -20; fi
}

fw_finish() {
    local label="$1"
    printf '\n'
    if [[ $fw_fail -eq 0 ]]; then
        printf '\033[32m✓ %s: %d checks passed\033[0m\n' "$label" "$fw_pass"
    else
        printf '\033[31m✗ %s: %d passed, %d FAILED\033[0m\n' "$label" "$fw_pass" "$fw_fail"
        exit 1
    fi
}
