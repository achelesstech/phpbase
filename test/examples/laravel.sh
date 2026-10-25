#!/usr/bin/env bash
# =============================================================================
# test/examples/laravel.sh — examples/laravel on a fresh Laravel project
# =============================================================================
#   test/examples/laravel.sh [composer-spec]      default laravel/laravel:^13.0
#
#   PHP_BASE_IMAGE / PHP_BASE_DEV_IMAGE pick the base (default
#   local/php-base:8.4 and local/php-base:8.4-dev).
#
# composer create-project in the -dev base, examples/laravel/ copied over it,
# compose.prod.yml booted with the hardening it ships, then: health, the
# migrate one-shot, real pages, the queue and scheduler roles, the hardening
# and the absence of published ports.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$HERE/lib.sh"
SPEC="${1:-laravel/laravel:^13.0}"

info "laravel: scaffold ${SPEC} (base ${PHP_BASE_IMAGE})"
ex_scaffold laravel composer create-project --no-interaction --prefer-dist --no-progress "$SPEC" .
ok "composer create-project ${SPEC}"

# The example's .env.example, filled in the way the README says.
app_key="base64:$(head -c 32 /dev/urandom | base64)"
sed -e "s|^APP_KEY=.*|APP_KEY=${app_key}|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=test-$$|" \
    -e "s|^APP_DOMAIN=.*|APP_DOMAIN=laravel-$$.test|" \
    -e "s|^TRAEFIK_ROUTER=.*|TRAEFIK_ROUTER=ex-laravel-$$|" \
    "$EX_DIR/.env.example" > "$EX_DIR/.env"

info "laravel: compose.prod.yml"
ex_up
if ex_wait_healthy app 90; then ok "app healthy within 90 s"; else bad "app not healthy within 90 s"; ex_finish laravel; fi

info "laravel: install"
if out="$(ex_compose run --rm migrate 2>&1)"; then
    ok "docker compose run --rm migrate -> 0"
else
    bad "docker compose run --rm migrate failed"; printf '%s\n' "$out" | tail -20
fi

info "laravel: requests"
code="$(ex_http app /up)"
if [[ "$code" == 200 ]]; then ok "GET /up -> 200"; else bad "GET /up -> ${code}"; fi
code="$(ex_http app /)"
if [[ "$code" == 200 ]]; then ok "GET / -> 200"; else bad "GET / -> ${code}"; fi
code="$(ex_http app /no-such-page)"
if [[ "$code" == 404 ]]; then ok "GET /no-such-page -> 404 (error view renders read-only)"; else bad "GET /no-such-page -> ${code}"; fi

info "laravel: roles"
if ex_wait_healthy scheduler 150; then ok "scheduler healthy within 150 s"; else bad "scheduler not healthy within 150 s"; fi
# Before `migrate` the worker exits (no cache table) and Docker restarts it with
# a growing back-off, up to a minute: wait for a start that stays up.
queue_state() { docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$(ex_cid queue)" 2>&1 || true; }
deadline=$((SECONDS + 90))
stable=""
while ((SECONDS < deadline)); do
    state="$(queue_state)"
    if [[ "$state" == "running "* ]]; then
        sleep 10
        if [[ "$(queue_state)" == "$state" ]]; then stable=1; break; fi
    else
        sleep 2
    fi
done
if [[ -n "$stable" ]]; then
    ok "queue running, and still up 10 s later"
else
    bad "queue: $(queue_state)"; ex_compose logs --no-color --tail 20 queue 2>&1 | sed 's/^/        /'
fi

info "laravel: image and hardening"
# mem_limit and the tmpfs size come from compose.prod.yml; the values the
# brief fixes for app are checked against it here.
cfg="$(ex_config_hardening app)"
if [[ "$cfg" == "$(ex_bytes 1g) 256m" ]]; then ok "compose.prod.yml: app mem_limit 1g, /tmp tmpfs 256m"; else bad "compose.prod.yml: app sets '${cfg}', want 1g and 256m"; fi
ex_assert_hardened app
ex_assert_hardened queue
ex_assert_hardened scheduler
ex_assert_no_ports app
if ex_compose exec -T app sh -c 'test ! -w app' >/dev/null 2>&1; then
    ok "code is not writable by the runtime user"
else
    bad "app/ is writable by the runtime user"
fi
if ex_compose exec -T app test -f public/build/manifest.json >/dev/null 2>&1; then
    ok "Vite assets built (public/build/manifest.json)"
else
    bad "no public/build/manifest.json"
fi
if ex_compose exec -T app sh -c 'command -v node' >/dev/null 2>&1; then
    bad "node is in the production image"
else
    ok "node is not in the production image"
fi
logs="$(ex_compose logs --no-color app 2>&1)" || logs=""
if [[ "$logs" == *"max_children=7 "* ]]; then
    ok "FPM_MAX_CHILDREN=auto -> 7 workers (1g limit, 256m tmpfs)"
else
    bad "FPM pool is not 7 workers: $(printf '%s\n' "$logs" | grep -m1 'max_children' || echo 'no fpm line')"
fi

ex_finish "examples/laravel (${SPEC})"
