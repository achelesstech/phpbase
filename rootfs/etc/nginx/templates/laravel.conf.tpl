# =============================================================================
# Laravel vhost (alias of the generic front-controller template)
# Rendered at runtime by docker-entrypoint.sh — placeholders: @DOCROOT@ etc.
# Plain HTTP :8080 — TLS terminates at the external Traefik proxy.
# =============================================================================
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_name _;

    root  @DOCROOT@;
    index index.php index.html;

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

    # Restricted by default — loosen deliberately if you scrape it.
    location = /fpm-status {
        access_log off;
        allow 127.0.0.1;
        deny  all;
        fastcgi_pass  127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include       fastcgi_params;
    }

    # ── Static assets ──
    location ~* \.(jpg|jpeg|gif|png|webp|avif|css|js|ico|woff|woff2|ttf|eot|svg|map)$ {
        expires    1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files  $uri =404;
    }

    # ── PHP handler ──
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
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

        # Security: prevent httpoxy
        fastcgi_param HTTP_PROXY "";
    }

    # ── Front controller (framework routing) ──
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # ── Deny dot-files (allow ACME/.well-known just in case) ──
    location ~ /\.well-known/ {
        allow all;
    }
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # ── Deny sensitive files ──
    location ~* \.(env|log|ini|bak|sql|dist|lock)$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
