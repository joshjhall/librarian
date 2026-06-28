#!/usr/bin/env bash
# check-docs-deadlinks — Deterministic Pre-Scan
#
# Detects broken relative links and anchors in documentation files.
# Does NOT perform HTTP requests for external URLs.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

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
                evidence=$(/usr/bin/printf '%.80s' "Link target not found: ${target}")
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
                evidence=$(/usr/bin/printf '%.80s' "Anchor #${anchor} has no matching heading in file")
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
            evidence=$(/usr/bin/printf '%.80s' "Suspicious URL: ${url}")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "suspicious-external-link" \
                "$evidence" "HIGH"
        done || true

done <"$FILE_LIST"
