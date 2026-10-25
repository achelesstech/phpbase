#!/usr/bin/env bash
# =============================================================================
# test/examples/wordpress.sh — examples/wordpress as a deployment repo
# =============================================================================
#   test/examples/wordpress.sh
#
#   PHP_BASE_IMAGE / PHP_BASE_DEV_IMAGE pick the base (default
#   local/php-base:8.4 and local/php-base:8.4-dev).
#
# Nothing to scaffold: the example IS the repository (core is downloaded at
# build). compose.prod.yml booted with the hardening it ships and MariaDB 11.4,
# `wp core install` in the running app, then: a real front page, the
# immutable-code constants, a media import with thumbnails on the uploads
# volume, the scheduler role, the hardening and the absence of published ports.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$HERE/lib.sh"

info "wordpress: copy the example (base ${PHP_BASE_IMAGE})"
ex_scaffold wordpress
domain="wordpress-$$.test"

# The example's .env.example, filled in the way the README says.
sed -e "s|^WORDPRESS_DB_PASSWORD=.*|WORDPRESS_DB_PASSWORD=test-$$|" \
    -e "s|^WORDPRESS_SECRET=.*|WORDPRESS_SECRET=$(head -c 48 /dev/urandom | base64 | tr -d '/+=')|" \
    -e "s|^APP_DOMAIN=.*|APP_DOMAIN=${domain}|" \
    -e "s|^TRAEFIK_ROUTER=.*|TRAEFIK_ROUTER=ex-wordpress-$$|" \
    "$EX_DIR/.env.example" > "$EX_DIR/.env"

# wp_get PATH — status code of GET PATH as Traefik sends it: the public Host
# and X-Forwarded-Proto https. A bare 127.0.0.1 request is answered with a
# canonical redirect to https://APP_DOMAIN/, which is correct but proves less.
wp_get() {
    local code
    code="$(ex_compose exec -T app curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Host: ${domain}" -H 'X-Forwarded-Proto: https' "http://127.0.0.1:8080$1" 2>/dev/null)" || code=000
    printf '%s\n' "$code"
}

# wp_out ARG… — stdout of `wp ARG…` in app (stderr dropped)
wp_out() { ex_compose exec -T app wp "$@" 2>/dev/null || true; }

info "wordpress: compose.prod.yml"
ex_up
if ex_wait_healthy app 90; then ok "app healthy within 90 s"; else bad "app not healthy within 90 s"; ex_finish wordpress; fi

info "wordpress: install"
if out="$(ex_compose exec -T app wp core install --url="https://${domain}" --title=ExampleWP \
        --admin_user=admin --admin_password="admin-$$-pw" --admin_email=admin@example.com --skip-email 2>&1)"; then
    ok "docker compose exec app wp core install -> 0"
else
    bad "wp core install failed"; printf '%s\n' "$out" | tail -20
fi
version="$(wp_out core version)"
ok "WordPress ${version:-?}"

info "wordpress: requests"
code="$(wp_get /)"
if [[ "$code" == 200 ]]; then ok "GET / -> 200"; else bad "GET / -> ${code}"; fi
code="$(wp_get /wp-login.php)"
if [[ "$code" == 200 ]]; then ok "GET /wp-login.php -> 200"; else bad "GET /wp-login.php -> ${code}"; fi
code="$(wp_get /wp-config.php)"
if [[ "$code" == 404 ]]; then ok "GET /wp-config.php -> 404 (wordpress.conf preset)"; else bad "GET /wp-config.php -> ${code}"; fi

info "wordpress: wp-config.php"
v="$(wp_out eval 'echo DISALLOW_FILE_MODS ? 1 : 0;')"
if [[ "$v" == 1 ]]; then ok "DISALLOW_FILE_MODS is true"; else bad "DISALLOW_FILE_MODS: '${v}'"; fi
v="$(wp_out eval 'echo DISABLE_WP_CRON ? 1 : 0;')"
if [[ "$v" == 1 ]]; then ok "DISABLE_WP_CRON is true"; else bad "DISABLE_WP_CRON: '${v}'"; fi
v="$(wp_out option get home)"
if [[ "$v" == "https://${domain}" ]]; then ok "home is https://${domain}"; else bad "home is '${v}'"; fi

info "wordpress: media on the uploads volume"
# shellcheck disable=SC2016  # PHP source, expanded by PHP
ex_compose exec -T app php -r '$i = imagecreatetruecolor(1600, 1200);
    imagefilledrectangle($i, 0, 0, 1600, 1200, imagecolorallocate($i, 200, 80, 40));
    imagejpeg($i, "/tmp/example.jpg", 90);' || bad "GD could not write /tmp/example.jpg"
if id="$(ex_compose exec -T app wp media import /tmp/example.jpg --title=Example --porcelain 2>&1)" \
        && [[ "$id" =~ ^[0-9]+$ ]]; then
    ok "wp media import (GD-made JPEG) -> 0, attachment ${id}"
    sizes="$(wp_out eval "\$m = wp_get_attachment_metadata(${id}); echo count(\$m['sizes'] ?? []);")"
    if [[ "$sizes" =~ ^[0-9]+$ && "$sizes" -gt 0 ]]; then ok "${sizes} thumbnail sizes generated"; else bad "thumbnail sizes: '${sizes}'"; fi
    file="$(wp_out eval "echo get_attached_file(${id});")"
    if [[ "$file" == /var/www/html/wp-content/uploads/* ]] && ex_compose exec -T app test -s "$file" >/dev/null 2>&1; then
        ok "original stored on the uploads volume"
    else
        bad "attached file '${file}' missing"
    fi
else
    bad "wp media import failed: ${id}"
fi

info "wordpress: scheduler"
if ex_wait_healthy scheduler 150; then ok "scheduler healthy within 150 s"; else bad "scheduler not healthy within 150 s"; fi
# Install scheduled core events that are already due; the next aligned run
# (within 60 s) executes them.
deadline=$((SECONDS + 90))
ran=""
while ((SECONDS < deadline)); do
    logs="$(ex_compose logs --no-color scheduler 2>&1)" || logs=""
    if [[ "$logs" == *"Success: Executed a total of"* ]]; then ran=1; break; fi
    sleep 5
done
if [[ -n "$ran" ]]; then
    ok "scheduler ran wp cron event run --due-now successfully"
else
    bad "no successful cron run in the scheduler"; ex_compose logs --no-color --tail 20 scheduler 2>&1 | sed 's/^/        /'
fi

info "wordpress: image and hardening"
ex_assert_hardened app 1g 256m
ex_assert_hardened scheduler 512m 256m
ex_assert_no_ports app
if ex_compose exec -T app sh -c 'test ! -w wp-includes && test ! -w wp-config.php' >/dev/null 2>&1; then
    ok "code and wp-config.php are not writable by the runtime user"
else
    bad "code is writable by the runtime user"
fi
logs="$(ex_compose logs --no-color app 2>&1)" || logs=""
if [[ "$logs" == *"max_children=7 "* ]]; then
    ok "FPM_MAX_CHILDREN=auto -> 7 workers (1g limit, 256m tmpfs)"
else
    bad "FPM pool is not 7 workers: $(printf '%s\n' "$logs" | grep -m1 'max_children' || echo 'no fpm line')"
fi

ex_finish "examples/wordpress (${version:-?})"
