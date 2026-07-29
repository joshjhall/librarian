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
    # sed/awk/head are load-bearing for the #542 pin: both entry points resolve
    # the version by running bin/ruff-version.sh, which parses ruff.toml with
    # awk. Absent, the reader dies inside the stub PATH and every case below
    # would fail for a reason that has nothing to do with what it tests — the
    # same trap class as the `timeout` symlink #544's review caught.
    for tool in bash env find sort cat printf locale grep mktemp rm dirname basename tr sed awk head; do
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

    assert_file_contains "$ci" 'pipx install "ruff==$(bash bin/ruff-version.sh)"' \
        "ci.yml installs the pinned ruff"
    assert_file_contains "$rel" 'pipx install "ruff==$(bash bin/ruff-version.sh)"' \
        "release.yml installs the pinned ruff (the release gate must match the PR gate)"

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
run_test test_ruff_toml_pins_version_at_top_level "ruff.toml pins an exact ruff version at the top level (#542)"
run_test test_ruff_version_reader_prints_the_pin "bin/ruff-version.sh prints the declared pin (#542)"
run_test test_ruff_version_reader_fails_loud_on_a_bad_pin "the pin reader fails loud on a missing/ranged/nested pin (#542)"
run_test test_every_install_path_reads_the_pin "all five ruff install paths read the pin (#542)"
run_test test_required_version_mismatch_actually_blocks_ruff "required-version actually blocks a mismatched ruff (#542)"
run_test test_installed_ruff_matches_the_pin "the ruff on PATH matches the pin (#542)"

generate_report
