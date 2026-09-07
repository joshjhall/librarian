# shellcheck shell=bash
# Shard sourcing + partition guard for the CI matrix split of run-all.sh (#960).
#
# THE PROBLEM THIS SOLVES. run-all.sh executed ~96 stages strictly in sequence on
# one runner, which was 97% of CI wall clock. Splitting them across a matrix makes
# the job concurrent, but it introduces a failure mode the monolith did not have:
# a stage can stop running while every shard still reports green. Three ways —
#
#   1. a shard file on disk that no manifest lists (its stages never dispatch);
#   2. a listed shard file that was deleted or renamed;
#   3. a stage that belongs to NO shard — the union of the shards drifting below
#      the full stage set, e.g. after a rename touches one list but not the other.
#
# The third is the dangerous one and is unique to sharding: (1) and (2) mirror
# tests/lib/fragments.sh, but a monolith could never lose a stage while looking
# complete, because there was only one list. So this file closes all three, and
# tests/validate-shards.sh drives each with a negative fixture proving it fires.
#
# Same posture, and the same reason, as fragments.sh: a gate that silently
# inspects less than it should is worse than no gate (#538, #571, #766, #906).
#
# WHY AN EXPLICIT ORDERED MANIFEST, NOT A GLOB. Identical to fragments.sh: a glob
# makes adding a file sufficient to run it, so nobody has to say WHERE it runs,
# and a dropped file is indistinguishable from a directory that never had it.
# The manifest is a reviewable artifact.
#
# Usage, from run-all.sh (which has already defined run_stage):
#
#     SHARDS="10-portability.sh 20-golem.sh 30-scanners.sh"
#     source_shards "$SCRIPT_DIR/shards" $SHARDS
#
# Pure bash-3.2 + coreutils. `command`-prefixed tool calls per #443.

# Every stage name claimed by any sourced shard, newline-delimited, in source
# order — populated by the RECORDING run_stage below, not by a second call the
# shard files have to remember to make.
#
# WHY A STUB run_stage RATHER THAN A `declare_stage` COMPANION CALL. The first
# draft had each dispatch say its label twice: once to declare it, once to run
# it. That is two spellings of one fact, and the failure it invites is precisely
# the one this file exists to prevent — edit the run_stage label, forget the
# declare_stage, and the union check compares a stale name against a live one and
# reports a partition hole that is really a typo (or, worse, matches by accident
# and hides a real one). One call site per stage; the recorder is swapped in by
# the caller. Same reason CLAUDE.md gives for one threshold table (#663).
_SHARD_STAGES=""

# The shard currently being sourced, so a stage can be attributed to its file.
_SHARD_CURRENT=""

# Owner map: `stage name<TAB>shard file` pairs, for duplicate reporting.
_SHARD_OWNERS=""

# shard_record_stage <stage-label> [command...]
# A run_stage-compatible recorder. tests/validate-shards.sh aliases run_stage to
# this before sourcing the shards, so the labels can be collected without
# executing a single gate. Extra arguments are accepted and ignored so the
# signature matches run_stage exactly.
shard_record_stage() {
    _SHARD_STAGES="${_SHARD_STAGES}$1
"
    _SHARD_OWNERS="${_SHARD_OWNERS}$1	${_SHARD_CURRENT}
"
}

# source_shards <dir> <file>...
# Source each named shard from <dir>, in order, then register the partition
# guard. Sourcing is fail-loud: a missing or unreadable shard aborts immediately
# rather than letting the suite run with a hole in it.
source_shards() {
    local dir="$1"
    shift
    local f

    if [ ! -d "$dir" ]; then
        command printf 'FATAL: shard directory not found: %s\n' "$dir" >&2
        exit 1
    fi
    if [ "$#" -eq 0 ]; then
        command printf 'FATAL: no shards declared for %s\n' "$dir" >&2
        exit 1
    fi

    for f in "$@"; do
        if [ ! -f "$dir/$f" ]; then
            command printf 'FATAL: declared shard is missing: %s\n' "$dir/$f" >&2
            exit 1
        fi
        _SHARD_CURRENT="$f"
        # shellcheck source=/dev/null  # path is composed at runtime from the caller's list
        source "$dir/$f"
    done
    _SHARD_CURRENT=""

    _SHARD_DIR="$dir"
    _SHARD_DECLARED="$(
        for f in "$@"; do command printf '%s\n' "$f"; done | command sort
    )"
    _SHARD_ON_DISK="$(
        command find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null |
            command sed 's|.*/||' | command sort
    )"
}

# shard_stage_list — print every stage claimed by the sourced shards, in order.
shard_stage_list() {
    command printf '%s' "${_SHARD_STAGES:-}"
}

# shard_owner_of <stage-label> — print the shard file(s) claiming <stage-label>.
shard_owner_of() {
    command printf '%s' "${_SHARD_OWNERS:-}" |
        command grep -F "$1	" |
        command cut -f2
}

# shard_unwired — shard files on disk that no manifest lists.
shard_unwired() {
    command comm -13 <(command printf '%s\n' "${_SHARD_DECLARED:-}") \
        <(command printf '%s\n' "${_SHARD_ON_DISK:-}")
}

# shard_missing — manifest entries with no file on disk.
shard_missing() {
    command comm -23 <(command printf '%s\n' "${_SHARD_DECLARED:-}") \
        <(command printf '%s\n' "${_SHARD_ON_DISK:-}")
}

# shard_duplicate_stages — stages claimed by more than one shard.
#
# A stage in two shards is not merely wasteful: it makes the union check pass
# while a DIFFERENT stage is missing, because a set comparison cannot see the
# double-count. So this is checked separately from the union, on the multiset.
shard_duplicate_stages() {
    command printf '%s' "${_SHARD_STAGES:-}" |
        command grep -v '^$' |
        command sort |
        command uniq -d
}
