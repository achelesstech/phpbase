#!/usr/bin/env bash
# =============================================================================
# check-links.sh — fail when a relative link in the Markdown points nowhere
# =============================================================================
#   scripts/check-links.sh
#
# Reads every git-tracked *.md file and checks the target of each inline link
# or image, [text](target), and of each reference definition, [ref]: target.
#   * http:, https:, mailto: and pure #anchor targets are skipped
#   * a #… suffix is dropped; the file or directory before it must exist
#   * targets resolve against the linking file's directory; a leading / means
#     the repository root, as on GitHub
# Fenced code blocks and `inline code` are not links and are ignored.
#
# Prints `<file>: broken link -> <target>` for each failure and exits 1 if
# there was any. Untracked files (e.g. the ignored .work/) are not read.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# One link target per output line, in document order.
extract_links() {
    awk '
        # Inside a fence: look only for the closing fence (same character,
        # at least as long, nothing after it).
        fence != "" {
            if ($0 ~ /^ ? ? ?(````*|~~~~*)[ \t]*$/) {
                f = $0
                gsub(/[ \t]/, "", f)
                if (substr(f, 1, 1) == substr(fence, 1, 1) && length(f) >= length(fence)) fence = ""
            }
            next
        }
        match($0, /^ ? ? ?(````*|~~~~*)/) {
            fence = substr($0, RSTART, RLENGTH)
            gsub(/ /, "", fence)
            next
        }
        {
            line = $0
            gsub(/``([^`]|`[^`])*``/, "", line)
            gsub(/`[^`]*`/, "", line)

            # Reference definition: [ref]: target "title"
            if (match(line, /^ ? ? ?\[[^]]+\]:[ \t]+/)) {
                t = substr(line, RLENGTH + 1)
                if (t ~ /^</) { sub(/^</, "", t); sub(/>.*$/, "", t) } else sub(/[ \t].*$/, "", t)
                if (t != "") print t
                next
            }

            # Inline link or image: [text](target "title"), [text](<target>)
            while (match(line, /\]\([^)]*\)/)) {
                t = substr(line, RSTART + 2, RLENGTH - 3)
                line = substr(line, RSTART + RLENGTH)
                sub(/^[ \t]+/, "", t)
                if (t ~ /^</) { sub(/^</, "", t); sub(/>.*$/, "", t) } else sub(/[ \t].*$/, "", t)
                if (t != "") print t
            }
        }
    ' "$1"
}

git rev-parse --is-inside-work-tree >/dev/null   # fail loudly outside a checkout

files=0 links=0 broken=0
while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    files=$((files + 1))
    dir="$(dirname "$file")"
    targets="$(extract_links "$file")"   # assignment, so an awk error stops us
    while IFS= read -r target; do
        case "$target" in
            '' | http://* | https://* | mailto:* | '#'*) continue ;;
        esac
        links=$((links + 1))
        path="${target%%#*}"
        if [[ "$path" == /* ]]; then
            resolved=".${path}"
        else
            resolved="${dir}/${path}"
        fi
        if [[ ! -e "$resolved" ]]; then
            echo "${file}: broken link -> ${target}"
            broken=$((broken + 1))
        fi
    done <<<"$targets"
done < <(git ls-files -z -- '*.md')

echo "check-links: ${links} relative links in ${files} files, ${broken} broken" >&2
[[ "$broken" -eq 0 ]] || exit 1
