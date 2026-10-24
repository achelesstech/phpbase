#!/usr/bin/env bash
# WordPress: core + wp-cli on the wordpress preset, MariaDB, real install.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
IMAGE="${1:?base image}"; SPEC="${2:-latest}"

info "wordpress: build"
fw_build "fw-wordpress:${FW_SUFFIX}" "$HERE/wordpress" --build-arg "BASE_IMAGE=${IMAGE}" --build-arg "WP_VERSION=${SPEC}"

info "wordpress: boot + install"
DB="$(fw_run db -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress -e MARIADB_PASSWORD=wp-smoke \
    -e MARIADB_RANDOM_ROOT_PASSWORD=yes --health-cmd 'healthcheck.sh --connect --innodb_initialized' \
    --health-interval 2s --health-retries 60 mariadb:11.4)"
fw_wait_healthy "$DB" 180 || { bad "mariadb never healthy"; fw_finish wordpress; }
APP="$(fw_run wordpress -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_PASSWORD=wp-smoke -e WORDPRESS_URL=http://localhost:8080 \
    "fw-wordpress:${FW_SUFFIX}")"
fw_wait_healthy "$APP" && ok "healthy (fpm-ping through the wordpress preset)" || { bad "never healthy"; fw_finish wordpress; }
fw_exec_ok "wp core install" "$APP" wp core install --url=http://localhost:8080 --title=SmokeWP \
    --admin_user=admin --admin_password=admin-smoke-123 --admin_email=admin@example.com --skip-email
fw_exec_ok "pretty permalinks" "$APP" wp rewrite structure '/%postname%/'
ver="$(docker exec "$APP" wp core version 2>/dev/null)"
ok "WordPress ${ver} installed"

info "wordpress: requests"
expect "$APP" / 200 "SmokeWP" "GET / renders the site"
expect "$APP" /hello-world/ 200 "Hello world" "pretty permalink /hello-world/ (try_files -> index.php)"
expect "$APP" /wp-login.php 200 "user_login" "GET /wp-login.php"
not_executed "$APP" /wp-content/uploads/evil.php
expect "$APP" /wp-config.php 404 "" "wp-config.php is never served"
expect "$APP" /xmlrpc.php 404 "" "xmlrpc.php denied"
expect "$APP" /readme.html 404 "" "readme.html (version disclosure) denied"
expect "$APP" /wp-json/ 200 "" "REST API index /wp-json/"

info "wordpress: media, cron, site health"
docker exec "$APP" php -r '$i = imagecreatetruecolor(1600, 1200); imagefilledrectangle($i, 0, 0, 1600, 1200, imagecolorallocate($i, 200, 80, 40)); imagejpeg($i, "/tmp/smoke.jpg", 90);'
fw_exec_ok "wp media import (thumbnails via the image editor)" "$APP" wp media import /tmp/smoke.jpg --title=Smoke
editor="$(docker exec "$APP" wp eval 'echo _wp_image_editor_choose(["mime_type" => "image/jpeg"]);' 2>/dev/null || true)"
[[ "$editor" == WP_Image_Editor_Imagick ]] && ok "image editor: ${editor}" || bad "image editor is ${editor:-none} (expected Imagick)"
heic="$(docker exec "$APP" wp eval 'echo wp_image_editor_supports(["mime_type" => "image/heic"]) ? "yes" : "no";' 2>/dev/null || true)"
[[ "$heic" == yes ]] && ok "HEIC uploads supported (WordPress 6.7+ converts them)" || bad "HEIC not supported"
fw_exec_ok "wp cron event run --due-now via php-base-every --once" "$APP" php-base-every --once 60 wp cron event run --due-now
health="$(docker exec "$APP" wp eval '
    require_once ABSPATH . "wp-admin/includes/admin.php";
    require_once ABSPATH . "wp-admin/includes/class-wp-site-health.php";
    $h = WP_Site_Health::get_instance();
    foreach (["php_extensions", "php_default_timezone", "php_sessions", "sql_server", "utf8mb4_support",
              "file_uploads", "opcode_cache", "persistent_object_cache", "available_updates_disk_space"] as $t) {
        if (method_exists($h, "get_test_" . $t)) {
            $r = $h->{"get_test_" . $t}();
            echo $t, "=", $r["status"], " ";
        }
    }' 2>&1 || true)"
[[ "$health" == *"php_extensions=good"* ]] && ok "Site Health: required+recommended PHP extensions all present" || bad "Site Health: ${health}"
info "  (Site Health: ${health})"

fw_finish "wordpress ${ver}"
