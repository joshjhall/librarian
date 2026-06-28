#!/usr/bin/env bash
# loop-make-it-secure — Deterministic Pre-Scan
#
# Detects security issues: hardcoded secrets, string interpolation in
# queries, dangerous function usage, and denylist validation patterns.
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

    # Skip test files — security patterns in tests are often intentional fixtures
    case "$file" in
        *test* | *spec* | *fixture* | *mock* | *fake*) continue ;;
    esac

    # --- Category: hardcoded-secret ---
    # High-entropy strings that look like API keys, tokens, or passwords
    /usr/bin/grep -niE '(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|secret[_-]?key|password|passwd|private[_-]?key)\s*[=:]\s*["\x27][A-Za-z0-9+/=_-]{16,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Possible hardcoded secret: ${evidence}" "HIGH"
        done || true

    # AWS-style access keys (AKIA...)
    /usr/bin/grep -nE 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "AWS access key pattern: ${evidence}" "HIGH"
        done || true

    # --- Category: string-interpolation-query ---
    # SQL queries built with string concatenation or f-strings
    case "$file" in
        *.py)
            # Detect f-string or .format() used with SQL keywords
            /usr/bin/grep -nE '(execute|cursor)\s*\(\s*f["\x27]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx)
            # Template literal SQL
            /usr/bin/grep -nE '(query|execute)\s*\(\s*`[^`]*(SELECT|INSERT|UPDATE|DELETE)' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            # fmt.Sprintf with SQL
            /usr/bin/grep -nE '(Exec|Query|QueryRow)\s*\(\s*fmt\.Sprintf' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # --- Category: dangerous-function ---
    # Functions that enable code injection or unsafe deserialization
    # Note: this script DETECTS these patterns for remediation, it does not use them
    /usr/bin/grep -nE '\b(subprocess\.call\s*\(.*shell\s*=\s*True|child_process\.exec\s*\()' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "dangerous-function" \
                "Dangerous function usage: ${evidence}" "HIGH"
        done || true

    # Unsafe deserialization patterns
    /usr/bin/grep -nE '\b(yaml\.load\s*\([^)]*\)(?!.*Loader)|marshal\.loads?\s*\()' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "dangerous-function" \
                "Unsafe deserialization: ${evidence}" "HIGH"
        done || true

    # --- Category: denylist-validation ---
    # Input validation patterns using denylists (!=, not in [bad values])
    /usr/bin/grep -niE '(blacklist|blocklist|denylist|banned|forbidden)\s*=\s*\[' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "denylist-validation" \
                "Denylist pattern (prefer allowlist): ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
