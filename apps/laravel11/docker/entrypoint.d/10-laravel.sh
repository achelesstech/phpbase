#!/bin/sh
# =============================================================================
# 10-laravel.sh — runs as www-data at container start
# =============================================================================
# Deliberately minimal. view:cache / event:cache / the optimized autoloader are
# baked into the image at build time; doing them here would race across the
# app, queue and scheduler containers and add seconds to every cold start.
#
# Only two things genuinely cannot be done at build time:
#   * creating writable dirs, because volumes are mounted after the image
#   * config:cache, because it must capture the RUNTIME environment
# =============================================================================
set -eu

cd "${APP_ROOT:-/var/www/html}"

# ── Writable directories ─────────────────────────────────────────────────────
for dir in \
    storage/app/public \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache
do
    mkdir -p "$dir"
done

# We run as www-data. chown/chmod succeed on image-owned files and fail on a
# bind mount owned by another uid — which must never abort startup.
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R u+rwX,g+rwX       storage bootstrap/cache 2>/dev/null || true

# Idempotent; a no-op when the public disk isn't configured.
php artisan storage:link 2>/dev/null || true

# ── Runtime config cache ─────────────────────────────────────────────────────
# Only the app container should write these. Workers set LARAVEL_SKIP_CACHE=1
# so they never race the app over the same files.
if [ "${LARAVEL_SKIP_CACHE:-0}" = "1" ]; then
    echo "[laravel] LARAVEL_SKIP_CACHE=1 — leaving caches alone"
elif [ "${APP_ENV:-production}" = "production" ]; then
    echo "[laravel] caching config and routes"
    php artisan config:cache
    # route:cache hard-fails on closure routes. That is a valid app design, so
    # warn and continue uncached rather than refusing to boot.
    php artisan route:cache \
        || echo "[laravel] WARNING: route:cache failed (closure routes?) — continuing uncached"
else
    php artisan config:clear || true
    php artisan route:clear  || true
fi

# ── Migrations ───────────────────────────────────────────────────────────────
# Off by default. Running migrations from every replica's entrypoint is how you
# get concurrent schema changes. Prefer the one-shot `migrate` compose service.
if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    echo "[laravel] running migrations"
    php artisan migrate --force --isolated || php artisan migrate --force
fi
