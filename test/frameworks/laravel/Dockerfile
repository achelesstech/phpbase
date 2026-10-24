# Laravel smoke-test app — also the minimal reference for a Laravel image.
ARG BASE_IMAGE
ARG BASE_DEV_IMAGE
# Composer is in the -dev image only, so the composer stage builds FROM it.
FROM ${BASE_DEV_IMAGE} AS build
ARG LARAVEL_SPEC=laravel/laravel:^13.0
# Runs as www-data: create-project generates .env and APP_KEY, creates the
# SQLite database and migrates it.
RUN composer create-project --no-interaction --prefer-dist --no-progress "${LARAVEL_SPEC}" /tmp/app

FROM ${BASE_IMAGE}
# Code ROOT-owned; only what Laravel writes at runtime belongs to www-data.
COPY --from=build --chown=root:root /tmp/app /var/www/html
USER root
RUN set -eux; \
    chown -R www-data:www-data storage bootstrap/cache database; \
    printf '<?php echo "EXECUTED";' > public/evil.php; \
    ln -s /etc/nginx/presets/laravel.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data
