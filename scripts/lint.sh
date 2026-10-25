#!/usr/bin/env bash
# =============================================================================
# lint.sh — every static check for the base image and the examples
# =============================================================================
#   scripts/lint.sh          (make lint; .github/workflows/lint.yml runs this)
#
# Prints one line per check (ok / FAIL / warn), with the tool's output indented
# under a failure, and exits 0 only if every check passed. The linters run in
# containers pinned by tag and digest, so a laptop and CI get the same verdict.
#
#   hadolint        every git-tracked Dockerfile, with the nearest .hadolint.yaml
#                   (an example's own, else the repository's)
#   ShellCheck sh   rootfs/usr/local/bin/* and the s6 scripts (run, finish,
#                   fail-fast, .s6-svscan/*)
#   ShellCheck bash scripts/**/*.sh, test/**/*.sh, examples/**/*.sh — except a
#                   file with a POSIX sh shebang (it runs in the container's
#                   busybox ash), which is checked as sh
#   actionlint      .github/workflows/*.yml, examples/*/.github/workflows/*.yml
#   compose         `docker compose config -q` for every examples/**/compose*.yml,
#                   with its directory's .env.example
#   traefik         make -C examples/traefik check (boots Traefik, removes it)
#   links           scripts/check-links.sh
#   unit tests      bash test/scripts/*.test.sh, one line each; resolve and
#                   workflow need the network (php.net, Docker Hub)
#   cloudflare      scripts/update-cloudflare-ips.sh --check: a warning, never
#                   a failure (who nginx trusts changes only through a PR)
#
# File lists come from `git ls-files`, so new files are picked up and ignored
# ones (.work/, .cache/) never are.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

HADOLINT=hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
SHELLCHECK=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
ACTIONLINT=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

failed=0

# run_check <label> <command…>: one line, plus the command's output on failure.
run_check() {
    local label="$1" out
    shift
    if out="$("$@" 2>&1)"; then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n' "$label"
        sed 's/^/      /' <<<"$out"
        failed=$((failed + 1))
    fi
}

tracked() { git ls-files -z -- "$@"; }

# Every file list here must be non-empty: zero files means a moved directory
# or a broken pathspec, and must not read as `ok`.
some_files() {   # some_files <file…>
    [[ "$#" -gt 0 ]] || { echo "no files matched: the file list is empty"; return 1; }
}

# --- hadolint ----------------------------------------------------------------
# The nearest .hadolint.yaml at or above the Dockerfile's directory.
hadolint_config() {
    local dir
    dir="$(dirname "$1")"
    while [[ "$dir" != "." && ! -f "$dir/.hadolint.yaml" ]]; do dir="$(dirname "$dir")"; done
    echo "$dir/.hadolint.yaml"
}
hadolint_all() {
    local f status=0
    some_files "$@" || return 1
    for f in "$@"; do
        echo "== $f ($(hadolint_config "$f"))"
        docker run --rm -v "$PWD:/src:ro" -w /src "$HADOLINT" \
            hadolint --no-color --config "$(hadolint_config "$f")" "$f" || status=1
    done
    return "$status"
}
mapfile -d '' dockerfiles < <(tracked 'Dockerfile' '*/Dockerfile')
run_check "hadolint (${#dockerfiles[@]} Dockerfiles)" hadolint_all "${dockerfiles[@]}"

# --- shellcheck --------------------------------------------------------------
run_shellcheck() {   # run_shellcheck <sh|bash> <file…>
    local shell="$1"
    shift
    some_files "$@" || return 1
    docker run --rm -v "$PWD:/src:ro" -w /src "$SHELLCHECK" -S warning -x -s "$shell" "$@"
}

sh_files=()
while IFS= read -r -d '' f; do
    # Symlinks (s6 finish -> ../fail-fast) are checked through their target.
    if [[ -f "$f" && ! -L "$f" ]]; then sh_files+=("$f"); fi
done < <(tracked 'rootfs/usr/local/bin/*' \
    'rootfs/etc/php-base/s6/*/run' 'rootfs/etc/php-base/s6/*/finish' \
    'rootfs/etc/php-base/s6/fail-fast' 'rootfs/etc/php-base/s6/.s6-svscan/*')

bash_files=()
while IFS= read -r -d '' f; do
    # git pathspec `*` crosses directories, so these are the ** globs.
    # A POSIX-sh shebang means busybox ash in the container: check it as sh.
    if [[ "$(head -n1 "$f")" =~ ^'#!'(/bin/sh|/usr/bin/env\ sh)([[:space:]]|$) ]]; then
        sh_files+=("$f")
    else
        bash_files+=("$f")
    fi
done < <(tracked 'scripts/*.sh' 'test/*.sh' 'examples/*.sh')

run_check "shellcheck -s sh (${#sh_files[@]} files)" run_shellcheck sh "${sh_files[@]}"
run_check "shellcheck -s bash (${#bash_files[@]} files)" run_shellcheck bash "${bash_files[@]}"

# --- actionlint --------------------------------------------------------------
mapfile -d '' workflows < <(tracked '.github/workflows/*.yml' 'examples/*/.github/workflows/*.yml')
actionlint_all() {
    some_files "$@" || return 1
    docker run --rm -v "$PWD:/repo:ro" -w /repo "$ACTIONLINT" -no-color "$@"
}
run_check "actionlint (${#workflows[@]} workflows)" actionlint_all "${workflows[@]}"

# --- compose -----------------------------------------------------------------
# A value .env.example leaves empty ON PURPOSE because it differs per host
# (compose refuses to start until it is set) gets a placeholder here, for the
# parse only. Everything else must come from .env.example as committed.
host_specific() {   # host_specific <compose file>  -> NAME=value lines
    case "$1" in
        examples/traefik/*) echo "DOCKER_GID=999" ;;   # `make init` fills it in
    esac
}
compose_all() {
    local f env status=0 vars
    some_files "$@" || return 1
    for f in "$@"; do
        env="$(dirname "$f")/.env.example"
        mapfile -t vars < <(host_specific "$f")
        echo "== $f"
        if [[ -f "$env" ]]; then
            env "${vars[@]}" docker compose --env-file "$env" -f "$f" config -q || status=1
        else
            env "${vars[@]}" docker compose -f "$f" config -q || status=1
        fi
    done
    return "$status"
}
mapfile -d '' composefiles < <(tracked 'examples/*compose*.yml')
run_check "docker compose config (${#composefiles[@]} files)" compose_all "${composefiles[@]}"

# --- Traefik, links, unit tests ----------------------------------------------
run_check "traefik check-config (make -C examples/traefik check)" make -s -C examples/traefik check
run_check "links (scripts/check-links.sh)" scripts/check-links.sh

mapfile -d '' unit_tests < <(tracked 'test/scripts/*.test.sh')
if [[ "${#unit_tests[@]}" -eq 0 ]]; then run_check "unit tests (test/scripts/*.test.sh)" some_files; fi
for t in "${unit_tests[@]}"; do
    run_check "unit test $t" bash "$t"
done

# --- Cloudflare: warn only ---------------------------------------------------
if out="$(scripts/update-cloudflare-ips.sh --check 2>&1)"; then
    printf 'ok    cloudflare ranges (%s)\n' "$out"
else
    printf 'warn  cloudflare ranges: not current, or not fetched (never fails lint)\n'
    sed 's/^/      /' <<<"$out"
fi

if [[ "$failed" -ne 0 ]]; then
    echo "lint: ${failed} check(s) failed" >&2
    exit 1
fi
echo "lint: all checks passed"
