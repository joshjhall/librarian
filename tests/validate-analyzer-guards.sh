#!/usr/bin/env bash
# Analyzer-crash guards on the python3-backed lint gates (issue #1078).
#
# Five tests/lint-*.sh gates build their entire report by assigning an embedded
# python3 analyzer's stdout to a top-level variable. Under `set -euo pipefail`,
# `VAR="$(cmd)"` propagates the inner command's status to the simple command, so
# an uncaught exception in the analyzer aborts the gate AT THAT LINE — before any
# run_test call and before the trailing generate_report, which is the call that
# turns TESTS_FAILED into the verdict.
#
# Measured before the fix, on the real gate with a crashing analyzer:
#
#   === Scanner extension-dispatch case parity (#754) ===
#   rc=3
#
# The suite header, then nothing. This is fail-LOUD, not silence-reads-as-a-pass:
# the process exits non-zero, run_stage renders the stage red, and nothing merges
# on the back of it. What is lost is the DIAGNOSTIC — on a sharded CI run, a
# stage that failed without saying which assertion, in a suite whose whole design
# principle is that a failure names itself.
#
# WHY THIS GATE RUNS THE REAL GATES AGAINST A STUB, rather than injecting a
# `raise SystemExit` into a sandboxed COPY (the shape issue #1078 suggested). A
# copy proves the guard fires IN THE COPY, which stays true while the shipped
# gate sits unguarded — the correct-copy-is-not-the-one-under-test shape. A
# crashing `python3` on PATH exercises the committed bytes of each gate, so the
# assertion cannot pass while the file a CI run executes is unprotected.
#
# BASH_ENV is unset for every stubbed child. In the devcontainer it points at
# /etc/bash_env, whose /etc/bashrc.d/ scripts hard-RESET $PATH; measured
# in-session, that lets the REAL /usr/local/bin/python3 outrank the stub and the
# gate passes GREEN — a negative fixture proving nothing, which is worse than no
# fixture at all. Same trap tests/validate-lint-gates.sh documents at its head.
#
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REAL_BASH="$(command -v bash)"

# The stub's stderr line. Asserted in the gate output to prove two things at
# once: that the analyzer's stderr genuinely reaches the report (issue #1078
# AC2 — a crash row with no cause is useless), and that the stub was actually
# REACHED rather than bypassed by a PATH reset.
STUB_STDERR="ANALYZER-STUB-TRACEBACK: deliberate crash"
STUB_RC=3

# The substring every guard's failure row must carry. Deliberately not imported
# from the gates under test — importing it would make the assertion tautological
# (it would match whatever the gates happen to say, including nothing).
CRASH_ROW="the python3 analyzer crashed"

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
# `-uVAR` attached, never GNU `--unset=VAR`: BSD env has no long options and
# dies `env: unsetenv nset=VAR: Invalid argument`.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Analyzer-crash guards on python3-backed lint gates (#1078)"

# The gates under test. Space-separated rather than an associative array: these
# files must stay bash-3.2 clean for base macOS, where `declare -A` is a syntax
# error. Cross-checked against a filesystem sweep by the roster guard below, so
# this list cannot silently fall behind the tree.
GUARDED_GATES="lint-classifier-lang.sh
lint-language-table-sync.sh
lint-review-route-lang.sh
lint-scanner-case-dispatch.sh
lint-test-file-anchoring.sh"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- The crashing analyzer stub ---------------------------------------------

# make_stub_dir <varname> — a PATH dir whose `python3` always crashes, plus the
# coreutils the gates themselves shell out to. Those are symlinked rather than
# inherited because the stub dir becomes the ENTIRE PATH: a real python3 further
# down the operator's PATH would defeat the whole fixture.
# The internal locals are underscore-prefixed so they cannot SHADOW the caller's
# variable: `local dir` here would hide a caller's `dir`, printf -v would assign
# the local copy, and the caller would read an unset name (loud under `set -u`,
# but only because of it).
make_stub_dir() {
    local __out="$1" _dir _tool _src
    _dir="$(command mktemp -d "$WORKDIR/stub.XXXXXX")" || return 1
    command mkdir -p "$_dir/bin"
    # `bash` is load-bearing: the stub's `#!/usr/bin/env bash` shebang resolves
    # through this PATH, and with the stub dir as the ENTIRE PATH an absent bash
    # makes the stub silently unexecutable — the gate would then take its
    # python3-ABSENT branch and exit the 77 skip sentinel, which is a PASS-shaped
    # outcome that looks nothing like the crash this fixture is testing.
    for _tool in bash env printf cat grep sed cut sort find mktemp rm cp mkdir \
        dirname basename tr wc head awk locale chmod ln; do
        _src="$(command -v "$_tool" 2>/dev/null)" || continue
        command ln -sf "$_src" "$_dir/bin/$_tool" 2>/dev/null || true
    done
    {
        command printf '#!/usr/bin/env bash\n'
        # A bare `--version` / `-c` probe must ALSO crash. A stub that answered
        # probes successfully and failed only the real invocation would leave the
        # fixture silent on any gate that version-gates its runtime first.
        command printf 'printf "%%s\\n" "%s" >&2\n' "$STUB_STDERR"
        command printf 'exit %s\n' "$STUB_RC"
    } >"$_dir/bin/python3"
    command chmod +x "$_dir/bin/python3"
    printf -v "$__out" '%s' "$_dir"
}

# Results of the most recent gate invocation.
GATE_RC=0
GATE_OUT=""

# run_gate <gate-basename> [stubdir] — run the REAL committed gate. With a
# stubdir, PATH is pinned to it ONLY so python3 crashes; without one, the gate
# runs against the real environment (the positive control).
run_gate() {
    local gate="$1" dir="${2:-}"
    GATE_RC=0
    if [ -n "$dir" ]; then
        GATE_OUT="$(cd "$REPO_ROOT" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            -uBASH_ENV \
            HOME="$dir" \
            PATH="$dir/bin" \
            "$REAL_BASH" "$SCRIPT_DIR/$gate" 2>&1)" || GATE_RC=$?
    else
        GATE_OUT="$(cd "$REPO_ROOT" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            "$REAL_BASH" "$SCRIPT_DIR/$gate" 2>&1)" || GATE_RC=$?
    fi
}

# --- The roster guard -------------------------------------------------------

# GUARDED_GATES must match the tree. Issue #1078 AC4 asked for a one-time sweep
# confirming five gates carry this shape; this turns that sweep into a standing
# invariant, so a SIXTH gate landing with an unguarded analyzer capture fails
# here instead of being quietly uncovered. That is the difference between a fix
# and a fix that stays fixed — the harden-one-knob-grep-every-sibling class this
# repo keeps re-filing.
test_roster_matches_the_tree() {
    local found expected
    # The discriminator is an indented `command python3 - ` heredoc launch: the
    # shape that captures a whole analyzer program. `grep -l` on FILES (not a
    # pipeline) — a `grep -q` in a pipeline can invert its own match under
    # pipefail via SIGPIPE.
    found="$(cd "$SCRIPT_DIR" && command grep -lE '^[[:space:]]*command python3 - ' \
        lint-*.sh 2>/dev/null | command sort || true)"
    expected="$(command printf '%s\n' "$GUARDED_GATES" | command sort)"

    assert_not_empty "$found" "the filesystem sweep found python3-backed lint gates"
    if [ "$found" != "$expected" ]; then
        _fail "the guarded-gate roster no longer matches the tree" \
            "A gate carrying an embedded python3 analyzer is not covered by this fixture (or a covered one was renamed/removed). Add it to GUARDED_GATES and give it the rc guard — an unguarded analyzer bypasses generate_report entirely (#1078)." \
            "swept:    $(command printf '%s' "$found" | command tr '\n' ' ')" \
            "expected: $(command printf '%s' "$expected" | command tr '\n' ' ')"
    fi
}

# --- The stub is genuinely reached ------------------------------------------

# Without this, every crash case below could be passing because the stub PATH is
# being bypassed and something ELSE is failing the gate. Measured: with BASH_ENV
# set, that is exactly what happens.
test_stub_python3_is_what_runs() {
    local dir out rc=0
    make_stub_dir dir || {
        skip_test "mktemp unavailable — cannot build the stub PATH"
        return 0
    }
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
        PATH="$dir/bin" "$REAL_BASH" -c 'command python3 --version' 2>&1)" || rc=$?
    assert_true "[ $rc -eq $STUB_RC ]" \
        "the stub python3 is what resolves on the scrubbed stub PATH (exit $STUB_RC)"
    assert_contains "$out" "$STUB_STDERR" \
        "the stub's stderr is what a caller sees"
}

# --- Per-gate crash behaviour ------------------------------------------------

# assert_gate_reports_the_crash <gate> — the four properties a guarded gate must
# have when its analyzer dies. Split out so each is stated once and every gate is
# held to the identical bar; a per-gate transcription would be free to drift.
assert_gate_reports_the_crash() {
    local gate="$1" dir
    make_stub_dir dir || {
        skip_test "mktemp unavailable — cannot build the stub PATH"
        return 1
    }
    run_gate "$gate" "$dir"

    # 1. A crashed analyzer still FAILS. This is the property that must not
    #    regress into a skip: the 77 sentinel is for an ABSENT linter, and a
    #    crashing one rendering as "[SKIP] ... did not run" would stop failing
    #    the suite — turning a loud bug into the inert-gate shape (#538/#571).
    assert_true "[ $GATE_RC -ne 0 ]" \
        "$gate: an analyzer crash fails the gate"
    assert_true "[ $GATE_RC -ne 77 ]" \
        "$gate: an analyzer crash is a FAILURE, not the 77 skip sentinel"

    # 2. The failure NAMES itself (AC1) rather than emitting a bare traceback.
    assert_contains "$GATE_OUT" "$CRASH_ROW" \
        "$gate: the crash surfaces as a named failing assertion"

    # 3. The analyzer's stderr is the evidence (AC2) — a crash row that does not
    #    say WHY costs the next person the diagnosis.
    #
    #    Asserted as an INDENTED _fail detail line, not as a bare substring of
    #    the output. run_gate captures the gate with `2>&1`, so the stub's stderr
    #    reaches GATE_OUT whether or not the REPORT carried it — a bare
    #    `assert_contains "$GATE_OUT" "$STUB_STDERR"` passes either way. Found by
    #    mutation: dropping the `2>&1` from a gate's heredoc opener (the exact
    #    regression AC2 is about, which makes the evidence read "(no output
    #    captured)") left that spelling green. _fail indents detail lines by
    #    eight spaces, and an unguarded leak is column-0, so the indent is what
    #    distinguishes "in the report" from "on the terminal".
    assert_contains "$GATE_OUT" "        $STUB_STDERR" \
        "$gate: the crash row carries the analyzer's stderr as evidence (as a report detail line, not a bare leak)"

    #    The paired negative: the placeholder the guard emits when it captured
    #    nothing. Its presence means the rc guard fired but the evidence was
    #    discarded, which is AC2 unmet even though the row above exists.
    assert_not_contains "$GATE_OUT" "(no output captured)" \
        "$gate: the crash row has real evidence, not the empty-capture placeholder"

    # 4. generate_report RAN. This is the actual bypass #1078 is about: the
    #    Summary block is produced by the only call that converts TESTS_FAILED
    #    into the verdict, and the unguarded gates aborted before reaching it.
    assert_contains "$GATE_OUT" "Summary" \
        "$gate: the reporting path ran (generate_report was reached)"
}

# assert_gate_is_clean_normally <gate> — the positive control. Without it, an
# always-firing crash row would satisfy every assertion above while breaking the
# gate for real work; the assertion would be green with AND without the property
# it claims to pin.
assert_gate_is_clean_normally() {
    local gate="$1"
    run_gate "$gate"
    assert_true "[ $GATE_RC -eq 0 ]" \
        "$gate: still passes against the real python3"
    assert_not_contains "$GATE_OUT" "$CRASH_ROW" \
        "$gate: does not report a crash when the analyzer runs fine"
}

test_classifier_lang_reports_a_crash() {
    assert_gate_reports_the_crash lint-classifier-lang.sh
}
test_classifier_lang_is_clean_normally() {
    assert_gate_is_clean_normally lint-classifier-lang.sh
}

test_language_table_sync_reports_a_crash() {
    assert_gate_reports_the_crash lint-language-table-sync.sh
}
test_language_table_sync_is_clean_normally() {
    assert_gate_is_clean_normally lint-language-table-sync.sh
}

test_review_route_lang_reports_a_crash() {
    assert_gate_reports_the_crash lint-review-route-lang.sh
}
test_review_route_lang_is_clean_normally() {
    assert_gate_is_clean_normally lint-review-route-lang.sh
}

test_scanner_case_dispatch_reports_a_crash() {
    assert_gate_reports_the_crash lint-scanner-case-dispatch.sh
}
test_scanner_case_dispatch_is_clean_normally() {
    assert_gate_is_clean_normally lint-scanner-case-dispatch.sh
}

# lint-test-file-anchoring.sh is the variant worth naming: its analyzer lives in
# a scan_root() helper with five OTHER call sites that deliberately tolerate
# failure (the parser self-tests run scan_root against broken fixtures). Only the
# top-level capture is guarded, so this case proves the guard reached the call
# site that matters — the one the grep for `REPORT="$(` never found.
test_test_file_anchoring_reports_a_crash() {
    assert_gate_reports_the_crash lint-test-file-anchoring.sh
}
test_test_file_anchoring_is_clean_normally() {
    assert_gate_is_clean_normally lint-test-file-anchoring.sh
}

run_test test_roster_matches_the_tree "the guarded-gate roster matches the tree (#1078 AC4)"
run_test test_stub_python3_is_what_runs "the crashing python3 stub is genuinely what runs"

run_test test_classifier_lang_reports_a_crash "lint-classifier-lang.sh reports an analyzer crash"
run_test test_classifier_lang_is_clean_normally "lint-classifier-lang.sh is clean with a real python3"
run_test test_language_table_sync_reports_a_crash "lint-language-table-sync.sh reports an analyzer crash"
run_test test_language_table_sync_is_clean_normally "lint-language-table-sync.sh is clean with a real python3"
run_test test_review_route_lang_reports_a_crash "lint-review-route-lang.sh reports an analyzer crash"
run_test test_review_route_lang_is_clean_normally "lint-review-route-lang.sh is clean with a real python3"
run_test test_scanner_case_dispatch_reports_a_crash "lint-scanner-case-dispatch.sh reports an analyzer crash"
run_test test_scanner_case_dispatch_is_clean_normally "lint-scanner-case-dispatch.sh is clean with a real python3"
run_test test_test_file_anchoring_reports_a_crash "lint-test-file-anchoring.sh reports an analyzer crash (via scan_root)"
run_test test_test_file_anchoring_is_clean_normally "lint-test-file-anchoring.sh is clean with a real python3"

generate_report
