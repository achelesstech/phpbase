# =============================================================================
# Moodle 5.2 — application image
# =============================================================================
# Unlike Laravel/Drupal, Moodle is not "your" repo — the code is an upstream
# tarball. So this is a DEPLOYMENT repo: one per Moodle site, or one per major
# version that you deploy.
#
# ── Moving to 5.3 LTS (October) ──────────────────────────────────────────────
# Copy this directory to moodle53 and change MOODLE_BRANCH to 503. Nothing else
# should need editing: the docroot layout is DETECTED at build time by
# select-vhost.sh rather than hardcoded, because the public/ restructure is
# exactly the kind of per-release detail that goes stale in a Dockerfile.
# Check the build log — it prints which layout it found and which vhost it
# installed — and run `moodle-doctor.sh` in the container afterwards.
# =============================================================================

ARG BASE_IMAGE=ghcr.io/achelesstech/php-base:8.4
FROM ${BASE_IMAGE} AS moodle

# 503 = 5.3.x (LTS, Oct 2026)   502 = 5.2.x   501 = 5.1.x   500 = 5.0.x
ARG MOODLE_BRANCH=502

ENV APP_ROOT=/var/www/html \
    MOODLE_DATAROOT=/var/moodledata

USER root
WORKDIR /var/www/html

# OS packages Moodle shells out to. Plain binaries, no compiler — so they live
# here rather than bloating the shared base.
#   ghostscript  PDF annotation / assignment feedback
#   graphviz     admin dependency graphs
#   *-client     backups and CLI debugging
RUN apk add --no-cache ghostscript graphviz mariadb-client postgresql-client

# ── Moodle source ────────────────────────────────────────────────────────────
RUN set -eux; \
    curl -fsSL "https://packaging.moodle.org/stable${MOODLE_BRANCH}/moodle-latest-${MOODLE_BRANCH}.tgz" \
        | tar xz --strip-components=1 -C /var/www/html; \
    chown -R www-data:www-data /var/www/html

# ── Composer dependencies ────────────────────────────────────────────────────
# Mandatory from 5.1: the release tarball no longer ships a complete vendor/
# tree and the environment check fails without it. Harmless on older branches
# that do ship one.
USER www-data
RUN set -eux; \
    if [ -f composer.json ]; then \
        composer install --no-dev --classmap-authoritative \
                         --no-interaction --no-progress; \
    else \
        echo "no composer.json in this branch — skipping"; \
    fi
USER root
RUN rm -rf /tmp/composer

# ── moodledata — must live OUTSIDE the install root ──────────────────────────
RUN mkdir -p "${MOODLE_DATAROOT}" \
    && chown -R www-data:www-data "${MOODLE_DATAROOT}"

# ── vhost: detected, not assumed ─────────────────────────────────────────────
COPY docker/vhost-public.conf docker/vhost-legacy.conf /tmp/vhosts/
COPY docker/select-vhost.sh   /usr/local/bin/select-vhost.sh
RUN chmod +x /usr/local/bin/select-vhost.sh \
    && select-vhost.sh "${APP_ROOT}" /tmp/vhosts \
    && rm -rf /tmp/vhosts \
    && chown www-data:www-data /etc/nginx/conf.d/vhost.conf

COPY --chown=www-data:www-data docker/entrypoint.d/ /docker-entrypoint.d/
COPY docker/moodle-cron.sh   /usr/local/bin/moodle-cron.sh
COPY docker/moodle-doctor.sh /usr/local/bin/moodle-doctor.sh
RUN chmod +x /docker-entrypoint.d/*.sh \
             /usr/local/bin/moodle-cron.sh \
             /usr/local/bin/moodle-doctor.sh

RUN nginx-validate.sh

USER www-data

# NOTE: no VOLUME instruction. It would create a stray anonymous volume on
# every `docker run` and make the path immutable to later build stages.
# Mount moodledata from compose instead.
