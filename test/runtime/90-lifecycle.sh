# shellcheck shell=bash
# lifecycle — a graceful stop finishes the request in flight, and a dead nginx
# or php-fpm takes the whole container down, non-zero, within 5 s (spec §7.4).
# Runs last: it kills $APP.

info "shutdown and failure propagation"
# Its own container rather than proxy's $NOCF, so TEST_ONLY=lifecycle works.
STOP="$(start stop "$FIXTURE_TAG")"
if wait_health "$STOP"; then
    # A 5 s request starts 1 s before the stop. nginx drains it (SIGQUIT) before
    # php-fpm is signalled, so it completes with 200 and the stop waits for it
    # (≥ 3 s), without reaching any kill timeout (15 s for nginx). A stop that
    # returns at once with a 200 means FPM's workers were signalled mid-request:
    # PHP's sleep() returns early on a signal.
    from_network_url "http://${STOP}:8080/index.php?sleep=5" -o /dev/null -w '%{http_code}' > "$TMPD/stop-code" 2>/dev/null &
    inflight=$!
    sleep 1
    t0=$(date +%s); docker stop -t 40 "$STOP" >/dev/null; t1=$(date +%s)
    wait "$inflight" || true
    code="$(cat "$TMPD/stop-code")"
    rc="$(docker inspect -f '{{.State.ExitCode}}' "$STOP")"
    took=$((t1 - t0))
    if [[ "$code" == 200 && "$rc" == 0 && "$took" -ge 3 && "$took" -lt 15 ]]; then
        ok "docker stop: the in-flight request got 200, exit 0, drained in ${took}s"
    else
        bad "docker stop: in-flight request got '${code}', exit ${rc}, took ${took}s"
    fi
else
    bad "stop container never became healthy"; docker logs "$STOP" 2>&1 | tail -20
fi

# fail_fast NAME PATTERN — kill the process matching PATTERN (pkill -f) in a
# healthy container NAME; the container must be gone, non-zero, within 5 s.
fail_fast() {
    local name="$1" pattern="$2" st
    docker exec "$name" pkill -9 -f "$pattern" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] || break
        sleep 1
    done
    st="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "$name")"
    if [[ "$st" == "false "* && "$st" != "false 0" ]]; then
        ok "killing '${pattern}' takes the container down within 5 s, exit ${st#false }"
    else
        bad "after killing '${pattern}': running=${st%% *} exit=${st#* }"
    fi
}
fail_fast "$APP" 'php-fpm: master'
NGX="$(start nginxdie "$FIXTURE_TAG")"
if wait_health "$NGX"; then
    fail_fast "$NGX" 'nginx: master'
else
    bad "nginxdie container never became healthy"
fi
