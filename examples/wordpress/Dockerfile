# =============================================================================
# WordPress — site image on achelesstech/php-base
# =============================================================================
# A DEPLOYMENT repository, one per site: WordPress core is an upstream release
# downloaded at build, not your code. What is yours lives in wp-content/
# (themes, plugins, mu-plugins), committed here and baked into the image.
#
#   site        core + wp-cli downloaded and verified, wp-content/ and
#               wp-config.php laid over it          (-dev base: build only)
#   production  root-owned code on the runtime base       <- compose.prod.yml
#   dev         the same tree on the -dev base             <- compose.yml
#
# Both bases are pinned by digest: `:8.4` alone changes the site image whenever
# the base is rebuilt, and last week's build can no longer be reproduced.
# README.md shows how to read the two digests; Renovate keeps them current.
# A tag-only reference (--build-arg PHP_BASE_IMAGE=…:8.4) builds as well.
# =============================================================================

ARG PHP_BASE_IMAGE=docker.io/achelesstech/php-base:8.4@sha256:<runtime>
ARG PHP_BASE_DEV_IMAGE=docker.io/achelesstech/php-base:8.4-dev@sha256:<dev>

# =============================================================================
# site — the complete docroot, assembled once for both final stages
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS site

# Upgrading WordPress: set the version and its checksum together (README.md):
#   curl -fsS https://downloads.wordpress.org/release/wordpress-X.Y.Z.tar.gz.sha1
# then run `wp core update-db` (the `migrate` service) after the deploy.
ARG WORDPRESS_VERSION=7.1.3
ARG WORDPRESS_SHA1=491a78c7676b15dffcc69130c6054b8f49228a91
# https://github.com/wp-cli/wp-cli/releases (the .phar.sha512 next to the phar)
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832

USER root
WORKDIR /build
RUN set -eux -o pipefail; \
    curl -fsSL -o wordpress.tar.gz \
        "https://downloads.wordpress.org/release/wordpress-${WORDPRESS_VERSION}.tar.gz"; \
    echo "${WORDPRESS_SHA1}  wordpress.tar.gz" | sha1sum -c -; \
    mkdir wordpress; \
    tar -xzf wordpress.tar.gz -C wordpress --strip-components=1; \
    rm wordpress.tar.gz wordpress/wp-config-sample.php; \
    curl -fsSL -o wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    echo "${WP_CLI_SHA512}  wp" | sha512sum -c -; \
    chmod 0755 wp
USER www-data

# Your themes, plugins and mu-plugins, over the ones core ships. Plugins are
# installed HERE, by committing them: DISALLOW_FILE_MODS keeps the admin from
# installing or updating anything at runtime, where it would be lost on the
# next deploy anyway.
COPY wp-content/ wordpress/wp-content/
# Every setting from the environment: one file for every site and stage.
COPY docker/wp-config.php wordpress/wp-config.php

# =============================================================================
# production
# =============================================================================
FROM ${PHP_BASE_IMAGE} AS production

# Code is ROOT-owned: a compromised PHP process cannot rewrite it.
COPY --from=site --chown=root:root /build/wordpress /var/www/html
COPY --from=site --chown=root:root /build/wp /usr/local/bin/wp

USER root
# Only wp-content/uploads belongs to www-data. With read_only: true it is the
# one writable path at runtime (the uploads volume); owning it here gives that
# volume www-data ownership when Docker first populates it.
RUN set -eux; \
    chown root:root /var/www/html; \
    install -d -o www-data -g www-data -m 0755 wp-content/uploads; \
    ln -s /etc/nginx/presets/wordpress.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data

# =============================================================================
# dev — the -dev base (Xdebug off until XDEBUG_MODE is set); compose.yml
# bind-mounts your own wp-content directories over the baked ones
# =============================================================================
FROM ${PHP_BASE_DEV_IMAGE} AS dev

COPY --from=site --chown=root:root /build/wordpress /var/www/html
COPY --from=site --chown=root:root /build/wp /usr/local/bin/wp

USER root
RUN set -eux; \
    chown root:root /var/www/html; \
    install -d -o www-data -g www-data -m 0755 wp-content/uploads; \
    ln -s /etc/nginx/presets/wordpress.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data
