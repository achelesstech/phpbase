#!/bin/sh
# Kept for app Dockerfiles written against the previous base: it now validates
# php-fpm as well as nginx. See php-base-validate.
exec /usr/local/bin/php-base-validate "$@"
