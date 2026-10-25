#!/usr/bin/env bash
# =============================================================================
# test/scripts/check-links.test.sh — scripts/check-links.sh against fixtures
# =============================================================================
#   bash test/scripts/check-links.test.sh
#
# Offline. Copies the script into a throwaway git repository, plants one
# Markdown file per case, and asserts what is and is not reported. The
# extractor is hand-written awk, and awk implementations differ, so each case
# pins one rule of the parser.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

pass=0
fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/d"
cp scripts/check-links.sh "$tmp/scripts/"
git -C "$tmp" init -q

printf 'target\n' >"$tmp/ok.md"
printf 'x\n' >"$tmp/d/x.md"
printf 'not added\n' >"$tmp/untracked.md"
cat >"$tmp/cases.md" <<'EOF'
# Cases

[^1]: missing-footnote.md is footnote text, not a link
[^note]:missing-footnote2.md

[r]:missing-nospace.md
[s]: ok.md
[t]:ok.md
[u]: untracked.md

```info`with-backtick
[after-bad-fence](missing-after-bad-fence.md)

```sh
[inside](missing-inside-fence.md)
```

[dir](d) [file](d/x.md) [anchor](ok.md#top)
EOF
git -C "$tmp" add scripts/check-links.sh ok.md d/x.md cases.md

status=0
out="$("$tmp/scripts/check-links.sh" 2>&1)" || status=$?

if [[ "$status" -eq 1 ]]; then ok "exits 1 when a link is broken"; else bad "exit status ${status}, expected 1"; fi

flagged() {   # flagged <description> <target>
    if grep -Fq -- "-> $2" <<<"$out"; then ok "$1"; else bad "$1 (not reported: $2)"; fi
}
not_flagged() {   # not_flagged <description> <target or target prefix>
    if grep -Fq -- "-> $2" <<<"$out"; then bad "$1 (reported: $2)"; else ok "$1"; fi
}

flagged     "[r]:target with no space is a reference definition"  missing-nospace.md
flagged     "a link after a backtick fence whose info string holds a backtick" missing-after-bad-fence.md
flagged     "a target git does not track"                           untracked.md
not_flagged "a [^1]: footnote is not a link"                        missing-footnote
not_flagged "a link inside a real fence is not checked"             missing-inside-fence.md
not_flagged "a tracked file resolves"                                ok.md
not_flagged "a directory holding tracked files resolves"            d
not_flagged "a #anchor suffix is dropped"                           'ok.md#top'
if grep -Fq 'link to a file git does not track -> untracked.md' <<<"$out"; then
    ok "an untracked target gets its own message"
else
    bad "an untracked target gets its own message"
fi
if [[ "$(grep -c -- '->' <<<"$out" || true)" -eq 3 ]]; then
    ok "exactly 3 links reported"
else
    bad "expected 3 reported links"
fi

if [[ "$fail" -ne 0 ]]; then sed 's/^/        /' <<<"$out"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
