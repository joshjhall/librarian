#!/usr/bin/env bash
# Coverage runner-resolution + fail-loud gate (issue #748).
#
# tests/coverage-python.sh probed for coverage.py with
# `python3 -c 'import coverage'` and drove it with `python3 -m coverage`. CI
# installs coverage with pipx, which puts it in an ISOLATED venv exposing only
# the `coverage` console script — so neither resolved, the script took its skip
# branch, and it exited 0. A green step inside a green job, with Codecov quietly
# reporting `not_found_files: ["coverage.xml"]`. Python coverage had never run.
#
# The fix was a runner resolution (`coverage` on PATH -> `python3 -m coverage`)
# plus COVERAGE_PYTHON_REQUIRED=1 to make a skip fatal where coverage was
# deliberately installed. This gate pins BOTH, because the sibling gate
# (validate-coverage-corpus.sh) is entirely static — it compares file lists and
# never invokes the script, so it cannot see a regression in resolution ORDER or
# in the exit code of the required path. Those are exactly the properties whose
# earlier breakage went unnoticed for months.
#
# THE STUB IS THE POINT. Each case runs the real script against a SANDBOXED PATH
# holding a fake `coverage` (or none), so the branch under test is selected on
# purpose rather than by whatever the host happens to have installed. A gate that
# only ever exercises the branch its own machine reaches is the
# self-skipping-test shape (#543): it covers the present arm and leaves the risky
# one untested.
#
# Three environment traps this had to survive, each of which silently undid the
# PATH strip and made every case pass for the wrong reason:
#   1. `coverage` lives in ~/.local/bin, so the strip must actually exclude it;
#   2. a login/interactive bash re-adds that dir from the user profile, so the
#      child needs --noprofile --norc;
#   3. BASH_ENV (set in this devcontainer) is sourced by EVERY non-interactive
#      bash and re-adds it even then — the same scrub
#      tests/validate-golem-event-listener.sh performs.
#
# Pure bash-3.2 + coreutils; no network, no coverage.py required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

COVERAGE_SH="$SCRIPT_DIR/coverage-python.sh"

# Resolve bash ONCE by absolute path, the same way
# tests/validate-golem-event-listener.sh does. The sandboxed runs below strip
# PATH deliberately, so a bare `bash` could not be resolved from inside them —
# but a hardcoded /usr/bin/bash is wrong on macOS, where bash lives in /bin.
REAL_BASH="$(command -v bash)"

test_suite "Coverage runner resolution + fail-loud (#748)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- sandbox helpers ---------------------------------------------------------

# make_stub_dir <name> — a PATH dir holding python3 plus, optionally, a fake
# `coverage` that records it was called and exits 0.
make_stub_dir() {
    local dir="$WORKDIR/$1"
    command mkdir -p "$dir"
    command ln -sf "$(command -v python3)" "$dir/python3" 2>/dev/null || true
    printf '%s\n' "$dir"
}

# add_coverage_stub <dir> — a `coverage` that answers --version and, for `run`,
# execs the real python3 so the script's drivers still work.
add_coverage_stub() {
    local dir="$1"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "${1:-}" = "--version" ]; then echo "coverage 7.0.0 (stub)"; exit 0; fi\n'
        printf 'echo "STUB_COVERAGE_CALLED $*" >>"%s/stub-calls.log"\n' "$WORKDIR"
        printf 'exit 0\n'
    } >"$dir/coverage"
    command chmod +x "$dir/coverage"
}

# run_script <path-dir> [ENV=VAL ...] — run coverage-python.sh with PATH scoped
# to <path-dir> plus the core system dirs, with the profile and BASH_ENV scrubbed
# (see the header). Output lands in RUN_OUT, exit code in RUN_RC.
RUN_OUT=""
RUN_RC=0
run_script() {
    local dir="$1"
    shift
    set +e
    RUN_OUT="$(
        PATH="$dir:/usr/bin:/bin" BASH_ENV="" "$@" \
            "$REAL_BASH" --noprofile --norc "$COVERAGE_SH" 2>&1
    )"
    RUN_RC=$?
    set -e
}

# --- tests -------------------------------------------------------------------

# Guard the sandbox itself. If the strip leaks (any of the three traps above),
# every case below silently tests the host's real coverage instead of the branch
# it names — passing for a reason that has nothing to do with the assertion.
test_sandbox_actually_strips_coverage() {
    local dir
    dir="$(make_stub_dir bare)"
    local found
    found="$(PATH="$dir:/usr/bin:/bin" BASH_ENV="" "$REAL_BASH" --noprofile --norc \
        -c 'command -v coverage || true')"

    assert_equals "" "$found" \
        "Sandbox PATH genuinely excludes coverage (profile + BASH_ENV scrubbed)"
}

# No runner at all, no required flag -> a clean skip, exit 0. This is the
# laptop/macOS posture and must stay friendly.
test_absent_runner_skips_cleanly() {
    local dir
    dir="$(make_stub_dir skip-case)"
    run_script "$dir"

    assert_equals "0" "$RUN_RC" "An absent coverage runner exits 0 (clean skip)"
    assert_contains "$RUN_OUT" "[skip] python-coverage" "It announces the skip"
}

# THE REGRESSION GUARD. Same absent runner, but the caller declared coverage must
# be there. This must FAIL, not skip — it is the whole mechanism preventing a
# repeat of "installed, unusable, green".
test_absent_runner_fails_when_required() {
    local dir
    dir="$(make_stub_dir required-case)"
    run_script "$dir" env COVERAGE_PYTHON_REQUIRED=1

    assert_equals "1" "$RUN_RC" \
        "COVERAGE_PYTHON_REQUIRED=1 turns an absent runner into a hard failure (exit 1)"
    assert_contains "$RUN_OUT" "[FAIL] python-coverage" "It fails loudly rather than skipping"
    assert_not_contains "$RUN_OUT" "[skip] python-coverage" \
        "It does NOT take the skip branch when coverage was required"
}

# A `coverage` on PATH is selected — the pipx case the module-only probe missed.
test_path_runner_is_selected() {
    local dir
    dir="$(make_stub_dir path-case)"
    add_coverage_stub "$dir"
    run_script "$dir"

    assert_contains "$RUN_OUT" "Runner: coverage on PATH" \
        "A coverage on PATH is selected (the pipx case the module probe missed)"
    assert_not_contains "$RUN_OUT" "[skip] python-coverage" \
        "A resolvable PATH runner does not skip"
}

# RESOLUTION ORDER, with BOTH runners resolvable. This is the case that actually
# pins the order, and it needs saying why the obvious version of this test does
# not work: on a host where `import coverage` fails (every dev box here — pipx
# keeps it in its own venv), the module branch cannot be selected no matter where
# it sits, so PATH wins under either ordering and the assertion is vacuous.
# Caught by the mutation round: swapping the branches back to module-first — the
# original #748 defect — left the earlier version of this test GREEN.
#
# So the sandbox makes the module branch genuinely resolvable too, via a
# PYTHONPATH stub package exposing the `coverage.Coverage` attribute the probe
# touches. Only then does "path is checked FIRST" become an observable claim.
test_path_runner_wins_when_both_resolve() {
    local dir modpath
    dir="$(make_stub_dir both-case)"
    add_coverage_stub "$dir"

    # A minimal importable `coverage` package with the probed attribute.
    modpath="$WORKDIR/pymod"
    command mkdir -p "$modpath/coverage"
    printf 'class Coverage:\n    pass\n' >"$modpath/coverage/__init__.py"

    # Sanity: the module branch really IS resolvable here. Without this the test
    # silently degrades back into the vacuous version above.
    local importable
    importable="$(PATH="$dir:/usr/bin:/bin" BASH_ENV="" PYTHONPATH="$modpath" \
        "$REAL_BASH" --noprofile --norc \
        -c 'python3 -c "import coverage; coverage.Coverage" 2>/dev/null && echo yes || echo no')"
    assert_equals "yes" "$importable" \
        "Sandbox makes the MODULE runner resolvable too (else the order claim is vacuous)"

    run_script "$dir" env PYTHONPATH="$modpath"

    assert_contains "$RUN_OUT" "Runner: coverage on PATH" \
        "With both resolvable, PATH wins — the ordering that fixes the pipx case"
    assert_not_contains "$RUN_OUT" "Runner: python3 -m coverage" \
        "The module runner is NOT selected ahead of PATH"
}

# THE MODULE BRANCH'S HAPPY PATH. The ordering test above only ever watches the
# module runner LOSE, and every other resolving case asserts the PATH runner won
# — so nothing observed `python3 -m coverage` actually being selected and working.
# That is the fallback a developer with coverage pip-installed (but not on PATH)
# hits, and "never chosen ahead of PATH" is not evidence it is choosable at all.
# Here PATH carries no coverage while the module stub does, so the elif is the
# only branch left.
test_module_runner_is_selected_when_alone() {
    local dir modpath
    dir="$(make_stub_dir module-only-case)" # deliberately no coverage stub

    modpath="$WORKDIR/pymod-only"
    command mkdir -p "$modpath/coverage"
    printf 'class Coverage:\n    pass\n' >"$modpath/coverage/__init__.py"

    run_script "$dir" env PYTHONPATH="$modpath"

    assert_contains "$RUN_OUT" "Runner: python3 -m coverage" \
        "With only the module resolvable, the module runner IS selected"
    assert_not_contains "$RUN_OUT" "[skip] python-coverage" \
        "The module fallback does not skip"
    assert_not_contains "$RUN_OUT" "Runner: coverage on PATH" \
        "It does not claim a PATH runner that is not there"
}

# A `coverage` NAME on PATH is not proof it WORKS. A stub that fails --version
# must not be selected — it must fall through to the module branch or the skip,
# never be driven as if healthy.
test_broken_path_runner_is_not_selected() {
    local dir
    dir="$(make_stub_dir broken-case)"
    printf '#!/usr/bin/env bash\nexit 127\n' >"$dir/coverage"
    command chmod +x "$dir/coverage"
    run_script "$dir"

    assert_not_contains "$RUN_OUT" "Runner: coverage on PATH" \
        "A coverage that fails its probe is NOT selected as the runner"
    assert_equals "0" "$RUN_RC" "It degrades to the clean skip rather than erroring"
}

# The required flag must not fire when a runner IS resolvable — otherwise CI
# would fail on a healthy environment.
#
# THE ASSERTION IS ABOUT THE RESOLUTION MESSAGE, NOT ABOUT SUCCESS. The stub
# coverage answers --version and then exits 0 without writing any data file, so
# the script legitimately fails LATER at `coverage.xml is empty`. A blanket
# "no [FAIL] appears" check therefore fails on CI while passing locally, and —
# worse — could not distinguish "the required flag fired" from "the stub produced
# no data": two different failures wearing the same string. (It passed locally
# only because the host's real coverage was reachable through the sandbox.)
#
# So assert the specific thing: the run got past resolution, and the
# required-mode diagnostic — which names the flag — is absent.
test_required_flag_is_inert_when_runner_resolves() {
    local dir
    dir="$(make_stub_dir required-ok-case)"
    add_coverage_stub "$dir"
    run_script "$dir" env COVERAGE_PYTHON_REQUIRED=1

    assert_contains "$RUN_OUT" "Runner:" \
        "A resolvable runner is announced even with COVERAGE_PYTHON_REQUIRED=1"
    assert_not_contains "$RUN_OUT" "COVERAGE_PYTHON_REQUIRED=1" \
        "The required-mode failure does NOT fire when a runner resolves"
    assert_not_contains "$RUN_OUT" "coverage.py not installed" \
        "It does not claim coverage is missing when a runner resolved"
}

# CI must actually SET the flag — the guard is worthless if the one caller that
# needs it forgets. Structural, so it holds without running the workflow.
#
# The assertion must ignore COMMENTS. A raw file-contains check passed with the
# `env:` block deleted, because the long comment above it explaining the flag
# still names it — the prose satisfied the assertion that was supposed to be
# checking the setting. Caught by the mutation round; it is the same shape as a
# config comment keeping a check green after the config itself is gone. So match
# the YAML key on a non-comment line instead.
# The match is also ANCHORED TO THE OWNING STEP. A whole-file grep cannot tell
# "wired to the Python coverage step" from "appears once somewhere in the
# workflow", so a future edit that attached the flag to the wrong step would
# still pass. Scope to the lines following the step header instead.
test_ci_sets_required_flag() {
    local ci="$REPO_ROOT/.github/workflows/ci.yml" step_block hits
    assert_file_exists "$ci" "ci.yml exists"

    # The `Python coverage` step's own block: from its header to the next step.
    step_block="$(command grep -v '^[[:space:]]*#' "$ci" 2>/dev/null |
        command awk '
            /^[[:space:]]*-[[:space:]]*name:[[:space:]]*Python coverage[[:space:]]*$/ { inb = 1; next }
            inb && /^[[:space:]]*-[[:space:]]*name:/ { inb = 0 }
            inb { print }')"

    assert_not_empty "$step_block" \
        "The 'Python coverage' step is present in ci.yml (else the anchor matches nothing)"

    hits="$(printf '%s\n' "$step_block" |
        command grep -cE '^[[:space:]]*COVERAGE_PYTHON_REQUIRED:[[:space:]]*"?1"?[[:space:]]*$' || true)"

    assert_equals "1" "$hits" \
        "The Python coverage step itself SETS COVERAGE_PYTHON_REQUIRED: \"1\" (real key, not a comment)"
}

run_test test_sandbox_actually_strips_coverage "Sandbox strips coverage from PATH"
run_test test_absent_runner_skips_cleanly "Absent runner skips cleanly (exit 0)"
run_test test_absent_runner_fails_when_required "Absent runner fails when required (exit 1)"
run_test test_path_runner_is_selected "coverage on PATH is selected"
run_test test_path_runner_wins_when_both_resolve "PATH wins when both runners resolve"
run_test test_module_runner_is_selected_when_alone "Module runner is selected when alone"
run_test test_broken_path_runner_is_not_selected "A broken PATH runner is not selected"
run_test test_required_flag_is_inert_when_runner_resolves "Required flag inert when runner resolves"
run_test test_ci_sets_required_flag "ci.yml sets the required flag"

generate_report
