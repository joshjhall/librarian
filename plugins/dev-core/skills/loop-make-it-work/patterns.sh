#!/usr/bin/env bash
# loop-make-it-work — Deterministic Pre-Scan
#
# Detects incomplete implementation blockers: stubs, placeholders, empty
# function bodies, and test files without assertions.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # --- Category: stub-detected ---
    # Match TODO, FIXME, STUB, PLACEHOLDER, NotImplementedError, unimplemented!
    /usr/bin/grep -niE '\b(TODO|FIXME|STUB|PLACEHOLDER)\b|NotImplementedError|raise NotImplementedError|unimplemented!\(\)|todo!\(\)|panic\("not implemented"\)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "stub-detected" \
                "Stub/placeholder: ${evidence}" "HIGH"
        done || true

    # --- Category: empty-body ---
    # Python: function with only pass or ellipsis body
    case "$file" in
        *.py)
            /usr/bin/grep -nE '^\s*def\s+\w+' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check if next non-blank line is pass or ...
                    next_line=$(/usr/bin/sed -n "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -m1 -nE '\S' | /usr/bin/head -1)
                    if echo "$next_line" | /usr/bin/grep -qE '^\s*(pass|\.\.\.)\s*$' 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-body" \
                            "Empty function body: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx)
            # TypeScript/JavaScript: function with empty braces {}
            /usr/bin/grep -nE '(function\s+\w+|=>\s*)\{[\s]*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-body" \
                        "Empty function body: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            # Go: function with empty braces
            /usr/bin/grep -nE '^func\s+.*\{[\s]*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-body" \
                        "Empty function body: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # --- Category: no-assertions ---
    # Test files without any assertion statements
    case "$file" in
        *test*.py | *_spec.py)
            if ! /usr/bin/grep -qE '\b(assert|assertEqual|assertTrue|assertFalse|assertRaises|assertIn|pytest\.raises)\b' "$file" 2>/dev/null; then
                /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
        *.test.ts | *.test.js | *.spec.ts | *.spec.js | *.test.tsx | *.test.jsx)
            if ! /usr/bin/grep -qE '\b(expect|assert|should)\b' "$file" 2>/dev/null; then
                /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
        *_test.go)
            if ! /usr/bin/grep -qE '\b(t\.(Error|Fatal|Log|Run|Helper)|assert\.|require\.)\b' "$file" 2>/dev/null; then
                /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
    esac

done <"$FILE_LIST"
