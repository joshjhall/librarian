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
#
# `mkdir`/`cp`/`chmod`/`sha256sum`/`cut` are the CACHE chain's tools — the
# restore branch's digest re-check and seeding copy, and the #742 staging block
# that populates ~/.cache/agnix-bin on a miss. They are planted for every case
# rather than only the cache ones because their absence is INVISIBLE: the
# staging chain ends in `|| true`, so a missing `cp` would silently produce the
# no-op the staging case exists to rule out, and the case would pass having
# proven nothing. Planting them unconditionally cannot perturb the other cases —
# the restore branch is still gated behind a `~/.cache/agnix-bin` that no case
# plants, and the staging block behind a `$staged_bin` only the staging case
# creates.
stub_dir() {
    local __out="$1" dir tool src
    dir="$(command mktemp -d "$WORKDIR/stub.XXXXXX")" || return 1
    command mkdir -p "$dir/bin"
    for tool in bash env mktemp rm cat printf grep sed dirname basename \
        mkdir cp chmod sha256sum cut; do
        src="$(command -v "$tool" 2>/dev/null)" || continue
        command ln -sf "$src" "$dir/bin/$tool" 2>/dev/null || true
    done
    printf -v "$__out" '%s' "$dir"
}

# npm_global_root <stubdir> — the directory this sandbox's `npm root -g` answers
# with. Shaped like a real global root (`…/lib/node_modules`, the tail of the
# `/cache/npm-global/lib/node_modules` recorded on the runner in #827) so a
# reader is not misled into thinking the staging path is a flat one.
#
# A function rather than a literal because BOTH sides need it and they must not
# drift: the stub prints it, and the staging case plants the binary the step is
# expected to read from it. Two copies of the path would let a typo make the
# case vacuous — the `-f` guard would find nothing and the staging chain would
# take its silent no-op, which is precisely the #766 regression this case exists
# to detect.
npm_global_root() {
    printf '%s\n' "$1/npm-global/lib/node_modules"
}

# plant_npm <dir> — an npm that logs its argv and takes its exit code from the
# environment, per sub-command:
#   NPM_SCRATCH_RC   the `--prefix "$verify_dir" --ignore-scripts` install
#   NPM_AUDIT_RC     `npm audit signatures`
#   NPM_GLOBAL_RC    `npm install -g …`
# Dispatching on the ARGV the step actually passes (rather than call order) keeps
# the stub honest if the step is ever reordered.
#
# `npm root -g` is answered FIRST, dispatching on the SUBCOMMAND at $1, and that
# ordering is the whole point (#827). The generic loop below matches `-g`
# anywhere in argv and exits with NPM_GLOBAL_RC — `npm root -g` hits that branch
# and exits printing NOTHING, so `staged_bin` in the #742 staging block would
# resolve to a bogus `/agnix/bin/agnix-binary`, the `-f` guard would no-op, and a
# case written against the stub as-is would measure nothing. Dispatching on `root`
# before that loop cannot disturb the existing `npm install -g` cases: their $1
# is `install`, so they never reach this branch.
#
# This branch deliberately exits 0 rather than honouring NPM_GLOBAL_RC, even
# though `npm root -g` does carry `-g`. That knob is documented above as the
# `npm install -g …` exit code, and the two are different operations: a case
# simulating a FAILED GLOBAL INSTALL would otherwise also break the root lookup,
# so one knob could no longer express "the install failed" without also
# expressing "npm cannot report its root". Simulating a failing `npm root -g`
# wants its own variable; nothing needs one yet, so none is added.
#
# It also CREATES the directory it names, and the scratch tree for a
# `--prefix` install, because the step treats both as real: `-f` guards and `cp`
# targets. A stub that only printed a path would leave the staging block reading
# a directory that does not exist.
plant_npm() {
    local dir="$1"
    command mkdir -p "$(npm_global_root "$dir")"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'printf "npm %%s\\n" "$*" >>"%s/calls.log"\n' "$dir"
        command printf 'if [ "${1:-}" = "root" ]; then printf "%%s\\n" "%s"; exit 0; fi\n' \
            "$(npm_global_root "$dir")"
        # Stand in for what a real `npm install --prefix DIR` produces: the
        # package tree the step then reads and copies into. Without it the
        # restore branch's seeding `cp` would fail for a reason unrelated to the
        # branch under test, and the staging case could not plant its decoy.
        #
        # Gated on NPM_SCRATCH_RC being 0, because a real install that FAILS
        # leaves no package tree behind. A stub that populated it either way
        # would let a future NPM_SCRATCH_RC!=0 case find the artifacts of a
        # success it did not get — which could mask a step that forgot to check
        # the scratch install's exit code and only "worked" because the tree
        # happened to be there. No case sets it non-zero today; the guard is
        # here so the first one that does measures the real thing.
        command printf 'prefix=""; take=""\n'
        command printf 'for a in "$@"; do\n'
        command printf '    if [ -n "$take" ]; then prefix="$a"; take=""; continue; fi\n'
        command printf '    if [ "$a" = "--prefix" ]; then take=1; fi\n'
        command printf 'done\n'
        command printf 'if [ -n "$prefix" ] && [ "${NPM_SCRATCH_RC:-0}" -eq 0 ]; then\n'
        command printf '    mkdir -p "$prefix/node_modules/agnix/bin"\n'
        # NPM_DECOY_BYTES plants a binary at the PRE-#766 `$verify_dir` spelling.
        # A real `--ignore-scripts` install leaves no binary here (that is the
        # whole point of #766), so this is deliberately artificial: it exists so
        # the staging case can tell the two SOURCES apart by content instead of
        # resting on the wrong path happening to be empty. Off unless a case
        # asks for it, so no other case sees a file it does not expect.
        command printf '    if [ -n "${NPM_DECOY_BYTES:-}" ]; then\n'
        command printf '        printf "%%s\\n" "$NPM_DECOY_BYTES" >"$prefix/node_modules/agnix/bin/agnix-binary"\n'
        command printf '    fi\n'
        command printf 'fi\n'
        command printf 'for a in "$@"; do\n'
        command printf '    if [ "$a" = "audit" ]; then exit "${NPM_AUDIT_RC:-0}"; fi\n'
        command printf '    if [ "$a" = "-g" ]; then exit "${NPM_GLOBAL_RC:-0}"; fi\n'
        command printf 'done\n'
        command printf 'exit "${NPM_SCRATCH_RC:-0}"\n'
    } >"$dir/bin/npm"
    command chmod +x "$dir/bin/npm"
}

# plant_agnix <dir> <workflow-file> [version] — an agnix whose `--version`
# smoke-test exits AGNIX_RC. The broken-binary case is AGNIX_RC=1: the install
# "succeeded", the binary does not work. That is the branch this whole suite
# exists for.
#
# It PRINTS its version to stdout (default: the version <workflow-file> pins),
# because the step's smoke test greps that output for the pinned version rather
# than merely running the binary (#742). A stub that logged the call but printed
# nothing would fail that grep, so every healthy-install case would report a
# skip — the regression this default prevents.
#
# THE WORKFLOW FILE IS REQUIRED, and that is the point (#767). This defaulted to
# ci.yml's pin for every caller, so a code-scanning.yml fixture planted a version
# resolved from the OTHER workflow. Harmless only because code-scanning.yml's
# smoke test carries no version grep and tests/lint-agnix-clean.sh asserts the
# two pins agree — both facts external to this file, and the first one changes
# the moment code-scanning.yml gains the #742 hardening. An OPTIONAL parameter
# defaulting to ci.yml would keep that silent wrong default available to the next
# caller who omits it, which is the defect itself preserved as a footgun; a
# required one makes every fixture state the workflow it is planted for.
#
# The optional THIRD argument plants a DIFFERENT version, which is how the
# stale-cache case drives the mismatch branch: a binary that runs perfectly and
# is simply not the pinned one.
plant_agnix() {
    local dir="$1" wf="$2" ver="${3:-}"
    if [ -z "$ver" ]; then
        ver="$(agnix_pin_version "$wf")"
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
        NPM_DECOY_BYTES="${NPM_DECOY_BYTES:-}" \
        AGNIX_RC="${AGNIX_RC:-0}" \
        "$REAL_BASH" -e -c "$body" 2>&1)" || STEP_RC=$?
    STEP_LOG="$(command cat "$dir/calls.log" 2>/dev/null || true)"
    STEP_SUMMARY="$(command cat "$dir/summary.md" 2>/dev/null || true)"
    STEP_OUTPUT="$(command cat "$dir/output.txt" 2>/dev/null || true)"
}

# --- Stub plumbing: the fixture's own anchoring (#767) -----------------------

test_plant_agnix_anchors_its_default_to_the_named_workflow() {
    # plant_agnix used to resolve its default version from ci.yml no matter which
    # workflow the fixture was being planted for, so every code-scanning.yml case
    # quietly planted the OTHER workflow's pin.
    #
    # THIS CASE CANNOT BE WRITTEN AGAINST THE REAL WORKFLOWS. Both pin the same
    # agnix version and tests/lint-agnix-clean.sh asserts they agree, so an
    # assertion that a code-scanning.yml fixture carries code-scanning.yml's pin
    # passes identically with and without the fix — a test that cannot fail for
    # the reason it was written. The divergent input has to be manufactured: a
    # scratch workflow whose pin is NOT ci.yml's, which is the one input where
    # the old and new behaviour differ.
    local sb scratch pin out
    stub_dir sb || return 1

    pin="$(agnix_pin_version "$WORKFLOW_DIR/ci.yml")"
    assert_not_empty "$pin" \
        "ci.yml must carry a greppable agnix pin, or this case has no baseline to differ from"

    # Far from any real version, so it cannot collide with the pin as a
    # substring the way an "0.0.0-not-$pin" spelling would.
    scratch="$sb/scratch-workflow.yml"
    command printf '          pin="agnix@9.9.9"\n' >"$scratch"
    # Checked in BOTH directions. The final assertion below is an absence
    # assertion against "$pin", so it goes vacuous if the two literals are
    # substrings of each other EITHER way — a one-directional guard would leave
    # the vacuous half unguarded and the case would pass while proving nothing.
    assert_not_contains "$pin" "9.9.9" \
        "the scratch pin must genuinely differ from ci.yml's, or the two sources are indistinguishable and this case proves nothing"
    assert_not_contains "9.9.9" "$pin" \
        "ci.yml's pin must not be a substring of the scratch version either, or the assert_not_contains below can never fail"

    plant_agnix "$sb" "$scratch"
    out="$(AGNIX_RC=0 "$sb/bin/agnix" --version 2>&1)" || true

    # The property is the RESOLUTION SOURCE, not a version literal: the planted
    # stub must report the pin of the workflow it was planted for.
    assert_contains "$out" "9.9.9" \
        "plant_agnix must default its version from the workflow file it was given (#767)"
    assert_not_contains "$out" "$pin" \
        "planting for one workflow must not resolve the version from ci.yml — the coupling #767 removed"
}

test_plant_agnix_without_a_workflow_aborts_loud() {
    # The REQUIRED parameter is the fix (#767); this pins what "required" buys.
    # The whole argument for a required parameter over an optional one defaulting
    # to ci.yml is that omitting it now FAILS rather than silently reproducing
    # the old wrong default — so that property has to be asserted, not merely
    # claimed in the comment above plant_agnix. Without this case, a future edit
    # restoring `wf="${2:-$WORKFLOW_DIR/ci.yml}"` reinstates the exact defect
    # while every other test in this file keeps passing.
    local sb rc=0
    stub_dir sb || return 1

    # A SUBSHELL is load-bearing: the suite runs under `set -u`, so the unbound
    # $2 aborts the shell it evaluates in. Called inline that would kill the
    # whole run rather than fail one case.
    (plant_agnix "$sb") >/dev/null 2>&1 || rc=$?

    assert_true "[ \"$rc\" -ne 0 ]" \
        "plant_agnix must abort when its workflow-file argument is omitted, not fall back to a default (#767) — a silent fallback is the footgun the required parameter exists to remove"
}

# --- ci.yml: the broken-binary branch ---------------------------------------

test_ci_broken_binary_skips_without_failing() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
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
    # #766: and it must NOT claim agnix installed. This is the arm that keeps
    # agnix best-effort (ADR 0001 §2/§4): the "Assert the agnix gate actually
    # ran" step fires only on installed=true, so writing it here — where the
    # binary is broken — would turn a legitimate skip into a failed job on
    # every runner that cannot install agnix.
    assert_not_contains "$STEP_OUTPUT" "installed=true" \
        "a broken binary must NOT record installed=true (#766) — that output arms the did-the-gate-run assertion, which would then fail the job on a legitimate skip"
}

test_ci_broken_binary_is_visible_in_the_step_summary() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=1 run_step "$sb" "$body"

    # The #741 half. A ::notice:: lives in log output nobody scrolls on a green
    # run; the step summary renders on the run page itself.
    assert_contains "$STEP_SUMMARY" "agnix unavailable" \
        "a persistent skip is surfaced on the run page (\$GITHUB_STEP_SUMMARY), not only in log output (#741)"
}

# The OTHER arm of the outer `if`: the scratch install itself fails (registry
# outage, offline runner), so `npm audit signatures` is never reached.
#
# Two things are pinned. First the STEP's behaviour: a failed scratch install
# must warn-and-skip rather than fail the job, and must not go on to install
# globally — the same best-effort contract the signature case covers, reached by
# the other route.
#
# Second the FIXTURE's: NPM_SCRATCH_RC=1 must leave no scratch package tree
# behind, because a real failed `npm install --prefix` leaves none. That guard
# had no case exercising it — it was verified only by an ad-hoc probe while
# writing it, and an unexercised guard in a fixture the whole suite trusts is
# how a fixture silently stops modelling what it claims to.
#
# RECORDED, NOT ENDORSED: the message asserted below says "signature
# verification failed", but this case never reaches `npm audit signatures` — the
# scratch install failed first. Both routes share one `else`, so a plain
# registry outage is announced as a supply-chain event, which is exactly the
# conflation the #740 comment beside that branch says must not happen ("a
# supply-chain signal must not read as an outage") — in the other direction.
# The assertion pins what ci.yml ACTUALLY emits, because a test that asserted
# the desirable text would fail today and this is a tests-only change (#827).
# Splitting the branch is a ci.yml fix and wants its own issue; when it lands,
# this expectation changes with it.
test_ci_scratch_install_failure_warns_and_leaves_no_tree() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=1 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a failed scratch install does not fail the job (agnix is best-effort, ADR 0001 §2/§4)"
    # Pinned on the FULL message, not a bare `::warning::`. That substring alone
    # would pass against any warning text whatsoever, including one rewritten to
    # something unrelated — a matcher with no teeth.
    assert_contains "$STEP_OUT" "::warning::agnix signature verification failed" \
        "the failed install is announced with the shared else-branch's message"
    # THE #741 ASSERTION, which every sibling skip case carries and which this
    # suite exists for: a persistent skip must reach the RUN PAGE, not only the
    # job log nobody scrolls on a green run. A scratch-install failure is such a
    # skip, and it reaches the summary by a DIFFERENT route than the audit
    # failure, so a regression that stopped writing the line on this route only
    # would be invisible without a case here.
    assert_contains "$STEP_SUMMARY" "signature verification failed" \
        "the scratch-install skip reaches \$GITHUB_STEP_SUMMARY too (#741) — the audit-failure route is a separate path through the same block"
    assert_not_contains "$STEP_LOG" "npm install -g" \
        "a failed scratch install must NOT reach the global install (#740: the audited bytes are the installed bytes)"
    assert_not_contains "$STEP_OUTPUT" "installed=true" \
        "a failed install must not arm the did-the-gate-run assertion (#766)"

    # The FIXTURE half, asserted by driving the stub directly rather than by
    # inspecting the step's $verify_dir: that directory is a `mktemp -d` created
    # inside the step body, in TMPDIR and not under $sb, so a glob out here
    # would match nothing and pass whether or not the guard worked — the
    # vacuous-assertion trap this suite is built to avoid. Calling the stub with
    # a prefix we choose keeps the check deterministic and in our own control.
    local probe
    probe="$sb/scratch-probe"
    (NPM_SCRATCH_RC=1 "$sb/bin/npm" install --prefix "$probe" --ignore-scripts "agnix@0.0.0" >/dev/null 2>&1) || true
    local made
    made=0
    [ -d "$probe/node_modules/agnix/bin" ] && made=1
    assert_equals "0" "$made" \
        "a FAILED scratch install leaves no package tree behind, as a real npm install does not (the NPM_SCRATCH_RC guard in plant_npm)"

    # …and the same call with RC=0 DOES build it. Without this arm the check
    # above would pass against a stub that had simply stopped creating the tree
    # at all, which would silently break the staging case's decoy.
    (NPM_SCRATCH_RC=0 "$sb/bin/npm" install --prefix "$sb/scratch-ok" --ignore-scripts "agnix@0.0.0" >/dev/null 2>&1) || true
    made=0
    [ -d "$sb/scratch-ok/node_modules/agnix/bin" ] && made=1
    assert_equals "1" "$made" \
        "a SUCCEEDING scratch install still builds the package tree (else the guard would have disabled the fixture wholesale)"
}

test_ci_signature_failure_is_its_own_event() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
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
    # #766: no install means no installed=true, so the did-the-gate-run
    # assertion stays disarmed and the gate's 77 skip remains legitimate.
    assert_not_contains "$STEP_OUTPUT" "installed=true" \
        "a signature failure must NOT record installed=true (#766) — agnix was never installed, so the gate's skip is legitimate and must not fail the job"
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
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml" "$stale"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" \
        "a version mismatch degrades to a skip, it does not fail the job (ADR 0001 §2/§4)"
    assert_contains "$STEP_OUT" "::notice::agnix install failed" \
        "a wrong-version binary takes the notice-and-skip path, not the healthy one"
    assert_contains "$STEP_SUMMARY" "agnix unavailable" \
        "the version-mismatch skip is visible on the run page too (#741)"
    # Non-vacuity, the same guard the broken-binary case carries. Every npm rc
    # is 0 here, so the ONLY thing that can send this case down the skip path is
    # the version grep — but that is an argument about today's if-condition, not
    # a property the test enforces. Without this line a refactor that reordered
    # or short-circuited the condition could reach the notice for an unrelated
    # reason and the case would still pass, having never exercised the mismatch
    # it is named for.
    assert_contains "$STEP_LOG" "agnix --version" \
        "the version smoke-test was genuinely invoked (else this case passes without testing the mismatch)"
}

test_ci_happy_path_is_quiet() {
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
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
    # #766: the success branch records that agnix genuinely installed. The
    # "Assert the agnix gate actually ran" step is gated on this output, so a
    # success path that stopped writing it would silently DISARM that step —
    # the gate could go inert again and nothing would fail. Pinned here on the
    # positive arm; the negative arm is pinned by the failure cases below.
    assert_contains "$STEP_OUTPUT" "installed=true" \
        "a healthy install records installed=true (#766) — the regression-detection step is gated on it, so losing this output disarms the check without failing anything"
}

# --- ci.yml: the #742 cache-staging source (#827) ---------------------------

# The staging block populates ~/.cache/agnix-bin on a cache MISS, reading from
# the GLOBAL install root:
#
#     staged_bin="$(npm root -g)/agnix/bin/agnix-binary"
#
# That spelling is the half of #766 that would otherwise regress silently.
# Under `--install-links` npm COPIES the package, so the postinstall writes
# bin/agnix-binary into `npm root -g`, NOT into $verify_dir. Reverting to the
# old `$verify_dir` spelling finds no file, takes the `-f` guard's silent no-op,
# and quietly stops populating the cache — green, and never a cache hit again.
#
# WHY THIS ASSERTS ON CONTENT, NOT EXISTENCE. Existence alone would be a
# one-directional test: the reverted spelling reads a path that (in a bare
# sandbox) holds nothing, so `[ -f ]` is false and the case fails — but only
# because the wrong path happened to be EMPTY, not because the test can tell the
# two sources apart. So this case plants a DECOY at the $verify_dir spelling
# with different bytes. The revert then finds a file, stages it, and the case
# fails on the CONTENT mismatch. That is what makes the mutation distinguishable
# in both directions rather than resting on an accident of the fixture.
test_ci_cache_staging_reads_the_global_root() {
    local sb body groot staged sidecar want_digest got_digest
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/ci.yml"
    load_step_body "$WORKFLOW_DIR/ci.yml" "Install agnix (pinned)" body || return 1

    # NON-VACUITY FLOOR. If the slice no longer reaches the staging block, every
    # assertion below would compare against a cache that was never written for a
    # reason this case is not testing.
    assert_contains "$body" 'npm root -g' \
        "the sliced step body reaches the cache-staging source (#742/#827)"

    # The binary the step SHOULD read: the global install root, where the
    # postinstall writes under --install-links.
    groot="$(npm_global_root "$sb")"
    command mkdir -p "$groot/agnix/bin"
    command printf 'GLOBAL-ROOT-BYTES\n' >"$groot/agnix/bin/agnix-binary"

    # THE DECOY, at the pre-#766 `$verify_dir` spelling. $verify_dir is a
    # `mktemp -d` created INSIDE the step body, so no fixture out here can
    # address it — the npm stub plants the decoy from within, on the same
    # `--prefix` install the step performs.
    #
    # No ~/.cache/agnix-bin is planted, so agnix_cache_usable stays 0 — this is
    # the cache-MISS arm, the only arm that performs the staging cp.
    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 \
        NPM_DECOY_BYTES="VERIFY-DIR-BYTES" run_step "$sb" "$body"

    assert_equals "0" "$STEP_RC" "the cache-miss staging path succeeds"
    assert_contains "$STEP_LOG" "npm root -g" \
        "the staging block queried npm root -g for its source (#827)"
    assert_contains "$STEP_OUT" "agnix binary staged for cache save" \
        "the staging cp chain ran to completion (its trailing || true would otherwise absorb a no-op silently)"

    staged="$sb/.cache/agnix-bin/agnix-binary"
    assert_file_exists "$staged" \
        "the cache directory was populated on a miss"
    # THE ASSERTION THIS CASE EXISTS FOR: the staged bytes came from the global
    # install root, not from $verify_dir.
    assert_file_contains "$staged" "GLOBAL-ROOT-BYTES" \
        "the staged binary was read from \$(npm root -g), the half of #766 that would otherwise regress silently (#742/#827)"
    assert_file_not_contains "$staged" "VERIFY-DIR-BYTES" \
        "the staged binary is NOT the pre-#766 \$verify_dir source — reverting staged_bin must fail here, not merely find an empty path"

    # The sidecar the restore branch re-checks against. A digest that did not
    # describe the staged bytes would make the next run's re-check discard a
    # perfectly good entry, so it is asserted as a real digest of a real file
    # rather than merely present.
    sidecar="$staged.sha256"
    assert_file_exists "$sidecar" \
        "the sha256 sidecar is written beside the staged binary"
    want_digest="$(command sha256sum "$staged" | command cut -d' ' -f1)"
    got_digest="$(command cut -d' ' -f1 <"$sidecar" 2>/dev/null || true)"
    assert_equals "$want_digest" "$got_digest" \
        "the sidecar digest describes the staged bytes (the restore branch re-checks against it)"
}

# --- ci.yml: the did-the-gate-actually-run assertion (#766) ------------------

# assert_gate_ran_step <gate-exit-code> <expected-step-rc> <label> — drive the
# "Assert the agnix gate actually ran" step body with a STUB
# tests/lint-agnix-clean.sh that exits the given code.
#
# The step is the regression-detection mechanism #766 asks for, so leaving it to
# a live CI run for its first coverage would mean shipping the one check whose
# whole job is catching a silent failure with no evidence that it fires. The
# stub is what makes all three outcomes reachable here: on a real tree the gate
# exits 0 (agnix present) or 77 (absent), and 77 cannot be produced on a runner
# that has agnix without uninstalling it.
#
# `cd`ing into the sandbox is load-bearing: the step invokes the gate by
# RELATIVE path (`bash tests/lint-agnix-clean.sh`), so a stub at that relative
# path inside a scratch cwd is what the body actually runs. Without the cd it
# would execute the repo's real gate and this case would measure the host's
# agnix instead of the branch under test.
assert_gate_ran_step() {
    local gate_rc="$1" want_rc="$2" label="$3"
    local sb body
    stub_dir sb || return 1
    load_step_body "$WORKFLOW_DIR/ci.yml" "Assert the agnix gate actually ran" body || return 1

    # NON-VACUITY FLOOR, same rationale as the install cases: a slice that no
    # longer reaches the gate invocation would drive a body that checks nothing
    # and pass every assertion below.
    assert_contains "$body" 'tests/lint-agnix-clean.sh' \
        "$label: the sliced step body reaches the gate invocation"

    command mkdir -p "$sb/tests"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'exit %s\n' "$gate_rc"
    } >"$sb/tests/lint-agnix-clean.sh"
    command chmod +x "$sb/tests/lint-agnix-clean.sh"

    STEP_RC=0
    STEP_OUT="$(cd "$sb" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        HOME="$sb" \
        PATH="$sb/bin" \
        "$REAL_BASH" -e -c "$body" 2>&1)" || STEP_RC=$?

    assert_equals "$want_rc" "$STEP_RC" "$label: step exit code"
}

test_gate_inert_fails_the_job() {
    # THE case this step exists for: agnix installed (the step only runs when
    # the install wrote installed=true) and the gate STILL reported 77. That
    # combination is always the #766 defect, and it must be loud.
    assert_gate_ran_step 77 1 "gate skipped despite a successful install"
    assert_contains "$STEP_OUT" "::error::" \
        "an inert gate is reported as an ::error:: annotation, not a silent non-zero exit"
    assert_contains "$STEP_OUT" "inert" \
        "the error names the condition (an inert gate), so the reader is not left to infer it"
}

test_gate_ran_clean_passes() {
    assert_gate_ran_step 0 0 "gate ran and found nothing"
    assert_not_contains "$STEP_OUT" "::error::" \
        "a gate that ran clean emits no error annotation"
}

test_gate_real_failure_is_not_swallowed_as_inert() {
    # A gate that RAN and found real errors exits non-zero but NOT 77. This step
    # must not convert that into its own inert-gate error: the suite has already
    # failed the job on the real finding, and relabelling it "the gate did not
    # run" would misdirect whoever reads the annotation. Exit 0 here is correct
    # precisely because this step's question ("did it run?") was answered yes.
    assert_gate_ran_step 1 0 "gate ran and reported findings"
    assert_not_contains "$STEP_OUT" "::error::" \
        "a real gate failure is not relabelled as an inert gate (the suite already failed the job on it)"
}

assert_global_install_uses_install_links() {
    local wf="$1" label="$2"
    local sb body
    stub_dir sb || return 1
    plant_npm "$sb"
    plant_agnix "$sb" "$WORKFLOW_DIR/$wf"
    load_step_body "$WORKFLOW_DIR/$wf" "$3" body || return 1

    NPM_SCRATCH_RC=0 NPM_AUDIT_RC=0 NPM_GLOBAL_RC=0 AGNIX_RC=0 run_step "$sb" "$body"

    # Asserted on the ARGV the step actually invoked, not on the workflow file's
    # text. tests/lint-agnix-clean.sh already greps the file; duplicating that
    # here would add a second reader of the same bytes and prove nothing new.
    # What this suite can prove — and that one cannot — is that the flag rides
    # the global install as EXECUTED, through whatever quoting and line
    # continuations the YAML slice carries.
    #
    # The two needles are checked on one logged line, because the property is
    # "the global install carried the flag", not "both strings appear somewhere
    # in the log". A scratch install that happened to log --install-links
    # elsewhere would satisfy a split assertion while the -g call went without.
    assert_contains "$STEP_LOG" "npm install -g --install-links" \
        "$label: the global install must carry --install-links (#766) — without it npm symlinks the package into \$verify_dir, the step's own 'rm -rf \"\$verify_dir\"' dangles it, and agnix resolves nowhere for every later step while this step still reports success"
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
    plant_agnix "$sb" "$wf"
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

test_ci_global_install_uses_install_links() {
    assert_global_install_uses_install_links "ci.yml" "ci.yml" "Install agnix (pinned)"
}

test_code_scanning_global_install_uses_install_links() {
    assert_global_install_uses_install_links "code-scanning.yml" "code-scanning.yml" "Install agnix (pinned)"
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
    plant_agnix "$sb" "$WORKFLOW_DIR/code-scanning.yml"
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
    plant_agnix "$sb" "$WORKFLOW_DIR/code-scanning.yml"
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
    plant_agnix "$sb" "$WORKFLOW_DIR/code-scanning.yml"
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

run_test test_plant_agnix_anchors_its_default_to_the_named_workflow \
    "plant_agnix defaults its version from the workflow it is planted for (#767)"
run_test test_plant_agnix_without_a_workflow_aborts_loud \
    "plant_agnix aborts when its workflow-file argument is omitted (#767)"
run_test test_ci_broken_binary_skips_without_failing \
    "ci.yml: a broken agnix binary skips instead of failing the job (#734)"
run_test test_ci_broken_binary_is_visible_in_the_step_summary \
    "ci.yml: the broken-binary skip reaches the run-page summary"
run_test test_ci_scratch_install_failure_warns_and_leaves_no_tree \
    "ci.yml: a failed scratch install warns, skips the global install, and leaves no tree"
run_test test_ci_signature_failure_is_its_own_event \
    "ci.yml: a signature failure is distinct, and blocks the global install"
run_test test_ci_wrong_version_binary_skips \
    "ci.yml: a runnable but WRONG-version binary skips (stale cache, #742)"
run_test test_ci_happy_path_is_quiet \
    "ci.yml: a healthy install announces no skip and installs the verified tree"
run_test test_ci_cache_staging_reads_the_global_root \
    "ci.yml: the cache-miss staging cp reads \$(npm root -g), not \$verify_dir (#742/#827)"
run_test test_gate_inert_fails_the_job \
    "ci.yml: an installed-but-inert agnix gate FAILS the job (#766)"
run_test test_gate_ran_clean_passes \
    "ci.yml: a gate that ran clean passes the assertion step"
run_test test_gate_real_failure_is_not_swallowed_as_inert \
    "ci.yml: a real gate failure is not relabelled as an inert gate"
run_test test_ci_global_install_uses_install_links \
    "ci.yml: the global install carries --install-links as executed (#766)"
run_test test_code_scanning_global_install_uses_install_links \
    "code-scanning.yml: the global install carries --install-links as executed (#766)"
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
