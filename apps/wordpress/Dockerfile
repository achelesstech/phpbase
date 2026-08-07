# =============================================================================
# WordPress — application image
# =============================================================================
# Like Moodle, WordPress core is an upstream tarball rather than your code, so
# this is a DEPLOYMENT repo: one per site. Your themes and plugins are yours,
# and belong in wp-content/ in this repo (see the COPY below).
#
# The previous revision's Dockerfile.wordpress had never been built — a `chmod`
# line after a heredoc terminator was parsed as a Dockerfile instruction. This
# one is verified.
#
# Docroot is the install root: WordPress has no public/ subdirectory.
# =============================================================================

ARG BASE_IMAGE=ghcr.io/achelesstech/php-base:8.4
FROM ${BASE_IMAGE} AS wordpress

ARG WP_VERSION=latest

ENV APP_ROOT=/var/www/html

USER root
WORKDIR /var/www/html

# `less` is WP-CLI's pager; mariadb-client for backups and CLI debugging.
RUN apk add --no-cache less mariadb-client

# ── WordPress core ───────────────────────────────────────────────────────────
RUN set -eux; \
    curl -fsSL "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz" \
        | tar xz --strip-components=1 -C /var/www/html; \
    chown -R www-data:www-data /var/www/html

# ── WP-CLI ───────────────────────────────────────────────────────────────────
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/wp-cli/v2.11.0/phar/wp-cli.phar \
        || curl -fsSL -o /usr/local/bin/wp \
           https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod +x /usr/local/bin/wp; \
    su -s /bin/sh www-data -c "wp --info --allow-root >/dev/null" || wp --info >/dev/null

# ── Your themes and plugins ──────────────────────────────────────────────────
# Uncomment what this site actually ships. Anything installed through the admin
# UI instead lives in the uploads/plugins volume and is NOT reproducible — for
# a container deployment, prefer committing them here.
# COPY --chown=www-data:www-data wp-content/themes/  /var/www/html/wp-content/themes/
# COPY --chown=www-data:www-data wp-content/plugins/ /var/www/html/wp-content/plugins/
# COPY --chown=www-data:www-data wp-content/mu-plugins/ /var/www/html/wp-content/mu-plugins/

COPY --chown=www-data:www-data docker/vhost.conf    /etc/nginx/conf.d/vhost.conf
COPY --chown=www-data:www-data docker/entrypoint.d/ /docker-entrypoint.d/
RUN chmod +x /docker-entrypoint.d/*.sh

RUN nginx-validate.sh

USER www-data

# =============================================================================
# dev
# =============================================================================
FROM wordpress AS dev

USER root
RUN apk add --no-cache --virtual .xdebug-deps $PHPIZE_DEPS \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug \
    && apk del .xdebug-deps \
    && apk add --no-cache git
USER www-data
