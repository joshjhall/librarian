#!/usr/bin/env bash
# check-code-health — Deterministic Pre-Scan
#
# Detects code health patterns that can be caught by regex: tech debt markers,
# debug statements, empty error handlers, and unused imports. Results are
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
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# The two `>>> shared:` regions below stay in the bash fallback and are kept
# byte-identical with ship-issue/pre-review-gates.sh by
# tests/validate-shared-scanner-sync.sh — the port does not disturb them.
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

# >>> shared:is-test-file (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
# is_test_file PATH — return 0 (true) if PATH is a test file by path/name
# convention. PATH-ONLY: content-colocated tests (Rust #[cfg(test)] blocks in
# real source files) are NOT this function's job. Segment-anchored so that
# contest.py / latest.js / attestation.go (which a bare *test* glob wrongly
# matches) are NOT skipped, while tests/helper.py (which a suffix-only set
# wrongly scans) IS. Handles both repo-relative and absolute path forms.
is_test_file() {
    case "$1" in
        tests/* | */tests/* | test/* | */test/* | \
            __tests__/* | */__tests__/* | spec/* | */spec/* | \
            __pycache__/* | */__pycache__/*) return 0 ;;
        test_*.* | */test_*.*) return 0 ;;
        *_test.* | *_spec.* | *.test.* | *.spec.*) return 0 ;;
    esac
    return 1
}
# <<< shared:is-test-file

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions)
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Determine if this is a test file (skip debug-statement checks for tests)
    is_test=0
    is_test_file "$file" && is_test=1

    # --- Category: tech-debt-marker ---
    # TODO, FIXME, HACK, XXX, WORKAROUND comments
    /usr/bin/grep -niE -- '\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "tech-debt-marker" \
                "Tech debt marker: ${evidence}" "HIGH"
        done || true

    # --- Category: debug-statement ---
    # Only flag in non-test files
    if [ "$is_test" -eq 0 ]; then
        # >>> shared:debug-statement-scan (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
        # This case is a DELIBERATE cross-plugin duplicate: review-audit and
        # workflow install independently, so pre-review-gates.sh cannot source
        # it. Edit both copies together; the drift guard fails CI otherwise.
        case "$file" in
            *.py)
                # Python: print() used as debug (not in logging context)
                /usr/bin/grep -nE -- '^\s*print\(' "$file" 2>/dev/null |
                    /usr/bin/grep -vE '(logging|logger|log\.)' |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                # Python: breakpoint(), pdb
                /usr/bin/grep -nE -- '^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debugger statement: ${evidence}" "HIGH"
                    done || true
                ;;
            *.js | *.ts | *.jsx | *.tsx)
                # JavaScript/TypeScript: console.log, console.debug, console.warn
                /usr/bin/grep -nE -- '^\s*console\.(log|debug|warn|info|trace)\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Console debug statement: ${evidence}" "HIGH"
                    done || true
                # debugger keyword
                /usr/bin/grep -nE -- '^\s*debugger\s*;?\s*$' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debugger keyword: ${evidence}" "HIGH"
                    done || true
                ;;
            *.rb)
                # Ruby: binding.pry, puts used as debug
                /usr/bin/grep -nE -- '^\s*(binding\.pry|binding\.irb|byebug)\b' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Ruby debugger: ${evidence}" "HIGH"
                    done || true
                ;;
            *.go)
                # Go: fmt.Println used as debug (not in main or test)
                /usr/bin/grep -nE -- '^\s*fmt\.Print(ln|f)?\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                ;;
            *.java | *.kt)
                # Java/Kotlin: System.out.println, System.err.println
                /usr/bin/grep -nE -- '^\s*System\.(out|err)\.print(ln)?\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                ;;
        esac
        # <<< shared:debug-statement-scan
    fi

    # --- Category: empty-handler ---

    case "$file" in
        *.py)
            # Python: except with only pass
            /usr/bin/grep -nE -- '^\s*except' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    next_line=$(/usr/bin/sed -n -- "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -m1 -E '\S' | /usr/bin/head -1)
                    if /usr/bin/printf '%s\n' "$next_line" | /usr/bin/grep -qE '^\s*pass\s*$' 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty except block (pass): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            # JS/TS: catch with empty body
            /usr/bin/grep -nE -- 'catch\s*\([^)]*\)\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.java | *.kt)
            # Java/Kotlin: catch with empty body
            /usr/bin/grep -nE -- 'catch\s*\([^)]*\)\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            # Ruby: rescue with no body
            /usr/bin/grep -nE -- '^\s*rescue\b' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    next_line=$(/usr/bin/sed -n -- "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -m1 -E '\S' | /usr/bin/head -1)
                    if /usr/bin/printf '%s\n' "$next_line" | /usr/bin/grep -qE '^\s*(end|rescue)\s*$' 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty rescue block: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.go)
            # Go: if err != nil with empty body
            /usr/bin/grep -nE -- 'if err != nil\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Swallowed error: ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
