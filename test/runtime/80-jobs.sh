# shellcheck shell=bash
# jobs — the in-container scheduler and php-base-every job containers.

info "background jobs"
SCH="$(start sched -e 'SCHEDULER_COMMAND=php -r "file_put_contents(\"/tmp/sched-ran\", time());"' -e SCHEDULER_INTERVAL=2 "$FIXTURE_TAG")"
wait_health "$SCH" || true
ran=no; for _ in $(seq 1 12); do docker exec "$SCH" test -f /tmp/sched-ran && { ran=yes; break; }; sleep 1; done
[[ "$ran" == yes ]] && ok "SCHEDULER_COMMAND runs inside the web container" || bad "scheduler never ran"

EVERY="$(start every --health-interval=2s --health-start-period=1s "$FIXTURE_TAG" php-base-every --name t 2 -- true)"
wait_health "$EVERY" healthy 20 && ok "php-base-every container: healthy via heartbeat (no compose override)" || bad "php-base-every container not healthy"
FAILING="$(start failing --health-interval=2s --health-retries=2 --health-start-period=1s -e HEALTHCHECK_MAX_AGE=3 "$FIXTURE_TAG" php-base-every --name f 1 -- false)"
wait_health "$FAILING" unhealthy 30 && ok "a job that keeps failing turns the container unhealthy" || bad "failing job stayed healthy"
WORKER="$(start worker --health-interval=2s --health-start-period=1s "$FIXTURE_TAG" sleep 300)"
wait_health "$WORKER" healthy 20 && ok "an arbitrary worker command is not falsely unhealthy" || bad "worker reported unhealthy"
t0=$(date +%s); docker stop -t 30 "$EVERY" >/dev/null; t1=$(date +%s)
[[ $((t1 - t0)) -lt 10 && "$(docker inspect -f '{{.State.ExitCode}}' "$EVERY")" == "0" ]] \
    && ok "php-base-every stops promptly and cleanly on SIGTERM ($((t1 - t0))s, exit 0)" || bad "php-base-every stop took $((t1 - t0))s exit $(docker inspect -f '{{.State.ExitCode}}' "$EVERY")"

# s6 restarts a worker that exits (Laravel's queue:work --max-time relies on
# it), and the container stays up.
RESTART="$(start restart -e 'WORKER_COMMAND=printf x >> /tmp/runs; sleep 1' "$FIXTURE_TAG")"
sleep 6
runs="$(docker exec "$RESTART" sh -c 'wc -c < /tmp/runs' 2>/dev/null || echo 0)"
[[ "$runs" -ge 2 && "$(docker inspect -f '{{.State.Running}}' "$RESTART")" == true ]] \
    && ok "WORKER_COMMAND is restarted after it exits (${runs} runs in 6 s, container up)" || bad "worker ran ${runs} time(s) in 6 s"

# WORKER_COMMAND is parsed by a shell: spaces and quotes arrive as a shell
# would pass them (review focus 2).
quote_cmd=$(cat <<'EOF_CMD'
php -r 'file_put_contents("/tmp/argv", json_encode(array_slice($argv, 1)));' -- "a b" 'c"d'
EOF_CMD
)
QUOTE="$(start quote -e "WORKER_COMMAND=${quote_cmd}" "$FIXTURE_TAG")"
argv=""; for _ in $(seq 1 10); do argv="$(docker exec "$QUOTE" cat /tmp/argv 2>/dev/null)" && break; sleep 1; done
[[ "$argv" == '["a b","c\"d"]' ]] && ok "WORKER_COMMAND keeps quoted arguments intact" || bad "worker argv was '${argv}', expected [\"a b\",\"c\\\"d\"]"
