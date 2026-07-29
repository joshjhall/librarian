#!/usr/bin/env bash
# loop-make-it-tested — Deterministic Pre-Scan
#
# Detects test coverage gaps: public functions without test files,
# test files without assertions, source modules without test counterparts.
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

    # Skip test files themselves and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml) continue ;;
    esac

    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    # --- Category: missing-test-file ---
    # Check if a corresponding test file exists
    has_test=false
    case "$ext" in
        py)
            for test_path in \
                "${dirname}/test_${name_no_ext}.py" \
                "${dirname}/tests/test_${name_no_ext}.py" \
                "${dirname}/../tests/test_${name_no_ext}.py" \
                "${dirname}/${name_no_ext}_test.py"; do
                if [ -f "$test_path" ]; then
                    has_test=true
                    break
                fi
            done
            ;;
        ts | js | tsx | jsx)
            for suffix in "test" "spec"; do
                for test_path in \
                    "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/../__tests__/${name_no_ext}.${suffix}.${ext}"; do
                    if [ -f "$test_path" ]; then
                        has_test=true
                        break 2
                    fi
                done
            done
            ;;
        go)
            test_path="${dirname}/${name_no_ext}_test.go"
            if [ -f "$test_path" ]; then
                has_test=true
            fi
            ;;
        rs)
            # Rust: check for mod tests in same file or tests/ directory
            if command grep -q '#\[cfg(test)\]' "$file" 2>/dev/null; then
                has_test=true
            elif [ -d "${dirname}/../tests" ]; then
                has_test=true
            fi
            ;;
    esac

    if [ "$has_test" = "false" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "missing-test-file" \
            "No test file found for ${basename}" "HIGH"
    fi

    # --- Category: untested-public-api ---
    # Public/exported functions that should have test coverage
    case "$ext" in
        py)
            # Public functions (not starting with _)
            command grep -nE '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    # Check if this function appears in any test file nearby
                    if ! command grep -rql "\b${func_name}\b" "${dirname}"/test_*.py "${dirname}"/tests/test_*.py 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        go)
            # Exported functions (capitalized)
            command grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    if [ -f "$test_file" ] && ! command grep -q "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
