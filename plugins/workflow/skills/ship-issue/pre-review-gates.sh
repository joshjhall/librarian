#!/usr/bin/env bash
# ship-issue — Pre-Review Gates (Deterministic Pre-Scan)
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

# =============================================================================
# Test-skip policy: gitignore-style patterns for files that don't need tests.
# Uses git check-ignore as the matching engine for full gitignore semantics
# (globs, ** recursion, ! negation, order-of-application).
#
# Defaults: test-skip-patterns.default (colocated with this script)
# Project overrides: .claude/pre-review.yml → test_skip_patterns section
# =============================================================================

SCRIPT_DIR="$(command dirname "$(command readlink -f "${BASH_SOURCE[0]}")")"
_SKIP_POLICY_REPO=""
_SKIP_POLICY_LOADED=false
_PROJECT_ROOT=""
# Declared conventions from .claude/pre-review.yml (#568). Both are newline-
# delimited and EMPTY unless the project declares them, which is what keeps the
# built-in heuristics the only behaviour for a repo with no config.
#   _TEST_PATTERNS   — gitignore-style globs of files that ARE tests
#   _TEST_DISCOVERY  — {name}-templated paths locating the test FOR a source
_TEST_PATTERNS=""
_TEST_DISCOVERY=""
# Second temp repo, created only when test_patterns are declared. MUST be
# initialized here: the script runs under `set -u`, so a bare reference before
# assignment would abort the whole scan.
_TEST_PATTERN_REPO=""

# read_yaml_list KEY FILE — the list items under top-level KEY, one per line.
# Extracts the lines between `KEY:` and the next top-level key (or EOF), then
# strips the YAML list prefix and surrounding quotes. Shared by all three keys
# so they cannot drift in how they parse (#568).
read_yaml_list() {
    command sed -n "/^$1:/,/^[a-zA-Z_]/{/^$1:/d;/^[a-zA-Z_]/d;p}" "$2" 2>/dev/null |
        command sed 's/^[[:space:]]*-[[:space:]]*//' |
        command sed 's/^["'\'']//' | command sed 's/["'\'']\s*$//' |
        command sed '/^$/d'
}

# load_test_skip_policy — Merge default + project patterns into a temp git repo.
# Called once lazily on first is_test_skipped() call.
load_test_skip_policy() {
    $_SKIP_POLICY_LOADED && return

    _SKIP_POLICY_REPO=$(command mktemp -d)
    command git init -q "$_SKIP_POLICY_REPO" 2>/dev/null

    local merged="${_SKIP_POLICY_REPO}/merged-patterns"
    command touch "$merged"

    # 1. Load defaults (colocated with this script)
    local defaults="${SCRIPT_DIR}/test-skip-patterns.default"
    if [ -f "$defaults" ]; then
        command cat "$defaults" >>"$merged"
        command printf '\n' >>"$merged"
    fi

    # 2. Load project overrides from .claude/pre-review.yml
    _PROJECT_ROOT=$(command git rev-parse --show-toplevel 2>/dev/null || command pwd)
    local project_root="$_PROJECT_ROOT"
    local project_config="${project_root}/.claude/pre-review.yml"

    if [ -f "$project_config" ]; then
        read_yaml_list test_skip_patterns "$project_config" >>"$merged"
        command printf '\n' >>"$merged"

        # Declared test conventions (#568). A repo whose tests the built-in
        # heuristics cannot infer declares them here rather than hoping a
        # widened heuristic guesses right — a wrongly-inferred test is a SILENT
        # false negative, so the built-ins stay conservative and this is the
        # supported escape hatch.
        _TEST_PATTERNS="$(read_yaml_list test_patterns "$project_config")"
        _TEST_DISCOVERY="$(read_yaml_list test_discovery "$project_config")"

        # test_patterns are matched by the same git check-ignore engine as the
        # skip patterns, in their OWN exclude file so the two sets cannot
        # contaminate each other.
        if [ -n "$_TEST_PATTERNS" ]; then
            _TEST_PATTERN_REPO=$(command mktemp -d)
            command git init -q "$_TEST_PATTERN_REPO" 2>/dev/null
            command printf '%s\n' "$_TEST_PATTERNS" \
                >"${_TEST_PATTERN_REPO}/.git/info/exclude"
        fi
    fi

    # Symlink as .git/info/exclude so git check-ignore uses our patterns
    command ln -sf "$merged" "${_SKIP_POLICY_REPO}/.git/info/exclude"

    _SKIP_POLICY_LOADED=true
}

# matches_declared_test_pattern FILE — 0 when the project declared this file as
# a test via `test_patterns` (#568). Always false when nothing was declared.
matches_declared_test_pattern() {
    load_test_skip_policy
    [ -n "$_TEST_PATTERN_REPO" ] || return 1

    local relpath="$1"
    if [ -n "$_PROJECT_ROOT" ] && [ "$_PROJECT_ROOT" != "." ]; then
        relpath="${relpath#"${_PROJECT_ROOT}/"}"
    fi
    case "$relpath" in
        /*) relpath="${relpath#/}" ;;
    esac
    command git -C "$_TEST_PATTERN_REPO" check-ignore -q --no-index "$relpath" 2>/dev/null
}

# declared_test_paths FILE — existing files that the project's `test_discovery`
# templates resolve to for this source, one per line (#568). Each template
# carries `{name}`, the source basename with its extension stripped; templates
# are repo-relative unless absolute. Empty when nothing is declared or nothing
# resolves.
declared_test_paths() {
    load_test_skip_policy
    [ -n "$_TEST_DISCOVERY" ] || return 0

    local base name_no_ext template resolved
    base="${1##*/}"
    name_no_ext="${base%.*}"

    while IFS= read -r template; do
        [ -n "$template" ] || continue
        # Pure bash substitution — no sed, so a name containing regex or sed
        # metacharacters cannot alter the template.
        resolved="${template//\{name\}/$name_no_ext}"
        case "$resolved" in
            /*) ;;
            *) resolved="${_PROJECT_ROOT}/${resolved}" ;;
        esac
        [ -f "$resolved" ] && command printf '%s\n' "$resolved"
    done <<EOF
$_TEST_DISCOVERY
EOF
}

# has_declared_test FILE — 0 when at least one declared template resolves.
has_declared_test() {
    local hit
    hit="$(declared_test_paths "$1")"
    [ -n "$hit" ]
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
    command git -C "$_SKIP_POLICY_REPO" check-ignore -q --no-index "$relpath" 2>/dev/null
}

# Cleanup temp repos on exit
cleanup_skip_policy() {
    if [ -n "$_SKIP_POLICY_REPO" ]; then
        command rm -rf "$_SKIP_POLICY_REPO"
    fi
    if [ -n "$_TEST_PATTERN_REPO" ]; then
        command rm -rf "$_TEST_PATTERN_REPO"
    fi
}
trap cleanup_skip_policy EXIT

# >>> shared:is-test-file (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
# is_test_file PATH — return 0 (true) if PATH is a test file by path/name
# convention. PATH-ONLY: content-colocated tests (Rust #[cfg(test)] blocks in
# real source files) are NOT this function's job. Segment-anchored so that
# contest.py / latest.js / attestation.go (which a bare *test* glob wrongly
# matches) are NOT skipped, while tests/helper.py (which a suffix-only set
# wrongly scans) IS. Handles both repo-relative and absolute path forms.
#
# The two arm groups anchor DIFFERENTLY, and the split is load-bearing (#568):
# in a bash `case` glob, `*` crosses `/`, so a path arm like `*/test_*.*` also
# matches a DIRECTORY named `test_helpers/` — silencing every scanner for real
# source at `src/test_helpers/production.py`. Directory arms are meant to cross
# slashes; the name arms are matched against the BASENAME so they cannot.
is_test_file() {
    case "$1" in
        tests/* | */tests/* | test/* | */test/* | \
            __tests__/* | */__tests__/* | spec/* | */spec/* | \
            __pycache__/* | */__pycache__/*) return 0 ;;
    esac
    case "${1##*/}" in
        test_*.*) return 0 ;;
        *_test.* | *_spec.* | *.test.* | *.spec.*) return 0 ;;
    esac
    return 1
}
# <<< shared:is-test-file

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
    command grep -niE -- '\b(it.s worth noting that|it is worth noting that|importantly,|notably,|broadly speaking|in essence,|at its core,|fundamentally,)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Hedging phrase: ${evidence}" "HIGH"
        done || true

    # Buzzword inflation
    command grep -niE -- '\b(enterprise[- ]grade|robust and scalable|seamlessly integrat|leverage the power of|cutting[- ]edge|state[- ]of[- ]the[- ]art|world[- ]class)\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Buzzword inflation: ${evidence}" "HIGH"
        done || true

    # Filler phrases in comments/docstrings
    command grep -niE -- '\b(this (function|method|class) (is responsible for|handles|takes care of|provides|ensures that)|as (mentioned|discussed|noted) (above|earlier|previously|before))\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Filler phrase: ${evidence}" "MEDIUM"
        done || true

    # Placeholder/stub text left behind
    command grep -niE -- '(# TODO: implement|// TODO: implement|raise NotImplementedError|throw new Error\(.not implemented)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Unimplemented placeholder: ${evidence}" "HIGH"
        done || true
}

# =============================================================================
# Category: debug-statement
# The per-language detection `case` below is a DELIBERATE cross-plugin duplicate
# of check-code-health/patterns.sh: review-audit and workflow install
# independently, so this script cannot source that one at runtime. The shared
# region (between the sentinel comments) is kept byte-for-byte in sync by
# tests/validate-shared-scanner-sync.sh — edit both copies together.
# =============================================================================

scan_debug_statements() {
    local file="$1"

    # Skip non-source files and test files
    case "$file" in
        *.lock | *lock.json | *go.sum | *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) return ;;
    esac
    is_test_file "$file" && return
    # ...including any the project DECLARED as tests (#568): a debug statement
    # in a declared test is as intentional as one in tests/.
    matches_declared_test_pattern "$file" && return

    # >>> shared:debug-statement-scan (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
    # This case is a DELIBERATE cross-plugin duplicate: review-audit and
    # workflow install independently, so pre-review-gates.sh cannot source
    # it. Edit both copies together; the drift guard fails CI otherwise.
    case "$file" in
        *.py)
            # Python: print() used as debug (not in logging context)
            command grep -nE -- '^\s*print\(' "$file" 2>/dev/null |
                command grep -vE '(logging|logger|log\.)' |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            # Python: breakpoint(), pdb
            command grep -nE -- '^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            # JavaScript/TypeScript: console.log, console.debug, console.warn
            command grep -nE -- '^\s*console\.(log|debug|warn|info|trace)\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Console debug statement: ${evidence}" "HIGH"
                done || true
            # debugger keyword
            command grep -nE -- '^\s*debugger\s*;?\s*$' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger keyword: ${evidence}" "HIGH"
                done || true
            ;;
        *.rb)
            # Ruby: binding.pry, puts used as debug
            command grep -nE -- '^\s*(binding\.pry|binding\.irb|byebug)\b' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Ruby debugger: ${evidence}" "HIGH"
                done || true
            ;;
        *.go)
            # Go: fmt.Println used as debug (not in main or test)
            command grep -nE -- '^\s*fmt\.Print(ln|f)?\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.java | *.kt)
            # Java/Kotlin: System.out.println, System.err.println
            command grep -nE -- '^\s*System\.(out|err)\.print(ln)?\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            ;;
    esac
    # <<< shared:debug-statement-scan
}

# =============================================================================
# Category: missing-test-file
# Source files with no corresponding test file.
# =============================================================================

# js_test_find_args <name-no-ext> — echo the `find` OR-chain matching any test
# named after this source, one shell-quoted token per line (#555, #568).
#
# Widened over the `py` arm's single-pattern find in two ways, because the
# js/ts ecosystem has no single convention:
#
#   stems — <name>.test, <name>.spec, test-<name>, test_<name>, spec-<name>,
#           validate-<name>; each matched as <stem>.<ext>, <stem>-*.<ext> and
#           <stem>_*.<ext>, so `validate-workflow-helpers.mjs` covers
#           `workflow.js`.
#   exts  — the whole js/ts family, NOT the source's own extension, which is
#           the cross-extension half of the bug.
#
# The stem list stays anchored to the source name rather than matching any test
# in the tree: `report.js` must not be satisfied by an unrelated
# `validate-workflow-helpers.mjs`.
#
# Emitted one token per line so callers rebuild an array with a `while read`
# (bash-3.2 has no mapfile). Tokens are never whitespace-bearing: they are
# literal `-name`/`-o` flags and globs built from a basename with its extension
# stripped.
js_test_find_args() {
    local name_no_ext="$1"
    local stem ext first=1
    for stem in \
        "${name_no_ext}.test" "${name_no_ext}.spec" \
        "test-${name_no_ext}" "test_${name_no_ext}" \
        "spec-${name_no_ext}" "validate-${name_no_ext}"; do
        for ext in js mjs cjs ts tsx jsx; do
            if [ "$first" -eq 1 ]; then first=0; else command printf '%s\n' "-o"; fi
            command printf '%s\n' "-name" "${stem}.${ext}"
            command printf '%s\n' "-o" "-name" "${stem}-*.${ext}"
            command printf '%s\n' "-o" "-name" "${stem}_*.${ext}"
        done
    done
}

# find_repo_rooted_js_tests <name-no-ext> [max] — paths of tests under
# <_PROJECT_ROOT>/tests named after this source, one per line (empty if none).
#
# `-type f` is load-bearing, not decoration: without it a DIRECTORY whose name
# matches a stem (a `tests/validate-thing-snapshots.js/` fixture or snapshot
# dir) satisfies the probe and silently suppresses a real finding. A false
# negative here hides exactly the bug this scanner exists to report.
#
# Command substitution, not a pipe into `grep -q`/`head`: under `set -o
# pipefail` a find|head-shaped probe exits 141 (SIGPIPE) when find outruns the
# reader, which would read as a scan failure.
#
# The caller has already checked that <_PROJECT_ROOT>/tests exists.
find_repo_rooted_js_tests() {
    local name_no_ext="$1" max="${2:-0}"
    local find_args=() tok
    while IFS= read -r tok; do
        find_args+=("$tok")
    done <<EOF
$(js_test_find_args "$name_no_ext")
EOF

    if [ "$max" = "1" ]; then
        command find "${_PROJECT_ROOT}/tests" -type f \
            \( "${find_args[@]}" \) -print -quit 2>/dev/null
    else
        command find "${_PROJECT_ROOT}/tests" -type f \
            \( "${find_args[@]}" \) -print 2>/dev/null
    fi
}

# has_repo_rooted_js_test <name-no-ext> — 0 when at least one such test exists.
has_repo_rooted_js_test() {
    local hit
    hit="$(find_repo_rooted_js_tests "$1" 1)"
    [ -n "$hit" ]
}

scan_missing_tests() {
    local file="$1"

    # Skip test files themselves
    is_test_file "$file" && return
    # ...including any the project DECLARED as tests (#568).
    matches_declared_test_pattern "$file" && return

    # Check against configurable skip policy (gitignore-style patterns)
    if is_test_skipped "$file"; then
        return
    fi

    # A DECLARED discovery template that resolves wins over every built-in
    # probe below (#568) — it is the project stating its convention outright,
    # which is strictly better evidence than any heuristic this scanner infers.
    has_declared_test "$file" && return

    local basename dirname name_no_ext ext
    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
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
                command find "${_PROJECT_ROOT}/tests" \
                    -name "test_${name_no_ext}.py" \
                    -print -quit 2>/dev/null | command grep -q . && return
            fi
            ;;
        ts | js | tsx | jsx | mjs | cjs)
            for suffix in "test" "spec"; do
                for test_path in \
                    "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/../__tests__/${name_no_ext}.${suffix}.${ext}"; do
                    [ -f "$test_path" ] && return
                done
            done
            # Repo-rooted tests/ tree (#555). The colocated probes above miss a
            # test that lives under <root>/tests/ rather than beside the source
            # — and, because they interpolate the SOURCE's own ${ext}, they also
            # miss a .js source tested from a .mjs file. This fallback drops
            # both restrictions.
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                has_repo_rooted_js_test "$name_no_ext" && return
            fi
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
                if ! command grep -qE -- \
                    '^[[:space:]]*((pub[[:space:]]+)?(fn|impl|struct|enum|trait)\b|macro_rules!)' \
                    "$file" 2>/dev/null; then
                    return
                fi
            fi
            command grep -q -- '#\[cfg(test)\]' "$file" 2>/dev/null && return
            [ -d "${dirname}/../tests" ] && return
            ;;
        rb | java | kt)
            # Known source extensions — no test lookup implemented yet, but
            # these are real source files so flag as HIGH
            ;;
        *)
            # Unknown extension not in skip policy — warn at MEDIUM
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "1" "missing-test-file" \
                "Unknown file type — verify if tests are needed: ${basename}" "MEDIUM"
            return
            ;;
    esac

    command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    is_test_file "$file" && return
    # ...including any the project DECLARED as tests (#568).
    matches_declared_test_pattern "$file" && return

    # Check against configurable skip policy
    if is_test_skipped "$file"; then
        return
    fi

    local basename dirname name_no_ext ext repo_rooted_tests declared
    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    # NOTE: each `func_name` below is captured by a `[a-zA-Z][a-zA-Z0-9_]*`
    # sed group, so it can only ever contain [A-Za-z0-9_] — no ERE
    # metacharacters. That invariant is why interpolating it into the
    # `\b${func_name}\b` grep pattern is safe without escaping; keep the
    # capture groups alnum-only if these extractors ever change.
    case "$ext" in
        py)
            command grep -nE -- '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(command printf '%s' "$content" | command sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    if ! command grep -rql -- "\b${func_name}\b" \
                        "${dirname}"/test_*.py \
                        "${dirname}"/tests/test_*.py \
                        "${dirname}"/../tests/test_*.py 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        go)
            command grep -nE -- '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    if [ -f "$test_file" ] && ! command grep -q -- "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        ts | js | tsx | jsx | mjs | cjs)
            # The repo-rooted candidates are resolved ONCE per file, not once
            # per export: the find is the expensive part and it does not depend
            # on the symbol. Only the greps below are per-export.
            repo_rooted_tests=""
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                repo_rooted_tests="$(find_repo_rooted_js_tests "$name_no_ext")"
            fi
            # Declared discovery templates join the SAME candidate list rather
            # than short-circuiting (#568): unlike missing-test-file, the
            # question here is whether a specific symbol is referenced, so the
            # declared file still has to be grepped for it.
            declared="$(declared_test_paths "$file")"
            if [ -n "$declared" ]; then
                repo_rooted_tests="${repo_rooted_tests:+${repo_rooted_tests}
}${declared}"
            fi
            command grep -nE -- '^export (function|const|class) [a-zA-Z]' "$file" 2>/dev/null |
                while IFS=: read -r line_num content; do
                    func_name=$(command printf '%s' "$content" | command sed 's/^export \(function\|const\|class\) \([a-zA-Z][a-zA-Z0-9_]*\).*/\2/')
                    found=false
                    for suffix in "test" "spec"; do
                        for test_path in \
                            "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                            "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}"; do
                            if [ -f "$test_path" ] && command grep -q -- "\b${func_name}\b" "$test_path" 2>/dev/null; then
                                found=true
                                break 2
                            fi
                        done
                    done
                    # Cross-directory fallback (#568): the colocated probes above
                    # cannot see a test in a repo-rooted tests/ tree, so a
                    # genuinely exercised export reported HIGH "no tests
                    # reference". Same candidate set scan_missing_tests uses.
                    if [ "$found" = "false" ] && [ -n "$repo_rooted_tests" ]; then
                        while IFS= read -r test_path; do
                            [ -n "$test_path" ] || continue
                            if command grep -q -- "\b${func_name}\b" "$test_path" 2>/dev/null; then
                                found=true
                                break
                            fi
                        done <<EOF
$repo_rooted_tests
EOF
                    fi
                    if [ "$found" = "false" ]; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
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
