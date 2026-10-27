# syntax=docker/dockerfile:1.7
# =============================================================================
# achelesstech/php-base — PHP-FPM + nginx under s6, non-root, proxy-fronted
# =============================================================================
# One image per PHP line (8.2, 8.3, 8.4, 8.5), rebuilt weekly (and whenever
# the upstream watcher sees a new PHP image, Alpine image or package update)
# from the newest upstream patch release on the newest Alpine the official PHP
# image supports.
#
#   FROM docker.io/achelesstech/php-base:8.4@sha256:…       production
#   FROM docker.io/achelesstech/php-base:8.4-dev@sha256:…   + Composer, Xdebug,
#                                                            PCOV, git, phpize
#
# Fits Laravel, Drupal, Moodle and WordPress with nothing compiled in the app:
#   * the union of their PHP extensions is built in (ext-builder below)
#   * an nginx preset per framework:      /etc/nginx/presets/*.conf
#   * the periodic job each one needs:    php-base-every / SCHEDULER_COMMAND
#
# Stages:
#   php-upstream     the official php:X.Y-fpm-alpine, pinned by digest
#   ext-builder      compiles the extensions, stages the runtime file set (/out)
#   ext-builder-dev  Xdebug and PCOV
#   runtime          a CLEAN alpine:<same minor> + /out + the libraries it links
#   dev              runtime + PHP sources, headers, phpize, docker-php-*,
#                    PEAR/PECL, Composer, git — everything that builds things
#
# Boundary rule (unchanged): compiled PHP extensions belong here; plain OS
# packages (ghostscript, database clients, nodejs) belong in the app image.
#
# Runtime contract: the container writes only under /tmp — rendered config in
# /tmp/php-base is wiped and re-rendered at every start — so `read_only: true`
# with `tmpfs: [/tmp]` works, and nothing a compromised PHP process writes
# into configuration survives a restart.
# =============================================================================

# The line. Used for the defaults below and checked against the PHP the
# runtime actually contains.
ARG PHP_VERSION=8.4
# CI and `make build` pass exact digests (scripts/build-args.sh):
#   PHP_IMAGE=php:8.4-fpm-alpine@sha256:…
#   ALPINE_IMAGE=alpine:3.24@sha256:…   the minor in the PHP image's /etc/alpine-release
#   COMPOSER_IMAGE=composer/composer:2-bin@sha256:…
# The FLOATING -alpine tag is deliberate: it follows docker-library to each new
# Alpine release. A hand-pinned alpine3.21 is how this image sat on PHP 8.4.15
# for eleven months — that tag stopped receiving PHP releases in Nov 2025.
# The defaults are for ad-hoc builds only; the runtime stage refuses an Alpine
# minor that differs from the PHP image's.
ARG PHP_IMAGE=php:${PHP_VERSION}-fpm-alpine
ARG ALPINE_IMAGE=alpine:3.24
ARG COMPOSER_IMAGE=composer/composer:2-bin

FROM ${COMPOSER_IMAGE} AS composer

# =============================================================================
# php-upstream — the source of PHP itself and of the build toolchain
# =============================================================================
FROM ${PHP_IMAGE} AS php-upstream

# =============================================================================
# ext-builder — compiles extensions; discarded, only /out ships
# =============================================================================
FROM php-upstream AS ext-builder

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
#
# Each tarball is saved to a file before it is unpacked, so curl can retry a
# dropped transfer from the start; into a pipe it cannot.
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
        curl -fsSL --retry 5 --retry-all-errors -o "/tmp/${name}.tgz" \
            "https://pecl.php.net/get/${name}-${spec#*:}.tgz"; \
        tar -xzf "/tmp/${name}.tgz" -C "/usr/src/php/ext/${name}" --strip-components=1; \
        rm "/tmp/${name}.tgz"; \
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

# Stage the runtime file set — an allowlist, so nothing new upstream adds
# (a tool, a header, a PEAR package) reaches production unnoticed:
#   bin/php, sbin/php-fpm, etc/php-fpm.conf, every built extension, and the
#   docker-*.ini files that load them (plus upstream's docker-fpm.ini, which
#   sets fastcgi.logging=Off, so PHP errors are not sent to nginx a second time).
# Our zz-base.ini and php-fpm.d/www.conf come from rootfs/.
#
# The `so:` libraries those files link are worked out here, where scanelf is
# installed, and written to /php-rundeps for the runtime stage to apk add.
# That includes GNU libiconv, which upstream links, so //TRANSLIT keeps working.
RUN set -eux -o pipefail; \
    mkdir -p /out/usr/local/bin /out/usr/local/sbin /out/usr/local/etc/php/conf.d /out/usr/local/lib/php; \
    cp -a /usr/local/bin/php       /out/usr/local/bin/; \
    cp -a /usr/local/sbin/php-fpm  /out/usr/local/sbin/; \
    cp -a /usr/local/etc/php-fpm.conf /out/usr/local/etc/; \
    cp -a /usr/local/etc/php/conf.d/docker-*.ini /out/usr/local/etc/php/conf.d/; \
    cp -a /usr/local/lib/php/extensions /out/usr/local/lib/php/; \
    scanelf --needed --nobanner --format '%n#p' --recursive /out/usr/local \
        | tr ',' '\n' | sort -u \
        | awk 'system("[ -e /out/usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
        > /php-rundeps; \
    cat /php-rundeps; \
    [ -s /php-rundeps ]

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
        curl -fsSL --retry 5 --retry-all-errors -o "/tmp/${name}.tgz" \
            "https://pecl.php.net/get/${name}-${spec#*:}.tgz"; \
        tar -xzf "/tmp/${name}.tgz" -C "/usr/src/php/ext/${name}" --strip-components=1; \
        rm "/tmp/${name}.tgz"; \
        if ! docker-php-ext-install -j"$(nproc)" "${name}"; then \
            [ "$ALLOW_MISSING_DEV_EXTENSIONS" = 1 ] || exit 1; \
            echo "WARNING: ${name} ${spec#*:} does not build on PHP ${PHP_VERSION}; left out of this dev image"; \
        fi; \
    done

# =============================================================================
# runtime — published as :X.Y
# =============================================================================
# A clean Alpine of the same minor the PHP image was built on, PHP's runtime
# file set from ext-builder, and the libraries it links. No compiler inputs,
# no PHP sources, no PEAR, no Composer: those are in -dev.
FROM ${ALPINE_IMAGE} AS runtime

ARG USER_ID=1000
ARG GROUP_ID=1000
# CI sets this to a per-run value (date + run id; local builds use the date).
# It is echoed by the package RUN below, so that layer is rebuilt on every CI
# run instead of being served from the build cache — a cached `apk add` would
# ship last month's nginx and openssl forever, and a same-day watcher rebuild
# for a package fix would republish identical bytes.
ARG PKG_CACHE_BUST=0

# ── Environment ──────────────────────────────────────────────────────────────
# /tmp/php-base/php is the LAST scan dir, so env-rendered overrides win over
# conf.d/zz-base.ini. /usr/local/etc/php/conf.d itself stays root-owned.
ENV TZ=UTC \
    APP_ROOT=/var/www/html \
    PHP_INI_SCAN_DIR="/usr/local/etc/php/conf.d:/tmp/php-base/php"

# ── OS packages ──────────────────────────────────────────────────────────────
# `apk upgrade` first: the Alpine image is rebuilt on Alpine point releases,
# not when openssl, curl or libxml2 get a CVE fix in between. This is how
# those fixes arrive within a week. Safe within a stable branch.
#
# ImageMagick's coders are separate Alpine packages: without them Imagick
# cannot read JPEG/WebP, and WordPress (6.7+ converts iPhone HEIC uploads)
# silently falls back to GD.
RUN set -eux; \
    echo "package refresh: ${PKG_CACHE_BUST}"; \
    apk upgrade --no-cache; \
    apk add --no-cache \
        ca-certificates \
        curl \
        icu-data-full \
        imagemagick \
        imagemagick-heic \
        imagemagick-jpeg \
        imagemagick-webp \
        nginx \
        s6 \
        tini \
        tzdata

# ── PHP: binaries, extensions, and the libraries they link ───────────────────
COPY --from=ext-builder /out/ /

# The list is computed in ext-builder, not hand-written, so adding an
# extension can never ship without its library (the classic "Unable to load
# dynamic library" on first boot). Bind-mounted, so it leaves no file behind.
RUN --mount=type=bind,from=ext-builder,source=/php-rundeps,target=/tmp/php-rundeps \
    set -eux; \
    runDeps="$(cat /tmp/php-rundeps)"; \
    apk add --no-cache --virtual .php-rundeps $runDeps

# ── Application user ─────────────────────────────────────────────────────────
# Alpine's www-data group is gid 82 (the official PHP image adds uid 82 too).
# busybox `deluser` removes the user but neither the group (so
# `addgroup -g 1000` would fail) nor the home directory. A home left behind
# owned by uid 82 is what made every tool that writes to $HOME (npm, git,
# composer without COMPOSER_HOME) fail with EACCES in the v1 apps.
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
    # nginx's default docroot, owned by the old gid 82 and never served here.
    rm -rf /var/www/localhost; \
    mkdir -p "${APP_ROOT}"; \
    chown www-data:www-data "${APP_ROOT}"; \
    chmod 0755 "${APP_ROOT}"; \
    [ "$(id -u www-data)" = "${USER_ID}" ]; \
    [ "$(id -g www-data)" = "${GROUP_ID}" ]

# ── Configuration (real files, never heredocs) ───────────────────────────────
COPY rootfs/ /

# ── Build metadata ───────────────────────────────────────────────────────────
# Declared this late on purpose: an ARG invalidates the cache of every RUN
# after it, and BUILD_DATE changes on every build. All of them come from the
# resolver (scripts/build-args.sh locally, the workflow in CI).
ARG PHP_VERSION
ARG PHP_FULL_VERSION=unknown
ARG ALPINE_FULL_VERSION=unknown
ARG UPSTREAM_IMAGE=unknown
ARG UPSTREAM_DIGEST=unknown
ARG BASE_VERSION=local
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG SOURCE_URL=https://github.com/achelesstech/phpbase
ARG BASE_NAME=unknown
ARG BASE_DIGEST=unknown

# base.* name the Alpine image this stage is built on; upstream-* name the PHP
# image the binaries came from. scripts/check-upstream.sh compares both
# digests (index digests) with what the registry serves now.
LABEL org.opencontainers.image.title="achelesstech/php-base" \
      org.opencontainers.image.description="PHP-FPM + nginx under s6, non-root, for Laravel, Drupal, Moodle and WordPress" \
      org.opencontainers.image.url="https://hub.docker.com/r/achelesstech/php-base" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="achelesstech" \
      org.opencontainers.image.version="${BASE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="${BASE_NAME}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}" \
      io.github.achelesstech.php-base.upstream-image="${UPSTREAM_IMAGE}" \
      io.github.achelesstech.php-base.upstream-digest="${UPSTREAM_DIGEST}" \
      io.github.achelesstech.php-base.php-version="${PHP_FULL_VERSION}" \
      io.github.achelesstech.php-base.alpine-version="${ALPINE_FULL_VERSION}" \
      io.github.achelesstech.php-base.variant="runtime"

# ── Ownership, modes, release file, self-checks ──────────────────────────────
# COPY keeps the build machine's file modes (0664/0775 on a umask-002 host),
# so the same commit used to build into different images on different hosts.
# Config, presets, s6 service definitions and hook directories are ROOT-owned:
# www-data reads them and never writes them. At runtime it writes /tmp (incl.
# /tmp/php-base) and whatever volumes the app mounts — nothing else. `chown -h`
# because the s6 definitions' supervise/ and event/ are symlinks into
# /tmp/php-base, which does not exist at build time.
#
# Then the build fails unless the image is what it claims to be. (Captured
# output, never `! pipeline`: `set -e` ignores a failing pipeline after `!`.)
RUN --mount=type=bind,from=php-upstream,source=/etc/alpine-release,target=/tmp/upstream-alpine-release \
    set -eux; \
    mkdir -p /docker-entrypoint.d /etc/nginx/conf.d /etc/nginx/server.d /etc/php-base /usr/local/etc/php-fpm.d; \
    for d in /etc/nginx /etc/php-base /etc/ImageMagick-7 /usr/local/etc/php /usr/local/etc/php-fpm.d /docker-entrypoint.d; do \
        chown -Rh root:root "$d"; \
        find "$d" -type d -exec chmod 0755 {} +; \
        find "$d" -type f -exec chmod 0644 {} +; \
    done; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh \
               /usr/local/bin/nginx-validate.sh /usr/local/bin/php-base-validate \
               /usr/local/bin/php-base-web /usr/local/bin/php-base-every \
               /usr/local/bin/php-base-info \
               /etc/php-base/s6/.s6-svscan/SIGTERM /etc/php-base/s6/.s6-svscan/finish \
               /etc/php-base/s6/fail-fast /etc/php-base/s6/*/run; \
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
        echo "UPSTREAM_IMAGE=${UPSTREAM_IMAGE}"; \
        echo "UPSTREAM_DIGEST=${UPSTREAM_DIGEST}"; \
    } > /etc/php-base/release; \
    \
    # PHP's binaries were linked against the PHP image's Alpine: the runtime
    # must be the same minor.
    alpine_full="$(cat /etc/alpine-release)"; \
    upstream_alpine="$(cat /tmp/upstream-alpine-release)"; \
    [ "${alpine_full%.*}" = "${upstream_alpine%.*}" ] \
        || { echo "runtime is Alpine ${alpine_full}, PHP was built on ${upstream_alpine}"; exit 1; }; \
    php_full="$(php -r 'echo PHP_VERSION;')"; \
    case "$php_full" in "${PHP_VERSION}".*) ;; *) echo "PHP ${php_full} is not the ${PHP_VERSION} line"; exit 1 ;; esac; \
    [ "$PHP_FULL_VERSION" = unknown ] || [ "$PHP_FULL_VERSION" = "$php_full" ] \
        || { echo "PHP_FULL_VERSION=${PHP_FULL_VERSION}, but the image has PHP ${php_full}"; exit 1; }; \
    # ALPINE_FULL_VERSION (the alpine-version label) is the pinned Alpine base;
    # `apk upgrade` may have moved the runtime a point release past it, never
    # back and never to another minor.
    [ "$ALPINE_FULL_VERSION" = unknown ] || [ "${ALPINE_FULL_VERSION%.*}" = "${alpine_full%.*}" ] \
        || { echo "ALPINE_FULL_VERSION=${ALPINE_FULL_VERSION}, but the image has Alpine ${alpine_full}"; exit 1; }; \
    [ "$ALPINE_FULL_VERSION" = unknown ] || [ "$(apk version -t "$alpine_full" "$ALPINE_FULL_VERSION")" != "<" ] \
        || { echo "ALPINE_FULL_VERSION=${ALPINE_FULL_VERSION} is newer than the image's Alpine ${alpine_full}"; exit 1; }; \
    # Every extension loads, without a warning.
    mods="$(php -m 2>&1)"; \
    case "$mods" in *[Ww]arning*|*"nable to load"*) echo "$mods"; exit 1 ;; esac; \
    php -v; \
    php-base-validate; \
    # Nothing may still belong to the upstream uid/gid 82.
    orphans="$(find / -xdev \( -user 82 -o -group 82 \) -print)"; \
    [ -z "$orphans" ] || { echo "owned by uid/gid 82: $orphans"; exit 1; }; \
    setid="$(find / -xdev -type f -perm /6000 -print)"; \
    [ -z "$setid" ] || { echo "setuid/setgid files: $setid"; exit 1; }; \
    # Build tooling, sources, PEAR and Composer are -dev only; Python (which
    # supervisord dragged in) and supervisord itself are gone for good.
    for p in /usr/src/php.tar.xz /usr/local/include /usr/local/lib/php/build /usr/local/lib/php/PEAR \
             /usr/local/bin/phpize /usr/local/bin/php-config /usr/local/bin/docker-php-* \
             /usr/local/bin/pear /usr/local/bin/pecl /usr/local/bin/peardev /usr/local/etc/pear.conf \
             /usr/local/php /usr/local/bin/php-cgi /usr/local/bin/phpdbg /usr/local/bin/composer \
             /usr/bin/python3 /usr/bin/supervisord /etc/supervisor; do \
        if [ -e "$p" ] || [ -L "$p" ]; then echo "must not be in the runtime image: $p"; exit 1; fi; \
    done; \
    if command -v python3; then echo "python3 must not be in the runtime image"; exit 1; fi

# Same names and meaning as the official image. Declared after the last use of
# the PHP_VERSION build argument (the line), which this ENV replaces.
ENV PHP_INI_DIR=/usr/local/etc/php \
    PHP_VERSION=${PHP_FULL_VERSION}

WORKDIR ${APP_ROOT}
USER www-data

EXPOSE 8080

# Role-aware (see healthcheck.sh): /fpm-ping on 127.0.0.1:8081 through FastCGI
# for the web role, heartbeat for php-base-every containers, nothing for other
# commands. Every 2 s during the start period, so Traefik (which routes only to
# healthy containers) gets a new container within seconds; every 30 s after.
# Kept on one line: hadolint anchors an inline ignore to the instruction's
# first line, so a wrapped HEALTHCHECK cannot be exempted from DL3025.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --start-interval=2s --retries=3 CMD healthcheck.sh

# SIGTERM reaches s6-svscan through tini; it stops nginx first with SIGQUIT
# (in-flight requests finish), then php-fpm with SIGQUIT and the scheduler and
# worker with SIGTERM. Kill timeouts are 15 s (nginx), 30 s (FPM) and 120 s
# (scheduler, worker), so a compose stop_grace_period should cover them.
STOPSIGNAL SIGTERM
ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
CMD ["php-base-web"]

# =============================================================================
# dev — published as :X.Y-dev
# =============================================================================
# The runtime plus everything that builds things: the app's `composer install`
# stage, local development, and extensions an app compiles itself
# (`apk add $PHPIZE_DEPS && docker-php-ext-install …`, as on the official
# image). Also replaces every app's "build Xdebug in the dev stage" step
# (which is what broke when pecl.php.net had an outage): the base CI builds it
# once a week.
FROM runtime AS dev

USER root

# PHPIZE_DEPS and the PHP_*FLAGS docker-php-ext-* compile with: the official
# image's values (test/run-dev.sh compares PHPIZE_DEPS with upstream).
ENV PHPIZE_DEPS="autoconf dpkg-dev dpkg file g++ gcc libc-dev make pkgconf re2c" \
    PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    PHP_CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    PHP_LDFLAGS="-Wl,-O1 -pie" \
    COMPOSER_HOME=/tmp/composer \
    COMPOSER_ALLOW_SUPERUSER=0

# From the PHP image: the source tarball (and its signature, where the line
# ships one), headers, phpize/php-config and the build files they use, the
# docker-php-* helpers, and PEAR/PECL where the line still has them (8.6 has
# none; the globs then match nothing).
COPY --from=php-upstream /usr/src/php.tar.xz /usr/src/php.tar.xz.as[c] /usr/src/
COPY --from=php-upstream /usr/local/include/ /usr/local/include/
COPY --from=php-upstream /usr/local/lib/php/ /usr/local/lib/php/
COPY --from=php-upstream /usr/local/bin/docker-php-* /usr/local/bin/phpize /usr/local/bin/php-config \
                         /usr/local/bin/pear* /usr/local/bin/pec[l] /usr/local/bin/
COPY --from=php-upstream /usr/local/etc/pear.con[f] /usr/local/etc/
# Every extension again, now with Xdebug and PCOV (the copy above brought
# only upstream's own).
COPY --from=ext-builder-dev /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=composer /composer /usr/local/bin/composer
COPY rootfs-dev/ /

RUN set -eux; \
    apk add --no-cache git openssh-client patch unzip; \
    ext_dir="$(php-config --extension-dir)"; \
    if [ -f "${ext_dir}/xdebug.so" ]; then docker-php-ext-enable xdebug; fi; \
    if [ -f "${ext_dir}/pcov.so" ];   then docker-php-ext-enable pcov;   fi; \
    chown -R root:root /usr/local/etc/php/conf.d; \
    chmod 0644 /usr/local/etc/php/conf.d/*.ini; \
    chmod 0755 /usr/local/bin/composer; \
    sed -i 's/^VARIANT=.*/VARIANT=dev/' /etc/php-base/release; \
    mods="$(php -m 2>&1)"; \
    case "$mods" in *[Ww]arning*|*"nable to load"*) echo "$mods"; exit 1 ;; esac; \
    php -v; \
    composer --version --no-ansi; \
    command -v phpize php-config docker-php-ext-install

LABEL io.github.achelesstech.php-base.variant="dev"

USER www-data
