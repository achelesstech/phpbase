# =============================================================================
# Laravel 13 — application image
# =============================================================================
# Copy this file, .dockerignore, compose*.yml and docker/ into the app repo.
#
# Laravel 13 requires PHP >= 8.3; from 13.3 it pulls Symfony 8 components that
# require 8.4. Hence the 8.4 base.
#
# Pin the base by digest. `:8.4` alone means your app image changes silently
# whenever the base is rebuilt, and you cannot reproduce last week's build.
# Renovate keeps the digest current — see renovate.json in this directory.
# =============================================================================

ARG BASE_IMAGE=docker.io/achelesstech/php-base:8.4
FROM ${BASE_IMAGE} AS base

ENV APP_ROOT=/var/www/html
WORKDIR /var/www/html

# =============================================================================
# deps — composer + node, cached on lockfiles alone
# =============================================================================
FROM base AS deps

USER root
RUN apk add --no-cache nodejs npm
USER www-data

# Lockfiles first: this layer is reused until a dependency actually changes.
COPY --chown=www-data:www-data composer.json composer.lock ./
# --no-scripts because artisan isn't present yet; --no-autoloader because the
# optimized autoloader needs the full source, which arrives in the next stage.
RUN composer install \
        --no-dev --no-interaction --no-progress \
        --no-scripts --no-autoloader --prefer-dist

COPY --chown=www-data:www-data package.json package-lock.json* ./
RUN npm ci --include=dev

# =============================================================================
# build — full source, autoloader, frontend assets
# =============================================================================
FROM deps AS build

COPY --chown=www-data:www-data . .

# dump-autoload runs post-autoload-dump, which is where package:discover
# happens — so the earlier --no-scripts is recovered here, not lost.
RUN composer dump-autoload --optimize --classmap-authoritative

RUN npm run build

# Bake the framework caches into the IMAGE, not into a startup hook.
#
# Running config:cache at container start writes into bootstrap/cache. If that
# path is a shared volume across app + queue + scheduler (the usual compose
# layout), four containers race to write the same files at boot and a worker
# can read a half-written cache. Baked here they are immutable, identical
# across every replica, and cost zero startup time.
#
# config:cache requires the build-time env to be representative. Values that
# differ per environment must be read via config() from env at RUNTIME — never
# env() outside a config file, which is a Laravel rule anyway.
RUN php artisan config:clear \
    && php artisan view:cache \
    && php artisan event:cache

# =============================================================================
# production
# =============================================================================
FROM base AS production

COPY --from=build --chown=www-data:www-data /var/www/html /var/www/html

USER root
RUN rm -rf \
        /var/www/html/node_modules \
        /var/www/html/tests \
        /var/www/html/.git \
        /var/www/html/.github \
    && rm -f \
        /var/www/html/.env \
        /var/www/html/.env.example \
        /var/www/html/phpunit.xml \
        /var/www/html/phpstan.neon
USER www-data

COPY --chown=www-data:www-data docker/vhost.conf          /etc/nginx/conf.d/vhost.conf
COPY --chown=www-data:www-data docker/entrypoint.d/       /docker-entrypoint.d/

# Fail the build, not production, on a bad vhost.
RUN nginx-validate.sh

# =============================================================================
# dev — adds Xdebug and the toolchain the production image deliberately omits
# =============================================================================
# Target it explicitly:  docker compose build --build-arg ... / target: dev
FROM base AS dev

USER root
RUN apk add --no-cache --virtual .xdebug-deps $PHPIZE_DEPS \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug \
    && apk del .xdebug-deps \
    && apk add --no-cache nodejs npm git

COPY docker/vhost.conf    /etc/nginx/conf.d/vhost.conf
COPY docker/entrypoint.d/ /docker-entrypoint.d/
USER www-data
