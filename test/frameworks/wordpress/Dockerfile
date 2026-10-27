# WordPress smoke-test app — also the minimal reference for a WordPress image.
ARG BASE_IMAGE
# Not used (WordPress needs no composer stage); declared so every fixture
# takes the same arguments.
ARG BASE_DEV_IMAGE
FROM ${BASE_IMAGE}
ARG WP_VERSION=latest
# Downloads are saved to files, so curl can retry a dropped transfer from the
# start; into a pipe it cannot.
USER root
RUN set -eux; \
    curl -fsSL --retry 5 --retry-all-errors -o /tmp/wordpress.tgz "https://wordpress.org/wordpress-${WP_VERSION}.tar.gz"; \
    tar xzf /tmp/wordpress.tgz --strip-components=1 -C /var/www/html; \
    rm /tmp/wordpress.tgz; \
    curl -fsSL --retry 5 --retry-all-errors -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod 0755 /usr/local/bin/wp; \
    chown -R root:root /var/www/html; \
    install -d -o www-data -g www-data /var/www/html/wp-content/uploads; \
    printf '<?php echo "EXECUTED";' > wp-content/uploads/evil.php; \
    chown www-data:www-data wp-content/uploads/evil.php; \
    ln -s /etc/nginx/presets/wordpress.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
COPY wp-config.php /var/www/html/wp-config.php
USER www-data
