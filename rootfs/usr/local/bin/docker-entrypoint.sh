#!/bin/sh
# =============================================================================
# docker-entrypoint.sh — achelesstech/php-base (runs as www-data, non-root)
# =============================================================================
#   1. Reset the runtime dir        /tmp/php-base           (wiped every start)
#      and recreate $HOME           /tmp/php-base/home      (/home/www-data links here)
#   2. PHP ini overrides from env   /tmp/php-base/php/zz-runtime.ini
#   3. FPM pool size + env          /tmp/php-base/fpm/zz-runtime.conf
#   4. nginx settings               /tmp/php-base/nginx/{main,http}.d/10-php-base.conf
#   5. s6 scan directory (web role) /tmp/php-base/s6/scan
#   6. Application hooks            /docker-entrypoint.d/*.sh
#   7. Validate (web role only), then exec CMD
#
# Nothing rendered here survives a restart, and nothing outside /tmp is
# written, so a read-only root filesystem works with a single tmpfs:
#
#     read_only: true
#     tmpfs: ["/tmp:rw,noexec,nosuid,nodev,size=256m"]
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

    mkdir -p "$RUNTIME/php" "$RUNTIME/fpm" "$RUNTIME/nginx/main.d" "$RUNTIME/nginx/http.d" \
             "$RUNTIME/nginx/tmp/client-body" "$RUNTIME/nginx/tmp/proxy" \
             "$RUNTIME/nginx/tmp/fastcgi" "$RUNTIME/nginx/tmp/uwsgi" \
             "$RUNTIME/nginx/tmp/scgi"
    # $HOME: /home/www-data is a symlink to this (the root is read-only).
    mkdir -m 0750 "$RUNTIME/home"
}

# ── Role ─────────────────────────────────────────────────────────────────────
# "web" when CMD is the default php-base-web (nginx + FPM under s6); "cli" for
# a worker, scheduler or one-off command. healthcheck.sh picks its probe from
# this. A v1 app image that still overrides the command with supervisord gets
# one clear line instead of "executable file not found".
detect_role() {
    case "${1:-}" in
        php-base-web|*/php-base-web) ROLE=web ;;
        supervisord|*/supervisord)
            die "supervisord was removed in php-base v2: use the default CMD (php-base-web), SCHEDULER_COMMAND/WORKER_COMMAND, or a separate container — see docs/migrating-from-v1.md" ;;
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
# size_mib SIZE [UNIT] — a size with a k/m/g suffix (64M, 262144k) in whole
# MiB. A bare number is in UNIT: bytes by default, or M. Fails on anything
# else, including a leading zero (08 is an octal error in shell arithmetic).
size_mib() {
    mul=1; div=1
    case "$1" in
        *[kK]) value="${1%?}"; div=1024 ;;
        *[mM]) value="${1%?}" ;;
        *[gG]) value="${1%?}"; mul=1024 ;;
        *)     value="$1"; [ "${2:-}" = M ] || div=1048576 ;;
    esac
    case "$value" in ''|*[!0-9]*|0?*) return 1 ;; esac
    echo $(( value * mul / div ))
}

# fpm_auto_children — print pm.max_children for FPM_MAX_CHILDREN=auto, and log
# the inputs. Workers get what the memory limit leaves after a reserve:
#   clamp(floor((L − R) / W), 2, 64)
#   L  the cgroup memory limit (v2 memory.max, else v1 memory.limit_in_bytes)
#   W  FPM_WORKER_MEMORY (64M)
#   R  opcache.memory_consumption + 64M + the /tmp size when /tmp is a tmpfs:
#      uploads and ImageMagick's cache live there, and on a tmpfs they are RAM
#      charged to the same limit.
# No limit (`max`, or ≥ 2^60 bytes, as cgroup v1 reports "unlimited") → 12.
fpm_auto_children() {
    limit=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        limit="$(cat /sys/fs/cgroup/memory.max)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi
    # Anything over 19 digits would overflow shell arithmetic; it is unlimited anyway.
    case "$limit" in ''|*[!0-9]*|????????????????????*) limit="" ;; esac
    [ -z "$limit" ] || [ $(( limit / 1048576 )) -lt 1099511627776 ] || limit=""
    if [ -z "$limit" ]; then
        log "fpm: max_children=12 (no memory limit)"
        echo 12
        return
    fi
    limit_mib=$(( limit / 1048576 ))

    worker_mib="$(size_mib "${FPM_WORKER_MEMORY:-64M}")" && [ "$worker_mib" -gt 0 ] \
        || die "FPM_WORKER_MEMORY must be a size of at least 1M (e.g. 64M), got '${FPM_WORKER_MEMORY:-}'"

    # The EFFECTIVE value, so PHP_OPCACHE_MEMORY (render_php) counts. ini_get
    # returns it as written: 256 (MiB, as PHP reads a bare number) or 256M.
    opcache="$(php -r 'echo ini_get("opcache.memory_consumption");' 2>/dev/null || true)"
    opcache_mib="$(size_mib "$opcache" M)" \
        || die "cannot read opcache.memory_consumption as a size (got '${opcache}')"

    # The last mount on /tmp wins. A tmpfs mounted without size= shows no size
    # in /proc/mounts (the kernel default, half the host RAM): ask df instead.
    tmp_mib=0
    tmp_mount="$(awk '$2 == "/tmp" { m = $3 " " $4 } END { print m }' /proc/mounts)"
    case "$tmp_mount" in
        "tmpfs "*)
            tmp_size="$(printf '%s\n' "${tmp_mount#tmpfs }" | tr ',' '\n' | sed -n 's/^size=//p')"
            if ! tmp_mib="$(size_mib "$tmp_size")"; then
                tmp_kib="$(df -k /tmp | awk 'NR == 2 { print $2 }')"
                case "$tmp_kib" in ''|*[!0-9]*) die "cannot read the size of the /tmp tmpfs (df gave '${tmp_kib}')" ;; esac
                tmp_mib=$(( tmp_kib / 1024 ))
            fi
            ;;
    esac

    reserve_mib=$(( opcache_mib + 64 + tmp_mib ))
    children=$(( (limit_mib - reserve_mib) / worker_mib ))
    [ "$children" -ge 2 ] || children=2
    [ "$children" -le 64 ] || children=64
    log "fpm: max_children=${children} (limit ${limit_mib}M, worker ${worker_mib}M, reserve ${reserve_mib}M)"
    echo "$children"
}

# Pool sizing is the most deployment-specific setting in the image, so it is
# runtime env. Re-opening [www] appends to the pool from www.conf; later wins,
# so the explicit FPM_* values, rendered after the derived ones, override them.
render_fpm() {
    out="$RUNTIME/fpm/zz-runtime.conf"

    children="${FPM_MAX_CHILDREN:-auto}"
    case "$children" in
        auto) children="$(fpm_auto_children)" ;;
        ''|*[!0-9]*|0*) die "FPM_MAX_CHILDREN must be a whole number of at least 1, or auto, got '${children}'" ;;
    esac
    # Spare servers scale with the pool, never past it (an explicit
    # FPM_MAX_CHILDREN=1 must still give a config php-fpm accepts).
    start=$(( (children + 3) / 4 )); [ "$start" -ge 2 ] || start=2
    min_spare=$(( children / 4 ));   [ "$min_spare" -ge 1 ] || min_spare=1
    max_spare=$(( (children + 1) / 2 )); [ "$max_spare" -ge 2 ] || max_spare=2
    [ "$start" -le "$children" ] || start="$children"
    [ "$max_spare" -le "$children" ] || max_spare="$children"

    {
        printf '[www]\n'
        printf 'pm.max_children = %s\n' "$children"
        printf 'pm.start_servers = %s\n' "$start"
        printf 'pm.min_spare_servers = %s\n' "$min_spare"
        printf 'pm.max_spare_servers = %s\n' "$max_spare"
        printf 'request_terminate_timeout = %s\n' "${FPM_REQUEST_TERMINATE_TIMEOUT:-300s}"
    } > "$out"

    n=0
    [ "${FPM_MAX_CHILDREN:-auto}" = auto ] || n=$((n + 1))
    [ -z "${FPM_REQUEST_TERMINATE_TIMEOUT:-}" ] || n=$((n + 1))
    for pair in \
        FPM_PM:pm \
        FPM_START_SERVERS:pm.start_servers \
        FPM_MIN_SPARE_SERVERS:pm.min_spare_servers \
        FPM_MAX_SPARE_SERVERS:pm.max_spare_servers \
        FPM_MAX_REQUESTS:pm.max_requests \
        FPM_PROCESS_IDLE_TIMEOUT:pm.process_idle_timeout \
        FPM_SLOWLOG_TIMEOUT:request_slowlog_timeout
    do
        name="${pair%%:*}"
        key="${pair#*:}"
        eval "value=\${${name}:-}"
        [ -n "$value" ] || continue
        printf '%s = %s\n' "$key" "$value" >> "$out"
        n=$((n + 1))
    done

    # Web requests only: the CLI (artisan, drush, cron) does not read the pool.
    if [ -n "${PHP_DISABLE_FUNCTIONS:-}" ]; then
        printf '%s' "$PHP_DISABLE_FUNCTIONS" | grep -qE '^[A-Za-z0-9_, ]+$' \
            || die "PHP_DISABLE_FUNCTIONS must be a comma-separated list of function names, got '${PHP_DISABLE_FUNCTIONS}'"
        printf 'php_admin_value[disable_functions] = %s\n' "$PHP_DISABLE_FUNCTIONS" >> "$out"
        n=$((n + 1))
    fi

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

# ── 4. nginx settings ────────────────────────────────────────────────────────
render_nginx() {
    # Main context. 2 rather than auto: auto is one per host CPU, not per CPU
    # the container may use, and each worker holds its own open_file_cache.
    workers="${NGINX_WORKER_PROCESSES:-2}"
    case "$workers" in
        auto) ;;
        ''|*[!0-9]*|0*) die "NGINX_WORKER_PROCESSES must be a whole number of at least 1, or auto, got '${workers}'" ;;
    esac
    printf '%s\n' "# Rendered by docker-entrypoint.sh — do not edit; change the env instead." \
        "worker_processes ${workers};" > "$RUNTIME/nginx/main.d/10-php-base.conf"

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

    # Keep PHP max_execution_time <= FPM_REQUEST_TERMINATE_TIMEOUT <= this <=
    # Traefik's readTimeout, so the innermost layer gives up first. Zero would
    # fail every slow request at once.
    read_timeout="${NGINX_FASTCGI_READ_TIMEOUT:-300s}"
    printf '%s' "$read_timeout" | grep -qE '^0*[1-9][0-9]*[smh]?$' \
        || die "NGINX_FASTCGI_READ_TIMEOUT must be a number above 0 with an optional s, m or h suffix (e.g. 600s), got '${read_timeout}'"

    gzip="${NGINX_GZIP:-0}"
    case "$gzip" in 0|1) ;; *) die "NGINX_GZIP must be 0 or 1, got '${gzip}'" ;; esac

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
        echo "fastcgi_read_timeout ${read_timeout};"
        # Off by default: Traefik already logs every request.
        case "${NGINX_ACCESS_LOG:-off}" in
            main) echo "access_log /dev/stdout main;" ;;
            json) echo "access_log /dev/stdout json;" ;;
            off)  echo "access_log off;" ;;
            *)    die "NGINX_ACCESS_LOG must be main, json or off" ;;
        esac
        # Off by default: Traefik compresses, and compressing twice wastes CPU.
        # gzip_vary and gzip_proxied are in nginx.conf (gzip_static uses them).
        if [ "$gzip" = 1 ]; then
            echo "gzip            on;"
            echo "gzip_comp_level 5;"
            echo "gzip_min_length 256;"
            echo "gzip_types text/plain text/css text/xml text/javascript"
            echo "    application/javascript application/json application/xml application/xml+rss"
            echo "    application/atom+xml application/manifest+json image/svg+xml font/woff2;"
        fi
    } > "$out"
}

# ── 5. s6 services (web role) ────────────────────────────────────────────────
# php-base-web runs s6-svscan on $RUNTIME/s6/scan. Each enabled service is a
# symlink to its root-owned definition in /etc/php-base/s6/, whose supervise/
# and event/ are in turn symlinks into $RUNTIME/s6/<service>/ — the only
# writable state s6 has; s6-supervise creates the targets (so they must not
# exist beforehand). The run scripts read SCHEDULER_COMMAND, SCHEDULER_INTERVAL,
# WORKER_COMMAND and APP_ROOT from the environment s6 inherits from here.
enable_service() {
    mkdir -p "$RUNTIME/s6/$1"
    ln -s "/etc/php-base/s6/$1" "$RUNTIME/s6/scan/$1"
}
render_services() {
    [ "$ROLE" = web ] || return 0
    scan="$RUNTIME/s6/scan"
    mkdir -p "$scan/.s6-svscan"
    # SIGTERM: the stop order (nginx drains first); finish: the exit status.
    for hook in SIGTERM finish; do ln -s "/etc/php-base/s6/.s6-svscan/$hook" "$scan/.s6-svscan/$hook"; done
    for service in php-fpm nginx; do enable_service "$service"; done
    if [ -n "${SCHEDULER_COMMAND:-}" ]; then
        interval="${SCHEDULER_INTERVAL:-60}"
        case "$interval" in ''|*[!0-9]*|0) die "SCHEDULER_INTERVAL must be a whole number of seconds, got '${interval}'" ;; esac
        enable_service scheduler
        log "scheduler: every ${interval}s: ${SCHEDULER_COMMAND}"
    fi
    if [ -n "${WORKER_COMMAND:-}" ]; then
        enable_service worker
        log "worker: ${WORKER_COMMAND}"
    fi
}

# ── 6. Application hooks ─────────────────────────────────────────────────────
# Hooks run at every start, so a hook anyone but root can modify is a
# persistence channel for a compromised PHP process: its owner can chmod it
# back to writable, and group/other write bits need no chmod at all. Warn
# (PHP_BASE_STRICT=1: refuse) on either. COPY hooks without --chown:
# root-owned, mode 0755.
run_hooks() {
    [ -d /docker-entrypoint.d ] || return 0
    [ ! -w /docker-entrypoint.d ] || warn "/docker-entrypoint.d is writable by uid $(id -u)"
    for hook in /docker-entrypoint.d/*.sh; do
        [ -e "$hook" ] || continue
        # busybox stat: owner uid, then the octal mode without a leading 0.
        # -L judges what runs: a symlink's own mode is always 777, and
        # Kubernetes ConfigMap/Secret volumes mount every file as one.
        owner_mode="$(stat -L -c '%u %a' "$hook")"
        unsafe=0
        if [ "${owner_mode% *}" != 0 ]; then
            warn "${hook} is not root-owned"
            unsafe=1
        fi
        if [ $((0${owner_mode#* } & 022)) -ne 0 ]; then
            warn "${hook} is writable by group or others"
            unsafe=1
        fi
        [ "$unsafe" = 0 ] || [ "${PHP_BASE_STRICT:-0}" != 1 ] \
            || die "refusing to run ${hook} (PHP_BASE_STRICT=1): COPY it without --chown, mode 0755"
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

# ── 7. Validate ──────────────────────────────────────────────────────────────
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
render_services
run_hooks
validate

log "exec: $*"
exec "$@"
