#!/usr/bin/env bash
# =============================================================================
# test/examples/drupal.sh — examples/drupal on a fresh Drupal project
# =============================================================================
#   test/examples/drupal.sh [composer-spec]   default drupal/recommended-project:^11
#
#   PHP_BASE_IMAGE / PHP_BASE_DEV_IMAGE pick the base (default
#   local/php-base:8.4 and local/php-base:8.4-dev).
#
# composer create-project (plus drush/drush, as the README says) in the -dev
# base, examples/drupal/ copied over it, compose.prod.yml booted with the
# hardening it ships, then: health, drush site:install against the example's
# PostgreSQL, real pages, trusted_host_patterns, the status report, both files
# volumes, the migrate one-shot, a real drush cron run by the scheduler, the
# hardening and the absence of published ports.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$HERE/lib.sh"
SPEC="${1:-drupal/recommended-project:^11}"
DOMAIN="drupal-$$.test"
SITE_NAME="Example Drupal $$"

info "drupal: scaffold ${SPEC} (base ${PHP_BASE_IMAGE})"
# shellcheck disable=SC2016  # $1 expands in the container's sh
ex_scaffold drupal sh -c 'composer create-project --no-interaction --prefer-dist --no-progress "$1" . \
    && composer require --no-interaction --no-progress drush/drush' sh "$SPEC"
ok "composer create-project ${SPEC} + composer require drush/drush"

# The example's .env.example, filled in the way the README says.
sed -e "s|^DB_PASSWORD=.*|DB_PASSWORD=test-$$|" \
    -e "s|^DRUPAL_HASH_SALT=.*|DRUPAL_HASH_SALT=$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=')|" \
    -e "s|^APP_DOMAIN=.*|APP_DOMAIN=${DOMAIN}|" \
    -e "s|^TRAEFIK_ROUTER=.*|TRAEFIK_ROUTER=ex-drupal-$$|" \
    "$EX_DIR/.env.example" > "$EX_DIR/.env"

drush() { ex_compose exec -T app vendor/bin/drush "$@"; }

# get PATH — the body, then the status code on the last line. Sent with the
# site's Host header: trusted_host_patterns rejects any other.
get() {
    ex_compose exec -T app curl -s -H "Host: ${DOMAIN}" -w '\n%{http_code}' --max-time 30 \
        "http://127.0.0.1:8080$1" 2>/dev/null || printf '\n000'
}

info "drupal: compose.prod.yml"
ex_up
if ex_wait_healthy app 90; then ok "app healthy within 90 s"; else bad "app not healthy within 90 s"; ex_finish drupal; fi

info "drupal: install"
if out="$(drush site:install standard -y --site-name="$SITE_NAME" --account-pass="admin-$$" 2>&1)"; then
    ok "drush site:install standard -> 0 (settings.php from the environment)"
else
    bad "drush site:install failed"; printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
    ex_finish drupal
fi

info "drupal: requests"
resp="$(get /)"; code="${resp##*$'\n'}"
if [[ "$code" == 200 && "$resp" == *"$SITE_NAME"* ]]; then
    ok "GET / -> 200, with the site name"
else
    bad "GET / -> ${code}$([[ "$resp" == *"$SITE_NAME"* ]] || echo ', site name missing')"
fi
resp="$(get /user/login)"; code="${resp##*$'\n'}"
if [[ "$code" == 200 ]]; then ok "GET /user/login -> 200"; else bad "GET /user/login -> ${code}"; fi
code="$(ex_http app /)"
if [[ "$code" == 400 ]]; then
    ok "GET / with Host 127.0.0.1 -> 400 (trusted_host_patterns from APP_DOMAIN)"
else
    bad "GET / with Host 127.0.0.1 -> ${code}, want 400"
fi

info "drupal: drush"
boot="$(drush status --field=bootstrap 2>/dev/null)" || boot=""
if [[ "$boot" == Successful ]]; then ok "drush status --field=bootstrap = Successful"; else bad "drush bootstrap: '${boot}'"; fi

if reqs="$(drush core:requirements --severity=2 --format=json 2>/dev/null)"; then
    errors="$(jq -r 'if type == "object" then to_entries | map("\(.key): \(.value.title // "")") | join("; ") else map(tostring) | join("; ") end' <<<"${reqs:-[]}" 2>&1)" \
        || errors="unparseable: ${reqs}"
    if [[ -z "$errors" ]]; then
        ok "drush core:requirements --severity=2 lists nothing"
    else
        bad "status report errors: ${errors}"
    fi
else
    bad "drush core:requirements failed"
fi

for scheme in public private; do
    if out="$(drush php:eval "if (file_put_contents('${scheme}://x.txt', 'x') !== 1) { throw new RuntimeException('not written'); }" 2>&1)"; then
        ok "${scheme}:// is writable (its volume)"
    else
        bad "${scheme}://x.txt not written: ${out}"
    fi
done

if out="$(ex_compose run --rm migrate 2>&1)"; then
    ok "docker compose run --rm migrate -> 0"
else
    bad "docker compose run --rm migrate failed"; printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
fi

info "drupal: scheduler"
if ex_wait_healthy scheduler 60; then ok "scheduler healthy"; else bad "scheduler not healthy"; fi
# A later system.cron_last than right after the install is the scheduler's own
# `drush cron`, through php-base-every, on the next minute boundary.
# Unset (empty) counts as 0.
cron_last() { local t; t="$(drush state:get system.cron_last 2>/dev/null)" || t=""; echo "${t:-0}"; }
before="$(cron_last)"
deadline=$((SECONDS + 150))
after="$before"
while ((SECONDS < deadline)); do
    after="$(cron_last)"
    [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ && "$after" -gt "$before" ]] && break
    sleep 5
done
if [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ && "$after" -gt "$before" ]]; then
    ok "scheduler ran drush cron (system.cron_last ${before} -> ${after})"
else
    bad "no drush cron run by the scheduler within 150 s (system.cron_last ${before} -> ${after})"
    ex_compose logs --no-color --tail 20 scheduler 2>&1 | sed 's/^/        /'
fi

info "drupal: image and hardening"
ex_assert_hardened app 1g 256m
ex_assert_hardened scheduler 512m 256m
ex_assert_no_ports app
if ex_compose exec -T app sh -c 'test ! -w web/index.php && test ! -w web/sites/default/settings.php && test ! -w web/sites/default' >/dev/null 2>&1; then
    ok "code and settings.php are not writable by the runtime user"
else
    bad "code or settings.php is writable by the runtime user"
fi
if ex_compose exec -T app sh -c 'command -v composer' >/dev/null 2>&1; then
    bad "composer is in the production image"
else
    ok "composer is not in the production image"
fi
logs="$(ex_compose logs --no-color app 2>&1)" || logs=""
if [[ "$logs" == *"max_children=7 "* ]]; then
    ok "FPM_MAX_CHILDREN=auto -> 7 workers (1g limit, 256m tmpfs)"
else
    bad "FPM pool is not 7 workers: $(printf '%s\n' "$logs" | grep -m1 'max_children' || echo 'no fpm line')"
fi

ex_finish "examples/drupal (${SPEC})"
