#!/usr/bin/env bash
# ship-issue — Pre-Review Gates (Deterministic Pre-Scan)
#
# Scans changed files for mechanical issues before PR creation:
# AI slop patterns, debug statements, missing tests, untested public APIs, and
# review-lens file sizing (#695, delegated to the sibling sizing.sh).
#
# Input:  $1 = file containing paths to scan (one per line)
#         $2 = OPTIONAL numstat sidecar (`git diff --numstat` rows) forwarded to
#              sizing.sh. Without it sizing still runs but has no growth signal,
#              so every over-threshold file is reported LOW/informational — which
#              is the safe direction (it cannot manufacture a blocking finding).
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

FILE_LIST="${1:?Usage: pre-review-gates.sh <file-list> [numstat-file]}"
NUMSTAT_FILE="${2:-}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- input-shape guard (#816) -----------------------------------------------
# The file-list argument is a list of PATHS, one per line -- not a diff. Handed
# a diff, the scan loop reads each diff line as a path, matches nothing, emits
# nothing, and exits 0: an output indistinguishable from a genuinely clean scan.
# That is the #538/#571 failure (a gate that sits inert and reads as a pass)
# reached through the INPUT rather than the runtime, and it is easy to hit --
# both inputs come from adjacent `git diff` invocations differing only by
# `--name-only`, and both are plausibly named `*.diff`.
#
# Two checks, deliberately different in severity:
#
#   DIFF SHAPE -> hard failure (exit 1). Unambiguous: no file list contains a
#     `diff --git`/`@@`/`+++`/`--- ` line, so there is no legitimate input this
#     rejects, and the silent-zero scan is exactly what the caller must not get.
#
#   NOTHING RESOLVES -> stderr warning, exit code UNCHANGED. This one cannot be
#     an error: a list naming only deleted files is legitimate (the paths are
#     gone by design), and an EMPTY list exiting 0 in silence is a contract
#     tests/validate-prescans.sh pins for every pre-scan. So it is a warning
#     that catches stale lists and wrong-cwd invocations without breaking either
#     real case -- which is why it is guarded on a NON-EMPTY list.
#
# BASH_SOURCE[0], not $0: inside a function it names the file this function was
# DEFINED in, so the message stays correct under a symlink, a relative
# invocation from another cwd, or a `source` -- the same reasoning the SCRIPT_DIR
# computation elsewhere in these scanners uses.
# The multi-byte Unicode format characters the reflected line must not carry:
# the zero-width family (U+200B-200F), bidi overrides/embeddings (U+202A-202E),
# bidi isolates (U+2066-2069) and BOM (U+FEFF). A bidi override is the dangerous
# one: it makes the reflected text RENDER reversed, so a hostile path can display
# as something other than what it is.
#
# Built with printf as LITERAL UTF-8 bytes, not written as \xNN escapes -- those
# are a GNU sed extension that BSD sed reads as literal text, which is the silent
# #679 failure class (the pattern stops matching and nothing reports it).
# An ALTERNATION, not a bracket class: a bracket over multi-byte sequences
# matches byte-wise and can split a character.
#
# This is what keeps the bash fallback in step with _strip_control() in the
# python primary, whose isprintable() rejects category Cf for free. Without it
# the two runtimes diverge on exactly the path the fallback exists to serve
# (measured: RTLO survived in bash, was stripped in python).
_PRESCAN_BIDI_BYTES="$(command printf '\342\200\213|\342\200\214|\342\200\215|\342\200\216|\342\200\217|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\201\246|\342\201\247|\342\201\250|\342\201\251|\357\273\277')"

assert_file_list_shape() {
    local list="$1"
    local tool="${BASH_SOURCE[0]##*/}"
    local line total=0 resolved=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        total=$((total + 1))
        case "$line" in
            'diff --git '* | '--- '* | '+++ '* | '@@ '*)
                # STRIP CONTROL BYTES before echoing the line back. The input is
                # caller-supplied and may come from an untrusted diff; raw ESC/BEL
                # reaching the operator's terminal can move the cursor, hide
                # following output, or drive an OSC title-bar sequence. Keep tab
                # (\011) so indentation still reads. Measured: without this, a
                # crafted `diff --git \033[31m...\033]0;X\007` line renders as
                # live escapes rather than text.
                # Two passes, because one tool cannot do both portably.
                # (1) tr strips single-byte C0 controls + DEL (ESC, BEL, ...).
                #     Tab (\011) is kept so indentation still reads.
                # (2) sed strips the MULTI-BYTE Unicode format characters that
                #     tr cannot express: bidi overrides/isolates (U+202A-202E,
                #     U+2066-2069), the zero-width family (U+200B-200F) and BOM
                #     (U+FEFF). A bidi override is the dangerous one -- it makes
                #     the reflected path RENDER in reverse, so `evil.js` can be
                #     displayed as something else entirely. `tr -d '[:cntrl:]'`
                #     does NOT cover these (locale-dependent, and C0-only in the
                #     C locale, measured), which is why they are enumerated as
                #     literal UTF-8 byte sequences -- a spelling that behaves
                #     identically under BSD and GNU sed.
                #     This mirrors _strip_control() in the python primary, whose
                #     `isprintable()` rejects category Cf for free. Without pass
                #     (2) the two runtimes DIVERGE on exactly the fallback path
                #     the bash body exists to serve (verified: RTLO survived in
                #     bash and was stripped in python).
                _safe_line="$(command printf '%s' "$line" |
                    command tr -d '\000-\010\013-\037\177' |
                    command sed -E "s/(${_PRESCAN_BIDI_BYTES})//g")"
                echo "Error: ${tool}: input looks like a DIFF, not a file list: ${list}" >&2
                echo "  Offending line: ${_safe_line}" >&2
                echo "  Expected one path per line -- did you mean 'git diff --name-only'?" >&2
                echo "  Refusing to scan: a diff matches no path, so this would emit nothing and exit 0, which reads as a clean scan." >&2
                exit 1
                ;;
        esac
        if [ -e "$line" ]; then
            resolved=$((resolved + 1))
        fi
    done <"$list"

    if [ "$total" -gt 0 ] && [ "$resolved" -eq 0 ]; then
        echo "Warning: ${tool}: no path listed in ${list} exists (${total} non-empty lines); scanning nothing." >&2
        echo "  A stale list or a wrong working directory yields an empty scan that reads as clean. Findings below (if any) are from a partial view." >&2
    fi
}

assert_file_list_shape "$FILE_LIST"

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
#   _STDOUT_PATTERNS — globs of files whose stdout writes ARE the program's
#                      output, not debug leftovers (#680)
_TEST_PATTERNS=""
_TEST_DISCOVERY=""
_STDOUT_PATTERNS=""
# Extra temp repos, created only when their key is declared. Each key gets its
# OWN repo so the pattern sets cannot contaminate each other — a `scripts/*.py`
# declared as CLI output must not also mark those files as tests. MUST be
# initialized here: the script runs under `set -u`, so a bare reference before
# assignment would abort the whole scan.
_TEST_PATTERN_REPO=""
_STDOUT_PATTERN_REPO=""

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
# >>> shared:yaml-list-parser (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
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

        # Files whose stdout writes ARE the program's output (#680). Same
        # parser, same matching engine — the three keys cannot drift in how
        # they are read or matched, which is the point of routing them all
        # through read_yaml_list + check-ignore.
        _STDOUT_PATTERNS="$(read_yaml_list stdout_is_output "$project_config")"

        # test_patterns are matched by the same git check-ignore engine as the
        # skip patterns, in their OWN exclude file so the two sets cannot
        # contaminate each other.
        if [ -n "$_TEST_PATTERNS" ]; then
            _TEST_PATTERN_REPO=$(command mktemp -d)
            command git init -q "$_TEST_PATTERN_REPO" 2>/dev/null
            command printf '%s\n' "$_TEST_PATTERNS" \
                >"${_TEST_PATTERN_REPO}/.git/info/exclude"
        fi

        # ...and a THIRD repo for stdout_is_output, for the same reason: sharing
        # a repo with test_patterns would silently make every declared-CLI file
        # a declared TEST, suppressing missing-test-file and untested-public-api
        # as a side effect — the exact conflation #680 rejected when it declined
        # to reuse test_skip_patterns.
        if [ -n "$_STDOUT_PATTERNS" ]; then
            _STDOUT_PATTERN_REPO=$(command mktemp -d)
            command git init -q "$_STDOUT_PATTERN_REPO" 2>/dev/null
            command printf '%s\n' "$_STDOUT_PATTERNS" \
                >"${_STDOUT_PATTERN_REPO}/.git/info/exclude"
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

# matches_declared_stdout_pattern FILE — 0 when the project declared this file
# under `stdout_is_output` (#680): its print/console.log IS the program's
# output, not a debug leftover. Always false when nothing was declared, so a
# repo with no config keeps today's behaviour exactly.
#
# Scoped to the PRINT family by its only caller (scan_debug_statements) —
# breakpoints keep firing in a declared file. Deliberately a separate key from
# `test_skip_patterns`: "needs no test of its own" and "legitimately writes to
# stdout" are different claims, and reusing the former would silence
# missing-test-file as a side effect.
matches_declared_stdout_pattern() {
    load_test_skip_policy
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

# Cleanup temp repos on exit.
#
# ONE BRANCH PER mktemp -d ABOVE. Adding a declared-convention key means adding
# a repo in load_test_skip_policy AND a branch here — the two go together, and
# the omission is silent: the scan still exits 0 and only leaks a directory per
# run. Keep this list in step with the `_*_REPO` declarations at the top of the
# file.
cleanup_skip_policy() {
    if [ -n "$_SKIP_POLICY_REPO" ]; then
        command rm -rf "$_SKIP_POLICY_REPO"
    fi
    if [ -n "$_TEST_PATTERN_REPO" ]; then
        command rm -rf "$_TEST_PATTERN_REPO"
    fi
    if [ -n "$_STDOUT_PATTERN_REPO" ]; then
        command rm -rf "$_STDOUT_PATTERN_REPO"
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

# NOT a `# >>> shared:` region, deliberately (#816). An earlier revision opened
# this block with a sentinel claiming sync with check-code-health/patterns.sh.
# That claim was never enforced and could not be: the twin has no counterpart
# region, the name appears in no SHARED_PAIRS entry, and patterns.sh's own
# comment states it carries NO is_scanner_pattern_line guard in either scan
# region. The two files differ here ON PURPOSE. A sentinel asserting a sync that
# does not exist is worse than no sentinel -- it reads as covered while nothing
# checks it, which is the same class of defect as the silent-zero scan #816 was
# filed for.
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
# (end is_scanner_pattern_line)

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

    # Hedging phrases — strong indicators of unedited AI output.
    #
    # NO trailing `\b` (#684). Five of these eight alternatives end in a comma,
    # and `\b` after a non-word character asserts that the NEXT character is a
    # word character — so `Importantly, the …` (comma then space) never matched
    # and five phrases were silently unreachable. The leading `\b` is kept: it
    # does the real work, stopping `notably,` from firing inside a longer word.
    # Dropping the trailing one costs only theoretical over-matches
    # (`broadly speakingly`), which these long multi-word phrases make moot.
    command grep -niE -- '\b(it.s worth noting that|it is worth noting that|importantly,|notably,|broadly speaking|in essence,|at its core,|fundamentally,)' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            is_scanner_pattern_line "$content" && continue
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "ai-slop" \
                "Hedging phrase: ${evidence}" "HIGH"
        done || true

    # Buzzword inflation.
    #
    # NO trailing `\b` (#684). `seamlessly integrat` is a STEM, written to catch
    # integrates/integrated/integrating — but `\b` after `t` demanded a non-word
    # character next, so every inflection failed and only a bare, ungrammatical
    # `seamlessly integrat` could match. The alternative was effectively dead.
    command grep -niE -- '\b(enterprise[- ]grade|robust and scalable|seamlessly integrat|leverage the power of|cutting[- ]edge|state[- ]of[- ]the[- ]art|world[- ]class)' "$file" 2>/dev/null |
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
# The per-language detection `case`s below are a DELIBERATE cross-plugin
# duplicate of check-code-health/patterns.sh: review-audit and workflow install
# independently, so this script cannot SOURCE that one at runtime. The shared
# regions (between the sentinel comments) are kept byte-for-byte in sync by
# tests/validate-shared-scanner-sync.sh — edit both copies together.
#
# READ "SOURCE" LITERALLY (#708). The claim is about pulling another plugin's
# shell FUNCTIONS into this script's scope, which is genuinely impossible here:
# CLAUDE_PLUGIN_ROOT is plugin-scoped and the plugins declare no dependency on
# each other. It is NOT a claim that this script can never REACH another
# plugin — the security arm at the foot of this file resolves
# check-security/patterns.sh at runtime and EXECUTES it as a separate process
# with a TSV contract at the boundary, which needs nothing in scope.
#
# The two arms diverge on what ABSENCE COSTS, not on mechanism. A missing
# check-code-health means these debug-statement rows go missing while the
# category still reports — so the logic is duplicated and pinned. A missing
# check-security means a SECURITY scan that finds nothing, which is
# indistinguishable from a clean diff — so that arm refuses loudly instead of
# degrading. Duplicating it here was the alternative and was rejected: measured,
# that is 469 lines of detector patterns and a lexical model kept in sync by
# hand, against the 57 the fail-loud process boundary costs.
#
# The detection is split into TWO regions along the line the `stdout_is_output`
# exemption follows (#680):
#
#   shared:debug-print-scan  — writes to stdout (print, console.*, fmt.Print*,
#                              System.out/err.print*). For a CLI these ARE the
#                              program's output, so a project can declare them
#                              exempt via `stdout_is_output`.
#   shared:debugger-scan     — breakpoints (breakpoint(), pdb, the `debugger`
#                              keyword, binding.pry, byebug). NEVER exempt:
#                              none of these is ever a program's output, so
#                              exempting them would be a real false negative.
#
# Splitting them into separate functions is what makes that distinction
# STRUCTURAL rather than a comment — see scan_debug_statements below. Before
# #680 both families were interleaved in one `case`, so the only available
# early-return exempted both.
#
# NO is_scanner_pattern_line guard in either region, unlike the ai-slop arms
# (#604). Every pattern is `^\s*`-anchored, and a scanner's own pattern literal
# always sits INSIDE a grep invocation indented in a function — so it can never
# match line-start. The guard therefore suppressed nothing on the real scanners
# (measured: 0 rows) while silently dropping genuine debug statements whose
# ARGUMENT happened to look like a regex, e.g. `print(re.search(r"\d+", data))`
# in ordinary source. Anchoring is what prevents self-matching in these regions;
# keep it that way. Adding an UNANCHORED pattern would reintroduce the
# self-match the guard was for — anchor it, or reconsider the guard for that
# arm alone.
# =============================================================================

# scan_debug_prints FILE — the stdout-writing arms. Exemptible via
# `stdout_is_output`; callers gate this one, never scan_debugger_statements.
scan_debug_prints() {
    local file="$1"
    local line_num content evidence

    # >>> shared:debug-print-scan (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
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
        *.[Rr][Ss])
            # Rust: the print!/println!/eprint!/eprintln! macro family (#838).
            # The `!` is part of the macro name and anchors the match.
            command grep -nE -- '^[[:space:]]*e?print(ln)?![[:space:]]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Debug print statement: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Ss][Ww][Ii][Ff][Tt])
            # Swift: print() and debugPrint() (#839). Both write to stdout, so
            # both are exemptible via `stdout_is_output` — a Swift CLI's print()
            # IS its output. Longest-first alternation, same rule as the python
            # arm this mirrors.
            command grep -nE -- '^[[:space:]]*(debugPrint|print)[[:space:]]*\(' "$file" 2>/dev/null |
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

# scan_debugger_statements FILE — the breakpoint arms. NEVER exempted by any
# declaration: a breakpoint is never a program's output (#680 AC3).
scan_debugger_statements() {
    local file="$1"
    local line_num content evidence

    # >>> shared:debugger-scan (kept in sync with check-code-health/patterns.sh by tests/validate-shared-scanner-sync.sh)
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
        *.[Rr][Ss])
            # Rust: the dbg! macro is a debugging aid, never program output, so
            # it belongs in this never-exempted family (#680 AC3, #838).
            command grep -nE -- '^[[:space:]]*dbg![[:space:]]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "debug-statement" \
                        "Rust debug macro: ${evidence}" "HIGH"
                done || true
            ;;
    esac
    # <<< shared:debugger-scan
}

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

    # A file the project declared under `stdout_is_output` skips the PRINT
    # family only (#680). The two calls are deliberately separate statements
    # rather than one guarded block: there is no control path on which the
    # declaration can suppress a breakpoint, which is the property AC3 asks
    # for and the reason the regions were split at all.
    matches_declared_stdout_pattern "$file" || scan_debug_prints "$file"
    scan_debugger_statements "$file"
}

# =============================================================================
# Category: missing-test-file
# Source files with no corresponding test file.
#
# The discovery helpers and scan_missing_tests live in the sibling
# test-discovery.sh (#816). SCRIPT_DIR, not `dirname "$0"`: it is computed
# above through `readlink -f "${BASH_SOURCE[0]}"`, so it resolves symlinks and
# does not depend on how this script was invoked -- the same reasoning the
# sizing.sh delegation at the foot of this file uses. Sourced, not executed:
# the callee needs this script's helpers and globals, and the
# untested-public-api scanner below needs the callee's.
# =============================================================================

_TEST_DISCOVERY_LIB="${SCRIPT_DIR}/test-discovery.sh"
if [ ! -f "$_TEST_DISCOVERY_LIB" ]; then
    echo "Error: pre-review-gates.sh requires the sibling test-discovery.sh; not found at ${_TEST_DISCOVERY_LIB}." >&2
    echo "  This tool refuses to report a clean scan it did not perform." >&2
    exit 1
fi
# shellcheck source=plugins/workflow/skills/ship-issue/test-discovery.sh
. "$_TEST_DISCOVERY_LIB"

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

# --- review-lens sizing (#695) ----------------------------------------------
# Delegated to the sibling sizing.{py,sh} pair rather than inlined here: it owns
# the growth-aware disposition and shares its production-LOC engine with
# check-decomposition through pinned sentinel regions, neither of which belongs
# in this file. It is invoked ONCE over the whole list (not per-file) because it
# does its own iteration and reads the numstat sidecar once.
#
# GRACEFUL DEGRADATION, matching pre-ship-validation.md's contract for this whole
# scanner: a missing or failing sizing tool must never take down the rest of the
# pre-scan, whose rows are already on stdout. Its own fail-loud exit 2 (no
# python3, no awk) is surfaced on stderr by the caller's shell, not swallowed
# into silence here — but it does not abort the gate.
# SCRIPT_DIR, not `dirname "$0"`: the former is computed once above through
# `readlink -f "${BASH_SOURCE[0]}"`, so it resolves symlinks and does not depend
# on how the script was invoked. `$0` survives neither — under a symlink, a
# relative invocation from another cwd, or a `source`, it can name a directory
# that is not this plugin's, which at best skips sizing silently and at worst
# runs a same-named script from wherever it did resolve.
_SIZING="${SCRIPT_DIR}/sizing.sh"
if [ -f "$_SIZING" ]; then
    if [ -n "$NUMSTAT_FILE" ] && [ -f "$NUMSTAT_FILE" ]; then
        command bash "$_SIZING" "$FILE_LIST" "$NUMSTAT_FILE" || true
    else
        command bash "$_SIZING" "$FILE_LIST" || true
    fi
fi

# --- security pre-scan, resolved at RUNTIME (#708) ---------------------------
# ship-issue's adversarial review fans out five dimensions. Four had a
# deterministic pre-scan handoff; `security` had none -- it resolved through
# REUSED_DIMENSIONS to code-reviewer's `reviewer:security` mode, whose whole
# instruction set is a prose checklist. So a hardcoded AWS key or an f-string SQL
# build was caught only if an LLM happened to notice it on that pass, while this
# repo already owned a deterministic scanner for exactly those patterns.
#
# WHY RUNTIME RESOLUTION AND NOT DUPLICATION. The sibling `sizing.sh` arm above
# shares check-decomposition's LOC engine by pinned duplication, and the
# debug-statement region further up says outright that "this script cannot source
# that one at runtime". Both remain true and neither is contradicted here,
# because they are about a DIFFERENT operation: SOURCING shell functions into
# this script's scope across a plugin boundary, which genuinely cannot be done --
# CLAUDE_PLUGIN_ROOT is plugin-scoped and the plugins declare no dependency on
# each other. check-security is not sourced. It is EXECUTED as a separate
# process with a TSV contract at the boundary, so nothing needs to be in scope
# and nothing can drift silently: it either runs and emits rows, or it is absent
# and this arm refuses.
#
# What differs is therefore not the mechanism but what ABSENCE COSTS, and that is
# what sets the two dispositions apart:
#
#   sizing.sh absent      -> a missing size opinion. Degrade gracefully; the
#                            other categories' rows are already on stdout.
#   check-security absent -> a SECURITY SCAN THAT FINDS NOTHING, which is
#                            byte-identical to a clean scan. That is the #538 /
#                            #571 inert-gate shape reached through the plugin
#                            boundary, and it is the exact outcome #708 exists to
#                            prevent. So this arm FAILS LOUD.
#
# The contract: zero rows from an ABSENT scanner and zero rows from a CLEAN diff
# must be distinguishable in BOTH the exit code and the output. A caller reading
# only stdout sees the marker row; a caller checking `$?` sees non-zero; a caller
# watching stderr sees what to install. No single channel is relied on, because a
# pipeline drops the exit code (#854) and a `2>/dev/null` drops the message.
_SECURITY_MARKER_CATEGORY='security-scan-unavailable'

# security_scan_refuse REASON DETAIL — emit the marker row + the actionable
# stderr message, then return 1. The caller turns that into a non-zero exit
# AFTER the rest of the scan's rows have already been written, so an operator
# still gets every finding the gate did compute.
security_scan_refuse() {
    local tool="${BASH_SOURCE[0]##*/}"
    command printf '%s\t%s\t%s\t%s\t%s\n' \
        '-' '0' "$_SECURITY_MARKER_CATEGORY" \
        "SECURITY PRE-SCAN DID NOT RUN ($1) — this scan's silence is NOT a clean result" \
        'HIGH'
    {
        echo "Error: ${tool}: the security pre-scan did not run: $1"
        [ -n "${2:-}" ] && echo "  $2"
        echo "  check-security/patterns.sh ships with the 'review-audit' plugin, which"
        echo "  installs independently of 'workflow'. Install it with:"
        echo "      claude plugin install review-audit@librarian"
        echo "  or point SECURITY_SCANNER at the scanner explicitly."
        echo "  Refusing to exit 0: a security scan that finds nothing because it did not"
        echo "  run is indistinguishable from a clean diff, which is the outcome this gate"
        echo "  exists to prevent."
    } >&2
    return 1
}

# resolve_security_scanner — print the scanner path on stdout, or nothing.
#
# Three probes, in order. The first two shapes genuinely differ and neither
# subsumes the other, which is why both are tried rather than one generalized:
#
#   1. SECURITY_SCANNER   explicit override. Also the seam the absent-scanner
#                         tests drive, so the refusal path is exercised by
#                         FORCING absence rather than by skipping when the tool
#                         is missing.
#   2. dev checkout       plugins/{workflow,review-audit}/ are siblings in this
#                         repo, so the path is a fixed relative walk: three
#                         levels up from ship-issue/ reaches plugins/.
#   3. installed cache    ~/.claude/plugins/cache/<marketplace>/review-audit/
#                         <version>/skills/... — ONE further level up than the
#                         dev walk, because an installed plugin root carries a
#                         <version> segment the source tree does not. The version
#                         is per PLUGIN and is not guaranteed to match workflow's
#                         own, so it is globbed rather than assumed; newest-last
#                         sort so a stale side-by-side install does not win.
#                         Both walks were verified against a real installed
#                         layout, not derived on paper — an earlier draft of each
#                         was off by one level and resolved nothing.
resolve_security_scanner() {
    local rel='skills/check-security/patterns.sh'
    local candidate

    if [ -n "${SECURITY_SCANNER:-}" ]; then
        # Printed even when it does not exist: the caller reports the configured
        # path in its refusal, which is far more useful than "not found".
        command printf '%s' "$SECURITY_SCANNER"
        return 0
    fi

    candidate="${SCRIPT_DIR}/../../../review-audit/${rel}"
    if [ -f "$candidate" ]; then
        command printf '%s' "$candidate"
        return 0
    fi

    # `ls -d` + tail over a glob rather than an array: bash 3.2 (stock macOS) is
    # the floor, and a nullglob-free literal glob would otherwise be returned
    # verbatim when it matches nothing.
    candidate="$(command ls -d "${SCRIPT_DIR}"/../../../../review-audit/*/"${rel}" 2>/dev/null |
        command sort | command tail -n 1)"
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        command printf '%s' "$candidate"
        return 0
    fi

    return 0
}

# Deliberately LAST in the file: every other scanner's rows are already on
# stdout, so a refusal here costs the operator nothing they had earned. The
# `|| _SECURITY_RC=$?` shape keeps `set -e` from aborting before the exit.
_SECURITY_RC=0
_SECURITY_SCANNER="$(resolve_security_scanner)"
if [ -z "$_SECURITY_SCANNER" ]; then
    security_scan_refuse "scanner not found" \
        "Searched the dev checkout and the installed plugin cache." || _SECURITY_RC=$?
elif [ ! -f "$_SECURITY_SCANNER" ]; then
    security_scan_refuse "scanner not found" \
        "Resolved to: ${_SECURITY_SCANNER}" || _SECURITY_RC=$?
else
    # Same $FILE_LIST every other scanner in this gate reads. That is what keeps
    # the pre-scan's file scope equal to the security dimension's diff scope on a
    # NARROWED re-review cycle (#492) as well as a full one: the harness builds
    # its manifest over deltaFiles, and ci-review-protocol.md re-runs this gate
    # on the current scope, so scoping follows from the shared input rather than
    # from a second scope computation that could drift out of step.
    if ! command bash "$_SECURITY_SCANNER" "$FILE_LIST"; then
        security_scan_refuse "scanner exited non-zero" \
            "Ran: ${_SECURITY_SCANNER}" || _SECURITY_RC=$?
    fi
fi

# A refusal is the ONLY non-zero exit from a successful scan; findings alone
# still exit 0, unchanged.
if [ "$_SECURITY_RC" != "0" ]; then
    exit 1
fi
