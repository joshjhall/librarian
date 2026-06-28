#!/usr/bin/env bash
# next-issue-ship — Pre-Review Gates (Deterministic Pre-Scan)
#
# Scans changed files for mechanical issues before PR creation:
# AI slop patterns, debug statements, missing tests, untested public APIs.
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

FILE_LIST="${1:?Usage: pre-review-gates.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# =============================================================================
# Test-skip policy: gitignore-style patterns for files that don't need tests.
# Uses git check-ignore as the matching engine for full gitignore semantics
# (globs, ** recursion, ! negation, order-of-application).
#
# Defaults: test-skip-patterns.default (colocated with this script)
# Project overrides: .claude/pre-review.yml → test_skip_patterns section
# =============================================================================

SCRIPT_DIR="$(/usr/bin/dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")"
_SKIP_POLICY_REPO=""
_SKIP_POLICY_LOADED=false
_PROJECT_ROOT=""

# load_test_skip_policy — Merge default + project patterns into a temp git repo.
# Called once lazily on first is_test_skipped() call.
load_test_skip_policy() {
    $_SKIP_POLICY_LOADED && return

    _SKIP_POLICY_REPO=$(/usr/bin/mktemp -d)
    /usr/bin/git init -q "$_SKIP_POLICY_REPO" 2>/dev/null

    local merged="${_SKIP_POLICY_REPO}/merged-patterns"
    /usr/bin/touch "$merged"

    # 1. Load defaults (colocated with this script)
    local defaults="${SCRIPT_DIR}/test-skip-patterns.default"
    if [ -f "$defaults" ]; then
        /usr/bin/cat "$defaults" >>"$merged"
        /usr/bin/printf '\n' >>"$merged"
    fi

    # 2. Load project overrides from .claude/pre-review.yml
    _PROJECT_ROOT=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null || /usr/bin/pwd)
    local project_root="$_PROJECT_ROOT"
    local project_config="${project_root}/.claude/pre-review.yml"

    if [ -f "$project_config" ]; then
        # Extract lines between "test_skip_patterns:" and the next top-level
        # key (or EOF). Strip YAML list prefix ("  - ") and quotes.
        /usr/bin/sed -n '/^test_skip_patterns:/,/^[a-zA-Z_]/{/^test_skip_patterns:/d;/^[a-zA-Z_]/d;p}' \
            "$project_config" 2>/dev/null |
            /usr/bin/sed 's/^[[:space:]]*-[[:space:]]*//' |
            /usr/bin/sed 's/^["'\'']//' | /usr/bin/sed 's/["'\'']\s*$//' |
            /usr/bin/sed '/^$/d' >>"$merged"
        /usr/bin/printf '\n' >>"$merged"
    fi

    # Symlink as .git/info/exclude so git check-ignore uses our patterns
    /usr/bin/ln -sf "$merged" "${_SKIP_POLICY_REPO}/.git/info/exclude"

    _SKIP_POLICY_LOADED=true
}

# is_test_skipped FILE — returns 0 if the file matches skip patterns
is_test_skipped() {
    load_test_skip_policy

    local file="$1"
    # Convert to project-relative path so gitignore patterns like
    # "src/critical/*.css" and "!config/**/*.rb" work correctly.
    local relpath="$file"
    if [ -n "$_PROJECT_ROOT" ] && [ "$_PROJECT_ROOT" != "." ]; then
        relpath="${file#"${_PROJECT_ROOT}/"}"
    fi
    # Fallback: strip leading / for any remaining absolute paths
    case "$relpath" in
        /*) relpath="${relpath#/}" ;;
    esac
    /usr/bin/git -C "$_SKIP_POLICY_REPO" check-ignore -q --no-index "$relpath" 2>/dev/null
}

# Cleanup temp repo on exit
cleanup_skip_policy() {
    if [ -n "$_SKIP_POLICY_REPO" ]; then
        /usr/bin/rm -rf "$_SKIP_POLICY_REPO"
    fi
}
trap cleanup_skip_policy EXIT

# =============================================================================
# Category: ai-slop
# Detects AI-generated artifacts: hedging phrases, buzzword inflation,
# verbose filler, placeholder text. Subset of deslop's 60+ patterns.
# =============================================================================

scan_ai_slop() {
    local file="$1"

    # Skip non-source files
    case "$file" in
        *.lock | *lock.json | *go.sum | *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) return ;;
    esac

    # Hedging phrases — strong indicators of unedited AI output
    /usr/bin/grep -niE '\b(it.s worth noting that|it is worth noting that|importantly,|notably,|broadly speaking|in essence,|at its core,|fundamentally,)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Hedging phrase: ${evidence}" "HIGH"
        done || true

    # Buzzword inflation
    /usr/bin/grep -niE '\b(enterprise[- ]grade|robust and scalable|seamlessly integrat|leverage the power of|cutting[- ]edge|state[- ]of[- ]the[- ]art|world[- ]class)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Buzzword inflation: ${evidence}" "HIGH"
        done || true

    # Filler phrases in comments/docstrings
    /usr/bin/grep -niE '\b(this (function|method|class) (is responsible for|handles|takes care of|provides|ensures that)|as (mentioned|discussed|noted) (above|earlier|previously|before))\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Filler phrase: ${evidence}" "MEDIUM"
        done || true

    # Placeholder/stub text left behind
    /usr/bin/grep -niE '(# TODO: implement|// TODO: implement|raise NotImplementedError|throw new Error\(.not implemented)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Unimplemented placeholder: ${evidence}" "HIGH"
        done || true
}

# =============================================================================
# Category: debug-statement
# Reuses patterns from check-code-health for debug/logging statements
# left in production code.
# =============================================================================

scan_debug_statements() {
    local file="$1"

    # Skip non-source files and test files
    case "$file" in
        *.lock | *lock.json | *go.sum | *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) return ;;
        *_test.* | *.test.* | *.spec.* | *__tests__*) return ;;
    esac

    case "$file" in
        *.py)
            /usr/bin/grep -nE '^\s*print\(' "$file" 2>/dev/null |
                /usr/bin/grep -vE '(logging|logger|log\.)' |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print: ${evidence}" "HIGH"
                done || true
            /usr/bin/grep -nE '^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger: ${evidence}" "HIGH"
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            /usr/bin/grep -nE '^\s*console\.(log|debug|warn|info|trace)\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Console statement: ${evidence}" "HIGH"
                done || true
            /usr/bin/grep -nE '^\s*debugger\s*;?\s*$' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger keyword: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            /usr/bin/grep -nE '^\s*fmt\.Print(ln|f)?\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            /usr/bin/grep -nE '^\s*(binding\.pry|binding\.irb|byebug)\b' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Ruby debugger: ${evidence}" "HIGH"
                done || true
            ;;
        *.java | *.kt)
            /usr/bin/grep -nE '^\s*System\.(out|err)\.print(ln)?\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print: ${evidence}" "HIGH"
                done || true
            ;;
    esac
}

# =============================================================================
# Category: missing-test-file
# Source files with no corresponding test file.
# =============================================================================

scan_missing_tests() {
    local file="$1"

    # Skip test files themselves
    case "$file" in
        *test* | *spec* | *__pycache__*) return ;;
    esac

    # Check against configurable skip policy (gitignore-style patterns)
    if is_test_skipped "$file"; then
        return
    fi

    local basename dirname name_no_ext ext
    basename=$(/usr/bin/basename "$file")
    dirname=$(/usr/bin/dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    # For known source extensions, check for test files (HIGH if missing)
    case "$ext" in
        py)
            for test_path in \
                "${dirname}/test_${name_no_ext}.py" \
                "${dirname}/tests/test_${name_no_ext}.py" \
                "${dirname}/../tests/test_${name_no_ext}.py" \
                "${dirname}/${name_no_ext}_test.py"; do
                [ -f "$test_path" ] && return
            done
            # Repo-rooted tests/ tree (pytest / Django / SciPy convention):
            # source at <root>/<seg>/.../<name>.py with test under
            # <root>/tests/.../test_<name>.py at any depth.
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                /usr/bin/find "${_PROJECT_ROOT}/tests" \
                    -name "test_${name_no_ext}.py" \
                    -print -quit 2>/dev/null | /usr/bin/grep -q . && return
            fi
            ;;
        ts | js | tsx | jsx)
            for suffix in "test" "spec"; do
                for test_path in \
                    "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/../__tests__/${name_no_ext}.${suffix}.${ext}"; do
                    [ -f "$test_path" ] && return
                done
            done
            ;;
        go)
            [ -f "${dirname}/${name_no_ext}_test.go" ] && return
            ;;
        rs)
            # mod.rs aggregator: only mod/pub use/doc/attribute lines, no
            # top-level definitions. Re-exports submodules whose own files
            # carry the tests, so flagging them is shipping-time noise.
            if [ "$basename" = "mod.rs" ]; then
                # `\b` won't match after `!` (both `!` and the following
                # space are non-word), so `macro_rules!` is anchored on its
                # own without a trailing boundary.
                if ! /usr/bin/grep -qE \
                    '^[[:space:]]*((pub[[:space:]]+)?(fn|impl|struct|enum|trait)\b|macro_rules!)' \
                    "$file" 2>/dev/null; then
                    return
                fi
            fi
            /usr/bin/grep -q '#\[cfg(test)\]' "$file" 2>/dev/null && return
            [ -d "${dirname}/../tests" ] && return
            ;;
        rb | java | kt)
            # Known source extensions — no test lookup implemented yet, but
            # these are real source files so flag as HIGH
            ;;
        *)
            # Unknown extension not in skip policy — warn at MEDIUM
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "1" "missing-test-file" \
                "Unknown file type — verify if tests are needed: ${basename}" "MEDIUM"
            return
            ;;
    esac

    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
        "$file" "1" "missing-test-file" \
        "No test file found for ${basename}" "HIGH"
}

# =============================================================================
# Category: untested-public-api
# New public/exported functions without test references.
# =============================================================================

scan_untested_public_api() {
    local file="$1"

    # Skip test files
    case "$file" in
        *test* | *spec* | *__pycache__*) return ;;
    esac

    # Check against configurable skip policy
    if is_test_skipped "$file"; then
        return
    fi

    local basename dirname name_no_ext ext
    basename=$(/usr/bin/basename "$file")
    dirname=$(/usr/bin/dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    case "$ext" in
        py)
            /usr/bin/grep -nE '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    if ! /usr/bin/grep -rql "\b${func_name}\b" \
                        "${dirname}"/test_*.py \
                        "${dirname}"/tests/test_*.py \
                        "${dirname}"/../tests/test_*.py 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        go)
            /usr/bin/grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    if [ -f "$test_file" ] && ! /usr/bin/grep -q "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        ts | js | tsx | jsx)
            /usr/bin/grep -nE '^export (function|const|class) [a-zA-Z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(/usr/bin/printf '%s' "$content" | /usr/bin/sed 's/^export \(function\|const\|class\) \([a-zA-Z][a-zA-Z0-9_]*\).*/\2/')
                    found=false
                    for suffix in "test" "spec"; do
                        for test_path in \
                            "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                            "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}"; do
                            if [ -f "$test_path" ] && /usr/bin/grep -q "\b${func_name}\b" "$test_path" 2>/dev/null; then
                                found=true
                                break 2
                            fi
                        done
                    done
                    if [ "$found" = "false" ]; then
                        evidence=$(/usr/bin/printf '%.60s' "$content")
                        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac
}

# =============================================================================
# Main: iterate over file list, run all scanners
# =============================================================================

while IFS= read -r file; do
    [ -f "$file" ] || continue

    scan_ai_slop "$file"
    scan_debug_statements "$file"
    scan_missing_tests "$file"
    scan_untested_public_api "$file"

done <"$FILE_LIST" || true
