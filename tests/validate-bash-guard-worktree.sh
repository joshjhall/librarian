#!/usr/bin/env bash
# Coverage for bash-guard.sh's Rule B — MAIN-SESSION destructive git aimed at
# ANOTHER tree's linked worktree (issue #662).
#
# #662: an orchestrator session ran `git reset --hard` against a golem worktree
# and destroyed uncommitted work. Neither guard stopped it — bash-guard.sh knew
# the verbs but exempted the main session outright, and worktree-guard.sh knew
# worktree scope but is registered only for Write/Edit/MultiEdit/NotebookEdit, so
# it never sees a Bash call (and its direction is the mirror image: it blocks
# golem->main, this is main->golem). Rule B closes that: a main-session
# destructive GIT verb whose resolved target tree is a linked worktree OTHER than
# the caller's own is DENIED.
#
# WHY A SEPARATE SUITE from validate-bash-guard.sh. That suite is deliberately
# fixture-free — inline JSON payloads, no git, no disk — because Rule A's
# discriminator is `agent_id`, a field. Rule B's discriminator is git TOPOLOGY, so
# every case here needs REAL repos on disk (git-dir vs git-common-dir cannot be
# faked without faking the thing under test). Mixing the two would force a git
# fixture onto 68 cases that do not want one. Same split rationale as
# validate-worktree-guard.sh, which builds real topologies for the same reason.
#
# The three properties that carry the risk of a silent regression:
#   1. POSITIVE-BLOCK — main session -> a PEER worktree, in BOTH targeting forms
#      (`git -C <wt>` and `cd <wt> && git`), must DENY. A resolution regression
#      that made this a no-op would silently restore the #662 hazard.
#   2. OWN-TREE + MAIN-TREE SAFETY — a golem resetting ITS OWN worktree, and the
#      human resetting the MAIN checkout, must stay ALLOWED. This is the half a
#      "target is a worktree" rule would break, and it is why the rule compares
#      git-DIRS rather than merely testing worktree-ness.
#   3. POLLING SAFETY — `git -C <wt> status`/`log`/`rev-parse` must stay ALLOWED.
#      An orchestrator polls worktrees routinely; denying that regresses #662's
#      own stated non-goal.
#
# MUTATION CHECKS (AC #5) are the load-bearing part of this file. Every fixture
# below is re-run against two deliberately-broken copies of the hook, because a
# fixture that passes with AND without the fix proves nothing — a class this repo
# has been bitten by repeatedly. Mutant 1 (neutered gate) pins the DENY set;
# Mutant 2 (forced-positive cross-tree test) pins the ALLOW set, which Mutant 1
# structurally cannot reach. See the two mutation sections at the end.
#
# Pure bash + coreutils (+ jq for decision parsing, which skips cleanly when jq
# is absent). Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/plugins/workflow/hooks/bash-guard.sh"
WT_RM="$REPO_ROOT/plugins/workflow/scripts/worktree-rm.sh"

REAL_BASH="$(command -v bash)"
REAL_GIT="$(command -v git)"

# git env that must NOT leak into the fixture or the hook's own `git -C` — else
# the OUTER repo's GIT_DIR pins scope to the wrong tree, and every case here
# would be measuring this repo instead of the sandbox. Same convention as
# validate-worktree-guard.sh / validate-golem-scripts.sh.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "bash-guard.sh Rule B — main-session git into a worktree (#662, #665)"

# --- Fixture: a main checkout + TWO linked worktrees ------------------------
# Two worktrees, not one: the peer-to-peer case (a golem reaching into ANOTHER
# golem's tree) is a real topology in an orchestrate run and must deny, and with
# only one worktree "own" and "peer" cannot be told apart at all.
FIXTURE="$(command mktemp -d)"
trap 'command rm -rf "$FIXTURE"' EXIT

git_clean() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_GIT" "$@"
}

MAIN_DIR="$FIXTURE/repo"
command mkdir -p "$MAIN_DIR"
git_clean -C "$MAIN_DIR" init -q
git_clean -C "$MAIN_DIR" config user.email "test@example.com"
git_clean -C "$MAIN_DIR" config user.name "Test"
printf 'seed\n' >"$MAIN_DIR/seed.txt"
git_clean -C "$MAIN_DIR" add seed.txt
git_clean -C "$MAIN_DIR" -c commit.gpgsign=false commit -qm seed

WT_DIR="$MAIN_DIR/.worktrees/issue-1"
WT2_DIR="$MAIN_DIR/.worktrees/issue-2"
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-1 "$WT_DIR" >/dev/null 2>&1
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-2 "$WT2_DIR" >/dev/null 2>&1

# Canonicalize (mktemp under /tmp may be a symlink to /private/tmp on macOS); the
# hook resolves roots with `cd … && pwd`, so compare against the same.
MAIN_DIR="$(cd "$MAIN_DIR" && pwd)"
WT_DIR="$(cd "$WT_DIR" && pwd)"
WT2_DIR="$(cd "$WT2_DIR" && pwd)"

# --- Runner -----------------------------------------------------------------
# run_guard <cwd> <command> [guard-path] — build a main-session PreToolUse payload
# (NO agent_id: Rule B's caller signal) and pipe it to the hook with git env
# scrubbed. <guard-path> defaults to the real hook; the mutation sections pass a
# patched copy. Command is JSON-encoded via jq so quotes/backslashes survive.
GUARD_OUT=""
run_guard() {
    local cwd="$1" cmd="$2" guard="${3:-$GUARD}" payload
    payload="$(jq -cn --arg c "$cmd" --arg w "$cwd" \
        '{cwd:$w, tool_name:"Bash", tool_input:{command:$c}}')"
    GUARD_OUT="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$guard" 2>/dev/null)" || true
}

# decision <stdout> — echo the permissionDecision, or "allow" when the hook
# emitted nothing (the allow path).
decision() {
    local out="$1"
    if [ -z "$out" ]; then
        printf 'allow\n'
        return 0
    fi
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'parse-error\n'
}

jq_required() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable"
        return 1
    fi
    return 0
}

# assert_decision <cwd> <command> <want> <desc> [guard] — the workhorse.
assert_decision() {
    local cwd="$1" cmd="$2" want="$3" desc="$4" guard="${5:-$GUARD}"
    run_guard "$cwd" "$cmd" "$guard"
    assert_equals "$want" "$(decision "$GUARD_OUT")" "$desc"
}

# --- AC #1: main-session destructive git into a worktree is DENIED ----------
# Both targeting forms must decide identically: `-C` is what an orchestrator
# actually types (its polling and rebase paths use it), `cd &&` is the natural
# hand-typed alternative. A cwd-only implementation passes the second and fails
# the first, which is precisely the realistic case.
test_deny_reset_hard_dashC() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR reset --hard" deny \
        "main-session \`git -C <wt> reset --hard\` is DENIED (the #662 incident)"
}
test_deny_reset_hard_cd() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "cd $WT_DIR && git reset --hard" deny \
        "main-session \`cd <wt> && git reset --hard\` is DENIED (same decision as -C)"
}
test_deny_reset_hard_relative_dashC() {
    jq_required || return 0
    # A relative -C must resolve against the payload cwd, not be skipped.
    assert_decision "$MAIN_DIR" "git -C .worktrees/issue-1 reset --hard" deny \
        "a RELATIVE \`-C\` resolves against cwd and is DENIED"
}
test_deny_reset_hard_relative_cd() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "cd .worktrees/issue-1 && git reset --hard" deny \
        "a RELATIVE \`cd\` resolves against cwd and is DENIED"
}
test_deny_git_clean() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR clean -fd" deny \
        "main-session \`git -C <wt> clean -fd\` is DENIED"
}
test_deny_git_checkout_dashdash() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR checkout -- seed.txt" deny \
        "main-session \`git -C <wt> checkout -- <file>\` is DENIED"
}
test_deny_chained_after_poll() {
    jq_required || return 0
    # The realistic shape: a poll the orchestrator legitimately runs, with the
    # destructive verb chained after it.
    assert_decision "$MAIN_DIR" "git status && git -C $WT_DIR reset --hard" deny \
        "a destructive verb CHAINED after a legitimate poll is DENIED"
}
test_deny_cd_persists_across_segments() {
    jq_required || return 0
    # A `cd` is a property of the SHELL, not of the next command, so it must still
    # be in effect after an intervening segment. `cd <wt> && git status && git
    # reset --hard` resets the worktree just as surely as the two-segment form.
    assert_decision "$MAIN_DIR" "cd $WT_DIR && git status && git reset --hard" deny \
        "a \`cd\` still applies after an INTERVENING segment (DENY)"
}
test_deny_tilde_path_to_worktree() {
    jq_required || return 0
    # #662 pre-PR review (BLOCKING, dynamically repro'd): a `~`-prefixed operand
    # is not absolute, so before the fix it was glued onto cwd as `<cwd>/~/wt` —
    # a nonexistent path — and the `-d` check fail-opened. The IDENTICAL worktree
    # denied via an absolute path and ALLOWED via `~`. Tilde is a routine idiom,
    # so that was a live silent bypass, not an exotic edge.
    #
    # Needs a worktree genuinely reachable under $HOME, which the shared $FIXTURE
    # (under /tmp) is not — so this case builds its own. Skips rather than
    # silently passing if $HOME is unusable, since a bogus path would fail-open
    # and the test would "pass" while measuring nothing.
    if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
        skip_test "HOME unset or not writable"
        return 0
    fi
    local sb rel
    sb="$(command mktemp -d "$HOME/bgwt-tilde.XXXXXX" 2>/dev/null)" || {
        skip_test "could not create a sandbox under HOME"
        return 0
    }
    git_clean -C "$sb" init -q
    git_clean -C "$sb" config user.email "test@example.com"
    git_clean -C "$sb" config user.name "Test"
    printf 'x\n' >"$sb/f"
    git_clean -C "$sb" add f
    git_clean -C "$sb" -c commit.gpgsign=false commit -qm s
    git_clean -C "$sb" worktree add -q -b tilde-wt "$sb/wt" >/dev/null 2>&1
    rel="${sb#"$HOME"/}"

    # Control: the ABSOLUTE path to this worktree must deny. Without it a `~`
    # allow could be blamed on the sandbox rather than on tilde handling.
    assert_decision "$sb" "git -C $sb/wt reset --hard" deny \
        "control: the same worktree DENIES via an absolute path"
    assert_decision "$sb" "git -C ~/$rel/wt reset --hard" deny \
        "a \`~/\`-prefixed \`-C\` resolves via \$HOME and is DENIED (not silently bypassed)"
    assert_decision "$sb" "cd ~/$rel/wt && git reset --hard" deny \
        "a \`~/\`-prefixed \`cd\` resolves via \$HOME and is DENIED"
    # And the expansion must not over-reach: ~ pointing at a NON-worktree allows.
    assert_decision "$sb" "git -C ~/$rel reset --hard" allow \
        "a \`~/\` path at a PRIMARY checkout still ALLOWS (expansion is not a blanket deny)"

    command rm -rf "$sb"
}
test_deny_peer_to_peer() {
    jq_required || return 0
    # Golem A reaching into golem B's tree. Both are linked worktrees, so this is
    # only catchable by comparing git-DIRS — worktree-ness alone cannot see it.
    assert_decision "$WT_DIR" "git -C $WT2_DIR reset --hard" deny \
        "a golem reaching into a PEER golem's worktree is DENIED"
}
test_deny_reason_is_actionable() {
    jq_required || return 0
    run_guard "$MAIN_DIR" "git -C $WT_DIR reset --hard"
    assert_valid_json "$GUARD_OUT" "deny output is valid JSON"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    assert_contains "$reason" "$WT_DIR" "deny reason names the worktree it blocked"
    assert_contains "$reason" "worktree-rm.sh" "deny reason points at the sanctioned teardown path"
    assert_contains "$reason" "status" "deny reason names the read-only alternative"
}

# --- AC #2: the MAIN checkout stays allowed (unchanged behavior) ------------
# Blocking these would break the human's own session — explicitly out of scope in
# the issue, and the one direction this change must never take.
test_allow_main_reset_hard() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git reset --hard" allow \
        "main-session \`git reset --hard\` in the MAIN checkout stays ALLOWED"
}
test_allow_main_git_clean() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git clean -fd" allow \
        "main-session \`git clean -fd\` in the MAIN checkout stays ALLOWED"
}
test_allow_main_checkout_dashdash() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git checkout -- seed.txt" allow \
        "main-session \`git checkout -- <file>\` in the MAIN checkout stays ALLOWED"
}
test_allow_main_reset_hard_explicit_dashC() {
    jq_required || return 0
    # Naming the main checkout explicitly must decide the same as the bare form.
    assert_decision "$MAIN_DIR" "git -C $MAIN_DIR reset --hard" allow \
        "an explicit \`-C <main>\` stays ALLOWED (same as the bare form)"
}

# --- AC #2 (cont.): a golem's OWN worktree stays allowed -------------------
# THE load-bearing allow. A rule of "the target is a linked worktree" would deny
# these and break every golem — this is why the rule compares git-dirs.
test_allow_dashC_does_not_leak_to_later_git() {
    jq_required || return 0
    # `-C` binds to ITS OWN git invocation. A poll under `-C <wt>` followed by a
    # reset of the MAIN checkout must resolve the reset against cwd, not inherit
    # the poll's `-C`. Getting this wrong denies a legitimate main-checkout reset
    # merely because an earlier command in the same line mentioned a worktree.
    assert_decision "$MAIN_DIR" "git -C $WT_DIR status && git reset --hard" allow \
        "a \`-C\` does NOT leak into a LATER git invocation (stays ALLOW)"
}
test_allow_later_cd_overrides_earlier() {
    jq_required || return 0
    # Last `cd` wins, as the shell would have it.
    assert_decision "$MAIN_DIR" "cd $WT_DIR && cd $MAIN_DIR && git reset --hard" allow \
        "a LATER \`cd\` back to the main checkout overrides an earlier one (ALLOW)"
}
test_deny_explicit_dashC_overrides_cd() {
    jq_required || return 0
    # `-C` beats an ambient `cd`, in both directions: here it re-targets a
    # main-checkout cwd onto the worktree, which must DENY.
    assert_decision "$MAIN_DIR" "cd $MAIN_DIR && git -C $WT_DIR reset --hard" deny \
        "an explicit \`-C <wt>\` overrides an earlier \`cd <main>\` (DENY)"
}
test_deny_repeated_dashC_chains() {
    jq_required || return 0
    # #662 review cycle 2 (BLOCKING, dynamically repro'd): real git treats
    # successive `-C` as chained chdirs, so `-C a -C b` targets `<cwd>/a/b`.
    # Resolving only the LAST operand pointed at `<cwd>/b` instead — and when some
    # unrelated `<cwd>/b` is itself a linked worktree, that is a WRONG-TREE deny
    # (naming a worktree the command never touched), not merely a missed one.
    #
    # The fixture makes the two paths genuinely different worktrees, so a decision
    # that named the wrong one cannot pass: the assertion reads the worktree path
    # out of the deny reason rather than just checking deny-vs-allow.
    # BOTH paths must be real, DIFFERENT worktrees. Building only `a/b` would make
    # the pre-fix code resolve `<cwd>/b` — a path that then does not exist — so it
    # would fail-open to ALLOW and the test would pass against a plain revert while
    # never exercising the historically-real failure: denying by NAMING an
    # unrelated but real worktree (#662 review cycle 3 caught exactly this
    # incomplete fixture).
    git_clean -C "$MAIN_DIR" worktree add -q -b chain-real "$MAIN_DIR/a/b" >/dev/null 2>&1 || {
        skip_test "could not build the chained-C fixture (a/b)"
        return 0
    }
    git_clean -C "$MAIN_DIR" worktree add -q -b chain-decoy "$MAIN_DIR/b" >/dev/null 2>&1 || {
        skip_test "could not build the chained-C decoy (b)"
        return 0
    }
    run_guard "$MAIN_DIR" "git -C a -C b reset --hard"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "chained \`-C a -C b\` into a worktree is DENIED"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    # Assert on the NAMED tree, not deny-vs-allow: with the decoy present, the
    # pre-fix code denies too — just naming the wrong worktree.
    assert_contains "$reason" "$MAIN_DIR/a/b" \
        "chained \`-C\` names the REAL target (<cwd>/a/b)"
    assert_not_contains "$reason" "worktree \`$MAIN_DIR/b\`" \
        "chained \`-C\` does NOT name the decoy (<cwd>/b) — the wrong-tree deny"
    # An ABSOLUTE operand resets the chain, exactly as chdir does.
    run_guard "$MAIN_DIR" "git -C a -C $WT_DIR reset --hard"
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    assert_contains "$reason" "$WT_DIR" \
        "an ABSOLUTE \`-C\` resets the chain rather than appending"
}
test_failopen_chain_poisoned_by_later_var() {
    jq_required || return 0
    # #662 review cycle 3 (BLOCKING, dynamically repro'd): git re-chdirs on EVERY
    # `-C`, so a later unresolvable `-C "$var"` fully re-targets the tree. Trusting
    # the chain accumulated from an earlier LITERAL operand decided about a tree
    # the command may never touch — a wrong-tree DENY here (it named `a/b`).
    # The whole invocation must fall back to the cwd-only fail-open path.
    run_guard "$MAIN_DIR" 'git -C a/b -C "$var" reset --hard'
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "an unresolvable LATER \`-C\` poisons the whole chain (fail-open, not a stale wrong-tree deny)"
}
test_failopen_chain_poisoned_by_earlier_var() {
    jq_required || return 0
    # The REVERSE operand order from the test above. `git_C_bad` is set on the
    # unresolvable branch and never cleared, so an unresolvable FIRST operand must
    # keep poisoning the invocation even though a literal follows it. Distinct
    # code path from later-unresolvable (the flag must SURVIVE a subsequent
    # successful capture rather than merely be set by the last one), and an
    # off-by-one that only poisoned on the final operand would pass the sibling
    # test while failing this one (#662 review cycle 4).
    run_guard "$MAIN_DIR" 'git -C "$var" -C .worktrees/issue-1 reset --hard'
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "an unresolvable EARLIER \`-C\` still poisons the chain (flag survives a later literal)"
}
test_all_three_verbs_share_target_resolution() {
    jq_required || return 0
    # `_rule_b_target` was extracted so the poison/chain rule lives in ONE place
    # for the `-C`-targeted Rule B verbs — the harden-one-knob-grep-every-sibling
    # class. That invariant is only worth stating if it is checked: exercise
    # `clean` and `checkout --` through the SAME shapes `reset --hard` is tested
    # with, so a future edit that special-cases one verb's call site is caught.
    #
    # #665's `worktree remove --force` is deliberately NOT in this loop: it takes
    # its target POSITIONALLY, so it does not share these `-C` shapes at all. It
    # falls back to `_rule_b_target` only when its positional operand is absent
    # or unresolvable, which its own fixtures cover. Adding it here would assert
    # a resolution path it does not use.
    local v
    for v in "clean -fd" "checkout -- seed.txt"; do
        run_guard "$MAIN_DIR" "git -C $WT_DIR $v"
        assert_equals "deny" "$(decision "$GUARD_OUT")" \
            "\`git $v\` into a peer worktree is DENIED (shares target resolution)"
        run_guard "$MAIN_DIR" "git -C a/b -C \"\$var\" $v"
        assert_equals "allow" "$(decision "$GUARD_OUT")" \
            "\`git $v\` honors the poisoned chain (shares target resolution)"
        run_guard "$WT_DIR" "git $v"
        assert_equals "allow" "$(decision "$GUARD_OUT")" \
            "\`git $v\` in its OWN worktree is ALLOWED (shares target resolution)"
    done
}
test_deny_tilde_mid_chain() {
    jq_required || return 0
    # #662 review cycle 3 (BLOCKING, dynamically repro'd): once folded into the
    # chain, a mid-chain tilde becomes `a/~`, which matched neither `~` nor `~/*`
    # at the end, so it was never expanded — it landed on the nonexistent
    # `<cwd>/a/~` and fail-opened. A LEADING tilde only worked by string-shape
    # luck. Expansion is now per-operand, and an expanded (absolute) tilde resets
    # the chain like any absolute operand.
    if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
        skip_test "HOME unset or not writable"
        return 0
    fi
    local sb rel
    sb="$(command mktemp -d "$HOME/bgwt-midchain.XXXXXX" 2>/dev/null)" || {
        skip_test "could not create a sandbox under HOME"
        return 0
    }
    git_clean -C "$sb" init -q
    git_clean -C "$sb" config user.email "test@example.com"
    git_clean -C "$sb" config user.name "Test"
    printf 'x\n' >"$sb/f"
    git_clean -C "$sb" add f
    git_clean -C "$sb" -c commit.gpgsign=false commit -qm s
    git_clean -C "$sb" worktree add -q -b midchain-wt "$sb/wt" >/dev/null 2>&1
    rel="${sb#"$HOME"/}"

    run_guard "$MAIN_DIR" "git -C a -C ~/$rel/wt reset --hard"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a MID-CHAIN \`~/\` operand is expanded and DENIED (not silently fail-opened)"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    assert_contains "$reason" "$sb/wt" \
        "the expanded mid-chain tilde RESETS the chain (names \$HOME/../wt, not <cwd>/a/...)"

    command rm -rf "$sb"
}
test_deny_bare_tilde_operand() {
    jq_required || return 0
    # The `"~")` arm of the expansion `case` (bare tilde, no trailing slash) had no
    # dynamic coverage — a refactor could silently drop it. Needs $HOME to BE a
    # worktree, which is not arrangeable, so assert the observable half: a bare `~`
    # resolves to $HOME (a real directory, hence a decision) rather than being
    # glued onto cwd as the nonexistent `<cwd>/~`.
    if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
        skip_test "HOME unset or missing"
        return 0
    fi
    assert_decision "$MAIN_DIR" "git -C ~ reset --hard" allow \
        "a BARE \`~\` operand resolves to \$HOME (not <cwd>/~) and allows there"
}
test_failopen_git_dir_env_var() {
    jq_required || return 0
    # `GIT_DIR=<wt>/.git git reset --hard` is a documented targeting gap: the env
    # var is not parsed as a Rule B target, so the command resolves against cwd.
    # Pinned so the documented behavior is asserted rather than assumed.
    assert_decision "$MAIN_DIR" "GIT_DIR=$WT_DIR/.git git reset --hard" allow \
        "a \`GIT_DIR=\` env-var target is not detected and fails open (documented gap)"
}
test_failopen_separated_git_dir_flag() {
    jq_required || return 0
    # Likewise the separated `--git-dir <p>` form: consumed as a global option so
    # the VERB is still detected, but never re-parsed as a target.
    assert_decision "$MAIN_DIR" "git --git-dir $WT_DIR/.git reset --hard" allow \
        "a separated \`--git-dir <p>\` target is not detected and fails open (documented gap)"
}
test_allow_own_worktree_bare() {
    jq_required || return 0
    assert_decision "$WT_DIR" "git reset --hard" allow \
        "a golem resetting ITS OWN worktree (bare) stays ALLOWED"
}
test_allow_own_worktree_dashC() {
    jq_required || return 0
    assert_decision "$WT_DIR" "git -C $WT_DIR reset --hard" allow \
        "a golem resetting its own worktree via explicit \`-C\` stays ALLOWED"
}
test_allow_own_worktree_clean() {
    jq_required || return 0
    assert_decision "$WT_DIR" "git clean -fd" allow \
        "a golem running \`git clean\` in its OWN worktree stays ALLOWED"
}
test_allow_own_worktree_subdir() {
    jq_required || return 0
    # cwd deeper than the worktree root still resolves to the same git-dir.
    command mkdir -p "$WT_DIR/sub"
    assert_decision "$WT_DIR/sub" "git reset --hard" allow \
        "a golem in a SUBDIR of its own worktree stays ALLOWED"
}

# --- Scope boundary: the OPPOSITE direction (worktree -> primary) ----------
# Pinned so the boundary is a recorded decision rather than an untested silence.
# Rule B's rule is "target is a linked worktree that is not the caller's own", so
# a target that is a PRIMARY checkout allows regardless of who called — including
# a golem's own main loop reaching into the main checkout. That is deliberate and
# NOT this issue's concern: #662 is main -> golem (the direction with no recovery
# path, since a worktree is dense with uncommitted work). The reverse direction is
# worktree-guard.sh's subject (#475/#501/#506) for Edit/Write, and on the Bash
# surface it stays uncovered by design — the main checkout is committed, pushed,
# and reflogged, so the blast radius is not comparable. Changing this assertion
# means deliberately widening #662's scope.
test_allow_worktree_into_primary_checkout() {
    jq_required || return 0
    assert_decision "$WT_DIR" "git -C $MAIN_DIR reset --hard" allow \
        "worktree -> PRIMARY checkout ALLOWS (out of #662 scope, by design)"
}

# --- AC #3: non-destructive worktree calls stay allowed (polling) ----------
test_allow_poll_status() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR status --porcelain" allow \
        "orchestrator polling \`git -C <wt> status\` stays ALLOWED"
}
test_allow_poll_log() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR log --oneline -5" allow \
        "orchestrator polling \`git -C <wt> log\` stays ALLOWED"
}
test_allow_poll_rev_parse() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR rev-parse HEAD" allow \
        "orchestrator polling \`git -C <wt> rev-parse\` stays ALLOWED"
}
test_allow_poll_diff() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR diff --name-only" allow \
        "orchestrator polling \`git -C <wt> diff\` stays ALLOWED"
}
test_allow_reset_soft_in_worktree() {
    jq_required || return 0
    # `git reset` without --hard is not in the deny-set; the worktree target must
    # not widen it.
    assert_decision "$MAIN_DIR" "git -C $WT_DIR reset HEAD seed.txt" allow \
        "\`git reset\` WITHOUT --hard into a worktree stays ALLOWED"
}
test_allow_checkout_branch_in_worktree() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $WT_DIR checkout main" allow \
        "\`git checkout <branch>\` (no \`--\`) into a worktree stays ALLOWED"
}

# --- Scope: git verbs ONLY (rm/mv/truncate/redirect unchanged) -------------
# The deliberate scope choice. Widening to the full deny-set would deny
# `rm -rf .worktrees/issue-N`, the documented teardown escape hatch.
test_allow_rm_worktree_teardown() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "rm -rf $WT_DIR" allow \
        "main-session \`rm -rf <wt>\` teardown stays ALLOWED (git verbs only)"
}
test_allow_mv_into_worktree() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "mv $WT_DIR/seed.txt $WT_DIR/other.txt" allow \
        "main-session \`mv\` inside a worktree stays ALLOWED (git verbs only)"
}
test_allow_redirect_into_worktree() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "echo x > $WT_DIR/seed.txt" allow \
        "main-session \`>\` into a worktree stays ALLOWED (git verbs only)"
}

# --- Fail-open paths (every resolution failure ALLOWS) ---------------------
# Rule B can only ever ADD a denial. These pin that: each is a way resolution can
# fail, and each must land on allow — the main session's historical behavior.
test_failopen_no_cwd() {
    jq_required || return 0
    local payload out
    payload="$(jq -cn '{tool_name:"Bash", tool_input:{command:"git reset --hard"}}')"
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_equals "allow" "$(decision "$out")" "a payload with NO cwd fails open (allow)"
}
test_failopen_nonexistent_target() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git -C $FIXTURE/does-not-exist reset --hard" allow \
        "a \`-C\` at a nonexistent path fails open (allow)"
}
test_failopen_target_outside_repo() {
    jq_required || return 0
    command mkdir -p "$FIXTURE/plain"
    assert_decision "$MAIN_DIR" "git -C $FIXTURE/plain reset --hard" allow \
        "a \`-C\` at a NON-repo directory fails open (allow)"
}
test_failopen_unresolvable_cd_var() {
    jq_required || return 0
    # A `$var` cd operand cannot be resolved without evaluating the shell, so the
    # target falls back to cwd (the main checkout) -> allow. Documented gap.
    assert_decision "$MAIN_DIR" 'wt=$WT; cd "$wt" && git reset --hard' allow \
        "an unresolvable \`cd \$var\` falls back to cwd (documented gap, allow)"
}
test_failopen_unresolvable_dashC_var() {
    jq_required || return 0
    # The `-C` side of the same gap — pinned separately because `-C` and `cd`
    # capture through DIFFERENT code paths (the git global-option scanner vs the
    # segment-head case), so a fix to one does not imply the other.
    assert_decision "$MAIN_DIR" 'wt=/x; git -C "$wt" reset --hard' allow \
        "an unresolvable \`-C \$var\` falls back to cwd (documented gap, allow)"
}
test_failopen_unresolvable_dashC_cmdsubst() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" 'git -C "$(pwd)/.worktrees/issue-1" reset --hard' allow \
        "an unresolvable \`-C \$(...)\` falls back to cwd (documented gap, allow)"
}
test_failopen_tilde_user_form() {
    jq_required || return 0
    # `~user/...` is deliberately NOT expanded (it would need a passwd lookup), so
    # it fails open. Pinned so the deliberate scope of the tilde fix is visible:
    # `~/` is expanded, `~user/` is not.
    assert_decision "$MAIN_DIR" "git -C ~nobody/wt reset --hard" allow \
        "a \`~user/\` path is NOT expanded and fails open (accepted gap, allow)"
}

# --- AC #4: worktree-rm.sh teardown still works end-to-end -----------------
# The guard must not have broken the sanctioned teardown path. Run the REAL
# script against a throwaway worktree in the fixture and assert it removes both
# the worktree and its branch.
test_worktree_rm_still_works() {
    local sb="$FIXTURE/rmrepo"
    command mkdir -p "$sb"
    git_clean -C "$sb" init -q
    git_clean -C "$sb" config user.email "test@example.com"
    git_clean -C "$sb" config user.name "Test"
    printf 'a\n' >"$sb/a"
    git_clean -C "$sb" add a
    git_clean -C "$sb" -c commit.gpgsign=false commit -qm a
    git_clean -C "$sb" worktree add -q -b feature/issue-77 "$sb/.worktrees/issue-77" >/dev/null 2>&1

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BRANCH_PREFIX=feature/issue- \
            "$REAL_BASH" "$WT_RM" 77 2>&1)" || rc=$?
    assert_equals "0" "$rc" "worktree-rm.sh exits 0 (teardown path still works, AC#4)"
    assert_true "[ ! -e \"$sb/.worktrees/issue-77\" ]" "worktree-rm.sh removed the worktree"
    local br
    br="$(git_clean -C "$sb" branch --list feature/issue-77)"
    assert_output_empty "$br" "worktree-rm.sh deleted the branch"
    assert_contains "$out" "removed worktree" "worktree-rm.sh reported the removal"

    # #665 AC3 — the script's OWN `git worktree remove --force` is now a
    # deny-set verb, so pin WHY the sanctioned path is still unaffected: this
    # guard is a PreToolUse hook on the BASH TOOL, so it only ever inspects the
    # command string a model submits. worktree-rm.sh is invoked as
    # `bash .../worktree-rm.sh N`; the forced remove inside it is a SUBPROCESS of
    # the script and never reaches the hook. Assert that directly — feed the hook
    # the exact invocation shape and require ALLOW. This is the claim the #665
    # decision rests on, so it is pinned by a test, not only by a header comment.
    assert_decision "$MAIN_DIR" "bash $WT_RM 77" allow \
        "#665 AC3: invoking worktree-rm.sh is ALLOWED (its forced remove is a subprocess, not a Bash-tool call)"
    assert_decision "$MAIN_DIR" "$WT_RM 77" allow \
        "#665 AC3: the bare-path invocation of worktree-rm.sh is ALLOWED too"
}

# --- Rule A regression: the subagent rule is untouched by the reordering ----
# The caller gate MOVED (from before the deny-set scan to after it). That is
# exactly the kind of restructure that can silently drop the original rule, so
# re-assert both of its directions here as well.
test_rule_a_subagent_still_denied() {
    jq_required || return 0
    local payload out
    payload="$(jq -cn --arg w "$MAIN_DIR" \
        '{cwd:$w, agent_id:"a1", tool_name:"Bash", tool_input:{command:"rm -rf src/"}}')"
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_equals "deny" "$(decision "$out")" "Rule A: a subagent \`rm -rf\` is still DENIED after the gate move"
}
test_rule_a_subagent_scratch_still_allowed() {
    jq_required || return 0
    local payload out
    payload="$(jq -cn --arg w "$MAIN_DIR" \
        '{cwd:$w, agent_id:"a1", tool_name:"Bash", tool_input:{command:"rm -rf /tmp/scan/out"}}')"
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_equals "allow" "$(decision "$out")" "Rule A: the subagent /tmp scratch carve-out still ALLOWS"
}

# --- No-jq fallback still enforces Rule B ----------------------------------
# base macOS ships no jq, so the pure-bash extractor must reach the same verdict.
# Decision is read WITHOUT jq in the child, so assert on the raw stdout shape.
test_nojq_denies_worktree_reset() {
    local stub="$FIXTURE/stub-bin" payload out
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    command ln -sf "$REAL_GIT" "$stub/git"
    payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s reset --hard"}}' \
        "$MAIN_DIR" "$WT_DIR")"
    out="$(printf '%s' "$payload" |
        /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_contains "$out" '"permissionDecision":"deny"' \
        "no-jq path still DENIES a main-session worktree reset"
}
test_nojq_allows_main_reset() {
    local stub="$FIXTURE/stub-bin" payload out
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    command ln -sf "$REAL_GIT" "$stub/git"
    payload="$(printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' "$MAIN_DIR")"
    out="$(printf '%s' "$payload" |
        /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "no-jq path still ALLOWS a main-checkout reset"
}

# ===========================================================================
# #665 — `git worktree remove --force` joins the Rule B deny-set
# ===========================================================================
# The FORCED form only. Plain `git worktree remove` refuses a dirty tree on its
# own, so it has no unrecoverable work to destroy; denying it would block a safe
# verb and push operators toward `--force`, which is backwards.
#
# TARGET RESOLUTION IS THE WHOLE TEST. `worktree remove` names its target
# POSITIONALLY, unlike the other three verbs which take `-C`. During
# implementation the first draft dropped only ONE token before scanning operands,
# so it read the literal word `remove` as the path — that resolves to a
# nonexistent dir and FAIL-OPENS, i.e. every deny fixture below silently allowed
# while the code looked right. A fixture set that only checked "safe things still
# allow" would have passed that draft, which is why the deny cases are asserted
# per-form rather than once.
test_deny_worktree_remove_force() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree remove --force $WT_DIR" deny \
        "#665 deny: \`git worktree remove --force <peer-wt>\`"
}
test_deny_worktree_remove_f_short() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree remove -f $WT_DIR" deny \
        "#665 deny: the \`-f\` short form"
}
test_deny_worktree_remove_doubled_f() {
    jq_required || return 0
    # `-f -f` is what git demands when the worktree ALSO holds untracked files —
    # i.e. the case with the most to lose, so it must not slip through.
    assert_decision "$MAIN_DIR" "git worktree remove -f -f $WT_DIR" deny \
        "#665 deny: the doubled \`-f -f\` form (untracked-files case)"
    assert_decision "$MAIN_DIR" "git worktree remove --force --force $WT_DIR" deny \
        "#665 deny: the doubled \`--force --force\` form"
}
test_deny_worktree_remove_relative() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree remove --force .worktrees/issue-1" deny \
        "#665 deny: a RELATIVE positional path resolves against cwd"
}
test_deny_worktree_remove_peer_to_peer() {
    jq_required || return 0
    assert_decision "$WT2_DIR" "git worktree remove --force $WT_DIR" deny \
        "#665 deny: peer worktree -> peer worktree"
}
test_deny_worktree_remove_after_dashdash() {
    jq_required || return 0
    # `--` ends option parsing; the path still follows it and must still resolve.
    assert_decision "$MAIN_DIR" "git worktree remove --force -- $WT_DIR" deny \
        "#665 deny: path after a \`--\` separator"
}
test_deny_worktree_remove_chained_after_poll() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree list && git worktree remove --force $WT_DIR" deny \
        "#665 deny: chained after a benign poll"
}
test_deny_worktree_remove_reason_actionable() {
    jq_required || return 0
    run_guard "$MAIN_DIR" "git worktree remove --force $WT_DIR"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    assert_contains "$reason" "worktree-rm.sh" \
        "#665: the deny reason points at the sanctioned teardown script"
    assert_contains "$reason" "$WT_DIR" \
        "#665: the deny reason names the target worktree"
}

# --- #665 scope boundary: the UNforced verb stays allowed -------------------
# This is the deliberate scope decision recorded in the hook header, so it gets a
# fixture rather than only a comment.
test_allow_worktree_remove_unforced() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree remove $WT_DIR" allow \
        "#665 scope: plain \`worktree remove\` (no --force) stays ALLOWED"
}
test_allow_worktree_remove_own_tree() {
    jq_required || return 0
    assert_decision "$WT_DIR" "git worktree remove --force $WT_DIR" allow \
        "#665: a session force-removing its OWN worktree is allowed"
}
test_allow_worktree_remove_primary_target() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" "git worktree remove --force $MAIN_DIR" allow \
        "#665: a PRIMARY-checkout target is allowed (not a linked worktree)"
}
test_allow_worktree_other_subcommands() {
    jq_required || return 0
    # Only `remove` is destructive. `list`/`prune`/`add` must not be swept in by a
    # too-broad `worktree` arm — `list` in particular is what polling uses.
    assert_decision "$MAIN_DIR" "git worktree list --porcelain" allow \
        "#665 scope: \`worktree list\` (polling) stays allowed"
    assert_decision "$MAIN_DIR" "git worktree prune" allow \
        "#665 scope: \`worktree prune\` stays allowed"
    assert_decision "$MAIN_DIR" "git worktree add -f $MAIN_DIR/.worktrees/issue-9" allow \
        "#665 scope: \`worktree add -f\` is not a removal (the -f must not match alone)"
}
test_failopen_worktree_remove_unresolvable_path() {
    jq_required || return 0
    assert_decision "$MAIN_DIR" 'git worktree remove --force $wt' allow \
        "#665 fail-open: an unresolvable \$var positional operand"
    assert_decision "$MAIN_DIR" 'git worktree remove --force $(cat p)' allow \
        "#665 fail-open: an unresolvable command-substitution operand"
}

# ===========================================================================
# MUTATION CHECKS (AC #5)
# ===========================================================================
# A fixture that passes both WITH and WITHOUT the fix proves nothing. Each mutant
# below is a copy of the real hook with ONE behaviour deliberately broken; the
# assertions verify the fixtures above actually flip. If a mutant fails to build
# (its sed anchor no longer matches the source) the test FAILS rather than
# silently measuring an unmutated copy — a mutation check that quietly tests the
# real hook is worse than none, since it reports confidence it never earned.

# mutant_build <name> <sed-expr> — copy the guard, apply the patch, verify it
# actually changed the file, and echo the mutant path. Echoes "" on failure.
mutant_build() {
    # Separate `local` statements on purpose: under `set -u` a single `local a=$1
    # b=$a` cannot reference `a` — the whole statement's assignments are evaluated
    # before any name is bound, so `$a` reads as unset and aborts the suite.
    local name="$1" expr="$2"
    local out="$FIXTURE/mutant-$name.sh"
    command sed "$expr" "$GUARD" >"$out" 2>/dev/null || return 0
    if command cmp -s "$GUARD" "$out"; then
        return 0 # anchor did not match: signal failure with an empty echo
    fi
    printf '%s' "$out"
}

# --- Mutant 1: neuter the caller gate --------------------------------------
# Restore the pre-#662 blanket main-session exemption by making Rule B's `if
# [ -z "$agent_id" ]` block exit immediately. Every DENY fixture must flip to
# ALLOW; any that does not was never testing Rule B.
test_mutation_neutered_gate() {
    jq_required || return 0
    local m
    m="$(mutant_build neutered 's|^    case "$matched" in$|    exit 0\n    case "$matched" in|')"
    assert_not_empty "$m" "mutant 1 built (the caller-gate anchor still matches the source)"
    [ -n "$m" ] || return 0

    # Sanity: the mutant must still be a working hook, not a syntax error — else
    # everything "allows" for the wrong reason and the check is vacuous.
    assert_true "\"$REAL_BASH\" -n \"$m\"" "mutant 1 is syntactically valid (allows are real, not crashes)"

    assert_decision "$MAIN_DIR" "git -C $WT_DIR reset --hard" allow \
        "MUTATION: neutering the gate makes \`-C <wt> reset --hard\` ALLOW (fixture is load-bearing)" "$m"
    assert_decision "$MAIN_DIR" "cd $WT_DIR && git reset --hard" allow \
        "MUTATION: neutering the gate makes \`cd <wt> && reset\` ALLOW (fixture is load-bearing)" "$m"
    assert_decision "$MAIN_DIR" "git -C .worktrees/issue-1 reset --hard" allow \
        "MUTATION: neutering the gate makes the RELATIVE -C form ALLOW" "$m"
    assert_decision "$MAIN_DIR" "git -C $WT_DIR clean -fd" allow \
        "MUTATION: neutering the gate makes \`clean -fd\` ALLOW" "$m"
    assert_decision "$MAIN_DIR" "git -C $WT_DIR checkout -- seed.txt" allow \
        "MUTATION: neutering the gate makes \`checkout --\` ALLOW" "$m"
    assert_decision "$MAIN_DIR" "git status && git -C $WT_DIR reset --hard" allow \
        "MUTATION: neutering the gate makes the CHAINED form ALLOW" "$m"
    assert_decision "$WT_DIR" "git -C $WT2_DIR reset --hard" allow \
        "MUTATION: neutering the gate makes PEER-to-PEER ALLOW" "$m"

    # And Rule A must survive the mutation — proof the mutant broke only Rule B,
    # so the flips above are attributable to the gate and nothing else.
    local payload out
    payload="$(jq -cn --arg w "$MAIN_DIR" \
        '{cwd:$w, agent_id:"a1", tool_name:"Bash", tool_input:{command:"rm -rf src/"}}')"
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$m" 2>/dev/null)" || true
    assert_equals "deny" "$(decision "$out")" \
        "MUTATION: mutant 1 still denies Rule A (it broke ONLY Rule B)"
}

# --- Mutant 2: force the cross-tree check positive -------------------------
# Mutant 1 can only ever prove the DENY set. This one pins the ALLOW set: skip
# the two "is this the caller's own tree" comparisons so ANY worktree target
# denies. The main-checkout and own-worktree fixtures must flip to DENY — which
# is what proves the rule's second clause (`target != own tree`) is actually
# doing work, rather than the whole thing reducing to "target is a worktree".
#
# The patch removes both the primary-checkout early-out and the own-tree
# early-out, i.e. every `|| exit 0` guarding a git-dir comparison.
test_mutation_forced_cross_tree() {
    jq_required || return 0
    local m
    # `#` as the sed delimiter, not `|` — the anchors themselves contain `||`,
    # which would terminate the expression early and silently patch nothing.
    m="$(mutant_build forced 's#^    \[ "$tgt_git" != "$tgt_common" \] || exit 0.*$#    :#; s#^    \[ "$tgt_git" != "$own_git" \] || exit 0.*$#    :#')"
    assert_not_empty "$m" "mutant 2 built (the cross-tree-check anchors still match the source)"
    [ -n "$m" ] || return 0
    assert_true "\"$REAL_BASH\" -n \"$m\"" "mutant 2 is syntactically valid (denies are real, not crashes)"

    assert_decision "$MAIN_DIR" "git reset --hard" deny \
        "MUTATION: forcing the cross-tree check makes a MAIN-checkout reset DENY (allow-fixture is load-bearing)" "$m"
    assert_decision "$MAIN_DIR" "git clean -fd" deny \
        "MUTATION: forcing the cross-tree check makes a MAIN-checkout clean DENY" "$m"
    assert_decision "$WT_DIR" "git reset --hard" deny \
        "MUTATION: forcing the cross-tree check makes a golem's OWN-tree reset DENY (the clause that keeps golems working)" "$m"
    assert_decision "$WT_DIR" "git -C $WT_DIR reset --hard" deny \
        "MUTATION: forcing the cross-tree check makes an explicit own-tree \`-C\` DENY" "$m"

    # Polling must STILL allow under this mutant: it never reaches the git-dir
    # comparisons (no deny-set match), so a flip here would mean the deny-set
    # scope — not the cross-tree check — is what those fixtures actually measure.
    assert_decision "$MAIN_DIR" "git -C $WT_DIR status --porcelain" allow \
        "MUTATION: polling still ALLOWS under mutant 2 (it is gated by the VERB, not the tree)"
    assert_decision "$MAIN_DIR" "rm -rf $WT_DIR" allow \
        "MUTATION: \`rm -rf <wt>\` still ALLOWS under mutant 2 (git-verbs-only scope is independent)"
}

# --- Mutant 3: neuter the #665 worktree-remove arm --------------------------
# Mutants 1 and 2 predate #665 and CANNOT measure it: mutant 1 patches the caller
# gate (so it flips the new fixtures for the OLD rule's reason) and mutant 2
# patches the git-dir comparisons (shared by every verb). Neither would notice if
# the `worktree` arm stopped matching entirely. Per this repo's
# mutate-every-RULE lesson, the rule added by a change needs its OWN mutant —
# the rule with zero failing mutants is exactly the one a mutation round exists
# to find.
#
# The patch makes the arm fall through by breaking its `remove` subcommand test,
# which is the arm's entry condition. Every #665 deny fixture must flip to allow;
# the pre-existing verbs must NOT flip (proof the mutant is scoped to #665).
test_mutation_neutered_worktree_arm() {
    jq_required || return 0
    local m
    m="$(mutant_build wtarm 's#^                    \[ "$_wt_sub" = "remove" \] || continue$#                    continue#')"
    assert_not_empty "$m" "mutant 3 built (the #665 worktree-arm anchor still matches the source)"
    [ -n "$m" ] || return 0
    assert_true "\"$REAL_BASH\" -n \"$m\"" "mutant 3 is syntactically valid (allows are real, not crashes)"

    assert_decision "$MAIN_DIR" "git worktree remove --force $WT_DIR" allow \
        "MUTATION: neutering the arm makes \`--force\` ALLOW (fixture is load-bearing)" "$m"
    assert_decision "$MAIN_DIR" "git worktree remove -f $WT_DIR" allow \
        "MUTATION: neutering the arm makes \`-f\` ALLOW" "$m"
    assert_decision "$MAIN_DIR" "git worktree remove -f -f $WT_DIR" allow \
        "MUTATION: neutering the arm makes \`-f -f\` ALLOW" "$m"
    assert_decision "$MAIN_DIR" "git worktree remove --force .worktrees/issue-1" allow \
        "MUTATION: neutering the arm makes the RELATIVE form ALLOW" "$m"
    assert_decision "$WT2_DIR" "git worktree remove --force $WT_DIR" allow \
        "MUTATION: neutering the arm makes PEER-to-PEER ALLOW" "$m"

    # Scope proof: the three original verbs must survive mutant 3 untouched. If
    # one of these flipped, the mutant is patching something shared and the
    # assertions above would be measuring the wrong rule.
    assert_decision "$MAIN_DIR" "git -C $WT_DIR reset --hard" deny \
        "MUTATION: mutant 3 still denies \`reset --hard\` (it broke ONLY the #665 arm)"
    assert_decision "$MAIN_DIR" "git -C $WT_DIR clean -fd" deny \
        "MUTATION: mutant 3 still denies \`clean\` (it broke ONLY the #665 arm)"
}

# --- Mutant 4: drop the --force requirement ---------------------------------
# The INVERSE direction. Mutant 3 proves the deny fixtures are load-bearing; this
# proves the ALLOW fixture is. Making the arm match regardless of `--force` must
# flip the unforced-remove allow to deny — otherwise that fixture is decoration
# and the documented `--force`-only scope is untested (the
# gate-and-evidence-converge tautology this repo has been bitten by).
test_mutation_force_requirement_dropped() {
    jq_required || return 0
    local m
    m="$(mutant_build wtforce 's#^                        \*" --force "\* | \*" -f "\*) ;;$#                        *) ;;#')"
    assert_not_empty "$m" "mutant 4 built (the --force-test anchor still matches the source)"
    [ -n "$m" ] || return 0
    assert_true "\"$REAL_BASH\" -n \"$m\"" "mutant 4 is syntactically valid (denies are real, not crashes)"

    assert_decision "$MAIN_DIR" "git worktree remove $WT_DIR" deny \
        "MUTATION: dropping the --force test makes the UNFORCED remove DENY (allow-fixture is load-bearing)" "$m"
    # And the forced form still denies — the mutant widened the rule, not broke it.
    assert_decision "$MAIN_DIR" "git worktree remove --force $WT_DIR" deny \
        "MUTATION: mutant 4 still denies the forced form (it only widened the match)" "$m"
}

# --- Registration integrity -------------------------------------------------
test_hooks_registered() {
    jq_required || return 0
    local hooks_json="$REPO_ROOT/plugins/workflow/hooks/hooks.json"
    assert_file_exists "$hooks_json" "hooks.json exists"
    local ok
    ok="$(jq -r '
        (.hooks.PreToolUse // [])
        | map(select(.matcher == "Bash"
              and ((.hooks // []) | any(.command | test("bash-guard\\.sh")))))
        | length' "$hooks_json" 2>/dev/null || echo 0)"
    assert_equals "1" "$ok" "hooks.json still registers the PreToolUse Bash matcher"
}

# --- Dispatch ---------------------------------------------------------------
run_test test_deny_reset_hard_dashC "AC1 deny: git -C <wt> reset --hard"
run_test test_deny_reset_hard_cd "AC1 deny: cd <wt> && git reset --hard"
run_test test_deny_reset_hard_relative_dashC "AC1 deny: relative -C"
run_test test_deny_reset_hard_relative_cd "AC1 deny: relative cd"
run_test test_deny_git_clean "AC1 deny: git -C <wt> clean -fd"
run_test test_deny_git_checkout_dashdash "AC1 deny: git -C <wt> checkout --"
run_test test_deny_chained_after_poll "AC1 deny: chained after a poll"
run_test test_deny_cd_persists_across_segments "AC1 deny: cd persists across an intervening segment"
run_test test_deny_tilde_path_to_worktree "AC1 deny: ~/-prefixed path (review BLOCKING regression)"
run_test test_deny_peer_to_peer "AC1 deny: peer worktree -> peer worktree"
run_test test_deny_repeated_dashC_chains "AC1 deny: chained -C a -C b names the REAL target (cycle-2 BLOCKING)"
run_test test_failopen_chain_poisoned_by_later_var "fail-open: later unresolvable -C poisons the chain (cycle-3 BLOCKING)"
run_test test_failopen_chain_poisoned_by_earlier_var "fail-open: EARLIER unresolvable -C poisons the chain (cycle-4)"
run_test test_all_three_verbs_share_target_resolution "invariant: all three verbs share _rule_b_target (cycle-4)"
run_test test_deny_tilde_mid_chain "AC1 deny: mid-chain ~/ expands and resets (cycle-3 BLOCKING)"
run_test test_deny_bare_tilde_operand "targeting: bare ~ resolves to \$HOME"
run_test test_failopen_git_dir_env_var "fail-open: GIT_DIR= env-var target (documented gap)"
run_test test_failopen_separated_git_dir_flag "fail-open: separated --git-dir <p> (documented gap)"
run_test test_allow_dashC_does_not_leak_to_later_git "targeting: -C does not leak to a later git"
run_test test_allow_later_cd_overrides_earlier "targeting: later cd overrides earlier"
run_test test_deny_explicit_dashC_overrides_cd "targeting: explicit -C overrides an ambient cd"
run_test test_deny_reason_is_actionable "AC1: deny reason is actionable"
run_test test_allow_main_reset_hard "AC2 allow: main checkout reset --hard"
run_test test_allow_main_git_clean "AC2 allow: main checkout clean -fd"
run_test test_allow_main_checkout_dashdash "AC2 allow: main checkout checkout --"
run_test test_allow_main_reset_hard_explicit_dashC "AC2 allow: explicit -C <main>"
run_test test_allow_own_worktree_bare "AC2 allow: golem's OWN worktree (bare)"
run_test test_allow_own_worktree_dashC "AC2 allow: golem's OWN worktree (-C)"
run_test test_allow_own_worktree_clean "AC2 allow: golem's OWN worktree (clean)"
run_test test_allow_own_worktree_subdir "AC2 allow: golem in a subdir of its own worktree"
run_test test_allow_poll_status "AC3 allow: poll git -C <wt> status"
run_test test_allow_poll_log "AC3 allow: poll git -C <wt> log"
run_test test_allow_poll_rev_parse "AC3 allow: poll git -C <wt> rev-parse"
run_test test_allow_poll_diff "AC3 allow: poll git -C <wt> diff"
run_test test_allow_reset_soft_in_worktree "AC3 allow: git reset (no --hard) into a worktree"
run_test test_allow_checkout_branch_in_worktree "AC3 allow: git checkout <branch> into a worktree"
run_test test_allow_rm_worktree_teardown "scope: rm -rf <wt> stays allowed"
run_test test_allow_mv_into_worktree "scope: mv inside a worktree stays allowed"
run_test test_allow_redirect_into_worktree "scope: > into a worktree stays allowed"
run_test test_failopen_no_cwd "fail-open: no cwd in the payload"
run_test test_failopen_nonexistent_target "fail-open: -C at a nonexistent path"
run_test test_failopen_target_outside_repo "fail-open: -C at a non-repo dir"
run_test test_failopen_unresolvable_cd_var "fail-open: unresolvable cd \$var"
run_test test_failopen_unresolvable_dashC_var "fail-open: unresolvable -C \$var"
run_test test_failopen_unresolvable_dashC_cmdsubst "fail-open: unresolvable -C \$(...)"
run_test test_failopen_tilde_user_form "fail-open: ~user/ is not expanded (accepted gap)"
run_test test_allow_worktree_into_primary_checkout "scope boundary: worktree -> primary allows by design"
run_test test_deny_worktree_remove_force "#665 deny: worktree remove --force <peer>"
run_test test_deny_worktree_remove_f_short "#665 deny: -f short form"
run_test test_deny_worktree_remove_doubled_f "#665 deny: doubled -f -f / --force --force"
run_test test_deny_worktree_remove_relative "#665 deny: relative positional path"
run_test test_deny_worktree_remove_peer_to_peer "#665 deny: peer -> peer"
run_test test_deny_worktree_remove_after_dashdash "#665 deny: path after --"
run_test test_deny_worktree_remove_chained_after_poll "#665 deny: chained after a poll"
run_test test_deny_worktree_remove_reason_actionable "#665: deny reason is actionable"
run_test test_allow_worktree_remove_unforced "#665 scope: unforced remove stays allowed"
run_test test_allow_worktree_remove_own_tree "#665 allow: own worktree"
run_test test_allow_worktree_remove_primary_target "#665 allow: primary-checkout target"
run_test test_allow_worktree_other_subcommands "#665 scope: list/prune/add unaffected"
run_test test_failopen_worktree_remove_unresolvable_path "#665 fail-open: unresolvable positional operand"
run_test test_worktree_rm_still_works "AC4: worktree-rm.sh teardown still works"
run_test test_rule_a_subagent_still_denied "Rule A regression: subagent rm still denied"
run_test test_rule_a_subagent_scratch_still_allowed "Rule A regression: scratch carve-out intact"
run_test test_nojq_denies_worktree_reset "no-jq: still denies a worktree reset"
run_test test_nojq_allows_main_reset "no-jq: still allows a main reset"
run_test test_mutation_neutered_gate "AC5 MUTATION 1: neutered gate flips every DENY"
run_test test_mutation_forced_cross_tree "AC5 MUTATION 2: forced cross-tree flips every own-tree ALLOW"
run_test test_mutation_neutered_worktree_arm "#665 MUTATION 3: neutered worktree arm flips every new DENY"
run_test test_mutation_force_requirement_dropped "#665 MUTATION 4: dropped --force test flips the unforced ALLOW"
run_test test_hooks_registered "hooks.json registers the guard"

generate_report
