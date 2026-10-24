#!/usr/bin/env bash
# =============================================================================
# upstream.test.sh — unit test for rebuild_reason (scripts/lib/upstream.sh)
# =============================================================================
#   test/scripts/upstream.test.sh
#
# No network and no real Docker:
#   * rebuild_reason: feeds digests and a pending-upgrade count and checks
#     which reason, if any, is reported;
#   * check-upstream.sh: runs it with a stub `docker` first on PATH to check
#     a missing published tag (build it) and a registry outage (fail).
# Exits 1 if any case fails.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=scripts/lib/upstream.sh
. scripts/lib/upstream.sh

P1=sha256:1111111111111111111111111111111111111111111111111111111111111111
P2=sha256:2222222222222222222222222222222222222222222222222222222222222222
A1=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
A2=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

failures=0
check() {
    local name="$1" expected="$2" actual
    shift 2
    actual="$(rebuild_reason "$@")"
    if [[ "$actual" == "$expected" ]]; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

#     name                         expected       PHP_NOW PHP_LABEL ALPINE_NOW ALPINE_LABEL PENDING
check "all equal, 0 pending"       ""             "$P1"   "$P1"     "$A1"      "$A1"        0
check "PHP digest differs"         "php-image"    "$P2"   "$P1"     "$A1"      "$A1"        0
check "Alpine digest differs"      "alpine-image" "$P1"   "$P1"     "$A2"      "$A1"        0
check "only pending = 3"           "apk-upgrades" "$P1"   "$P1"     "$A1"      "$A1"        3
check "PHP and Alpine both differ" "php-image"    "$P2"   "$P1"     "$A2"      "$A1"        0

# ── check-upstream.sh against a stub `docker` (no network) ──────────────────
# The stub answers imagetools for the published tags, php:* and alpine:*, with
# labels that match upstream, and `docker run` with no pending upgrades. One
# published tag can be made missing (STUB_MISSING + STUB_MISSING_MSG) or
# fail some other way (STUB_OUTAGE, with STUB_OUTAGE_MSG or a 429 by default).
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat >"$stub_dir/docker" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
    run) exit 0 ;;
    buildx) ref="\$4" fmt="\$6" ;;
    *) echo "stub docker: unexpected \$*" >&2; exit 99 ;;
esac
if [[ -n "\${STUB_MISSING:-}" && "\$ref" == "\${STUB_IMAGE}:\${STUB_MISSING}" ]]; then
    echo "ERROR: \$ref: \${STUB_MISSING_MSG}" >&2; exit 1
fi
if [[ -n "\${STUB_OUTAGE:-}" && "\$ref" == "\${STUB_IMAGE}:\${STUB_OUTAGE}" ]]; then
    echo "\${STUB_OUTAGE_MSG:-ERROR: unexpected status from HEAD request to https://registry-1.docker.io/v2/x/manifests/y: 429 Too Many Requests}" >&2; exit 1
fi
if [[ "\$fmt" == *.Manifest* ]]; then
    case "\$ref" in
        php:*)    echo '{"digest":"$P1"}' ;;
        alpine:*) echo '{"digest":"$A1"}' ;;
        *)        echo '{"digest":"sha256:dddd"}' ;;
    esac
else
    echo '{"linux/amd64":{"config":{"Labels":{
        "io.github.achelesstech.php-base.upstream-digest":"$P1",
        "org.opencontainers.image.base.digest":"$A1",
        "io.github.achelesstech.php-base.alpine-version":"3.24.3"}}}}'
fi
STUB
chmod +x "$stub_dir/docker"

export STUB_IMAGE
STUB_IMAGE="$(jq -r '.image' versions.json)"
mapfile -t lines < <(jq -r --arg t "$(date -u +%F)" '.php[] | select((.prerelease // false) | not) | select(.eol >= $t) | .line' versions.json)
first="${lines[0]}"

# run_check VAR=VALUE...: runs check-upstream.sh with the stub; sets out, err, status.
run_check() {
    status=0
    out="$(env "$@" PATH="$stub_dir:$PATH" scripts/check-upstream.sh 2>"$stub_dir/err")" || status=$?
    err="$(cat "$stub_dir/err")"
}

expect() {
    local name="$1"
    shift
    if "$@"; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}"
        echo "       status=${status}"
        echo "       stdout: ${out}"
        echo "       stderr: ${err}"
        failures=$((failures + 1))
    fi
}

reason_of() { sed -n 's/^reasons=//p' <<<"$out" | jq -r --arg l "$1" '.[$l]'; }

run_check
expect "stub: all lines current" \
    test "$status" -eq 0 -a "$(grep -c '^rebuild=$' <<<"$out" || true)" -eq 1

for msg in "not found" "manifest unknown"; do
    run_check STUB_MISSING="$first" STUB_MISSING_MSG="$msg"
    expect "stub: tag ${first} ${msg} -> exit 0" test "$status" -eq 0
    expect "stub: tag ${first} ${msg} -> rebuild=${first}" \
        test "$(grep -c "^rebuild=${first}\$" <<<"$out" || true)" -eq 1
    expect "stub: tag ${first} ${msg} -> reason php-image" test "$(reason_of "$first")" = php-image
    expect "stub: tag ${first} ${msg} -> other lines current" \
        test "$(sed -n 's/^reasons=//p' <<<"$out" | jq --arg l "$first" '[to_entries[] | select(.key != $l and .value != "")] | length')" = 0
    expect "stub: tag ${first} ${msg} -> ::warning:: names the tag" \
        test "$(grep -cF "::warning::${STUB_IMAGE}:${first} does not exist yet" <<<"$err" || true)" -eq 1
done

run_check STUB_OUTAGE="$first"
expect "stub: registry outage -> run fails" test "$status" -ne 0
expect "stub: registry outage -> no rebuild= printed" test "$(grep -c '^rebuild=' <<<"$out" || true)" -eq 0
expect "stub: registry outage -> error passed on" \
    test "$(grep -c '429 Too Many Requests' <<<"$err" || true)" -eq 1

# A local "not found" (here a broken credential helper) is not the registry
# saying the tag is missing: it must fail the run, not rebuild every line.
# shellcheck disable=SC2016 # docker's literal message, $PATH unexpanded
helper_msg='ERROR: error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH, out: ``'
run_check STUB_OUTAGE="$first" STUB_OUTAGE_MSG="$helper_msg"
expect "stub: credential helper not found -> run fails" test "$status" -ne 0
expect "stub: credential helper not found -> no rebuild= printed" \
    test "$(grep -c '^rebuild=' <<<"$out" || true)" -eq 0
expect "stub: credential helper not found -> no ::warning::" \
    test "$(grep -c '::warning::' <<<"$err" || true)" -eq 0
expect "stub: credential helper not found -> error passed on" \
    test "$(grep -c 'executable file not found' <<<"$err" || true)" -eq 1

if (( failures > 0 )); then
    echo "${failures} case(s) failed"
    exit 1
fi
echo "all cases passed"
