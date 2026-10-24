#!/usr/bin/env bash
# Drupal: create-project + drush site:install (SQLite), drupal preset.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
IMAGE="${1:?base image}"; SPEC="${2:-drupal/recommended-project:^11}"

info "drupal: build"
fw_build "fw-drupal:${FW_SUFFIX}" "$HERE/drupal" --build-arg "BASE_IMAGE=${IMAGE}" --build-arg "DRUPAL_SPEC=${SPEC}"

info "drupal: boot + install"
APP="$(fw_run drupal "fw-drupal:${FW_SUFFIX}")"
fw_wait_healthy "$APP" && ok "healthy (fpm-ping through the drupal preset)" || { bad "never healthy"; fw_finish drupal; }
fw_exec_ok "drush site:install standard (SQLite)" "$APP" vendor/bin/drush site:install standard -y \
    --db-url=sqlite://localhost/sites/default/files/.ht.sqlite --site-name=SmokeDrupal --account-pass=admin123 --no-interaction
ver="$(docker exec "$APP" vendor/bin/drush status --field=drupal-version 2>/dev/null || true)"
boot="$(docker exec "$APP" vendor/bin/drush status --field=bootstrap 2>/dev/null || true)"
[[ "$boot" == Successful ]] && ok "Drupal ${ver} installed (drush bootstrap: ${boot})" || bad "Drupal ${ver} not bootstrapping (${boot:-none})"

info "drupal: requests"
expect "$APP" / 200 "SmokeDrupal" "GET / renders the installed site"
expect "$APP" /user/login 200 "Log in" "GET /user/login (clean URLs through index.php)"
expect "$APP" /core/install.php 200 "" "GET /core/install.php reaches the allowlisted front controller"
not_executed "$APP" /sites/default/files/evil.php
expect "$APP" /sites/default/files/.ht.sqlite 404 "" "the SQLite database file is not downloadable"
expect "$APP" /core/core.services.yml 404 "" "*.yml under core/ is denied"
expect "$APP" /vendor/autoload.php 404 "" "vendor/ is outside the docroot"

# Image styles: the first request for a derivative must reach Drupal, which
# generates it (the preset routes files/styles/ through @rewrite).
docker exec "$APP" php -r '$i = imagecreatetruecolor(640, 480); imagefilledrectangle($i, 0, 0, 640, 480, imagecolorallocate($i, 30, 120, 200)); imagepng($i, "web/sites/default/files/smoke.png");'
style_url="$(docker exec "$APP" vendor/bin/drush php:eval "echo \Drupal\image\Entity\ImageStyle::load('thumbnail')->buildUrl('public://smoke.png');" 2>/dev/null | sed 's#^https\{0,1\}://[^/]*##')"
code="$(fw_get "$APP" "$style_url")"; ctype="$(docker exec "$APP" sh -c "curl -s -o /dev/null -w '%{content_type}' 'http://127.0.0.1:8080${style_url}'")"
[[ "$code" == 200 && "$ctype" == image/* ]] && ok "image style derivative generated on first request (${ctype})" || bad "image style: ${code} ${ctype} for ${style_url}"

info "drupal: drush"
fw_exec_ok "drush cron via php-base-every --once" "$APP" php-base-every --once 300 vendor/bin/drush cron
reqs="$(docker exec "$APP" vendor/bin/drush core:requirements --severity=2 --format=json 2>/dev/null || echo '{}')"
# trusted_host_patterns is a per-site setting, not something the image can set.
errors="$(jq -r 'to_entries | map(select(.key != "trusted_host_patterns")) | map("\(.key): \(.value.title // .key)") | join("; ")' <<<"${reqs:-{\}}" 2>/dev/null || echo "unparseable")"
[[ -z "$errors" ]] && ok "status report: no errors (drush core:requirements --severity=2)" || bad "status report errors: ${errors}"
warns="$(docker exec "$APP" vendor/bin/drush core:requirements --severity=1 --format=json 2>/dev/null | jq -r 'keys | join(", ")' 2>/dev/null || true)"
info "  (status report warnings, informational: ${warns:-none})"

fw_finish "drupal ${ver}"
