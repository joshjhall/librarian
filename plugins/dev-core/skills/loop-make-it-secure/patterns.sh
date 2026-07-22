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
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
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
    if locale -a 2>/dev/null | command grep -qixF "$_cand"; then
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
        command printf "%.${n}s" "$s"
    fi
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test files — security patterns in tests are often intentional fixtures
    case "$file" in
        *test* | *spec* | *fixture* | *mock* | *fake*) continue ;;
    esac

    # --- Category: hardcoded-secret ---
    # High-entropy strings that look like API keys, tokens, or passwords. The
    # opening-quote class is ["'] — a double or single quote — written ["'\'']
    # so the single quote is a real quote char (#183; the old ["\x27] never
    # matched a single-quoted value because grep does not expand \x27 in a
    # bracket expression).
    command grep -niE '(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|secret[_-]?key|password|passwd|private[_-]?key)\s*[=:]\s*["'\''][A-Za-z0-9+/=_-]{16,}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Possible hardcoded secret: ${evidence}" "HIGH"
        done || true

    # AWS-style access keys (AKIA...)
    command grep -nE 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "AWS access key pattern: ${evidence}" "HIGH"
        done || true

    # --- Category: string-interpolation-query ---
    # SQL queries built with string concatenation or f-strings
    case "$file" in
        *.py)
            # Detect f-string or .format() used with SQL keywords. Quote class
            # ["'] written ["'\''] so a single-quoted f'...' also matches (#183;
            # the old ["\x27] missed f'... because \x27 is not expanded in a
            # bracket expression).
            command grep -nE '(execute|cursor)\s*\(\s*f["'\'']' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx)
            # Template literal SQL
            command grep -nE '(query|execute)\s*\(\s*`[^`]*(SELECT|INSERT|UPDATE|DELETE)' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            # fmt.Sprintf with SQL
            command grep -nE '(Exec|Query|QueryRow)\s*\(\s*fmt\.Sprintf' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "string-interpolation-query" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # --- Category: dangerous-function ---
    # Functions that enable code injection or unsafe deserialization
    # Note: this script DETECTS these patterns for remediation, it does not use them
    command grep -nE '\b(subprocess\.call\s*\(.*shell\s*=\s*True|child_process\.exec\s*\()' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "dangerous-function" \
                "Dangerous function usage: ${evidence}" "HIGH"
        done || true

    # Unsafe deserialization patterns. `marshal.load(s)` is always flagged;
    # `yaml.load(...)` is flagged only WITHOUT an explicit Loader= (a safe loader
    # makes it benign). POSIX ERE (grep -E) has no negative lookahead, so the
    # yaml exclusion is a second `grep -v` on the line rather than an inline
    # `(?!...)` — the old inline lookahead never matched anything, disabling
    # yaml.load detection entirely (#183).
    command grep -nE '\b(yaml\.load\s*\(|marshal\.loads?\s*\()' "$file" 2>/dev/null |
        command grep -vE 'Loader\s*=' |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "dangerous-function" \
                "Unsafe deserialization: ${evidence}" "HIGH"
        done || true

    # --- Category: denylist-validation ---
    # Input validation patterns using denylists (!=, not in [bad values])
    command grep -niE '(blacklist|blocklist|denylist|banned|forbidden)\s*=\s*\[' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "denylist-validation" \
                "Denylist pattern (prefer allowlist): ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
