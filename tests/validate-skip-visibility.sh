#!/usr/bin/env bash
# Skip visibility + the broken-agnix-binary install branch (issue #741).
#
# TWO GAPS, one root cause: a gate that stopped running looks exactly like a
# gate that keeps passing.
#
#   1. THE UNEXERCISED BRANCH. #734 made ci.yml's agnix install non-fatal and
#      folded the `agnix --version` smoke-test INTO the `if` condition, so an
#      install that succeeds while producing an unusable binary (broken
#      postinstall, incompatible Node, a crash on invocation) routes to
#      notice-and-skip instead of aborting the step under `bash -e`. That is the
#      LIKELIER half of the failure space — a registry outage is caught by the
#      outer `if`, a bad install is not — and nothing exercised it.
#      tests/lint-agnix-clean.sh covers agnix ABSENT (77) and agnix WORKING;
#      tests/validate-agnix-helpers.sh covers the gate's pure helpers. The
#      workflow step itself had no coverage at all, so a future edit hoisting
#      `agnix --version` back into the `then` branch would restore the exact
#      job-failing regression #734 removed, silently.
#
#   2. THE INVISIBLE SKIP. When the gate persistently skips — no agnix on the
#      host, or precisely this broken-binary case — the only trace is a
#      `::notice::` and a `[SKIP]` line inside job-log output nobody scrolls on
#      a green run. run_stage's 77 rendering (#538/#571) stopped the gate lying
#      to a reader OF THE LOG; it does nothing for the reader of the run page.
#      Both halves now write to $GITHUB_STEP_SUMMARY, and both are asserted here.
#
# WHY THE WORKFLOW BODY IS SLICED, NOT COPIED. A `run:` block only executes on a
# real GitHub runner, so the tempting shape is a grep for the strings it should
# contain. That is what tests/lint-agnix-clean.sh already does for the signature
# family, and it cannot see BEHAVIOUR: the #734 regression is a two-line move
# that leaves every searched string present and in order. So this suite slices
# the step's real bytes out of the yml and RUNS them under a stub PATH — the
# same discipline tests/validate-agnix-helpers.sh applies to the gate's helpers
# and tests/validate-lint-gates.sh applies to post-create.sh's install decision.
# A hand-copied body would drift from the workflow and keep passing while the
# real step broke.
#
# The extractor FAILS LOUD on an absent or over-grown region rather than
# yielding an empty body every assertion would then vacuously pass against.
#
# BASH_ENV is unset for every child: in the devcontainer it points at
# /etc/bash_env, whose /etc/bashrc.d/ scripts hard-RESET $PATH and would let a
# REAL npm/agnix outrank the stubs, silently invalidating every case.
#
# Pure bash + coreutils. Uses the shared harness assertions. bash-3.2 clean, no
# GNU-only regex (macOS ships BSD grep/sed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ALL="$SCRIPT_DIR/run-all.sh"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

REAL_BASH="$(command -v bash)"

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# The reserved "did not run" sentinel. Duplicated from run-all.sh on purpose:
# importing it from the script under test would make the assertion tautological.
SKIP_SENTINEL=77

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Skip visibility + agnix install branches (#741)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Extraction --------------------------------------------------------------

# extract_step_body <file> <step-name> — print the dedented body of the named
# step's `run: |` block scalar.
#
# YAML-aware by INDENTATION, which is what a block scalar is actually delimited
# by: the body runs from the line after `run: |` through the last line indented
# deeper than the `run:` key itself, with blank lines passed through. Anchoring
# on the closing construct instead (a following `- name:`, say) would be the
# end-marker-over-grow trap this repo has already been bitten by — a moved START
# delimiter errors loudly, a moved END one silently swallows whatever follows.
#
# Matching the step name as a LITERAL via index() rather than a regex: the name
# contains parentheses ("Install agnix (pinned)"), and building a pattern from it
# would mean escaping characters whose meaning flips between BRE and ERE across
# GNU and BSD. Same reasoning as harness.sh's extract_contract.
#
# Empty output on any failure — no match, no `run:`, an empty body — is handled
# by load_step_body below, which is the only caller.
extract_step_body() {
    command awk -v want="- name: $2" '
        # Locate the step. index()==1 after stripping leading blanks makes this
        # a literal prefix match on the list item, so a step whose name merely
        # CONTAINS another step name cannot be confused for it.
        !instep {
            probe = $0
            sub(/^[[:space:]]*/, "", probe)
            if (index(probe, want) == 1) { instep = 1 }
            next
        }
        # Inside the step, before its script: find the `run: |` key and record
        # the column it sits at. That column is the block scalar delimiter.
        instep && !inrun {
            if ($0 ~ /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/) {
                match($0, /^[[:space:]]*/)
                keyindent = RLENGTH
                inrun = 1
            } else if ($0 ~ /^[[:space:]]*- name:/) {
                # Ran off the end of the step without finding a script.
                exit
            }
            next
        }
        # The body: every line indented deeper than the key. A blank line is
        # part of the scalar (it may be interior whitespace), so it does not
        # terminate — only a NON-blank line at or left of the key column does.
        inrun {
            if ($0 ~ /^[[:space:]]*$/) { buf = buf "\n"; next }
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= keyindent) { exit }
            if (bodyindent == 0) { bodyindent = RLENGTH }
            print buf substr($0, bodyindent + 1)
            buf = ""
        }
    ' "$1"
}

# load_step_body <file> <step-name> <outvar> — extract, then PROVE the region is
# sound before any caller asserts against it.
#
# This guard is the reason the suite is not vacuous. An extractor that silently
# yields "" turns every downstream assertion into a comparison against nothing,
# and a body that over-grew into the next step would execute commands the case
# never meant to drive. Both are reported as failures here rather than surfacing
# as confusing behaviour later.
#
# Every local here is `__`-prefixed. The caller passes the NAME of its own
# variable and `printf -v` assigns through it, so a local sharing that name
# would shadow the caller's and the assignment would land on the shadow — the
# call returns "successfully" having set nothing, and the caller then reads an
# unset variable. Prefixing is what keeps the indirection sound for any name a
# caller picks.
load_step_body() {
    local __file="$1" __step="$2" __out="$3" __body __ok
    __body="$(extract_step_body "$__file" "$__step")"

    assert_not_empty "$__body" \
        "$(command basename "$__file"): extracted a non-empty body for step '$__step' (an empty slice would make every assertion below pass vacuously)"

    # Over-grow guard: a body that swallowed the following list item would carry
    # another `- name:` key. Checked as a value comparison, not by interpolating
    # the captured body into an eval'd assertion string.
    __ok=1
    case "$__body" in
        *"- name:"*) __ok=0 ;;
    esac
    assert_equals "1" "$__ok" \
        "$(command basename "$__file"): step '$__step' body stops at its own block scalar (it must not swallow the next step)"

    printf -v "$__out" '%s' "$__body"
}

# --- Stub plumbing -----------------------------------------------------------

# stub_dir <varname> — a fresh dir holding ONLY the tools a workflow step body
# legitimately reaches for, so a case cannot accidentally invoke a real npm or
# agnix sitting further down the operator's PATH.
#
# `bash` and `env` are load-bearing: the stubs' `#!/usr/bin/env bash` shebang
# resolves through this PATH, and with the stub dir as the ENTIRE PATH an absent
# bash makes every stub silently unexecutable — every case would then fail for a
# reason unrelated to what it tests. `mktemp`/`rm` are what the step itself runs.
stub_dir() {
    local __out="$1" dir tool src
    dir="$(command mktemp -d "$WORKDIR/stub.XXXXXX")" || return 1
    command mkdir -p "$dir/bin"
    for tool in bash env mktemp rm cat printf grep sed dirname basename; do
        src="$(command -v "$tool" 2>/dev/null)" || continue
        command ln -sf "$src" "$dir/bin/$tool" 2>/dev/null || true
    done
    printf -v "$__out" '%s' "$dir"
}

# plant_npm <dir> — an npm that logs its argv and takes its exit code from the
# environment, per sub-command:
#   NPM_SCRATCH_RC   the `--prefix "$verify_dir" --ignore-scripts` install
#   NPM_AUDIT_RC     `npm audit signatures`
#   NPM_GLOBAL_RC    `npm install -g …`
# Dispatching on the ARGV the step actually passes (rather than call order) keeps
# the stub honest if the step is ever reordered.
plant_npm() {
    local dir="$1"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'printf "npm %%s\\n" "$*" >>"%s/calls.log"\n' "$dir"
        command printf 'for a in "$@"; do\n'
        command printf '    if [ "$a" = "audit" ]; then exit "${NPM_AUDIT_RC:-0}"; fi\n'
        command printf '    if [ "$a" = "-g" ]; then exit "${NPM_GLOBAL_RC:-0}"; fi\n'
        command printf 'done\n'
        command printf 'exit "${NPM_SCRATCH_RC:-0}"\n'
    } >"$dir/bin/npm"
    command chmod +x "$dir/bin/npm"
}

# plant_agnix <dir> [version] — an agnix whose `--version` smoke-test exits
# AGNIX_RC. The broken-binary case is AGNIX_RC=1: the install "succeeded", the
# binary does not work. That is the branch this whole suite exists for.
#
# It PRINTS its version to stdout (default: the version ci.yml pins), because
# the step's smoke test greps that output for the pinned version rather than
# merely running the binary (#742). A stub that logged the call but printed
# nothing would fail that grep, so every healthy-install case would report a
# skip — the regression this default prevents.
#
# The optional second argument plants a DIFFERENT version, which is how the
# stale-cache case drives the mismatch branch: a binary that runs perfectly and
# is simply not the pinned one.
plant_agnix() {
    local dir="$1" ver="${2:-}"
    if [ -z "$ver" ]; then
        ver="$(agnix_pin_version "$WORKFLOW_DIR/ci.yml")"
    fi
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'printf "agnix %%s\\n" "$*" >>"%s/calls.log"\n' "$dir"
        # The version line is emitted ONLY on the success path. A stub that
        # printed it before honouring AGNIX_RC would satisfy the step's
        # `grep -qF <pin>` on its text alone, so the broken-binary cases would
        # take the healthy branch and assert nothing — the failure mode this
        # whole suite exists to cover, hidden by its own fixture.
        command printf 'if [ "${AGNIX_RC:-0}" -ne 0 ]; then exit "${AGNIX_RC:-0}"; fi\n'
        command printf 'printf "agnix %s\\n"\n' "$ver"
    } >"$dir/bin/agnix"
    command chmod +x "$dir/bin/agnix"
}

# agnix_pin_version <workflow> — the bare X.Y.Z from that file's agnix install
# pin. Read from the workflow rather than hardcoded so a version bump does not
# silently strand these fixtures on a stale number (the same reason the gate in
# tests/lint-agnix-clean.sh derives its pins instead of copying them).
agnix_pin_version() {
    command grep -oE 'agnix@[0-9]+\.[0-9]+\.[0-9]+' "$1" 2>/dev/null |
        command head -n 1 | command sed -n 's/^agnix@//p' || true
}

# Results of the most recent step invocation.
STEP_RC=0
STEP_OUT=""
STEP_LOG=""
STEP_SUMMARY=""
STEP_OUTPUT=""

# run_step <stubdir> <body> — execute the sliced step body the way GitHub does:
# `bash -e`, with $GITHUB_STEP_SUMMARY and $GITHUB_OUTPUT pointed at scratch
# files so the step's own writes are observable.
#
# `-e` is not incidental. It is the exact condition under which a bare
# `agnix --version` in the `then` branch would fail the job, so a case that ran
# the body without it could not distinguish the fixed shape from the regression.
run_step() {
    local dir="$1" body="$2"
    command rm -f "$dir/calls.log" "$dir/summary.md" "$dir/output.txt"
    : >"$dir/summary.md"
    : >"$dir/output.txt"
    STEP_RC=0
    STEP_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        HOME="$dir" \
        PATH="$dir/bin" \
        GITHUB_STEP_SUMMARY="$dir/summary.md" \
        GITHUB_OUTPUT="$dir/output.txt" \
        NPM_SCRATCH_RC="${NPM_SCRATCH_RC:-0}" \
        NPM_AUDIT_RC="${NPM_AUDIT_RC:-0}" \
        NPM_GLOBAL_RC="${NPM_GLOBAL_RC:-0}" \
        AGNIX_RC="${AGNIX_RC:-0}" \
        "$REAL_BASH" -e -c "$body" 2>&1)" || STEP_RC=$?
    STEP_LOG="$(command cat "$dir/calls.log" 2>/dev/null || true)"
    STEP_SUMMARY="$(command cat "$dir/summary.md" 2>/dev/null || true)"
    STEP_OUTPUT="$(command cat "$dir/output.txt" 2>/dev/null || true)"
}

# --- ci.yml: the broken-binary branch ---------------------------------------

test_ci_broken_binary_skips_without_failing() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    # NON-VACUITY FLOOR. If the step is reshaped so the slice no longer reaches
    # the install, every behavioural assertion below would drive a body that
    # never installs anything — and pass. Pin the marker that makes the case
    # meaningful.
    assert_contains "$body" 'npm install -g' \
        "the sliced ci.yml body reaches the global install (a truncated slice would assert nothing)"
    assert_contains "$body" 'agnix --version' \
        "the sliced ci.yml body reaches the smoke-test"

    # Install succeeds, binary is broken. THE case.
    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=1 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a broken agnix binary must NOT fail the step (#734) — under 'bash -e' a smoke-test outside the if-condition aborts the whole job"
    assert_contains "$STEP_OUT" "::notice::agnix install failed" \
        "the broken-binary path emits the install-failed notice, not silence"
    assert_not_contains "$STEP_OUT" "signature verification failed" \
        "a broken binary is not reported as a signature failure — different events, different messages"
    # The smoke-test must actually have run; otherwise the branch was reached
    # for some other reason and this case proves nothing about it.
    assert_contains "$STEP_LOG" "agnix --version" \
        "the smoke-test was genuinely invoked"
}

test_ci_broken_binary_is_visible_in_the_step_summary() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=1 run_step "$sb" "$body"

    # The #741 half. A ::notice:: lives in log output nobody scrolls on a green
    # run; the step summary renders on the run page itself.
    assert_contains "$STEP_SUMMARY" "agnix unavailable" \
        "a persistent skip is surfaced on the run page (\$GITHUB_STEP_SUMMARY), not only in log output (#741)"
}

test_ci_signature_failure_is_its_own_event() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=1 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a signature failure skips rather than failing the job (agnix is a best-effort enrichment)"
    assert_contains "$STEP_OUT" "::warning::agnix signature verification failed" \
        "a supply-chain signal is a warning with its own message, not the generic outage notice"
    assert_not_contains "$STEP_OUT" "::notice::agnix install failed" \
        "the two failure branches stay distinct — an unsigned tarball must not read as an outage"
    assert_contains "$STEP_SUMMARY" "signature verification failed" \
        "the signature failure reaches the run page too (#741)"

    # THE SECURITY PROPERTY, driven rather than grepped: verification failing
    # means the global install never happens. lint-agnix-clean.sh asserts the
    # ORDER of those lines in the file; only executing the branch proves the
    # guard actually holds.
    assert_not_contains "$STEP_LOG" "npm install -g" \
        "a failed signature check must prevent the global install entirely (#740)"
}

test_ci_wrong_version_binary_skips() {
    # A binary that RUNS PERFECTLY and is simply not the pinned version (#742).
    # Distinct from the broken-binary case above in the way that matters: there,
    # `agnix --version` fails outright; here it succeeds, so any smoke test that
    # merely executes the binary accepts it.
    #
    # That is exactly the stale-cache failure. The cache key restores an older
    # binary, install.js finds bin/agnix-binary present and skips its download,
    # and the job scans with an agnix it did not pin — green, and wrong. The
    # drift gate in tests/lint-agnix-clean.sh cannot see this: it compares
    # literals someone WROTE, never a stale blob in the remote cache. So the
    # step's own version grep is the only thing standing between a stale entry
    # and a bad scan, and this case is what holds it in place.
    local sb body pin
    stub_dir sb || return 1
    plant_npm "$sb"
    pin="$(agnix_pin_version "$WORKFLOW_DIR/ci.yml")"
    assert_not_empty "$pin" \
        "ci.yml must carry a greppable agnix pin for this fixture to mean anything"
    # A version that is NOT the pin and does not CONTAIN it either. The obvious
    # spelling — something like "0.0.0-not-$pin" — embeds the pin as a
    # substring, so the step's `grep -qF` matches it and the fixture sails down
    # the healthy path: a test that cannot fail for the reason it was written.
    # A fixed literal far from any real version avoids that, and the assertion
    # below proves the two genuinely differ rather than assuming it.
    local stale="1.0.0"
    assert_not_contains "$stale" "$pin" \
        "the stale fixture version must not contain the pin as a substring, or the step's grep -qF matches it and this case silently becomes a duplicate of the happy path"
    plant_agnix "$sb" "$stale"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a version mismatch degrades to a skip, it does not fail the job (ADR 0001 §2/§4)"
    assert_contains "$STEP_OUT" "::notice::agnix install failed" \
        "a wrong-version binary takes the notice-and-skip path, not the healthy one"
    assert_contains "$STEP_SUMMARY" "agnix unavailable" \
        "the version-mismatch skip is visible on the run page too (#741)"
}

test_ci_happy_path_is_quiet() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" "a healthy install succeeds"
    # The inverse of the two cases above, and the reason they mean anything: if
    # the step announced a skip unconditionally, both would pass while the
    # summary cried wolf on every green run.
    assert_not_contains "$STEP_OUT" "::notice::" \
        "a healthy install emits no skip notice"
    assert_not_contains "$STEP_OUT" "::warning::" \
        "a healthy install emits no warning"
    assert_equals "" "$STEP_SUMMARY" \
        "a healthy install writes NOTHING to the step summary (an unconditional line would make the skip signal meaningless)"
    assert_contains "$STEP_LOG" 'npm install -g' \
        "the global install ran on the happy path"
    # #740: the audited bytes must be the installed bytes.
    assert_contains "$STEP_LOG" "node_modules/agnix" \
        "the global install reads the VERIFIED tree, not a re-resolved registry fetch (#740)"
}

# assert_summary_write_failure_is_survivable <workflow-file> <label> — drive the
# named workflow's install step with an unwritable $GITHUB_STEP_SUMMARY.
#
# Shared by both workflows rather than written twice: the two steps carry the
# same append in the same shape, and a copy would let one drift while the other
# kept passing. That is the very asymmetry cycle 1 caught in the code itself, so
# the test for it must not reintroduce the shape one level up.
#
# A directory is the portable way to make the append fail: `>>` on a directory
# errors on every platform, whereas a mode-000 file is still writable by root
# (CI containers routinely run as root, so a chmod-based fixture would silently
# stop failing there).
assert_summary_write_failure_is_survivable() {
    local wf="$1" label="$2" sb body rc=0 out
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$wf" "Install agnix (pinned)" body || return 1

    command mkdir -p "$sb/unwritable-summary"
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" \
        GITHUB_STEP_SUMMARY="$sb/unwritable-summary" \
        GITHUB_OUTPUT="$sb/output.txt" \
        NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=1 \
        "$REAL_BASH" -e -c "$body" 2>&1)" || rc=$?

    # The reporting addition must not become a NEW way to fail the job. The step
    # runs under `bash -e`, so an unguarded append to an unwritable summary file
    # would abort it — converting the graceful skip this whole step exists to
    # produce back into the hard failure #734 removed, by way of the fix for it.
    assert_equals "0" "$rc" \
        "$label: an unwritable \$GITHUB_STEP_SUMMARY must not fail the step — the summary line is reporting, not a gate (#741)"
    assert_contains "$out" "::notice::agnix install failed" \
        "$label: the notice still reaches the log when the summary write fails (the signal is not lost, only its second surface)"
    # `2>/dev/null` must precede the append: redirections apply left to right, so
    # the usual trailing spelling opens the file first and a failed open writes
    # its diagnostic to the still-live stderr — absorbed failure, unabsorbed
    # noise, landing a spurious error in the job log of an otherwise fine run.
    assert_not_contains "$out" "Is a directory" \
        "$label: the failed append is silent, not merely non-fatal (stderr is redirected BEFORE the open)"
}

test_ci_summary_write_failure_does_not_fail_the_job() {
    assert_summary_write_failure_is_survivable "$WORKFLOW_DIR/ci.yml" "ci.yml"
}

test_code_scanning_summary_write_failure_does_not_fail_the_job() {
    assert_summary_write_failure_is_survivable \
        "$WORKFLOW_DIR/code-scanning.yml" "code-scanning.yml"
}

# --- code-scanning.yml: the same branch, reached by the sibling route ---------

test_code_scanning_broken_binary_marks_absent() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/code-scanning.yml" "Install agnix (pinned)" body || return 1

    assert_contains "$body" 'present=' \
        "the sliced code-scanning.yml body reaches its present= output (a truncated slice would assert nothing)"

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=1 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a broken agnix binary must not fail the code-scanning job either"
    # The load-bearing difference from ci.yml: downstream steps are gated on
    # this output. Writing present=true before the smoke-test would let a re-run
    # scan with a binary already known not to work.
    assert_contains "$STEP_OUTPUT" "present=false" \
        "a broken binary sets present=false, so the scan and upload steps skip"
    assert_not_contains "$STEP_OUTPUT" "present=true" \
        "present=true is never written for a binary that failed its smoke-test"
    assert_contains "$STEP_OUT" "::notice::agnix install failed" \
        "the code-scanning branch announces the skip too"
    # The SIBLING half of #741. ci.yml and code-scanning.yml carry the same
    # branch structure, so escalating the skip to the run page in one and not
    # the other would leave the identical invisible skip alive by the other
    # route — the harden-one-knob-but-not-its-sibling class this repo keeps
    # rediscovering.
    assert_contains "$STEP_SUMMARY" "agnix unavailable" \
        "code-scanning's broken-binary skip reaches the run page too, not just ci.yml's (#741)"
}

test_code_scanning_signature_failure_is_visible() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/code-scanning.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=1 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" "a signature failure skips rather than failing the code-scanning job"
    assert_contains "$STEP_OUTPUT" "present=false" \
        "an unverified agnix never scans (present=false)"
    assert_contains "$STEP_SUMMARY" "signature verification failed" \
        "code-scanning's signature failure reaches the run page with its OWN message (#741/#740)"
    assert_not_contains "$STEP_LOG" "npm install -g" \
        "a failed signature check prevents the global install here too (#740)"
}

test_code_scanning_happy_path_marks_present() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb"
    load_step_body "$WORKFLOW_DIR/code-scanning.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" "a healthy install succeeds"
    assert_contains "$STEP_OUTPUT" "present=true" \
        "a working agnix sets present=true so the scan runs"
}

# --- run-all.sh: run_stage's step-summary escalation -------------------------

# render_stage <summary-file> <exit-code>... — run run-all.sh's REAL run_stage
# over one command per exit code, with $GITHUB_STEP_SUMMARY pointed at the given
# file. Pass the literal `UNSET` to run with the variable genuinely absent from
# the environment. Slicing the function out of the source, rather than
# reimplementing it, is the same reasoning as the workflow extractor above.
#
# The flag variable and the sentinel are sliced in alongside it: run_stage reads
# both, and a stand-in for either could disagree with the real thing.
#
# UNSET IS NOT THE SAME AS EMPTY, and getting this wrong made an earlier draft
# of the off-GitHub case vacuous. With the variable set-but-empty, dropping the
# guard still creates no file — `>>""` simply fails and the `|| true` absorbs it
# — so the case passed with the guard AND without it. Only a genuinely absent
# variable discriminates, and only under `set -u`, where the unguarded expansion
# is a fatal error rather than a silent empty string. Both halves are required;
# either one alone tests nothing.
#
# `set -u` therefore mirrors run-all.sh's own `set -uo pipefail` rather than
# being incidental hygiene — the child must run under the same option the real
# script does, or it is not running the real script's conditions.
render_stage() {
    local summary="$1"
    shift
    local codes="$*"
    local summary_env=(GITHUB_STEP_SUMMARY="$summary")
    if [ "$summary" = "UNSET" ]; then
        summary_env=(--unset=GITHUB_STEP_SUMMARY)
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        "${summary_env[@]}" \
        "$REAL_BASH" -c '
            set -u
            eval "$(command sed -n "/^SKIP_EXIT_CODE=/p" "$1")"
            eval "$(command sed -n "/^_skips_header_written=/p" "$1")"
            eval "$(command sed -n "/^note_skip_in_step_summary() {/,/^}/p" "$1")"
            eval "$(command sed -n "/^run_stage() {/,/^}/p" "$1")"
            rc=0
            n=0
            for code in $2; do
                n=$((n + 1))
                run_stage "Demo stage $n" "$3" -c "exit $code"
            done
        ' _ "$RUN_ALL" "$codes" "$REAL_BASH" 2>&1
}

test_skipped_stage_reaches_the_step_summary() {
    local summary out
    summary="$WORKDIR/summary-one.md"
    : >"$summary"
    out="$(render_stage "$summary" "$SKIP_SENTINEL")"

    # The stdout contract from #538 is unchanged — this is additive.
    assert_contains "$out" "[SKIP] Demo stage 1 — did not run" \
        "the existing [SKIP] stdout rendering is undisturbed"

    local written
    written="$(command cat "$summary")"
    assert_contains "$written" "Skipped gates" \
        "a skipped stage adds a 'Skipped gates' section to the run-page summary (#741)"
    assert_contains "$written" "Demo stage 1" \
        "the summary names WHICH gate did not run"
}

test_repeated_skips_share_one_header() {
    local summary written headers
    summary="$WORKDIR/summary-many.md"
    : >"$summary"
    render_stage "$summary" "$SKIP_SENTINEL $SKIP_SENTINEL $SKIP_SENTINEL" >/dev/null
    written="$(command cat "$summary")"

    # Lazily-written header: one heading over a list, not one per skip.
    headers="$(command grep -c 'Skipped gates' "$summary" || true)"
    assert_equals "1" "$headers" \
        "the section header is written once, however many gates skip"
    assert_contains "$written" "Demo stage 3" \
        "every skipped gate is listed, not just the first"
}

test_passing_and_failing_stages_add_nothing() {
    local summary out
    summary="$WORKDIR/summary-none.md"
    : >"$summary"
    # A pass and a real failure. Neither is a skip, so neither belongs in a
    # section about gates that did not run — and a header emitted for them would
    # make the section noise rather than signal.
    out="$(render_stage "$summary" "0 1")"

    assert_contains "$out" "[ok] Demo stage 1" "a passing stage still renders [ok]"
    assert_contains "$out" "[FAIL] Demo stage 2" "a failing stage still renders [FAIL]"
    assert_equals "" "$(command cat "$summary")" \
        "neither a pass nor a failure writes to the skipped-gates summary"
}

test_off_github_is_a_total_noop() {
    local out
    # An ABSENT $GITHUB_STEP_SUMMARY — every local `just test` run — under
    # `set -u`, which is what run-all.sh actually sets. See render_stage's note:
    # set-but-empty would not discriminate, because an unguarded `>>""` fails
    # harmlessly on its own.
    out="$(render_stage "UNSET" "$SKIP_SENTINEL")"

    assert_contains "$out" "[SKIP] Demo stage 1 — did not run" \
        "the stdout skip line still renders with no step summary configured"
    # The regression the guard prevents: an unguarded expansion is a FATAL
    # `unbound variable` under set -u, which would abort run-all.sh mid-suite on
    # the first skipped gate — turning a reporting nicety into a suite-killer on
    # every developer machine.
    assert_not_contains "$out" "unbound variable" \
        "an absent \$GITHUB_STEP_SUMMARY must not abort the suite under set -u (a local 'just test' is unaffected)"
    # And the stages after the skip must still run: an abort would take the
    # whole remaining suite with it, which the single-stage assertion above
    # cannot see.
    out="$(render_stage "UNSET" "$SKIP_SENTINEL 0")"
    assert_contains "$out" "[ok] Demo stage 2" \
        "a skip off GitHub does not stop the stages that follow it"
}

test_run_stage_survives_an_unwritable_summary() {
    local out summary_dir
    summary_dir="$WORKDIR/unwritable-run-all"
    command mkdir -p "$summary_dir"

    # The sibling of test_ci_summary_write_failure_does_not_fail_the_job, for
    # run-all.sh's OWN emission. Its `|| true` is a separate line of code from
    # ci.yml's, and the comment beside it makes the same load-bearing claim
    # ("must never turn a skipped stage into a failed suite") — so it needs its
    # own assertion, or a regression dropping it there would pass on the
    # strength of the ci.yml case covering a different file.
    #
    # A directory rather than a chmod-000 file, for the reason given at the
    # ci.yml case: root can write a mode-000 file, and CI containers routinely
    # run as root, so a permission-based fixture would silently stop failing.
    out="$(render_stage "$summary_dir" "$SKIP_SENTINEL 0")"

    assert_contains "$out" "[SKIP] Demo stage 1 — did not run" \
        "the stdout skip line still renders when the summary write fails"
    assert_not_contains "$out" "Is a directory" \
        "the failed append is absorbed, not leaked into the suite's output"
    # The load-bearing half: the stage AFTER the failed write still runs. An
    # unabsorbed failure would abort the suite mid-run.
    assert_contains "$out" "[ok] Demo stage 2" \
        "an unwritable \$GITHUB_STEP_SUMMARY does not abort the suite (#741)"
}

test_node_absent_branch_reports_its_skip() {
    # The one skip path that does NOT go through run_stage: run-all.sh prints
    # its two [SKIP] lines directly when node is missing. Before #741 it also
    # bypassed the step summary entirely — every other skip-if-absent gate
    # reported itself on the run page and these two did not, which is the same
    # invisible-skip asymmetry the change exists to remove, surviving in the one
    # branch that reaches the outcome by a different route.
    #
    # Sliced out of run-all.sh and driven with a stub PATH that has no `node`,
    # so the else-branch is genuinely taken rather than simulated.
    local sb out
    stub_dir sb || return 1
    # THE POINT OF THE CASE: stub_dir does not plant node, but remove it
    # explicitly so a future widening of that symlink list cannot silently make
    # this case take the then-branch and assert nothing.
    command rm -f "$sb/bin/node"

    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        HOME="$sb" PATH="$sb/bin" \
        GITHUB_STEP_SUMMARY="$sb/node-summary.md" \
        "$REAL_BASH" -c '
            set -u
            eval "$(command sed -n "/^SKIP_EXIT_CODE=/p" "$1")"
            eval "$(command sed -n "/^_skips_header_written=/p" "$1")"
            eval "$(command sed -n "/^note_skip_in_step_summary() {/,/^}/p" "$1")"
            eval "$(command sed -n "/^run_stage() {/,/^}/p" "$1")"
            SCRIPT_DIR="$2"
            eval "$(command sed -n "/^if command -v node /,/^fi$/p" "$1")"
        ' _ "$RUN_ALL" "$SCRIPT_DIR" 2>&1 || true)"

    assert_contains "$out" "[SKIP] Manifest validation" \
        "the node-absent branch was genuinely taken (no node on the stub PATH)"
    local written
    written="$(command cat "$sb/node-summary.md" 2>/dev/null || true)"
    assert_contains "$written" "Manifest validation" \
        "the node-absent skip reaches the run page like every other skip (#741)"
    assert_contains "$written" "Workflow helper unit tests" \
        "BOTH node-dependent stages are reported, not just the first"
}

# --- Registration ------------------------------------------------------------

run_test test_ci_broken_binary_skips_without_failing \
    "ci.yml: a broken agnix binary skips instead of failing the job (#734)"
run_test test_ci_broken_binary_is_visible_in_the_step_summary \
    "ci.yml: the broken-binary skip reaches the run-page summary"
run_test test_ci_signature_failure_is_its_own_event \
    "ci.yml: a signature failure is distinct, and blocks the global install"
run_test test_ci_wrong_version_binary_skips \
    "ci.yml: a runnable but WRONG-version binary skips (stale cache, #742)"
run_test test_ci_happy_path_is_quiet \
    "ci.yml: a healthy install announces no skip and installs the verified tree"
run_test test_ci_summary_write_failure_does_not_fail_the_job \
    "ci.yml: an unwritable step summary does not fail the job"
run_test test_code_scanning_summary_write_failure_does_not_fail_the_job \
    "code-scanning.yml: an unwritable step summary does not fail the job"
run_test test_code_scanning_broken_binary_marks_absent \
    "code-scanning.yml: a broken binary sets present=false"
run_test test_code_scanning_signature_failure_is_visible \
    "code-scanning.yml: a signature failure is visible and blocks the install"
run_test test_code_scanning_happy_path_marks_present \
    "code-scanning.yml: a healthy install sets present=true"
run_test test_skipped_stage_reaches_the_step_summary \
    "run_stage: a 77 stage is written to the step summary"
run_test test_repeated_skips_share_one_header \
    "run_stage: repeated skips share one section header"
run_test test_passing_and_failing_stages_add_nothing \
    "run_stage: pass and fail write nothing to the summary"
run_test test_off_github_is_a_total_noop \
    "run_stage: an absent step summary is a total no-op under set -u"
run_test test_run_stage_survives_an_unwritable_summary \
    "run_stage: an unwritable step summary does not abort the suite"
run_test test_node_absent_branch_reports_its_skip \
    "run-all.sh: the node-absent skip reaches the run page too"

generate_report
