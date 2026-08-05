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

test_suite "bash-guard.sh Rule B — main-session git into a worktree (#662)"

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
run_test test_worktree_rm_still_works "AC4: worktree-rm.sh teardown still works"
run_test test_rule_a_subagent_still_denied "Rule A regression: subagent rm still denied"
run_test test_rule_a_subagent_scratch_still_allowed "Rule A regression: scratch carve-out intact"
run_test test_nojq_denies_worktree_reset "no-jq: still denies a worktree reset"
run_test test_nojq_allows_main_reset "no-jq: still allows a main reset"
run_test test_mutation_neutered_gate "AC5 MUTATION 1: neutered gate flips every DENY"
run_test test_mutation_forced_cross_tree "AC5 MUTATION 2: forced cross-tree flips every own-tree ALLOW"
run_test test_hooks_registered "hooks.json registers the guard"

generate_report
