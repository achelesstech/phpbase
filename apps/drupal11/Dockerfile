# =============================================================================
# Drupal 11 — application image
# =============================================================================
# Assumes a composer-managed project (drupal/recommended-project layout) where
# the docroot is web/. Copy this file, .dockerignore, compose*.yml and docker/
# into the app repo.
#
# Drupal 11 requires PHP >= 8.3. APCu is in the base image (it is the backing
# store for Drupal's class loader and fast-bootstrap caches).
# =============================================================================

ARG BASE_IMAGE=docker.io/achelesstech/php-base:8.4
FROM ${BASE_IMAGE} AS base

ENV APP_ROOT=/var/www/html
WORKDIR /var/www/html

# =============================================================================
# deps
# =============================================================================
FROM base AS deps

# COMPOSER_HOME is set to /tmp/composer by the base image, so composer works as
# a non-root user with no home directory. Do not drop this.
COPY --chown=www-data:www-data composer.json composer.lock ./
RUN composer install \
        --no-dev --no-interaction --no-progress \
        --no-scripts --no-autoloader --prefer-dist

# =============================================================================
# build
# =============================================================================
FROM deps AS build

COPY --chown=www-data:www-data . .
RUN composer dump-autoload --optimize --classmap-authoritative

# Install Drush for real if the project doesn't already declare it.
# `composer require --no-update` only edits composer.json and installs nothing.
RUN if composer show drush/drush >/dev/null 2>&1; then \
        echo "drush already required by the project"; \
    else \
        composer require drush/drush --no-interaction --no-progress --optimize-autoloader; \
    fi

# =============================================================================
# production
# =============================================================================
FROM base AS production

COPY --from=build --chown=www-data:www-data /var/www/html /var/www/html

USER root
# OS packages belong here, not in the base image: no compiler needed, and they
# stay visibly attached to the app that requires them.
RUN apk add --no-cache postgresql-client \
    && rm -rf /var/www/html/.git /var/www/html/.github \
    && rm -f  /var/www/html/.env
USER www-data

COPY --chown=www-data:www-data docker/vhost.conf    /etc/nginx/conf.d/vhost.conf
COPY --chown=www-data:www-data docker/entrypoint.d/ /docker-entrypoint.d/

RUN nginx-validate.sh

# =============================================================================
# dev
# =============================================================================
FROM base AS dev

USER root
RUN apk add --no-cache --virtual .xdebug-deps $PHPIZE_DEPS \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug \
    && apk del .xdebug-deps \
    && apk add --no-cache git postgresql-client

COPY docker/vhost.conf    /etc/nginx/conf.d/vhost.conf
COPY docker/entrypoint.d/ /docker-entrypoint.d/
USER www-data
