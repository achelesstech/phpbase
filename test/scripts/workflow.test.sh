#!/usr/bin/env bash
# =============================================================================
# test/scripts/workflow.test.sh — build-base.yml agrees with the resolver
# =============================================================================
#   bash test/scripts/workflow.test.sh
#   BUILD_JSON='[…]' COMPOSER_IMAGE='composer/…@sha256:…' bash test/scripts/workflow.test.sh
#
# Checks three things a slip in the workflow would otherwise break only in CI:
#   * every matrix.<key> the workflow reads is a key of the resolver's build[0]
#     (an unknown key silently expands to an empty string);
#   * the build-arguments step writes exactly the names scripts/build-args.sh
#     prints, so CI and local builds get the same arguments;
#   * DOCKERHUB_TOKEN is the only secret it reads. GitHub withholds a job
#     output that contains any secret's value, and resolve's outputs name the
#     image, so a username secret leaves build and publish an empty matrix.
#
# Without BUILD_JSON it runs `scripts/resolve-matrix.sh --only 8.4 --local`
# (registry reads). CI passes the run's own resolver output instead. Either
# way, the resolved line seeds build-args.sh's daily cache if it has none, so
# build-args.sh does not resolve a second time.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

WORKFLOW=.github/workflows/build-base.yml

if [[ -z "${BUILD_JSON:-}" ]]; then
    out="$(scripts/resolve-matrix.sh --only 8.4 --local)"
    BUILD_JSON="$(sed -n 's/^build=//p' <<<"$out")"
    COMPOSER_IMAGE="$(sed -n 's/^composer=//p' <<<"$out")"
fi
: "${COMPOSER_IMAGE:?COMPOSER_IMAGE must be set together with BUILD_JSON}"
first="$(jq -ce '.[0]' <<<"$BUILD_JSON")"
line="$(jq -r '.line' <<<"$first")"

cache=".cache/resolve/${line}-$(date -u +%Y%m%d).json"
if [[ ! -s "$cache" ]]; then
    mkdir -p "$(dirname "$cache")"
    jq --arg c "$COMPOSER_IMAGE" '. + {composer: $c}' <<<"$first" >"$cache"
fi

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
words() { paste -sd' ' <<<"$1"; }   # newline-separated list -> one line

# ── matrix keys ──────────────────────────────────────────────────────────────
keys="$(jq -r 'keys[]' <<<"$first" | sort -u)"
# Not preceded by a name character or '-': `resolve-matrix.sh` is no key.
used="$(grep -oE '(^|[^[:alnum:]_-])matrix\.[a-z_]+' "$WORKFLOW" | sed -E 's/.*matrix\.//' | sort -u)"
unknown="$(comm -13 <(echo "$keys") <(echo "$used"))"
if [[ -z "$used" ]]; then
    bad "the workflow reads no matrix keys (wrong file?)"
elif [[ -n "$unknown" ]]; then
    bad "matrix keys the resolver does not provide: $(words "$unknown")"
else
    ok "all $(wc -l <<<"$used") matrix keys exist in build[0]"
fi

# ── build-argument names ─────────────────────────────────────────────────────
# The run block of the step with `id: args`: from that line to the next step.
step="$(awk '
    /^ +id: args$/            { on = 1; next }
    on && /^ +- (name|uses):/ { exit }
    on                        { print }
' "$WORKFLOW")"
written="$(grep -oE 'echo "[A-Z][A-Z0-9_]*=' <<<"$step" | sed -E 's/^echo "//; s/=$//' | sort -u || true)"
expected="$(scripts/build-args.sh "$line" | sed -E 's/^--build-arg ([A-Z0-9_]+)=.*/\1/' | sort -u)"
missing="$(comm -23 <(echo "$expected") <(echo "$written"))"
extra="$(comm -13 <(echo "$expected") <(echo "$written"))"
if [[ -z "$written" ]]; then
    bad "no NAME= lines found in the step with id: args"
elif [[ -n "$missing$extra" ]]; then
    bad "build arguments differ from build-args.sh — missing: [$(words "$missing")] extra: [$(words "$extra")]"
else
    ok "the workflow writes the same $(wc -l <<<"$written") build arguments as build-args.sh"
fi

# ── secrets ──────────────────────────────────────────────────────────────────
secrets_read="$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$WORKFLOW" | sort -u || true)"
if [[ "$secrets_read" == secrets.DOCKERHUB_TOKEN ]]; then
    ok "DOCKERHUB_TOKEN is the only secret the workflow reads"
else
    bad "the workflow reads [$(words "$secrets_read")], not only secrets.DOCKERHUB_TOKEN: GitHub would withhold any output of resolve that contains one of their values"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
