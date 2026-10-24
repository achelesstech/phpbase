#!/usr/bin/env bash
# =============================================================================
# test/examples/traefik-routing.sh — Traefik routes through the socket proxy
# =============================================================================
#   test/examples/traefik-routing.sh
#
# Boots an isolated compose project made of:
#   - the socket-proxy service and socket network, copied from
#     examples/traefik/compose.yml (only the fixed names and the restart
#     policy change);
#   - the example's Traefik image with a test static config: one HTTP entry
#     point, no ACME, the Docker provider via the proxy;
#   - traefik/whoami labelled Host(`whoami.test`).
#
# Asserts that labels route (200), that a stopped container stops routing
# (404), that the proxy runs read-only, without capabilities and as non-root,
# and that it refuses POST /containers/create.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE="$HERE/../../examples/traefik/compose.yml"

WHOAMI_IMAGE="traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44"
SUFFIX="$$-${RANDOM}"
PROJECT="php-base-test-traefik-${SUFFIX}"
LABEL_VALUE="traefik-routing-${SUFFIX}"
LABEL="php-base-test=${LABEL_VALUE}"
WAIT_SECONDS=15

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

workdir="$(mktemp -d)"
compose() { docker compose -p "$PROJECT" -f "$workdir/compose.yml" "$@"; }

cleanup() {
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    docker ps -aq --filter "label=${LABEL}" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
    docker network ls -q --filter "label=${LABEL}" | xargs -r docker network rm >/dev/null 2>&1 || true
    docker volume ls -q --filter "label=${LABEL}" | xargs -r docker volume rm >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

# The proxy needs the group that owns the socket. Same variable the example's
# .env sets.
DOCKER_GID="$(stat -c %g /var/run/docker.sock)"
export DOCKER_GID

# -----------------------------------------------------------------------------
info "compose project ${PROJECT}"
# -----------------------------------------------------------------------------
# Built from the example rather than retyped, so the test follows the example.
python3 - "$EXAMPLE" "$workdir/compose.yml" "$PROJECT" "$LABEL_VALUE" "$WHOAMI_IMAGE" <<'PY'
import sys, yaml

example_path, out_path, project, label, whoami = sys.argv[1:]
example = yaml.safe_load(open(example_path))
labels = {"php-base-test": label}
# Traefik matches the provider network by its real name, so give it one.
edge = f"{project}-edge"

proxy = dict(example["services"]["socket-proxy"])
# Fixed names would collide with a real deployment and with parallel runs.
proxy.pop("container_name", None)
proxy["restart"] = "no"
proxy["labels"] = {**(proxy.get("labels") or {}), **labels}

socket_net = dict(example["networks"]["socket"])
socket_net.pop("name", None)
socket_net["labels"] = labels

test = {
    "networks": {
        "socket": socket_net,
        "edge": {"name": edge, "labels": labels},
    },
    "services": {
        "socket-proxy": proxy,
        "traefik": {
            "image": example["services"]["traefik"]["image"],
            "depends_on": ["socket-proxy"],
            "command": [
                "--entrypoints.web.address=:8000",
                "--providers.docker.endpoint=tcp://socket-proxy:2375",
                "--providers.docker.exposedbydefault=false",
                f"--providers.docker.network={edge}",
                "--log.level=INFO",
            ],
            "ports": ["127.0.0.1::8000"],
            "networks": ["edge", "socket"],
            "labels": labels,
        },
        "whoami": {
            "image": whoami,
            "networks": ["edge"],
            "labels": {
                **labels,
                "traefik.enable": "true",
                "traefik.docker.network": edge,
                "traefik.http.routers.whoami.rule": "Host(`whoami.test`)",
                "traefik.http.routers.whoami.entrypoints": "web",
                "traefik.http.services.whoami.loadbalancer.server.port": "80",
            },
        },
    },
}
yaml.safe_dump(test, open(out_path, "w"), sort_keys=False)
PY

if ! up_out="$(compose up -d --quiet-pull 2>&1)"; then
    bad "compose up failed"
    printf '%s\n' "$up_out" | tail -20 | sed 's/^/        /'
    exit 1
fi

port="$(compose port traefik 8000 | sed 's/.*://')"
url="http://127.0.0.1:${port}/"

# http_status_for <seconds> <wanted> — poll until the status is <wanted>
http_status_for() {
    local seconds="$1" wanted="$2" code=""
    for _ in $(seq 1 "$seconds"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: whoami.test' "$url" || true)"
        [[ "$code" == "$wanted" ]] && break
        sleep 1
    done
    printf '%s' "$code"
}

# -----------------------------------------------------------------------------
info "routing by label"
# -----------------------------------------------------------------------------
code="$(http_status_for "$WAIT_SECONDS" 200)"
if [[ "$code" == 200 ]]; then
    ok "Host: whoami.test → 200 through the socket proxy"
else
    bad "Host: whoami.test → ${code:-no answer}, wanted 200 within ${WAIT_SECONDS}s"
    compose logs --tail=20 traefik socket-proxy 2>&1 | sed 's/^/        /'
fi

compose stop whoami >/dev/null 2>&1
code="$(http_status_for "$WAIT_SECONDS" 404)"
if [[ "$code" == 404 ]]; then
    ok "whoami stopped → 404 (events reach Traefik)"
else
    bad "whoami stopped → ${code:-no answer}, wanted 404 within ${WAIT_SECONDS}s"
fi

# -----------------------------------------------------------------------------
info "socket-proxy hardening"
# -----------------------------------------------------------------------------
proxy_id="$(compose ps -q socket-proxy)"
read -r readonly_root cap_drop user <<<"$(docker inspect -f \
    '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{if .Config.User}}{{.Config.User}}{{else}}root{{end}}' \
    "$proxy_id")"

if [[ "$readonly_root" == true ]]; then
    ok "read-only root filesystem"
else
    bad "root filesystem is writable (ReadonlyRootfs=${readonly_root})"
fi

if [[ "$cap_drop" == '["ALL"]' ]]; then
    ok "CapDrop [ALL]"
else
    bad "CapDrop is ${cap_drop}, wanted [\"ALL\"]"
fi

uid="${user%%:*}"
if [[ "$uid" != root && "$uid" != 0 ]]; then
    ok "runs as non-root (${user})"
else
    bad "runs as root (User=${user})"
fi

# -----------------------------------------------------------------------------
info "socket-proxy refuses writes"
# -----------------------------------------------------------------------------
# Asked from inside Traefik: the only client the proxy is meant to serve. The
# body is a valid create request, so a 2xx means a container was really made;
# it carries the test label so cleanup would remove it.
# api_status <method> <path> [body] — the proxy's HTTP status, or wget's error
api_status() {
    local method="$1" path="$2" body="${3:-}" out args=(-S -q -O /dev/null)
    [[ "$method" == POST ]] && args+=(--header 'Content-Type: application/json' --post-data "$body")
    out="$(compose exec -T traefik wget "${args[@]}" "http://socket-proxy:2375${path}" 2>&1 || true)"
    if [[ "$out" =~ HTTP/[0-9.]+\ ([0-9]{3}) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'no status (%s)' "${out%%$'\n'*}"
    fi
}

status="$(api_status GET /version)"
if [[ "$status" == 200 ]]; then
    ok "GET /version → 200 (the probe path works)"
else
    bad "GET /version → ${status}, wanted 200"
fi

create_body="{\"Image\":\"${WHOAMI_IMAGE}\",\"Labels\":{\"php-base-test\":\"${LABEL_VALUE}\"}}"
status="$(api_status POST /containers/create "$create_body")"
if [[ "$status" == 403 || "$status" == 405 ]]; then
    ok "POST /containers/create → ${status} (refused by the proxy)"
else
    bad "POST /containers/create → ${status}, wanted 403 or 405"
fi

echo
echo "traefik-routing: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
