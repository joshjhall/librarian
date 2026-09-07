#!/usr/bin/env bash
# Shard partition gate for the run-all.sh CI matrix (issue #960).
#
# WHAT THIS EXISTS TO STOP. Sharding the suite across a CI matrix buys ~2x wall
# clock and introduces one new failure mode: a stage can stop running while every
# shard still reports green. The monolith could not do that — there was one list,
# and losing a stage meant a visible deletion. With N lists, a stage goes missing
# when a rename touches the dispatch but not the manifest, or when a shard file is
# added and nobody wires it in.
#
# That is the inert-gate shape this repo keeps filing issues about (#538, #571,
# #766, and #906 — a job that reported pass for its entire lifetime without ever
# executing). So the partition is checked in THREE directions, each with a
# NEGATIVE FIXTURE proving the check actually fires:
#
#   1. a shard file on disk that the manifest does not list;
#   2. a manifest entry with no file on disk;
#   3. the union of the shards != the full stage set (a stage in no shard).
#
# Plus a fourth that the issue did not name but which makes (3) unsound on its
# own: a stage claimed by TWO shards. A set-equality union check cannot see a
# double-count, so a duplicate can mask a genuine omission — the two errors
# cancel and the gate reports a clean partition over a suite that is missing a
# stage. It is checked on the multiset, separately.
#
# WHY THE FIXTURES ARE THE POINT. Each assertion here would pass vacuously if
# the underlying helper returned empty for the wrong reason (a bad path, a typo'd
# glob, a comm invocation reading the wrong stream). The negative fixtures build
# a real shard directory, break it in one specific way, and assert the helper
# reports THAT breakage — so a helper that always returns "fine" fails this gate
# rather than passing it. Same posture as fragments.sh's non-vacuity assertion.
#
# Pure bash + coreutils. bash-3.2 clean, per CLAUDE.md § Runtime policy.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

RUN_ALL="$SCRIPT_DIR/run-all.sh"
SHARD_DIR="$SCRIPT_DIR/shards"

REAL_BASH="$(command -v bash)"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
cleanup() { command rm -rf "$WORKDIR"; }
trap cleanup EXIT

test_suite "run-all.sh shard partition (#960)"

# --- helpers ----------------------------------------------------------------

# collect_stages — every stage label the REAL shards claim, one per line.
#
# Sources the shard files with run_stage aliased to the recorder, so no gate
# actually executes. That is what makes this gate cheap enough to run in every
# shard of the very matrix it validates.
collect_stages() {
    "$REAL_BASH" -c '
        set -uo pipefail
        SCRIPT_DIR="$1"
        source "$SCRIPT_DIR/lib/shards.sh"
        run_stage() { shard_record_stage "$@"; }
        source_shards "$SCRIPT_DIR/shards" $2
        shard_stage_list
    ' _ "$SCRIPT_DIR" "$(manifest_of "$RUN_ALL")" 2>&1
}

# manifest_of <run-all-path> — the SHARDS="..." value, read from the source.
#
# Parsed rather than duplicated: a second copy of the manifest in this gate would
# be one more list to drift, which is the defect under test.
manifest_of() {
    command sed -n 's/^SHARDS="\([^"]*\)".*/\1/p' "$1" | command head -n1
}

# make_shard_sandbox <outvar> — a miniature shards/ tree plus a run-all-shaped
# manifest, for the negative fixtures. Deliberately small: the point is the
# manifest logic, not the real corpus.
# The internal variable is `__sb`, NOT `d`. Callers pass the literal name `d`,
# and bash-3.2 has no namerefs — `printf -v "$__out"` assigns by NAME, so a
# same-named `local d` here would shadow the caller's and the assignment would
# land on the local, leaving the caller with an empty string. That failed as
# `source /lib/shards.sh: No such file or directory` (an empty $d), which reads
# like a path bug rather than a scoping one. Same trap as tests/lib/harness.sh's
# out-param helpers; keep the internal name distinct from any plausible caller's.
make_shard_sandbox() {
    local __out="$1"
    local __sb
    __sb="$(command mktemp -d "$WORKDIR/sb.XXXXXX")"
    command mkdir -p "$__sb/shards" "$__sb/lib"
    command cp "$SCRIPT_DIR/lib/shards.sh" "$__sb/lib/shards.sh"
    {
        command printf '# shellcheck shell=bash\n'
        command printf 'run_stage "Alpha" true\n'
    } >"$__sb/shards/10-a.sh"
    {
        command printf '# shellcheck shell=bash\n'
        command printf 'run_stage "Beta" true\n'
    } >"$__sb/shards/20-b.sh"
    printf -v "$__out" '%s' "$__sb"
}

# run_sandbox_manifest <dir> <manifest> — source the sandbox shards under the
# given manifest and print the outcome. Exit status is source_shards'.
run_sandbox_manifest() {
    local d="$1" manifest="$2"
    "$REAL_BASH" -c '
        set -uo pipefail
        d="$1"
        source "$d/lib/shards.sh"
        run_stage() { shard_record_stage "$@"; }
        source_shards "$d/shards" $2
        printf "UNWIRED:%s\n" "$(shard_unwired | command tr "\n" " ")"
        printf "MISSING:%s\n" "$(shard_missing | command tr "\n" " ")"
        printf "DUPES:%s\n" "$(shard_duplicate_stages | command tr "\n" " ")"
    ' _ "$d" "$manifest" 2>&1
}

# --- direction 1: a shard on disk that nobody listed ------------------------

test_unlisted_shard_is_reported() {
    local d="" out=""
    make_shard_sandbox d
    # 20-b.sh exists but is left out of the manifest.
    out="$(run_sandbox_manifest "$d" "10-a.sh")"
    assert_contains "$out" "UNWIRED:20-b.sh" \
        "a shard file on disk that the manifest omits is reported (its stages would never run)"
}

# NON-VACUITY for direction 1: the same helper must stay QUIET on a correct
# tree. Without this, a shard_unwired that always printed a filename would pass
# the case above while flagging every healthy repo.
test_complete_manifest_reports_no_unwired() {
    local d="" out=""
    make_shard_sandbox d
    out="$(run_sandbox_manifest "$d" "10-a.sh 20-b.sh")"
    assert_contains "$out" "UNWIRED:" "a complete manifest reports nothing unwired"
    assert_not_contains "$out" "UNWIRED:10-a.sh" "10-a.sh is not falsely flagged"
    assert_not_contains "$out" "UNWIRED:20-b.sh" "20-b.sh is not falsely flagged"
}

# --- direction 2: a manifest entry with no file -----------------------------

# source_shards ABORTS on a missing file rather than continuing, so this asserts
# the exit status and the diagnostic, not a printed list. Aborting is the right
# behaviour: continuing would run a suite with a known hole in it.
test_missing_shard_aborts_loudly() {
    local d="" out="" rc=0
    make_shard_sandbox d
    out="$(run_sandbox_manifest "$d" "10-a.sh 20-b.sh 99-gone.sh")" || rc=$?
    assert_true "[ '$rc' -ne 0 ]" \
        "a manifest entry with no file on disk fails the suite (exit $rc)"
    assert_contains "$out" "99-gone.sh" "the diagnostic names the missing shard"
    assert_contains "$out" "FATAL" "the diagnostic is loud, not a warning"
}

# --- direction 3: the union of shards != the full stage set -----------------

# THE CASE THE ISSUE IS ABOUT. A stage that belongs to no shard runs nowhere,
# and every shard still reports green because each is internally consistent.
#
# The real check compares the shards' union against the stage set. There is no
# second list to compare against — deliberately, since a committed expected-stage
# list would be exactly the duplicate that drifts. Instead the invariant is
# anchored on the SCRIPTS the shards dispatch: every tests/*.sh gate that the
# suite is supposed to run must be named by some shard. A gate file that no shard
# mentions is either unwired or deliberately excluded, and the exclusions are
# explicit and few.
test_every_gate_script_is_dispatched_by_a_shard() {
    local f base undispatched=""
    for f in "$SCRIPT_DIR"/*.sh; do
        base="${f##*/}"
        case "$base" in
            # EXPLICIT and FEW, each for a structural reason — never "we chose
            # not to run this", which would make the gate assert the opposite of
            # the truth (CLAUDE.md § scanner exclusions).
            #
            #   run-all.sh          the entry point that does the dispatching.
            #   validate-shards.sh  this gate; it validates the manifest and is
            #                       run by every shard, not owned by one.
            #   coverage-*.sh       not suite stages at all — they are the
            #                       separate, informational `coverage` job in
            #                       ci.yml (and `just coverage`), deliberately
            #                       kept out of `just test` because a coverage
            #                       regression must not block a merge (#186).
            run-all.sh | validate-shards.sh | coverage-python.sh | coverage-mjs.sh) continue ;;
        esac
        command grep -rq -- "$base" "$SHARD_DIR" || undispatched="$undispatched$base
"
    done
    assert_equals "" "$undispatched" \
        "every tests/*.sh gate is dispatched by some shard (an undispatched gate runs NOWHERE, with all shards green)"
}

# Non-vacuity for the sweep above: it must actually have inspected a real corpus.
# A broken glob would leave `undispatched` empty and assert nothing.
test_gate_sweep_corpus_is_non_empty() {
    local n
    n="$(command ls "$SCRIPT_DIR"/*.sh 2>/dev/null | command wc -l | command tr -d '[:space:]')"
    assert_true "[ '$n' -gt 50 ]" \
        "the gate sweep inspected a real corpus of tests/*.sh (found $n)"
}

# --- direction 4: one stage, one shard --------------------------------------

test_duplicate_stage_is_reported() {
    local d="" out=""
    make_shard_sandbox d
    # Claim "Alpha" from a second shard as well.
    {
        command printf '# shellcheck shell=bash\n'
        command printf 'run_stage "Alpha" true\n'
    } >"$d/shards/30-c.sh"
    out="$(run_sandbox_manifest "$d" "10-a.sh 20-b.sh 30-c.sh")"
    assert_contains "$out" "DUPES:Alpha" \
        "a stage claimed by two shards is reported (a duplicate can mask a missing stage in the union check)"
}

test_clean_partition_reports_no_duplicates() {
    local d="" out=""
    make_shard_sandbox d
    out="$(run_sandbox_manifest "$d" "10-a.sh 20-b.sh")"
    assert_contains "$out" "DUPES:" "the duplicate check runs"
    assert_not_contains "$out" "DUPES:Alpha" "a clean partition reports no duplicate"
}

# The real corpus must satisfy it too — the fixtures prove the check works, this
# proves the repo passes it.
test_real_shards_have_no_duplicate_stages() {
    local dupes
    dupes="$("$REAL_BASH" -c '
        set -uo pipefail
        SCRIPT_DIR="$1"
        source "$SCRIPT_DIR/lib/shards.sh"
        run_stage() { shard_record_stage "$@"; }
        source_shards "$SCRIPT_DIR/shards" $2
        shard_duplicate_stages
    ' _ "$SCRIPT_DIR" "$(manifest_of "$RUN_ALL")" 2>&1)"
    assert_equals "" "$dupes" "no stage is claimed by two shards in the real manifest"
}

# --- the real corpus is wired and non-trivial -------------------------------

test_real_manifest_is_parseable_and_complete() {
    local manifest
    manifest="$(manifest_of "$RUN_ALL")"
    assert_not_empty "$manifest" "run-all.sh declares a SHARDS manifest this gate can read"
    # Every declared shard exists, and every file on disk is declared. Asserted
    # through the real helpers so this fails if either direction regresses.
    local out
    out="$("$REAL_BASH" -c '
        set -uo pipefail
        SCRIPT_DIR="$1"
        source "$SCRIPT_DIR/lib/shards.sh"
        run_stage() { shard_record_stage "$@"; }
        source_shards "$SCRIPT_DIR/shards" $2
        printf "UNWIRED:%s\n" "$(shard_unwired | command tr "\n" " ")"
        printf "MISSING:%s\n" "$(shard_missing | command tr "\n" " ")"
    ' _ "$SCRIPT_DIR" "$manifest" 2>&1)"
    # Asserted as exact empty-valued lines. `assert_contains "UNWIRED: "` (with a
    # trailing space) was the first spelling and was WRONG in the silent
    # direction: `tr` emits nothing for empty input, so the healthy output is
    # `UNWIRED:` with no space — the assertion failed on a correct tree, and had
    # the polarity been reversed it would have passed on a broken one.
    assert_contains "$out" "UNWIRED:
" "no shard file on disk is missing from the manifest"
    assert_contains "$out" "MISSING:" "no manifest entry lacks a file on disk"
    assert_not_contains "$out" "UNWIRED:1" "no real shard is reported unwired"
    assert_not_contains "$out" "MISSING:1" "no real manifest entry is reported missing"
}

test_real_shards_claim_every_stage() {
    local stages n
    stages="$(collect_stages)"
    n="$(command printf '%s' "$stages" | command grep -c . | command tr -d '[:space:]')"
    # A floor, not an exact count: the suite grows, and pinning the number would
    # make every added gate edit this file for no safety. What matters is that
    # the shards claim a real corpus rather than silently collapsing to a few.
    assert_true "[ '$n' -gt 80 ]" \
        "the shards jointly claim the full stage corpus (claimed $n)"
}

# Each shard must be independently runnable — that is the whole premise of the
# matrix. Asserted structurally (a shard names at least one gate) rather than by
# running them, which would cost the full suite three times over.
test_each_shard_is_non_empty() {
    local f base n
    for f in "$SHARD_DIR"/*.sh; do
        base="${f##*/}"
        n="$(command grep -c '^[[:space:]]*run_stage ' "$f" | command tr -d '[:space:]')"
        assert_true "[ '$n' -gt 0 ]" "$base dispatches at least one stage (an empty shard is a job that proves nothing)"
    done
}

# --- the default path still runs everything (AC1) ---------------------------

# `bash tests/run-all.sh` with no arguments must select ALL shards, or `just
# test` and the lefthook pre-push hook quietly start testing a third of the tree.
# Asserted on the selection logic, driven with a stub, rather than by running the
# suite.
test_default_invocation_selects_every_shard() {
    assert_file_defines "$RUN_ALL" 'SELECTED="$SHARDS"' \
        "with no --shard flag, the default selection is the full manifest"
}

test_unknown_shard_is_a_hard_error() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && "$REAL_BASH" "$RUN_ALL" --shard 99-nope 2>&1)" || rc=$?
    assert_true "[ '$rc' -ne 0 ]" "an unknown --shard exits non-zero (exit $rc)"
    assert_contains "$out" "unknown shard" "the error names the problem"
    # THE POINT: it must not degrade to running nothing and reporting success —
    # that is the #906 shape, a job green for its whole life without executing.
    assert_not_contains "$out" "All test stages passed" \
        "an unknown shard does NOT report a passing suite"
}

test_shard_flag_without_value_is_a_hard_error() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && "$REAL_BASH" "$RUN_ALL" --shard 2>&1)" || rc=$?
    assert_true "[ '$rc' -ne 0 ]" "--shard with no value exits non-zero (exit $rc)"
}

run_test test_unlisted_shard_is_reported "direction 1: an unlisted shard file on disk is reported"
run_test test_complete_manifest_reports_no_unwired "direction 1 non-vacuity: a complete manifest flags nothing"
run_test test_missing_shard_aborts_loudly "direction 2: a manifest entry with no file aborts loudly"
run_test test_every_gate_script_is_dispatched_by_a_shard "direction 3: every tests/*.sh gate is dispatched by some shard"
run_test test_gate_sweep_corpus_is_non_empty "direction 3 non-vacuity: the sweep inspected a real corpus"
run_test test_duplicate_stage_is_reported "direction 4: a stage claimed by two shards is reported"
run_test test_clean_partition_reports_no_duplicates "direction 4 non-vacuity: a clean partition flags nothing"
run_test test_real_shards_have_no_duplicate_stages "the real manifest has no duplicate stage"
run_test test_real_manifest_is_parseable_and_complete "the real manifest is parseable, wired, and complete"
run_test test_real_shards_claim_every_stage "the real shards claim the full stage corpus"
run_test test_each_shard_is_non_empty "every shard dispatches at least one stage"
run_test test_default_invocation_selects_every_shard "AC1: a bare invocation selects every shard"
run_test test_unknown_shard_is_a_hard_error "an unknown --shard fails loudly, never an empty green run"
run_test test_shard_flag_without_value_is_a_hard_error "--shard with no value fails loudly"

generate_report
