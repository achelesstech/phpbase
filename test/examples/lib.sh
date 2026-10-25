#!/usr/bin/env bash
# =============================================================================
# test/examples/lib.sh — shared helpers for the app-example tests
# =============================================================================
# Each test/examples/<fw>.sh scaffolds a real project, copies examples/<fw>/
# over it, and boots the example's compose.prod.yml as an isolated compose
# project, with test/examples/compose.test.yml layered on top:
#
#   ex_scaffold <fw> [command…]   .work/examples/<fw>-<pid>/, then the example
#   ex_up                         up -d --build
#   ex_wait_healthy SERVICE [timeout]
#   ex_http SERVICE PATH          status code of GET PATH on 127.0.0.1:8080
#   ex_assert_hardened SERVICE [MEM_LIMIT [TMPFS_SIZE|volume]]
#   ex_assert_no_ports SERVICE
#   ex_compose …                  docker compose for this project
#   ex_finish LABEL               summary; exit 1 on any failure
#
# Every container, network and volume the test creates carries the label
# php-base-test=example-<fw>-<pid>; cleanup (trap EXIT) runs `compose down`
# and then removes whatever still carries the label.
#
# The example's compose.prod.yml names its image ${APP_IMAGE:-…}:${APP_TAG:-…};
# the test builds it as php-base-ex-<fw>-<pid>:test, never as a docker.io name.
# The base images come from PHP_BASE_IMAGE / PHP_BASE_DEV_IMAGE (defaults:
# local/php-base:8.4 and local/php-base:8.4-dev).
# =============================================================================
set -euo pipefail

EX_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EX_TEST_COMPOSE="$EX_REPO/test/examples/compose.test.yml"
PHP_BASE_IMAGE="${PHP_BASE_IMAGE:-local/php-base:8.4}"
PHP_BASE_DEV_IMAGE="${PHP_BASE_DEV_IMAGE:-local/php-base:8.4-dev}"
export PHP_BASE_IMAGE PHP_BASE_DEV_IMAGE

EX_FW=""
EX_DIR=""
EX_PROJECT=""
EX_LABEL=""
ex_pass=0
ex_fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; ex_pass=$((ex_pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; ex_fail=$((ex_fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Compose files: the example, the test overlay, and the generated label file
# (written by ex_up; absent before it).
ex_compose() {
    local files=(-f "$EX_DIR/compose.prod.yml" -f "$EX_TEST_COMPOSE")
    [[ ! -f "$EX_DIR/.ex-labels.json" ]] || files+=(-f "$EX_DIR/.ex-labels.json")
    docker compose -p "$EX_PROJECT" --project-directory "$EX_DIR" "${files[@]}" "$@"
}

ex_cleanup() {
    [[ -n "$EX_PROJECT" ]] || return 0
    if [[ -d "$EX_DIR" ]]; then
        ex_compose --profile '*' down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    docker ps -aq --filter "label=${EX_LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=${EX_LABEL}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    docker network ls -q --filter "label=${EX_LABEL}" | xargs -r docker network rm >/dev/null 2>&1 || true
    docker image rm -f "${APP_IMAGE}:${APP_TAG}" >/dev/null 2>&1 || true
    rm -rf "$EX_DIR"
}
trap ex_cleanup EXIT

# ex_scaffold <fw> [command…] — create .work/examples/<fw>-<pid>/, run the
# command (if any) in it inside the -dev base image as the calling user, then
# copy examples/<fw>/. over the result. Composer's download cache is kept in
# .work/examples/.composer-cache between runs.
ex_scaffold() {
    EX_FW="$1"; shift
    EX_DIR="$EX_REPO/.work/examples/${EX_FW}-$$"
    EX_PROJECT="php-base-ex-${EX_FW}-$$"
    EX_LABEL="php-base-test=example-${EX_FW}-$$"
    APP_IMAGE="php-base-ex-${EX_FW}-$$"
    APP_TAG="test"
    export APP_IMAGE APP_TAG

    local cache="$EX_REPO/.work/examples/.composer-cache"
    mkdir -p "$EX_DIR" "$cache"
    if [[ $# -gt 0 ]]; then
        if ! docker run --rm --label "$EX_LABEL" --user "$(id -u):$(id -g)" \
                -e COMPOSER_CACHE_DIR=/composer-cache -v "$cache:/composer-cache" \
                -v "$EX_DIR:/app" -w /app "$PHP_BASE_DEV_IMAGE" "$@" >"$EX_DIR.scaffold.log" 2>&1; then
            bad "scaffold failed: $*"
            tail -30 "$EX_DIR.scaffold.log"
            rm -f "$EX_DIR.scaffold.log"
            exit 1
        fi
        rm -f "$EX_DIR.scaffold.log"
    fi
    cp -a "$EX_REPO/examples/${EX_FW}/." "$EX_DIR/"
}

# ex_up — label every service, non-external network and volume of the merged
# project, then `up -d --build`.
ex_up() {
    local config
    if ! config="$(ex_compose config --format json 2>&1)"; then
        bad "compose config failed"; printf '%s\n' "$config" | tail -20; exit 1
    fi
    printf '%s' "$config" | jq --arg v "${EX_LABEL#php-base-test=}" '
        def labelled: map_values(select((.external // false) | not) | {labels: {"php-base-test": $v}});
        {
          services: (.services | map_values({labels: {"php-base-test": $v}})),
          networks: ((.networks // {}) | labelled),
          volumes:  ((.volumes // {}) | labelled)
        }' > "$EX_DIR/.ex-labels.json"

    local out
    if out="$(ex_compose up -d --build --quiet-pull 2>&1)"; then
        ok "compose up -d --build (${EX_PROJECT})"
    else
        bad "compose up -d --build"; printf '%s\n' "$out" | tail -40; exit 1
    fi
}

# ex_cid SERVICE — the service's (first) container id, running or not
ex_cid() { ex_compose ps -aq "$1" | head -n1; }

# ex_wait_healthy SERVICE [timeout seconds, default 120] — 0 once healthy;
# prints the service's last log lines on timeout, exit or "unhealthy".
ex_wait_healthy() {
    local service="$1" timeout="${2:-120}" cid s="" deadline
    deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        cid="$(ex_cid "$service")"
        s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo gone)"
        [[ "$s" == healthy ]] && return 0
        [[ "$s" == exited || "$s" == dead || "$s" == unhealthy ]] && break
        sleep 2
    done
    printf '        %s: %s\n' "$service" "${s:-no container}"
    ex_compose logs --no-color --tail 40 "$service" 2>&1 | sed 's/^/        /'
    return 1
}

# ex_http SERVICE PATH — prints the status code (000 when there is no answer)
ex_http() {
    local code
    code="$(ex_compose exec -T "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:8080$2" 2>/dev/null)" || code=000
    printf '%s\n' "$code"
}

# ex_bytes 1g|512m|64k|N — bytes
ex_bytes() {
    local v="${1,,}"
    case "$v" in
        *k) echo $(( ${v%k} * 1024 )) ;;
        *m) echo $(( ${v%m} * 1024 * 1024 )) ;;
        *g) echo $(( ${v%g} * 1024 * 1024 * 1024 )) ;;
        *)  echo "$v" ;;
    esac
}

# ex_config_hardening SERVICE — "<mem_limit bytes> <tmpfs size|volume>" from
# the merged compose config ("-" for a value it does not set). /tmp may be a
# short-syntax `tmpfs:` entry, a long-syntax tmpfs mount or a volume.
ex_config_hardening() {
    ex_compose --profile '*' config --format json 2>/dev/null | jq -r --arg s "$1" '
        .services[$s] as $svc
        | ([ ($svc.volumes // [])[] | select(.target == "/tmp")
             | if .type == "tmpfs" then ((.tmpfs.size // "-") | tostring) else .type end ]
           + [ ($svc.tmpfs // [] | if type == "string" then [.] else . end)[]
               | select(startswith("/tmp:") or . == "/tmp")
               | ((capture("size=(?<v>[^,]+)").v) // "-") ]
          ) as $tmp
        | "\($svc.mem_limit // "-") \($tmp[0] // "-")"'
}

# ex_assert_hardened SERVICE [MEM_LIMIT [TMPFS_SIZE|volume]]
#   read-only root, CapDrop [ALL], no-new-privileges, a pids limit, the
#   mem_limit, /tmp as a noexec,nosuid,nodev tmpfs of TMPFS_SIZE (or a volume),
#   and a stop_grace_period of at least 45 s (app) or 120 s (queue, scheduler).
#   MEM_LIMIT and TMPFS_SIZE default to what the example's compose file sets,
#   and an example that sets neither fails.
ex_assert_hardened() {
    local service="$1" mem="${2:-}" tmp="${3:-}" cid fields
    if [[ -z "$mem" || -z "$tmp" ]]; then
        local cfg_mem cfg_tmp
        read -r cfg_mem cfg_tmp <<<"$(ex_config_hardening "$service")" || true
        mem="${mem:-${cfg_mem:--}}"
        tmp="${tmp:-${cfg_tmp:--}}"
    fi
    local ro capdrop secopt memory pids stop tmptype
    cid="$(ex_cid "$service")"
    if ! fields="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}|{{.HostConfig.Memory}}|{{if .HostConfig.PidsLimit}}{{.HostConfig.PidsLimit}}{{else}}0{{end}}|{{if .Config.StopTimeout}}{{.Config.StopTimeout}}{{else}}0{{end}}|{{range .Mounts}}{{if eq .Destination "/tmp"}}{{.Type}}{{end}}{{end}}' "$cid" 2>&1)"; then
        bad "${service}: no container to inspect (${fields})"; return 0
    fi
    IFS='|' read -r ro capdrop secopt memory pids stop tmptype <<<"$fields"

    if [[ "$ro" == true ]]; then ok "${service}: read-only root"; else bad "${service}: root is not read-only"; fi
    if [[ "$capdrop" == '["ALL"]' ]]; then ok "${service}: cap_drop [ALL]"; else bad "${service}: CapDrop is ${capdrop}"; fi
    if [[ "$secopt" =~ \"no-new-privileges(:true)?\" ]]; then ok "${service}: no-new-privileges"; else bad "${service}: SecurityOpt is ${secopt}"; fi
    if [[ "$pids" -gt 0 ]]; then ok "${service}: pids_limit ${pids}"; else bad "${service}: no pids_limit"; fi
    if [[ "$mem" == - ]]; then
        bad "${service}: no mem_limit in the compose file"
    elif [[ "$memory" == "$(ex_bytes "$mem")" ]]; then
        ok "${service}: mem_limit ${mem}"
    else
        bad "${service}: Memory is ${memory}, want ${mem}"
    fi

    if [[ "$tmp" == - ]]; then
        bad "${service}: no sized /tmp tmpfs (or volume) in the compose file"
    elif [[ "$tmp" == volume ]]; then
        if [[ "$tmptype" == volume ]]; then ok "${service}: /tmp is a volume"; else bad "${service}: /tmp mount type is '${tmptype}', want volume"; fi
    else
        local mounts line="" want
        mounts="$(ex_compose exec -T "$service" cat /proc/mounts 2>&1)" || mounts=""
        while read -r _ mp fstype opts _; do
            [[ "$mp" == /tmp && "$fstype" == tmpfs ]] && line="$opts"
        done <<<"$mounts"
        want="size=$(( $(ex_bytes "$tmp") / 1024 ))k"
        local opt missing=""
        for opt in "$want" noexec nosuid nodev; do
            [[ ",${line}," == *",${opt},"* ]] || missing+=" ${opt}"
        done
        if [[ -z "$missing" ]]; then
            ok "${service}: /tmp is a tmpfs, ${want},noexec,nosuid,nodev"
        else
            bad "${service}: /tmp tmpfs options '${line}', missing${missing}"
        fi
    fi

    local min=0
    case "$service" in
        app) min=45 ;;
        queue|scheduler) min=120 ;;
    esac
    if [[ "$min" -gt 0 ]]; then
        if [[ "$stop" -ge "$min" ]]; then
            ok "${service}: stop_grace_period ${stop}s (>= ${min}s)"
        else
            bad "${service}: stop_grace_period ${stop}s, want >= ${min}s"
        fi
    fi
}

# ex_assert_no_ports SERVICE — nothing published on the host
ex_assert_no_ports() {
    local service="$1" cid bindings published
    cid="$(ex_cid "$service")"
    bindings="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$cid" 2>&1)" || bindings="?"
    published="$(docker port "$cid" 2>&1)" || published="?"
    if [[ ( "$bindings" == '{}' || "$bindings" == null ) && -z "$published" ]]; then
        ok "${service}: no published ports"
    else
        bad "${service}: published ports: ${bindings} ${published}"
    fi
}

ex_finish() {
    printf '\n'
    if [[ $ex_fail -eq 0 ]]; then
        printf '\033[32m✓ %s: %d checks passed\033[0m\n' "$1" "$ex_pass"
    else
        printf '\033[31m✗ %s: %d passed, %d FAILED\033[0m\n' "$1" "$ex_pass" "$ex_fail"
        exit 1
    fi
}
