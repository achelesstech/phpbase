# syntax=docker/dockerfile:1.7
# =============================================================================
# PHP Base Image — Production Grade (Traefik-fronted)
# =============================================================================
# Reusable, configurable PHP + Nginx + Supervisor base image.
# Designed to run BEHIND an external reverse proxy (Traefik) that terminates
# TLS. The container listens on plain HTTP :8080 and trusts X-Forwarded-*.
#
# Build child images for Laravel, Drupal, Moodle, WordPress, Symfony, Mautic…
#
#   docker build --build-arg PHP_VERSION=8.4 --build-arg INSTALL_REDIS=true -t php-base .
#
# Nginx vhost is rendered AT RUNTIME from a per-platform template, selected
# with the NGINX_PROFILE env var (generic | laravel | drupal | moodle).
# =============================================================================

# ─── Build Arguments ─────────────────────────────────────────────────────────

# Core versions (8.4 covers Laravel 13, Drupal 11 and Moodle 5.1 in one base)
ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.21
ARG COMPOSER_VERSION=2

# ─── Extension toggles ───────────────────────────────────────────────────────
ARG INSTALL_COMPOSER=true
ARG INSTALL_MYSQL=true
ARG INSTALL_POSTGRESQL=true
ARG INSTALL_SQLITE=false
ARG INSTALL_REDIS=false
ARG INSTALL_MEMCACHED=false
ARG INSTALL_APCU=false
ARG INSTALL_IMAGEMAGICK=false
ARG INSTALL_GD=true
ARG INSTALL_LDAP=false
ARG INSTALL_SOAP=false
ARG INSTALL_PSPELL=false
ARG INSTALL_INTL=true
ARG INSTALL_CLAMAV=false
ARG INSTALL_GRAPHVIZ=false
ARG INSTALL_GHOSTSCRIPT=false
ARG INSTALL_XDEBUG=false
ARG INSTALL_PCOV=false
# NOTE: INSTALL_XMLRPC removed — Moodle 4.x+ no longer requires the xmlrpc
# extension and the PECL package is unmaintained (RC quality).

# ─── PHP tuning ──────────────────────────────────────────────────────────────
ARG PHP_MEMORY_LIMIT=512M
ARG PHP_UPLOAD_MAX_FILESIZE=100M
ARG PHP_POST_MAX_SIZE=100M
ARG PHP_MAX_EXECUTION_TIME=300
ARG PHP_MAX_INPUT_VARS=10000
ARG PHP_OPCACHE_MEMORY=256
ARG PHP_OPCACHE_MAX_FILES=20000
ARG PHP_OPCACHE_VALIDATE_TIMESTAMPS=0

# ─── PHP-FPM tuning ─────────────────────────────────────────────────────────
ARG FPM_PM=dynamic
ARG FPM_MAX_CHILDREN=20
ARG FPM_START_SERVERS=3
ARG FPM_MIN_SPARE_SERVERS=2
ARG FPM_MAX_SPARE_SERVERS=5
ARG FPM_MAX_REQUESTS=500
ARG FPM_PROCESS_IDLE_TIMEOUT=10s

# ─── Nginx tuning ───────────────────────────────────────────────────────────
ARG NGINX_WORKER_CONNECTIONS=1024
ARG NGINX_CLIENT_MAX_BODY_SIZE=100M
ARG NGINX_KEEPALIVE_TIMEOUT=65
ARG NGINX_GZIP_COMP_LEVEL=6
ARG NGINX_FASTCGI_READ_TIMEOUT=300

# ─── Application layout ─────────────────────────────────────────────────────
ARG APP_ROOT=/var/www/html
ARG APP_PUBLIC_DIR=public
ARG NGINX_PROFILE=generic

# ─── OS-level ────────────────────────────────────────────────────────────────
ARG TIMEZONE=UTC
ARG USER_ID=1000
ARG GROUP_ID=1000

# =============================================================================
# STAGE 1 — Extension builder
# =============================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS ext-builder

ARG INSTALL_MYSQL INSTALL_POSTGRESQL INSTALL_SQLITE
ARG INSTALL_REDIS INSTALL_MEMCACHED INSTALL_APCU INSTALL_IMAGEMAGICK INSTALL_GD
ARG INSTALL_LDAP INSTALL_SOAP INSTALL_PSPELL INSTALL_INTL
ARG INSTALL_XDEBUG INSTALL_PCOV

RUN set -eux; \
    BUILD_DEPS="$PHPIZE_DEPS linux-headers oniguruma-dev libxml2-dev libzip-dev zlib-dev curl-dev"; \
    PHP_EXTS="mbstring exif pcntl bcmath curl xml zip opcache"; \
    PECL_EXTS=""; \
    \
    if [ "$INSTALL_GD" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS freetype-dev libpng-dev libjpeg-turbo-dev libwebp-dev libavif-dev"; \
        PHP_EXTS="$PHP_EXTS gd"; \
    fi; \
    if [ "$INSTALL_INTL" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS icu-dev"; \
        PHP_EXTS="$PHP_EXTS intl"; \
    fi; \
    if [ "$INSTALL_MYSQL" = "true" ]; then \
        PHP_EXTS="$PHP_EXTS pdo_mysql mysqli"; \
    fi; \
    if [ "$INSTALL_POSTGRESQL" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS postgresql-dev"; \
        PHP_EXTS="$PHP_EXTS pdo_pgsql pgsql"; \
    fi; \
    if [ "$INSTALL_SQLITE" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS sqlite-dev"; \
        PHP_EXTS="$PHP_EXTS pdo_sqlite"; \
    fi; \
    if [ "$INSTALL_LDAP" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS openldap-dev"; \
        PHP_EXTS="$PHP_EXTS ldap"; \
    fi; \
    if [ "$INSTALL_SOAP" = "true" ]; then \
        PHP_EXTS="$PHP_EXTS soap"; \
    fi; \
    if [ "$INSTALL_REDIS" = "true" ]; then \
        PECL_EXTS="$PECL_EXTS redis"; \
    fi; \
    if [ "$INSTALL_APCU" = "true" ]; then \
        PECL_EXTS="$PECL_EXTS apcu"; \
    fi; \
    if [ "$INSTALL_MEMCACHED" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS libmemcached-dev zlib-dev"; \
        PECL_EXTS="$PECL_EXTS memcached"; \
    fi; \
    if [ "$INSTALL_IMAGEMAGICK" = "true" ]; then \
        BUILD_DEPS="$BUILD_DEPS imagemagick-dev"; \
        PECL_EXTS="$PECL_EXTS imagick"; \
    fi; \
    if [ "$INSTALL_XDEBUG" = "true" ]; then \
        PECL_EXTS="$PECL_EXTS xdebug"; \
    fi; \
    if [ "$INSTALL_PCOV" = "true" ]; then \
        PECL_EXTS="$PECL_EXTS pcov"; \
    fi; \
    \
    apk add --no-cache --virtual .build-deps $BUILD_DEPS; \
    \
    if [ "$INSTALL_GD" = "true" ]; then \
        docker-php-ext-configure gd \
            --with-freetype --with-jpeg --with-webp --with-avif; \
    fi; \
    if [ "$INSTALL_LDAP" = "true" ]; then \
        docker-php-ext-configure ldap; \
    fi; \
    \
    docker-php-ext-install -j"$(nproc)" $PHP_EXTS; \
    \
    if [ -n "$PECL_EXTS" ]; then \
        pecl install $PECL_EXTS; \
        ENABLE_LIST=$(echo "$PECL_EXTS" | sed 's/-[0-9][^ ]*//g'); \
        docker-php-ext-enable $ENABLE_LIST; \
    fi; \
    \
    # Xdebug / PCOV: installed but disabled; toggled at runtime via env
    for ext in xdebug pcov; do \
        if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-${ext}.ini" ]; then \
            mv "/usr/local/etc/php/conf.d/docker-php-ext-${ext}.ini" \
               "/usr/local/etc/php/conf.d/docker-php-ext-${ext}.ini.disabled"; \
        fi; \
    done; \
    \
    apk del .build-deps; \
    rm -rf /tmp/pear /usr/src/php

# =============================================================================
# STAGE 2 — Composer (pinned version)
# =============================================================================
FROM composer:${COMPOSER_VERSION} AS composer-bin

# =============================================================================
# STAGE 3 — Production runtime
# =============================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

LABEL maintainer="ops@achelesstech.com" \
      description="Production PHP base image — Nginx + PHP-FPM + Supervisor, Traefik-fronted" \
      org.opencontainers.image.source="https://github.com/achelesstech/php-base-image"

# ── Re-declare every ARG needed in this stage ────────────────────────────────
ARG TIMEZONE APP_ROOT APP_PUBLIC_DIR NGINX_PROFILE USER_ID GROUP_ID
ARG INSTALL_COMPOSER INSTALL_MYSQL INSTALL_POSTGRESQL INSTALL_SQLITE
ARG INSTALL_REDIS INSTALL_MEMCACHED INSTALL_APCU INSTALL_IMAGEMAGICK INSTALL_GD
ARG INSTALL_LDAP INSTALL_SOAP INSTALL_PSPELL INSTALL_INTL
ARG INSTALL_CLAMAV INSTALL_GRAPHVIZ INSTALL_GHOSTSCRIPT
ARG PHP_MEMORY_LIMIT PHP_UPLOAD_MAX_FILESIZE PHP_POST_MAX_SIZE
ARG PHP_MAX_EXECUTION_TIME PHP_MAX_INPUT_VARS
ARG PHP_OPCACHE_MEMORY PHP_OPCACHE_MAX_FILES PHP_OPCACHE_VALIDATE_TIMESTAMPS
ARG FPM_PM FPM_MAX_CHILDREN FPM_START_SERVERS
ARG FPM_MIN_SPARE_SERVERS FPM_MAX_SPARE_SERVERS FPM_MAX_REQUESTS FPM_PROCESS_IDLE_TIMEOUT
ARG NGINX_WORKER_CONNECTIONS NGINX_CLIENT_MAX_BODY_SIZE
ARG NGINX_KEEPALIVE_TIMEOUT NGINX_GZIP_COMP_LEVEL NGINX_FASTCGI_READ_TIMEOUT

# ── Persist key values as runtime env vars ───────────────────────────────────
# Vhost values are ENV (not baked into config) so the entrypoint can render
# the nginx vhost at container start — override any of these at `docker run`.
ENV TZ=${TIMEZONE} \
    APP_ROOT=${APP_ROOT} \
    APP_PUBLIC_DIR=${APP_PUBLIC_DIR} \
    NGINX_PROFILE=${NGINX_PROFILE} \
    NGINX_CLIENT_MAX_BODY_SIZE=${NGINX_CLIENT_MAX_BODY_SIZE} \
    NGINX_FASTCGI_READ_TIMEOUT=${NGINX_FASTCGI_READ_TIMEOUT} \
    PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT} \
    PHP_UPLOAD_MAX_FILESIZE=${PHP_UPLOAD_MAX_FILESIZE} \
    PHP_POST_MAX_SIZE=${PHP_POST_MAX_SIZE} \
    PHP_MAX_EXECUTION_TIME=${PHP_MAX_EXECUTION_TIME} \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=${PHP_OPCACHE_VALIDATE_TIMESTAMPS}

# ── Timezone ─────────────────────────────────────────────────────────────────
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# ── Create app user with matching UID/GID ────────────────────────────────────
RUN deluser www-data 2>/dev/null || true; \
    addgroup -g ${GROUP_ID} -S www-data; \
    adduser -u ${USER_ID} -S -G www-data -s /sbin/nologin www-data

# ── Install runtime packages (single layer, conditional) ────────────────────
RUN set -eux; \
    PKGS="nginx supervisor curl tini tzdata libxml2 libzip oniguruma"; \
    \
    [ "$INSTALL_GD"          = "true" ] && PKGS="$PKGS freetype libpng libjpeg-turbo libwebp libavif" || true; \
    [ "$INSTALL_INTL"        = "true" ] && PKGS="$PKGS icu-libs icu-data-full" || true; \
    [ "$INSTALL_MYSQL"       = "true" ] && PKGS="$PKGS mariadb-client" || true; \
    [ "$INSTALL_POSTGRESQL"  = "true" ] && PKGS="$PKGS postgresql-client" || true; \
    [ "$INSTALL_SQLITE"      = "true" ] && PKGS="$PKGS sqlite" || true; \
    [ "$INSTALL_MEMCACHED"   = "true" ] && PKGS="$PKGS libmemcached-libs" || true; \
    [ "$INSTALL_IMAGEMAGICK" = "true" ] && PKGS="$PKGS imagemagick" || true; \
    [ "$INSTALL_LDAP"        = "true" ] && PKGS="$PKGS libldap" || true; \
    [ "$INSTALL_CLAMAV"      = "true" ] && PKGS="$PKGS clamav clamav-libunrar" || true; \
    [ "$INSTALL_GRAPHVIZ"    = "true" ] && PKGS="$PKGS graphviz" || true; \
    [ "$INSTALL_GHOSTSCRIPT" = "true" ] && PKGS="$PKGS ghostscript" || true; \
    \
    apk add --no-cache $PKGS; \
    \
    mkdir -p \
        ${APP_ROOT} \
        /tmp/nginx-client-body /tmp/nginx-proxy \
        /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi \
        /var/log/nginx /var/log/supervisor /var/cache/nginx \
        /var/lib/nginx/tmp \
        /etc/nginx/conf.d /etc/nginx/templates \
        /etc/supervisor/conf.d \
        /docker-entrypoint.d; \
    \
    # Everything the (non-root) entrypoint must write to at startup:
    chown -R www-data:www-data \
        ${APP_ROOT} /tmp/nginx-* /var/log/nginx /var/log/supervisor \
        /var/cache/nginx /var/lib/nginx \
        /etc/nginx/conf.d /etc/nginx/templates \
        /etc/supervisor/conf.d /docker-entrypoint.d

# ── Copy compiled extensions from builder ────────────────────────────────────
COPY --from=ext-builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=ext-builder /usr/local/etc/php/conf.d/     /usr/local/etc/php/conf.d/

# ── Copy Composer binary (conditionally kept) ────────────────────────────────
COPY --from=composer-bin /usr/bin/composer /usr/bin/composer
RUN [ "$INSTALL_COMPOSER" = "true" ] || rm -f /usr/bin/composer

# ── PHP configuration ────────────────────────────────────────────────────────
RUN cat <<PHPINI > /usr/local/etc/php/conf.d/zz-base-image.ini
; =============================================================================
; PHP Base Image — Runtime configuration
; Values injected at build time; overridable via ENV at runtime
; (see docker-entrypoint.sh → zz-runtime-overrides.ini).
; =============================================================================

; ── Limits ──
memory_limit        = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}
post_max_size       = ${PHP_POST_MAX_SIZE}
max_execution_time  = ${PHP_MAX_EXECUTION_TIME}
max_input_vars      = ${PHP_MAX_INPUT_VARS}
max_input_time      = ${PHP_MAX_EXECUTION_TIME}

; ── Security ──
expose_php              = Off
display_errors          = Off
display_startup_errors  = Off
log_errors              = On
error_log               = /proc/self/fd/2

; ── Sessions ──
; cookie_secure=1 is correct behind Traefik with TLS: the vhost forwards
; X-Forwarded-Proto into the HTTPS fastcgi param so PHP knows the scheme.
; For plain-HTTP local dev, set PHP_SESSION_COOKIE_SECURE=0 at runtime.
session.cookie_httponly  = 1
session.cookie_secure    = 1
session.cookie_samesite  = Lax
session.use_strict_mode  = 1

; ── OPcache ──
opcache.enable                  = 1
opcache.memory_consumption      = ${PHP_OPCACHE_MEMORY}
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files   = ${PHP_OPCACHE_MAX_FILES}
opcache.validate_timestamps     = ${PHP_OPCACHE_VALIDATE_TIMESTAMPS}
opcache.revalidate_freq         = 0
opcache.save_comments           = 1
; enable_file_override left OFF: it breaks apps that probe files before the
; cache is warm (Drupal update.php has a history of issues with it).
opcache.enable_file_override    = 0
opcache.jit_buffer_size         = 128M
opcache.jit                     = 1255

; ── Realpath cache ──
realpath_cache_size = 4096K
realpath_cache_ttl  = 600
PHPINI

# ── Make PHP conf.d writable pieces available to the non-root entrypoint ────
# The entrypoint (running as www-data) writes runtime overrides and toggles
# xdebug/pcov. Pre-create the override file and hand ownership of the toggle
# targets to www-data — without this the container CANNOT START as non-root.
RUN touch /usr/local/etc/php/conf.d/zz-runtime-overrides.ini; \
    chown www-data:www-data \
        /usr/local/etc/php/conf.d \
        /usr/local/etc/php/conf.d/zz-runtime-overrides.ini; \
    chown www-data:www-data /usr/local/etc/php/conf.d/*.disabled 2>/dev/null || true

# ── PHP-FPM pool ─────────────────────────────────────────────────────────────
RUN cat <<FPMCONF > /usr/local/etc/php-fpm.d/www.conf
[global]
error_log = /proc/self/fd/2
log_level = warning

[www]
user  = www-data
group = www-data

; TCP listener (listen.owner/group/mode apply to unix sockets only — removed)
listen = 127.0.0.1:9000

pm                   = ${FPM_PM}
pm.max_children      = ${FPM_MAX_CHILDREN}
pm.start_servers     = ${FPM_START_SERVERS}
pm.min_spare_servers = ${FPM_MIN_SPARE_SERVERS}
pm.max_spare_servers = ${FPM_MAX_SPARE_SERVERS}
pm.max_requests      = ${FPM_MAX_REQUESTS}
pm.process_idle_timeout = ${FPM_PROCESS_IDLE_TIMEOUT}

pm.status_path  = /fpm-status
ping.path       = /fpm-ping
ping.response   = pong

access.log    = /proc/self/fd/1
access.format = "%R - %u %t \"%m %r\" %s %f %{mili}dms %{kilo}MkB %C%%"

clear_env                = no
catch_workers_output     = yes
decorate_workers_output  = no

chdir = ${APP_ROOT}
FPMCONF

# ── Nginx — main config ─────────────────────────────────────────────────────
# Includes an X-Forwarded-Proto → HTTPS fastcgi map so PHP applications see
# the correct scheme when Traefik terminates TLS in front of this container.
RUN cat <<NGINXCONF > /etc/nginx/nginx.conf
# Runs as www-data (non-root)
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid       /tmp/nginx.pid;

events {
    worker_connections ${NGINX_WORKER_CONNECTIONS};
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Temp paths for non-root operation
    client_body_temp_path /tmp/nginx-client-body;
    proxy_temp_path       /tmp/nginx-proxy;
    fastcgi_temp_path     /tmp/nginx-fastcgi;
    uwsgi_temp_path       /tmp/nginx-uwsgi;
    scgi_temp_path        /tmp/nginx-scgi;

    # ── Reverse-proxy awareness (Traefik) ──
    # Tell PHP the original scheme; the vhost passes \$fcgi_https as HTTPS.
    map \$http_x_forwarded_proto \$fcgi_https {
        default "";
        https   "on";
    }

    # Logging
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time';
    access_log /var/log/nginx/access.log main;

    # Performance
    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  ${NGINX_KEEPALIVE_TIMEOUT};
    types_hash_max_size 2048;
    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

    # Buffers
    client_body_buffer_size 16k;
    large_client_header_buffers 4 16k;

    # Gzip
    gzip            on;
    gzip_vary       on;
    gzip_proxied    any;
    gzip_comp_level ${NGINX_GZIP_COMP_LEVEL};
    gzip_min_length 256;
    gzip_types
        text/plain text/css text/xml text/javascript
        application/javascript application/json application/xml+rss
        application/atom+xml image/svg+xml font/woff2;

    # Security headers (defaults; TLS/HSTS headers belong on Traefik)
    add_header X-Frame-Options        "SAMEORIGIN"                      always;
    add_header X-Content-Type-Options "nosniff"                         always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

# ── Nginx vhost templates (per platform, rendered at runtime) ────────────────
# The old build-time vhost had a broken DOCROOT &&/|| chain and could not be
# adapted per platform. Templates live in /etc/nginx/templates and the
# entrypoint renders the one selected by NGINX_PROFILE into conf.d.
COPY rootfs/etc/nginx/templates/ /etc/nginx/templates/

# ── Supervisor ───────────────────────────────────────────────────────────────
# NOTE: no per-program `user=` — supervisord itself already runs as www-data
# and a non-root supervisord cannot setuid (programs would fail to spawn).
RUN cat <<'SUPCONF' > /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon    = true
logfile     = /tmp/supervisord.log
pidfile     = /tmp/supervisord.pid
loglevel    = warn

[unix_http_server]
file  = /tmp/supervisor.sock
chmod = 0700

[supervisorctl]
serverurl = unix:///tmp/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[include]
files = /etc/supervisor/conf.d/programs/*.conf

[program:php-fpm]
command    = php-fpm -F
autostart  = true
autorestart = unexpected
priority   = 5
stdout_logfile          = /dev/stdout
stdout_logfile_maxbytes = 0
stderr_logfile          = /dev/stderr
stderr_logfile_maxbytes = 0

[program:nginx]
command    = nginx -g "daemon off;"
autostart  = true
autorestart = unexpected
priority   = 10
stdout_logfile          = /dev/stdout
stdout_logfile_maxbytes = 0
stderr_logfile          = /dev/stderr
stderr_logfile_maxbytes = 0
SUPCONF

# Extra-programs dir: entrypoint hooks may drop programs here (e.g. Moodle cron)
RUN mkdir -p /etc/supervisor/conf.d/programs && \
    chown -R www-data:www-data /etc/supervisor/conf.d

# ── Entrypoint script ───────────────────────────────────────────────────────
COPY rootfs/usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# ── Final permissions ────────────────────────────────────────────────────────
RUN chown -R www-data:www-data \
        ${APP_ROOT} /var/log/nginx /var/log/supervisor \
        /var/cache/nginx /var/lib/nginx

WORKDIR ${APP_ROOT}
USER www-data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -sf http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
