# Drupal smoke-test app — also the minimal reference for a Drupal image.
ARG BASE_IMAGE
ARG BASE_DEV_IMAGE
# Composer is in the -dev image only, so the composer stage builds FROM it.
FROM ${BASE_DEV_IMAGE} AS build
ARG DRUPAL_SPEC=drupal/recommended-project:^11
RUN set -eux; \
    composer create-project --no-interaction --prefer-dist --no-progress "${DRUPAL_SPEC}" /tmp/app; \
    cd /tmp/app; \
    composer require --no-interaction --no-progress drush/drush

FROM ${BASE_IMAGE}
COPY --from=build --chown=root:root /tmp/app /var/www/html
USER root
RUN set -eux; \
    mkdir -p web/sites/default/files; \
    cp web/sites/default/default.settings.php web/sites/default/settings.php; \
    # The installer writes settings.php; a real image bakes it read-only.
    chown -R www-data:www-data web/sites/default; \
    printf '<?php echo "EXECUTED";' > web/sites/default/files/evil.php; \
    ln -s /etc/nginx/presets/drupal.conf /etc/nginx/conf.d/default.conf; \
    nginx-validate.sh
USER www-data
