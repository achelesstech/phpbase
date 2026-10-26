#!/usr/bin/env bash
# =============================================================================
# test/scripts/registry.test.sh — every manifest read goes through registry.sh
# =============================================================================
#   bash test/scripts/registry.test.sh
#
# Docker Hub counts every manifest it serves as a pull, and `--format` on an
# index fetches the manifest of every platform in it: 9 pulls for one
# php:X.Y-fpm-alpine lookup, against 1 for each call in scripts/lib/registry.sh.
# So no other tracked code calls that command. Prose (Markdown, comment lines)
# may name it. No network, no Docker.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

callers="$(git grep -nE 'imagetools[[:space:]]+inspect' -- ':!*.md' ':!scripts/lib/registry.sh' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$callers" ]]; then
    printf '  ok    only scripts/lib/registry.sh reads manifests\n'
else
    printf '  FAIL  manifest reads outside scripts/lib/registry.sh (a pull per platform on an index):\n'
    sed 's/^/        /' <<<"$callers"
    exit 1
fi
