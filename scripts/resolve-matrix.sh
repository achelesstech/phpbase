#!/usr/bin/env bash
# =============================================================================
# resolve-matrix.sh — turn versions.json into exact, reproducible build inputs
# =============================================================================
#   scripts/resolve-matrix.sh [--only 8.4,8.5] [--include-eol] [--date YYYYMMDD] [--local]
#
# For every PHP line it resolves, AT THIS MOMENT:
#   * the digest of php:<line>-fpm-alpine (or <line>-rc-fpm-alpine), so every
#     job in the run builds from the same bytes even if upstream pushes mid-run
#   * the exact PHP patch version and Alpine release inside that digest
#   * the digest of alpine:<minor>, the clean base the runtime stage uses
#   * a build tag X.Y.Z-YYYYMMDD that is not on Docker Hub yet (else .2, .3, …)
#   * the tags to publish
# and guards upstream freshness (scripts/lib/guards.sh):
#   * FAIL a line whose PHP is behind a php.net release more than 3 days old
#   * warn when a newer Alpine has been out for more than 14 days
#   * warn when upstream's tag has not been updated for 30 days
#   * warn when a pre-release line already has a GA upstream tag
#   * warn when php.net supports a branch versions.json does not list
#
# --local   for local builds (scripts/build-args.sh): a guard failure is only a
#           warning, the build tag is <php_version>-local, and Docker Hub's
#           tag API is never contacted.
#
# Prints `key=value` lines for $GITHUB_OUTPUT:
#   lines     JSON array, one object per PHP line
#   build     JSON array, one object per (line, platform) — the build matrix
#   failed    JSON array of {line, reason}: lines a guard removed
#   composer  composer/composer:2-bin@sha256:…
#   date      YYYYMMDD
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/guards.sh
source scripts/lib/guards.sh

ONLY=""
INCLUDE_EOL=0
LOCAL=0
DATE="$(date -u +%Y%m%d)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)        ONLY="$2"; shift 2 ;;
        --include-eol) INCLUDE_EOL=1; shift ;;
        --date)        DATE="$2"; shift 2 ;;
        --local)       LOCAL=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
TODAY="${DATE:0:4}-${DATE:4:2}-${DATE:6:2}"
HUB_API="${HUB_API:-https://hub.docker.com}"
HUB_REPO="$(jq -r '.image | sub("^docker.io/"; "")' versions.json)"   # achelesstech/php-base

note()  { echo "::notice::$*" >&2; }
warn()  { echo "::warning::$*" >&2; }
error() { echo "::error::$*" >&2; }

IMAGE="$(jq -r '.image' versions.json)"
PLATFORMS="$(jq -c '.platforms' versions.json)"

digest_of() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r '.digest'
}

# hub_tag_exists TAG — 0 if achelesstech/php-base:TAG is on Docker Hub, 1 if
# not. Any other answer stops the run: guessing could reuse a published tag.
hub_tag_exists() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        "${HUB_API}/v2/namespaces/${HUB_REPO%%/*}/repositories/${HUB_REPO#*/}/tags/$1" 2>/dev/null)" || true
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   error "cannot check existing tags on Docker Hub (HTTP ${code:-none} for ${HUB_REPO}:$1)"; exit 1 ;;
    esac
}

# ── Run-wide facts ──────────────────────────────────────────────────────────
# Newest stable Alpine and the date its branch first shipped.
alpine_latest=""
alpine_first=""
if alpine_json="$(curl -fsS --max-time 20 https://alpinelinux.org/releases.json)"; then
    alpine_latest="$(jq -r '.latest_stable | ltrimstr("v")' <<<"$alpine_json")"
    alpine_first="$(jq -r '.latest_stable as $b | .release_branches[] | select(.rel_branch == $b)
        | [.releases[].date] | min // empty' <<<"$alpine_json")"
else
    warn "alpinelinux.org is unreachable; cannot check that upstream is on the newest Alpine."
fi

# Branches php.net supports that versions.json does not list.
if active="$(curl -fsS --max-time 20 https://www.php.net/releases/active.php)"; then
    while IFS= read -r branch; do
        warn "php.net supports PHP ${branch}, but versions.json does not list it."
    done < <(jq -r --argjson listed "$(jq -c '[.php[].line]' versions.json)" \
        '[.[] | keys[]] - $listed | .[]' <<<"$active")
else
    warn "php.net is unreachable; cannot check for PHP branches versions.json does not list."
fi

lines='[]'
failed='[]'
while IFS= read -r entry; do
    line="$(jq -r '.line' <<<"$entry")"
    eol="$(jq -r '.eol' <<<"$entry")"
    prerelease="$(jq -r '.prerelease // false' <<<"$entry")"
    latest="$(jq -r '.latest // false' <<<"$entry")"
    max_size_mb="$(jq -r '.max_size_mb // empty' <<<"$entry")"

    if [[ -n "$ONLY" && ",${ONLY}," != *",${line},"* ]]; then
        continue
    fi
    if [[ "$TODAY" > "$eol" && "$INCLUDE_EOL" -eq 0 ]]; then
        warn "PHP ${line} reached end of life on ${eol} — not built. Remove it from versions.json, or dispatch with include_eol."
        continue
    fi
    [[ -n "$max_size_mb" ]] || { error "versions.json: PHP ${line} has no max_size_mb"; exit 1; }

    if [[ "$prerelease" == true ]]; then upstream="php:${line}-rc-fpm-alpine"; else upstream="php:${line}-fpm-alpine"; fi
    digest="$(digest_of "$upstream")"
    php_version="$(docker buildx imagetools inspect "${upstream}@${digest}" --format '{{json .Image}}' \
        | jq -r '."linux/amd64".config.Env[] | select(startswith("PHP_VERSION=")) | sub("^PHP_VERSION="; "")')"
    # Which Alpine is inside? Read it from the image itself. (The Hub tags API
    # is no shortcut: docker-library pushes the floating and the patch tags as
    # separate indexes, so their digests do not match.)
    alpine_full="$(docker run --rm --quiet --platform linux/amd64 --entrypoint cat "${upstream}@${digest}" /etc/alpine-release)"
    alpine="$(cut -d. -f1,2 <<<"$alpine_full")"
    alpine_digest="$(digest_of "alpine:${alpine}")"

    # ── Freshness guards ────────────────────────────────────────────────────
    updated=unknown
    if [[ "$LOCAL" -eq 0 ]]; then
        updated="$(curl -fsS --max-time 20 "${HUB_API}/v2/namespaces/library/repositories/php/tags/${upstream#php:}" \
            | jq -r '.last_updated // "unknown"' || echo unknown)"
        if [[ "$updated" != unknown ]]; then
            age_days=$(( ( $(date -u +%s) - $(date -u -d "$updated" +%s) ) / 86400 ))
            (( age_days <= 30 )) || warn "${upstream} was last updated ${age_days} days ago — upstream may have stopped building this line."
        fi
    fi

    guard_fail=""
    if [[ "$prerelease" == true ]]; then
        if docker buildx imagetools inspect "php:${line}-fpm-alpine" >/dev/null 2>&1; then
            warn "php:${line}-fpm-alpine exists: PHP ${line} has gone GA, but versions.json still marks it prerelease."
        fi
    else
        newest=""
        newest_date=""
        if phpnet="$(curl -fsS --max-time 20 "https://www.php.net/releases/?json&version=${line}")"; then
            newest="$(jq -r '.version // empty' <<<"$phpnet")"
            newest_date="$(jq -r '.date // empty' <<<"$phpnet")"
        fi
        verdict="$(php_guard "$php_version" "$newest" "$newest_date" "$TODAY")"
        case "$verdict" in
            warn:*) warn "PHP ${line}: ${verdict#warn:}" ;;
            fail:*) guard_fail="${verdict#fail:}" ;;
        esac
    fi
    if [[ -n "$alpine_latest" ]]; then
        verdict="$(alpine_guard "$alpine" "$alpine_latest" "$alpine_first" "$TODAY")"
        [[ "$verdict" != warn:* ]] || warn "PHP ${line}: ${verdict#warn:}"
    fi

    if [[ -n "$guard_fail" ]]; then
        if [[ "$LOCAL" -eq 1 ]]; then
            warn "PHP ${line}: ${guard_fail} (a CI build would fail this line)"
        else
            error "PHP ${line}: ${guard_fail} — line not built."
            failed="$(jq -c --arg l "$line" --arg r "$guard_fail" '. + [{line: $l, reason: $r}]' <<<"$failed")"
            continue
        fi
    fi
    note "PHP ${line}: ${php_version} on Alpine ${alpine_full} (${upstream}@${digest:0:19}…, alpine:${alpine}@${alpine_digest:0:19}…, updated ${updated})"

    # ── Build tag: never one that is already published ──────────────────────
    if [[ "$LOCAL" -eq 1 ]]; then
        build_tag="${php_version}-local"
    else
        existing=()
        build_tag="$(next_build_tag "${php_version}-${DATE}")"
        while hub_tag_exists "$build_tag"; do
            existing+=("$build_tag")
            build_tag="$(next_build_tag "${php_version}-${DATE}" "${existing[@]}")"
        done
    fi

    # ── Tags ────────────────────────────────────────────────────────────────
    if [[ "$prerelease" == true ]]; then
        tags="$(jq -nc --arg i "$IMAGE" --arg l "$line" '[$i + ":" + $l + "-rc"]')"
    else
        tags="$(jq -nc --arg i "$IMAGE" --arg l "$line" --arg p "$php_version" --arg b "$build_tag" --argjson latest "$latest" \
            '[$i+":"+$l, $i+":"+$p, $i+":"+$b] + (if $latest then [$i+":latest"] else [] end)')"
    fi

    lines="$(jq -c \
        --arg line "$line" --arg upstream "$upstream" --arg digest "$digest" \
        --arg php "$php_version" --arg alpine "$alpine" --arg alpine_full "$alpine_full" \
        --arg alpine_digest "$alpine_digest" --arg build_tag "$build_tag" \
        --argjson prerelease "$prerelease" --argjson tags "$tags" --argjson max_size_mb "$max_size_mb" \
        --argjson fw "$(jq -c '.frameworks // {}' <<<"$entry")" \
        '. + [{line: $line, prerelease: $prerelease, upstream: $upstream, digest: $digest,
               from: ($upstream + "@" + $digest), php_version: $php,
               alpine: $alpine, alpine_full: $alpine_full,
               alpine_image: ("alpine:" + $alpine + "@" + $alpine_digest), alpine_digest: $alpine_digest,
               build_tag: $build_tag, tags: $tags,
               dev_tags: ($tags | map(if endswith(":latest") then sub(":latest$"; ":latest-dev") else . + "-dev" end)),
               max_size_mb: $max_size_mb, frameworks: $fw}]' <<<"$lines")"
done < <(jq -c '.php[]' versions.json)

# One build job per (line, platform), each on a NATIVE runner — no QEMU.
build="$(jq -c --argjson platforms "$PLATFORMS" '
    [ .[] as $l | $platforms[] as $p | $l + {
        platform: $p,
        arch: ($p | split("/")[1]),
        runner: (if $p == "linux/arm64" then "ubuntu-24.04-arm" else "ubuntu-24.04" end)
    } ]' <<<"$lines")"

composer="composer/composer:2-bin@$(digest_of composer/composer:2-bin)"

echo "lines=${lines}"
echo "build=${build}"
echo "failed=${failed}"
echo "composer=${composer}"
echo "date=${DATE}"

[[ "$(jq length <<<"$lines")" -gt 0 ]] || { error "nothing to build"; exit 1; }
