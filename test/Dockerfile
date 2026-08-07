# =============================================================================
# Test fixture — the smallest possible correct consumer of php-base
# =============================================================================
# Built by `make test`. It is also the minimal reference for the base image's
# contract: supply one vhost that listens on 8080 and defines /fpm-ping.
#
# Built as an image rather than bind-mounted, so the test exercises the real
# application-image path and does not depend on host file-sharing settings.
# =============================================================================

ARG BASE_IMAGE=local/php-base:8.4
FROM ${BASE_IMAGE}

COPY --chown=www-data:www-data public/     /var/www/html/public/
COPY --chown=www-data:www-data vhost.conf  /etc/nginx/conf.d/vhost.conf
COPY --chown=www-data:www-data hook.sh     /docker-entrypoint.d/10-fixture.sh

RUN nginx-validate.sh
