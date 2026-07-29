#!/usr/bin/env bash
# Lint-gate integrity coverage (issue #538).
#
# tests/lint-python.sh used to gate on a bare `command -v ruff` and exit 0 when
# ruff was absent, which tests/run-all.sh rendered as `[ok] Python lint + format
# (ruff) (0s)` — byte-identical to a real pass. On a host with no ruff binary the
# gate was therefore INERT while reading green, and nobody noticed. Two
# behaviours now carry that regression risk:
#
#   1. RUNNER RESOLUTION — `ruff` on PATH wins; else a PROBED `uvx ruff` (uvx can
#      exist but be offline/uncached, so an unprobed selection would turn a
#      graceful skip into a hard failure); else skip. The gate must genuinely
#      invoke the runner it selected, and must FAIL when that runner reports a
#      violation — a resolution that resolves but does not actually lint is the
#      original bug wearing a different hat.
#   2. SKIP-VS-PASS REPORTING — the skip branch exits with the reserved sentinel
#      77 and run-all.sh's run_stage renders it `[SKIP] … did not run` WITHOUT
#      failing the suite. A skip that renders as `[ok]`, or one that fails the
#      suite, both re-break the contract.
#
# Test shape: each resolution case runs the REAL tests/lint-python.sh against a
# stub PATH holding a fake `ruff`/`uvx` whose behaviour the case controls, so the
# selection is observable (each stub logs its invocation) without needing the
# real binaries. The reporting cases source run-all.sh's run_stage in isolation
# and drive it with canned exit codes.
#
# BASH_ENV is unset for every child: in the devcontainer it points at
# /etc/bash_env, whose /etc/bashrc.d/ scripts hard-RESET $PATH and would let the
# REAL ruff/uvx outrank the stubs, silently invalidating every resolution case.
#
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT_PYTHON="$SCRIPT_DIR/lint-python.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"

REAL_BASH="$(command -v bash)"
# Absolute path for the same reason as REAL_BASH: the stub PATH holds only the
# symlinks stub_dir plants, and `sh` is not among them, so a bare `sh` would not
# resolve. `sh` specifically (not bash) because just runs recipes under sh —
# testing the recipe body under bash would not prove it parses where it runs.
REAL_SH="$(command -v sh)"

# The reserved "did not run" sentinel. Duplicated from the scripts under test on
# purpose: importing it from them would make the assertion tautological.
SKIP_SENTINEL=77

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Lint-gate integrity (runner resolution + skip reporting) (#538)"

# --- Sandbox plumbing -------------------------------------------------------

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# stub_dir <varname> — a fresh empty dir to hold PATH stubs, plus the coreutils
# the gate itself needs (find/sort). Those are symlinked rather than inherited,
# because the stub dir becomes the ENTIRE PATH: a resolution case must not be
# able to reach a real ruff/uvx sitting further down the operator's PATH.
stub_dir() {
    local __out="$1" dir tool src
    dir="$(command mktemp -d "$WORKDIR/stub.XXXXXX")" || return 1
    command mkdir -p "$dir/bin"
    # `bash` is load-bearing: the stubs' `#!/usr/bin/env bash` shebang resolves
    # through this PATH, and with the stub dir as the ENTIRE PATH an absent bash
    # makes every stub silently unexecutable (the gate then reports "no runner").
    for tool in bash env find sort cat printf locale grep mktemp rm dirname basename tr; do
        src="$(command -v "$tool" 2>/dev/null)" || continue
        command ln -sf "$src" "$dir/bin/$tool" 2>/dev/null || true
    done
    printf -v "$__out" '%s' "$dir"
}

# plant_runner <dir> <name> <version_rc> <lint_rc>
#   Writes an executable stub at <dir>/bin/<name> that:
#     - logs every invocation ("<name> <args...>") to <dir>/calls.log
#     - exits <version_rc> for a `--version` probe (the uvx availability check)
#     - exits <lint_rc> for anything else (check / format --check)
#   `uvx` stubs swallow their leading `ruff` argument the same way the real uvx
#   does, so the log records what ruff was actually asked to do.
plant_runner() {
    local dir="$1" name="$2" version_rc="$3" lint_rc="$4"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'printf "%%s %%s\\n" "%s" "$*" >>"%s/calls.log"\n' "$name" "$dir"
        command printf 'for a in "$@"; do\n'
        command printf '    if [ "$a" = "--version" ]; then exit %s; fi\n' "$version_rc"
        command printf 'done\n'
        command printf 'exit %s\n' "$lint_rc"
    } >"$dir/bin/$name"
    command chmod +x "$dir/bin/$name"
}

# Results of the most recent gate invocation.
GATE_RC=0
GATE_OUT=""
GATE_LOG=""

# run_gate <stubdir> — run the REAL lint-python.sh with PATH pinned to the stub
# dir ONLY. Captures exit code, stdout+stderr, and the runner call log.
run_gate() {
    local dir="$1"
    command rm -f "$dir/calls.log"
    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        HOME="$dir" \
        PATH="$dir/bin" \
        "$REAL_BASH" "$LINT_PYTHON" 2>&1)" || GATE_RC=$?
    GATE_LOG="$(command cat "$dir/calls.log" 2>/dev/null || true)"
}

# --- Resolution: ruff on PATH wins ------------------------------------------

test_prefers_ruff_binary_when_present() {
    local sb
    stub_dir sb || return 1
    plant_runner "$sb" ruff 0 0
    plant_runner "$sb" uvx 0 0
    run_gate "$sb"

    assert_equals "0" "$GATE_RC" "gate passes when the ruff stub reports clean"
    assert_contains "$GATE_LOG" "ruff check plugins" "the ruff binary is invoked for check"
    assert_contains "$GATE_LOG" "ruff format --check plugins" "the ruff binary is invoked for format"
    assert_contains "$GATE_OUT" "Runner: ruff on PATH" "the resolved runner is announced"
    # uvx must not be consulted at all when a real ruff exists.
    assert_true "! printf '%s' \"$GATE_LOG\" | command grep -q '^uvx '" \
        "uvx is not invoked when ruff is on PATH"
}

# The whole point of the issue: a resolved runner must make the gate FAIL on a
# violation. A gate that resolves but swallows the verdict is still vacuous.
test_ruff_violation_fails_the_gate() {
    local sb
    stub_dir sb || return 1
    plant_runner "$sb" ruff 0 1 # lint_rc=1 → violations found
    run_gate "$sb"

    assert_equals "1" "$GATE_RC" "a reported violation fails the gate"
    assert_contains "$GATE_OUT" "FAIL" "the failure is visible in the report"
}

# --- Resolution: probed uvx fallback ----------------------------------------

test_falls_back_to_uvx_when_ruff_absent() {
    local sb
    stub_dir sb || return 1
    plant_runner "$sb" uvx 0 0 # probe succeeds, lint clean; no ruff planted
    run_gate "$sb"

    assert_equals "0" "$GATE_RC" "gate runs (not skips) via uvx when ruff is absent"
    assert_contains "$GATE_LOG" "uvx ruff --version" "the uvx availability probe runs"
    assert_contains "$GATE_LOG" "uvx ruff check plugins" "check is dispatched through uvx"
    assert_contains "$GATE_LOG" "uvx ruff format --check plugins" "format is dispatched through uvx"
    assert_contains "$GATE_OUT" "Runner: uvx ruff" "the uvx runner is announced"
}

test_uvx_violation_fails_the_gate() {
    local sb
    stub_dir sb || return 1
    plant_runner "$sb" uvx 0 1 # probe OK, lint reports violations
    run_gate "$sb"

    assert_equals "1" "$GATE_RC" "a violation reported through uvx fails the gate"
}

# A present-but-broken uvx (offline, no cached ruff) must degrade to the SKIP
# branch, NOT to a hard gate failure — that would make a bare host unable to run
# the suite at all.
test_unusable_uvx_skips_rather_than_fails() {
    local sb
    stub_dir sb || return 1
    plant_runner "$sb" uvx 1 0 # probe FAILS
    run_gate "$sb"

    assert_equals "$SKIP_SENTINEL" "$GATE_RC" "a failing uvx probe yields the skip sentinel"
    assert_contains "$GATE_LOG" "uvx ruff --version" "the probe was actually attempted"
    assert_true "! printf '%s' \"$GATE_LOG\" | command grep -q 'check plugins'" \
        "no lint is attempted through an unusable uvx"
}

# A uvx that HANGS (stalled network — DNS resolves, connection never completes)
# must not wedge the suite. run-all.sh deliberately does not wrap stages in
# `timeout`, so nothing upstream would bound this; the gate bounds its own probe.
# Distinct from the failing-probe case above: that one exits promptly non-zero,
# this one never returns on its own.
test_hanging_uvx_is_bounded_not_wedged() {
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout(1) unavailable — cannot bound the hang case"
        return 0
    fi

    local sb
    stub_dir sb || return 1
    command ln -sf "$(command -v sleep)" "$sb/bin/sleep" 2>/dev/null || true
    command ln -sf "$(command -v timeout)" "$sb/bin/timeout" 2>/dev/null || true

    # A uvx whose --version probe never returns.
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'printf "uvx %%s\\n" "$*" >>"%s/calls.log"\n' "$sb"
        command printf 'for a in "$@"; do\n'
        command printf '    if [ "$a" = "--version" ]; then sleep 3600; fi\n'
        command printf 'done\n'
        command printf 'exit 0\n'
    } >"$sb/bin/uvx"
    command chmod +x "$sb/bin/uvx"

    # Outer bound well under the inner one: if the gate honors UVX_PROBE_TIMEOUT
    # it returns on its own and this never fires. Exit 124 = the outer timeout
    # fired = the gate wedged.
    local rc=0 out
    out="$(command timeout 30 /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        HOME="$sb" \
        PATH="$sb/bin" \
        UVX_PROBE_TIMEOUT=2 \
        "$REAL_BASH" "$LINT_PYTHON" 2>&1)" || rc=$?

    assert_true "[ \"$rc\" -ne 124 ]" "the gate returns on its own — a hanging uvx does not wedge it"
    assert_equals "$SKIP_SENTINEL" "$rc" "a hanging uvx degrades to the skip sentinel"
    assert_contains "$out" "GATE DID NOT RUN" "the bounded hang reports as a skip, not a pass"
}

# --- Resolution: nothing available → loud skip ------------------------------

test_no_runner_exits_skip_sentinel() {
    local sb
    stub_dir sb || return 1 # neither ruff nor uvx planted
    run_gate "$sb"

    assert_equals "$SKIP_SENTINEL" "$GATE_RC" "exits the reserved skip sentinel, not 0"
}

# The message is the user-visible half of the fix: it must be impossible to read
# a skip as a pass.
test_skip_message_says_it_did_not_run() {
    local sb
    stub_dir sb || return 1
    run_gate "$sb"

    assert_contains "$GATE_OUT" "GATE DID NOT RUN" "the skip states the gate did not run"
    assert_contains "$GATE_OUT" "Skipped: 1" "the skip is counted as skipped"
    assert_contains "$GATE_OUT" "Failed:  0" "a skip is not reported as a failure"
}

# --- Reporting: run_stage renders 77 distinctly -----------------------------
#
# run-all.sh is a linear script that would execute the whole suite if sourced, so
# run_stage is extracted by slicing the function definition out of the source and
# eval'ing just that, alongside the SKIP_EXIT_CODE constant it reads.
# (Same "slice the pure helper" idea as validate-workflow-helpers.mjs.)

# render_stage <exit_code> — run run-all.sh's real run_stage over a command that
# exits <exit_code>. Echoes the rendered line plus the resulting rc.
render_stage() {
    local code="$1"
    /usr/bin/env --unset=BASH_ENV "$REAL_BASH" -c '
        set -uo pipefail
        rc=0
        SKIP_EXIT_CODE=77
        eval "$(command sed -n "/^run_stage() {/,/^}/p" "$1")"
        run_stage "Demo stage" "$3" -c "exit $2"
        printf "SUITE_RC=%s\n" "$rc"
    ' _ "$RUN_ALL" "$code" "$REAL_BASH" 2>&1
}

test_run_stage_renders_skip_not_ok() {
    local out
    out="$(render_stage "$SKIP_SENTINEL")"

    assert_contains "$out" "[SKIP] Demo stage" "a 77 stage renders as [SKIP]"
    assert_contains "$out" "did not run" "the [SKIP] line says it did not run"
    assert_true "! printf '%s' \"$out\" | command grep -q '\[ok\] Demo stage'" \
        "a 77 stage is NOT rendered as [ok] (the original bug)"
}

test_run_stage_skip_does_not_fail_suite() {
    local out
    out="$(render_stage "$SKIP_SENTINEL")"

    assert_contains "$out" "SUITE_RC=0" "a skipped stage leaves the suite rc at 0"
}

# Guard the other two arms of the same branch: widening it to recognize 77 must
# not have disturbed pass or fail rendering.
test_run_stage_still_renders_pass_and_fail() {
    local ok_out fail_out
    ok_out="$(render_stage 0)"
    fail_out="$(render_stage 1)"

    assert_contains "$ok_out" "[ok] Demo stage" "exit 0 still renders [ok]"
    assert_contains "$ok_out" "SUITE_RC=0" "exit 0 leaves the suite rc at 0"
    assert_contains "$fail_out" "[FAIL] Demo stage" "a non-0/77 exit still renders [FAIL]"
    assert_contains "$fail_out" "SUITE_RC=1" "a real failure still fails the suite"
}

# --- Wiring: the sentinel constant stays in sync ----------------------------

test_sentinel_constant_agreed_by_both_scripts() {
    assert_file_contains "$LINT_PYTHON" "SKIP_EXIT_CODE=$SKIP_SENTINEL" \
        "lint-python.sh defines the shared skip sentinel"
    assert_file_contains "$RUN_ALL" "SKIP_EXIT_CODE=$SKIP_SENTINEL" \
        "run-all.sh defines the same skip sentinel"
}

# post-create.sh is the "suspenders" half of the fix — a fresh container must end
# up with a real ruff, and must fail loudly rather than proceed without one.
test_post_create_ensures_ruff() {
    local pc="$REPO_ROOT/.devcontainer/post-create.sh"
    assert_file_exists "$pc" "post-create.sh exists"
    assert_file_contains "$pc" "uv tool install ruff" "installs ruff via uv when available"
    assert_file_contains "$pc" "pipx install ruff" "falls back to pipx"
    assert_file_contains "$pc" "ERROR: ruff still not on PATH" "verifies ruff landed on PATH"
}

# #544 — `just lint` must share lint-python.sh's runner resolution. It did NOT,
# and nothing caught that: every case above drives lint-python.sh, so the
# justfile could keep calling bare `ruff` while the gate's own resolution grew a
# uvx branch. On a uvx-only host that made `just test` pass and `just lint`
# hard-fail "command not found" — two documented entry points for one lint pass,
# disagreeing. Pin the justfile side so the pair cannot drift apart again.
#
# TWO tests, because a grep alone is not enough here. The file-content case
# below pins that the justfile still CARRIES the resolution; the behavioural case
# after it pins that the recipe body actually PARSES AND RUNS. A broken backslash
# continuation or a typo'd variable would satisfy every assert_file_contains here
# and still leave `just lint` broken for real users — the recipe is
# backslash-joined POSIX sh, which is exactly the shape where that mistake hides.
test_justfile_shares_ruff_resolution() {
    local jf="$REPO_ROOT/justfile"
    assert_file_exists "$jf" "justfile exists"
    assert_file_contains "$jf" 'command -v ruff' \
        "just lint prefers a ruff binary on PATH"
    assert_file_contains "$jf" 'uvx ruff --version' \
        "just lint PROBES uvx before selecting it (an unprobed uvx hard-fails when offline)"
    assert_file_contains "$jf" 'RUFF="uvx ruff"' \
        "just lint falls back to uvx ruff"
    assert_file_contains "$jf" '$RUFF check plugins' \
        "just lint invokes check through the resolved runner, not a bare ruff"
    assert_file_contains "$jf" '$RUFF format --check plugins' \
        "just lint invokes format --check through the resolved runner"
    # The skip branch must SAY it did not run, for the same reason the gate's
    # sentinel exists: a silent no-op reads as a pass.
    assert_file_contains "$jf" 'did NOT run' \
        "just lint's no-runner branch announces that Python lint was skipped"
    # The probe must be BOUNDED. Unbounded, a stalled link (DNS resolves,
    # connection hangs) wedges `just lint` forever — and it is not always run
    # with an operator present to interrupt it.
    assert_file_contains "$jf" 'UVX_PROBE_TIMEOUT' \
        "just lint bounds the uvx probe so a stalled network cannot wedge it"
}

# Behavioural half of the pair: extract the recipe's ruff-resolution body from
# the justfile and RUN it under a stub PATH. Needs neither `just` installed nor
# the recipe's dprint/taplo/rumdl/node steps.
#
# It must replicate just's LINE MODEL, not just concatenate the text. just feeds
# each recipe line to its own shell, and a trailing `\` is what makes several
# source lines one logical command. So the extraction JOINS ONLY ON `\`: a line
# without one ends the command, exactly as just would treat it. Getting this
# wrong makes the test vacuous — an earlier revision emitted the raw lines and
# let `sh` re-join them, which still ran fine with a backslash deleted and so
# passed against a justfile that `just` itself would have broken on.
#
# Extracting rather than duplicating the snippet is the point: a hand-copied
# expectation would drift from the justfile and pass while the real recipe broke.
test_justfile_recipe_body_executes() {
    local jf="$REPO_ROOT/justfile" body
    # From the `@if command -v ruff` opener to the first line NOT ending in `\`.
    # Strip just's `@` prefix and indentation, drop the trailing backslash, and
    # join with a space — the result is the single logical command just builds.
    # A missing backslash therefore TRUNCATES the command here, the same way it
    # would strand `$RUFF check plugins` in a fresh shell under just.
    body="$(command awk '
        /^[[:space:]]*@if command -v ruff/ { grab = 1 }
        grab {
            line = $0
            sub(/^[[:space:]]*@?/, "", line)
            cont = (line ~ /\\$/)
            sub(/[[:space:]]*\\$/, "", line)
            out = (out == "" ? line : out " " line)
            if (!cont) { print out; exit }
        }
    ' "$jf")"
    assert_not_empty "$body" "recipe body extracted (the anchors still match)"
    # The extraction must have reached the invocation. If a backslash went
    # missing upstream the command truncates before this, and asserting on it
    # here is what turns that into a failure rather than a silent pass.
    assert_contains "$body" '$RUFF check plugins' \
        "the resolution and its invocation are ONE logical line (no broken continuation)"

    # Replace the real lint invocations with an echo so the case asserts on
    # RESOLUTION, not on ruff's verdict over plugins/.
    local probe="${body//\$RUFF check plugins \&\& \$RUFF format --check plugins/echo \"RESOLVED=\$RUFF\"}"

    # Same env scrubbing as run_gate: BASH_ENV must be unset or the
    # devcontainer's /etc/bash_env resets PATH and the REAL ruff outranks the
    # stub, silently invalidating the case.
    local sb out
    stub_dir sb || return 1

    # `timeout` and `sleep` are NOT in stub_dir's symlink list, and without them
    # the recipe's `command -v timeout` fails and every case below silently takes
    # the UNBOUNDED else-branch — the bounded path this test exists to cover
    # would never execute. Plant them, as test_hanging_uvx_is_bounded_not_wedged
    # already does for the same reason.
    command ln -sf "$(command -v timeout)" "$sb/bin/timeout" 2>/dev/null || true
    command ln -sf "$(command -v sleep)" "$sb/bin/sleep" 2>/dev/null || true

    # ruff absent, uvx present and probing OK -> must resolve to "uvx ruff".
    plant_runner "$sb" uvx 0 0
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" "$REAL_SH" -c "$probe" 2>&1 || true)"
    assert_contains "$out" 'RESOLVED=uvx ruff' \
        "the real recipe body parses and resolves to uvx when ruff is absent"

    # ruff present -> must win over uvx.
    plant_runner "$sb" ruff 0 0
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" "$REAL_SH" -c "$probe" 2>&1 || true)"
    assert_contains "$out" 'RESOLVED=ruff' \
        "the real recipe body prefers a ruff binary over uvx"

    # Neither runner -> must take the skip branch and say so.
    command rm -f "$sb/bin/ruff" "$sb/bin/uvx"
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" "$REAL_SH" -c "$probe" 2>&1 || true)"
    assert_contains "$out" 'did NOT run' \
        "the real recipe body takes the skip branch when no runner resolves"
}

# The bound's whole purpose, exercised end to end. The presence grep for
# UVX_PROBE_TIMEOUT proves only that the token appears somewhere in the file — a
# regression that dropped the `timeout "${UVX_PROBE_TIMEOUT:-60}" ` wrapper while
# leaving the name in a comment would still pass it. This drives a uvx that never
# returns and asserts the recipe body gives up and degrades to the skip branch,
# mirroring test_hanging_uvx_is_bounded_not_wedged's coverage of lint-python.sh.
test_justfile_hanging_uvx_is_bounded() {
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout(1) unavailable — cannot bound the hang case"
        return 0
    fi

    local jf="$REPO_ROOT/justfile" body
    body="$(command awk '
        /^[[:space:]]*@if command -v ruff/ { grab = 1 }
        grab {
            line = $0
            sub(/^[[:space:]]*@?/, "", line)
            cont = (line ~ /\\$/)
            sub(/[[:space:]]*\\$/, "", line)
            out = (out == "" ? line : out " " line)
            if (!cont) { print out; exit }
        }
    ' "$jf")"
    assert_not_empty "$body" "recipe body extracted for the hang case"
    local probe="${body//\$RUFF check plugins \&\& \$RUFF format --check plugins/echo \"RESOLVED=\$RUFF\"}"

    local sb
    stub_dir sb || return 1
    command ln -sf "$(command -v timeout)" "$sb/bin/timeout" 2>/dev/null || true
    command ln -sf "$(command -v sleep)" "$sb/bin/sleep" 2>/dev/null || true

    # A uvx whose --version probe never returns.
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'for a in "$@"; do\n'
        command printf '    if [ "$a" = "--version" ]; then sleep 3600; fi\n'
        command printf 'done\n'
        command printf 'exit 0\n'
    } >"$sb/bin/uvx"
    command chmod +x "$sb/bin/uvx"

    # Outer bound well above the inner one: if the recipe honors
    # UVX_PROBE_TIMEOUT it returns on its own and the outer never fires. Exit
    # 124 = outer fired = the recipe wedged, which is the regression.
    local rc=0 out
    out="$(command timeout 30 /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV HOME="$sb" PATH="$sb/bin" UVX_PROBE_TIMEOUT=2 \
        "$REAL_SH" -c "$probe" 2>&1)" || rc=$?

    assert_true "[ \"$rc\" -ne 124 ]" \
        "a hanging uvx does not wedge the recipe (outer timeout did not fire)"
    assert_contains "$out" 'did NOT run' \
        "a hanging uvx degrades to the skip branch rather than blocking forever"
}

run_test test_prefers_ruff_binary_when_present "ruff on PATH is preferred and actually invoked"
run_test test_ruff_violation_fails_the_gate "a violation via the ruff binary fails the gate"
run_test test_falls_back_to_uvx_when_ruff_absent "falls back to probed uvx when ruff is absent"
run_test test_uvx_violation_fails_the_gate "a violation via uvx fails the gate"
run_test test_unusable_uvx_skips_rather_than_fails "an unusable uvx skips rather than hard-failing"
run_test test_hanging_uvx_is_bounded_not_wedged "a hanging uvx is bounded, not left to wedge the suite"
run_test test_no_runner_exits_skip_sentinel "no runner available exits the 77 skip sentinel"
run_test test_skip_message_says_it_did_not_run "the skip message says the gate did not run"
run_test test_run_stage_renders_skip_not_ok "run_stage renders a 77 stage as [SKIP], not [ok]"
run_test test_run_stage_skip_does_not_fail_suite "a skipped stage does not fail the suite"
run_test test_run_stage_still_renders_pass_and_fail "pass/fail rendering is undisturbed"
run_test test_sentinel_constant_agreed_by_both_scripts "the skip sentinel agrees across both scripts"
run_test test_post_create_ensures_ruff "post-create.sh installs and verifies ruff"
run_test test_justfile_shares_ruff_resolution "just lint shares the ruff→uvx runner resolution (#544)"
run_test test_justfile_recipe_body_executes "the just lint recipe body actually parses and resolves (#544)"
run_test test_justfile_hanging_uvx_is_bounded "a hanging uvx does not wedge just lint (#544)"

generate_report
