# shellcheck shell=bash
# boot — the default role (nginx + php-fpm). Always runs: it starts $APP and
# fetches $body, which the other sections read.
# shellcheck disable=SC2034  # APP and body are read by the other sections.

info "boot (default role: nginx + php-fpm)"
APP="$(start app \
    -e PHP_MEMORY_LIMIT=333M \
    -e FPM_MAX_CHILDREN=7 \
    -e 'PHP_SESSION_SAVE_PATH=tcp://redis:6379?auth=s3cret&database=2' \
    -e $'PHP_INI_EXTRA=pcre.backtrack_limit = 5000000\nmbstring.language = Neutral' \
    "$FIXTURE_TAG")"
if wait_health "$APP"; then
    ok "healthcheck passes via /fpm-ping (FPM answers, not just nginx)"
else
    bad "container never became healthy"; docker logs "$APP" 2>&1 | tail -40; exit 1
fi
hc="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{index .HostConfig.Tmpfs "/tmp"}}' "$APP")"
[[ "$hc" == "true [ALL] [no-new-privileges] 1073741824 256 rw,noexec,nosuid,nodev,size=256m" ]] \
    && ok "fixture runs with the hardened production flags" || bad "not hardened: $hc"
body="$(get "$APP")"
