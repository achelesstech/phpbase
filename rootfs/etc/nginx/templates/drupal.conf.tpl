# =============================================================================
# Drupal 10/11 vhost — docroot is the composer project's web/ directory
# Rendered at runtime by docker-entrypoint.sh — placeholders: @DOCROOT@ etc.
# Plain HTTP :8080 — TLS terminates at the external Traefik proxy.
#
# Fixes vs the old generic vhost:
#   * image styles (/sites/*/files/styles/) fall back to index.php so
#     derivatives are generated on first request instead of returning 404
#   * PHP execution is DENIED inside sites/*/files (upload RCE hardening)
#   * /update.php with path info works
#   * private file paths (/system/files/) route through Drupal
# =============================================================================
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_name _;

    root  @DOCROOT@;
    index index.php;

    server_tokens off;
    client_max_body_size @CLIENT_MAX_BODY_SIZE@;

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

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }

    # ── Security: never execute PHP from user-upload directories ──
    location ~ ^/sites/[^/]+/files/.*\.php$ {
        deny all;
        return 404;
    }

    # Raw access to private file storage is forbidden (served via Drupal)
    location ~ ^/sites/.*/private/ {
        return 403;
    }

    # Composer/vendor and project metadata must never be reachable
    location ~* ^/(vendor|core/tests|composer\.(json|lock))($|/) {
        deny all;
        return 404;
    }

    # ── Dot-files (allow .well-known) ──
    location ~ /\.well-known/ { allow all; }
    location ~ (^|/)\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # ── Image styles: generate derivative on first request via Drupal ──
    # MUST come before the generic static-assets block below.
    location ~ ^/sites/.*/files/styles/ {
        try_files $uri @rewrite;
    }

    # Private files served through Drupal (with optional language prefix)
    location ~ ^(/[a-z\-]+)?/system/files/ {
        try_files $uri /index.php?$query_string;
    }

    # ── Static assets ──
    location ~* \.(jpg|jpeg|gif|png|webp|avif|css|js|ico|woff|woff2|ttf|eot|svg|map)$ {
        expires    1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files  $uri @rewrite;
    }

    # ── PHP handler (index.php, update.php with path info, core scripts) ──
    location ~ '\.php$|^/update.php' {
        fastcgi_split_path_info ^(.+?\.php)(|/.*)$;
        # try_files runs before fastcgi_split_path_info materializes, so
        # $fastcgi_script_name still equals the full $uri. Use set+if instead.
        set $script_path $document_root$fastcgi_script_name;
        if (!-f $script_path) { return 404; }

        fastcgi_pass  127.0.0.1:9000;
        fastcgi_index index.php;

        fastcgi_param SCRIPT_FILENAME $script_path;
        fastcgi_param PATH_INFO       $fastcgi_path_info;
        fastcgi_param QUERY_STRING    $query_string;
        include       fastcgi_params;

        # Reverse-proxy scheme awareness (Traefik terminates TLS)
        fastcgi_param HTTPS $fcgi_https;

        fastcgi_intercept_errors  on;
        fastcgi_read_timeout      @FASTCGI_READ_TIMEOUT@;
        fastcgi_buffer_size       128k;
        fastcgi_buffers           4 256k;
        fastcgi_busy_buffers_size 256k;

        fastcgi_param HTTP_PROXY "";
    }

    location @rewrite {
        rewrite ^ /index.php;
    }

    # ── Front controller ──
    location / {
        try_files $uri /index.php?$query_string;
    }
}
