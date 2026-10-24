# shellcheck shell=bash
# =============================================================================
# upstream.sh — decide whether a published line needs a rebuild
# =============================================================================
#   . scripts/lib/upstream.sh
#   rebuild_reason PHP_NOW PHP_LABEL ALPINE_NOW ALPINE_LABEL PENDING
#
#   PHP_NOW       current digest of php:<line>-fpm-alpine
#   PHP_LABEL     the published image's ….upstream-digest label
#   ALPINE_NOW    current digest of alpine:<minor>
#   ALPINE_LABEL  the published image's org.opencontainers.image.base.digest
#   PENDING       how many packages `apk upgrade --simulate` would upgrade
#
# Prints the first reason that applies, in this order, or nothing:
#   php-image     the upstream PHP image moved
#   alpine-image  the Alpine base image moved
#   apk-upgrades  the published image has packages to upgrade
# A missing (empty) label never equals a digest, so it reads as "moved".
# =============================================================================

rebuild_reason() {
    local php_now="$1" php_label="$2" alpine_now="$3" alpine_label="$4" pending="$5"

    if [[ "$php_now" != "$php_label" ]]; then
        echo php-image
    elif [[ "$alpine_now" != "$alpine_label" ]]; then
        echo alpine-image
    elif (( pending > 0 )); then
        echo apk-upgrades
    fi
}
