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
#
# PURE BASH, no sed — deliberately (#679). The previous implementation opened
# with a multi-command sed brace block (`{cmd;cmd;p}`), which is GNU-only: BSD
# sed (the macOS default) rejects `;` as a command separator inside braces and
# exits 1. Because the call carried `2>/dev/null`, that error was invisible:
# every key parsed to EMPTY, the declared-convention path went inert, and the
# scan still exited 0 — a project's .claude/pre-review.yml looked applied and
# was not. The trailing quote strip compounded it with `\s`, a GNU regex
# extension that BSD sed reads as a literal `s`.
#
# The format here is a flat list of scalars, so it needs no regex engine at all.
# Parsing it in bash removes the dialect question entirely rather than trading
# one sed dialect for another, and leaves no subprocess whose failure could be
# swallowed. No `2>/dev/null`: an unreadable file is caught by the `[ -f ]`
# guard, and there is nothing else here that can write to stderr.
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

        # Trailing side: remove a closing quote AND any whitespace after it.
        # This is the `\s` site — GNU read `\s` as whitespace, BSD sed reads it
        # as a literal `s`, so on macOS `- "a.py"  ` kept its closing quote and
        # became a pattern matching nothing.
        #
        # The old expression is `["']\s*$`: the whitespace run only comes off
        # when a QUOTE sits in front of it. So an unquoted `- a.py  ` keeps its
        # trailing spaces on GNU today. That is very likely a latent bug (such
        # a glob matches nothing), but fixing it here would be a silent
        # behaviour change riding along on a portability fix — so this mirrors
        # the old semantics exactly and the quirk is left for its own issue.
        local trimmed="${item%"${item##*[![:space:]]}"}"
        case "$trimmed" in
            *\") item="${trimmed%\"}" ;;
            *\') item="${trimmed%\'}" ;;
        esac

        # Drop blank lines, mirroring the old `sed '/^$/d'`.
        [ -n "$item" ] || continue

        command printf '%s\n' "$item"
    done <"$file"
}

# filter_test_discovery LIST — the `test_discovery` entries that are actually
# templates, dropping any that carry no `{name}` placeholder (#601).
#
# An entry without `{name}` is not a template, it is a CONSTANT: it resolves to
# the same path for every source file, so if that path exists, has_declared_test()
# is true for everything and scan_missing_tests returns early for the WHOLE run —
# a silent false negative that takes the category to zero rows while the scan
# still exits 0 and still prints its other categories.
#
# The shape that triggers it is the natural way to reach for this key ("map this
# one oddly-named test to its source"), which is why it is rejected loudly here
# rather than documented as a caveat. A genuine per-source mapping needs its own
# config key with an explicit source side; this key is templates only.
#
# Warns on stderr, never stdout — stdout carries the TSV contract that the review
# harness parses (file/line/category/evidence/certainty), so a diagnostic there
# would be read as a finding.
filter_test_discovery() {
    local list="$1" entry kept="" dropped=""

    [ -n "$list" ] || return 0

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            *'{name}'*) kept="${kept:+${kept}
}${entry}" ;;
            # Comma-joined, not space-joined: a template path may legitimately
            # contain a space, and a space-joined list would leave the warning
            # ambiguous about where one rejected entry ends and the next begins.
            *) dropped="${dropped:+${dropped}, }${entry}" ;;
        esac
    done <<EOF
$list
EOF

    if [ -n "$dropped" ]; then
        command printf '%s\n' \
            "Warning: ignoring test_discovery entries with no {name} placeholder: ${dropped}" \
            "  A constant path resolves for EVERY source, which would silence missing-test-file for the entire run." \
            "  Use a template (e.g. tests/validate-{name}.sh); a per-source mapping needs an explicit source side." >&2
    fi

    [ -n "$kept" ] && command printf '%s\n' "$kept"
    return 0
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
        _TEST_DISCOVERY="$(filter_test_discovery \
            "$(read_yaml_list test_discovery "$project_config")")"

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
#
# TRUST MODEL: templates are NOT sanitized, and a relative template is joined to
# _PROJECT_ROOT without normalizing `..`, so `../../../etc/{name}` resolves
# outside the repo and can suppress a finding. That is accepted, not overlooked:
# .claude/pre-review.yml is the audited repo's OWN file, and the pre-existing
# `test_skip_patterns` key already suppresses any finding with a single line
# (`src/**`), so this grants no capability a hostile config did not already
# have. It is a footgun to document, not a privilege boundary to enforce —
# a template that points outside the repo is a config bug worth noticing.
# The `{name}` expansion itself is a pure bash substitution (no eval, no sed),
# so a source name carrying shell or regex metacharacters cannot alter the
# template or escape the `[ -f ]` test.
#
# That reasoning covers a HOSTILE config. It does not cover an HONEST one that
# quietly disables a detector, which is the failure #601 found: an entry with no
# `{name}` is a constant, resolves for every source, and silences
# missing-test-file for the whole run. Those entries are rejected up front by
# filter_test_discovery(), so every template reaching this function carries a
# placeholder — the loop below can assume expansion actually varies per source.
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

# >>> shared:scanner-pattern-line (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
# is_scanner_pattern_line LINE — return 0 (true) when LINE is a detector's own
# regex SOURCE rather than prose (#599).
#
# The ai-slop and debug-statement patterns are written as literals inside the
# scanners' own `grep`/`re.search` calls, so pointing the pre-scan at a diff
# that touches a scanner file makes every one of those literals match itself.
# Measured over the #567 batch, that was every ai-slop row emitted for a scanner
# file — HIGH certainty, and handed to five reviewers as candidates to
# adjudicate (#556). Systematic, not incidental: it recurs on every PR that
# touches a scanner, which is exactly where reviewer attention is worth most.
#
# LINE-scoped on purpose, NOT path-scoped. Exempting patterns.sh /
# pre-review-gates.sh wholesale is simpler but wrong: a genuine hedging phrase
# in a scanner file's prose comment must still fire. Only the invocation line
# carrying the quoted pattern is suppressed, so the comment two lines above it
# is still scanned normally.
#
# Two arms, one per scanner runtime — a pattern literal reads differently in
# each, and the python primary self-matches just as the bash fallback does:
#   bash    `command grep -niE -- '<pattern>' "$file"`
#   python  `re.search(r"<pattern>", line)` (also re.match / re.compile)
# The flag arm is deliberately `-[a-zA-Z]*` (any short-flag cluster) and
# requires the `--` end-of-options marker plus an opening quote, so an ordinary
# filtering grep with no pattern literal (e.g. `grep -vE '(logging|logger)'`,
# which has no `--`) is NOT suppressed.
is_scanner_pattern_line() {
    case "$1" in
        *grep\ -[a-zA-Z]*\ --\ [\'\"]*) return 0 ;;
        *re.search\(r[\'\"]* | *re.match\(r[\'\"]* | *re.compile\(r[\'\"]*) return 0 ;;
    esac
    return 1
}
# <<< shared:scanner-pattern-line

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
    # ...and test files, which scan_debug_statements has always skipped but this
    # scanner did not (#599). A test fixture GENERATES slop on purpose — the
    # heredocs and `printf` lines that build a corpus case are the detector's
    # own inputs, not unedited AI output. Measured over the #567 batch these
    # fixture-generator lines were the majority of surviving ai-slop rows.
    is_test_file "$file" && return
    matches_declared_test_pattern "$file" && return

    # Hedging phrases — strong indicators of unedited AI output
    command grep -niE -- '\b(it.s worth noting that|it is worth noting that|importantly,|notably,|broadly speaking|in essence,|at its core,|fundamentally,)\b' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            is_scanner_pattern_line "$content" && continue
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Hedging phrase: ${evidence}" "HIGH"
        done || true

    # Buzzword inflation
    command grep -niE -- '\b(enterprise[- ]grade|robust and scalable|seamlessly integrat|leverage the power of|cutting[- ]edge|state[- ]of[- ]the[- ]art|world[- ]class)\b' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            is_scanner_pattern_line "$content" && continue
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Buzzword inflation: ${evidence}" "HIGH"
        done || true

    # Filler phrases in comments/docstrings
    command grep -niE -- '\b(this (function|method|class) (is responsible for|handles|takes care of|provides|ensures that)|as (mentioned|discussed|noted) (above|earlier|previously|before))\b' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            is_scanner_pattern_line "$content" && continue
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Filler phrase: ${evidence}" "MEDIUM"
        done || true

    # Placeholder/stub text left behind
    command grep -niE -- '(# TODO: implement|// TODO: implement|raise NotImplementedError|throw new Error\(.not implemented)' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            is_scanner_pattern_line "$content" && continue
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
    #
    # NO is_scanner_pattern_line guard here, unlike the ai-slop arms (#604).
    # Every pattern below is `^\s*`-anchored, and a scanner's own pattern
    # literal always sits INSIDE a grep invocation indented in a function — so
    # it can never match line-start. The guard therefore suppressed nothing on
    # the real scanners (measured: 0 rows) while silently dropping genuine
    # debug statements whose ARGUMENT happened to look like a regex, e.g.
    # `print(re.search(r"\d+", data))` in ordinary source. Anchoring is what
    # prevents self-matching in this region; keep it that way. Adding an
    # UNANCHORED pattern below would reintroduce the self-match the guard was
    # for — anchor it, or reconsider the guard for that arm alone.
    case "$file" in
        *.py)
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
        *.js | *.ts | *.jsx | *.tsx | *.mjs | *.cjs)
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
        *.rb)
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
        *.go)
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
        *.java | *.kt)
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

# sh_test_find_args <name-no-ext> — echo the `find` OR-chain matching any shell
# test named after this source, one token per line (#598). Same shape as
# js_test_find_args; the arms differ because shell test naming here is a
# different convention, not the js/ts one.
#
# Three arm groups, each earning its place against a measured false negative:
#
#   exact    — `tests/<name>.sh`, for a suite whose file simply IS the name
#              (tests/golem-gate-watch.sh covers scripts/golem-gate-watch.sh).
#   stems    — the #568 stem set, as <stem>.<ext>, <stem>-*.<ext>,
#              <stem>_*.<ext>, so `tests/validate-golem-scripts.sh` and
#              `tests/validate-release-notes.sh` both count.
#   fragment — `NN-<name>.sh` / `NN-<name>-*.sh`, the split-suite layout (#564)
#              where cases live in tests/<suite>/NN-<area>.sh.
#
# Tokens are never whitespace-bearing: literal find flags plus globs built from
# a basename with its extension stripped.
sh_test_find_args() {
    local name="$1"
    local stem ext glob first=1

    for glob in \
        "${name}.sh" "${name}.bash" \
        "[0-9][0-9]-${name}.sh" "[0-9][0-9]-${name}-*.sh"; do
        if [ "$first" -eq 1 ]; then first=0; else command printf '%s\n' "-o"; fi
        command printf '%s\n' "-name" "$glob"
    done
    for stem in \
        "validate-${name}" "test-${name}" "test_${name}" \
        "${name}_test" "${name}.test" "${name}-test"; do
        for ext in sh bash; do
            for glob in "${stem}.${ext}" "${stem}-*.${ext}" "${stem}_*.${ext}"; do
                command printf '%s\n' "-o" "-name" "$glob"
            done
        done
    done
}

# sh_test_find_args_exact <candidate> — the RESTRICTED arm set used for a
# hyphen-stripped candidate (#598). Exact filenames only: no `-*`/`_*` wildcard
# forms.
#
# The restriction is the whole point and must not be "simplified" away by
# reusing sh_test_find_args here. Stripping `golem-` off `golem-status` is what
# lets `tests/golem-scripts/60-status.sh` count, but the stripped token is a
# short generic word, and allowing wildcards on it was MEASURED to match
# `bin/ruff-version.sh` against `tests/release/10-version-utils.sh` via a bare
# `version` — a silent false negative on a file with no test of its own, which
# is strictly worse than the finding it suppresses.
#
# The trailing fragment glob is `.sh`-ONLY by design, unlike the stem arms above
# it. Split-suite fragments (#564) are a convention of this repo's own tests/
# tree, and every one of them is `.sh` — there is no `NN-<area>.bash` anywhere,
# nor any `.bash` file at all. Adding a `.bash` fragment arm would widen the
# match surface of the already-restricted stripped candidate to buy nothing.
sh_test_find_args_exact() {
    local cand="$1"
    local ext glob first=1

    for ext in sh bash; do
        for glob in \
            "${cand}.${ext}" "validate-${cand}.${ext}" \
            "test-${cand}.${ext}" "test_${cand}.${ext}"; do
            if [ "$first" -eq 1 ]; then first=0; else command printf '%s\n' "-o"; fi
            command printf '%s\n' "-name" "$glob"
        done
    done
    command printf '%s\n' "-o" "-name" "[0-9][0-9]-${cand}.sh"
}

# find_repo_rooted_sh_tests <name-no-ext> [max] — paths of shell tests under
# <_PROJECT_ROOT>/tests named after this source, one per line (#598).
#
# `-type f` and the command-substitution shape carry over from
# find_repo_rooted_js_tests for the reasons documented there: a DIRECTORY named
# like a test would otherwise suppress a real finding, and a `find | head` probe
# exits 141 under `set -o pipefail` when find outruns the reader.
#
# `-not -path '*/fixtures/*'` is load-bearing and specific to the shell arm: the
# repo keeps scanner FIXTURES at tests/fixtures/category-parity/match/patterns.sh,
# and without this every plugins/**/patterns.sh matched that one file — 14 real
# scanners silently "covered" by a fixture. A fixture is an input to a test, not
# a test for the source it happens to be named after.
#
# The caller has already checked that <_PROJECT_ROOT>/tests exists.
find_repo_rooted_sh_tests() {
    local name="$1" max="${2:-0}"
    local find_args=() tok
    while IFS= read -r tok; do
        find_args+=("$tok")
    done <<EOF
$(sh_test_find_args "$name")
EOF

    if [ "$max" = "1" ]; then
        command find "${_PROJECT_ROOT}/tests" -type f -not -path '*/fixtures/*' \
            \( "${find_args[@]}" \) -print -quit 2>/dev/null
    else
        command find "${_PROJECT_ROOT}/tests" -type f -not -path '*/fixtures/*' \
            \( "${find_args[@]}" \) -print 2>/dev/null
    fi
}

# find_repo_rooted_sh_tests_stripped <name-no-ext> — as above but for the
# candidate with ONE leading hyphen segment removed, using the exact-only arms.
# Prints nothing when the name carries no hyphen.
find_repo_rooted_sh_tests_stripped() {
    local name="$1"
    case "$name" in
        *-*) ;;
        *) return 0 ;;
    esac
    local cand="${name#*-}"
    [ -n "$cand" ] || return 0

    local find_args=() tok
    while IFS= read -r tok; do
        find_args+=("$tok")
    done <<EOF
$(sh_test_find_args_exact "$cand")
EOF

    command find "${_PROJECT_ROOT}/tests" -type f -not -path '*/fixtures/*' \
        \( "${find_args[@]}" \) -print -quit 2>/dev/null
}

# find_repo_rooted_symbol_test_files — every file under <_PROJECT_ROOT>/tests
# that could reference a symbol, one path per line (#600).
#
# SYMBOL-anchored, NOT filename-anchored — the deliberate divergence from
# find_repo_rooted_js_tests above, and the whole reason a separate helper
# exists. That helper insists a candidate be named after the source, so
# `report.js` is not satisfied by an unrelated `validate-workflow-helpers.mjs`.
# That anchor does not transfer to python: every patterns.py in this repo shares
# the stem `patterns`, so python-appropriate stems (test_patterns.py,
# patterns_test.py) resolve to NOTHING and the name anchor buys zero rows back.
# Measured over all 21 patterns.py: name-anchored stems left all 49 false rows
# standing; this symbol search leaves 16. The `\bsymbol\b` grep the callers run
# against the returned list IS the anchor here — a test that names the function
# is evidence about that function regardless of what the file is called.
#
# Two exclusions, each load-bearing rather than tidy-up:
#
#   */fixtures/*  — a fixture is an INPUT to a test, not a test for the source it
#                   happens to name (#598's rationale, where a single
#                   tests/fixtures/category-parity/match/patterns.sh silently
#                   "covered" 14 real scanners).
#   *.md          — documentation that mentions a symbol does not exercise it.
#                   tests/ARCHITECTURE.md names `main`; treating that as coverage
#                   is a false negative bought with prose.
#
# Callers MUST resolve this ONCE per source file, never once per symbol: the
# find is the expensive part and does not depend on the symbol (the same shape
# the js/ts arm states above). Command substitution, not a `find | head` probe,
# which exits 141 under `set -o pipefail` when find outruns the reader.
#
# The caller has already checked that <_PROJECT_ROOT>/tests exists.
find_repo_rooted_symbol_test_files() {
    command find "${_PROJECT_ROOT}/tests" -type f \
        -not -path '*/fixtures/*' -not -name '*.md' -print 2>/dev/null
}

# find_repo_rooted_go_tests — repo-rooted GO test files only (#600).
#
# The go arm may not use the unrestricted list above, and the restriction is
# load-bearing rather than tidiness. That arm's contract is CONSERVATIVE: it
# fires only when a candidate test exists, leaving a package with no tests at
# all to scan_missing_tests instead of emitting one row per exported func. If
# "a candidate exists" were satisfied by ANY file under tests/, then in any repo
# with a populated tests/ tree — this one included — the gate would be
# permanently true and the arm would fire on every exported func of every
# untested go package. That is the exact noise the contract exists to prevent,
# and it was a real regression in the first cut of this change.
#
# `*_test.go` is the language's own universal convention (the `go test` toolchain
# only compiles files with that suffix), so it is the honest spelling of "a go
# test exists" — no heuristic needed.
find_repo_rooted_go_tests() {
    command find "${_PROJECT_ROOT}/tests" -type f \
        -not -path '*/fixtures/*' -name '*_test.go' -print 2>/dev/null
}

# has_repo_rooted_sh_test <name-no-ext> — 0 when at least one such test exists,
# by the full-name arms or the restricted stripped-candidate arm.
has_repo_rooted_sh_test() {
    local hit
    hit="$(find_repo_rooted_sh_tests "$1" 1)"
    [ -n "$hit" ] && return 0
    hit="$(find_repo_rooted_sh_tests_stripped "$1")"
    [ -n "$hit" ]
}

# has_repo_rooted_foreign_py_test <name-no-ext> <basename> — 0 when a repo-rooted
# SHELL test both names and mentions this python source (#644).
#
# Cross-language on purpose. The py arm above it looks only for python-named
# tests (test_<name>.py, <name>_test.py); in a repo whose python is deliberately
# tested by bash gates no such file will ever exist, so that arm cannot resolve
# BY CONSTRUCTION and every python source carries a permanent HIGH row. Measured
# before this helper: 15 of 15 plugins/**/patterns.py fired while 0 of 15 sibling
# patterns.sh did — same directories, same suites, and the differing outcome was
# an artifact of which arm got a repo-rooted probe (#598 gave the sh arm one),
# not a real difference in coverage.
#
# TWO anchors, and the finding needs BOTH. Each is load-bearing:
#
#   name    — sh_test_find_args, the same OR-chain the sh arm uses. This is also
#             what makes #601 structurally unreachable here: the search is
#             derived from the SOURCE's own basename, so it cannot degenerate
#             into a constant that resolves for every source the way a
#             {name}-less test_discovery template would.
#   content — the candidate must mention <basename>, DELIMITED. Cross-language
#             coverage is a weaker claim than same-language, so this probe is
#             deliberately STRICTER than the sh arm it mirrors: sharing a stem
#             with a shell suite is not, on its own, evidence that the suite
#             exercises the python file. Measured to cost 0 rows across the tree
#             today — every .py that resolves by name also mentions itself in
#             that test — so the strictness is free insurance rather than a live
#             tradeoff.
#
# The content anchor is DELIMITED, not a bare substring, and that is load-bearing
# rather than tidiness. An unanchored `grep -F "patterns.py"` also matches
# `get_patterns.py`, `not_patterns.py` and `patterns.py.bak`, so a suite named
# validate-patterns.sh that discusses an unrelated get_patterns.py satisfied BOTH
# anchors and silently suppressed a real HIGH row — a reproduced false negative,
# and exactly the over-match class #598/#601 exist to prevent. The basename is
# regex-escaped and required to sit between non-filename characters (or a line
# edge), so a path-qualified `plugins/x/patterns.py` still counts while a
# superstring does not.
#
# NO hyphen-stripped arm, unlike has_repo_rooted_sh_test. Measured across every
# hyphenated python stem in the tree — golem-event-listener -> event-listener,
# autonomy-resolve -> resolve, agnix-normalize -> normalize — stripping resolves
# ZERO additional files while carrying exactly the generic-token over-match risk
# sh_test_find_args_exact documents (a bare `version` matching
# tests/release/10-version-utils.sh). It buys nothing and costs false-negative
# surface, so the foreign probe stays full-name only.
#
# `-not -path '*/fixtures/*'` carries over from the sh helper for its reason: a
# fixture is an INPUT to a test, not a test for the source it happens to name.
# MEASURED to be load-bearing here too — dropping it lets a
# tests/fixtures/**/validate-<name>.sh that mentions the source suppress a real
# row.
#
# The sibling symbol helper also excludes `-name '*.md'`; this one deliberately
# does NOT, because here it would be dead code. That helper searches the tests/
# tree UNFILTERED by name, so a doc can reach it; this probe only ever sees
# candidates that matched sh_test_find_args, and every one of those 40 arms ends
# in `.sh` or `.bash`. No `.md` can be in the candidate set to begin with, so the
# clause would exclude nothing — and a test written to "pin" it passes with the
# clause deleted, which is how it was caught.
#
# The find is resolved ONCE into a command substitution rather than piped into a
# reader — a `find | head`-shaped probe exits 141 (SIGPIPE) under `set -o
# pipefail` when find outruns it, which would read as a scan failure.
#
# The caller has already checked that <_PROJECT_ROOT>/tests exists.
has_repo_rooted_foreign_py_test() {
    local name="$1" basename="$2"
    local find_args=() tok candidates cand esc pattern

    while IFS= read -r tok; do
        find_args+=("$tok")
    done <<EOF
$(sh_test_find_args "$name")
EOF

    candidates="$(command find "${_PROJECT_ROOT}/tests" -type f \
        -not -path '*/fixtures/*' \
        \( "${find_args[@]}" \) -print 2>/dev/null)"
    [ -n "$candidates" ] || return 1

    # Escape every ERE metacharacter so the basename is matched literally, then
    # require a non-filename character (or a line edge) on each side. `-.` are
    # inside the bracket negation, so `-` must stay LAST there to read as a
    # literal rather than opening a range.
    esc="$(command printf '%s' "$basename" |
        command sed 's/[][^$.*+?(){}|\\/]/\\&/g')"
    pattern="(^|[^A-Za-z0-9_.-])${esc}([^A-Za-z0-9_.-]|\$)"

    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        command grep -qE -- "$pattern" "$cand" 2>/dev/null && return 0
    done <<EOF
$candidates
EOF

    return 1
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

    local basename dirname name_no_ext ext colo_ext
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
                # Repo-rooted SHELL test naming this source (#644). Every probe
                # above is python-named, so in a repo that tests its python from
                # bash gates the arm cannot resolve by construction and the row
                # is permanent — which is why this one reaches across languages.
                # It is stricter than the sh arm's equivalent (name AND content,
                # no hyphen-stripped candidate); the rationale for each anchor,
                # and the measurements behind them, are at the helper.
                has_repo_rooted_foreign_py_test "$name_no_ext" "$basename" &&
                    return
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
        sh | bash)
            # Shell (#598). `*.sh` used to sit in test-skip-patterns.default on
            # the premise that shell scripts have no tests. In a repo whose
            # tests ARE shell suites that premise is false, and the skip made
            # the scanner silent on the bulk of every diff — indistinguishable
            # in the handoff from a clean one.
            #
            # Colocated first (cheap, no find), then the repo-rooted tree.
            # Both extensions on every form: the `sh | bash)` label above claims
            # .bash sources are handled, so a .sh-only colocated list would make
            # that claim false for a colocated .bash test.
            for colo_ext in sh bash; do
                for test_path in \
                    "${dirname}/test_${name_no_ext}.${colo_ext}" \
                    "${dirname}/test-${name_no_ext}.${colo_ext}" \
                    "${dirname}/tests/test_${name_no_ext}.${colo_ext}" \
                    "${dirname}/tests/test-${name_no_ext}.${colo_ext}" \
                    "${dirname}/tests/validate-${name_no_ext}.${colo_ext}" \
                    "${dirname}/../tests/validate-${name_no_ext}.${colo_ext}" \
                    "${dirname}/${name_no_ext}_test.${colo_ext}"; do
                    [ -f "$test_path" ] && return
                done
            done
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                has_repo_rooted_sh_test "$name_no_ext" && return
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

# symbol_in_candidate_list <symbol> <newline-delimited-paths> — 0 when any listed
# file mentions <symbol> as a whole word (#600). Shared by all three arms so
# they cannot drift in how a candidate is judged.
#
# Iterates rather than passing the list to one `grep -l`: the paths come from a
# find and an unquoted expansion would word-split any path containing spaces.
# An empty list returns 1 (not found) without invoking grep — a bare `grep PAT`
# with no file operand would block reading stdin.
symbol_in_candidate_list() {
    local symbol="$1" list="$2" test_path
    [ -n "$list" ] || return 1
    while IFS= read -r test_path; do
        [ -n "$test_path" ] || continue
        if command grep -q -- "\b${symbol}\b" "$test_path" 2>/dev/null; then
            return 0
        fi
    done <<EOF
$list
EOF
    return 1
}

# py_public_symbols_gate <file> — this MODULE's public-API policy (#606).
#
# #600 fixed test DISCOVERY for the py arm; this fixes symbol SELECTION. The
# extractor below treats every non-underscore top-level `def` as public API,
# which is wrong for a `main()`-guarded CLI script: its internal helpers are
# driven end-to-end THROUGH the entry point, never imported and never named by a
# test, so a well-exercised helper reported HIGH "no tests reference".
#
# Three policies, echoed on stdout:
#   all:<space-separated names>  __all__ present — only these names are public
#   none                         main()-guarded, no __all__ — nothing is API
#   open                         plain module — every top-level def is public
#
# __all__ takes precedence over the main() guard deliberately: it is a POSITIVE
# declaration by the author, and it is the escape hatch for a module that is
# genuinely both a CLI and an importable library. Absent it, a main() guard is
# the only structural evidence available that a module is an entry point.
#
# Note what this does NOT do. The issue (#606) originally proposed suppressing a
# guarded module's def "unless the symbol is imported somewhere outside its own
# file". Measured against this repo, no such import exists for ANY of the 16
# symbols — the only cross-file hits are the sibling patterns.sh bash port
# (which defines a same-named SHELL function) and docs prose. A word-grep proxy
# for "is imported" would therefore suppress or expose a symbol based on whether
# a bash port happened to reuse the name, which is arbitrary. Structure only.
#
# Callers MUST resolve this ONCE per source file: it is a property of the
# module, not of the symbol, so recomputing it inside the per-def loop would
# re-read the whole file once per export for an answer that cannot change.
#
# Only the sentinel-bracketed FUNCTION BODIES are compared — this doc comment is
# outside the region and deliberately differs from the dev-core copy's, which
# carries the three-copy enforcement table instead of the #600/#606 rationale
# above. Comments INSIDE the region are compared like any other line.
# >>> shared:py-public-symbols (kept in sync with loop-make-it-tested/patterns.sh by tests/validate-shared-scanner-sync.sh)
py_public_symbols_gate() {
    local file="$1" all_names

    # `__all__ = [...]` / `(...)`, possibly spanning lines. Take from the first
    # __all__ assignment to the closing bracket, then keep only the quoted
    # names. A module with __all__ answers `all:` even if it is ALSO guarded.
    #
    # awk, not `sed -n '/start/,/end/p'`: a sed range looks for its END pattern
    # starting at the line AFTER the start, so a single-line `__all__ = ["x"]`
    # does not terminate on its own closing bracket and the range runs on to the
    # next `]` or `)` anywhere in the file — swallowing unrelated quoted strings
    # as if they were exported names. The awk below tests the start line itself.
    if command grep -qE '^__all__([[:space:]]*:[^=]*)?[[:space:]]*=' "$file" 2>/dev/null; then
        all_names=$(command awk '
            /^__all__([[:space:]]*:[^=]*)?[[:space:]]*=/ && !inb {
                inb = 1
                rest = substr($0, index($0, "=") + 1)
                print rest
                if (rest ~ /[])]/) exit
                next
            }
            inb { print; if ($0 ~ /[])]/) exit }
        ' "$file" 2>/dev/null |
            command grep -oE '"[a-zA-Z_][a-zA-Z0-9_]*"|'\''[a-zA-Z_][a-zA-Z0-9_]*'\''' |
            command tr -d '"'\''' | command tr '\n' ' ')
        command printf 'all:%s' "$all_names"
        return
    fi

    # The `if __name__ == "__main__":` guard, in either quote style. Anchored at
    # column 0: a guard nested inside a function or class is not the module's
    # entry point and must not gate the whole file.
    if command grep -qE '^if[[:space:]]+__name__[[:space:]]*==[[:space:]]*["'\'']__main__["'\'']' \
        "$file" 2>/dev/null; then
        command printf 'none'
        return
    fi

    command printf 'open'
}

# py_symbol_is_public <symbol> <gate> — 0 when <symbol> is public under <gate>.
py_symbol_is_public() {
    local symbol="$1" gate="$2"
    case "$gate" in
        none) return 1 ;;
        all:*)
            # Whole-word match within the space-delimited name list; the padding
            # keeps `check_mcp` from matching `check_mcp_config`.
            case " ${gate#all:} " in
                *" $symbol "*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 0 ;;
    esac
}
# <<< shared:py-public-symbols

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

    local basename dirname name_no_ext ext repo_rooted_tests declared py_gate
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
            # Cross-directory fallback (#600). The colocated globs below cannot
            # see a test in a repo-rooted tests/ tree, so a well-exercised
            # function reported HIGH "no tests reference" — the same class #555
            # and #568 removed for js/ts. Resolved ONCE per file, not per
            # export: the find does not depend on the symbol.
            repo_rooted_tests=""
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                repo_rooted_tests="$(find_repo_rooted_symbol_test_files)"
            fi
            # Declared discovery templates join the SAME candidate list rather
            # than short-circuiting (#568): the question here is whether a
            # specific symbol is referenced, so the declared file still has to
            # be grepped for it.
            declared="$(declared_test_paths "$file")"
            if [ -n "$declared" ]; then
                repo_rooted_tests="${repo_rooted_tests:+${repo_rooted_tests}
}${declared}"
            fi
            # Module-level public-API policy (#606) — resolved ONCE per file
            # alongside the candidate lists above, for the same reason: it does
            # not depend on the symbol.
            py_gate="$(py_public_symbols_gate "$file")"
            command grep -nE -- '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    # Not public API for this module — no test is EXPECTED to
                    # name it, so "no tests reference" is not a finding.
                    py_symbol_is_public "$func_name" "$py_gate" || continue
                    if command grep -rql -- "\b${func_name}\b" \
                        "${dirname}"/test_*.py \
                        "${dirname}"/tests/test_*.py \
                        "${dirname}"/../tests/test_*.py 2>/dev/null; then
                        continue
                    fi
                    if symbol_in_candidate_list "$func_name" "$repo_rooted_tests"; then
                        continue
                    fi
                    evidence=$(truncate_chars 60 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "untested-public-api" \
                        "No tests reference ${func_name}: ${evidence}" "HIGH"
                done || true
            ;;
        go)
            # Cross-directory fallback (#600), same shape as the py arm.
            #
            # The go arm stays CONSERVATIVE by design: it fires only when at
            # least one candidate test file exists, so a package with no tests
            # at all is left to scan_missing_tests rather than emitting one row
            # per exported func. This change widens WHICH candidates count — the
            # sibling <name>_test.go plus any repo-rooted *_test.go — it does not
            # make the arm fire where it was previously silent.
            #
            # find_repo_rooted_GO_tests, not the unrestricted symbol list the py
            # arm uses: the gate below is satisfied by a non-empty candidate list,
            # so an unrestricted list would make it permanently true in any repo
            # with a populated tests/ tree and fire on every exported func of
            # every untested package. See that helper's comment.
            repo_rooted_tests=""
            if [ -n "$_PROJECT_ROOT" ] && [ -d "${_PROJECT_ROOT}/tests" ]; then
                repo_rooted_tests="$(find_repo_rooted_go_tests)"
            fi
            declared="$(declared_test_paths "$file")"
            if [ -n "$declared" ]; then
                repo_rooted_tests="${repo_rooted_tests:+${repo_rooted_tests}
}${declared}"
            fi
            command grep -nE -- '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    have_candidate=false
                    [ -f "$test_file" ] && have_candidate=true
                    [ -n "$repo_rooted_tests" ] && have_candidate=true
                    [ "$have_candidate" = "true" ] || continue

                    if [ -f "$test_file" ] &&
                        command grep -q -- "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        continue
                    fi
                    if symbol_in_candidate_list "$func_name" "$repo_rooted_tests"; then
                        continue
                    fi
                    evidence=$(truncate_chars 60 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "untested-public-api" \
                        "No tests reference ${func_name}: ${evidence}" "HIGH"
                done || true
            ;;
        ts | js | tsx | jsx | mjs | cjs)
            # KNOWN LIMIT: the export grep below is ESM-only (`^export
            # function|const|class`). Idiomatic CommonJS — `module.exports.x =`
            # / `exports.x =` — is NOT detected, so this category is close to a
            # no-op for a genuinely CJS-style `.cjs` file. That is a deliberate
            # boundary, not an oversight: routing .cjs here (#568) is about not
            # mis-filing it as an "unknown file type", and widening the export
            # grammar is new DETECTION work beyond this issue. The failure mode
            # is under-reporting, never a wrong flag, so it cannot produce a
            # false positive on a real repo.
            #
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
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # `sed -E` (ERE), not the default BRE: `\|` alternation is a
                    # GNU extension. Under BSD sed this substitution never
                    # matched, so func_name fell through as the ENTIRE source
                    # line — which the `\b${func_name}\b` grep below can never
                    # match, reporting every exported symbol as untested (#679).
                    func_name=$(command printf '%s' "$content" | command sed -E 's/^export (function|const|class) ([a-zA-Z][a-zA-Z0-9_]*).*/\2/')
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
                    if [ "$found" = "false" ] &&
                        symbol_in_candidate_list "$func_name" "$repo_rooted_tests"; then
                        found=true
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
