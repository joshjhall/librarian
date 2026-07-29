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

    # --- Category: stub-detected ---
    # Match TODO, FIXME, STUB, PLACEHOLDER, NotImplementedError, unimplemented!
    command grep -niE '\b(TODO|FIXME|STUB|PLACEHOLDER)\b|NotImplementedError|raise NotImplementedError|unimplemented!\(\)|todo!\(\)|panic\("not implemented"\)' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "stub-detected" \
                "Stub/placeholder: ${evidence}" "HIGH"
        done || true

    # --- Category: empty-body ---
    # Python: function with only pass or ellipsis body
    case "$file" in
        *.py)
            command grep -nE '^\s*def\s+\w+' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Check if next non-blank line is pass or ... . NOTE: grep -m1
                    # (NOT -nm1): a stray -n prefixed "<lineno>:" to next_line, so
                    # the `^\s*(pass|...)` check never matched and this arm was
                    # dead (#183).
                    next_line=$(command sed -n "$((line_num + 1)),\$p" "$file" |
                        command grep -m1 -E '\S' | command head -1)
                    if echo "$next_line" | command grep -qE '^\s*(pass|\.\.\.)\s*$' 2>/dev/null; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-body" \
                            "Empty function body: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx)
            # TypeScript/JavaScript: function with empty braces {}. Uses
            # [[:space:]]* for the inner whitespace — the old `[\s]*` was a bracket
            # class of literal backslash/'s', not whitespace, so `{ }` (a real
            # space) was missed (#183).
            command grep -nE '(function\s+\w+|=>\s*)\{[[:space:]]*\}' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-body" \
                        "Empty function body: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            # Go: function with empty braces ([[:space:]]* not [\s]*, see #183).
            command grep -nE '^func\s+.*\{[[:space:]]*\}' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-body" \
                        "Empty function body: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # --- Category: no-assertions ---
    # Test files without any assertion statements
    case "$file" in
        *test*.py | *_spec.py)
            if ! command grep -qE '\b(assert|assertEqual|assertTrue|assertFalse|assertRaises|assertIn|pytest\.raises)\b' "$file" 2>/dev/null; then
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
        *.test.ts | *.test.js | *.spec.ts | *.spec.js | *.test.tsx | *.test.jsx)
            if ! command grep -qE '\b(expect|assert|should)\b' "$file" 2>/dev/null; then
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
        *_test.go)
            if ! command grep -qE '\b(t\.(Error|Fatal|Log|Run|Helper)|assert\.|require\.)\b' "$file" 2>/dev/null; then
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "1" "no-assertions" \
                    "Test file contains no assertion statements" "HIGH"
            fi
            ;;
    esac

done <"$FILE_LIST"
