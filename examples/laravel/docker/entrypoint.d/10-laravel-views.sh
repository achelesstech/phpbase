#!/bin/sh
# =============================================================================
# 10-laravel-views.sh — seed Blade's compiled-view directory (runs as www-data)
# =============================================================================
# The root filesystem is read-only, so VIEW_COMPILED_PATH (set in the
# Dockerfile) points into the /tmp tmpfs. This copies the views compiled at
# build time (`php artisan view:cache`) there, so they are not compiled again;
# Blade adds the rest on first use. The directory is emptied first: nothing a
# previous run left behind is ever included as PHP.
# =============================================================================
set -eu

dest="${VIEW_COMPILED_PATH:-}"
baked="${APP_ROOT:-/var/www/html}/storage/framework/views"
# Only a directory on /tmp is ours to empty. Unset, or pointed anywhere else
# (the baked directory itself, say): leave it alone.
case "$dest" in
    /tmp/?*) ;;
    *) exit 0 ;;
esac

rm -rf "$dest"
mkdir -p "$dest"
for view in "$baked"/*.php; do
    [ -e "$view" ] || continue
    cp -p "$view" "$dest/"
done
