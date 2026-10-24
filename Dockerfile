# syntax=docker/dockerfile:1.7
# =============================================================================
# achelesstech/php-base — PHP-FPM + nginx + supervisor, non-root, proxy-fronted
# =============================================================================
# One image per PHP line (8.2, 8.3, 8.4, 8.5), rebuilt weekly from the newest
# upstream patch release on the newest Alpine the official PHP image supports.
#
#   FROM docker.io/achelesstech/php-base:8.4@sha256:…       production
#   FROM docker.io/achelesstech/php-base:8.4-dev@sha256:…   + Xdebug, PCOV, git
#
# Fits Laravel, Drupal, Moodle and WordPress with nothing compiled in the app:
#   * the union of their PHP extensions is built in (ext-builder below)
#   * an nginx preset per framework:      /etc/nginx/presets/*.conf
#   * the periodic job each one needs:    php-base-every / SCHEDULER_COMMAND
#
# Boundary rule (unchanged): compiled PHP extensions belong here; plain OS
# packages (ghostscript, database clients, nodejs) belong in the app image.
#
# Runtime contract: the container writes only under /tmp — rendered config in
# /tmp/php-base is wiped and re-rendered at every start — so `read_only: true`
# with `tmpfs: [/tmp]` works, and nothing a compromised PHP process writes
# into configuration survives a restart.
# =============================================================================

ARG PHP_VERSION=8.4
# CI passes an exact digest (scripts/resolve-matrix.sh):
#   php:8.4-fpm-alpine@sha256:…
# The FLOATING -alpine tag is deliberate: it follows docker-library to each new
# Alpine release. A hand-pinned alpine3.21 is how this image sat on PHP 8.4.15
# for eleven months — that tag stopped receiving PHP releases in Nov 2025.
ARG PHP_IMAGE=php:${PHP_VERSION}-fpm-alpine
ARG COMPOSER_IMAGE=composer/composer:2-bin

FROM ${COMPOSER_IMAGE} AS composer

# =============================================================================
# ext-builder — compiles extensions; discarded, only the .so files ship
# =============================================================================
FROM ${PHP_IMAGE} AS ext-builder

# PECL versions are pinned and bumped by Renovate PRs (renovate.json), so a new
# extension release is proven on every PHP line before it ships to any of them.
# renovate: datasource=github-tags depName=krakjoe/apcu extractVersion=^v(?<version>.+)$
ARG APCU_VERSION=5.1.28
# 3.2.17RC1: named RC but published as STABLE on PECL (Nov 2025), and the only
# release that compiles on PHP 8.5 (3.2.16 includes the removed
# ext/standard/php_smart_string.h). Supports PHP 7.0-8.5.
# renovate: datasource=github-tags depName=igbinary/igbinary
ARG IGBINARY_VERSION=3.2.17RC1
# renovate: datasource=github-tags depName=Imagick/imagick
ARG IMAGICK_VERSION=3.8.1
# renovate: datasource=github-tags depName=php-memcached-dev/php-memcached extractVersion=^v(?<version>.+)$
ARG MEMCACHED_VERSION=3.4.0
# renovate: datasource=github-tags depName=phpredis/phpredis
ARG REDIS_VERSION=6.3.0
# renovate: datasource=github-tags depName=php/pecl-php-uploadprogress extractVersion=^uploadprogress-(?<version>.+)$
ARG UPLOADPROGRESS_VERSION=2.0.2

# Already built into the official image and NOT rebuilt here: ctype, curl,
# dom, fileinfo, iconv (GNU libiconv, so //TRANSLIT works), mbstring, opcache,
# openssl, pdo_sqlite, phar, posix, session, simplexml, sodium, sqlite3,
# tokenizer, xml*, zlib — and argon2 password hashing (Drupal 12 needs it).
#
# PECL extensions are NOT installed with `pecl install`: the official PHP 8.6
# image no longer ships pecl/PEAR at all (PECL is deprecated in favour of
# PIE). Instead each release tarball is unpacked into the PHP source tree and
# built with docker-php-ext-install — one code path for 8.2 through 8.6, with
# plain ./configure flags that fail the build if misspelled
# (docker-php-ext-configure runs configure with --enable-option-checking=fatal).
#
# The virtual package is named .phpize-deps on purpose: docker-php-ext-configure
# sees it and does not install and purge $PHPIZE_DEPS again for every extension.
# Unpinned apk versions and the unquoted $PHPIZE_DEPS are intentional — see
# .hadolint.yaml.
RUN set -eux -o pipefail; \
    apk add --no-cache --virtual .phpize-deps \
        $PHPIZE_DEPS \
        cyrus-sasl-dev \
        freetype-dev \
        gmp-dev \
        icu-dev \
        imagemagick-dev \
        libavif-dev \
        libjpeg-turbo-dev \
        libmemcached-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        linux-headers \
        lz4-dev \
        openldap-dev \
        postgresql-dev \
        zlib-dev \
        zstd-dev; \
    \
    docker-php-source extract; \
    for spec in \
        "igbinary:${IGBINARY_VERSION}" \
        "apcu:${APCU_VERSION}" \
        "imagick:${IMAGICK_VERSION}" \
        "uploadprogress:${UPLOADPROGRESS_VERSION}" \
        "redis:${REDIS_VERSION}" \
        "memcached:${MEMCACHED_VERSION}"; \
    do \
        name="${spec%%:*}"; \
        mkdir -p "/usr/src/php/ext/${name}"; \
        curl -fsSL "https://pecl.php.net/get/${name}-${spec#*:}.tgz" \
            | tar -xz -C "/usr/src/php/ext/${name}" --strip-components=1; \
    done; \
    \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif; \
    docker-php-ext-configure igbinary --enable-igbinary; \
    docker-php-ext-configure apcu --enable-apcu; \
    docker-php-ext-configure imagick --with-imagick; \
    docker-php-ext-configure uploadprogress --enable-uploadprogress; \
    # No `opcache`: the official images ship it prebuilt and enabled, and from
    # PHP 8.5 it is part of PHP itself — `docker-php-ext-install opcache`
    # fails there ("cp: can't stat 'modules/*'").
    docker-php-ext-install -j"$(nproc)" \
        bcmath \
        exif \
        gd \
        gmp \
        intl \
        ldap \
        mysqli \
        pcntl \
        pdo_mysql \
        pdo_pgsql \
        pgsql \
        soap \
        sockets \
        zip \
        igbinary \
        apcu \
        imagick \
        uploadprogress; \
    \
    # Second pass: redis and memcached compile against igbinary's headers,
    # which the first pass installed.
    docker-php-ext-configure redis \
        --enable-redis --enable-redis-igbinary \
        --enable-redis-zstd --with-libzstd \
        --enable-redis-lz4 --with-liblz4; \
    docker-php-ext-configure memcached \
        --enable-memcached --enable-memcached-igbinary --enable-memcached-json \
        --enable-memcached-session --enable-memcached-sasl --disable-memcached-protocol; \
    docker-php-ext-install -j"$(nproc)" redis memcached; \
    \
    php -m

# =============================================================================
# ext-builder-dev — debugger and coverage driver, for the :X.Y-dev image only
# =============================================================================
FROM ext-builder AS ext-builder-dev

# renovate: datasource=github-tags depName=xdebug/xdebug
ARG XDEBUG_VERSION=3.5.3
# renovate: datasource=github-tags depName=krakjoe/pcov extractVersion=^v(?<version>.+)$
ARG PCOV_VERSION=1.0.12
# 1 for prerelease PHP lines: Xdebug's configure enforces a maximum PHP
# version and refuses to build on a release candidate until it supports it.
ARG ALLOW_MISSING_DEV_EXTENSIONS=0

RUN set -eux -o pipefail; \
    for spec in "xdebug:${XDEBUG_VERSION}" "pcov:${PCOV_VERSION}"; do \
        name="${spec%%:*}"; \
        mkdir -p "/usr/src/php/ext/${name}"; \
        curl -fsSL "https://pecl.php.net/get/${name}-${spec#*:}.tgz" \
            | tar -xz -C "/usr/src/php/ext/${name}" --strip-components=1; \
        if ! docker-php-ext-install -j"$(nproc)" "${name}"; then \
            [ "$ALLOW_MISSING_DEV_EXTENSIONS" = 1 ] || exit 1; \
            echo "WARNING: ${name} ${spec#*:} does not build on PHP ${PHP_VERSION}; left out of this dev image"; \
        fi; \
    done

# =============================================================================
# runtime — published as :X.Y
# =============================================================================
FROM ${PHP_IMAGE} AS runtime

ARG PHP_VERSION
ARG USER_ID=1000
ARG GROUP_ID=1000
# CI sets this to the build date. It is echoed by the package RUN below, so
# that layer is rebuilt every week instead of being served from the build
# cache — a cached `apk add` would ship last month's nginx and openssl forever.
ARG PKG_CACHE_BUST=0

# ── Environment ──────────────────────────────────────────────────────────────
# /tmp/php-base/php is the LAST scan dir, so env-rendered overrides win over
# conf.d/zz-base.ini. /usr/local/etc/php/conf.d itself stays root-owned.
ENV TZ=UTC \
    APP_ROOT=/var/www/html \
    PHP_INI_SCAN_DIR="/usr/local/etc/php/conf.d:/tmp/php-base/php" \
    COMPOSER_HOME=/tmp/composer \
    COMPOSER_ALLOW_SUPERUSER=0

# ── Application user ─────────────────────────────────────────────────────────
# Upstream's www-data is 82:82. busybox `deluser` removes the user but neither
# the group (so `addgroup -g 1000` would fail) nor the home directory — which
# stays behind owned by the deleted uid 82. Every tool that writes to $HOME
# (npm, git, composer without COMPOSER_HOME) then fails with EACCES: the real
# cause of the npm_config_cache workaround in both Laravel apps.
#
# /home/www-data is a symlink to /tmp/php-base/home, a 0750 directory the
# entrypoint creates at every start. The root filesystem is meant to run
# read-only and the image writes only under /tmp, so a real directory here
# could never be written. $HOME and the passwd entry stay /home/www-data.
# When the entrypoint is bypassed (--entrypoint sh), $HOME dangles until
# something creates /tmp/php-base/home.
RUN set -eux; \
    deluser  www-data 2>/dev/null || true; \
    delgroup www-data 2>/dev/null || true; \
    rm -rf /home/www-data; \
    addgroup -g "${GROUP_ID}" -S www-data; \
    adduser  -u "${USER_ID}" -S -D -H -h /home/www-data -G www-data -s /sbin/nologin www-data; \
    ln -s /tmp/php-base/home /home/www-data; \
    # Upstream also leaves APP_ROOT world-writable (1777) and owned by uid 82.
    chown www-data:www-data "${APP_ROOT}"; \
    chmod 0755 "${APP_ROOT}"; \
    [ "$(id -u www-data)" = "${USER_ID}" ]; \
    [ "$(id -g www-data)" = "${GROUP_ID}" ]

# ── OS packages ──────────────────────────────────────────────────────────────
# `apk upgrade` first: docker-library rebuilds the PHP image when PHP or
# Alpine releases, not when openssl, curl or libxml2 get a CVE fix in between.
# This is how those fixes arrive within a week. Safe within a stable branch.
#
# ImageMagick's coders are separate Alpine packages: without them Imagick
# cannot read JPEG/WebP, and WordPress (6.7+ converts iPhone HEIC uploads)
# silently falls back to GD.
RUN set -eux; \
    echo "package refresh: ${PKG_CACHE_BUST}"; \
    apk upgrade --no-cache; \
    apk add --no-cache \
        curl \
        icu-data-full \
        imagemagick \
        imagemagick-heic \
        imagemagick-jpeg \
        imagemagick-webp \
        nginx \
        supervisor \
        tini \
        tzdata \
        unzip

# ── Compiled extensions ──────────────────────────────────────────────────────
COPY --from=ext-builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=ext-builder /usr/local/etc/php/conf.d/     /usr/local/etc/php/conf.d/

# Shared libraries the extensions link against — computed, not hand-listed, so
# adding an extension can never ship without its library (the classic "Unable
# to load dynamic library" on first boot).
RUN set -eux -o pipefail; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive "$(php-config --extension-dir)" \
            | tr ',' '\n' | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .php-ext-rundeps $runDeps; \
    # Fail the build on any load warning instead of shipping it. (Captured, not
    # `! php -m | grep`: `set -e` ignores a failing pipeline that starts with `!`.)
    mods="$(php -m 2>&1)"; \
    case "$mods" in *[Ww]arning*|*"nable to load"*) echo "$mods"; exit 1 ;; esac

COPY --from=composer /composer /usr/local/bin/composer

# ── Configuration (real files, never heredocs) ───────────────────────────────
COPY rootfs/ /

# ── Build metadata ───────────────────────────────────────────────────────────
# Declared this late on purpose: an ARG invalidates the cache of every RUN
# after it, and BUILD_DATE changes on every build.
ARG BASE_VERSION=local
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG SOURCE_URL=https://github.com/achelesstech/phpbase
ARG BASE_NAME=unknown
ARG BASE_DIGEST=unknown

LABEL org.opencontainers.image.title="achelesstech/php-base" \
      org.opencontainers.image.description="PHP-FPM + nginx + supervisor, non-root, for Laravel, Drupal, Moodle and WordPress" \
      org.opencontainers.image.url="https://hub.docker.com/r/achelesstech/php-base" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="achelesstech" \
      org.opencontainers.image.version="${BASE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="${BASE_NAME}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      tech.acheless.php-base.php-line="${PHP_VERSION}" \
      tech.acheless.php-base.variant="runtime"

# ── Ownership and modes, set explicitly ──────────────────────────────────────
# COPY keeps the build machine's file modes (0664/0775 on a umask-002 host),
# so the same commit used to build into different images on different hosts.
# Config, presets and hook directories are ROOT-owned: www-data reads them and
# never writes them. At runtime it writes /tmp (incl. /tmp/php-base) and
# whatever volumes the app mounts — nothing else.
RUN set -eux; \
    rm -f /usr/local/etc/php-fpm.d/docker.conf /usr/local/etc/php-fpm.d/zz-docker.conf \
          /usr/local/etc/php-fpm.d/www.conf.default; \
    mkdir -p /docker-entrypoint.d /etc/nginx/conf.d /etc/nginx/server.d /etc/php-base; \
    for d in /etc/nginx /etc/supervisor /etc/php-base /usr/local/etc/php /usr/local/etc/php-fpm.d /docker-entrypoint.d; do \
        chown -R root:root "$d"; \
        find "$d" -type d -exec chmod 0755 {} +; \
        find "$d" -type f -exec chmod 0644 {} +; \
    done; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh \
               /usr/local/bin/nginx-validate.sh /usr/local/bin/php-base-validate \
               /usr/local/bin/supervisor-fatal-listener.sh /usr/local/bin/php-base-every \
               /usr/local/bin/php-base-info /usr/local/bin/composer; \
    # nginx opens its compiled-in prefix/log paths before reading the config
    # when run without `-e` (e.g. an operator's `nginx -s reload`).
    chown -R www-data:www-data /var/lib/nginx /var/log/nginx; \
    rm -f /etc/nginx/http.d/default.conf; \
    { \
        echo "BASE_VERSION=${BASE_VERSION}"; \
        echo "VARIANT=runtime"; \
        echo "BUILD_DATE=${BUILD_DATE}"; \
        echo "VCS_REF=${VCS_REF}"; \
        echo "BASE_NAME=${BASE_NAME}"; \
        echo "BASE_DIGEST=${BASE_DIGEST}"; \
    } > /etc/php-base/release; \
    # Nothing may still belong to the upstream uid/gid 82.
    orphans="$(find / -xdev \( -user 82 -o -group 82 \) -print)"; \
    [ -z "$orphans" ] || { echo "owned by uid/gid 82: $orphans"; exit 1; }; \
    php -v; \
    php-base-validate; \
    composer --version

WORKDIR ${APP_ROOT}
USER www-data

EXPOSE 8080

# Role-aware (see healthcheck.sh): /fpm-ping through FastCGI for the web role,
# heartbeat for php-base-every containers, nothing for other commands.
# Kept on one line: hadolint anchors an inline ignore to the instruction's
# first line, so a wrapped HEALTHCHECK cannot be exempted from DL3025.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD healthcheck.sh

STOPSIGNAL SIGTERM
ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]

# =============================================================================
# dev — published as :X.Y-dev
# =============================================================================
# Replaces every app's "build Xdebug in the dev stage" step (which is what
# broke when pecl.php.net had an outage): the base CI builds it once a week.
FROM runtime AS dev

USER root

COPY --from=ext-builder-dev /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY rootfs-dev/ /

RUN set -eux; \
    apk add --no-cache git openssh-client patch; \
    ext_dir="$(php-config --extension-dir)"; \
    if [ -f "${ext_dir}/xdebug.so" ]; then docker-php-ext-enable xdebug; fi; \
    if [ -f "${ext_dir}/pcov.so" ];   then docker-php-ext-enable pcov;   fi; \
    chown -R root:root /usr/local/etc/php/conf.d; \
    chmod 0644 /usr/local/etc/php/conf.d/*.ini; \
    sed -i 's/^VARIANT=.*/VARIANT=dev/' /etc/php-base/release; \
    mods="$(php -m 2>&1)"; \
    case "$mods" in *[Ww]arning*|*"nable to load"*) echo "$mods"; exit 1 ;; esac; \
    php -v

LABEL tech.acheless.php-base.variant="dev"

USER www-data
