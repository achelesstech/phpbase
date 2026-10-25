#!/usr/bin/env bash
# =============================================================================
# check-links.sh — fail when a relative link in the Markdown points nowhere
# =============================================================================
#   scripts/check-links.sh
#
# Reads every git-tracked *.md file and checks the target of each inline link
# or image, [text](target), and of each reference definition, [ref]: target.
#   * http:, https:, mailto: and pure #anchor targets are skipped
#   * a #… suffix is dropped; the file or directory before it must exist AND
#     be in the git index (a directory: hold tracked files), because a link to
#     an untracked file works here and is broken on GitHub
#   * targets resolve against the linking file's directory; a leading / means
#     the repository root, as on GitHub
# Fenced code blocks and `inline code` are not links and are ignored. GitHub
# footnote definitions, [^1]: text, are not reference definitions.
#
# Prints `<file>: broken link -> <target>` for each failure and exits 1 if
# there was any. Untracked files (e.g. the ignored .work/) are not read.
#
# Limits — a line-based approximation of CommonMark, not a parser:
#   * HTML links (<a href>, <img src>) are not checked;
#   * indented (4-space) code blocks are read as prose, so a link-shaped
#     string inside one is checked;
#   * an inline target containing parentheses, ](a(b).md), is cut at the
#     first `)`; a link split across lines is missed;
#   * %-encoded targets (my%20file.md) are checked literally, not decoded;
#   * #anchors are not checked against the target's headings.
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
        # Opening fence. A backtick fence whose info string holds a backtick
        # is not a fence (CommonMark 4.5); that line is read as prose below.
        match($0, /^ ? ? ?(````*|~~~~*)/) {
            f = substr($0, RSTART, RLENGTH)
            gsub(/ /, "", f)
            if (substr(f, 1, 1) != "`" || index(substr($0, RSTART + RLENGTH), "`") == 0) {
                fence = f
                next
            }
        }
        {
            line = $0
            gsub(/``([^`]|`[^`])*``/, "", line)
            gsub(/`[^`]*`/, "", line)

            # Reference definition: [ref]: target "title", also [ref]:target.
            # A label starting with ^ is a GitHub footnote, not a link.
            if (match(line, /^ ? ? ?\[[^]^][^]]*\]:[ \t]*/)) {
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
        elif ! git ls-files --error-unmatch -- ":(literal)${resolved}" >/dev/null 2>&1; then
            echo "${file}: link to a file git does not track -> ${target}"
            broken=$((broken + 1))
        fi
    done <<<"$targets"
done < <(git ls-files -z -- '*.md')

echo "check-links: ${links} relative links in ${files} files, ${broken} broken" >&2
[[ "$broken" -eq 0 ]] || exit 1
