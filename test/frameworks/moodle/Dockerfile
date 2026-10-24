# Moodle smoke-test app — also the minimal reference for a Moodle image.
ARG BASE_IMAGE
ARG BASE_DEV_IMAGE

# Composer is in the -dev image only, so the release tarball is unpacked and
# its vendor/ installed in a stage built FROM it.
FROM ${BASE_DEV_IMAGE} AS build
ARG MOODLE_BRANCH=503
# `curl | tar` below must fail when curl does.
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
USER root
RUN set -eux; \
    curl -fsSL "https://packaging.moodle.org/stable${MOODLE_BRANCH}/moodle-latest-${MOODLE_BRANCH}.tgz" \
        | tar xz --strip-components=1 -C /var/www/html; \
    chown -R www-data:www-data /var/www/html
# 5.1+ tarballs ship no complete vendor/; the environment check fails without it.
USER www-data
RUN if [ -f composer.json ]; then composer install --no-dev --classmap-authoritative --no-interaction --no-progress; fi

FROM ${BASE_IMAGE}
COPY --from=build --chown=root:root /var/www/html /var/www/html
COPY config.php /var/www/html/config.php
USER root
RUN set -eux; \
    chown -R root:root /var/www/html; \
    install -d -o www-data -g www-data /var/moodledata; \
    if [ -f public/index.php ]; then \
        ln -s /etc/nginx/presets/moodle.conf /etc/nginx/conf.d/default.conf; \
    else \
        ln -s /etc/nginx/presets/moodle-legacy.conf /etc/nginx/conf.d/default.conf; \
        sed -i "s#/public/lib/setup.php#/lib/setup.php#; s#^\$CFG->routerconfigured.*##" config.php; \
    fi; \
    # Test-only probe: OPcache usage as seen by FPM (not the CLI).
    docroot="$( [ -f public/index.php ] && echo public || echo . )"; \
    printf '%s' '<?php $s = opcache_get_status(false); printf("%d scripts, %.0f MB used, %.0f MB free, %d restarts", $s["opcache_statistics"]["num_cached_scripts"], $s["memory_usage"]["used_memory"] / 1048576, $s["memory_usage"]["free_memory"] / 1048576, $s["opcache_statistics"]["oom_restarts"] + $s["opcache_statistics"]["hash_restarts"]);' > "$docroot/smoke-opcache.php"; \
    nginx-validate.sh
USER www-data
