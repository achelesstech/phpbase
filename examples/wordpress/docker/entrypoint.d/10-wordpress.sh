#!/bin/sh
# =============================================================================
# 10-wordpress.sh — runs as www-data at container start
# =============================================================================
# The previous revision's version did an UNGUARDED `chown -R wp-content` under
# `set -e`. Running as www-data, that fails on a bind mount owned by another
# uid and the container never starts. Every ownership operation here is
# guarded.
# =============================================================================
set -eu

cd "${APP_ROOT:-/var/www/html}"

# ── Writable directories ─────────────────────────────────────────────────────
for dir in wp-content/uploads wp-content/cache wp-content/upgrade; do
    mkdir -p "$dir" 2>/dev/null || true
done
chown -R www-data:www-data wp-content/uploads wp-content/cache wp-content/upgrade 2>/dev/null || true
chmod -R u+rwX,g+rwX       wp-content/uploads wp-content/cache wp-content/upgrade 2>/dev/null || true

# ── wp-config.php ────────────────────────────────────────────────────────────
if [ -f wp-config.php ]; then
    echo "[wordpress] wp-config.php already present"
elif [ -z "${WORDPRESS_DB_HOST:-}" ]; then
    echo "[wordpress] WARNING: no wp-config.php and WORDPRESS_DB_HOST is unset"
else
    echo "[wordpress] generating wp-config.php"

    # --skip-check because the DB may still be starting; compose depends_on
    # with a healthcheck handles ordering, but this must not be fatal either.
    wp config create \
        --dbname="${WORDPRESS_DB_NAME:-wordpress}" \
        --dbuser="${WORDPRESS_DB_USER:-wordpress}" \
        --dbpass="${WORDPRESS_DB_PASSWORD:-}" \
        --dbhost="${WORDPRESS_DB_HOST}" \
        --dbprefix="${WORDPRESS_TABLE_PREFIX:-wp_}" \
        --skip-check \
        --force

    # Behind a TLS-terminating proxy WordPress must be told its canonical URL,
    # or it derives http:// from the request and redirect-loops against
    # Cloudflare/Traefik. The nginx vhost already passes HTTPS correctly; these
    # two constants remove any remaining ambiguity.
    if [ -n "${WORDPRESS_URL:-}" ]; then
        wp config set WP_HOME    "${WORDPRESS_URL}" --type=constant
        wp config set WP_SITEURL "${WORDPRESS_URL}" --type=constant
    fi

    # Disallow in-place edits: the container filesystem is not the source of
    # truth, and anything written there is lost on the next deploy.
    wp config set DISALLOW_FILE_EDIT true --raw --type=constant
    if [ "${WORDPRESS_ALLOW_UPDATES:-false}" != "true" ]; then
        wp config set DISALLOW_FILE_MODS true --raw --type=constant
    fi

    echo "[wordpress] wp-config.php generated"
fi

# ── Salts ────────────────────────────────────────────────────────────────────
# Regenerating these on every boot would log every user out on every restart,
# so only do it once, when they are still the placeholder value.
if [ -f wp-config.php ] && grep -q "put your unique phrase here" wp-config.php 2>/dev/null; then
    echo "[wordpress] generating unique salts"
    wp config shuffle-salts 2>/dev/null || true
fi

# ── Core database install ────────────────────────────────────────────────────
# Off by default. Prefer the one-shot `install` compose service.
if [ "${WORDPRESS_RUN_INSTALL:-false}" = "true" ] && ! wp core is-installed 2>/dev/null; then
    echo "[wordpress] running core install"
    wp core install \
        --url="${WORDPRESS_URL:?WORDPRESS_URL required for install}" \
        --title="${WORDPRESS_SITE_TITLE:-WordPress}" \
        --admin_user="${WORDPRESS_ADMIN_USER:-admin}" \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD:?required}" \
        --admin_email="${WORDPRESS_ADMIN_EMAIL:?required}" \
        --skip-email
fi
