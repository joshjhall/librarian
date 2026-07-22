#!/usr/bin/env bash
# loop-make-it-documented — Deterministic Pre-Scan
#
# Detects documentation gaps: public functions without docstrings, exported
# symbols without JSDoc/GoDoc, public classes without documentation.
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

    # Skip test files and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml | *.lock) continue ;;
    esac

    basename=$(command basename "$file")
    ext="${basename##*.}"

    case "$ext" in
        py)
            # --- Python: public functions without docstrings ---
            # awk truncates by BYTES; it now emits `category \t line \t rawtext`
            # and the char-aware bash helper truncates rawtext, matching the
            # python primary on multibyte defs/classes (#17 equivalence). rawtext
            # is the trailing field so a `read -r cat line rawtext` keeps it whole.
            command awk '
                /^def [a-zA-Z][a-zA-Z0-9_]*\(/ {
                    func_line = NR
                    func_text = $0
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "undocumented-public-function\t%d\t%s\n", func_line, func_text
                    }
                }
                /^class [A-Z][a-zA-Z0-9_]*/ {
                    class_line = NR
                    class_text = $0
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "undocumented-public-class\t%d\t%s\n", class_line, class_text
                    }
                }
            ' "$file" 2>/dev/null |
                while IFS=$'\t' read -r category line_num rawtext; do
                    evidence=$(truncate_chars 60 "$rawtext")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "$category" \
                        "No docstring: ${evidence}" "HIGH"
                done || true
            ;;
        ts | js | tsx | jsx)
            # --- TypeScript/JavaScript: exported functions without JSDoc ---
            command grep -n '^export\s\+\(async\s\+\)\?function\s\+\w\+\|^export\s\+\(default\s\+\)\?class\s\+\w\+' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check if preceded by JSDoc comment (/** ... */)
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE '^\s*\*/' 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            category="undocumented-export"
                            if command printf '%s' "$content" | command grep -q 'class' 2>/dev/null; then
                                category="undocumented-public-class"
                            fi
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "$category" \
                                "No JSDoc: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        go)
            # --- Go: exported functions without GoDoc comments ---
            # grep -nE (extended regex): the pattern uses `\(` for a literal
            # paren, which in a BASIC regex opens an unclosed group (grep errors,
            # matches nothing). With -E the arm actually runs (#183; it was dead).
            command grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE "^// ${func_name}" 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-export" \
                                "No GoDoc for ${func_name}: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        sh | bash)
            # --- Shell: functions without usage comment ---
            command grep -n '^\w\+()' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE '^\s*#' 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-function" \
                                "No comment before function: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
