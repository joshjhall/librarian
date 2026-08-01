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
LINT_SHELLCHECK="$SCRIPT_DIR/lint-shellcheck.sh"
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
    # `awk` is load-bearing for the #542 pin: both entry points resolve the
    # version by running bin/ruff-version.sh, which parses ruff.toml with awk.
    # Absent, the reader dies inside the stub PATH and every case below would
    # fail for a reason that has nothing to do with what it tests — the same trap
    # class as the `timeout` symlink #544's review caught.
    for tool in bash env find sort cat printf locale grep mktemp rm dirname basename tr awk; do
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
    local sb pin
    stub_dir sb || return 1
    plant_runner "$sb" uvx 0 0 # probe succeeds, lint clean; no ruff planted
    run_gate "$sb"
    # The fallback resolves the PINNED ruff (#542), so every expectation below
    # carries the version. Read it rather than hardcoding it, or bumping the pin
    # would mean editing this file too.
    pin="$(command bash "$REPO_ROOT/bin/ruff-version.sh")"

    assert_equals "0" "$GATE_RC" "gate runs (not skips) via uvx when ruff is absent"
    assert_contains "$GATE_LOG" "uvx ruff@$pin --version" "the uvx availability probe runs, pinned"
    assert_contains "$GATE_LOG" "uvx ruff@$pin check plugins" "check is dispatched through the pinned uvx"
    assert_contains "$GATE_LOG" "uvx ruff@$pin format --check plugins" "format is dispatched through the pinned uvx"
    assert_contains "$GATE_OUT" "Runner: uvx ruff@$pin" "the uvx runner is announced with its pin"
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
    assert_contains "$GATE_LOG" "uvx ruff@$(command bash "$REPO_ROOT/bin/ruff-version.sh") --version" \
        "the probe was actually attempted"
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

test_sentinel_constant_agreed_by_every_script() {
    assert_file_contains "$LINT_PYTHON" "SKIP_EXIT_CODE=$SKIP_SENTINEL" \
        "lint-python.sh defines the shared skip sentinel"
    assert_file_contains "$LINT_SHELLCHECK" "SKIP_EXIT_CODE=$SKIP_SENTINEL" \
        "lint-shellcheck.sh defines the same skip sentinel (#571)"
    assert_file_contains "$RUN_ALL" "SKIP_EXIT_CODE=$SKIP_SENTINEL" \
        "run-all.sh defines the same skip sentinel"
}

# --- The shell gate's own skip path (#571) -----------------------------------
#
# lint-shellcheck.sh used to `exit 0` when shellcheck was absent, so run-all.sh
# rendered `[ok] Shellcheck (bundled shell scripts)` — byte-identical to a real
# pass — for a gate that never ran. Same inert-gate defect #538 fixed for the
# Python gate; CI installs shellcheck, so it was a local-host reporting hole
# that no CI run could catch.
#
# The constant check above is grep-level and would still pass if the exit path
# were wrong. This runs the REAL gate under a PATH with no shellcheck and pins
# the observable contract: rc 77, and a message that says it did not run.
test_shellcheck_gate_skips_with_sentinel() {
    local sb out rc=0
    stub_dir sb || return 1 # no shellcheck planted

    out="$(/usr/bin/env --unset=BASH_ENV "${GIT_SCRUB[@]/#/--unset=}" \
        PATH="$sb/bin" "$REAL_BASH" "$LINT_SHELLCHECK" 2>&1)" || rc=$?

    assert_equals "$SKIP_SENTINEL" "$rc" \
        "an absent shellcheck exits the reserved skip sentinel, not 0 (#571)"
    assert_contains "$out" "GATE DID NOT RUN" \
        "the skip message states the gate did not run (#571)"
    assert_true "! printf '%s' \"$out\" | command grep -q 'Failed:  [1-9]'" \
        "a skip is not reported as a failure (#571)"
}

# The other half of the contract: with shellcheck present the gate must actually
# run and lint something. Without this, deleting the corpus entirely would still
# satisfy the skip test above — the gate would be inert in a new way.
test_shellcheck_gate_runs_when_available() {
    local out rc=0
    command -v shellcheck >/dev/null 2>&1 || {
        skip_test "shellcheck not installed — cannot exercise the ran-for-real arm"
        return 0
    }

    out="$(/usr/bin/env --unset=BASH_ENV "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$LINT_SHELLCHECK" 2>&1)" || rc=$?

    assert_equals "0" "$rc" "the gate passes on this repo's scripts"
    assert_true "! printf '%s' \"$out\" | command grep -q 'GATE DID NOT RUN'" \
        "a real run does not report itself as skipped"
    assert_true "printf '%s' \"$out\" | command grep -qE 'Passed:  [1-9]'" \
        "the gate actually linted something (corpus is non-empty)"
}

# post-create.sh is the "suspenders" half of the fix — a fresh container must end
# up with a real ruff, and must fail loudly rather than proceed without one.
test_post_create_ensures_ruff() {
    local pc="$REPO_ROOT/.devcontainer/post-create.sh"
    assert_file_exists "$pc" "post-create.sh exists"
    # The version is pinned (#542) — test_every_install_path_reads_the_pin owns
    # the exact pinned spelling; here the point is only that both installers are
    # still wired up.
    assert_file_contains "$pc" "uv tool install" "installs ruff via uv when available"
    assert_file_contains "$pc" "pipx install" "falls back to pipx"
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
    assert_file_contains "$jf" 'uvx "ruff@$RUFF_PIN" --version' \
        "just lint PROBES uvx before selecting it (an unprobed uvx hard-fails when offline)"
    assert_file_contains "$jf" 'RUFF="uvx ruff@$RUFF_PIN"' \
        "just lint falls back to the pinned uvx ruff"
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

# extract_lint_recipe_body — the justfile `lint` recipe's ruff-resolution
# command, as ONE logical line, exactly as just would assemble it.
#
# It must replicate just's LINE MODEL, not just concatenate the text. just feeds
# each recipe line to its own shell, and a trailing `\` is what makes several
# source lines one logical command. So this JOINS ONLY ON `\`: a line without one
# ends the command, exactly as just would treat it. Getting this wrong makes the
# callers vacuous — an earlier revision emitted the raw lines and let `sh` re-join
# them, which still ran fine with a backslash deleted and so passed against a
# justfile that `just` itself would have broken on.
#
# The anchor is the recipe's FIRST line (`@RUFF_PIN=`, since #542 put the pin
# resolution ahead of the resolution chain). Shared by both behavioural cases so
# the anchor lives in one place: duplicated, a future edit that moves it would be
# fixed in one copy and silently blind the other.
#
# Extracting rather than duplicating the snippet is the point: a hand-copied
# expectation would drift from the justfile and pass while the real recipe broke.
extract_lint_recipe_body() {
    command awk '
        /^[[:space:]]*@RUFF_PIN=/ { grab = 1 }
        grab {
            line = $0
            sub(/^[[:space:]]*@?/, "", line)
            cont = (line ~ /\\$/)
            sub(/[[:space:]]*\\$/, "", line)
            out = (out == "" ? line : out " " line)
            if (!cont) { print out; exit }
        }
    ' "$REPO_ROOT/justfile"
}

# Behavioural half of the pair: run the extracted recipe body under a stub PATH.
# Needs neither `just` installed nor the recipe's dprint/taplo/rumdl/node steps.
test_justfile_recipe_body_executes() {
    local body
    body="$(extract_lint_recipe_body)"
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

    # The recipe reads the pin with a path RELATIVE to the justfile
    # (`bash bin/ruff-version.sh`), which is correct under just — it runs recipes
    # from the justfile's directory. Reproduce that by running from REPO_ROOT, or
    # the reader would not resolve and every case below would fail for the wrong
    # reason.
    local pin
    pin="$(command bash "$REPO_ROOT/bin/ruff-version.sh")"

    # ruff absent, uvx present and probing OK -> must resolve to the PINNED uvx.
    plant_runner "$sb" uvx 0 0
    out="$(cd "$REPO_ROOT" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" "$REAL_SH" -c "$probe" 2>&1 || true)"
    assert_contains "$out" "RESOLVED=uvx ruff@$pin" \
        "the real recipe body parses and resolves to the PINNED uvx when ruff is absent (#542)"
    # The probe must ask uvx for the pinned ruff too — probing a floating `ruff`
    # and then dispatching `ruff@<v>` would validate a different package than the
    # one it goes on to run.
    assert_contains "$(command cat "$sb/calls.log" 2>/dev/null)" "uvx ruff@$pin --version" \
        "the uvx probe itself is pinned, not just the dispatch (#542)"

    # ruff present -> must win over uvx.
    plant_runner "$sb" ruff 0 0
    out="$(cd "$REPO_ROOT" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" "$REAL_SH" -c "$probe" 2>&1 || true)"
    assert_contains "$out" 'RESOLVED=ruff' \
        "the real recipe body prefers a ruff binary over uvx"

    # Neither runner -> must take the skip branch and say so.
    command rm -f "$sb/bin/ruff" "$sb/bin/uvx"
    out="$(cd "$REPO_ROOT" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
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

    local body
    body="$(extract_lint_recipe_body)"
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
    # cd to REPO_ROOT for the same reason as the case above: the recipe reads the
    # pin via a justfile-relative `bash bin/ruff-version.sh`, and just runs
    # recipes from the justfile's directory.
    local rc=0 out
    out="$(cd "$REPO_ROOT" && command timeout 30 /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV HOME="$sb" PATH="$sb/bin" UVX_PROBE_TIMEOUT=2 \
        "$REAL_SH" -c "$probe" 2>&1)" || rc=$?

    assert_true "[ \"$rc\" -ne 124 ]" \
        "a hanging uvx does not wedge the recipe (outer timeout did not fire)"
    assert_contains "$out" 'did NOT run' \
        "a hanging uvx degrades to the skip branch rather than blocking forever"
}

# --- #542: one pinned ruff version, threaded through every install path -------
#
# Before this, five paths each resolved ruff independently and unpinned
# (post-create, ci.yml, release.yml, lint-python.sh's uvx fallback, the justfile's
# uvx fallback), so a new ruff release could fail `ruff format --check` with no
# code change behind it. ruff.toml's top-level `required-version` is now the
# single source; bin/ruff-version.sh is the single reader.
#
# The pin is only real while ALL of them read it: `required-version` makes ruff
# refuse to run on a mismatch, so one path left floating does not drift quietly —
# it hard-fails the first time ruff publishes a new release. Hence one assertion
# per path below, so dropping any single one fails this gate.

# is_bare_semver <string> — echoes "yes" when the argument is exactly X.Y.Z.
#
# A helper rather than an inline `grep -qE` inside assert_true, because that
# assertion EVALS the command string it is handed: interpolating a captured value
# into it turns quotes and newlines in that value into shell syntax. In the worst
# case the mangled command loses its input and blocks on stdin, which hangs the
# whole suite instead of failing one case.
is_bare_semver() {
    case "$1" in
        *[!0-9.]* | '' | *..* | .* | *.) command printf 'no' ;;
        *.*.*.*) command printf 'no' ;;
        *.*.*) command printf 'yes' ;;
        *) command printf 'no' ;;
    esac
}

# The pin must be TOP-LEVEL. Under [format] ruff rejects it as an unknown field —
# a placement regression would leave the file *looking* pinned while ruff ignored
# it. Asserted by parsing scope, not by grepping the whole file.
test_ruff_toml_pins_version_at_top_level() {
    local rt="$REPO_ROOT/ruff.toml" hits
    assert_file_exists "$rt" "ruff.toml exists"
    # Count exact pins in the top-level scope only — everything before the first
    # [table] header. Counted into a scalar rather than piped inside assert_true:
    # that assertion EVALS its argument, so interpolating file content (multi-line,
    # full of quotes) into it mangles the command and hangs on stdin.
    hits="$(command awk '
        /^[[:space:]]*\[/ { exit }
        /^required-version[[:space:]]*=[[:space:]]*"==[0-9]+\.[0-9]+\.[0-9]+"/ { n++ }
        END { print n + 0 }
    ' "$rt")"
    assert_equals "1" "$hits" \
        "ruff.toml pins exactly one ==X.Y.Z required-version at the TOP level (under [format] ruff ignores it)"
}

# The reader is what keeps the five consumers from each growing their own parse.
# Behavioural, not a grep: it must print the version the file actually carries.
test_ruff_version_reader_prints_the_pin() {
    local reader="$REPO_ROOT/bin/ruff-version.sh" out declared
    assert_file_exists "$reader" "bin/ruff-version.sh exists"

    out="$(command bash "$reader" 2>&1)"
    declared="$(command awk '
        /^[[:space:]]*\[/ { exit }
        /^required-version/ { gsub(/^[^"]*"==|".*$/, "", $0); print; exit }
    ' "$REPO_ROOT/ruff.toml")"
    assert_equals "$declared" "$out" "the reader prints exactly the version ruff.toml declares"
    # Shape checks go through a computed yes/no rather than an interpolated
    # pipeline: assert_true EVALS its argument, so any value with quotes or
    # newlines in it would mangle the command instead of failing the assertion.
    assert_equals "yes" "$(is_bare_semver "$out")" \
        "the reader prints a BARE version (no '==' prefix) — the shape pipx/uvx want"
}

# Fail-loud, per CLAUDE.md's runtime policy. A reader that printed nothing on a
# missing pin would silently degrade every caller back to installing a floating
# ruff — reintroducing the exact bug, while every consumer's grep still passed.
test_ruff_version_reader_fails_loud_on_a_bad_pin() {
    local reader="$REPO_ROOT/bin/ruff-version.sh" fixture rc out

    # No pin at all.
    fixture="$WORKDIR/nopin.toml"
    command printf 'target-version = "py311"\n' >"$fixture"
    rc=0
    out="$(command bash "$reader" "$fixture" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "a ruff.toml with no pin exits non-zero"
    assert_contains "$out" "required-version" "the error names what is missing"
    assert_equals "no" "$(is_bare_semver "$out")" \
        "nothing version-shaped is printed for a missing pin"

    # A RANGE, not an exact pin — accepting it would let the paths drift again.
    fixture="$WORKDIR/range.toml"
    command printf 'required-version = ">=0.16.0"\n' >"$fixture"
    rc=0
    command bash "$reader" "$fixture" >/dev/null 2>&1 || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "a range instead of an exact ==X.Y.Z pin exits non-zero"

    # Pinned, but nested under a [table] — ruff ignores it there, so the reader
    # must NOT report it as the effective pin.
    fixture="$WORKDIR/nested.toml"
    command printf '[format]\nrequired-version = "==1.2.3"\n' >"$fixture"
    rc=0
    out="$(command bash "$reader" "$fixture" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "a pin nested under a [table] is not accepted (ruff ignores it there)"
    assert_not_contains "$out" "1.2.3" \
        "the nested version is not reported as the effective pin"
}

# One assertion per install path. These are content assertions on purpose: the
# workflows and post-create only run in CI / on container create, so there is no
# way to execute them here — what IS checkable is that none of them still names a
# floating `ruff`.
test_every_install_path_reads_the_pin() {
    local pc="$REPO_ROOT/.devcontainer/post-create.sh"
    local ci="$REPO_ROOT/.github/workflows/ci.yml"
    local rel="$REPO_ROOT/.github/workflows/release.yml"
    local lp="$SCRIPT_DIR/lint-python.sh"
    local jf="$REPO_ROOT/justfile"

    assert_file_contains "$pc" "bin/ruff-version.sh" \
        "post-create.sh resolves the pin through the shared reader"
    assert_file_contains "$pc" 'uv tool install --force "ruff==$RUFF_VERSION"' \
        "post-create.sh's uv install is pinned"
    assert_file_contains "$pc" 'pipx install --force "ruff==$RUFF_VERSION"' \
        "post-create.sh's pipx install is pinned"

    # Both workflows resolve the pin on its own line with an explicit `|| exit 1`
    # rather than inline as `pipx install "ruff==$(...)"`. That is load-bearing:
    # a failing command substitution inside a larger command does NOT abort under
    # `set -e`, so the inline form would degrade to `ruff==` and fail as a pipx
    # argument error instead of surfacing ruff-version.sh's own diagnostic.
    local w
    for w in "$ci" "$rel"; do
        assert_file_contains "$w" 'ruff_version="$(bash bin/ruff-version.sh)" || exit 1' \
            "$(command basename "$w") resolves the pin with an explicit failure check"
        assert_file_contains "$w" 'pipx install "ruff==$ruff_version"' \
            "$(command basename "$w") installs the resolved pin"
    done

    assert_file_contains "$lp" 'bin/ruff-version.sh' \
        "lint-python.sh resolves the pin through the shared reader"
    assert_file_contains "$lp" 'uvx "ruff@$RUFF_PIN"' \
        "lint-python.sh's uvx fallback is pinned"

    assert_file_contains "$jf" 'bash bin/ruff-version.sh' \
        "the justfile resolves the pin through the shared reader"
    assert_file_contains "$jf" 'uvx "ruff@$RUFF_PIN"' \
        "the justfile's uvx probe is pinned"

    # The inverse: no path may still install a FLOATING ruff. Every grep above
    # would still pass if a pinned line were ADDED beside an unpinned one, so
    # match install lines whose ruff argument carries no version and count them.
    local f floating
    for f in "$pc" "$ci" "$rel"; do
        floating="$(command grep -cE '(pipx|uv tool) install ([^ ]+ )*"?ruff"?[[:space:]]*$' "$f" || true)"
        # grep -c prints 0 but EXITS 1 on a zero count; the `|| true` above keeps
        # set -e from taking that as a failure, and the count is still on stdout.
        assert_equals "0" "$floating" \
            "$(command basename "$f") has no leftover unpinned ruff install"
    done
}

# The pin's ENFORCEMENT leg, exercised against the real binary. required-version
# is not merely a declaration: ruff refuses to run when the running version
# disagrees, which is what covers the paths with no install step to pin
# (lefthook.yml's bare `ruff format`/`ruff check` on staged files, and anyone
# running ruff by hand). If a future ruff dropped or softened that behaviour, the
# pin would silently become documentation — this is what would catch it.
test_required_version_mismatch_actually_blocks_ruff() {
    if ! command -v ruff >/dev/null 2>&1; then
        skip_test "no ruff binary on PATH — cannot exercise the enforcement leg"
        return 0
    fi

    local fixture="$WORKDIR/mismatch.toml" py="$WORKDIR/sample.py" rc out
    # A version ruff will never be running.
    command printf 'required-version = "==0.0.1"\n' >"$fixture"
    command printf 'x = 1\n' >"$py"

    rc=0
    out="$(command ruff check --config "$fixture" "$py" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "ruff check REFUSES to run against a mismatched required-version"
    assert_contains "$out" "Required version" "the refusal names the version mismatch"

    rc=0
    command ruff format --check --config "$fixture" "$py" >/dev/null 2>&1 || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "ruff format --check is blocked by the same mismatch"
}

# post-create.sh's install DECISION, driven behaviourally.
#
# Every other assertion about post-create.sh in this file is a substring grep,
# because the script itself only runs on a real container create. That left its
# actual branching — already-pinned skip, reinstall-on-mismatch via uv vs pipx,
# the mismatch-with-no-installer error, and the no-installer error — with no
# coverage at all: a broken comparison or a typo in the version substitution
# would first surface inside a devcontainer build. The decision is now a pure
# function (`ruff_install_action`), so it can be sliced out and driven directly,
# the same way render_stage slices run-all.sh's run_stage.
#
# Slicing rather than reimplementing is the point: a hand-copied version of the
# branching would drift from the script and keep passing while the real one broke.
# run_install_action <current> <pinned> <has_uv> <has_pipx>
run_install_action() {
    /usr/bin/env --unset=BASH_ENV "$REAL_BASH" -c '
        eval "$(command sed -n "/^ruff_install_action() {/,/^}/p" "$1")"
        ruff_install_action "$2" "$3" "$4" "$5"
    ' _ "$REPO_ROOT/.devcontainer/post-create.sh" "$1" "$2" "$3" "$4" 2>&1
}

test_post_create_install_decision() {
    local pin="0.16.0"

    # Already at the pin: no install, regardless of what is available.
    assert_equals "skip" "$(run_install_action "$pin" "$pin" yes yes)" \
        "an on-PATH ruff at the pinned version installs nothing"
    assert_equals "skip" "$(run_install_action "$pin" "$pin" no no)" \
        "…and still skips when no installer is present (nothing to correct)"

    # THE bug this branch exists to fix: a ruff already on PATH at the WRONG
    # version must be REINSTALLED, not accepted. Accepting it would leave the
    # container with a ruff that hard-fails every lint on required-version.
    assert_equals "uv" "$(run_install_action "0.9.9" "$pin" yes yes)" \
        "a MISMATCHED on-PATH ruff is reinstalled, not accepted (uv preferred)"
    assert_equals "pipx" "$(run_install_action "0.9.9" "$pin" no yes)" \
        "…falling back to pipx when uv is absent"

    # Absent ruff: install by whichever manager exists, uv first.
    assert_equals "uv" "$(run_install_action "" "$pin" yes yes)" \
        "an absent ruff installs via uv when available"
    assert_equals "pipx" "$(run_install_action "" "$pin" no yes)" \
        "…and via pipx when uv is absent"

    # The two error arms are DISTINCT on purpose — one says "cannot install",
    # the other "ruff exists but is unusable against this pin". Collapsing them
    # would send an operator to the wrong fix.
    assert_equals "error-mismatch" "$(run_install_action "0.9.9" "$pin" no no)" \
        "a mismatched ruff with no installer is its own error, not 'cannot install'"
    assert_equals "error-no-installer" "$(run_install_action "" "$pin" no no)" \
        "no ruff and no installer is the cannot-install error"
}

# The dispatch must handle each of the five outcomes EXPLICITLY, with the
# wildcard reserved for an internal-contract violation.
#
# A `*)` that doubles as the error-no-installer arm looks harmless — the helper
# only ever echoes five strings today — but it converts a future misspelling of
# an outcome name in the helper into the "install uv or pipx" message, which is
# actively wrong advice when uv is present and the real fault is a bug in the
# script. Asserted structurally: every outcome name the helper can echo must
# appear as its own case label.
#
# (The illustrative misspelling that was here is gone on purpose: `typos` gates
# the pre-push hook and flags it inside a comment, which is the gate working
# correctly — describe the mistake, don't spell it.)
test_post_create_dispatch_handles_every_outcome() {
    local pc="$REPO_ROOT/.devcontainer/post-create.sh" outcome outcomes
    # Read the outcome names out of the HELPER rather than hardcoding them, so a
    # newly added outcome is picked up here automatically instead of silently
    # falling through to the wildcard.
    #
    # Unquoted on purpose below: the awk output is a newline-separated list of
    # `[a-z-]+` tokens (the regex admits nothing else), and word-splitting it into
    # the loop is the intent.
    outcomes="$(command awk '
        /^ruff_install_action\(\) \{/ { grab = 1; next }
        grab && /^\}/ { exit }
        grab && match($0, /echo "[a-z-]+"/) {
            s = substr($0, RSTART + 6, RLENGTH - 7)
            print s
        }
    ' "$pc")"

    # NON-VACUITY FLOOR. If the helper is renamed, or its body reshaped so the
    # awk anchor stops matching, the extraction yields NOTHING — and a for-loop
    # over nothing asserts nothing while still reporting PASS. That failure mode
    # is the whole reason this case exists, so pin the count: 5 documented
    # outcomes today, and a 6th must arrive with a deliberate bump here.
    assert_equals "5" "$(command printf '%s\n' "$outcomes" | command grep -c '[a-z]')" \
        "all 5 helper outcomes were extracted (a broken anchor would silently assert nothing)"

    # shellcheck disable=SC2086 # deliberate word-split, see comment above
    for outcome in $outcomes; do
        assert_file_contains "$pc" "    $outcome)" \
            "the dispatch handles '$outcome' explicitly, not via the wildcard"
    done
    # And the wildcard must be an internal-error arm, not a duplicate of a real
    # outcome's message.
    assert_file_contains "$pc" "ERROR: internal — ruff_install_action returned" \
        "the wildcard reports an internal-contract violation"
}

# The dispatch's ARM BODIES, executed for real.
#
# The two cases above cover the pure helper's verdicts and the presence of each
# case LABEL, but both are blind to what an arm actually does: swap the `uv)` and
# `pipx)` bodies and every label is still present, in order, so they both pass —
# while the script installs through the wrong manager. That is the same
# wrong-tool-for-the-condition class #542 exists to close, so the arms get driven
# for real: slice out the `ruff_action=…` + `case … esac` block, stub `uv`/`pipx`
# to log their argv, and assert on WHICH installer ran and with what.
#
# `ruff_install_action` is sliced in alongside it — the block calls it, and the
# point is to exercise the real dispatch against the real helper rather than a
# stand-in that could disagree with either.
run_dispatch() {
    local sb="$1" cur="$2" pin="$3" uv="$4" pipx="$5"
    command rm -f "$sb/install.log"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" \
        current_ruff="$cur" RUFF_VERSION="$pin" have_uv="$uv" have_pipx="$pipx" \
        "$REAL_BASH" -c '
        eval "$(command awk "/^ruff_install_action\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(command awk "/^ruff_action=/,/^esac/" "$1")"
    ' _ "$REPO_ROOT/.devcontainer/post-create.sh" 2>&1
}

test_post_create_dispatch_arms_run_the_right_installer() {
    local sb out pin="0.16.0"
    stub_dir sb || return 1
    # Stubs that record their own argv. `--force` and the pinned spec are part of
    # what is asserted: a reinstall that dropped --force would silently no-op
    # against an existing wrong-version install.
    local t
    for t in uv pipx; do
        {
            command printf '#!/usr/bin/env bash\n'
            command printf 'command printf "%s %%s\\n" "$*" >>"%s/install.log"\n' "$t" "$sb"
        } >"$sb/bin/$t"
        command chmod +x "$sb/bin/$t"
    done

    # uv available -> uv, with --force and the pinned spec.
    run_dispatch "$sb" "" "$pin" yes yes >/dev/null
    out="$(command cat "$sb/install.log" 2>/dev/null || true)"
    assert_equals "uv tool install --force ruff==$pin" "$out" \
        "the uv arm installs through uv, pinned and forced (not pipx)"

    # uv absent -> pipx. This is the pair a body-swap would break.
    run_dispatch "$sb" "" "$pin" no yes >/dev/null
    out="$(command cat "$sb/install.log" 2>/dev/null || true)"
    assert_equals "pipx install --force ruff==$pin" "$out" \
        "the pipx arm installs through pipx, pinned and forced (not uv)"

    # A mismatched on-PATH ruff must still REINSTALL, not skip.
    run_dispatch "$sb" "0.9.9" "$pin" yes yes >/dev/null
    out="$(command cat "$sb/install.log" 2>/dev/null || true)"
    assert_equals "uv tool install --force ruff==$pin" "$out" \
        "a mismatched ruff is reinstalled at the pin, not accepted"

    # Already pinned -> NOTHING runs. An arm that installed anyway would be a
    # silent waste on every container create, invisible to a label check.
    run_dispatch "$sb" "$pin" "$pin" yes yes >/dev/null
    assert_equals "" "$(command cat "$sb/install.log" 2>/dev/null || true)" \
        "the skip arm runs no installer at all"

    # Both error arms: no install attempted, and the message must match the
    # CONDITION — the mismatch arm must not tell an operator to install a tool.
    out="$(run_dispatch "$sb" "0.9.9" "$pin" no no)"
    assert_equals "" "$(command cat "$sb/install.log" 2>/dev/null || true)" \
        "the mismatch error arm attempts no install"
    assert_contains "$out" "neither uv nor pipx is available to correct it" \
        "the mismatch error names the real problem"

    out="$(run_dispatch "$sb" "" "$pin" no no)"
    assert_contains "$out" "cannot install ruff" \
        "the no-installer error arm says what is missing"
}

# installed_ruff_version must VALIDATE the shape it parses, not just take field
# two. It feeds both the reinstall decision above and the post-install
# verification, so a malformed read that silently compared equal to itself would
# report the pin as landed when it had not.
test_post_create_version_parse_is_validated() {
    local sb out
    stub_dir sb || return 1

    plant_version_stub() {
        {
            command printf '#!/usr/bin/env bash\n'
            command printf 'command cat <<'"'"'VEOF'"'"'\n%s\nVEOF\n' "$1"
        } >"$sb/bin/ruff"
        command chmod +x "$sb/bin/ruff"
    }

    # Sliced with awk, not sed: this runs with the stub dir as the ENTIRE PATH,
    # and that list carries only what the code under test genuinely needs (awk,
    # for bin/ruff-version.sh). Reaching for sed here would mean adding it to the
    # stub list purely for the test's own convenience, which is how that list
    # grew an inaccurate "load-bearing" claim in the first place.
    run_parse() {
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin" "$REAL_BASH" -c '
            eval "$(command awk "/^installed_ruff_version\\(\\) \\{/,/^\\}/" "$1")"
            installed_ruff_version || true
        ' _ "$REPO_ROOT/.devcontainer/post-create.sh" 2>&1
    }

    plant_version_stub 'ruff 0.16.0'
    assert_equals "0.16.0" "$(run_parse)" "the normal 'ruff X.Y.Z' output parses"

    # A leading warning line: field two of line ONE is not the version.
    plant_version_stub 'warning: something
ruff 0.16.0'
    assert_equals "0.16.0" "$(run_parse)" \
        "a preceding warning line does not derail the parse"

    # Shapes that must yield NOTHING rather than a wrong string.
    plant_version_stub 'ruff 0.16.0+build7'
    assert_equals "" "$(run_parse)" "build metadata is rejected, not silently truncated"
    plant_version_stub 'someothertool 1.2.3'
    assert_equals "" "$(run_parse)" "a different tool's output is rejected"
    plant_version_stub 'ruff'
    assert_equals "" "$(run_parse)" "a missing version field yields nothing"

    command rm -f "$sb/bin/ruff"
    assert_equals "" "$(run_parse)" "an absent ruff yields nothing"
}

# The pinned version must be the one actually in use here, or the local suite is
# green against a ruff that CI would reject before it ran a single rule.
test_installed_ruff_matches_the_pin() {
    if ! command -v ruff >/dev/null 2>&1; then
        skip_test "no ruff binary on PATH — nothing to compare against the pin"
        return 0
    fi

    local pin running
    pin="$(command bash "$REPO_ROOT/bin/ruff-version.sh")"
    running="$(command ruff --version 2>/dev/null | command awk '{print $2}')"
    assert_equals "$pin" "$running" \
        "the ruff on PATH is the pinned version (a mismatch makes every lint hard-fail)"
}

# --- coverage-python.sh's coverage.py probe (#564) ---------------------------
#
# Same subject as the ruff gates above: a tool-absent gate must SKIP cleanly
# rather than misbehave. coverage-python.sh gated on a bare `import coverage`,
# which is not evidence coverage.py is installed — the script runs from the repo
# root, where `./coverage/` is the output directory coverage-mjs.sh writes
# lcov.info into, and PEP 420 makes any directory on sys.path an implicit
# NAMESPACE PACKAGE. So `import coverage` bound an empty build-output dir and
# succeeded with the library absent, the skip was bypassed, and the run hard-
# failed at `coverage xml` with a misleading message.
#
# Driven against a REPLACED sys.path, not merely a prepended PYTHONPATH. A real
# installed package always outranks a namespace package regardless of path order,
# so on a host that HAS coverage.py (CI does, and any host that ran
# `just coverage`) a PYTHONPATH-only fixture silently resolves the real library
# and the case tests nothing. Assigning `sys.path[:]` to the fixture dir alone
# makes the empty directory the ONLY candidate, so the case behaves identically
# whether or not coverage.py is installed. Verified both ways.
test_coverage_probe_rejects_a_namespace_package() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available — cannot exercise the import probe"
        return 0
    fi

    local sb rc_bare=0 rc_attr=0 path_stmt
    sb="$(command mktemp -d "$WORKDIR/nspkg.XXXXXX")" || return 1
    # An EMPTY directory named `coverage` — exactly what ./coverage/ is before
    # coverage-mjs.sh has written into it, and enough for PEP 420.
    command mkdir -p "$sb/coverage"
    path_stmt="import sys; sys.path[:] = ['$sb']; "

    # The OLD probe: importability alone. Against this path it SUCCEEDS, which is
    # precisely the bug — assert that, so the test states the hazard it guards.
    (command python3 -c "${path_stmt}import coverage" 2>/dev/null) || rc_bare=$?
    assert_equals "0" "$rc_bare" \
        "a bare 'import coverage' SUCCEEDS against an empty ./coverage/ dir (PEP 420 namespace package) — why importability is not a valid probe"

    # The NEW probe: touch a real attribute. A namespace package has none, so this
    # must fail and the gate skips as designed.
    (command python3 -c "${path_stmt}import coverage; coverage.Coverage" 2>/dev/null) || rc_attr=$?
    assert_true "[ \"$rc_attr\" -ne 0 ]" \
        "the attribute probe REJECTS the namespace package, so coverage-python.sh skips instead of failing at 'coverage xml'"

    # And the script itself must carry the attribute form, not the bare import —
    # otherwise the two assertions above pass while the real gate stays broken.
    assert_file_contains "$REPO_ROOT/tests/coverage-python.sh" \
        "import coverage; coverage.Coverage" \
        "coverage-python.sh probes a real attribute, not mere importability (#564)"
    assert_file_not_contains "$REPO_ROOT/tests/coverage-python.sh" \
        "python3 -c 'import coverage'" \
        "coverage-python.sh no longer gates on the bare import that the ./coverage/ dir satisfies"
}

# The script must also SKIP (exit 0, no report) rather than hard-fail when
# coverage.py is genuinely absent — the end-to-end behaviour the probe exists to
# produce. Run it with a stub PATH holding a python3 that reports 3.11 and fails
# every import, so the case is independent of the host's real python.
test_coverage_python_skips_when_coverage_absent() {
    local sb rc=0 out
    stub_dir sb || return 1

    command cat >"$sb/bin/python3" <<'STUB'
#!/usr/bin/env bash
# Version gate: report 3.11 so the script proceeds past it. Any other -c program
# (both the old bare import and the new attribute probe) fails, standing in for
# a host with no coverage.py.
case "$2" in
    *version_info*) exit 0 ;;
    *) exit 1 ;;
esac
STUB
    command chmod +x "$sb/bin/python3"

    out="$(cd "$REPO_ROOT" && command env --unset=BASH_ENV PATH="$sb/bin" \
        bash "$REPO_ROOT/tests/coverage-python.sh" 2>&1)" || rc=$?

    assert_equals "0" "$rc" \
        "coverage-python.sh EXITS 0 when coverage.py is absent (a skip, not a failure)"
    assert_contains "$out" "[skip] python-coverage" \
        "coverage-python.sh says it skipped, naming the missing dependency"
    assert_not_contains "$out" "coverage xml failed" \
        "coverage-python.sh never reaches the xml step when the probe correctly skips (#564)"
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
run_test test_sentinel_constant_agreed_by_every_script "the skip sentinel agrees across all three scripts (#571)"
run_test test_shellcheck_gate_skips_with_sentinel "an absent shellcheck exits 77, not 0 (#571)"
run_test test_shellcheck_gate_runs_when_available "the shell gate really runs when shellcheck is present (#571)"
run_test test_post_create_ensures_ruff "post-create.sh installs and verifies ruff"
run_test test_justfile_shares_ruff_resolution "just lint shares the ruff→uvx runner resolution (#544)"
run_test test_justfile_recipe_body_executes "the just lint recipe body actually parses and resolves (#544)"
run_test test_justfile_hanging_uvx_is_bounded "a hanging uvx does not wedge just lint (#544)"
run_test test_ruff_toml_pins_version_at_top_level "ruff.toml pins an exact ruff version at the top level (#542)"
run_test test_ruff_version_reader_prints_the_pin "bin/ruff-version.sh prints the declared pin (#542)"
run_test test_ruff_version_reader_fails_loud_on_a_bad_pin "the pin reader fails loud on a missing/ranged/nested pin (#542)"
run_test test_every_install_path_reads_the_pin "all five ruff install paths read the pin (#542)"
run_test test_required_version_mismatch_actually_blocks_ruff "required-version actually blocks a mismatched ruff (#542)"
run_test test_post_create_install_decision "post-create's install decision covers all five outcomes (#542)"
run_test test_post_create_dispatch_handles_every_outcome "post-create's dispatch handles every outcome explicitly (#542)"
run_test test_post_create_dispatch_arms_run_the_right_installer "post-create's dispatch arms run the right installer (#542)"
run_test test_post_create_version_parse_is_validated "post-create validates the ruff --version shape it parses (#542)"
run_test test_installed_ruff_matches_the_pin "the ruff on PATH matches the pin (#542)"
run_test test_coverage_probe_rejects_a_namespace_package "coverage-python.sh's probe rejects the ./coverage/ namespace package (#564)"
run_test test_coverage_python_skips_when_coverage_absent "coverage-python.sh skips (exit 0) when coverage.py is absent (#564)"

generate_report
