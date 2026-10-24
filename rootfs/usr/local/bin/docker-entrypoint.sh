#!/bin/sh
# =============================================================================
# docker-entrypoint.sh — achelesstech/php-base (runs as www-data, non-root)
# =============================================================================
#   1. Reset the runtime dir        /tmp/php-base           (wiped every start)
#   2. PHP ini overrides from env   /tmp/php-base/php/zz-runtime.ini
#   3. FPM pool overrides from env  /tmp/php-base/fpm/zz-runtime.conf
#   4. nginx http{} settings        /tmp/php-base/nginx/http.d/10-php-base.conf
#   5. Application hooks            /docker-entrypoint.d/*.sh
#   6. Validate (web role only), then exec CMD
#
# Nothing rendered here survives a restart, and nothing outside /tmp is
# written, so a read-only root filesystem works with a single tmpfs:
#
#     read_only: true
#     tmpfs: [/tmp]
#
# /tmp rather than /run: Docker mounts a /run tmpfs as root:root 0755, which
# a non-root entrypoint cannot write, while /tmp gets 1777.
# =============================================================================
set -eu

RUNTIME=/tmp/php-base
APP_ROOT="${APP_ROOT:-/var/www/html}"
export APP_ROOT

# All entrypoint output goes to STDERR. Stdout belongs to the command: with
# logging on stdout, `docker compose run --rm app php artisan route:list --json`
# (or any CLI piped into jq) starts with "[entrypoint] …" lines and breaks.
log()  { echo "[entrypoint] $*" >&2; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# ── 1. Runtime directory ─────────────────────────────────────────────────────
reset_runtime() {
    mkdir -p "$RUNTIME" 2>/dev/null \
        || die "cannot create ${RUNTIME}. With read_only: true, mount a tmpfs at /tmp."
    [ -w "$RUNTIME" ] || die "${RUNTIME} is not writable by uid $(id -u) (created as root at build time? remove it from the image)"

    # Wipe the previous start's files. Anything a compromised PHP process left
    # here — an .ini with auto_prepend_file, an nginx include — is gone before
    # PHP or nginx ever reads this directory.
    find "$RUNTIME" -mindepth 1 -delete 2>/dev/null \
        || die "could not clean ${RUNTIME} (files owned by another uid?)"

    mkdir -p "$RUNTIME/php" "$RUNTIME/fpm" "$RUNTIME/nginx/http.d" \
             "$RUNTIME/nginx/tmp/client-body" "$RUNTIME/nginx/tmp/proxy" \
             "$RUNTIME/nginx/tmp/fastcgi" "$RUNTIME/nginx/tmp/uwsgi" \
             "$RUNTIME/nginx/tmp/scgi"
}

# ── Role ─────────────────────────────────────────────────────────────────────
# "web" when CMD is the default supervisord (nginx + FPM); "cli" for a worker,
# scheduler or one-off command. healthcheck.sh picks its probe from this.
detect_role() {
    case "${1:-}" in
        supervisord|*/supervisord) ROLE=web ;;
        *)                         ROLE=cli ;;
    esac
    printf '%s\n' "$ROLE" > "$RUNTIME/role"
}

# ini values: simple tokens are written bare (256M, On, UTC, /tmp); anything
# else is quoted, so a Redis save_path like tcp://redis:6379?auth=x&database=2
# no longer breaks the ini parser. error_reporting stays bare: it is an
# expression (E_ALL & ~E_DEPRECATED).
ini_line() {
    key="$1"; value="$2"
    case "$value" in *'"'*) die "${key}: double quotes are not supported in env-rendered ini values" ;; esac
    if [ "$key" = error_reporting ] || printf '%s' "$value" | grep -qE '^[A-Za-z0-9_./:+@-]+$'; then
        printf '%s = %s\n' "$key" "$value"
    else
        printf '%s = "%s"\n' "$key" "$value"
    fi
}

# ── 2. PHP ini overrides ─────────────────────────────────────────────────────
render_php() {
    out="$RUNTIME/php/zz-runtime.ini"
    : > "$out"
    n=0
    for pair in \
        PHP_MEMORY_LIMIT:memory_limit \
        PHP_UPLOAD_MAX_FILESIZE:upload_max_filesize \
        PHP_POST_MAX_SIZE:post_max_size \
        PHP_MAX_EXECUTION_TIME:max_execution_time \
        PHP_MAX_INPUT_TIME:max_input_time \
        PHP_MAX_INPUT_VARS:max_input_vars \
        PHP_MAX_FILE_UPLOADS:max_file_uploads \
        PHP_DATE_TIMEZONE:date.timezone \
        PHP_DISPLAY_ERRORS:display_errors \
        PHP_ERROR_REPORTING:error_reporting \
        PHP_ZEND_ASSERTIONS:zend.assertions \
        PHP_SESSION_COOKIE_SECURE:session.cookie_secure \
        PHP_SESSION_COOKIE_SAMESITE:session.cookie_samesite \
        PHP_SESSION_GC_MAXLIFETIME:session.gc_maxlifetime \
        PHP_SESSION_SAVE_HANDLER:session.save_handler \
        PHP_SESSION_SAVE_PATH:session.save_path \
        PHP_OPCACHE_ENABLE:opcache.enable \
        PHP_OPCACHE_ENABLE_CLI:opcache.enable_cli \
        PHP_OPCACHE_MEMORY:opcache.memory_consumption \
        PHP_OPCACHE_INTERNED_STRINGS_BUFFER:opcache.interned_strings_buffer \
        PHP_OPCACHE_MAX_FILES:opcache.max_accelerated_files \
        PHP_OPCACHE_VALIDATE_TIMESTAMPS:opcache.validate_timestamps \
        PHP_OPCACHE_REVALIDATE_FREQ:opcache.revalidate_freq \
        PHP_OPCACHE_JIT:opcache.jit \
        PHP_OPCACHE_JIT_BUFFER_SIZE:opcache.jit_buffer_size \
        PHP_REALPATH_CACHE_SIZE:realpath_cache_size \
        PHP_REALPATH_CACHE_TTL:realpath_cache_ttl
    do
        name="${pair%%:*}"
        key="${pair#*:}"
        eval "value=\${${name}:-}"
        [ -n "$value" ] || continue
        ini_line "$key" "$value" >> "$out"
        n=$((n + 1))
    done

    # Free-form escape hatch, written verbatim, one directive per line:
    #   PHP_INI_EXTRA: |
    #     mbstring.language = Neutral
    #     pcre.backtrack_limit = 5000000
    if [ -n "${PHP_INI_EXTRA:-}" ]; then
        printf '%s\n' "$PHP_INI_EXTRA" >> "$out"
        n=$((n + 1))
    fi

    [ "$n" -eq 0 ] || log "applied ${n} PHP ini override(s)"
}

# ── 3. PHP-FPM pool overrides ────────────────────────────────────────────────
# Pool sizing is the most deployment-specific setting in the image, so it is
# runtime env. Re-opening [www] appends to the pool from www.conf; later wins.
render_fpm() {
    out="$RUNTIME/fpm/zz-runtime.conf"
    printf '[www]\n' > "$out"
    n=0
    for pair in \
        FPM_PM:pm \
        FPM_MAX_CHILDREN:pm.max_children \
        FPM_START_SERVERS:pm.start_servers \
        FPM_MIN_SPARE_SERVERS:pm.min_spare_servers \
        FPM_MAX_SPARE_SERVERS:pm.max_spare_servers \
        FPM_MAX_REQUESTS:pm.max_requests \
        FPM_PROCESS_IDLE_TIMEOUT:pm.process_idle_timeout \
        FPM_REQUEST_TERMINATE_TIMEOUT:request_terminate_timeout \
        FPM_SLOWLOG_TIMEOUT:request_slowlog_timeout
    do
        name="${pair%%:*}"
        key="${pair#*:}"
        eval "value=\${${name}:-}"
        [ -n "$value" ] || continue
        printf '%s = %s\n' "$key" "$value" >> "$out"
        n=$((n + 1))
    done

    if [ "${FPM_ACCESS_LOG:-0}" = 1 ]; then
        # php-fpm closes stdout at startup; fd 2 is the one that works.
        printf '%s\n' 'access.log = /proc/self/fd/2' \
            'access.format = "%R - %u %t \"%m %r\" %s %f %{mili}dms %{kilo}MkB %C%%"' >> "$out"
        n=$((n + 1))
    fi

    if [ -n "${FPM_POOL_EXTRA:-}" ]; then
        printf '%s\n' "$FPM_POOL_EXTRA" >> "$out"
        n=$((n + 1))
    fi

    [ "$n" -eq 0 ] || log "applied ${n} PHP-FPM pool override(s)"
}

# ── 4. nginx http{} settings ─────────────────────────────────────────────────
render_nginx() {
    out="$RUNTIME/nginx/http.d/10-php-base.conf"

    # Follow PHP's EFFECTIVE post_max_size (baked ini + overrides) unless set
    # explicitly. A mismatch is the classic "upload fails at nginx with 413
    # although PHP allows it".
    body="${NGINX_CLIENT_MAX_BODY_SIZE:-$(php -r 'echo ini_get("post_max_size");' 2>/dev/null || echo 64M)}"
    printf '%s' "$body" | grep -qE '^[0-9]+[kKmMgG]?$' \
        || die "NGINX_CLIENT_MAX_BODY_SIZE / post_max_size '${body}' is not a size nginx understands"

    header="${NGINX_REAL_IP_HEADER:-X-Forwarded-For}"
    printf '%s' "$header" | grep -qE '^[A-Za-z0-9-]+$' || die "bad NGINX_REAL_IP_HEADER '${header}'"

    # Unset -> private ranges (Traefik on a Docker network); set to "" to trust nothing.
    if [ "${NGINX_REAL_IP_FROM+set}" = set ]; then from="$NGINX_REAL_IP_FROM"; else from="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7"; fi
    cloudflare="${NGINX_TRUST_CLOUDFLARE:-1}"

    {
        echo "# Rendered by docker-entrypoint.sh — do not edit; change the env instead."
        echo "client_max_body_size ${body};"
        if [ -n "$from" ]; then
            echo "real_ip_header    ${header};"
            echo "real_ip_recursive on;"
            for cidr in $from; do
                printf '%s' "$cidr" | grep -qE '^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$' || die "bad CIDR in NGINX_REAL_IP_FROM: '${cidr}'"
                echo "set_real_ip_from ${cidr};"
            done
            # Behind Cloudflare -> Traefik, Traefik appends the edge address to
            # X-Forwarded-For; without these ranges nginx stops there and every
            # visitor "is" a Cloudflare IP (rate limits, logs, IP bans).
            [ "$cloudflare" != 1 ] || echo "include /etc/nginx/php-base/cloudflare-real-ip.conf;"
        fi
        case "${NGINX_ACCESS_LOG:-main}" in
            main) echo "access_log /dev/stdout main;" ;;
            json) echo "access_log /dev/stdout json;" ;;
            off)  echo "access_log off;" ;;
            *)    die "NGINX_ACCESS_LOG must be main, json or off" ;;
        esac
    } > "$out"
}

# ── Optional supervisord programs ────────────────────────────────────────────
# supervisord.conf reads these through %(ENV_…)s, so it must see a value even
# when the feature is off.
export_supervisor_env() {
    export SCHEDULER_INTERVAL="${SCHEDULER_INTERVAL:-60}"
    if [ -n "${SCHEDULER_COMMAND:-}" ]; then
        export PHP_BASE_SCHEDULER_ENABLED=true
        [ "$ROLE" != web ] || log "scheduler: every ${SCHEDULER_INTERVAL}s: ${SCHEDULER_COMMAND}"
    else
        export SCHEDULER_COMMAND=true PHP_BASE_SCHEDULER_ENABLED=false
    fi
    if [ -n "${WORKER_COMMAND:-}" ]; then
        export PHP_BASE_WORKER_ENABLED=true
        [ "$ROLE" != web ] || log "worker: ${WORKER_COMMAND}"
    else
        export WORKER_COMMAND=true PHP_BASE_WORKER_ENABLED=false
    fi
}

# ── 5. Application hooks ─────────────────────────────────────────────────────
# Hooks run at every start, so a hook the runtime user can modify is a
# persistence channel for a compromised PHP process. Warn (PHP_BASE_STRICT=1:
# refuse) when one is. COPY hooks without --chown: root-owned, mode 0755.
run_hooks() {
    [ -d /docker-entrypoint.d ] || return 0
    [ ! -w /docker-entrypoint.d ] || warn "/docker-entrypoint.d is writable by uid $(id -u)"
    for hook in /docker-entrypoint.d/*.sh; do
        [ -e "$hook" ] || continue
        if [ -w "$hook" ]; then
            warn "${hook} is writable by uid $(id -u) — COPY it without --chown (root-owned)"
            [ "${PHP_BASE_STRICT:-0}" != 1 ] || die "refusing to run a runtime-writable hook (PHP_BASE_STRICT=1)"
        fi
        # Read-only bind mounts frequently lose the exec bit, so fall back to
        # sh. Hook output goes to stderr too, for the same reason as log().
        if [ -x "$hook" ]; then
            log "running ${hook}"
            "$hook" >&2
        else
            log "running ${hook} (via sh — not executable)"
            sh "$hook" >&2
        fi
    done
}

# ── 6. Validate ──────────────────────────────────────────────────────────────
# Seconds-long crash loops with a bad env value are worse than one clear line.
validate() {
    [ "$ROLE" = web ] || return 0
    if ! out="$(nginx -t -e stderr 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "nginx configuration test failed"
    fi
    if ! out="$(php-fpm -t 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "php-fpm configuration test failed"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
reset_runtime
detect_role "$@"
log "$(php-base-info --short 2>/dev/null || echo php-base) role=${ROLE}"
render_php
render_fpm
render_nginx
export_supervisor_env
run_hooks
validate

log "exec: $*"
exec "$@"
