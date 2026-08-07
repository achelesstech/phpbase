#!/bin/sh
# =============================================================================
# docker-entrypoint.sh — achelesstech/php-base (runs as www-data, non-root)
# =============================================================================
#   1. Render PHP ini overrides from env  -> /etc/php-runtime.d/zz-runtime.ini
#   2. Render FPM pool overrides from env -> php-fpm.d/zz-runtime.conf
#   3. Run application hooks              -> /docker-entrypoint.d/*.sh
#   4. exec CMD (normally supervisord)
#
# It does NOT render an nginx vhost. The vhost is a static file owned by the
# application image and copied to /etc/nginx/conf.d/.
# =============================================================================
set -eu

RUNTIME_INI="/etc/php-runtime.d/zz-runtime.ini"
RUNTIME_FPM="/usr/local/etc/php-fpm.d/zz-runtime.conf"

log() { echo "[entrypoint] $*"; }

# ── PHP ini overrides ────────────────────────────────────────────────────────
# /etc/php-runtime.d is the second entry in PHP_INI_SCAN_DIR, so anything
# written here wins over the baked defaults in conf.d/zz-base.ini.
render_php_overrides() {
    : > "$RUNTIME_INI"
    count=0

    for pair in \
        "PHP_MEMORY_LIMIT:memory_limit" \
        "PHP_UPLOAD_MAX_FILESIZE:upload_max_filesize" \
        "PHP_POST_MAX_SIZE:post_max_size" \
        "PHP_MAX_EXECUTION_TIME:max_execution_time" \
        "PHP_MAX_INPUT_TIME:max_input_time" \
        "PHP_MAX_INPUT_VARS:max_input_vars" \
        "PHP_DATE_TIMEZONE:date.timezone" \
        "PHP_DISPLAY_ERRORS:display_errors" \
        "PHP_ERROR_REPORTING:error_reporting" \
        "PHP_SESSION_COOKIE_SECURE:session.cookie_secure" \
        "PHP_SESSION_SAVE_HANDLER:session.save_handler" \
        "PHP_SESSION_SAVE_PATH:session.save_path" \
        "PHP_OPCACHE_ENABLE:opcache.enable" \
        "PHP_OPCACHE_MEMORY:opcache.memory_consumption" \
        "PHP_OPCACHE_MAX_FILES:opcache.max_accelerated_files" \
        "PHP_OPCACHE_VALIDATE_TIMESTAMPS:opcache.validate_timestamps"
    do
        env_name="${pair%%:*}"
        ini_key="${pair#*:}"
        eval "value=\${${env_name}:-}"
        [ -n "$value" ] || continue
        printf '%s = %s\n' "$ini_key" "$value" >> "$RUNTIME_INI"
        count=$((count + 1))
    done

    [ "$count" -eq 0 ] || log "applied ${count} PHP ini override(s)"
}

# ── PHP-FPM pool overrides ───────────────────────────────────────────────────
# Pool sizing is the single most deployment-specific setting in the image, so
# it is runtime env rather than a build arg. Re-opening [www] appends to the
# pool defined in www.conf; later keys win.
render_fpm_overrides() {
    : > "$RUNTIME_FPM"
    body=""
    count=0

    for pair in \
        "FPM_PM:pm" \
        "FPM_MAX_CHILDREN:pm.max_children" \
        "FPM_START_SERVERS:pm.start_servers" \
        "FPM_MIN_SPARE_SERVERS:pm.min_spare_servers" \
        "FPM_MAX_SPARE_SERVERS:pm.max_spare_servers" \
        "FPM_MAX_REQUESTS:pm.max_requests" \
        "FPM_PROCESS_IDLE_TIMEOUT:pm.process_idle_timeout" \
        "FPM_REQUEST_TERMINATE_TIMEOUT:request_terminate_timeout" \
        "FPM_SLOWLOG_TIMEOUT:request_slowlog_timeout"
    do
        env_name="${pair%%:*}"
        key="${pair#*:}"
        eval "value=\${${env_name}:-}"
        [ -n "$value" ] || continue
        body="${body}${key} = ${value}
"
        count=$((count + 1))
    done

    if [ "$count" -gt 0 ]; then
        printf '[www]\n%s' "$body" > "$RUNTIME_FPM"
        log "applied ${count} PHP-FPM pool override(s)"
    fi
}

# ── Application hooks ────────────────────────────────────────────────────────
# Read-only bind mounts frequently lose the exec bit, so fall back to `sh`.
run_hooks() {
    [ -d /docker-entrypoint.d ] || return 0
    for hook in /docker-entrypoint.d/*.sh; do
        [ -e "$hook" ] || continue
        if [ -x "$hook" ]; then
            log "running ${hook}"
            "$hook"
        else
            log "running ${hook} (via sh — not executable)"
            sh "$hook"
        fi
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────
log "$(cat /etc/php-base-release 2>/dev/null || echo 'php-base')"

render_php_overrides
render_fpm_overrides
run_hooks

log "exec: $*"
exec "$@"
