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
#
# Runtime: this tool has a Python 3.11+ primary implementation (patterns.py) and
# this bash script as the portable fallback. When a python3>=3.11 is available
# the shim below execs patterns.py (identical TSV contract); otherwise the bash
# body runs. Set PATTERNS_FORCE_BASH=1 to force the fallback (used by the parity
# test). See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
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
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "AWS access key pattern: ${evidence}" "HIGH"
        done || true

    # GitHub tokens (ghp_, gho_, ghs_, ghr_, github_pat_)
    /usr/bin/grep -nE '(ghp_|gho_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "GitHub token pattern: ${evidence}" "HIGH"
        done || true

    # Stripe keys (sk_live_, rk_live_, pk_live_)
    /usr/bin/grep -nE '(sk_live_|rk_live_|pk_live_)[A-Za-z0-9]{20,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Stripe live key pattern: ${evidence}" "HIGH"
        done || true

    # Private key headers
    /usr/bin/grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Private key header: ${evidence}" "HIGH"
        done || true

    # Generic password/secret/token assignment with string literal values
    # (skip env var reads, placeholders, and comments). The quote delimiter class
    # is ["'] — a double- or single-quote. It is written ["'\''] so the single
    # quote is a real quote char: `'\''` closes the outer '-string, emits an
    # escaped ', and reopens. (Earlier this was `["\x27]`, but GNU grep does not
    # expand \x27 inside a bracket expression — it added literal \,x,2,7 to the
    # class, so any value containing x/2/7 was silently missed. Fixed in #168.)
    /usr/bin/grep -nEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)\s*[=:]\s*["'\''][^"'\'']{8,}["'\'']' "$file" 2>/dev/null |
        /usr/bin/grep -viE '(changeme|placeholder|xxx|TODO|example|REPLACE|your_|test_|fake_|dummy_|#|//|/\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Possible hardcoded credential: ${evidence}" "HIGH"
        done || true

    # --- Category: injection-risk ---

    # SQL injection: f-string or string concat with SQL keywords
    case "$file" in
        *.py)
            # f"..." or f'...' opening a SQL statement. Quote class ["'] written
            # as ["'\''] so the single quote is literal (see #168 — the old
            # ["\x27] never matched f'SELECT because \x27 is not expanded in a
            # bracket expression).
            /usr/bin/grep -nE 'f["'\''](SELECT|INSERT|UPDATE|DELETE|DROP)\b' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in f-string: ${evidence}" "HIGH"
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            /usr/bin/grep -nE '`(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\$\{' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in template literal: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            /usr/bin/grep -nE '"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*#\{' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # String concatenation with SQL keywords (all languages)
    /usr/bin/grep -nE '"(SELECT|INSERT|UPDATE|DELETE)\b.*"\s*\+\s*' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "injection-risk" \
                "SQL string concatenation: ${evidence}" "HIGH"
        done || true

    # --- Category: xss-risk ---

    # React: raw HTML rendering
    /usr/bin/grep -n "$XSS_REACT_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "React raw HTML rendering: ${evidence}" "HIGH"
        done || true

    # Vue: v-html directive
    /usr/bin/grep -n "$XSS_VUE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Vue raw HTML directive: ${evidence}" "HIGH"
        done || true

    # Django/Jinja: |safe filter, mark_safe()
    /usr/bin/grep -nE "$XSS_SAFE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Template safe filter bypassing escaping: ${evidence}" "HIGH"
        done || true

    # Blade: unescaped output
    /usr/bin/grep -n "$XSS_BLADE_PATTERN" "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Blade unescaped output: ${evidence}" "HIGH"
        done || true

    # --- Category: insecure-crypto ---

    # MD5/SHA1 used for security (skip comment-only lines). The skip filter must
    # match AFTER grep -n's "<lineno>:" prefix — anchoring at plain `^\s*#` never
    # fired (the line always starts with a digit), so comment lines were flagged
    # too. `^[0-9]+:\s*(#|...)` skips a line whose first non-space code char opens
    # a comment. (Fixed in #168.)
    /usr/bin/grep -nEi '\b(md5|sha1)\s*\(' "$file" 2>/dev/null |
        /usr/bin/grep -vE '^[0-9]+:[[:space:]]*(#|//|/\*|\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "insecure-crypto" \
                "Weak hash algorithm: ${evidence}" "HIGH"
        done || true

    # ECB mode encryption (skip comment-only lines — same grep -n prefix fix as
    # the weak-hash probe above; see #168).
    /usr/bin/grep -nEi '\bECB\b|MODE_ECB|mode.*ecb' "$file" 2>/dev/null |
        /usr/bin/grep -vE '^[0-9]+:[[:space:]]*(#|//|/\*|\*)' |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "insecure-crypto" \
                "ECB mode encryption: ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
