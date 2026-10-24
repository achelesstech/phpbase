# shellcheck shell=bash
# lifecycle — graceful shutdown, and a dead php-fpm taking the container down.
# Runs last: it kills $APP.

info "shutdown and failure propagation"
# Its own container rather than proxy's $NOCF, so TEST_ONLY=lifecycle works.
STOP="$(start stop "$FIXTURE_TAG")"
wait_health "$STOP" || true
t0=$(date +%s); docker stop -t 40 "$STOP" >/dev/null; t1=$(date +%s)
[[ "$(docker inspect -f '{{.State.ExitCode}}' "$STOP")" == "0" ]] \
    && ok "docker stop: graceful exit 0 in $((t1 - t0))s" || bad "web container exit code $(docker inspect -f '{{.State.ExitCode}}' "$STOP") on stop"
docker exec "$APP" sh -c 'for _ in 1 2 3 4 5 6; do pkill -9 -x php-fpm 2>/dev/null || pkill -9 -f "php-fpm: master" 2>/dev/null || true; sleep 1; done' >/dev/null 2>&1 || true
for _ in $(seq 1 60); do [[ "$(docker inspect -f '{{.State.Running}}' "$APP")" == "true" ]] || break; sleep 1; done
[[ "$(docker inspect -f '{{.State.Running}}' "$APP")" == "false" ]] \
    && ok "repeatedly killing php-fpm brings the container down (FATAL listener)" || bad "php-fpm killed but container still running"
