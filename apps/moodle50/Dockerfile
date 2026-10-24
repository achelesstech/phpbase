# =============================================================================
# Moodle 5.0 — application image
# =============================================================================
# Unlike Laravel/Drupal, Moodle is not "your" repo — the code is an upstream
# tarball. So this is a DEPLOYMENT repo: one per Moodle site, or one per major
# version that you deploy.
#
# 5.0 predates 5.2 in the public/ restructure timeline, so it may well use the
# FLAT layout (config.php and index.php at the install root, no r.php router).
# Nothing here hardcodes that assumption: select-vhost.sh inspects the extracted
# tarball and installs vhost-legacy.conf or vhost-public.conf accordingly, and
# prints which it chose. That is why this directory is a near-copy of moodle52
# rather than a fork — only MOODLE_BRANCH actually differs.
# =============================================================================

ARG BASE_IMAGE=docker.io/achelesstech/php-base:8.4
FROM ${BASE_IMAGE} AS moodle

# 503 = 5.3.x (LTS, Oct 2026)   502 = 5.2.x   501 = 5.1.x   500 = 5.0.x
ARG MOODLE_BRANCH=500

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
