# =============================================================================
# Moodle 5.1/5.2+ vhost — docroot is Moodle's /public directory (5.1+
# restructure: config.php and non-web code live OUTSIDE the served root).
# Rendered at runtime by docker-entrypoint.sh — placeholders: @DOCROOT@ etc.
# Plain HTTP :8080 — TLS terminates at the external Traefik proxy
# (set MOODLE_SSLPROXY=true so $CFG->sslproxy is written to config.php).
#
# Matches the official Moodle nginx config (docs.moodle.org/502/en/Nginx):
#   * PHP handler saves $fastcgi_path_info BEFORE try_files (try_files wipes
#     it), then try_files falls back to r.php — missing scripts route through
#     the Routing Engine instead of FPM's "File not found"
#   * SCRIPT_FILENAME/DOCUMENT_ROOT use $realpath_root (symlink-safe)
#   * PHP location ordered BEFORE the static-assets regex, so
#     /lib/requirejs.php/1/all.js and /theme/styles.php/... are executed
#   * /dataroot/ uses `^~` — CRITICAL: X-Accel-Redirect performs an internal
#     redirect that re-runs location matching; without ^~ the static-assets
#     REGEX location wins over this plain prefix and every xsendfile-served
#     .css/.png/.jpg 404s against the docroot (== "theme assets missing")
#   * MDL-69333 internal-file deny list
# Requires: $CFG->routerconfigured = true; in config.php (set by entrypoint)
# =============================================================================
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_name _;

    root  @DOCROOT@;
    index index.php;

    server_tokens off;
    client_max_body_size @CLIENT_MAX_BODY_SIZE@;

    # ── Security headers ──
    # Deliberately NO X-Frame-Options: Moodle needs framing for LTI and filters.
    # (Any add_header here replaces inherited http-level add_header directives.)
    add_header X-Content-Type-Options "nosniff"                         always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;

    # ── Health probes ──
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    location = /fpm-ping {
        access_log off;
        allow 127.0.0.1;
        deny  all;
        fastcgi_pass  127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include       fastcgi_params;
    }

    location = /fpm-status {
        access_log off;
        allow 127.0.0.1;
        deny  all;
        fastcgi_pass  127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include       fastcgi_params;
    }

    # ── Dot-files (allow "Well-Known URIs" per RFC 5785) ──
    location ~ /\.(?!well-known).* {
        return 404;
    }

    # ── Internal files that must never be web-served (MDL-69333) ──
    location ~ (/vendor/|/node_modules/|composer\.json|/readme|/README|readme\.txt|/upgrade\.txt|/UPGRADING\.md|db/install\.xml|/fixtures/|/behat/|phpunit\.xml|\.lock|environment\.xml|\.(bak|sql|dist|log)$) {
        deny all;
        return 404;
    }

    # ── PHP handler — official Moodle 4.5+ FastCGI config ──
    # MUST come before the static-assets regex. Matches plain scripts and
    # slashargument URLs:
    #   /pluginfile.php/123/mod_folder/content/0/report.pdf
    #   /theme/styles.php/boost/1700000000_1/all
    #   /lib/requirejs.php/1/all.js
    location ~ \.php(/|$) {
        # Split the path info based on URI.
        fastcgi_split_path_info ^(.+\.php)(/.*)$;

        # Store the original path_info — try_files wipes it in a moment.
        set $path_info $fastcgi_path_info;

        # Look for the php file; fall back to the router (r.php).
        try_files $fastcgi_script_name $fastcgi_script_name/ /r.php$is_args$args;

        fastcgi_pass  127.0.0.1:9000;
        fastcgi_index index.php;
        include       fastcgi_params;

        # Re-apply path_info after including fastcgi_params.
        fastcgi_param PATH_INFO       $path_info;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT   $realpath_root;

        # Reverse-proxy scheme awareness (Traefik terminates TLS)
        fastcgi_param HTTPS $fcgi_https;

        fastcgi_read_timeout      @FASTCGI_READ_TIMEOUT@;
        fastcgi_buffer_size       128k;
        fastcgi_buffers           4 256k;
        fastcgi_busy_buffers_size 256k;

        fastcgi_param HTTP_PROXY "";
    }

    # ── Static assets (real files only; php-with-pathinfo already handled) ──
    location ~* \.(jpg|jpeg|gif|png|webp|avif|css|js|ico|woff|woff2|ttf|eot|svg|map)$ {
        expires    1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files  $uri =404;
    }

    # ── X-Accel-Redirect: nginx serves moodledata files instead of PHP ──
    # Pairs with $CFG->xsendfile = 'X-Accel-Redirect' in config.php.
    # `^~` is REQUIRED: the internal redirect re-matches locations, and a
    # plain prefix loses to the static-assets regex above — which try_files
    # against the docroot and 404s every CSS/image styles.php/image.php/
    # pluginfile.php hands off. `internal` prevents client access to dataroot.
    location ^~ /dataroot/ {
        internal;
        alias /var/moodledata/;   # must end with /
    }

    # ── Front controller — Moodle 5.1+ Routing Engine ──
    # r.php dispatches non-file URLs (requires $CFG->routerconfigured = true).
    location / {
        try_files $uri $uri/ /r.php$is_args$args;
    }
}
