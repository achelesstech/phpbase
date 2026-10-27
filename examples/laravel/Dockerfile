# =============================================================================
# Laravel 13 — application image on achelesstech/php-base
# =============================================================================
# Copy this directory into the app repository (see README.md).
#
#   vendor      composer install          (-dev base: Composer lives there)
#   assets      npm ci + vite build       (Node; never reaches the image)
#   build       full source, autoloader, framework caches baked
#   production  root-owned code on the runtime base       <- compose.prod.yml
#   dev         the -dev base, source bind-mounted         <- compose.yml
#
# Laravel 13 needs PHP >= 8.3; from 13.3 it pulls Symfony 8, which needs 8.4.
#
# Both bases are pinned by digest: `:8.4` alone changes the app image whenever
# the base is rebuilt, and last week's build can no longer be reproduced.
# README.md shows how to read the two digests; Renovate keeps them current.
# A tag-only reference (--build-arg PHP_BASE_IMAGE=…:8.4) builds as well.
# =============================================================================

ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:e0c4e55351bb18b0bd3d695d9b397128d79992dac719375f1f2b72e17bae5e02
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:92c1680fd525ac39e5297c23b051e64e5551c7bbf08a1262948052a1a3fd05f5

# =============================================================================
# vendor — Composer dependencies, cached on the lockfile alone
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS vendor

# The base's APP_ROOT, spelled out for the relative paths below.
WORKDIR /var/www/html
COPY --chown=www-data:www-data composer.json composer.lock ./
# --no-scripts: artisan isn't here yet. --no-autoloader: the optimized
# autoloader needs the full source, which arrives in `build`.
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist \
        --no-scripts --no-autoloader

# =============================================================================
# assets — Vite build. Only public/build/ leaves this stage.
# =============================================================================
FROM docker.io/library/node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53 AS assets

WORKDIR /app
COPY package.json package-lock.json* .npmrc* ./
# Commit package-lock.json: `npm ci` installs exactly what it lists. Without
# one (a fresh `laravel new` has none), `npm install` resolves the ranges.
RUN if [ -f package-lock.json ]; then npm ci; else npm install --no-audit --no-fund; fi
COPY . .
# Tailwind scans Blade views under vendor/ (pagination), and packages such as
# Livewire ship their JavaScript there.
COPY --from=vendor /var/www/html/vendor ./vendor
RUN npm run build

# =============================================================================
# build — autoloader and framework caches
# =============================================================================
FROM vendor AS build

COPY --chown=www-data:www-data . .

# dump-autoload runs post-autoload-dump, which is where package:discover
# happens, so the earlier --no-scripts is recovered here.
#
# The caches are baked into the IMAGE rather than written at start: the root
# filesystem is read-only, and app, queue and scheduler would otherwise race
# over the same files. config:cache is the exception: it would freeze the
# build's (empty) environment, so configuration is read from the runtime
# environment instead. Read env() only inside config/*.php, as Laravel requires.
RUN set -eux; \
    mkdir -p storage/app/public storage/app/private storage/framework/cache/data \
             storage/framework/sessions storage/framework/views storage/logs bootstrap/cache; \
    composer dump-autoload --no-dev --optimize --classmap-authoritative; \
    php artisan storage:link; \
    php artisan event:cache; \
    php artisan route:cache; \
    php artisan view:cache

# =============================================================================
# production
# =============================================================================
FROM ${PHP_BASE_IMAGE} AS production

# Code is ROOT-owned: a compromised PHP process cannot rewrite it.
COPY --from=build --chown=root:root /var/www/html /var/www/html
COPY --from=assets --chown=root:root /app/public/build /var/www/html/public/build
# Hooks root-owned and not writable by www-data (no --chown).
COPY docker/entrypoint.d/ /docker-entrypoint.d/

USER root
# Only what Laravel writes belongs to www-data. With read_only: true only the
# storage/app volume is writable at runtime; owning storage/ here gives that
# volume www-data ownership when Docker first populates it.
RUN set -eux; \
    chown root:root /var/www/html; \
    chown -R www-data:www-data storage bootstrap/cache; \
    ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data

# Blade compiles a view it has not seen before (the /up page, error pages,
# mail templates) into this directory. The root filesystem is read-only, so it
# lives on the /tmp tmpfs; docker/entrypoint.d/10-laravel-views.sh seeds it
# with the views baked above at every start.
ENV VIEW_COMPILED_PATH=/tmp/laravel/views

# =============================================================================
# dev — the -dev base (Composer, Xdebug off until XDEBUG_MODE is set); the
# source is bind-mounted by compose.yml
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS dev

USER root
RUN set -eux; \
    ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data
