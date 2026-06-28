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
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions)
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Determine if this is a test file (skip debug-statement checks for tests)
    is_test=0
    case "$file" in
        *_test.* | *.test.* | *.spec.* | *__tests__* | *test* | *spec*) is_test=1 ;;
    esac

    # --- Category: tech-debt-marker ---
    # TODO, FIXME, HACK, XXX, WORKAROUND comments
    /usr/bin/grep -niE '\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "tech-debt-marker" \
                "Tech debt marker: ${evidence}" "HIGH"
        done || true

    # --- Category: debug-statement ---
    # Only flag in non-test files
    if [ "$is_test" -eq 0 ]; then
        case "$file" in
            *.py)
                # Python: print() used as debug (not in logging context)
                /usr/bin/grep -nE '^\s*print\(' "$file" 2>/dev/null |
                    /usr/bin/grep -vE '(logging|logger|log\.)' |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                # Python: breakpoint(), pdb
                /usr/bin/grep -nE '^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debugger statement: ${evidence}" "HIGH"
                    done || true
                ;;
            *.js | *.ts | *.jsx | *.tsx)
                # JavaScript/TypeScript: console.log, console.debug, console.warn
                /usr/bin/grep -nE '^\s*console\.(log|debug|warn|info|trace)\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Console debug statement: ${evidence}" "HIGH"
                    done || true
                # debugger keyword
                /usr/bin/grep -nE '^\s*debugger\s*;?\s*$' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debugger keyword: ${evidence}" "HIGH"
                    done || true
                ;;
            *.rb)
                # Ruby: binding.pry, puts used as debug
                /usr/bin/grep -nE '^\s*(binding\.pry|binding\.irb|byebug)\b' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Ruby debugger: ${evidence}" "HIGH"
                    done || true
                ;;
            *.go)
                # Go: fmt.Println used as debug (not in main or test)
                /usr/bin/grep -nE '^\s*fmt\.Print(ln|f)?\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                ;;
            *.java | *.kt)
                # Java/Kotlin: System.out.println, System.err.println
                /usr/bin/grep -nE '^\s*System\.(out|err)\.print(ln)?\(' "$file" 2>/dev/null |
                    while IFS=: read -r line_num content; do
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "debug-statement" \
                            "Debug print statement: ${evidence}" "HIGH"
                    done || true
                ;;
        esac
    fi

    # --- Category: empty-handler ---

    case "$file" in
        *.py)
            # Python: except with only pass
            /usr/bin/grep -nE '^\s*except' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    next_line=$(/usr/bin/sed -n "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -m1 -E '\S' | /usr/bin/head -1)
                    if echo "$next_line" | /usr/bin/grep -qE '^\s*pass\s*$' 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty except block (pass): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            # JS/TS: catch with empty body
            /usr/bin/grep -nE 'catch\s*\([^)]*\)\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.java | *.kt)
            # Java/Kotlin: catch with empty body
            /usr/bin/grep -nE 'catch\s*\([^)]*\)\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            # Ruby: rescue with no body
            /usr/bin/grep -nE '^\s*rescue\b' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    next_line=$(/usr/bin/sed -n "$((line_num + 1)),\$p" "$file" |
                        /usr/bin/grep -m1 -E '\S' | /usr/bin/head -1)
                    if echo "$next_line" | /usr/bin/grep -qE '^\s*(end|rescue)\s*$' 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.80s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty rescue block: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.go)
            # Go: if err != nil with empty body
            /usr/bin/grep -nE 'if err != nil\s*\{\s*\}' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Swallowed error: ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
