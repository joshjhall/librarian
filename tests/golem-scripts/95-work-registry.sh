# shellcheck shell=bash
# golem-work.sh — background-work registry tests (issue #949, the explicit half
# of #890's liveness signal).
#
# Covers the register/complete lifecycle, the three staleness bounds (dead pid,
# age-out, fail-soft), the jq and no-jq read paths, and the TSV contract
# golem-transcript-liveness.sh consumes.
#
# WHAT THIS FILE IS REALLY DEFENDING. The registry was implemented, reviewed for
# three adversarial cycles, and WITHDRAWN because it regenerated one bug class
# three times — every instance producing the exact symptom #890 exists to remove,
# a working golem reported `idle`. All of them lived in two places:
#
#   * THE TWO-KNOB BOUNDARY. GOLEM_STATUS_DIR and GOLEM_WORKTREE_DIR are
#     independently overridable, and every defect assumed one of them held its
#     default. So the matrices below cross BOTH — a relative AND an absolute
#     status dir, a single- AND a multi-segment worktree dir — because a fixture
#     that only builds the default layout cannot reach the bug at all.
#   * NUMERIC-VS-TEXTUAL VALIDATION. `--pid 0` was rejected by a literal `case`
#     glob, i.e. a STRING compare, so `00`/`000` sailed past it — and `kill -0 00`
#     signals the process group exactly like `kill -0 0`, making the entry
#     unreapable. Hence the padded-zero rows.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / WORK / ...) and sources tests/lib/golem-sandbox.sh for the
# shared plumbing (new_sandbox / make_golem_worktree / plant_work_registry / ...)
# BEFORE this file. This fragment therefore only DEFINES test functions; the
# entry point dispatches them from its explicit ordered run_test list.
#
# WHY THE VERDICT TESTS LIVE NEXT DOOR. The registry is only half of the fix; the
# idle-vs-background-vs-indeterminate decision lives in
# golem-transcript-liveness.sh and is pinned in 90-transcript-liveness.sh. This
# file pins the registry's OWN contract in isolation — what `count` returns, and
# when an entry is reaped — so a break here names the registry, not the
# classifier.

# run_work <sandbox> [args...] — invoke golem-work.sh from inside the sandbox with
# both knobs at their defaults. Captures RUN_RC/RUN_OUT.
#
# GOLEM_ID/AGENT_ID are unset via WORK_ID_SCRUB: this suite may itself be running
# inside a live golem, and an inherited id would make every case assert the
# RUNNER's identity instead of the code's derivation. See the helper's header.
run_work() {
    local sb="$1"
    shift
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" "${WORK_ID_SCRUB[@]/#/-u}" \
            HOME="$sb" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$WORK" "$@" 2>&1)" || RUN_RC=$?
}

# run_work_at <cwd> <worktree-dir> <status-dir> [args...] — the two-knob runner.
# Invokes golem-work.sh from an ARBITRARY cwd with BOTH knobs set explicitly, so
# a single case can place the writer inside a worktree and the reader in the main
# checkout (or somewhere unrelated entirely) while varying the layout.
#
# The cwd is a parameter because it is the whole point: an OBSERVER's ambient
# directory must not influence which registry it reads, and the only way to prove
# that is to move it.
run_work_at() {
    local cwd="$1" wtdir="$2" sd="$3"
    shift 3
    RUN_RC=0
    RUN_OUT="$(cd "$cwd" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" "${WORK_ID_SCRUB[@]/#/-u}" \
            HOME="$cwd" \
            GOLEM_WORKTREE_DIR="$wtdir" \
            GOLEM_STATUS_DIR="$sd" \
            "$REAL_BASH" "$WORK" "$@" 2>&1)" || RUN_RC=$?
}

# As run_work, but with a PATH stripped to a symlink farm that deliberately
# EXCLUDES jq, to drive the no-jq fallback. The farm resolves each tool to an
# ABSOLUTE path first: `command -v` can name a shell FUNCTION (measured — `grep`
# is a function in this container), and symlinking to a bare name yields a
# self-referential link that dies 127 at read time while every assertion stays
# green. BASH_ENV is unset so a profile cannot restore the real PATH.
run_work_nojq() {
    local sb="$1"
    shift
    local stub="$sb/nojq-bin" t d p
    command mkdir -p "$stub"
    for t in bash git date mkdir tr basename dirname cat grep ps sed; do
        p=""
        for d in /usr/bin /bin /usr/local/bin /opt/homebrew/bin; do
            if [ -x "$d/$t" ]; then
                p="$d/$t"
                break
            fi
        done
        [ -n "$p" ] && command ln -sf "$p" "$stub/$t"
    done
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" "${WORK_ID_SCRUB[@]/#/-u}" \
            -uBASH_ENV \
            PATH="$stub" \
            HOME="$sb" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$WORK" "$@" 2>&1)" || RUN_RC=$?
}

# _work_now — current epoch seconds, for age-relative fixtures.
_work_now() {
    command date -u +%s
}

# --- lifecycle --------------------------------------------------------------

# register prints `id=work-<epoch>-<rand>` and the item then counts as open. The
# `id=` key=value shape is the worktree-safe contract (#815): a caller READS it
# rather than eval-ing a command substitution, which a worktree-isolated session
# refuses — silently, yielding an empty string.
test_work_register_opens_item() {
    local sb
    new_sandbox sb
    run_work "$sb" register workflow "review harness" --golem golem-42
    assert_exit 0 "$RUN_RC" "register exits 0"
    assert_contains "$RUN_OUT" "id=work-" "register prints the id as key=value (#815)"
    run_work "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "the registered item counts as open"
}

# complete closes the item with that id, and the reduction stops reporting it.
test_work_complete_closes_item() {
    local sb id
    new_sandbox sb
    run_work "$sb" register bash "suite" --golem golem-42
    id="${RUN_OUT#id=}"
    run_work "$sb" complete "$id" --golem golem-42
    assert_exit 0 "$RUN_RC" "complete exits 0"
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "a completed item is no longer open"
}

# Idempotent by design: a skill's cleanup path may call complete unconditionally,
# and completing an unknown id must not fail the golem's turn.
test_work_complete_unknown_id_is_idempotent() {
    local sb
    new_sandbox sb
    run_work "$sb" complete work-1-dead --golem golem-42
    assert_exit 0 "$RUN_RC" "completing an unknown id is a no-op that exits 0"
}

# `finish` is the documented close verb (#1209): a worktree-isolated session
# refuses any command containing the token `complete`, so that spelling never ran
# in a golem. It must close the item EXACTLY as the alias does — same on-disk
# event, which the reducers and golem-work.schema.json key on. A second item stays
# open so compaction does not truncate the log before the event can be read:
# a count-only assertion would pass even if `finish` wrote a new event name that
# the reducer happened to treat as a close.
test_work_finish_closes_item() {
    local sb id keep reg
    new_sandbox sb
    reg="$sb/.worktrees/.status/golem-42.work.jsonl"
    run_work "$sb" register bash "suite" --golem golem-42
    id="${RUN_OUT#id=}"
    run_work "$sb" register monitor "kept open" --golem golem-42
    keep="${RUN_OUT#id=}"
    run_work "$sb" finish "$id" --golem golem-42
    assert_exit 0 "$RUN_RC" "finish exits 0"
    run_work "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "finish closed exactly the named item"
    run_work "$sb" list --golem golem-42
    assert_contains "$RUN_OUT" "$keep" "the other item is still listed"
    assert_not_contains "$RUN_OUT" "$id" "the finished item is no longer listed"
    assert_contains "$(command cat "$reg")" "\"event\":\"complete\",\"id\":\"$id\"" \
        "finish writes the SAME on-disk event the alias does (schema unchanged)"
}

# `finish` keeps the alias's idempotence on an unknown id. (The alias itself —
# back-compat for callers outside worktree isolation — stays pinned by the #949
# test_work_complete_* cases above, which still dispatch through it.)
test_work_finish_unknown_id_is_idempotent() {
    local sb
    new_sandbox sb
    run_work "$sb" finish work-1-dead --golem golem-42
    assert_exit 0 "$RUN_RC" "finishing an unknown id is a no-op that exits 0"
    # An error must name the spelling a golem can actually run, well-formed —
    # pins the message text no other assertion reads.
    run_work "$sb" finish --golem golem-42
    assert_exit 2 "$RUN_RC" "finish with no id refuses"
    assert_contains "$RUN_OUT" "golem-work finish: need <id>" \
        "the refusal names the documented verb"
    run_work "$sb" finish bogus --golem golem-42
    assert_exit 2 "$RUN_RC" "finish with a malformed id refuses"
    assert_contains "$RUN_OUT" "golem-work finish: invalid id 'bogus'" \
        "the invalid-id refusal names the documented verb too"
}

# The bug was a DOC bug as much as a CLI one: the script worked, the documented
# spelling was refused. So pin the docs. Corpus = every workflow skill plus the
# workflow README; dev-core's loop contracts use `complete` as a STATUS value and
# are rightly out (unbackticked, as orchestrate's prose uses it, never matches).
# Three shapes, all live before #1209: the full command
# (`golem-work.sh complete {id}`), the bare backticked verb beside a `register`
# (`register workflow`/`complete`), and a backticked verb WITH its argument in a
# span of its own (`...register bash ...` then `complete {id}`) — the last two
# a golem-work-anchored grep missed. The one sentence that names the old verb to
# explain the rename (two lines of background-work.md) is exempted by its exact
# phrasing in that file only, and the exemption is counted: a third exempted
# line — say a runnable recipe that merely mentions `builtin` — fails rather
# than hides.
test_work_docs_never_show_refused_verb() {
    local root="$REPO_ROOT/plugins/workflow" corpus raw hits exempt n
    local md_re='golem-work\.sh[^`]*[[:space:]]complete([[:space:]]|$)|`complete([[:space:]][^`]*)?`'
    # shellcheck disable=SC2016  # literal fixture line, never expanded
    n="$(printf '%s\n' '`golem-work.sh register bash "x" --pid {pid}` then `complete {id}`' |
        command grep -cE "$md_re" || true)"
    assert_equals "1" "$n" "markdown regex fires on a backticked verb carrying its argument"
    corpus="$(command find "$root/skills" "$root/README.md" -name '*.md' -type f)"
    n="$(printf '%s\n' "$corpus" | command grep -c .)"
    assert_true "[ \"$n\" -ge 10 ]" "the doc corpus is non-empty (found $n files)"
    # shellcheck disable=SC2086  # word-split the newline-separated file list
    raw="$(command grep -nE "$md_re" $corpus || true)"
    exempt='/golem/background-work\.md:[0-9]+:(Spell it `finish`, never `complete` \(#1209\)|bash.s string-evaluating `complete` builtin)'
    hits="$(printf '%s\n' "$raw" | command grep -vE "$exempt" | command grep . || true)"
    assert_equals "" "$hits" "no workflow doc shows the refused \`complete\` verb"
    n="$(printf '%s\n' "$raw" | command grep -cE "$exempt" || true)"
    assert_equals "2" "$n" "exactly the two lines of the #1209 rename sentence are exempted"
    # The COMMAND form is wrong in any workflow file of any type — a schema
    # description or a script comment instructs a golem just as a skill does (the
    # orchestrate schema still named it after the markdown sweep). Only the
    # script that defines the alias may spell it, to explain the rename. Two
    # regexes, split by file type: in a script or doc the gap may cross quotes —
    # a quoted "${CLAUDE_PLUGIN_ROOT}/scripts/golem-work.sh" path, or a quoted
    # option before the verb — and stops only at a backtick span; in JSON it
    # must also stop at `"`, or one string's verb would match the next string.
    local text_re='golem-work\.sh[^`]*[[:space:]]complete([[:space:]`"]|$)' line
    local json_re='golem-work\.sh"?[^`"]*[[:space:]]complete([[:space:]`"]|$)'
    # shellcheck disable=SC2016  # literal fixture lines, never expanded
    for line in \
        'golem-work.sh complete {id}' \
        '"${CLAUDE_PLUGIN_ROOT}/scripts/golem-work.sh" complete "$id"' \
        'golem-work.sh --golem "$g" complete "$id"' \
        '<skill-base-dir>/../../scripts/golem-work.sh complete'; do
        n="$(printf '%s\n' "$line" | command grep -cE "$text_re" || true)"
        assert_equals "1" "$n" "command-form regex fires on: $line"
    done
    # shellcheck disable=SC2016  # literal fixture lines, never expanded
    for line in \
        'golem-work.sh finish {id}' \
        '`golem-work.sh register bash "x" --pid {pid}` then `finish {id}`'; do
        n="$(printf '%s\n' "$line" | command grep -cE "$text_re" || true)"
        assert_equals "0" "$n" "command-form regex stays quiet on: $line"
    done
    # shellcheck disable=SC2016  # literal fixture line, never expanded
    n="$(printf '%s\n' '"`golem-work.sh finish` (which writes this `complete` event)"' |
        command grep -cE "$json_re" || true)"
    assert_equals "0" "$n" "JSON command-form regex stays quiet on the schema's event note"
    # shellcheck disable=SC2016  # literal fixture line, never expanded
    n="$(printf '%s\n' '"description": "`golem-work.sh complete` is idempotent"' |
        command grep -cE "$json_re" || true)"
    assert_equals "1" "$n" "JSON command-form regex fires on the pre-#1209 schema shape"
    # Vacuity control, structural rather than content-anchored: the walk must
    # reach the files that name the script at all (13 at #1209), so a wrong
    # \$root cannot read as a clean tree — and no single comment's wording holds
    # the test up.
    n="$(command grep -rlE 'golem-work\.sh' "$root" | command grep -c . || true)"
    assert_true "[ \"$n\" -ge 10 ]" "the command-form scan reaches the files naming golem-work.sh (found $n)"
    raw="$(command grep -rnE "$text_re" "$root" --exclude='*.json' || true)
$(command grep -rnE "$json_re" "$root" --include='*.json' || true)"
    # The exemption is the rename note's COMMENT lines in golem-work.sh, counted —
    # not the whole file, whose usage heredoc is exactly what a golem reads.
    local note_re='/scripts/golem-work\.sh:[0-9]+:#'
    hits="$(printf '%s\n' "$raw" | command grep -vE "$note_re" | command grep . || true)"
    assert_equals "" "$hits" "no workflow file of any type spells the refused command form"
    n="$(printf '%s\n' "$raw" | command grep -cE "$note_re" || true)"
    assert_equals "1" "$n" "exactly one golem-work.sh comment line (the rename note) is exempted"
    # And the usage text itself advertises `finish`, never the refused command.
    RUN_OUT="$("$REAL_BASH" "$WORK" 2>&1 || true)"
    assert_contains "$RUN_OUT" "  finish <id> [--golem G]" "usage advertises the finish verb"
    assert_not_contains "$RUN_OUT" "golem-work.sh complete" "usage never shows the refused command"
}

# Same class as #1209 with a different trigger: an argument VALUE, not the verb
# (#1241). A worktree-isolated session refuses any command whose text contains a
# git operation it cannot verify stays in-tree, quoted description included, so
# `register bash "git push"` never runs in a golem. Corpus = every file under
# plugins/workflow of any type, as for the command form above. The word boundary
# before `git` is spelled as a class, not `\b`, to stay BSD-clean; each quote
# style bounds its own description, so an apostrophe inside "..." still matches.
# Line-oriented: a description wrapped onto the line after `register <kind>` is
# out of scope (no doc wraps one today). It keys on `git <word-or-flag>`, not a
# bare `git`: measured live, isolation accepted `register bash "push via git"`.
# `register` takes its flags anywhere, so flag/value pairs may precede the kind.
test_work_docs_never_show_git_in_description() {
    local root="$REPO_ROOT/plugins/workflow" re raw n line
    local git='git[[:space:]]+[a-z-]' edge='[^[:alnum:]_-]'
    local flags='([[:space:]]+--[a-z-]+[[:space:]]+[^[:space:]]+)*'
    re="register${flags}[[:space:]]+[a-z]+[[:space:]]+(\"([^\"]*$edge)?$git|'([^']*$edge)?$git)"
    # shellcheck disable=SC2016  # literal fixture lines, never expanded
    for line in \
        '<skill-base-dir>/../../scripts/golem-work.sh register bash "git push" --pid {pid}' \
        '`golem-work.sh register monitor "wait on git fetch"` then `finish {id}`' \
        "golem-work.sh register bash 'git push -u origin HEAD'" \
        "golem-work.sh register bash \"golem's git push\"" \
        'golem-work.sh register bash "Git Push"' \
        'golem-work.sh register bash "git -C repo push" --pid {pid}' \
        'golem-work.sh register bash "git --no-pager log"' \
        'golem-work.sh register --pid {pid} bash "git push"' \
        'golem-work.sh register --golem golem-7 --pid 42 monitor "git fetch"'; do
        n="$(printf '%s\n' "$line" | command grep -ciE "$re" || true)"
        assert_equals "1" "$n" "git-in-description regex fires on: $line"
    done
    # shellcheck disable=SC2016  # literal fixture lines, never expanded
    for line in \
        'golem-work.sh register bash "pre-push suite" --pid {pid}' \
        'golem-work.sh register workflow "review harness"' \
        'golem-work.sh register bash "Digit sum"' \
        'golem-work.sh register bash "push via git" --pid {pid}' \
        'golem-work.sh register --pid {pid} bash "pre-push suite"' \
        "golem-work.sh register bash \"golem's suite\" --pid {pid}" \
        'golem-work.sh register bash "run-all.sh" --pid 12345'; do
        n="$(printf '%s\n' "$line" | command grep -ciE "$re" || true)"
        assert_equals "0" "$n" "git-in-description regex stays quiet on: $line"
    done
    # Vacuity control: the walk must reach register calls that HAVE a quoted
    # description, or a wrong $root reads as a clean tree. Floor = the count at
    # #1241; a doc dropping an example lowers it deliberately, in the same diff.
    n="$(command grep -rhE "register${flags}[[:space:]]+[a-z]+[[:space:]]+[\"']" "$root" | command grep -c . || true)"
    assert_true "[ \"$n\" -ge 5 ]" "the scan reaches documented register descriptions (found $n)"
    raw="$(command grep -rniE "$re" "$root" || true)"
    assert_equals "" "$raw" "no workflow file shows a register description containing a git command"
}

# Two opens and one close leaves exactly one — the reduction matches on id, so a
# close cannot take the wrong item with it.
test_work_multiple_items_counted_independently() {
    local sb first
    new_sandbox sb
    run_work "$sb" register bash "one" --golem golem-42
    first="${RUN_OUT#id=}"
    run_work "$sb" register monitor "two" --golem golem-42
    run_work "$sb" count --golem golem-42
    assert_equals "2" "$RUN_OUT" "both items are open"
    run_work "$sb" complete "$first" --golem golem-42
    run_work "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "completing one leaves the other open"
}

# --- bound 1: dead pid ------------------------------------------------------

# An entry whose pid no longer exists is dropped ON READ — no cleanup daemon, and
# a crashed golem self-heals on the next sweep. This is the bound that makes a
# crash recover in seconds rather than after the hour-long age-out.
test_work_dead_pid_is_reaped() {
    local sb now dead
    new_sandbox sb
    now="$(_work_now)"
    # A pid VERIFIED unsignalable, not merely one that was spawned and reaped.
    # The inline `(exit 0) & dead=$!; wait` idiom asserts an OS fact this test
    # does not control, and it was measured failing here under a full suite run
    # (Expected '0' / Actual '1'). See dead_pid's header.
    dead_pid dead || {
        skip_test "could not obtain a verifiably dead pid"
        return 0
    }
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "dead job" "$now" "$dead")"
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "an entry whose pid is gone is reaped on read"
}

# The mirror: a LIVE pid is kept. Without this the reaper could pass the test
# above by dropping everything, which is the failure that would restore a false
# idle for every registered golem.
test_work_live_pid_is_not_reaped() {
    local sb now live
    new_sandbox sb
    now="$(_work_now)"
    # A pid VERIFIED signalable — the mirror of dead_pid's precondition check.
    live_pid live || {
        skip_test "could not start a verifiably live child"
        return 0
    }
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "live job" "$now" "$live")"
    run_work "$sb" count --golem golem-42
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    assert_equals "1" "$RUN_OUT" "an entry whose pid is alive is kept"
}

# --- bound 2: age-out -------------------------------------------------------

# THE ACCEPTANCE CRITERION IN ITS OWN RIGHT: a leaked entry must not be able to
# pin a golem to `working` forever. The pid here is ALIVE, so only the age bound
# can drop it — which is what makes this a test of the age bound rather than of
# the reaper.
test_work_aged_out_entry_is_reaped() {
    local sb old live
    new_sandbox sb
    old="$(($(_work_now) - 7200))" # 2h, past the 3600 default
    # The pid must be VERIFIABLY alive for this to test the AGE bound rather
    # than accidentally re-testing the pid bound: if the child were not running,
    # the entry would be reaped for the wrong reason and the case would pass
    # while asserting nothing about age.
    live_pid live || {
        skip_test "could not start a verifiably live child"
        return 0
    }
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "leaked" "$old" "$live")"
    run_work "$sb" count --golem golem-42
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    assert_equals "0" "$RUN_OUT" "an entry past GOLEM_WORK_MAX_AGE is reaped even with a live pid"
}

# The bound is env-overridable, and the override is read by the READER — the
# entry carries no ambient knowledge of it.
test_work_max_age_is_env_overridable() {
    local sb old
    new_sandbox sb
    old="$(($(_work_now) - 100))"
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "recent" "$old")"
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" "${WORK_ID_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status GOLEM_WORK_MAX_AGE=50 \
            "$REAL_BASH" "$WORK" count --golem golem-42 2>&1)"
    assert_equals "0" "$RUN_OUT" "a tighter GOLEM_WORK_MAX_AGE reaps a younger entry"
}

# A per-entry max_age recorded at registration WINS over the ambient default, so
# a caller that knows its job is long is not reaped early.
test_work_per_entry_max_age_wins() {
    local sb old
    new_sandbox sb
    old="$(($(_work_now) - 5000))" # past the 3600 default...
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "long job" "$old" "" 99999)"
    run_work "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "a per-entry max_age overrides the ambient default"
}

# --- bound 3: fail-soft -----------------------------------------------------

# `count` must ALWAYS print an integer and ALWAYS exit 0. A consumer that had to
# branch on an error would eventually treat the error as "0 open" — which is the
# false idle, arriving through the error path instead of the logic.
test_work_absent_registry_counts_zero() {
    local sb
    new_sandbox sb
    run_work "$sb" count --golem golem-99
    assert_exit 0 "$RUN_RC" "count exits 0 with no registry at all"
    assert_equals "0" "$RUN_OUT" "an absent registry counts zero"
}

# Distinct from the above on purpose: an EMPTY FILE and NO FILE are different
# on-disk states that must read identically. Having both is what pins the
# contract rather than assuming the two paths coincide.
test_work_empty_registry_counts_zero() {
    local sb
    new_sandbox sb
    plant_work_registry "$sb" golem-42 ""
    run_work "$sb" count --golem golem-42
    assert_exit 0 "$RUN_RC" "count exits 0 on an empty registry"
    assert_equals "0" "$RUN_OUT" "an empty registry counts zero"
}

# The file is append-only and grown by interruptible writers, so ONE torn line
# must be skipped rather than aborting the whole read — otherwise a single
# partial append blinds the signal entirely.
test_work_tolerates_malformed_lines() {
    local sb now
    new_sandbox sb
    now="$(_work_now)"
    plant_work_registry "$sb" golem-42 \
        "$(command printf '%s\n%s\n%s' \
            "$(work_register_line work-1-aaaa bash "good one" "$now")" \
            '{"event":"register","id":' \
            "$(work_register_line work-2-bbbb bash "good two" "$now")")"
    run_work "$sb" count --golem golem-42
    assert_equals "2" "$RUN_OUT" "a torn line is skipped; both intact entries still count"
}

# --- the TSV contract -------------------------------------------------------

# An absent pid is emitted as `-`, NOT as an empty column. TAB is IFS whitespace,
# so `read` COLLAPSES a run of them: an empty column shifts every later field
# left, and the description lands in $pid — measured. A numeric description would
# then be probed as a pid.
test_work_list_uses_dash_for_absent_pid() {
    local sb now
    new_sandbox sb
    now="$(_work_now)"
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "no pid here" "$now")"
    run_work "$sb" list --golem golem-42
    assert_contains "$RUN_OUT" "no pid here" "the description survives to the last column"
    # The real property: the description is the LAST field, so it cannot have
    # shifted left into the pid column.
    assert_true "[ \"\$(command printf '%s' \"$RUN_OUT\" | command awk -F'\\t' '{print \$NF}')\" = 'no pid here' ]" \
        "the description is the final TSV field (an empty pid column would shift it left)"
    assert_true "[ \"\$(command printf '%s' \"$RUN_OUT\" | command awk -F'\\t' '{print \$4}')\" = '-' ]" \
        "an absent pid is the '-' sentinel, never an empty column"
}

# --- the no-jq peer ---------------------------------------------------------

# THE DEFECT THIS PINS (#949): the withdrawn no-jq writer emitted `"pid":007`.
# JSON FORBIDS leading zeros, but `jq` happens to accept it (reading it back as
# 7), so a jq-only assertion passed while a spec-compliant parser rejected the
# whole line. Validated here with python3's json.loads — a DIFFERENT parser than
# the one the writer's own fallback path avoids — which is the only way this
# class of bug is visible at all.
test_work_nojq_write_is_spec_valid_json() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available (needed as the spec-compliant JSON parser)"
        return 0
    fi
    local sb reg
    new_sandbox sb
    run_work_nojq "$sb" register bash "no-jq item" --golem golem-42 --pid 4242 --max-age 90
    assert_exit 0 "$RUN_RC" "the no-jq writer registers successfully"
    reg="$sb/.worktrees/.status/golem-42.work.jsonl"
    assert_file_exists "$reg" "the no-jq path wrote the registry"
    RUN_RC=0
    RUN_OUT="$(command python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        json.loads(line)
print("VALID")
' "$reg" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "every no-jq line parses under a spec-compliant parser (got: $RUN_OUT)"
    assert_contains "$RUN_OUT" "VALID" "the no-jq registry is spec-valid JSON"
}

# The two read paths are PEERS, not a primary and a degraded stub: the registry's
# whole value is being readable by an observer that may run under a stripped
# environment, so they must agree on the same input.
test_work_nojq_read_matches_jq_read() {
    local sb now jq_count jq_list
    new_sandbox sb
    now="$(_work_now)"
    # THREE registers and a COMPLETE, not two bare registers. The shape matters:
    # the reduction's dedup loop only runs when a slot must be dropped, so a
    # fixture with no `complete` never enters it. The weaker fixture this
    # replaces (2 registers, 0 completes) passed while the no-jq reader was
    # reporting the WRONG ITEMS — see the identity assertions below.
    plant_work_registry "$sb" golem-42 \
        "$(command printf '%s\n%s\n%s\n%s' \
            "$(work_register_line work-1-aaaa bash "one" "$now")" \
            "$(work_register_line work-2-bbbb monitor "two" "$now")" \
            "$(work_register_line work-3-cccc workflow "three" "$now")" \
            '{"event":"complete","id":"work-1-aaaa","golem":"golem-42"}')"

    run_work "$sb" count --golem golem-42
    jq_count="$RUN_OUT"
    run_work_nojq "$sb" count --golem golem-42
    assert_equals "$jq_count" "$RUN_OUT" "the no-jq reader agrees with the jq reader"
    assert_equals "2" "$RUN_OUT" "and both see exactly the two still-open items"

    # COUNT PARITY IS NOT ENOUGH, and this is the whole lesson of the defect that
    # prompted these lines. A desynchronized reduction emitted the COMPLETED item
    # and dropped an open one — the count still read 2, so a count-only assertion
    # was green while the identities were swapped. Same-number is not same-answer:
    # assert WHICH items each reader reports.
    run_work "$sb" list --golem golem-42
    jq_list="$RUN_OUT"
    run_work_nojq "$sb" list --golem golem-42
    assert_equals "$jq_list" "$RUN_OUT" \
        "the two readers report the SAME items, not merely the same number"
    assert_contains "$RUN_OUT" "work-2-bbbb" "the open items are listed (work-2)"
    assert_contains "$RUN_OUT" "work-3-cccc" "the open items are listed (work-3)"
    assert_not_contains "$RUN_OUT" "work-1-aaaa" \
        "the COMPLETED item is not reported open by the no-jq reader"
}

# The staleness bounds through the NO-JQ reader (#949 review). Every other bound
# test calls run_work, which leaves PATH intact and therefore exercises the jq
# arm; jq is present in dev and CI, so the no-jq reduction's own age arithmetic
# and field extraction were unverified — in exactly the stripped-PATH environment
# the header calls out as the reason this path must be a full peer rather than a
# degraded stub.
#
# Table-driven over the three bounds so a future arm cannot be added without a
# no-jq counterpart being obvious by its absence.
test_work_nojq_bounds_match_jq_bounds() {
    local sb now old dead
    new_sandbox sb
    now="$(_work_now)"
    old="$((now - 7200))" # past the 3600 default

    # (a) age-out: an old entry is reaped by BOTH readers.
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "leaked" "$old")"
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "jq reader ages out a leaked entry"
    run_work_nojq "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "no-jq reader ages out a leaked entry too"

    # (b) per-entry max_age wins over the ambient default, in both readers.
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "long job" "$((now - 5000))" "" 99999)"
    run_work "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "jq reader honors a per-entry max_age"
    run_work_nojq "$sb" count --golem golem-42
    assert_equals "1" "$RUN_OUT" "no-jq reader honors a per-entry max_age too"

    # (c) dead pid: reaped by both. The pid is VERIFIED dead (see dead_pid).
    dead_pid dead || {
        skip_test "could not obtain a verifiably dead pid"
        return 0
    }
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "dead job" "$now" "$dead")"
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "jq reader reaps a dead pid"
    run_work_nojq "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "no-jq reader reaps a dead pid too"

    # (d) a torn line is skipped rather than aborting the no-jq read.
    plant_work_registry "$sb" golem-42 \
        "$(command printf '%s\n%s\n%s' \
            "$(work_register_line work-1-aaaa bash "good one" "$now")" \
            '{"event":"register","id":' \
            "$(work_register_line work-2-bbbb bash "good two" "$now")")"
    run_work_nojq "$sb" count --golem golem-42
    assert_equals "2" "$RUN_OUT" "no-jq reader skips a torn line and counts both intact entries"
}

# --- numeric validation (the padded-zero defect class) ----------------------

# THE DEFECT, TABLE-DRIVEN. `--pid 0` was guarded by a literal `case "$pid" in 0)`
# — a STRING compare — so `00`/`000` were accepted, and `kill -0 00` signals the
# caller's whole process GROUP exactly like `kill -0 0`. The entry could never be
# reaped and sat `working` until the hour-long age-out: the guard reintroduced the
# bug it was written to close.
#
# Table-driven because the defect is the CLASS, not any one spelling — a guard
# naming only `0` is exactly what shipped and exactly what failed.
test_work_rejects_zero_and_padded_pid() {
    local sb spelling
    new_sandbox sb
    for spelling in 0 00 000 007 0042; do
        run_work "$sb" register bash "t" --golem golem-42 --pid "$spelling"
        assert_exit 2 "$RUN_RC" "--pid '$spelling' is rejected (zero/padded: unreapable, or invalid JSON)"
        assert_contains "$RUN_OUT" "--pid must be" "the rejection names the flag for '$spelling'"
    done
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "no rejected registration was written"
}

# --max-age carried the identical defect, found by grepping outward rather than
# by review. Same table, same reason.
test_work_rejects_zero_and_padded_max_age() {
    local sb spelling
    new_sandbox sb
    for spelling in 0 00 007 0060; do
        run_work "$sb" register bash "t" --golem golem-42 --max-age "$spelling"
        assert_exit 2 "$RUN_RC" "--max-age '$spelling' is rejected"
        assert_contains "$RUN_OUT" "--max-age must be" "the rejection names the flag for '$spelling'"
    done
    run_work "$sb" count --golem golem-42
    assert_equals "0" "$RUN_OUT" "no rejected registration was written"
}

# The guard must not be so eager it rejects legitimate input — a validator that
# refuses everything passes every rejection test above while breaking the feature.
test_work_accepts_canonical_numeric_values() {
    local sb
    new_sandbox sb
    run_work "$sb" register bash "ok" --golem golem-42 --pid 12345 --max-age 60
    assert_exit 0 "$RUN_RC" "a canonical pid and max-age are accepted"
    run_work "$sb" register bash "no flags" --golem golem-42
    assert_exit 0 "$RUN_RC" "both flags remain optional"
}

test_work_rejects_non_numeric_pid() {
    local sb
    new_sandbox sb
    run_work "$sb" register bash "t" --golem golem-42 --pid abc
    assert_exit 2 "$RUN_RC" "a non-numeric pid is rejected"
    run_work "$sb" register bash "t" --golem golem-42 --pid -1
    assert_exit 2 "$RUN_RC" "a negative pid is rejected"
}

# --- the two-knob boundary (where all three withdrawn defects hid) ----------

# THE HEADLINE MATRIX. An OBSERVER — the gate-watch sweep, running anywhere —
# must read the SUBJECT's registry, across every combination of the two
# independently-overridable knobs. Each withdrawn defect made exactly one of
# these rows report zero, and every one of those zeros rendered as `idle`.
#
# `--worktree` is the flag under test: it derives BOTH the golem id and the
# status dir from the subject path, so the two cannot silently disagree.
test_work_observer_reads_subject_across_both_knobs() {
    local sb wt sd_rel abs_status now
    local wtdir
    for wtdir in .worktrees nested/worktrees; do
        new_sandbox sb
        wt="$(make_golem_worktree "$sb" 42 "$wtdir")" || {
            skip_test "git worktree add unavailable"
            return 0
        }
        sd_rel="$wtdir/.status"
        now="$(_work_now)"
        plant_work_registry "$sb" golem-42 \
            "$(work_register_line work-1-aaaa workflow "review harness" "$now")" "$sd_rel"

        # Read from the MAIN checkout.
        run_work_at "$sb" "$wtdir" "$sd_rel" count --worktree "$wt"
        assert_equals "1" "$RUN_OUT" \
            "observer in the main checkout sees the item (GOLEM_WORKTREE_DIR=$wtdir)"

        # Read from an UNRELATED cwd — the sweep's real situation. This is the row
        # a repo_root-based resolution fails: it would resolve the OBSERVER's
        # directory and read an empty registry.
        run_work_at "$WORKDIR" "$wtdir" "$sd_rel" count --worktree "$wt"
        assert_equals "1" "$RUN_OUT" \
            "observer in an unrelated cwd still sees the SUBJECT's item (GOLEM_WORKTREE_DIR=$wtdir)"
    done

    # An ABSOLUTE GOLEM_STATUS_DIR must pass through untouched — joining a repo
    # root onto it would produce a path that exists nowhere, which reads as an
    # empty registry, which reads as idle.
    new_sandbox sb
    wt="$(make_golem_worktree "$sb" 42 nested/worktrees)" || {
        skip_test "git worktree add unavailable"
        return 0
    }
    abs_status="$sb/abs-status"
    command mkdir -p "$abs_status"
    now="$(_work_now)"
    command printf '%s\n' "$(work_register_line work-1-aaaa bash "abs" "$now")" \
        >"$abs_status/golem-42.work.jsonl"
    run_work_at "$WORKDIR" nested/worktrees "$abs_status" count --worktree "$wt"
    assert_equals "1" "$RUN_OUT" "an ABSOLUTE GOLEM_STATUS_DIR is honored, not joined onto a root"
}

# The round trip through the REAL writer, rather than a planted fixture: a golem
# registers from inside its worktree, and an observer elsewhere reads it. This is
# the only case that proves the writer's resolution and the reader's resolution
# actually land on the same file — two independently-correct-looking derivations
# that disagree is precisely how the withdrawn version failed.
test_work_writer_and_observer_agree_on_the_same_file() {
    local sb wt
    new_sandbox sb
    wt="$(make_golem_worktree "$sb" 42 nested/worktrees)" || {
        skip_test "git worktree add unavailable"
        return 0
    }
    # Writer: inside the worktree, id derived from the worktree basename (no
    # --golem), which is how a real golem calls it.
    run_work_at "$wt" nested/worktrees nested/worktrees/.status \
        register workflow "review harness"
    assert_exit 0 "$RUN_RC" "a golem registers from inside its own worktree"
    assert_contains "$RUN_OUT" "id=work-" "the writer minted an id"
    # Observer: unrelated cwd, subject named only by its worktree path.
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status count --worktree "$wt"
    assert_equals "1" "$RUN_OUT" "the observer reads the very file the writer wrote"
}

# The identity derivation must come from the SUBJECT, never from the observer's
# ambient environment. With GOLEM_ID stamped to a DIFFERENT golem — the shape of
# this suite running inside a live golem — a --worktree read must still answer
# about the subject.
test_work_observer_ignores_ambient_golem_id() {
    local sb wt now
    new_sandbox sb
    wt="$(make_golem_worktree "$sb" 42)" || {
        skip_test "git worktree add unavailable"
        return 0
    }
    now="$(_work_now)"
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa bash "subject work" "$now")"
    RUN_OUT="$(cd "$WORKDIR" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_ID=golem-999 AGENT_ID=agent-999 \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$WORK" count --worktree "$wt" 2>&1)"
    assert_equals "1" "$RUN_OUT" \
        "a --worktree read answers about the SUBJECT even when \$GOLEM_ID names another golem"
}

# --- input validation -------------------------------------------------------

test_work_rejects_invalid_kind() {
    local sb
    new_sandbox sb
    run_work "$sb" register frobnicate "t" --golem golem-42
    assert_exit 2 "$RUN_RC" "an unknown kind is rejected"
    assert_contains "$RUN_OUT" "bash|monitor|workflow" "the error names the valid kinds"
}

# The golem id becomes a FILENAME SEGMENT, so a traversal attempt must never
# reach the filesystem.
test_work_rejects_traversal_golem_id() {
    local sb
    new_sandbox sb
    run_work "$sb" register bash "t" --golem "golem-../../etc/passwd"
    assert_exit 2 "$RUN_RC" "a golem id containing path metacharacters is rejected"
}

test_work_unknown_subcommand_fails_loud() {
    local sb
    new_sandbox sb
    run_work "$sb" frobnicate
    assert_true "[ \"$RUN_RC\" != '0' ]" "an unknown subcommand exits non-zero"
    assert_contains "$RUN_OUT" "unknown subcommand" "and says so"
}

# --- malformed invocation vs runtime fail-soft (#949 review) ----------------

# A DANGLING flag must refuse loudly rather than collapse to an empty value.
# Table-driven across every flag and subcommand, because the defect is the CLASS:
# the original `x="${1:-}"` shape appeared at nine sites, and hardening only the
# one a reviewer happened to name would leave the siblings exposed.
#
# `--worktree` is the sharpest case and the reason this is not cosmetic: its
# whole purpose is to stop an OBSERVER resolving ambiently, so a dangling
# `--worktree` would read the ASKER's registry, find nothing, and print a
# well-formed `0` that renders as `idle` — the exact false verdict, arriving
# through the argument parser.
test_work_dangling_flag_refuses() {
    local sb spec
    new_sandbox sb
    for spec in \
        "register:bash:job:--pid" \
        "register:bash:job:--max-age" \
        "register:bash:job:--golem" \
        "complete:work-1-aaaa:--golem" \
        "finish:work-1-aaaa:--golem" \
        "count:--worktree" \
        "count:--golem" \
        "count:--status-dir" \
        "list:--worktree" \
        "list:--golem"; do
        # ':' -> argument boundary; the trailing field is the dangling flag.
        local old_ifs="$IFS"
        IFS=':'
        # shellcheck disable=SC2086  # deliberate word-split on the ':' spec
        set -- $spec
        IFS="$old_ifs"
        run_work "$sb" "$@"
        assert_exit 2 "$RUN_RC" "dangling flag refuses: golem-work $spec"
        assert_contains "$RUN_OUT" "requires a value" \
            "the refusal names the missing value: $spec"
    done
}

# THE CONTROL for the case above, and the reason it does not weaken `count`'s
# fail-soft contract. A RUNTIME condition — nothing registered, a golem that does
# not exist, a --worktree that is not a golem worktree, an explicit empty string
# — must still print an integer and exit 0. Only a MALFORMED INVOCATION refuses.
test_work_count_stays_fail_soft_on_runtime_conditions() {
    local sb
    new_sandbox sb
    run_work "$sb" count --golem golem-does-not-exist
    assert_exit 0 "$RUN_RC" "an unknown golem is a runtime condition, not an error"
    assert_equals "0" "$RUN_OUT" "and counts zero"

    run_work "$sb" count --worktree "$sb/not-a-worktree"
    assert_exit 0 "$RUN_RC" "a non-worktree path stays fail-soft"
    assert_equals "0" "$RUN_OUT" "and counts zero"

    # An explicit empty STRING is an argument, not a dangling flag.
    run_work "$sb" count --worktree ""
    assert_exit 0 "$RUN_RC" "an explicit empty --worktree value stays fail-soft"
    assert_equals "0" "$RUN_OUT" "and counts zero"
}

# cmd_list's observer flags exercised DIRECTLY (#949 review). Every other
# observer test drives `count`; `list` shares work_observe_target but has its own
# argument loop and its own error arm, so a break there would be invisible.
test_work_list_observer_flags() {
    local sb wt now
    new_sandbox sb
    wt="$(make_golem_worktree "$sb" 42 nested/worktrees)" || {
        skip_test "git worktree add unavailable"
        return 0
    }
    now="$(_work_now)"
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "review harness" "$now")" \
        "nested/worktrees/.status"

    # --worktree resolves BOTH halves from the subject, read from an unrelated cwd.
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status list --worktree "$wt"
    assert_exit 0 "$RUN_RC" "list --worktree exits 0"
    assert_contains "$RUN_OUT" "work-1-aaaa" "list --worktree reads the SUBJECT's registry"
    assert_contains "$RUN_OUT" "review harness" "and renders the description"

    # A path that is not a golem worktree is a usage error for `list` (unlike
    # `count`, which is contractually fail-soft).
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status list --worktree "$sb/nope"
    assert_exit 2 "$RUN_RC" "list refuses a non-golem-worktree path"
    assert_contains "$RUN_OUT" "not a golem worktree" "and says why"
}

# --- cmd_complete + cmd_list validation branches (#949 review cycle 2) -------

# `complete`'s own input validation, mirroring the register-side cases. The id
# becomes a match key rather than a path, but it is validated to the same
# charset for the same reason: a malformed key silently matches nothing, and
# "matched nothing" is indistinguishable from "already closed" — so the failure
# would be a completed-looking no-op while the entry stays open and pins a false
# `background`.
test_work_complete_rejects_malformed_id() {
    local sb
    new_sandbox sb
    run_work "$sb" complete not-work-shaped --golem golem-42
    assert_exit 2 "$RUN_RC" "an id that is not work-* is rejected"
    assert_contains "$RUN_OUT" "invalid id" "and says so"

    run_work "$sb" complete "work-../../etc/passwd" --golem golem-42
    assert_exit 2 "$RUN_RC" "an id carrying path metacharacters is rejected"
    assert_contains "$RUN_OUT" "invalid id" "and says so"

    run_work "$sb" complete work-1-aaaa work-2-bbbb --golem golem-42
    assert_exit 2 "$RUN_RC" "a second positional id is rejected"
    assert_contains "$RUN_OUT" "too many arguments" "and says so"
}

# `list` takes no positional arguments, so a stray one is a usage error rather
# than something to silently ignore — an ignored argument is a caller who thinks
# they filtered the output and did not.
test_work_list_rejects_positional_argument() {
    local sb
    new_sandbox sb
    run_work "$sb" list foo --golem golem-42
    assert_exit 2 "$RUN_RC" "a stray positional argument is rejected"
    assert_contains "$RUN_OUT" "unexpected argument" "and says so"
}

# work_compact truncates the registry once nothing is open, which is what keeps
# an append-only log from growing without bound. ASSERT THE FILE, not the count:
# `count` reads 0 through the reduction whether or not the bytes were actually
# removed, so a count-only assertion cannot tell compaction from a no-op — the
# same same-number-is-not-same-answer trap that let cycle 1's defect through.
test_work_compact_truncates_when_empty() {
    local sb id reg
    new_sandbox sb
    reg="$sb/.worktrees/.status/golem-42.work.jsonl"
    run_work "$sb" register bash "only item" --golem golem-42
    id="${RUN_OUT#id=}"
    assert_true "[ -s '$reg' ]" "the registry has bytes while an item is open"
    run_work "$sb" complete "$id" --golem golem-42
    assert_exit 0 "$RUN_RC" "complete exits 0"
    assert_true "[ ! -s '$reg' ]" \
        "the registry file is TRUNCATED once nothing is open, not merely reduced to 0"
}

# --status-dir used DIRECTLY, with a real value, and its precedence over
# --worktree. Every other observer test reaches the status dir through
# --worktree (which composes id + dir together), so the standalone flag and the
# documented "an explicit flag still wins" composition were both unverified —
# a comment asserting behavior that no test measures.
test_work_status_dir_flag_and_precedence() {
    local sb wt now other
    new_sandbox sb
    wt="$(make_golem_worktree "$sb" 42 nested/worktrees)" || {
        skip_test "git worktree add unavailable"
        return 0
    }
    now="$(_work_now)"
    # The registry --worktree would derive.
    plant_work_registry "$sb" golem-42 \
        "$(work_register_line work-1-aaaa workflow "derived" "$now")" \
        "nested/worktrees/.status"
    # A DIFFERENT status dir holding two items for the same golem.
    other="$sb/other-status"
    command mkdir -p "$other"
    command printf '%s\n%s\n' \
        "$(work_register_line work-2-bbbb bash "explicit one" "$now")" \
        "$(work_register_line work-3-cccc bash "explicit two" "$now")" \
        >"$other/golem-42.work.jsonl"

    # --status-dir alone (no --worktree) reads the literal path given.
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status \
        count --golem golem-42 --status-dir "$other"
    assert_equals "2" "$RUN_OUT" "--status-dir alone reads the registry at that literal path"

    # An explicit --status-dir WINS over what --worktree would have derived.
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status \
        count --worktree "$wt" --status-dir "$other"
    assert_equals "2" "$RUN_OUT" \
        "an explicit --status-dir overrides the dir --worktree would derive"

    # Without the override, --worktree derives its own (1 item), proving the
    # two fixtures are genuinely distinct and the assertion above is not vacuous.
    run_work_at "$WORKDIR" nested/worktrees nested/worktrees/.status \
        count --worktree "$wt"
    assert_equals "1" "$RUN_OUT" \
        "--worktree alone derives the subject's own status dir (the fixtures differ)"
}
