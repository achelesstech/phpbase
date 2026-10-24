#!/usr/bin/env bash
# Laravel: create-project, boot behind the laravel preset, exercise it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
IMAGE="${1:?base image}"; SPEC="${2:-laravel/laravel:^13.0}"

info "laravel: build"
fw_build "fw-laravel:${FW_SUFFIX}" "$HERE/laravel" --build-arg "BASE_IMAGE=${IMAGE}" --build-arg "LARAVEL_SPEC=${SPEC}"

info "laravel: boot"
APP="$(fw_run laravel "fw-laravel:${FW_SUFFIX}")"
fw_wait_healthy "$APP" && ok "healthy (fpm-ping through the laravel preset)" || { bad "never healthy"; fw_finish laravel; }
ver="$(docker exec "$APP" php artisan --version --no-ansi 2>/dev/null || true)"
ok "running ${ver}"

info "laravel: requests"
expect "$APP" / 200 "Laravel" "GET / renders the welcome page (sessions/cache in SQLite work)"
expect "$APP" /up 200 "" "GET /up (Laravel health route) -> 200"
not_executed "$APP" /evil.php
expect "$APP" /.env 404 "" "GET /.env -> 404"
expect "$APP" /index.php 200 "Laravel" "GET /index.php -> front controller"
app_handles_missing "$APP" /livewire/livewire.js
app_handles_missing "$APP" /images/route-served.png
code="$(fw_get "$APP" /favicon.ico -I)"; [[ "$code" =~ ^(200|204)$ ]] && ok "favicon served ($code)" || bad "favicon ($code)"

info "laravel: CLI"
fw_exec_ok "php artisan about" "$APP" php artisan about --no-ansi
fw_exec_ok "config:cache + route:cache + view:cache (bootstrap/cache and storage writable)" "$APP" sh -c 'php artisan config:cache && php artisan route:cache && php artisan view:cache'
fw_exec_ok "scheduler: php-base-every --once 60 php artisan schedule:run" "$APP" php-base-every --once 60 php artisan schedule:run
fw_exec_ok "queue: php artisan queue:work --once --stop-when-empty" "$APP" php artisan queue:work --once --stop-when-empty
fw_exec_ok "code is not writable by the runtime user" "$APP" sh -c '! test -w app && ! test -w public/index.php'

fw_finish "laravel (${ver})"
