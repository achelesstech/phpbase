#!/bin/sh
# =============================================================================
# healthcheck.sh — proves PHP-FPM is actually answering, not just nginx.
# =============================================================================
# A static `return 200` /healthz location is served entirely by nginx and stays
# green while PHP-FPM is dead — the container reports healthy and 502s every
# request. /fpm-ping goes through FastCGI, so it fails when FPM fails.
#
# The application vhost must define:
#
#     location = /fpm-ping {
#         access_log off;
#         allow 127.0.0.1; allow ::1; deny all;
#         fastcgi_pass 127.0.0.1:9000;
#         fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
#         include fastcgi_params;
#     }
#
# Containers that override CMD to run a worker (queue:work, cron, …) do not
# run nginx. Disable or replace this healthcheck for those services in compose.
# =============================================================================
set -eu

PORT="${HEALTHCHECK_PORT:-8080}"
PATH_="${HEALTHCHECK_PATH:-/fpm-ping}"

response="$(curl --silent --fail --max-time 4 "http://127.0.0.1:${PORT}${PATH_}" 2>/dev/null)" \
    || { echo "healthcheck: no response from 127.0.0.1:${PORT}${PATH_}" >&2; exit 1; }

case "$response" in
    *pong*) exit 0 ;;
    *)      echo "healthcheck: unexpected response: ${response}" >&2; exit 1 ;;
esac
