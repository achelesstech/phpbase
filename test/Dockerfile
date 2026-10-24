# =============================================================================
# Test fixture — the smallest correct consumer of php-base
# =============================================================================
# Built by test/run.sh. Also the minimal reference for the base's contract:
# a vhost on 8080 that includes /etc/nginx/php-base/health.conf.
#
# Built as an image rather than bind-mounted, so the test exercises the real
# application-image path and not host file-sharing settings.
# =============================================================================

ARG BASE_IMAGE=php-base-next:8.4
FROM ${BASE_IMAGE}

# Code and hooks are copied ROOT-owned (the default) — the recommended pattern.
# The hook is deliberately NOT executable, to prove the sh fallback.
COPY public/                 /var/www/html/public/
COPY vhost.conf              /etc/nginx/conf.d/default.conf
COPY --chmod=0644 hook.sh    /docker-entrypoint.d/10-fixture.sh

RUN nginx-validate.sh
