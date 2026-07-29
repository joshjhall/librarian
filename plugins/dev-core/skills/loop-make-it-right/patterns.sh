#!/usr/bin/env bash
# loop-make-it-right — Deterministic Pre-Scan
#
# Detects structural quality issues: long functions, deep nesting, and
# single-character variable names outside loop counters.
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

# Configurable via environment (thresholds.yml values passed by orchestrator)
MAX_FUNCTION_LINES="${LOOP_MAX_FUNCTION_LINES:-50}"
MAX_NESTING_DEPTH="${LOOP_MAX_NESTING_DEPTH:-4}"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # --- Category: long-function ---
    # Detect function definitions and count lines until closing
    case "$file" in
        *.py)
            # Python: count lines from def to next def/class or dedent
            command grep -n '^\s*def \w\+' "$file" 2>/dev/null |
                while read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Count lines until next function/class at same or lower indent
                    indent=$(command printf '%s' "$content" | command sed 's/[^ ].*//' | command wc -c)
                    end_line=$(command sed -n "$((line_num + 1)),\$p" "$file" |
                        command grep -n "^.\{0,${indent}\}[^ ]" |
                        command head -1 | command cut -d: -f1)
                    if [ -n "$end_line" ]; then
                        func_lines=$((end_line))
                    else
                        total=$(command wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.ts | *.js | *.tsx | *.jsx | *.go | *.rs)
            # Brace-delimited languages: count from opening { to closing }
            command grep -nE '^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+' "$file" 2>/dev/null |
                while read -r raw; do
                    line_num=${raw%%:*}
                    _content=${raw#*:}
                    # Simple heuristic: count lines from definition to next function
                    next_func=$(command sed -n "$((line_num + 1)),\$p" "$file" |
                        command grep -nE '^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+' |
                        command head -1 | command cut -d: -f1)
                    if [ -n "$next_func" ]; then
                        func_lines=$((next_func))
                    else
                        total=$(command wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(truncate_chars 60 "$_content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

    # --- Category: deep-nesting ---
    # Count leading whitespace to detect excessive nesting. awk truncates by
    # BYTES (its `%.60s` / substr are byte-based even under a UTF-8 locale), which
    # diverged from the python primary's char slice on multibyte lines. So awk now
    # emits the RAW line as a trailing field and the char-aware bash helper
    # truncates it (#17 equivalence). Fields before the raw line are tab-free, and
    # `read -r ... rawline` captures the (possibly tab-bearing) line whole.
    nest_unit=0
    case "$file" in
        *.py) nest_unit=4 ;;
        *.ts | *.js | *.tsx | *.jsx | *.go | *.rs) nest_unit=2 ;;
    esac
    if [ "$nest_unit" -ne 0 ]; then
        command awk -v max="$MAX_NESTING_DEPTH" -v unit="$nest_unit" '
            /^[[:space:]]+[^[:space:]]/ {
                match($0, /^[[:space:]]+/)
                depth = int(RLENGTH / unit)
                if (depth > max) {
                    printf "%d\t%d\t%s\n", NR, depth, $0
                }
            }
        ' "$file" 2>/dev/null |
            while IFS=$'\t' read -r line_num depth rawline; do
                evidence=$(truncate_chars 60 "$rawline")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "deep-nesting" \
                    "Nesting depth ${depth} (max ${MAX_NESTING_DEPTH}): ${evidence}" "HIGH"
            done || true
    fi

    # --- Category: single-char-name ---
    # Single-character variable names outside common loop patterns
    case "$file" in
        *.py)
            command grep -nE '^\s+[a-zA-Z]\s*=' "$file" 2>/dev/null |
                command grep -vE '^\s*(for|with)\s+[a-zA-Z]\s+in\b|_\s*=' |
                while read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Extract the variable name
                    varname=$(command printf '%s' "$content" | command sed 's/^[[:space:]]*\([a-zA-Z]\)[[:space:]]*=.*/\1/')
                    # Skip common loop vars and conventional single-char names
                    case "$varname" in
                        i | j | k | n | x | y | _ | e | f) continue ;;
                    esac
                    evidence=$(truncate_chars 60 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "single-char-name" \
                        "Single-character variable '${varname}': ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
