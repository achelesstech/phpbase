#!/bin/sh
# =============================================================================
# moodle-doctor.sh — diagnose Moodle-on-nginx from inside the container
# =============================================================================
#   docker compose exec app moodle-doctor.sh
#
# Moodle on nginx fails in a small number of specific, well-known ways, and
# every one of them presents as something vague: "theme is broken", "files
# won't download", "redirect loop". Apache hides most of them because
# .htaccess + mod_php handle pathinfo and X-Sendfile differently.
#
# This checks each failure mode explicitly and tells you which one you have.
# =============================================================================
set -u

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1";      pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1";      fail=$((fail+1)); }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1";      warn=$((warn+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

APP_ROOT="${APP_ROOT:-/var/www/html}"
CONFIG="${APP_ROOT}/config.php"
BASE="http://127.0.0.1:8080"

cfg() { php -r "define('CLI_SCRIPT',true); require '${CONFIG}'; \$v=\$CFG->$1 ?? null; echo is_bool(\$v)?(\$v?'true':'false'):(string)\$v;" 2>/dev/null; }

# Booleans need their own accessor. Moodle's bootstrap normalises settings, so
# a `= true` in config.php comes back out of setup.php as the string "1".
# Comparing against "true" gives a false alarm on a correctly configured site.
cfgbool() { php -r "define('CLI_SCRIPT',true); require '${CONFIG}'; echo empty(\$CFG->$1) ? 'false' : 'true';" 2>/dev/null; }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

# nginx location blocks span multiple lines, so grep cannot see inside one.
# Extract the block, then test it. Uses index() rather than an interpolated
# regex — the paths we search for contain slashes, which would terminate an
# awk regex literal.
nginx_block() {
    awk -v pat="$1" '
        index($0, "location") && index($0, pat) { inblock = 1 }
        inblock                                 { print }
        inblock && /^[[:space:]]*}/             { inblock = 0 }
    ' /etc/nginx/conf.d/vhost.conf
}

# -----------------------------------------------------------------------------
head_ "layout"
if [ -f /etc/moodle-layout ]; then
    sed 's/^/        /' /etc/moodle-layout
    . /etc/moodle-layout
else
    note "/etc/moodle-layout missing — built outside the template?"
    docroot="${APP_ROOT}"
fi

NGINX_ROOT="$(sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' /etc/nginx/conf.d/vhost.conf | head -1)"
if [ "$NGINX_ROOT" = "${docroot:-}" ]; then
    ok "nginx root matches the detected Moodle docroot (${NGINX_ROOT})"
else
    bad "nginx root is '${NGINX_ROOT}' but Moodle's docroot is '${docroot:-?}'"
    echo "        → this is the #1 cause of a blank page or sitewide 404"
fi

# -----------------------------------------------------------------------------
head_ "config.php"
if [ ! -f "$CONFIG" ]; then
    bad "no config.php — set MOODLE_DB_HOST and restart, or run the installer"
else
    php -l "$CONFIG" >/dev/null 2>&1 \
        && ok "config.php parses" \
        || bad "config.php has a PHP syntax error (run: php -l $CONFIG)"

    WWWROOT="$(cfg wwwroot)"
    DATAROOT="$(cfg dataroot)"
    SSLPROXY="$(cfgbool sslproxy)"
    XSENDFILE="$(cfg xsendfile)"

    echo "        wwwroot=${WWWROOT}"

    case "$WWWROOT" in
        */) bad "wwwroot has a trailing slash — Moodle requires none" ;;
        *)  ok "wwwroot has no trailing slash" ;;
    esac

    case "$WWWROOT" in
        https://*)
            if [ "$SSLPROXY" = "true" ]; then
                ok "https wwwroot with \$CFG->sslproxy = true"
            else
                bad "https wwwroot but \$CFG->sslproxy is not true"
                echo "        → behind Traefik/Cloudflare this is an infinite redirect loop"
            fi ;;
        http://*)
            [ "$SSLPROXY" = "true" ] \
                && note "http wwwroot but sslproxy=true — mismatched, expect odd redirects" \
                || ok "http wwwroot, sslproxy off (local dev)" ;;
    esac

    case "$DATAROOT" in
        "${docroot:-/var/www/html}"/*) bad "dataroot is INSIDE the web root — user files are publicly downloadable" ;;
        "") bad "dataroot unset" ;;
        *)  ok "dataroot is outside the web root (${DATAROOT})" ;;
    esac

    if [ -w "$DATAROOT" ]; then ok "dataroot is writable"; else bad "dataroot is NOT writable by $(id -un)"; fi
fi

# -----------------------------------------------------------------------------
head_ "X-Accel-Redirect (the 'theme and files are broken' failure)"
if [ "${XSENDFILE:-}" = "X-Accel-Redirect" ]; then
    ALIAS="$(sed -n '/location \^\?~\? *\/dataroot\//,/}/s/^[[:space:]]*alias[[:space:]]\{1,\}\([^;]*\);.*/\1/p' /etc/nginx/conf.d/vhost.conf | head -1)"
    if [ -n "$ALIAS" ]; then
        ok "nginx has a /dataroot/ location (alias ${ALIAS})"
        case "$ALIAS" in
            */) ok "alias ends in a slash (required)" ;;
            *)  bad "alias must end with a trailing slash or paths concatenate wrongly" ;;
        esac
        grep -qE 'location[[:space:]]+\^~[[:space:]]*/dataroot/' /etc/nginx/conf.d/vhost.conf \
            && ok "/dataroot/ uses ^~ (beats the static-asset regex)" \
            || bad "/dataroot/ is a plain prefix — the static-asset REGEX wins the
        internal redirect and every css/image served via xsendfile 404s.
        THIS is usually what 'Moodle theme is missing' means. Add ^~."
        nginx_block '/dataroot/' | grep -qE '^[[:space:]]*internal[[:space:]]*;' \
            && ok "/dataroot/ is marked internal (not client-reachable)" \
            || bad "/dataroot/ is NOT internal — moodledata is downloadable by anyone"
        [ "${ALIAS%/}" = "${DATAROOT%/}" ] \
            && ok "nginx alias matches \$CFG->dataroot" \
            || bad "alias '${ALIAS}' != dataroot '${DATAROOT}'"
    else
        bad "xsendfile is on but nginx has no /dataroot/ location — all file downloads 404"
    fi
else
    note "xsendfile not enabled — files are streamed through PHP (slower, works)"
fi

# -----------------------------------------------------------------------------
head_ "live request checks"
c="$(code "${BASE}/fpm-ping")"
[ "$c" = "200" ] && ok "/fpm-ping 200 (PHP-FPM reachable)" || bad "/fpm-ping returned ${c}"

c="$(code "${BASE}/")"
case "$c" in
    200|30*) ok "GET / returned ${c}" ;;
    *)       bad "GET / returned ${c} — check 'docker compose logs app'" ;;
esac

# Slasharguments. This is the single most common Moodle-on-nginx breakage: the
# PHP location must match .php WITH a path suffix and pass PATH_INFO through.
# If this 404s, pluginfile downloads and theme CSS both die.
c="$(code "${BASE}/theme/styles.php/boost/1/all")"
case "$c" in
    200|30*|40[34]) ok "slashargument URL reached PHP (styles.php/... -> ${c})" ;;
    404) bad "slashargument URL 404s — nginx is not passing PATH_INFO.
        Check: location ~ \\.php(/|\$) must come BEFORE the static-asset regex,
        and \$path_info must be saved before try_files and re-applied after
        'include fastcgi_params'." ;;
    *)   note "styles.php/... returned ${c}" ;;
esac

c="$(code "${BASE}/lib/requirejs.php/1/all.js")"
case "$c" in
    404) bad "requirejs.php/....js 404s — the static-asset regex is matching the
        .js suffix and trying to serve it from disk. Move the PHP location
        ABOVE the static-asset location." ;;
    *)   ok "requirejs.php/....js reached PHP (${c})" ;;
esac

if [ "${router:-}" = "present" ]; then
    ROUTERCFG="$(cfgbool routerconfigured)"
    [ "$ROUTERCFG" = "true" ] \
        && ok "r.php present and \$CFG->routerconfigured = true" \
        || bad "r.php exists but \$CFG->routerconfigured is not true — the vhost
        falls back to /r.php and Moodle will refuse to dispatch"
fi

# -----------------------------------------------------------------------------
head_ "reverse proxy"
FWD="$(curl -s --max-time 10 -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.9' \
       -o /dev/null -w '%{http_code}' "${BASE}/" || true)"
ok "forwarded-header request returned ${FWD}"
echo "        (nginx maps X-Forwarded-Proto -> HTTPS and X-Forwarded-For -> REMOTE_ADDR;"
echo "         Traefik must be the component that strips/sets these from clients)"

# -----------------------------------------------------------------------------
head_ "cron"
if pgrep -f 'cron.php|moodle-cron' >/dev/null 2>&1; then
    ok "a cron runner is active in this container"
else
    note "no cron in THIS container — expected if you use the cron sidecar.
        Verify with: docker compose ps cron
        Moodle silently stops processing tasks without cron every minute."
fi

# -----------------------------------------------------------------------------
printf '\n'
printf '%s passed, %s warnings, %s failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
