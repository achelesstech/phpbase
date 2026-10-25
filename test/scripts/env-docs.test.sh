#!/usr/bin/env bash
# =============================================================================
# test/scripts/env-docs.test.sh — the docs name every setting the image reads
# =============================================================================
#   bash test/scripts/env-docs.test.sh
#
#   * every PHP_*, FPM_*, NGINX_*, HEALTHCHECK_*, SCHEDULER_*, WORKER_*,
#     PHP_BASE_* and XDEBUG_* name in rootfs/usr/local/bin/* appears in
#     docs/image.md, as a whole word (PHP_OPCACHE_ENABLE_CLI does not count
#     for PHP_OPCACHE_ENABLE);
#   * README.md shows the tag examples.
#
# Reads the files only: no network, no Docker.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# has FILE STRING — the fixed string occurs in FILE (captured, then matched,
# so no pipefail pipe ends in grep -q).
has() {
    local text
    text="$(cat "$1" 2>/dev/null || true)"
    [[ "$text" == *"$2"* ]]
}

doc=docs/image.md
names="$(grep -ohE '\b(PHP|FPM|NGINX|HEALTHCHECK|SCHEDULER|WORKER|PHP_BASE|XDEBUG)_[A-Z_]+' \
    rootfs/usr/local/bin/* | sort -u)"
[[ -n "$names" ]] || { echo "no variable names found in rootfs/usr/local/bin/*" >&2; exit 1; }

documented="$(grep -ohE '\b[A-Z][A-Z0-9_]*\b' "$doc" 2>/dev/null | sort -u || true)"
missing=0
while IFS= read -r name; do
    if [[ $'\n'"$documented"$'\n' != *$'\n'"$name"$'\n'* ]]; then
        bad "${doc} documents ${name}"
        missing=$((missing + 1))
    fi
done <<<"$names"
[[ "$missing" -gt 0 ]] || ok "${doc} documents all $(wc -l <<<"$names") variables the scripts read"

for tag in achelesstech/php-base:8.4 :8.4.27-20261026 :8.4-dev :latest; do
    if has README.md "$tag"; then ok "README.md shows ${tag}"; else bad "README.md shows ${tag}"; fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
