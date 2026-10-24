#!/usr/bin/env bash
# =============================================================================
# check-config.sh — validate the configuration before restarting the edge
# =============================================================================
# There is no `traefik validate` subcommand. This is the substitute: parse the
# YAML, then start the real binary against the real files in a throwaway
# container, isolated from Docker and from the live ACME store, and fail on any
# error-level log line.
#
# It catches unknown keys, bad CIDRs, unparseable durations, broken YAML
# anchors, and dynamic-config shapes Traefik rejects — the class of mistake
# that is otherwise discovered by :443 going down.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# The exact image compose.yml runs, tag and digest, so a version bump is
# checked by the binary it deploys. IMAGE=... overrides it to try another.
IMAGE="${IMAGE:-$(sed -n 's/^ *image: *\(traefik:[^ ]*\).*/\1/p' compose.yml)}"
[ -n "$IMAGE" ] || { echo "no traefik image found in compose.yml" >&2; exit 1; }
NAME="traefik-cfgcheck-$$"
BOOT_SECONDS="${BOOT_SECONDS:-8}"

fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

# Traefik's JSON log is unreadable raw, and the interesting line is buried in
# startup banners. Pull out message + error and drop everything else.
explain() {
    python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        print("        " + line)
        continue
    who = (d.get("providerName") or d.get("entryPointName")
           or d.get("routerName") or d.get("resolver") or "-")
    msg = d.get("message", "")
    err = d.get("error", "")
    print("        [{}] {} {}".format(who, msg, err).rstrip())
'
}

echo "== YAML syntax =="
for f in config/traefik.yml config/dynamic/*.yml compose.yml; do
    if python3 -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null; then
        ok "$f"
    else
        bad "$f"
        python3 -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' "$f" 2>&1 \
            | sed 's/^/        /'
    fi
done
[ "$fail" -eq 0 ] || { echo; echo "fix the YAML first"; exit 1; }

echo "== one trustedIPs list, shared by both entryPoints =="
python3 - <<'PY' || fail=1
import sys, yaml
d = yaml.safe_load(open("config/traefik.yml"))
ep = d["entryPoints"]
try:
    a = ep["web"]["forwardedHeaders"]["trustedIPs"]
    b = ep["websecure"]["forwardedHeaders"]["trustedIPs"]
except KeyError as e:
    print(f"  \033[31mFAIL\033[0m  an entryPoint has no forwardedHeaders.trustedIPs ({e})")
    print("        without it X-Forwarded-For is forgeable from the internet")
    sys.exit(1)
if a != b:
    print("  \033[31mFAIL\033[0m  web and websecure have different trustedIPs lists")
    sys.exit(1)
print(f"  \033[32mok\033[0m    identical, {len(a)} ranges")
PY

echo "== Traefik accepts the configuration ($IMAGE) =="

# Isolated: its own throwaway ACME dir (so "no such file" errors do not appear)
# and no Docker provider reachable. The unreachable-Docker errors are therefore
# expected and filtered below — everything else is a real finding.
#
# The scratch dir is inside the project, NOT /tmp: Docker Desktop only shares a
# configured set of host paths, and a bind mount from /tmp fails with "Mounts
# denied: the path is not shared from the host".
tmpcerts="$(mktemp -d "$PWD/.cfgcheck.XXXXXX")"
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1
    rm -rf "$tmpcerts"
}
trap cleanup EXIT

start_err="$(docker run -d --name "$NAME" \
    -v "$PWD/config/traefik.yml:/etc/traefik/traefik.yml:ro" \
    -v "$PWD/config/dynamic:/etc/traefik/dynamic:ro" \
    -v "$tmpcerts:/etc/traefik/certs" \
    --entrypoint traefik "$IMAGE" \
    --configFile=/etc/traefik/traefik.yml 2>&1 >/dev/null)"

if [ -n "$start_err" ]; then
    bad "could not start the check container:"
    sed 's/^/        /' <<<"$start_err"
    exit 1
fi

sleep "$BOOT_SECONDS"
logs="$(docker logs "$NAME" 2>&1)"

# A fatal static-config error makes Traefik exit rather than log at "error".
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    bad "Traefik exited — the static config was rejected:"
    reason="$(grep -E '"level":"(error|fatal)"' <<<"$logs")"
    if [ -n "$reason" ]; then
        explain <<<"$reason"
    else
        tail -5 <<<"$logs" | sed 's/^/        /'
    fi
    echo
    echo "configuration is NOT valid."
    exit 1
fi

# Expected in isolation only:
#  - no socket-proxy to resolve (there is no compose network here)
#  - ACME cannot reach Let's Encrypt / has no account yet in the throwaway dir
errors="$(grep -E '"level":"(error|fatal)"' <<<"$logs" \
        | grep -vE 'socket-proxy|docker API|ACME|acme|HTTP challenge' || true)"

if [ -n "$errors" ]; then
    bad "Traefik reported errors:"
    explain <<<"$errors"
else
    ok "static config loaded"
    ok "dynamic config loaded (middlewares, routers, tls)"
    # "Server configuration reloaded on :443" is logged at DEBUG, so it is not
    # visible at INFO. Ask the binary instead — this is the same command the
    # compose healthcheck runs, so a failure here means the healthcheck would
    # fail too.
    if docker exec "$NAME" traefik healthcheck --ping >/dev/null 2>&1; then
        ok "the ping entryPoint answers (healthcheck would pass)"
    else
        bad "traefik healthcheck --ping failed — the container will never
        report healthy. Check the 'ping' entryPoint and 'ping.entryPoint'."
    fi
fi

echo
[ "$fail" -eq 0 ] && echo "configuration is valid." || echo "configuration is NOT valid."
exit "$fail"
