# =============================================================================
# Moodle 5.1+ vhost — docroot is Moodle's /public directory (5.1 restructure:
# config.php, and non-web code live OUTSIDE the served root).
# Rendered at runtime by docker-entrypoint.sh — placeholders: @DOCROOT@ etc.
# Plain HTTP :8080 — TLS terminates at the external Traefik proxy
# (set MOODLE_SSLPROXY=true so $CFG->sslproxy is written to config.php).
#
# Based on the official Moodle 5.1+ nginx config (docs.moodle.org/Nginx):
#   * No try_files in the PHP handler — it interferes with fastcgi_split_path_info
#   * location / falls back to r.php (Moodle's routing engine, compulsory 5.1+)
#   * PHP location is ordered BEFORE the static-assets regex, so URLs like
#     /lib/requirejs.php/1/all.js are executed, not treated as static .js
# Requires: $CFG->routerconfigured = true; in config.php (set by entrypoint hook)
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

    # ── Dot-files, VCS, backups ──
    location ~ /\.well-known/ { allow all; }
    location ~ (^|/)\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    location ~* \.(bak|sql|dist|lock|log)$ {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Moodle internal directories that must not be web-served even if a
    # pre-5.1 tree is mounted (harmless with the 5.1 /public layout)
    location ~ ^/(vendor|node_modules|behat|phpunit)/ {
        deny all;
        return 404;
    }

    # ── PHP handler — MUST come before the static-assets regex ──
    # Matches both plain scripts and slashargument URLs:
    #   /pluginfile.php/123/mod_folder/content/0/report.pdf
    #   /theme/styles.php/boost/1700000000_1/all
    #   /lib/requirejs.php/1/all.js
    # No try_files here — it runs before fastcgi_split_path_info materializes
    # and 404s slashargument URLs. The Moodle router (r.php) handles missing
    # scripts gracefully. (docs.moodle.org/Nginx)
    location ~ \.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.*)$;

        fastcgi_pass  127.0.0.1:9000;
        fastcgi_index index.php;

        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO       $fastcgi_path_info;
        include       fastcgi_params;

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
    location /dataroot/ {
        internal;
        alias /var/moodledata/;
    }

    # ── Front controller — Moodle 5.1+ routing engine ──
    # r.php is Moodle's router (compulsory from 5.1). Non-file URLs fall
    # through to r.php which dispatches to the correct controller.
    # Requires $CFG->routerconfigured = true; in config.php.
    location / {
        try_files $uri $uri/ /r.php$is_args$args;
    }
}
