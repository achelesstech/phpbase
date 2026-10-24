#!/usr/bin/env bash
# =============================================================================
# resolve-matrix.sh — turn versions.json into exact, reproducible build inputs
# =============================================================================
#   scripts/resolve-matrix.sh [--only 8.4,8.5] [--include-eol] [--date YYYYMMDD]
#
# For every PHP line it resolves, AT THIS MOMENT:
#   * the digest of php:<line>-fpm-alpine (or <line>-rc-fpm-alpine), so every
#     job in the run builds from the same bytes even if upstream pushes mid-run
#   * the exact PHP patch version and Alpine release inside that digest
#   * the tags to publish
# and warns (GitHub annotations) when upstream looks stale or lags php.net —
# the two signals that would have caught the frozen 8.4.15 within a week.
#
# Prints `key=value` lines for $GITHUB_OUTPUT:
#   lines     JSON array, one object per PHP line
#   build     JSON array, one object per (line, platform) — the build matrix
#   composer  composer/composer:2-bin@sha256:…
#   date      YYYYMMDD
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY=""
INCLUDE_EOL=0
DATE="$(date -u +%Y%m%d)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)        ONLY="$2"; shift 2 ;;
        --include-eol) INCLUDE_EOL=1; shift ;;
        --date)        DATE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
TODAY="${DATE:0:4}-${DATE:4:2}-${DATE:6:2}"

note() { echo "::notice::$*" >&2; }
warn() { echo "::warning::$*" >&2; }

IMAGE="$(jq -r '.image' versions.json)"
PLATFORMS="$(jq -c '.platforms' versions.json)"

digest_of() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r '.digest'
}

lines='[]'
while IFS= read -r entry; do
    line="$(jq -r '.line' <<<"$entry")"
    eol="$(jq -r '.eol' <<<"$entry")"
    prerelease="$(jq -r '.prerelease // false' <<<"$entry")"
    latest="$(jq -r '.latest // false' <<<"$entry")"

    if [[ -n "$ONLY" && ",${ONLY}," != *",${line},"* ]]; then
        continue
    fi
    if [[ "$TODAY" > "$eol" && "$INCLUDE_EOL" -eq 0 ]]; then
        warn "PHP ${line} reached end of life on ${eol} — not built. Remove it from versions.json, or dispatch with include_eol."
        continue
    fi

    if [[ "$prerelease" == true ]]; then upstream="php:${line}-rc-fpm-alpine"; else upstream="php:${line}-fpm-alpine"; fi
    digest="$(digest_of "$upstream")"
    php_version="$(docker buildx imagetools inspect "${upstream}@${digest}" --format '{{json .Image}}' \
        | jq -r '."linux/amd64".config.Env[] | select(startswith("PHP_VERSION=")) | sub("^PHP_VERSION="; "")')"
    # Which Alpine is inside? Read it from the image itself. (The Hub tags API
    # is no shortcut: docker-library pushes the floating and the patch tags as
    # separate indexes, so their digests do not match.)
    alpine_full="$(docker run --rm --quiet --platform linux/amd64 --entrypoint cat "${upstream}@${digest}" /etc/alpine-release)"
    alpine="$(cut -d. -f1,2 <<<"$alpine_full")"

    # ── Staleness guards ────────────────────────────────────────────────────
    repo_tag="${upstream#php:}"
    updated="$(curl -fsS "https://hub.docker.com/v2/namespaces/library/repositories/php/tags/${repo_tag}" | jq -r '.last_updated' || echo unknown)"
    if [[ "$updated" != unknown ]]; then
        age_days=$(( ( $(date -u +%s) - $(date -u -d "$updated" +%s) ) / 86400 ))
        (( age_days <= 30 )) || warn "${upstream} was last updated ${age_days} days ago — upstream may have stopped building this line."
    fi
    if [[ "$prerelease" != true ]]; then
        newest="$(curl -fsS "https://www.php.net/releases/index.php?json&version=${line}" | jq -r '.version // empty' || true)"
        if [[ -n "$newest" && "$newest" != "$php_version" ]]; then
            warn "php.net has PHP ${newest}, but ${upstream} still ships ${php_version} (docker-library usually follows within a day or two)."
        fi
    fi
    note "PHP ${line}: ${php_version} on Alpine ${alpine_full} (${upstream}@${digest:0:19}…, updated ${updated})"

    # ── Tags ────────────────────────────────────────────────────────────────
    if [[ "$prerelease" == true ]]; then
        tags="$(jq -nc --arg i "$IMAGE" --arg l "$line" '[$i + ":" + $l + "-rc"]')"
    else
        tags="$(jq -nc --arg i "$IMAGE" --arg l "$line" --arg p "$php_version" --arg a "$alpine" --arg d "$DATE" --argjson latest "$latest" \
            '[$i+":"+$l, $i+":"+$p, $i+":"+$l+"-alpine"+$a, $i+":"+$p+"-"+$d] + (if $latest then [$i+":latest"] else [] end)')"
    fi

    lines="$(jq -c \
        --arg line "$line" --arg upstream "$upstream" --arg digest "$digest" \
        --arg php "$php_version" --arg alpine "$alpine" --arg alpine_full "$alpine_full" \
        --argjson prerelease "$prerelease" --argjson tags "$tags" --argjson fw "$(jq -c '.frameworks // {}' <<<"$entry")" \
        '. + [{line: $line, upstream: $upstream, digest: $digest, from: ($upstream + "@" + $digest),
               php_version: $php, alpine: $alpine, alpine_full: $alpine_full, prerelease: $prerelease,
               tags: $tags, dev_tags: ($tags | map(if endswith(":latest") then sub(":latest$"; ":latest-dev") else . + "-dev" end)),
               frameworks: $fw}]' <<<"$lines")"
done < <(jq -c '.php[]' versions.json)

[[ "$(jq length <<<"$lines")" -gt 0 ]] || { echo "::error::nothing to build" >&2; exit 1; }

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
echo "composer=${composer}"
echo "date=${DATE}"
