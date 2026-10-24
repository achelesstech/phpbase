#!/usr/bin/env bash
# =============================================================================
# test/scripts/resolve.test.sh — scripts/resolve-matrix.sh against live data
# =============================================================================
#   bash test/scripts/resolve.test.sh
#
# Needs the network (php.net, alpinelinux.org, the registry) and Docker.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Review Focus 5: when Docker Hub cannot say whether a build tag exists, the
# resolver must stop, not guess a tag that may already be published.
if HUB_API=http://127.0.0.1:9 scripts/resolve-matrix.sh --only 8.4 >"$tmp/out" 2>"$tmp/err"; then
    bad "Hub unreachable: resolver exited 0"
elif grep -q 'cannot check existing tags on Docker Hub' "$tmp/err"; then
    ok "Hub unreachable: resolver fails with 'cannot check existing tags on Docker Hub'"
else
    bad "Hub unreachable: resolver failed, but stderr lacks the message:"
    sed 's/^/        /' "$tmp/err"
fi

# Output shape of a --local resolution.
if scripts/resolve-matrix.sh --only 8.4 --local >"$tmp/out" 2>"$tmp/err" \
    && sed -n 's/^lines=//p' "$tmp/out" | jq -e '.[0] |
        (.alpine_image | test("^alpine:3\\.[0-9]+@sha256:")) and (.alpine == (.alpine_full | split(".")[0:2] | join(".")))
        and (.tags | map(test("-alpine")) | any | not) and (.max_size_mb == 180) and (.build_tag | endswith("-local"))' >/dev/null; then
    ok "--local output: pinned alpine_image, no -alpine tags, max_size_mb 180, -local build tag"
else
    bad "--local output shape"
    sed 's/^/        /' "$tmp/err" "$tmp/out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
