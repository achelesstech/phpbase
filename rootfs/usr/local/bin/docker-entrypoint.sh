#!/bin/sh
set -e

# =============================================================================
# docker-entrypoint.sh — PHP Base Image (runs as www-data, non-root)
# =============================================================================
# 1. Applies runtime PHP overrides from ENV
# 2. Toggles Xdebug / PCOV from ENV
# 3. Renders the nginx vhost from the template selected by NGINX_PROFILE
# 4. Runs child-image hooks from /docker-entrypoint.d/
# 5. Hands off to CMD (supervisord)
# =============================================================================

# ── Runtime ENV overrides for PHP ────────────────────────────────────────────
apply_runtime_php_overrides() {
    INI="/usr/local/etc/php/conf.d/zz-runtime-overrides.ini"
    CHANGED=false

    : > "$INI"  # pre-created and www-data-owned at build time

    for pair in \
        "PHP_MEMORY_LIMIT:memory_limit" \
        "PHP_UPLOAD_MAX_FILESIZE:upload_max_filesize" \
        "PHP_POST_MAX_SIZE:post_max_size" \
        "PHP_MAX_EXECUTION_TIME:max_execution_time" \
        "PHP_DISPLAY_ERRORS:display_errors" \
        "PHP_ERROR_REPORTING:error_reporting" \
        "PHP_SESSION_COOKIE_SECURE:session.cookie_secure" \
        "PHP_OPCACHE_VALIDATE_TIMESTAMPS:opcache.validate_timestamps"
    do
        ENV_NAME="${pair%%:*}"
        INI_KEY="${pair#*:}"
        eval VAL="\${$ENV_NAME:-}"
        if [ -n "$VAL" ]; then
            echo "$INI_KEY = $VAL" >> "$INI"
            CHANGED=true
        fi
    done

    # `$CHANGED && echo` returns 1 when false and aborts under `set -e` —
    # use an explicit if instead.
    if [ "$CHANGED" = "true" ]; then
        echo "[entrypoint] Applied runtime PHP overrides"
    fi
}

# ── Enable Xdebug / PCOV if requested via ENV ───────────────────────────────
toggle_debug_extensions() {
    EXT_DIR="/usr/local/etc/php/conf.d"

    if [ "${ENABLE_XDEBUG:-false}" = "true" ] && \
       [ -f "$EXT_DIR/docker-php-ext-xdebug.ini.disabled" ]; then
        cp "$EXT_DIR/docker-php-ext-xdebug.ini.disabled" \
           "$EXT_DIR/docker-php-ext-xdebug.ini"
        echo "[entrypoint] Xdebug ENABLED"
    fi

    if [ "${ENABLE_PCOV:-false}" = "true" ] && \
       [ -f "$EXT_DIR/docker-php-ext-pcov.ini.disabled" ]; then
        cp "$EXT_DIR/docker-php-ext-pcov.ini.disabled" \
           "$EXT_DIR/docker-php-ext-pcov.ini"
        echo "[entrypoint] PCOV ENABLED"
    fi
}

# ── Render nginx vhost from platform template ───────────────────────────────
# NGINX_PROFILE: generic | laravel | drupal | moodle (child images set this)
# Document root resolution (explicit if/elif — the old &&/|| chain always
# overwrote DOCUMENT_ROOT with the public dir):
#   1. NGINX_DOCUMENT_ROOT env, if set
#   2. APP_ROOT/APP_PUBLIC_DIR, if APP_PUBLIC_DIR is non-empty
#   3. APP_ROOT
render_nginx_vhost() {
    PROFILE="${NGINX_PROFILE:-generic}"
    TPL="/etc/nginx/templates/${PROFILE}.conf.tpl"

    if [ ! -f "$TPL" ]; then
        echo "[entrypoint] WARNING: unknown NGINX_PROFILE '${PROFILE}', falling back to generic"
        TPL="/etc/nginx/templates/generic.conf.tpl"
    fi

    if [ -n "${NGINX_DOCUMENT_ROOT:-}" ]; then
        DOCROOT="${NGINX_DOCUMENT_ROOT}"
    elif [ -n "${APP_PUBLIC_DIR:-}" ]; then
        DOCROOT="${APP_ROOT}/${APP_PUBLIC_DIR}"
    else
        DOCROOT="${APP_ROOT}"
    fi

    sed \
        -e "s|@DOCROOT@|${DOCROOT}|g" \
        -e "s|@FASTCGI_READ_TIMEOUT@|${NGINX_FASTCGI_READ_TIMEOUT:-300}|g" \
        -e "s|@CLIENT_MAX_BODY_SIZE@|${NGINX_CLIENT_MAX_BODY_SIZE:-100M}|g" \
        "$TPL" > /etc/nginx/conf.d/default.conf

    echo "[entrypoint] Rendered nginx vhost: profile=${PROFILE} root=${DOCROOT}"
}

# ── Run child-image init scripts ─────────────────────────────────────────────
run_entrypoint_hooks() {
    if [ -d /docker-entrypoint.d/ ]; then
        for f in /docker-entrypoint.d/*.sh; do
            [ -e "$f" ] || continue
            if [ -x "$f" ]; then
                echo "[entrypoint] Running $f"
                "$f"
            else
                # ro-mounted hooks are often not executable — run via sh
                echo "[entrypoint] Running (sh) $f"
                sh "$f"
            fi
        done
    fi
}

# ── Execute ──────────────────────────────────────────────────────────────────
echo "[entrypoint] PHP Base Image — starting"

apply_runtime_php_overrides
toggle_debug_extensions
render_nginx_vhost
run_entrypoint_hooks

echo "[entrypoint] Handing off to: $*"
exec "$@"
