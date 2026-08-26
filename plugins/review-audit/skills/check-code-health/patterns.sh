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
# The `>>> shared:` regions below stay in the bash fallback and are kept
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

# --- declared `stdout_is_output` support (#686) -------------------------------
#
# A repo declares, in its own `.claude/pre-review.yml`, the files whose
# `print()`/`console.log` IS the program's output rather than a debug leftover
# (#680). Without this, a CLI-heavy repo saw every legitimate CLI `print()`
# reported as a HIGH `debug-statement` by /review-audit:codebase-audit, and the
# declaration it had correctly written was simply never read here.
#
# WHY THIS IS DUPLICATED, not sourced. `ship-issue/pre-review-gates.sh` is the
# reference implementation, but it lives in the `workflow` plugin:
# CLAUDE_PLUGIN_ROOT is plugin-scoped, the two plugins declare no dependency on
# each other, and a user may install `review-audit` without `workflow`. So the
# logic must physically exist in both — the same rationale the
# `shared:debug-print-scan` / `shared:debugger-scan` / `shared:is-test-file`
# regions already carry.
#
# WHAT IS AND IS NOT PINNED AS SHARED. Only the PARSER below is a `shared:`
# region. It is a zero-dependency leaf, so the two copies can be — and are held —
# byte-identical. The loader and predicate after it are DELIBERATELY NOT shared:
# pre-review-gates.sh reads four keys (`test_skip_patterns`, `test_patterns`,
# `test_discovery`, `stdout_is_output`) and seeds three temp repos, while this
# scanner implements only the last and needs exactly one. A shared region demands
# byte-identity, so pinning a deliberately-trimmed subset would force this plugin
# to carry three config keys it does not act on. That divergence is the design,
# not drift — which is why the sync gate is pointed at the parser alone.

# >>> shared:yaml-list-parser (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
read_yaml_list() {
    local key="$1" file="$2"
    local line item in_section=false

    [ -f "$file" ] || return 0

    # `|| [ -n "$line" ]` so a final line with no trailing newline is not lost.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "${key}:"*)
                in_section=true
                continue
                ;;
            # Any other line starting in column 0 with a letter/underscore is
            # the NEXT top-level key, which ends this section. Matches the old
            # sed range terminator `/^[a-zA-Z_]/` exactly.
            [a-zA-Z_]*)
                in_section=false
                continue
                ;;
        esac

        $in_section || continue

        item="$line"
        # Strip the `- ` list marker: leading whitespace, the `-`, and the
        # whitespace after it. Mirrors 's/^[[:space:]]*-[[:space:]]*//' — note
        # that expression requires the `-`, so a line WITHOUT one keeps its
        # leading whitespace verbatim. Only strip when the marker is actually
        # present, or a malformed no-dash line would silently change shape.
        local unindented="${item#"${item%%[![:space:]]*}"}"
        case "$unindented" in
            -*)
                item="${unindented#-}"
                item="${item#"${item%%[![:space:]]*}"}"
                ;;
        esac

        # Strip ONE layer of surrounding quotes, leading side independent of
        # trailing — matching the old two-expression pipeline
        # (`s/^["']//` then `s/["']\s*$//`).
        case "$item" in
            \"*) item="${item#\"}" ;;
            \'*) item="${item#\'}" ;;
        esac

        # Trailing side: strip whitespace UNCONDITIONALLY, then a closing quote.
        # So `- a.py  ` and `- "a.py"  ` both land on `a.py`.
        #
        # Whitespace INSIDE the quotes is preserved (`- "a.py  "` keeps its two
        # spaces), mirroring the leading side, which likewise strips only up to
        # the opening quote. An explicit quote is the one way to declare that
        # the space is meant, so it stays the escape hatch rather than being
        # stripped along with the accidental kind.
        #
        # This deliberately DIVERGES from the old GNU pipeline (#684). That
        # expression was `["']\s*$` — the whitespace run only came off when a
        # QUOTE sat in front of it, so an unquoted `- a.py  ` kept its trailing
        # spaces. #679 mirrored the quirk byte-for-byte because its contract was
        # identical GNU output and a silent behaviour change riding along on a
        # portability fix is hard to attribute later. This is that quirk's own
        # issue, so the change is made here on purpose and in isolation.
        #
        # It is load-bearing for exactly ONE consumer, which is why it is worth
        # changing rather than pinning. A key whose values become gitignore
        # patterns is unaffected — git strips trailing whitespace from those
        # itself, so the quirk is invisible there. But a key whose values are
        # resolved as literal paths (`[ -f "$resolved" ]`) is not: a trailing
        # space names a file that does not exist, so the entry silently resolved
        # to nothing and the finding it should have suppressed was reported
        # anyway — a false finding with no visible cause. In this file that
        # consumer is `test_discovery` (see declared_test_paths).
        item="${item%"${item##*[![:space:]]}"}"
        case "$item" in
            *\") item="${item%\"}" ;;
            *\') item="${item%\'}" ;;
        esac

        # Drop blank lines, mirroring the old `sed '/^$/d'`.
        [ -n "$item" ] || continue

        command printf '%s\n' "$item"
    done <"$file"
}
# <<< shared:yaml-list-parser

# --- loader + predicate (NOT shared — see the divergence note above) ----------

# Lazily-populated state. Pre-initialized because this script runs `set -u`.
_STDOUT_POLICY_LOADED=false
_PROJECT_ROOT=""
_STDOUT_PATTERNS=""
_STDOUT_PATTERN_REPO=""

# load_stdout_policy — read `stdout_is_output` from the project's
# .claude/pre-review.yml into a throwaway git repo, once per run.
#
# Matching is delegated to `git check-ignore` (see the predicate below) rather
# than to a hand-rolled glob matcher, so a declared pattern means exactly what it
# would mean in a .gitignore. Same engine, same semantics as the reference
# implementation — which is what lets the two agree without either one
# reimplementing the other's matcher.
load_stdout_policy() {
    $_STDOUT_POLICY_LOADED && return 0
    _STDOUT_POLICY_LOADED=true

    _PROJECT_ROOT=$(command git rev-parse --show-toplevel 2>/dev/null || command pwd)
    local project_config="${_PROJECT_ROOT}/.claude/pre-review.yml"
    [ -f "$project_config" ] || return 0

    _STDOUT_PATTERNS="$(read_yaml_list stdout_is_output "$project_config")"

    # No declaration -> no repo -> the predicate is false for every file, and
    # this scanner behaves exactly as it did before #686. The empty-config path
    # is the common one and must stay a no-op.
    if [ -n "$_STDOUT_PATTERNS" ]; then
        _STDOUT_PATTERN_REPO=$(command mktemp -d)
        command git init -q "$_STDOUT_PATTERN_REPO" 2>/dev/null
        command printf '%s\n' "$_STDOUT_PATTERNS" \
            >"${_STDOUT_PATTERN_REPO}/.git/info/exclude"
    fi
}

# ONE CLEANUP BRANCH PER `mktemp -d` ABOVE. #680 added a third temp repo to the
# reference implementation without a matching branch and leaked it; the failure
# is silent (a stray /tmp dir, no error, no wrong output), so the trap ships
# together with the mktemp rather than being remembered afterwards.
cleanup_stdout_policy() {
    if [ -n "$_STDOUT_PATTERN_REPO" ]; then
        command rm -rf "$_STDOUT_PATTERN_REPO"
    fi
}
trap cleanup_stdout_policy EXIT

# matches_declared_stdout_pattern FILE — 0 when the project declared this file
# under `stdout_is_output`. Always false when nothing was declared, so a repo
# with no config keeps the pre-#686 behaviour exactly.
#
# NO wall-clock bound on the git calls here, unlike the python primary, which
# passes `timeout=` to each subprocess. Deliberate: bounding a command portably
# needs the `bounded_run` helper (a GNU `timeout` is not on base macOS), that
# helper lives in the WORKFLOW plugin, and this plugin cannot source it — the
# same boundary that forces the duplication above. Adding a third copy of it to
# guard a path that only runs when python is absent is not a trade worth making.
# The exposure is small and equal to the pre-#686 status quo: git here is local
# and metadata-only, and a hang would stall a scan rather than corrupt one.
#
# Scoped to the PRINT family by its only caller — a declared file's breakpoints
# still fire (#680 AC3). Deliberately a separate key from any test-related one:
# "legitimately writes to stdout" and "needs no test of its own" are different
# claims, and conflating them would silence unrelated findings as a side effect.
matches_declared_stdout_pattern() {
    load_stdout_policy
    [ -n "$_STDOUT_PATTERN_REPO" ] || return 1

    local relpath="$1"
    if [ -n "$_PROJECT_ROOT" ] && [ "$_PROJECT_ROOT" != "." ]; then
        relpath="${relpath#"${_PROJECT_ROOT}/"}"
    fi
    case "$relpath" in
        /*) relpath="${relpath#/}" ;;
    esac
    command git -C "$_STDOUT_PATTERN_REPO" check-ignore -q --no-index "$relpath" 2>/dev/null
}

# >>> shared:is-test-file (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
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
# Category: debug-statement — split into two families (#680).
#
# The per-language `case`s below are a DELIBERATE cross-plugin duplicate of
# ship-issue/pre-review-gates.sh (review-audit and workflow install
# independently, so neither can source the other). Both regions are kept
# byte-identical by tests/validate-shared-scanner-sync.sh — edit both copies
# together.
#
#   shared:debug-print-scan  — writes to stdout (print, console.*, fmt.Print*,
#                              System.out/err.print*). In a CLI these ARE the
#                              program's output, which is why a project may
#                              declare them exempt via `stdout_is_output`.
#   shared:debugger-scan     — breakpoints (breakpoint(), pdb, the `debugger`
#                              keyword, binding.pry, byebug). NEVER exempt:
#                              none is ever a program's output.
#
# BOTH copies now honor the declaration (#686): the loader above reads
# `stdout_is_output` and the dispatcher gates ONLY the print family, so a
# declared CLI file keeps its breakpoint findings. The split is what makes that
# possible — it is the seam the exemption applies to, which is why it exists
# structurally rather than as a comment.
#
# NO is_scanner_pattern_line guard in either region, unlike pre-review-gates'
# ai-slop arms (#604): every pattern is `^\s*`-anchored, and a scanner's own
# pattern literal always sits INSIDE a grep invocation indented in a function,
# so it can never match line-start. The guard suppressed nothing real (measured:
# 0 rows) while silently dropping genuine debug statements whose ARGUMENT looked
# like a regex, e.g. `print(re.search(r"\d+", data))`. Keep new patterns
# anchored.
# =============================================================================

# scan_debug_prints FILE — the stdout-writing arms.
scan_debug_prints() {
    local file="$1"
    local line_num content evidence

    # >>> shared:debug-print-scan (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
    #
    # CASE-INSENSITIVE extension arms (#754). patterns.py lowercases the
    # extension once per file before dispatch, so a literal `case` here scanned
    # `Debug.PY` under python and skipped it entirely under bash — a silent
    # parity divergence with no error and exit 0. Bracket classes keep the match
    # fork-free and bash-3.2 clean (`${file,,}` is bash 4; macOS ships 3.2).
    case "$file" in
        *.[Pp][Yy])
            # Python: print() used as debug (not in logging context)
            command grep -nE -- '^[[:space:]]*print\(' "$file" 2>/dev/null |
                command grep -vE '(logging|logger|log\.)' |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Jj][Ss] | *.[Tt][Ss] | *.[Jj][Ss][Xx] | *.[Tt][Ss][Xx] | *.[Mm][Jj][Ss] | *.[Cc][Jj][Ss])
            # JavaScript/TypeScript: console.log, console.debug, console.warn
            command grep -nE -- '^[[:space:]]*console\.(log|debug|warn|info|trace)\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Console debug statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Gg][Oo])
            # Go: fmt.Println used as debug (not in main or test)
            command grep -nE -- '^[[:space:]]*fmt\.Print(ln|f)?\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Jj][Aa][Vv][Aa] | *.[Kk][Tt])
            # Java/Kotlin: System.out.println, System.err.println
            command grep -nE -- '^[[:space:]]*System\.(out|err)\.print(ln)?\(' "$file" 2>/dev/null |
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
    # <<< shared:debug-print-scan
}

# scan_debugger_statements FILE — the breakpoint arms. Never exempted.
scan_debugger_statements() {
    local file="$1"
    local line_num content evidence

    # >>> shared:debugger-scan (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
    #
    # CASE-INSENSITIVE extension arms, same rule and same reason as
    # shared:debug-print-scan above (#754).
    case "$file" in
        *.[Pp][Yy])
            # Python: breakpoint(), pdb
            command grep -nE -- '^[[:space:]]*(breakpoint\(\)|import pdb|pdb\.set_trace)' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Jj][Ss] | *.[Tt][Ss] | *.[Jj][Ss][Xx] | *.[Tt][Ss][Xx] | *.[Mm][Jj][Ss] | *.[Cc][Jj][Ss])
            # debugger keyword
            command grep -nE -- '^[[:space:]]*debugger[[:space:]]*;?[[:space:]]*$' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debugger keyword: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Rr][Bb])
            # Ruby: binding.pry, puts used as debug
            command grep -nE -- '^[[:space:]]*(binding\.pry|binding\.irb|byebug)\b' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Ruby debugger: ${evidence}" "HIGH"
                done || true
            ;;
    esac
    # <<< shared:debugger-scan
}

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
    command grep -niE -- '\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "tech-debt-marker" \
                "Tech debt marker: ${evidence}" "HIGH"
        done || true

    # --- Category: debug-statement ---
    # Only flag in non-test files. The PRINT family is skipped when the project
    # declared this file under `stdout_is_output` (#686); the DEBUGGER family
    # runs unconditionally (#680 AC3).
    #
    # Two separate statements on purpose. Written as one `if/else` there would be
    # a control path on which the declaration suppresses a breakpoint too; as
    # written, no such path exists — the exemption structurally cannot reach the
    # debugger arm, which is the property AC3 asks for.
    if [ "$is_test" -eq 0 ]; then
        matches_declared_stdout_pattern "$file" || scan_debug_prints "$file"
        scan_debugger_statements "$file"
    fi

    # --- Category: empty-handler ---
    #
    # CASE-INSENSITIVE extension arms, same rule and same reason as the two
    # shared debug regions above (#754). This block is NOT inside a shared
    # region, which is exactly how it was missed on the first pass — the sync
    # gate had nothing to say about it and the two regions it sits between were
    # already converted. tests/lint-scanner-case-dispatch.sh is the backstop.
    case "$file" in
        *.[Pp][Yy])
            # Python: except with only pass
            command grep -nE -- '^[[:space:]]*except' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    next_line=$(command sed -n -- "$((line_num + 1)),\$p" "$file" |
                        command grep -m1 -E '[^[:space:]]' | command head -1)
                    if command printf '%s\n' "$next_line" | command grep -qE '^[[:space:]]*pass[[:space:]]*$' 2>/dev/null; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty except block (pass): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.[Jj][Ss] | *.[Tt][Ss] | *.[Jj][Ss][Xx] | *.[Tt][Ss][Xx])
            # JS/TS: catch with empty body
            command grep -nE -- 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Jj][Aa][Vv][Aa] | *.[Kk][Tt])
            # Java/Kotlin: catch with empty body
            command grep -nE -- 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Empty catch block: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Rr][Bb])
            # Ruby: rescue with no body
            command grep -nE -- '^[[:space:]]*rescue\b' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    next_line=$(command sed -n -- "$((line_num + 1)),\$p" "$file" |
                        command grep -m1 -E '[^[:space:]]' | command head -1)
                    if command printf '%s\n' "$next_line" | command grep -qE '^[[:space:]]*(end|rescue)[[:space:]]*$' 2>/dev/null; then
                        evidence=$(truncate_chars 80 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "empty-handler" \
                            "Empty rescue block: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.[Gg][Oo])
            # Go: if err != nil with empty body
            command grep -nE -- 'if err != nil[[:space:]]*\{[[:space:]]*\}' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "empty-handler" \
                        "Swallowed error: ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
