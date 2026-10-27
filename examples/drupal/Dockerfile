# =============================================================================
# Drupal 11 — application image on achelesstech/php-base
# =============================================================================
# Copy this directory into the app repository (see README.md). The project is
# composer-managed (drupal/recommended-project layout, docroot web/) and
# requires drush/drush.
#
#   vendor      composer install          (-dev base: Composer lives there)
#   build       full source, autoloader
#   production  root-owned code on the runtime base       <- compose.prod.yml
#   dev         the -dev base, source bind-mounted         <- compose.yml
#
# Drupal 11 needs PHP >= 8.3. APCu is in the base (Drupal's class loader and
# fast-bootstrap caches use it).
#
# Both bases are pinned by digest: `:8.4` alone changes the app image whenever
# the base is rebuilt, and last week's build can no longer be reproduced.
# README.md shows how to read the two digests; Renovate keeps them current.
# A tag-only reference (--build-arg PHP_BASE_IMAGE=…:8.4) builds as well.
# =============================================================================

ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:e0c4e55351bb18b0bd3d695d9b397128d79992dac719375f1f2b72e17bae5e02
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:92c1680fd525ac39e5297c23b051e64e5551c7bbf08a1262948052a1a3fd05f5

# =============================================================================
# vendor — Composer dependencies and Drupal's scaffold files (web/index.php,
# web/core, …), cached on the lockfile alone
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS vendor

# The base's APP_ROOT, spelled out for the relative paths below.
WORKDIR /var/www/html
COPY --chown=www-data:www-data composer.json composer.lock ./
# Scripts and plugins run: drupal/core-composer-scaffold writes web/ here.
# --no-autoloader: the autoloader needs the full source, which arrives in
# `build`.
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist --no-autoloader

# =============================================================================
# build — the project's own code (custom modules and themes, config/) and
# the autoloader
# =============================================================================
FROM vendor AS build

COPY --chown=www-data:www-data . .

# --optimize, never --classmap-authoritative: Drupal registers each module's
# namespace at runtime, which an authoritative classmap would refuse.
RUN set -eux; \
    test -x vendor/bin/drush || { echo "drush/drush is missing: composer require drush/drush"; exit 1; }; \
    composer dump-autoload --no-dev --optimize

# =============================================================================
# production
# =============================================================================
FROM ${PHP_BASE_IMAGE} AS production

# Code is ROOT-owned: a compromised PHP process cannot rewrite it, and the
# env-driven settings.php (no secrets in it) is read-only with the rest.
COPY --from=build --chown=root:root /var/www/html /var/www/html
COPY docker/settings.php /var/www/html/web/sites/default/settings.php

USER root
# Only the two files directories belong to www-data. With read_only: true they
# are the only writable paths at runtime (volumes); owning them here gives the
# volumes www-data ownership when Docker first populates them.
# config/sync must exist (empty until the first export is committed): with it
# and the database settings in place, the installer accepts a read-only
# settings.php. Its .htaccess is written here, by Drupal itself, because cron
# checks for one and cannot write it at runtime.
RUN set -eux; \
    chown root:root /var/www/html; \
    mkdir -p config/sync web/sites/default/files private; \
    php -r 'require "vendor/autoload.php"; exit(Drupal\Component\FileSecurity\FileSecurity::writeHtaccess("config/sync") ? 0 : 1);'; \
    chown www-data:www-data web/sites/default/files private; \
    chmod 0555 web/sites/default; \
    chmod 0444 web/sites/default/settings.php; \
    ln -s /etc/nginx/presets/drupal.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data

# =============================================================================
# dev — the -dev base (Composer, Xdebug off until XDEBUG_MODE is set); the
# source is bind-mounted by compose.yml
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS dev

USER root
RUN set -eux; \
    ln -s /etc/nginx/presets/drupal.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data
