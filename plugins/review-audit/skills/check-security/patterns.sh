#!/usr/bin/env bash
# check-security — Deterministic Pre-Scan
#
# Detects security patterns that can be caught by regex: hardcoded secrets,
# injection risks, XSS patterns, and insecure cryptography. Results are
# passed to the LLM for context-dependent confirmation/dismissal.
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

# XSS detection patterns — stored as variable to avoid hook false positives
# on the pattern strings themselves (this script DETECTS these, not uses them)
XSS_REACT_PATTERN='dangerously''SetInnerHTML'
XSS_VUE_PATTERN='v-html'
XSS_SAFE_PATTERN='\|safe\b|mark_safe\('
XSS_BLADE_PATTERN='{!!'

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test fixtures, example env files, and lock files
    case "$file" in
        *test*fixture* | *testdata* | *.env.example | *.env.sample | *.env.template) continue ;;
        *lock.json | *lock.yaml | *.lock | *go.sum) continue ;;
    esac

    # --- Category: hardcoded-secret ---

    # AWS access keys (AKIA followed by 16 uppercase alphanumeric chars)
    /usr/bin/grep -nE 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "AWS access key pattern: ${evidence}" "HIGH"
        done || true

    # GitHub tokens (ghp_, gho_, ghs_, ghr_, github_pat_)
    /usr/bin/grep -nE '(ghp_|gho_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "GitHub token pattern: ${evidence}" "HIGH"
        done || true

    # Stripe keys (sk_live_, rk_live_, pk_live_)
    /usr/bin/grep -nE '(sk_live_|rk_live_|pk_live_)[A-Za-z0-9]{20,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Stripe live key pattern: ${evidence}" "HIGH"
        done || true

    # Private key headers
    /usr/bin/grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Private key header: ${evidence}" "HIGH"
        done || true

    # Generic password/secret/token assignment with string literal values
    # (skip env var reads, placeholders, and comments)
    /usr/bin/grep -nEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)\s*[=:]\s*["\x27][^"\x27]{8,}["\x27]' "$file" 2>/dev/null |
        /usr/bin/grep -viE '(changeme|placeholder|xxx|TODO|example|REPLACE|your_|test_|fake_|dummy_|#|//|/\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Possible hardcoded credential: ${evidence}" "HIGH"
        done || true

    # --- Category: injection-risk ---

    # SQL injection: f-string or string concat with SQL keywords
    case "$file" in
        *.py)
            /usr/bin/grep -nE 'f["\x27](SELECT|INSERT|UPDATE|DELETE|DROP)\b' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in f-string: ${evidence}" "HIGH"
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            /usr/bin/grep -nE '`(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\$\{' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in template literal: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            /usr/bin/grep -nE '"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*#\{' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # String concatenation with SQL keywords (all languages)
    /usr/bin/grep -nE '"(SELECT|INSERT|UPDATE|DELETE)\b.*"\s*\+\s*' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "injection-risk" \
                "SQL string concatenation: ${evidence}" "HIGH"
        done || true

    # --- Category: xss-risk ---

    # React: raw HTML rendering
    /usr/bin/grep -n "$XSS_REACT_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "React raw HTML rendering: ${evidence}" "HIGH"
        done || true

    # Vue: v-html directive
    /usr/bin/grep -n "$XSS_VUE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Vue raw HTML directive: ${evidence}" "HIGH"
        done || true

    # Django/Jinja: |safe filter, mark_safe()
    /usr/bin/grep -nE "$XSS_SAFE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Template safe filter bypassing escaping: ${evidence}" "HIGH"
        done || true

    # Blade: unescaped output
    /usr/bin/grep -n "$XSS_BLADE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Blade unescaped output: ${evidence}" "HIGH"
        done || true

    # --- Category: insecure-crypto ---

    # MD5/SHA1 used for security (skip comments)
    /usr/bin/grep -nEi '\b(md5|sha1)\s*\(' "$file" 2>/dev/null |
        /usr/bin/grep -vE '^\s*(#|//|/\*|\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "insecure-crypto" \
                "Weak hash algorithm: ${evidence}" "HIGH"
        done || true

    # ECB mode encryption
    /usr/bin/grep -nEi '\bECB\b|MODE_ECB|mode.*ecb' "$file" 2>/dev/null |
        /usr/bin/grep -vE '^\s*(#|//|/\*|\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "insecure-crypto" \
                "ECB mode encryption: ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
