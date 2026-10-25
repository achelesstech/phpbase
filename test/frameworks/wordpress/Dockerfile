# WordPress smoke-test app — also the minimal reference for a WordPress image.
ARG BASE_IMAGE
# Not used (WordPress needs no composer stage); declared so every fixture
# takes the same arguments.
ARG BASE_DEV_IMAGE
FROM ${BASE_IMAGE}
ARG WP_VERSION=latest
# `curl | tar` below must fail when curl does: pipefail (no SHELL instruction).
USER root
RUN set -eux -o pipefail; \
    curl -fsSL "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz" | tar xz --strip-components=1 -C /var/www/html; \
    curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod 0755 /usr/local/bin/wp; \
    chown -R root:root /var/www/html; \
    install -d -o www-data -g www-data /var/www/html/wp-content/uploads; \
    printf '<?php echo "EXECUTED";' > wp-content/uploads/evil.php; \
    chown www-data:www-data wp-content/uploads/evil.php; \
    ln -s /etc/nginx/presets/wordpress.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
COPY wp-config.php /var/www/html/wp-config.php
USER www-data
