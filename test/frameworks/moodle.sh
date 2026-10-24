#!/usr/bin/env bash
# Moodle: release tarball + composer, PostgreSQL, install_database, preset.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
IMAGE="${1:?base image}"; SPEC="${2:-MOODLE_503_STABLE}"
BRANCH="$(sed -E 's/^MOODLE_([0-9]+)_STABLE$/\1/' <<<"$SPEC")"

info "moodle: build (${SPEC})"
fw_build "fw-moodle:${FW_SUFFIX}" "$HERE/moodle" --build-arg "BASE_IMAGE=${IMAGE}" --build-arg "MOODLE_BRANCH=${BRANCH}"

info "moodle: boot + install"
DB="$(fw_run db -e POSTGRES_DB=moodle -e POSTGRES_USER=moodle -e POSTGRES_PASSWORD=moodle-smoke \
    --health-cmd 'pg_isready -U moodle -d moodle' --health-interval 2s --health-retries 60 postgres:18-alpine)"
fw_wait_healthy "$DB" 120 || { bad "postgres never healthy"; fw_finish moodle; }
APP="$(fw_run moodle -e MOODLE_DB_HOST=db -e MOODLE_DB_PASSWORD=moodle-smoke -e MOODLE_URL=http://127.0.0.1:8080 \
    -e PHP_MEMORY_LIMIT=512M "fw-moodle:${FW_SUFFIX}")"
fw_wait_healthy "$APP" && ok "healthy (fpm-ping through the moodle preset)" || { bad "never healthy"; fw_finish moodle; }
CLI="$(docker exec "$APP" sh -c '[ -d public/admin/cli ] && echo public/admin/cli || echo admin/cli')"
layout="$(docker exec "$APP" sh -c 'readlink /etc/nginx/conf.d/default.conf')"
ok "CLI scripts in ${CLI}/, vhost ${layout##*/}"
# install_database runs Moodle's own environment check first and refuses to
# continue on any failed requirement (extensions, max_input_vars, …).
t0=$(date +%s)
fw_exec_ok "install_database.php (includes Moodle's environment check)" "$APP" php "$CLI/install_database.php" \
    --agree-license --adminuser=admin --adminpass='Admin-smoke-123!' --adminemail=admin@example.com \
    --fullname=SmokeMoodle --shortname=smoke
ok "install took $(( $(date +%s) - t0 ))s"
ver="$(docker exec "$APP" php -r 'define("CLI_SCRIPT", true); require "config.php"; echo $CFG->release;' 2>/dev/null | awk '{print $1}')"

info "moodle: requests"
expect "$APP" /login/index.php 200 "SmokeMoodle" "GET /login/index.php"
code="$(fw_get "$APP" /theme/styles.php/boost/1/all)"
[[ "$code" =~ ^(200|30[0-9])$ ]] && ok "slash arguments: /theme/styles.php/boost/1/all -> ${code}" || bad "styles.php slashargs -> ${code}"
code="$(fw_get "$APP" /lib/javascript.php/1/lib/javascript-static.js)"
[[ "$code" =~ ^(200|30[0-9])$ ]] && ok "slash arguments + .js suffix reach PHP (-> ${code})" || bad "javascript.php slashargs -> ${code}"
expect "$APP" /composer.json 404 "" "composer.json not served"
expect "$APP" /vendor/autoload.php 404 "" "vendor/ not served"
expect "$APP" /config.php "200|30[0-9]|404" "" "config.php is executed or absent, never served"
[[ "$(fw_body "$APP")" != *'$CFG'* ]] && ok "config.php body contains no source" || bad "config.php source leaked"
if [[ "$layout" == */moodle.conf ]]; then
    app_handles_missing "$APP" /no/such/route
fi

info "moodle: cron + checks"
fw_exec_ok "cron.php via php-base-every --once" "$APP" php-base-every --once 60 php "$CLI/cron.php"
files="$(docker exec "$APP" sh -c 'find /var/www/html -name "*.php" | wc -l')"
ok "PHP files in the tree: ${files} (opcache.max_accelerated_files is 65407)"
for p in /login/index.php /theme/styles.php/boost/1/all /lib/javascript.php/1/lib/javascript-static.js /course/index.php /login/index.php; do fw_get "$APP" "$p" >/dev/null; done
oc="$(fw_get "$APP" /smoke-opcache.php >/dev/null; fw_body "$APP")"
ok "OPcache after a few pages: ${oc}"
checks="$(docker exec "$APP" php "$CLI/checks.php" 2>&1 | tail -15 || true)"
info "  (admin/cli/checks.php summary:)"; printf '%s\n' "$checks" | sed 's/^/    /'

fw_finish "moodle ${ver:-$SPEC}"
