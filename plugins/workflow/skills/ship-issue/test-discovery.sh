#!/usr/bin/env bash
# ship-issue — missing-test-file discovery (extracted from pre-review-gates.sh, #816)
#
# The test-DISCOVERY half of the pre-review pre-scan: given a source file, find
# whether a test for it exists anywhere the project's conventions allow, and emit
# the missing-test-file row when none does. Extracted from pre-review-gates.sh,
# which had grown to 810 production LOC against a 700 `sh` warning budget; #816
# added to it, so the seam was taken while the file was already open.
#
# NOT a standalone tool: it is `.`-sourced by pre-review-gates.sh and has no
# main. It carries no `# >>> shared:` sentinel region, which is precisely why
# this block was the seam chosen — the region-sync pairs in
# tests/validate-shared-scanner-sync.sh are untouched by the move.
#
# The boundary is resolved by bash's LATE BINDING, in both directions:
#   upward   — calls is_test_file, is_test_skipped, matches_declared_test_pattern
#              and has_declared_test, and reads $_PROJECT_ROOT, all defined by
#              the sourcing script before it invokes anything here.
#   downward — find_repo_rooted_js_tests, find_repo_rooted_symbol_test_files and
#              find_repo_rooted_go_tests are called by the untested-public-api
#              scanner that remains in pre-review-gates.sh.
# So neither file is usable alone, and that is intentional: this is one scanner
# split across two files, not a library with an API.
#
# shellcheck shell=bash

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
