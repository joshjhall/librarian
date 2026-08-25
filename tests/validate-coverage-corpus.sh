#!/usr/bin/env bash
# Coverage-corpus completeness gate (issue #748).
#
# THE DEFECT THIS EXISTS TO CATCH. tests/coverage-python.sh built its corpus from
# a single `find "$PLUGINS_DIR" -name 'patterns.py'`. Every Python file we ship
# that is not named patterns.py was therefore never executed under `coverage run`
# — no fixture, no driver, no measurement. Five had accumulated: sizing.py,
# split-verify.py, autonomy-resolve.py, golem-event-listener.py, and plan-lens.py
# (which landed AFTER #748 was filed and fell into the same hole while the issue
# describing that hole sat open — the sharpest possible demonstration).
#
# The bug was never "four files were missed". It was that the corpus was keyed on
# a FILENAME CONVENTION, so falling outside the convention was SILENT: no error,
# no warning, a green coverage job, and a Codecov report that simply did not
# mention the file. Adding drivers for those five fixes today's instance; it does
# nothing about the next scanner someone writes that is not named patterns.py.
#
# So this gate re-keys the check on "every Python file we ship" and asserts
#
#     { plugins/**/*.py }  ==  { patterns.py ports }  ∪  { NON_PATTERNS_TOOLS }
#
# in BOTH directions:
#
#   * a shipped .py in neither set -> UNDRIVEN. The regression #748 fixes.
#   * a NON_PATTERNS_TOOLS entry with no file -> STALE. A rename or deletion that
#     left the declaration behind, which would otherwise sit there looking like
#     coverage of something that no longer exists.
#
# WHY A STATIC GATE AND NOT A CHECK INSIDE coverage-python.sh. That script skips
# whenever coverage.py is absent — which is most laptops, and (until #748) was
# every CI run. A completeness check living inside it would inherit that skip and
# be inert exactly when it mattered. This gate needs no python3 and no
# coverage.py: it reads two file lists and compares them. So it runs in
# tests/run-all.sh, gating CI and pre-push unconditionally.
#
# It deliberately does NOT verify that a declared tool is driven WELL — that its
# driver reaches meaningful branches. Coverage percentages answer that, and a gate
# that tried would be asserting on the numbers Codecov already reports. This one
# answers only the binary question the old corpus could not: is every shipped
# Python file accounted for at all?
#
# Pure bash-3.2 + coreutils + grep; no network, no jq, no python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

COVERAGE_SH="$SCRIPT_DIR/coverage-python.sh"

# The driver fragment (#779). The bespoke drivers for the non-patterns.py tools
# moved OUT of coverage-python.sh into this file; test_declared_tools_have_drivers
# must search both, or every declared tool reads as undriven and this gate fails
# for a reason that has nothing to do with the defect it exists to catch.
#
# The DECLARATIONS (NON_PATTERNS_TOOLS / IMPORTED_MODULES) stay in the entry
# point, so the _parse_list readers above are deliberately NOT extended — only
# the driver-invocation search below spans the two files.
DRIVERS_SH="$SCRIPT_DIR/python-corpus/90-workflow-tool-drivers.sh"

test_suite "Coverage corpus completeness (#748)"

# --- readers -----------------------------------------------------------------

# shipped_python_files — every .py under plugins/, repo-relative, sorted.
shipped_python_files() {
    (cd "$REPO_ROOT" && command find plugins -type f -name '*.py' 2>/dev/null | command sort)
}

# patterns_ports — the subset the glob-driven loop in coverage-python.sh reaches.
patterns_ports() {
    (cd "$REPO_ROOT" && command find plugins -type f -name 'patterns.py' 2>/dev/null | command sort)
}

# declared_tools — the NON_PATTERNS_TOOLS list parsed out of coverage-python.sh.
#
# Parsed with a pure-bash line walk rather than sed: the repo targets BSD sed on
# macOS, where the GNU range/regex spellings this would want are literals (see
# CLAUDE.md § runtime policy, #679). A `\|` or `\s` here would silently match
# nothing, the declared set would read as EMPTY, and an empty declared set makes
# every non-patterns tool look undriven — a gate that fails loudly for the wrong
# reason on exactly one platform.
declared_tools() {
    _parse_list 'NON_PATTERNS_TOOLS="'
}

# imported_modules — the IMPORTED_MODULES list: library modules with no CLI,
# measured transitively through an importer that IS driven. Same parse.
imported_modules() {
    _parse_list 'IMPORTED_MODULES="'
}

# _parse_list <opening-token> — shared walker for both declarations.
_parse_list() {
    local file="$COVERAGE_SH" token="$1" line inside=""
    while IFS= read -r line; do
        case "$line" in
            "$token"*)
                inside="yes"
                # The opening line carries `NAME="\` — a line continuation, so
                # it holds no path itself.
                continue
                ;;
        esac
        [ -n "$inside" ] || continue
        case "$line" in
            *'"')
                # Closing line: strip the trailing quote and emit the path.
                printf '%s\n' "${line%\"}"
                inside=""
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$file" | command grep -v '^[[:space:]]*$' | command sort
}

# --- tests -------------------------------------------------------------------

# The gate's own inputs must be non-empty. Without this, a `find` that matched
# nothing (a moved plugins/ dir, a botched path) would make every set-difference
# below trivially empty and the suite would pass while checking nothing — the
# tautological-pass shape.
test_inputs_non_empty() {
    local shipped ports declared
    shipped="$(shipped_python_files)"
    ports="$(patterns_ports)"
    declared="$(declared_tools)"

    assert_not_empty "$shipped" "Shipped Python file list is non-empty (gate is not a no-op)"
    assert_not_empty "$ports" "patterns.py port list is non-empty"
    assert_not_empty "$declared" "NON_PATTERNS_TOOLS parsed out of coverage-python.sh is non-empty"
}

# THE POINT OF THE GATE. A shipped .py that is neither a patterns.py port nor a
# declared tool is measured by nothing.
test_no_undriven_python_file() {
    local shipped ports declared imported covered undriven
    shipped="$(shipped_python_files)"
    ports="$(patterns_ports)"
    declared="$(declared_tools)"
    imported="$(imported_modules)"
    covered="$(printf '%s\n%s\n%s\n' "$ports" "$declared" "$imported" |
        command grep -v '^[[:space:]]*$' | command sort -u)"
    undriven="$(command comm -23 <(printf '%s\n' "$shipped") <(printf '%s\n' "$covered"))"

    assert_equals "" "$undriven" \
        "Every shipped Python file is accounted for (patterns.py port, NON_PATTERNS_TOOLS, or IMPORTED_MODULES)"
    if [ -n "$undriven" ]; then
        printf '    unaccounted (give it a driver + NON_PATTERNS_TOOLS entry, or list it in IMPORTED_MODULES if a driven tool imports it):\n' >&2
        printf '      %s\n' $undriven >&2
    fi
}

# The other direction: a declaration pointing at a file that no longer exists.
test_no_stale_declaration() {
    local shipped declared stale
    shipped="$(shipped_python_files)"
    declared="$(printf '%s\n%s\n' "$(declared_tools)" "$(imported_modules)" |
        command grep -v '^[[:space:]]*$' | command sort -u)"
    stale="$(command comm -13 <(printf '%s\n' "$shipped") <(printf '%s\n' "$declared"))"

    assert_equals "" "$stale" \
        "Every declared entry (both lists) names a file that exists"
    if [ -n "$stale" ]; then
        printf '    stale declarations (renamed or deleted — drop them from NON_PATTERNS_TOOLS):\n' >&2
        printf '      %s\n' $stale >&2
    fi
}

# A declared entry must not be a patterns.py port: those are reached by the glob
# loop already, and declaring one would double-count it while implying it needs a
# bespoke driver it does not have.
test_declared_are_not_patterns_ports() {
    local declared overlap
    declared="$(declared_tools)"
    overlap="$(printf '%s\n' "$declared" | command grep '/patterns\.py$' || true)"

    assert_equals "" "$overlap" \
        "NON_PATTERNS_TOOLS holds no patterns.py port (those are glob-driven already)"
}

# Every declared tool must actually be INVOKED by a driver in the script.
# Declaring a file without writing its driver would satisfy the set comparison
# above while measuring nothing — the same silent hole one level in.
#
# THE MATCH MUST BE AN INVOCATION, NOT A MENTION. An earlier version of this
# check counted occurrences of the basename anywhere in coverage-python.sh and
# required >= 2. That threshold was already met by prose alone — the file's
# header comment names every tool, and the NON_PATTERNS_TOOLS entry is itself a
# second hit — so deleting a tool's entire driver block left the gate GREEN while
# the tool went back to being unmeasured. Verified by mutation: with the whole
# sizing.py driver removed, the old check still passed. A gate that cannot fail
# for the reason it exists is worse than no gate, because its comment asserts a
# guarantee the code does not provide.
#
# So resolve the driver's `*_PY` variable from its assignment, then require that
# variable to be passed to a real run_coverage/exec_coverage invocation.
#
# The invocations are LINE-CONTINUED — `run_coverage run --parallel-mode ... \`
# on one line, `"$SIZING_PY" "$SIZING_LIST" ...` on the next — so the match must
# run over logical lines, not physical ones. Comment lines are dropped first, and
# backslash-continuations are then joined, so prose describing a driver can never
# stand in for one and a real multi-line invocation is still seen.
test_declared_tools_have_drivers() {
    local declared tool base var joined sources missing=""
    declared="$(declared_tools)"

    # The searchable body: the entry point AND the driver fragment, CONCATENATED
    # INTO ONE STREAM (#779).
    #
    # `cat` into the pipe rather than passing both paths to grep, and the
    # difference is load-bearing rather than stylistic: grep prefixes every match
    # with `filename:` as soon as it is given two or more files, so the `sed
    # 's/=.*$//'` below would yield `tests/coverage-python.sh:SIZING_PY` instead
    # of `SIZING_PY`. Every tool would then resolve to a variable name that does
    # not exist, be reported `no-driver-variable`, and this gate would fail on a
    # perfectly well-driven corpus. Concatenated content has no filenames in it
    # and cannot acquire that prefix.
    sources="$(command cat "$COVERAGE_SH" "$DRIVERS_SH" 2>/dev/null)"

    # Strip comment-only lines, then fold continuations into logical lines.
    joined="$(printf '%s\n' "$sources" | command grep -v '^[[:space:]]*#' |
        command awk '{
            line = line $0
            if (sub(/\\$/, "", line)) { next }
            print line
            line = ""
        }
        END { if (line != "") print line }')"
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        base="${tool##*/}"

        # The variable whose assignment ends in this basename, e.g.
        # `SIZING_PY="$PLUGINS_DIR/workflow/skills/ship-issue/sizing.py"` -> SIZING_PY.
        # POSIX classes only (BSD grep has no \w), and the `=` boundary is what
        # keeps this matching an assignment rather than any mention.
        var="$(printf '%s\n' "$sources" |
            command grep -E "^[[:space:]]*[A-Z_][A-Z0-9_]*=\"[^\"]*/${base}\"" 2>/dev/null |
            command head -1 |
            command sed -e 's/^[[:space:]]*//' -e 's/=.*$//')"

        if [ -z "$var" ]; then
            missing="$missing $tool(no-driver-variable)"
            continue
        fi

        # That variable must reach a real invocation, on the joined logical lines.
        if ! printf '%s\n' "$joined" |
            command grep -E "(run_coverage|exec_coverage).*\"\\\$${var}\"" >/dev/null 2>&1; then
            missing="$missing $tool(declared-but-never-invoked)"
        fi
    done <<EOF
$declared
EOF

    assert_equals "" "$missing" \
        "Every declared tool is INVOKED by a run_coverage driver (not merely mentioned)"
}

# An IMPORTED_MODULES entry earns its exemption ONLY by actually being imported.
# The list says "measured transitively", and that claim is worth exactly as much
# as the import that backs it: a module nothing imports is measured by nothing,
# and listing it would be a silent exemption — precisely the shape #748 exists to
# prevent, re-entering through the door built to accommodate a legitimate case.
#
# So require a sibling .py in the SAME directory to import the module by name.
# Same-directory is the real constraint, not a shortcut: these modules are reached
# via a sys.path insert of the file's own dir (they exist as deliberate per-plugin
# duplicates precisely because a cross-plugin import is impossible), so an
# importer anywhere else could not load this copy.
test_imported_modules_are_imported() {
    local imported module dir stem missing=""
    imported="$(imported_modules)"

    # No entries is a legitimate state (nothing but CLI tools shipped), not a
    # failure — the loop simply does nothing.
    while IFS= read -r module; do
        [ -n "$module" ] || continue
        dir="$REPO_ROOT/$(dirname "$module")"
        stem="$(basename "$module" .py)"

        # `import X` or `from X import ...`, in any sibling EXCEPT the module
        # itself (a file importing its own name proves nothing).
        if ! (cd "$dir" 2>/dev/null && command grep -lE \
            "^[[:space:]]*(from[[:space:]]+${stem}[[:space:]]+import|import[[:space:]]+${stem})" \
            ./*.py 2>/dev/null | command grep -qv "^\./${stem}\.py$"); then
            missing="$missing $module"
        fi
    done <<EOF
$imported
EOF

    assert_equals "" "$missing" \
        "Every IMPORTED_MODULES entry is imported by a sibling scanner (else nothing measures it)"
    if [ -n "$missing" ]; then
        printf '    listed as imported, but no sibling imports it:\n' >&2
        printf '      %s\n' $missing >&2
    fi
}

# The corpus fragment that builds these fixtures must be SOURCED. An unlisted
# fragment leaves its path-list variables unbound, which `set -u` turns into a
# hard failure — but only when the script actually runs, which needs coverage.py.
# Asserting the wiring statically keeps it honest on hosts that skip.
test_workflow_fragment_is_wired() {
    local frag="$SCRIPT_DIR/python-corpus/80-workflow-tools.sh"
    assert_file_exists "$frag" "The workflow-tools corpus fragment exists"
    assert_file_contains "$COVERAGE_SH" "80-workflow-tools" \
        "coverage-python.sh sources the 80-workflow-tools fragment"

    # The DRIVER fragment (#779), same reasoning one phase later: the fixtures
    # above are useless if the block that feeds them to the tools is unsourced.
    assert_file_exists "$DRIVERS_SH" "The workflow-tool driver fragment exists"
    assert_file_contains "$COVERAGE_SH" "90-workflow-tool-drivers" \
        "coverage-python.sh sources the 90-workflow-tool-drivers fragment"
}

run_test test_inputs_non_empty "Gate inputs are non-empty"
run_test test_no_undriven_python_file "No shipped Python file is undriven"
run_test test_no_stale_declaration "No stale NON_PATTERNS_TOOLS declaration"
run_test test_declared_are_not_patterns_ports "Declared tools exclude patterns.py ports"
run_test test_declared_tools_have_drivers "Declared tools have drivers"
run_test test_imported_modules_are_imported "Imported modules are actually imported"
run_test test_workflow_fragment_is_wired "Workflow-tools corpus fragment is wired"

generate_report
