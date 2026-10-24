#!/usr/bin/env bash
# =============================================================================
# build-args.sh — the --build-arg list for a local build of one PHP line
# =============================================================================
#   scripts/build-args.sh 8.4            one `--build-arg K=V` per line
#   REFRESH=1 scripts/build-args.sh 8.4  resolve again instead of the cache
#   BUILD_DATE=… scripts/build-args.sh   fixed build date (default: now)
#
# Local builds get the same pinned inputs CI uses: it runs
# `scripts/resolve-matrix.sh --only LINE --local` and turns that line into
# build arguments, with the same names CI passes. The resolved line (plus the
# composer image) is cached in .cache/resolve/<LINE>-<YYYYMMDD>.json and reused
# for the rest of the UTC day, so repeated builds do not query registries.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LINE="${1:?usage: build-args.sh <php-line, e.g. 8.4>}"
DATE="$(date -u +%Y%m%d)"
CACHE=".cache/resolve/${LINE}-${DATE}.json"

if [[ "${REFRESH:-0}" == 1 || ! -s "$CACHE" ]]; then
    mkdir -p "$(dirname "$CACHE")"
    out="$(scripts/resolve-matrix.sh --only "$LINE" --include-eol --local --date "$DATE")"
    sed -n 's/^lines=//p' <<<"$out" \
        | jq -e --arg c "$(sed -n 's/^composer=//p' <<<"$out")" '.[0] + {composer: $c}' >"${CACHE}.tmp" \
        || { rm -f "${CACHE}.tmp"; echo "build-args.sh: PHP ${LINE} did not resolve" >&2; exit 1; }
    mv "${CACHE}.tmp" "$CACHE"
fi

jq -r \
    --arg date "$DATE" \
    --arg build_date "${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg vcs_ref "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" '
    [ "PHP_VERSION=\(.line)",
      "PHP_IMAGE=\(.from)",
      "ALPINE_IMAGE=\(.alpine_image)",
      "COMPOSER_IMAGE=\(.composer)",
      "UPSTREAM_IMAGE=\(.upstream)",
      "UPSTREAM_DIGEST=\(.digest)",
      "PHP_FULL_VERSION=\(.php_version)",
      "ALPINE_FULL_VERSION=\(.alpine_full)",
      "BASE_NAME=docker.io/library/alpine:\(.alpine)",
      "BASE_DIGEST=\(.alpine_digest)",
      "BASE_VERSION=\(.php_version)-local",
      "PKG_CACHE_BUST=\($date)",
      "BUILD_DATE=\($build_date)",
      "VCS_REF=\($vcs_ref)",
      "ALLOW_MISSING_DEV_EXTENSIONS=\(if .prerelease then 1 else 0 end)",
      "SOURCE_URL=https://github.com/achelesstech/phpbase"
    ] | .[] | "--build-arg " + .' "$CACHE"
