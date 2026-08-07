#!/bin/sh
# =============================================================================
# 10-drupal.sh — runs as www-data at container start
# =============================================================================
set -eu

cd "${APP_ROOT:-/var/www/html}"

# ── Writable files directory ─────────────────────────────────────────────────
mkdir -p web/sites/default/files
# Runs as www-data: succeeds on image-owned paths, fails on a foreign-uid bind
# mount. Never abort startup over it.
chown -R www-data:www-data web/sites/default/files 2>/dev/null || true
chmod -R u+rwX,g+rwX       web/sites/default/files 2>/dev/null || true

# ── settings.php ─────────────────────────────────────────────────────────────
if [ ! -f web/sites/default/settings.php ] && [ -f web/sites/default/default.settings.php ]; then
    cp web/sites/default/default.settings.php web/sites/default/settings.php
fi

# ── Reverse-proxy trust ──────────────────────────────────────────────────────
# Without this Drupal sees Traefik's IP as the client and generates http:// URLs
# behind TLS. Appended exactly once; disable with DRUPAL_REVERSE_PROXY=false.
if [ "${DRUPAL_REVERSE_PROXY:-true}" = "true" ] \
   && [ -f web/sites/default/settings.php ] \
   && ! grep -q 'reverse_proxy_addresses' web/sites/default/settings.php 2>/dev/null; then

    cat >> web/sites/default/settings.php <<'PHP'

// Appended by the container entrypoint: trust the reverse proxy.
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = array_filter(explode(
  ',',
  getenv('DRUPAL_REVERSE_PROXY_ADDRESSES') ?: '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
));
$settings['reverse_proxy_trusted_headers'] =
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR |
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_HOST |
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT |
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO;
PHP
    echo "[drupal] reverse-proxy settings appended to settings.php"
fi

# ── Database updates ─────────────────────────────────────────────────────────
# Off by default: running updatedb from every replica's entrypoint means
# concurrent schema changes. Prefer the one-shot `drush` compose service.
if [ "${RUN_UPDATES:-false}" = "true" ]; then
    echo "[drupal] running database updates"
    ./vendor/bin/drush updatedb -y --no-interaction || true
    ./vendor/bin/drush cache:rebuild                || true
fi
