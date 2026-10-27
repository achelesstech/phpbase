# syntax=docker/dockerfile:1
# (the ${VAR#…}/${VAR%…} modifiers below need a current Dockerfile frontend,
# not whatever version the builder happens to bundle)
# =============================================================================
# Moodle 5.3 LTS — application image on achelesstech/php-base
# =============================================================================
# A DEPLOYMENT repo (see README.md): Moodle is the upstream release tarball,
# downloaded at build. The repository holds this directory, config.php and
# whatever plugins the site adds.
#
#   source      release tarball + composer install   (-dev base: Composer)
#   production  root-owned code on the runtime base   <- compose.prod.yml
#   dev         the same tree on the -dev base        <- compose.yml
#
# Both bases are pinned by digest: `:8.4` alone changes the app image whenever
# the base is rebuilt, and last week's build can no longer be reproduced.
# README.md shows how to read the two digests; Renovate keeps them current.
# A tag-only reference (--build-arg PHP_BASE_IMAGE=…:8.4) builds as well.
# =============================================================================

ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:<runtime>
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:<dev>

# =============================================================================
# source — the Moodle tree with its Composer dependencies
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS source

# The Moodle branch. MOODLE_503_STABLE is 5.3 LTS, the version the base
# image's tests install; it uses the public/ layout moodle.conf serves.
ARG MOODLE_BRANCH=MOODLE_503_STABLE
# MOODLE_503_STABLE -> 503: the packaging server's name for the branch.
ARG MOODLE_PKG=${MOODLE_BRANCH#MOODLE_}

# The base's APP_ROOT, spelled out for the relative paths below.
WORKDIR /var/www/html
# The newest weekly build of the branch. ADD, not `curl | tar`: BuildKit
# checks the URL on every build and reuses the cached layer only while the
# tarball is unchanged, so a rebuild picks up Moodle's weekly fixes.
# Integrity rests on HTTPS to packaging.moodle.org: a weekly build that moves
# cannot be pinned by checksum. To pin, point the URL at one fixed release
# file instead and add `--checksum=sha256:<hash>` to this ADD.
ADD --chown=www-data:www-data \
    https://packaging.moodle.org/stable${MOODLE_PKG%_STABLE}/moodle-latest-${MOODLE_PKG%_STABLE}.tgz \
    /tmp/moodle.tgz
USER root
RUN set -eux; \
    tar xzf /tmp/moodle.tgz --strip-components=1 -C /var/www/html; \
    rm /tmp/moodle.tgz; \
    chown -R www-data:www-data /var/www/html
USER www-data
# 5.1+ tarballs ship no complete vendor/; Moodle's environment check fails
# without it.
RUN composer install --no-dev --classmap-authoritative --no-interaction --no-progress

# Plugins kept in this repository go here, e.g.
#   COPY --chown=www-data:www-data plugins/mod_example/ public/mod/example/

# =============================================================================
# production
# =============================================================================
FROM ${PHP_BASE_IMAGE} AS production

# Code is ROOT-owned: a compromised PHP process cannot rewrite it, and plugins
# are installed through this file, not the web UI ($CFG->disableupdateautodeploy).
COPY --from=source --chown=root:root /var/www/html /var/www/html
COPY --chown=root:root docker/config.php /var/www/html/config.php

USER root
# ghostscript: PDF annotation in assignment feedback ($CFG->pathtogs).
# moodledata is the one writable path besides /tmp; owning it here gives the
# volume www-data ownership when Docker first populates it.
RUN set -eux; \
    chown root:root /var/www/html; \
    apk add --no-cache ghostscript; \
    install -d -o www-data -g www-data -m 0750 /var/moodledata; \
    php -l config.php; \
    ln -s /etc/nginx/presets/moodle.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data

# Long admin pages, backups and restores: all three timeouts at 600 s (the
# base defaults are 120 s for PHP, 300 s for FPM and nginx).
ENV PHP_MAX_EXECUTION_TIME=600 \
    NGINX_FASTCGI_READ_TIMEOUT=600s \
    FPM_REQUEST_TERMINATE_TIMEOUT=600s

# =============================================================================
# dev — the -dev base (Composer, Xdebug off until XDEBUG_MODE is set) with the
# same Moodle tree; compose.yml bind-mounts config.php
# =============================================================================
# Keep the COPY, RUN and ENV below in sync with `production` (only php -l is
# left out: config.php is bind-mounted and edited here).
FROM ${PHP_BASE_DEV_IMAGE} AS dev

COPY --from=source --chown=root:root /var/www/html /var/www/html
COPY --chown=root:root docker/config.php /var/www/html/config.php

USER root
RUN set -eux; \
    chown root:root /var/www/html; \
    apk add --no-cache ghostscript; \
    install -d -o www-data -g www-data -m 0750 /var/moodledata; \
    ln -s /etc/nginx/presets/moodle.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data

ENV PHP_MAX_EXECUTION_TIME=600 \
    NGINX_FASTCGI_READ_TIMEOUT=600s \
    FPM_REQUEST_TERMINATE_TIMEOUT=600s
