#!/usr/bin/env bash
# check-docs-missing-api — Deterministic Pre-Scan
#
# Detects exported/public functions without documentation across languages.
# Uses language-specific patterns to find function definitions missing
# preceding docstring/comment blocks.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
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

# check_prev_lines FILE LINE_NUM PATTERN — returns 0 if PATTERN found in
# the 3 lines before LINE_NUM
check_prev_lines() {
    local file="$1" target_line="$2" pattern="$3"
    local start=$((target_line - 3))
    [ "$start" -lt 1 ] && start=1
    command sed -n "${start},$((target_line - 1))p" "$file" 2>/dev/null |
        command grep -qE "$pattern"
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    case "$file" in
        # --- Python ---
        *.py)
            # Find module-level function/class definitions
            command grep -nE '^(def |class )[A-Za-z_]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Skip private definitions — anchor on the NAME (token after
                    # def/class), NOT a whole-line substring, so a public def
                    # whose trailing comment mentions `def _x` is still flagged
                    # (#348). The grep admits a leading underscore so the private
                    # def reaches this name-anchored skip.
                    case "$content" in
                        "def _"* | "class _"*) continue ;;
                    esac
                    # Check for docstring (triple quotes) in preceding lines
                    if ! check_prev_lines "$file" "$line_num" '"""'; then
                        # Also check if function body starts with docstring
                        next_lines=$(command sed -n "$((line_num + 1)),$((line_num + 2))p" "$file" 2>/dev/null)
                        if ! command echo "$next_lines" | command grep -qE '^\s+"""'; then
                            evidence=$(truncate_chars 80 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-api" \
                                "Python: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;

        # --- JavaScript/TypeScript ---
        *.js | *.ts | *.jsx | *.tsx)
            # Find exported functions, classes, types
            command grep -nE '^export (function|class|const|type|interface|enum) ' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check for JSDoc comment (/**) in preceding lines
                    if ! check_prev_lines "$file" "$line_num" '/\*\*'; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "JS/TS: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Go ---
        *.go)
            # Find exported functions (capitalized, not in test files)
            case "$file" in *_test.go) continue ;; esac
            command grep -nE '^func [A-Z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Go convention: comment line immediately before with function name
                    func_name=$(command echo "$content" | command grep -oE 'func [A-Z][A-Za-z0-9]*' | command awk '{print $2}')
                    if [ -n "$func_name" ]; then
                        prev_line=$(command sed -n "$((line_num - 1))p" "$file" 2>/dev/null)
                        if ! command echo "$prev_line" | command grep -q "// ${func_name}"; then
                            evidence=$(truncate_chars 80 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-api" \
                                "Go: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;

        # --- Rust ---
        *.rs)
            # Find pub fn and pub struct
            command grep -nE '^pub (fn|struct|enum|trait|type) ' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Check for /// doc comment
                    if ! check_prev_lines "$file" "$line_num" '^\s*///'; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Rust: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Shell ---
        *.sh | *.bash)
            # Find function definitions
            command grep -nE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)|^function [a-zA-Z_]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    # Skip private functions — anchor on the NAME, not a
                    # whole-line substring (#348): `_helper()` and
                    # `function _helper` are private, but a public function whose
                    # comment mentions `function _x` must still be flagged.
                    case "$content" in
                        _* | "function _"*) continue ;;
                    esac
                    # Check for # comment on preceding line
                    if ! check_prev_lines "$file" "$line_num" '^\s*#'; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Shell: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Ruby ---
        *.rb)
            command grep -nE '^\s*def [a-z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    if ! check_prev_lines "$file" "$line_num" '^\s*#'; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Ruby: ${evidence}" "HIGH"
                    fi
                done || true
            ;;

        # --- Java/Kotlin ---
        *.java | *.kt)
            command grep -nE '^\s*public .*(void|int|String|boolean|List|Map|Optional|fun )' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    if ! check_prev_lines "$file" "$line_num" '/\*\*'; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "undocumented-public-api" \
                            "Java/Kotlin: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
