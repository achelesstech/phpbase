#!/usr/bin/env bash
# =============================================================================
# test/scripts/docs.test.sh — the operator docs cover what they promise
# =============================================================================
#   bash test/scripts/docs.test.sh
#
#   * docs/migrating-from-v1.md names every breaking change, and is the file
#     the entrypoint's supervisord error points to;
#   * docs/publishing.md covers the secrets, signing, the watcher, Renovate
#     and the public repository;
#   * docs/reverse-proxy.md covers the resolvers, the keep-alive pair, cert
#     expiry, the /tmp tmpfs and Moodle's client-address setting;
#   * CHANGELOG.md has a v2 entry with its breaking changes, and points at no
#     file the repository does not track;
#   * docs/traefik/labels.md and the examples index carry no v1 health advice;
#   * docs/README.md and examples/README.md link the new pages and every
#     example.
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

# must FILE STRING... — each string occurs in FILE.
must() {
    local file="$1" s
    shift
    if [[ ! -f "$file" ]]; then
        bad "${file} exists"
        return
    fi
    for s in "$@"; do
        if has "$file" "$s"; then ok "${file} mentions ${s}"; else bad "${file} mentions ${s}"; fi
    done
}

# must_not FILE STRING... — no string occurs in FILE.
must_not() {
    local file="$1" s
    shift
    for s in "$@"; do
        if has "$file" "$s"; then bad "${file} no longer mentions ${s}"; else ok "${file} no longer mentions ${s}"; fi
    done
}

# has_line FILE REGEX — some line of FILE matches the extended regex.
has_line() {
    local text
    text="$(cat "$1" 2>/dev/null || true)"
    [[ -n "$text" ]] || return 1
    local re="$2" line
    while IFS= read -r line; do
        [[ "$line" =~ $re ]] && return 0
    done <<<"$text"
    return 1
}

# ── docs/migrating-from-v1.md ───────────────────────────────────────────────
mig=docs/migrating-from-v1.md
must "$mig" php-base-web /etc/supervisor php-fpm.sock 8081 -dev NGINX_ACCESS_LOG NGINX_GZIP pgrep PHP_BASE_STRICT \
    supervisord SCHEDULER_COMMAND WORKER_COMMAND 'fastcgi_pass php_fpm' fastcgi-php.conf \
    php.ini-production php.ini-development HOME FarmBook HQ

# The entrypoint's supervisord error sends people to this exact file.
entry="$(cat rootfs/usr/local/bin/docker-entrypoint.sh)"
if [[ "$entry" == *"docs/migrating-from-v1.md"* && -f "$mig" ]]; then
    ok "the entrypoint's supervisord error points at an existing ${mig}"
else
    bad "the entrypoint's supervisord error points at an existing ${mig}"
fi

# ── docs/publishing.md ──────────────────────────────────────────────────────
pub=docs/publishing.md
must "$pub" DOCKERHUB_USERNAME DOCKERHUB_TOKEN 'cosign verify' watch-upstream Renovate public build-base

# ── docs/reverse-proxy.md ───────────────────────────────────────────────────
rp=docs/reverse-proxy.md
must "$rp" letsencrypt cloudflare 120s 90s traefik_tls_certs_not_after tmpfs getremoteaddrconf
# The v1 Moodle and Drupal env names are gone from the examples.
must_not "$rp" MOODLE_SSLPROXY moodle-doctor DRUPAL_REVERSE_PROXY_ADDRESSES

# ── CHANGELOG.md ────────────────────────────────────────────────────────────
cl=CHANGELOG.md
if has_line "$cl" '^## v2([^0-9.]|$)'; then ok "${cl} has a '## v2' heading"; else bad "${cl} has a '## v2' heading"; fi
if has_line "$cl" '^#+ Breaking changes'; then ok "${cl} has a 'Breaking changes' heading"; else bad "${cl} has a 'Breaking changes' heading"; fi
# A list under the heading: the next non-blank line after it is a list item.
breaking="$(awk '/^#+ Breaking changes/ { f = 1; next } f && NF { print; exit }' "$cl" 2>/dev/null || true)"
if [[ "$breaking" == "- "* || "$breaking" == "1. "* ]]; then
    ok "${cl}: 'Breaking changes' is a list"
else
    bad "${cl}: 'Breaking changes' is a list"
fi
# PROPOSAL.md and VERIFICATION.md were prototype files and were never tracked.
must_not "$cl" PROPOSAL.md VERIFICATION.md 'v2 (proposal)'

# ── v1 health advice ────────────────────────────────────────────────────────
labels=docs/traefik/labels.md
must_not "$labels" moodle52 'pgrep -f'
must "$labels" 'docker.io/achelesstech/moodle-app' heartbeat 8081
must_not examples/README.md "image's \`/fpm-ping\` check" 'pgrep -f'
for readme in examples/laravel/README.md examples/drupal/README.md examples/wordpress/README.md; do
    must_not "$readme" "healthy when \`/fpm-ping\` and" "healthy when \`/fpm-ping\` answers through"
    must "$readme" '127.0.0.1:8081'
done
# publishing.md describes renovate.json as it is: examples/** images get PRs.
must "$pub" 'examples/**' ignorePaths

# ── Indexes ─────────────────────────────────────────────────────────────────
must docs/README.md '(publishing.md)' '(migrating-from-v1.md)' '(image.md)' '(security.md)'
for ex in laravel drupal wordpress moodle traefik portainer; do
    must examples/README.md "(${ex}/)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
