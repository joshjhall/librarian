#!/usr/bin/env bash
# check-docs-deadlinks — Deterministic Pre-Scan
#
# Detects broken relative links and anchors in documentation files.
# Does NOT perform HTTP requests for external URLs.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
# Runtime: Python 3.11+ primary (patterns.py); this bash body is the portable
# fallback. PATTERNS_FORCE_BASH=1 forces bash. See CLAUDE.md § Key conventions.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | /usr/bin/grep -qixF "$_cand"; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        /usr/bin/printf "%.${n}s" "$s"
    fi
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Get the directory of the current file for relative path resolution
    file_dir=$(/usr/bin/dirname "$file")

    # --- Category: broken-relative-link ---
    # Match markdown links: [text](relative/path) — exclude URLs, anchors-only, and images
    /usr/bin/grep -nE '\[([^]]*)\]\(([^)]+)\)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            # Extract the link target
            target=$(/usr/bin/echo "$content" | /usr/bin/grep -oE '\]\([^)]+\)' | /usr/bin/head -1 | /usr/bin/sed 's/^](//' | /usr/bin/sed 's/)$//')

            # Skip empty, URLs, mailto, anchors-only
            case "$target" in
                "" | http://* | https://* | mailto:* | "#"* | ftp://*) continue ;;
            esac

            # Strip anchor from target for file existence check
            target_file=$(/usr/bin/echo "$target" | /usr/bin/sed 's/#.*//')
            [ -z "$target_file" ] && continue

            # Resolve relative to the document's directory
            resolved="${file_dir}/${target_file}"

            if [ ! -e "$resolved" ]; then
                evidence=$(truncate_chars 80 "Link target not found: ${target}")
                /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "broken-relative-link" \
                    "$evidence" "HIGH"
            fi
        done || true

    # --- Category: broken-anchor ---
    # Match same-file anchor links: [text](#heading)
    /usr/bin/grep -nE '\[([^]]*)\]\(#([^)]+)\)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            anchor=$(/usr/bin/echo "$content" | /usr/bin/grep -oE '\]\(#[^)]+\)' | /usr/bin/head -1 | /usr/bin/sed 's/^](#//' | /usr/bin/sed 's/)$//')
            [ -z "$anchor" ] && continue

            # Convert anchor to heading format for matching
            # GitHub/GitLab anchors: lowercase, spaces→hyphens, strip special chars
            # Search for matching heading in the same file
            heading_pattern=$(/usr/bin/echo "$anchor" | /usr/bin/sed 's/-/ /g')
            if ! /usr/bin/grep -qiE "^#{1,6} .*${heading_pattern}" "$file" 2>/dev/null; then
                evidence=$(truncate_chars 80 "Anchor #${anchor} has no matching heading in file")
                /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "broken-anchor" \
                    "$evidence" "HIGH"
            fi
        done || true

    # --- Category: suspicious-external-link ---
    # URLs with deprecation/sunset indicators
    /usr/bin/grep -noE 'https?://[^ )>"]+' "$file" 2>/dev/null |
        /usr/bin/grep -iE '(deprecated|sunset|eol|end-of-life|removed|legacy)' |
        while IFS=: read -r line_num url; do
            evidence=$(truncate_chars 80 "Suspicious URL: ${url}")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "suspicious-external-link" \
                "$evidence" "HIGH"
        done || true

done <"$FILE_LIST"
