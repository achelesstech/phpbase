# shellcheck shell=bash
# limits — the request body limit and the FPM slowlog.

info "nginx body limit follows PHP post_max_size"
SMALL="$(start small -e PHP_POST_MAX_SIZE=1M -e PHP_UPLOAD_MAX_FILESIZE=1M "$FIXTURE_TAG")"
wait_health "$SMALL" || true
code_big="$(docker exec "$SMALL" sh -c 'head -c 2097152 /dev/zero | curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/octet-stream" --data-binary @- http://127.0.0.1:8080/')"
code_ok="$(docker exec "$SMALL" sh -c 'head -c 524288 /dev/zero | curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/octet-stream" --data-binary @- http://127.0.0.1:8080/')"
[[ "$code_big:$code_ok" == "413:200" ]] && ok "PHP_POST_MAX_SIZE=1M -> nginx 413 at 2M, 200 at 512K" || bad "body limit: 2M->${code_big}, 512K->${code_ok}"

info "FPM slowlog (FPM_SLOWLOG_TIMEOUT used to stop php-fpm from starting)"
SLOW="$(start slow -e FPM_SLOWLOG_TIMEOUT=1s "$FIXTURE_TAG")"
if wait_health "$SLOW"; then
    get_path "$SLOW" '/index.php?sleep=2' >/dev/null || true
    sleep 1
    grep -q <<<"$(docker logs "$SLOW" 2>&1)" 'executing too slow' && ok "FPM_SLOWLOG_TIMEOUT works and traces reach the container log" || bad "no slowlog trace in logs"
else
    bad "FPM_SLOWLOG_TIMEOUT=1s: container did not become healthy"
fi
