#!/usr/bin/env bash
# =============================================================================
# test/examples/moodle.sh — examples/moodle (Moodle 5.3 LTS, PostgreSQL 18)
# =============================================================================
#   test/examples/moodle.sh
#
#   PHP_BASE_IMAGE / PHP_BASE_DEV_IMAGE pick the base (default
#   local/php-base:8.4 and local/php-base:8.4-dev).
#
# A deployment repo: no project to scaffold, the image downloads Moodle. The
# example is booted with the compose.prod.yml hardening it ships, installed
# with its one-shot `install` service (install_database.php), then: a real
# login page through the Traefik headers, config.php's proxy setting, cron
# through php-base-every, the long timeouts, /tmp on a named volume, the
# hardening and the absence of published ports.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$HERE/lib.sh"

info "moodle: copy the example (base ${PHP_BASE_IMAGE})"
ex_scaffold moodle
domain="moodle-$$.test"
# The example's .env.example, filled in the way the README says.
sed -e "s|^DB_PASSWORD=.*|DB_PASSWORD=test-$$|" \
    -e "s|^MOODLE_ADMIN_PASSWORD=.*|MOODLE_ADMIN_PASSWORD=Admin-test-$$!|" \
    -e "s|^MOODLE_ADMIN_EMAIL=.*|MOODLE_ADMIN_EMAIL=admin@${domain}|" \
    -e "s|^APP_DOMAIN=.*|APP_DOMAIN=${domain}|" \
    -e "s|^TRAEFIK_ROUTER=.*|TRAEFIK_ROUTER=ex-moodle-$$|" \
    "$EX_DIR/.env.example" > "$EX_DIR/.env"
ok "examples/moodle copied, .env filled in"

info "moodle: compose.prod.yml"
ex_up
if ex_wait_healthy app 180; then ok "app healthy within 180 s"; else bad "app not healthy within 180 s"; ex_finish moodle; fi

info "moodle: install (install_database.php against PostgreSQL 18)"
t0=$SECONDS
if out="$(ex_compose run --rm install 2>&1)"; then
    ok "docker compose run --rm install -> 0 ($((SECONDS - t0)) s)"
else
    bad "docker compose run --rm install failed"; printf '%s\n' "$out" | tail -30
    ex_finish moodle
fi
installed_at="$(date +%s)"

info "moodle: requests"
# What Traefik sends: the public host and the forwarded scheme and port.
code="$(ex_compose exec -T app curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H "Host: ${domain}" -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Port: 443' \
    http://127.0.0.1:8080/login/index.php 2>/dev/null)" || code=000
if [[ "$code" == 200 ]]; then ok "GET /login/index.php -> 200"; else bad "GET /login/index.php -> ${code}"; fi

# shellcheck disable=SC2016  # $CFG is PHP, not shell
conf="$(ex_compose exec -T app php -r 'define("CLI_SCRIPT", true); require "config.php"; echo $CFG->getremoteaddrconf;' 2>&1)" || true
if [[ "$conf" == 3 ]]; then
    ok "\$CFG->getremoteaddrconf = 3 (REMOTE_ADDR only; nginx sets it from Traefik)"
else
    bad "\$CFG->getremoteaddrconf is '${conf}', want 3"
fi

info "moodle: scheduler"
cmd="$(docker inspect -f '{{join .Config.Cmd " "}}' "$(ex_cid scheduler)" 2>&1)" || cmd="?"
if [[ "$cmd" == "php-base-every 60 php admin/cli/cron.php"* ]]; then
    ok "scheduler: ${cmd}"
else
    bad "scheduler command is '${cmd}'"
fi
if ex_wait_healthy scheduler 150; then ok "scheduler healthy"; else bad "scheduler not healthy within 150 s"; fi
# The heartbeat is touched at start and after every SUCCESSFUL run: wait for
# one newer than the install.
beat=0
deadline=$((SECONDS + 150))
while ((SECONDS < deadline)); do
    beat="$(ex_compose exec -T scheduler stat -c %Y /tmp/php-base/heartbeat.job 2>/dev/null)" || beat=0
    [[ "$beat" -gt "$installed_at" ]] && break
    sleep 5
done
if [[ "$beat" -gt "$installed_at" ]]; then
    ok "scheduler: a cron.php run succeeded after the install"
else
    bad "scheduler: no successful cron.php run within 150 s of the install"
    ex_compose logs --no-color --tail 30 scheduler 2>&1 | sed 's/^/        /'
fi

info "moodle: timeouts and /tmp"
nginx_conf="$(ex_compose exec -T app cat /tmp/php-base/nginx/http.d/10-php-base.conf 2>&1)" || nginx_conf=""
if [[ "$nginx_conf" == *"fastcgi_read_timeout 600s;"* ]]; then
    ok "nginx: fastcgi_read_timeout 600s;"
else
    bad "nginx: no 'fastcgi_read_timeout 600s;' in the rendered config"
fi
# The documented upload limit, end to end: post_max_size 512M -> nginx.
if [[ "$nginx_conf" == *"client_max_body_size 512M;"* ]]; then
    ok "nginx: client_max_body_size 512M; (follows post_max_size)"
else
    bad "nginx: no 'client_max_body_size 512M;' in the rendered config"
fi
# The CLI always reports max_execution_time 0: read the ini the entrypoint
# rendered, the last scan dir PHP-FPM loads.
php_ini="$(ex_compose exec -T app cat /tmp/php-base/php/zz-runtime.ini 2>&1)" || php_ini=""
if [[ "$php_ini" == *"max_execution_time = 600"* ]]; then
    ok "PHP: max_execution_time = 600"
else
    bad "PHP: no 'max_execution_time = 600' in the rendered ini"
fi
fpm_conf="$(ex_compose exec -T app cat /tmp/php-base/fpm/zz-runtime.conf 2>&1)" || fpm_conf=""
if [[ "$fpm_conf" == *"request_terminate_timeout = 600s"* ]]; then
    ok "FPM: request_terminate_timeout = 600s"
else
    bad "FPM: no 'request_terminate_timeout = 600s' in the rendered pool"
fi
tmp_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/tmp"}}{{.Type}} {{.Name}}{{end}}{{end}}' "$(ex_cid app)" 2>&1)" || tmp_mount="?"
if [[ "$tmp_mount" == "volume ${EX_PROJECT}_app-tmp" ]]; then
    ok "app: /tmp is the named volume ${EX_PROJECT}_app-tmp"
else
    bad "app: /tmp mount is '${tmp_mount}', want the named volume app-tmp"
fi

info "moodle: image and hardening"
ex_assert_hardened app 2g volume
ex_assert_hardened scheduler
ex_assert_no_ports app
if ex_compose exec -T app sh -c 'test ! -w . && test ! -w config.php && test ! -w public' >/dev/null 2>&1; then
    ok "code and config.php are not writable by the runtime user"
else
    bad "code or config.php is writable by the runtime user"
fi
# MOODLE_ADMIN_* are for the install one-shot only.
for svc in app scheduler; do
    env_names="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(ex_cid "$svc")" 2>&1)" || env_names="?"
    if [[ "$env_names" == "?" ]]; then
        bad "${svc}: cannot read the environment"
    elif [[ "$env_names" == *MOODLE_ADMIN_* ]]; then
        bad "${svc}: MOODLE_ADMIN_* is in the environment"
    else
        ok "${svc}: no MOODLE_ADMIN_* in the environment"
    fi
done
logs="$(ex_compose logs --no-color app 2>&1)" || logs=""
if [[ "$logs" == *"max_children=27 "* ]]; then
    ok "FPM_MAX_CHILDREN=auto -> 27 workers (2g limit, /tmp a volume: no tmpfs reserve)"
else
    bad "FPM pool is not 27 workers: $(printf '%s\n' "$logs" | grep -m1 'max_children' || echo 'no fpm line')"
fi

ex_finish "examples/moodle"
