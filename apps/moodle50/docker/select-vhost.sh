#!/bin/sh
# =============================================================================
# select-vhost.sh — install the vhost that matches the downloaded Moodle tree
# =============================================================================
# Run at BUILD time, after the tarball is extracted. Detects the layout instead
# of assuming it, so the same template works across 5.0, 5.2 and 5.3 without
# anyone having to remember which release moved the docroot.
#
# Moodle's "public directory" restructure moves all web-served code into
# public/ and leaves config.php outside it. Which release that landed in — and
# whether a given branch has it — is exactly the kind of fact that goes stale,
# so this looks at the actual files.
#
# The result is still a STATIC vhost: chosen once at build time, validated by
# nginx-validate.sh, never re-rendered at container start.
# =============================================================================
set -eu

APP_ROOT="${1:-/var/www/html}"
SRC_DIR="${2:-/tmp/vhosts}"
DEST="/etc/nginx/conf.d/vhost.conf"

echo "── Moodle layout detection ──"

if [ -f "${APP_ROOT}/public/index.php" ]; then
    LAYOUT="public"
    DOCROOT="${APP_ROOT}/public"
else
    LAYOUT="legacy"
    DOCROOT="${APP_ROOT}"
fi

# The Routing Engine (r.php) is a separate axis from the docroot move.
if [ -f "${DOCROOT}/r.php" ]; then
    ROUTER="present"
else
    ROUTER="absent"
fi

echo "   layout : ${LAYOUT}"
echo "   docroot: ${DOCROOT}"
echo "   r.php  : ${ROUTER}"

if [ "$LAYOUT" = "public" ]; then
    cp "${SRC_DIR}/vhost-public.conf" "$DEST"
else
    cp "${SRC_DIR}/vhost-legacy.conf" "$DEST"
fi

# The public vhost falls back to /r.php. If the router is missing, that
# fallback silently turns every unmatched URL into a 404 that looks like a
# routing bug. Catch the mismatch at build time instead.
if [ "$LAYOUT" = "public" ] && [ "$ROUTER" = "absent" ]; then
    echo "   WARNING: public/ layout but no r.php — rewriting the front"
    echo "            controller fallback to index.php"
    sed -i 's#/r\.php\$is_args\$args#/index.php$is_args$args#g' "$DEST"
    ROUTER="absent (fallback rewritten to index.php)"
fi

# Record what was chosen. During an incident this is the first thing to check.
cat > /etc/moodle-layout <<EOF
layout=${LAYOUT}
docroot=${DOCROOT}
router=${ROUTER}
EOF

echo "   installed: $(basename "$([ "$LAYOUT" = public ] && echo vhost-public.conf || echo vhost-legacy.conf)") -> ${DEST}"
