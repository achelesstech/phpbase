# syntax=docker/dockerfile:1.7
# =============================================================================
# achelesstech/php-base — PHP-FPM + Nginx + Supervisor, non-root, Traefik-fronted
# =============================================================================
# This image is DELIBERATELY BORING. It has no platform identity and no
# feature toggles. Every application (Laravel, Drupal, Moodle, …) gets the
# same fixed payload and adds its own vhost, code and OS packages on top.
#
#   FROM docker.io/achelesstech/php-base:8.4@sha256:...
#
# Boundary rule
#   Compiled PHP extensions  -> here, as the union of what every app needs.
#                               (slow: needs $PHPIZE_DEPS and a compiler)
#   OS packages / binaries   -> the application image. `apk add ghostscript`
#                               takes seconds and needs no compiler, so it
#                               belongs next to the app that needs it.
#
# Nginx here provides the http{} block only. The server{} block is a static
# file owned by the application repo and dropped into /etc/nginx/conf.d/.
#
# Everything numeric is tunable at RUNTIME via env — see README.md.
# =============================================================================

ARG PHP_VERSION=8.4
ARG ALPINE_VERSION=3.21

# =============================================================================
# STAGE 1 — Extension builder (throwaway)
# =============================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS ext-builder

# Already enabled by the upstream php:*-fpm-alpine image and therefore NOT
# rebuilt here: mbstring, curl, xml, dom, simplexml, sodium, openssl, phar,
# fileinfo, session, tokenizer, sqlite3, pdo_sqlite, iconv, posix.
#
# Unpinned apk versions and the unquoted $PHPIZE_DEPS are both intentional —
# see .hadolint.yaml for why those two rules are switched off.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        freetype-dev \
        icu-dev \
        imagemagick-dev \
        libavif-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        linux-headers \
        openldap-dev \
        postgresql-dev; \
    \
    docker-php-ext-configure gd \
        --with-freetype --with-jpeg --with-webp --with-avif; \
    \
    docker-php-ext-install -j"$(nproc)" \
        bcmath \
        exif \
        gd \
        intl \
        ldap \
        mysqli \
        opcache \
        pcntl \
        pdo_mysql \
        pdo_pgsql \
        pgsql \
        soap \
        zip; \
    \
    pecl install apcu redis imagick; \
    docker-php-ext-enable apcu redis imagick; \
    \
    rm -rf /tmp/pear
    # No `apk del` — this stage is discarded; only the .so files are copied out.

# =============================================================================
# STAGE 2 — Runtime
# =============================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

ARG PHP_VERSION
ARG ALPINE_VERSION
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG BASE_VERSION=dev

LABEL org.opencontainers.image.title="achelesstech/php-base" \
      org.opencontainers.image.description="PHP-FPM + Nginx + Supervisor, non-root, reverse-proxy fronted" \
      org.opencontainers.image.source="https://github.com/achelesstech/php-base" \
      org.opencontainers.image.vendor="achelesstech" \
      tech.acheless.php-base.version="${BASE_VERSION}" \
      tech.acheless.php-base.php="${PHP_VERSION}" \
      tech.acheless.php-base.alpine="${ALPINE_VERSION}"

# ── Environment ──────────────────────────────────────────────────────────────
# PHP_INI_SCAN_DIR adds a SECOND, writable directory for entrypoint-rendered
# overrides. /usr/local/etc/php/conf.d itself stays root-owned so a compromised
# PHP worker cannot persist an auto_prepend_file across restarts.
ENV TZ=UTC \
    PHP_INI_SCAN_DIR="/usr/local/etc/php/conf.d:/etc/php-runtime.d" \
    COMPOSER_HOME=/tmp/composer \
    COMPOSER_ALLOW_SUPERUSER=0 \
    APP_ROOT=/var/www/html

# ── Application user ─────────────────────────────────────────────────────────
# `deluser` (busybox) removes the user but NOT the group, so the stock gid 82
# group survives and `addgroup -g 1000` fails. Without `set -e` that failure is
# swallowed and you silently get uid 1000 / gid 82. Delete both, then verify.
RUN set -eux; \
    deluser  www-data 2>/dev/null || true; \
    delgroup www-data 2>/dev/null || true; \
    addgroup -g "${GROUP_ID}" -S www-data; \
    adduser  -u "${USER_ID}" -S -D -H -G www-data -s /sbin/nologin www-data; \
    [ "$(id -u www-data)" = "${USER_ID}" ]; \
    [ "$(id -g www-data)" = "${GROUP_ID}" ]

# ── Runtime packages ─────────────────────────────────────────────────────────
# Runtime shared libraries for the extensions compiled in stage 1, plus the
# three daemons. Database CLI clients are deliberately NOT here — see the
# boundary rule at the top of this file.
RUN set -eux; \
    apk add --no-cache \
        curl \
        freetype \
        icu-data-full \
        icu-libs \
        imagemagick \
        libavif \
        libjpeg-turbo \
        libldap \
        libpng \
        libpq \
        libwebp \
        libzip \
        nginx \
        supervisor \
        tini \
        tzdata

# ── Directories the non-root entrypoint and daemons must write to ────────────
RUN set -eux; \
    rm -f /usr/local/etc/php-fpm.d/*; \
    mkdir -p \
        "${APP_ROOT}" \
        /docker-entrypoint.d \
        /etc/nginx/conf.d \
        /etc/php-runtime.d \
        /etc/supervisor/conf.d \
        /var/lib/nginx/tmp \
        /var/tmp/run \
        /var/tmp/nginx/client-body \
        /var/tmp/nginx/fastcgi \
        /var/tmp/nginx/proxy \
        /var/tmp/nginx/scgi \
        /var/tmp/nginx/uwsgi; \
    chown -R www-data:www-data \
        "${APP_ROOT}" \
        /docker-entrypoint.d \
        /etc/nginx/conf.d \
        /etc/php-runtime.d \
        /etc/supervisor/conf.d \
        /var/lib/nginx \
        /var/tmp/nginx \
        /var/tmp/run; \
    # nginx's compiled-in default error log is /var/lib/nginx/logs/error.log,
    # a symlink to /var/log/nginx owned by the apk package's `nginx` uid. It is
    # opened BEFORE the config is parsed, so without this every start logs
    # "could not open error log file".
    chown -R www-data:www-data /var/log/nginx

# ── Compiled extensions from stage 1 ─────────────────────────────────────────
COPY --from=ext-builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=ext-builder /usr/local/etc/php/conf.d/     /usr/local/etc/php/conf.d/

# ── Composer ─────────────────────────────────────────────────────────────────
# Needed at BUILD time by every app repo (and by Moodle 5.1+, which no longer
# ships a complete vendor/ tree). Pin by digest in production.
COPY --from=composer:2.8 /usr/bin/composer /usr/local/bin/composer

# ── Configuration (real files — never heredocs) ──────────────────────────────
# Copied AFTER the stage-1 conf.d so zz-base.ini is not clobbered.
COPY rootfs/ /

# ── Pre-create the single FPM drop-in the entrypoint rewrites at start ───────
# Only this one file is www-data-writable; /usr/local/etc/php-fpm.d is not.
RUN set -eux; \
    chmod +x /usr/local/bin/docker-entrypoint.sh \
             /usr/local/bin/healthcheck.sh \
             /usr/local/bin/nginx-validate.sh \
             /usr/local/bin/supervisor-fatal-listener.sh; \
    touch /usr/local/etc/php-fpm.d/zz-runtime.conf; \
    chown www-data:www-data /usr/local/etc/php-fpm.d/zz-runtime.conf; \
    echo "php-base ${BASE_VERSION} (php ${PHP_VERSION}, alpine ${ALPINE_VERSION})" \
        > /etc/php-base-release; \
    php --version; \
    php -m; \
    php-fpm --test; \
    nginx-validate.sh

WORKDIR ${APP_ROOT}
USER www-data

EXPOSE 8080

# /fpm-ping proves PHP-FPM is alive. A static nginx /healthz stays green while
# FPM is dead, which is how a container reports healthy and 502s every request.
# Application vhosts MUST define the /fpm-ping location (see apps/*/docker/vhost.conf).
# Kept on one line: hadolint anchors an inline ignore to the instruction's first
# line, so a wrapped HEALTHCHECK cannot be exempted from DL3025 (which wants JSON
# notation; shell form is the conventional spelling for HEALTHCHECK CMD).
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD healthcheck.sh

ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
