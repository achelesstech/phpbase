# shellcheck shell=bash
# =============================================================================
# scripts/lib/guards.sh — upstream freshness guards and build-tag choice
# =============================================================================
# Sourced by scripts/resolve-matrix.sh (and test/scripts/guards.test.sh).
# Defines functions only; sourcing it has no side effects.
#
# The guards print `ok`, `warn:<message>` or `fail:<message>`. They decide;
# the caller reports. All dates are UTC; GNU date is assumed (CI and the host
# both have it).
# =============================================================================

# _days_between FROM TO — whole days from FROM to TO (any `date -d` format).
_days_between() {
    local from to
    from="$(date -u -d "$1" +%s)" || return 1
    to="$(date -u -d "$2" +%s)" || return 1
    echo $(( (to - from) / 86400 ))
}

# _version_lt A B — true when version A sorts strictly before version B.
_version_lt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# php_guard UPSTREAM NEWEST NEWEST_DATE TODAY
#   UPSTREAM     PHP version inside the upstream image, e.g. 8.4.26
#   NEWEST       php.net's newest release of that branch ('' = unreachable)
#   NEWEST_DATE  php.net's `date` field for it, e.g. "21 Oct 2026"
#   TODAY        YYYY-MM-DD
# Fails when upstream is behind a php.net release more than 3 days old:
# docker-library normally follows within a day or two.
php_guard() {
    local upstream="$1" newest="$2" newest_date="$3" today="$4" age
    if [[ -z "$newest" ]]; then
        echo "warn:php.net is unreachable; cannot check that upstream PHP ${upstream} is current"
        return
    fi
    if [[ "$upstream" == "$newest" ]]; then
        echo ok
        return
    fi
    if ! age="$(_days_between "$newest_date" "$today" 2>/dev/null)"; then
        echo "warn:php.net has PHP ${newest} (release date '${newest_date}' unreadable), upstream ships ${upstream}"
        return
    fi
    if _version_lt "$upstream" "$newest" && (( age > 3 )); then
        echo "fail:php.net released PHP ${newest} ${age} days ago, but upstream still ships ${upstream}"
    else
        echo "warn:php.net has PHP ${newest} (released ${age} days ago), upstream ships ${upstream}"
    fi
}

# alpine_guard IMAGE_MINOR LATEST_MINOR LATEST_FIRST_DATE TODAY
#   IMAGE_MINOR        Alpine minor inside the upstream image, e.g. 3.24
#   LATEST_MINOR       alpinelinux.org's latest stable minor, e.g. 3.25
#   LATEST_FIRST_DATE  date of that branch's first release, YYYY-MM-DD
#   TODAY              YYYY-MM-DD
# Warns (never fails) when a newer Alpine has been out for more than 14 days.
alpine_guard() {
    local image_minor="$1" latest_minor="$2" first_date="$3" today="$4" age
    if _version_lt "$image_minor" "$latest_minor" \
        && age="$(_days_between "$first_date" "$today" 2>/dev/null)" \
        && (( age > 14 )); then
        echo "warn:Alpine ${latest_minor} has been out for ${age} days, but upstream is still on Alpine ${image_minor}"
        return
    fi
    echo ok
}

# next_build_tag BASE [EXISTING...]
# BASE if it is not among EXISTING, else BASE.N with the smallest free N >= 2,
# so a published build tag is never reused.
next_build_tag() {
    local base="$1" n=2
    shift
    local -A taken=()
    local t
    for t in "$@"; do taken["$t"]=1; done
    if [[ -z "${taken[$base]:-}" ]]; then
        echo "$base"
        return
    fi
    while [[ -n "${taken[$base.$n]:-}" ]]; do n=$((n + 1)); done
    echo "$base.$n"
}
