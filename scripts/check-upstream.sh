#!/usr/bin/env bash
# =============================================================================
# check-upstream.sh — which published lines need a rebuild, and why
# =============================================================================
#   scripts/check-upstream.sh
#
# For every stable (non-pre-release), non-EOL line in versions.json, reads the
# published ${IMAGE}:<line> (amd64 config labels) and compares it with now:
#   php-image     php:<line>-fpm-alpine's digest differs from the
#                 io.github.achelesstech.php-base.upstream-digest label
#   alpine-image  alpine:<minor>'s digest differs from the
#                 org.opencontainers.image.base.digest label, where <minor>
#                 comes from the io.github.achelesstech.php-base.alpine-version
#                 label (3.24.3 -> 3.24)
#   apk-upgrades  `apk upgrade --simulate`, run as root inside the published
#                 image, would upgrade at least one package
# The first that applies is the line's reason (scripts/lib/upstream.sh).
#
# Prints, for $GITHUB_OUTPUT:
#   rebuild   comma-separated lines that need a rebuild (empty if none)
#   reasons   JSON object, line -> reason ("" when the line is current)
# and one ::notice:: per line that needs a rebuild, on stderr.
#
# A line whose ${IMAGE}:<line> tag does not exist yet (the registry says "not
# found" or "manifest unknown") needs a build: it gets a ::warning:: and the
# reason php-image, as an image without labels cannot match upstream. Every
# other failed lookup fails the run: an outage must not read as "current".
#
# All digests compared are index (manifest-list) digests, as printed by
#   docker buildx imagetools inspect <ref> --format '{{json .Manifest}}' | jq -r .digest
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/upstream.sh
. scripts/lib/upstream.sh

note() { echo "::notice::$*" >&2; }
warn() { echo "::warning::$*" >&2; }

IMAGE="$(jq -r '.image' versions.json)"
TODAY="$(date -u +%F)"
PHP_LABEL_KEY=io.github.achelesstech.php-base.upstream-digest
ALPINE_LABEL_KEY=org.opencontainers.image.base.digest
ALPINE_VERSION_KEY=io.github.achelesstech.php-base.alpine-version

digest_of() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -re '.digest'
}

# published_digest_of REF: like digest_of, but prints nothing (and succeeds)
# when the registry says REF does not exist. Any other error is passed on.
published_digest_of() {
    local out err status=0
    err="$(mktemp)"
    out="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>"$err")" || status=$?
    if (( status == 0 )); then
        rm -f "$err"
        jq -re '.digest' <<<"$out"
        return
    fi
    local message
    message="$(cat "$err")"
    rm -f "$err"
    # Only the registry's answer about this ref counts as "missing"; a local
    # "…: executable file not found in $PATH" must still fail the run.
    if [[ "$message" == *"$1: not found"* || "$message" == *"manifest unknown"* ]]; then
        return 0
    fi
    echo "$message" >&2
    return "$status"
}

# label KEY: KEY's value in the current line's $labels, or empty.
label() { jq -r --arg k "$1" '.[$k] // empty' <<<"$labels"; }

rebuild=()
reasons='{}'
while IFS= read -r line; do
    published="${IMAGE}:${line}"
    published_digest="$(published_digest_of "$published")"
    if [[ -n "$published_digest" ]]; then
        labels="$(docker buildx imagetools inspect "${published}@${published_digest}" --format '{{json .Image}}' \
            | jq -c '."linux/amd64".config.Labels // {}')"
    else
        warn "${published} does not exist yet: building PHP ${line}."
        labels='{}'
    fi

    php_label="$(label "$PHP_LABEL_KEY")"
    alpine_label="$(label "$ALPINE_LABEL_KEY")"
    alpine_version="$(label "$ALPINE_VERSION_KEY")"

    php_now="$(digest_of "php:${line}-fpm-alpine")"
    if [[ -n "$alpine_version" ]]; then
        alpine_now="$(digest_of "alpine:$(cut -d. -f1,2 <<<"$alpine_version")")"
    else
        # No alpine-version label (a v1 image): there is no base to compare.
        alpine_now="unknown"
    fi

    pending=0
    if [[ -n "$published_digest" ]]; then
        # Capture first, count second: grep -c exits 1 on zero matches.
        simulated="$(docker run --rm --quiet --platform linux/amd64 --user 0 --entrypoint sh "${published}@${published_digest}" \
            -c 'apk upgrade --simulate --no-cache 2>/dev/null')"
        pending="$(grep -c Upgrading <<<"$simulated" || true)"
    fi

    reason="$(rebuild_reason "$php_now" "$php_label" "$alpine_now" "$alpine_label" "$pending")"
    if [[ -n "$reason" ]]; then
        rebuild+=("$line")
        note "PHP ${line}: rebuild (${reason}; ${pending} package upgrade(s) pending)"
    fi
    reasons="$(jq -c --arg l "$line" --arg r "$reason" '. + {($l): $r}' <<<"$reasons")"
done < <(jq -r --arg t "$TODAY" '.php[] | select((.prerelease // false) | not) | select(.eol >= $t) | .line' versions.json)

echo "rebuild=$(IFS=,; echo "${rebuild[*]}")"
echo "reasons=${reasons}"
