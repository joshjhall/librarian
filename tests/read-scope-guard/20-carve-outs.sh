# shellcheck shell=bash
# ALLOW carve-outs — read-scope guard tests (issue #630).
#
# The half of the contract a deny-only suite cannot see. An over-broad READ deny wedges a golem mid-turn with no recovery path, so each thing a too-broad rule would break gets its own pinned case: my own worktree, the shared `.status/` feed, out-of-repo paths, the main checkout, and the orchestrator session.
#
# Sourced by tests/validate-read-scope-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/read-scope-guard-fixtures.sh (building the topologies)
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# --- My own worktree (AC#3) -------------------------------------------------
test_allow_own_worktree() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$WT_DIR/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "reading my own worktree is allowed"
}
test_allow_own_worktree_nested() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "$WT_DIR/plugins/workflow"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "searching a nested path in my own worktree is allowed"
}

# --- The shared status dir (AC#3) -------------------------------------------
# `<worktree-dir>/.status/` is a SIBLING of every worktree root, so a rule
# phrased as "deny everything outside my worktree but inside the worktree dir"
# would take it out — and with it the escalation path itself (golem-notify.sh
# writes the feed; golem-inbox.sh relays human gates down through it). The guard
# survives this by matching only `issue-*` siblings, which is a property worth
# asserting rather than trusting.
test_allow_status_dir() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$STATUS_DIR/feed.jsonl"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "reading the shared .status feed is allowed"
}
test_allow_status_dir_glob() {
    jq_required || return 0
    run_guard "$WT_DIR" "Glob" "path" "$STATUS_DIR"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "globbing the shared .status dir is allowed"
}

# --- Outside the repo entirely (AC#3) ---------------------------------------
test_allow_out_of_repo_tmp() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "/tmp/scratch.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "out-of-repo /tmp target allowed"
}
test_allow_out_of_repo_home() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "${HOME:-/root}/.claude.json"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "out-of-repo \$HOME target allowed"
}

# --- The MAIN checkout is DELIBERATELY allowed ------------------------------
# #630: "Start by denying peer worktrees only; extend to main later behind
# evidence." A golem legitimately reads CLAUDE.md and .claude/memory/*.md, and
# the failure direction here punishes over-breadth — so this is a decision, not
# an oversight, and it is pinned so a later widening is a deliberate diff to THIS
# assertion rather than a quiet ratchet. Note the WRITE guard denies the same
# path (worktree-guard.sh), which is exactly the asymmetry #630 argues for.
test_allow_main_checkout_read() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$MAIN_DIR/seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "reading the MAIN checkout is allowed (narrow-by-design, #630)"
}

# --- The orchestrator must keep reading every worktree (AC#2) ---------------
# The main session has git-dir == git-common-dir. Blocking it would break the
# orchestrator's core job — it polls every golem's tree — so the identical call
# that denies from a worktree must allow from main.
test_allow_main_session_reading_peer() {
    jq_required || return 0
    run_guard "$MAIN_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "orchestrator reading a worktree is allowed"
}
test_allow_main_session_grep_all_worktrees() {
    jq_required || return 0
    run_guard "$MAIN_DIR" "Grep" "path" "$WT_PARENT"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "orchestrator searching the whole worktree dir is allowed"
}

# --- Relative and absent targets --------------------------------------------
# A relative path resolves against cwd (my own worktree) and cannot reach a peer.
# An ABSENT path is the Grep/Glob "search cwd" shape — the single most common
# search a golem runs — so denying on a missing field would be the worst possible
# false positive.
test_allow_relative_target() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "plugins/workflow"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "relative target allowed"
}
test_allow_absent_path_field() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "-" ""
    assert_equals "allow" "$(decision "$GUARD_OUT")" "Grep with no path (searches cwd) allowed"
}

# --- A non-issue sibling under a CUSTOM worktree dir ------------------------
# Pairs with 10-peer-deny.sh's custom-dir deny: the same alternate topology must
# still allow its own tree, proving the custom-dir case denies because the target
# is a PEER and not because the guard turned into a blanket deny there.
test_allow_own_tree_custom_worktree_dir() {
    jq_required || return 0
    if [ "$ALT_OK" -ne 1 ]; then
        skip_test "alt-topology fixture unavailable"
        return 0
    fi
    run_guard "$ALT_WT" "Read" "file_path" "$ALT_WT/a"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "own tree allowed under a non-default worktree dir name"
}

# --- An `issue-*` directory that is NOT a worktree stays readable -----------
# `issue-*` is a naming CONVENTION, not proof of worktree-ness. A human's
# `issue-999-scratch-notes/`, a kept backup of a torn-down tree, or anything
# tooling drops beside the worktrees matches the pattern while being nobody's
# worktree — and denying those is the over-broad READ deny this guard's own
# header argues against: it wedges a golem on a path with no peer behind it.
#
# Caught by review and dynamically reproduced: before the structural check, a
# bare `mkdir issue-999-scratch-notes` was DENIED. The guard now confirms the
# sibling carries a linked worktree's gitlink FILE (`<peer>/.git`, written by
# `git worktree add`) before treating it as a peer.
#
# The pair below is the point. Asserting only the allow would pass for a guard
# that stopped denying peers entirely, so the deny half runs against the SAME
# parent directory — the two differ by exactly one property, whether the
# directory is a real worktree.
test_allow_non_worktree_issue_named_sibling() {
    jq_required || return 0
    local decoy="$WT_PARENT/issue-999-scratch-notes"
    command mkdir -p "$decoy" || {
        skip_test "could not create the decoy directory"
        return 0
    }
    printf 'notes\n' >"$decoy/todo.md"
    # Arm check: it must NOT look like a worktree, or the case proves nothing.
    if [ -e "$decoy/.git" ]; then
        skip_test "decoy unexpectedly carries a .git entry"
        command rm -rf "$decoy"
        return 0
    fi
    run_guard "$WT_DIR" "Read" "file_path" "$decoy/todo.md"
    local d
    d="$(decision "$GUARD_OUT")"
    command rm -rf "$decoy"
    assert_equals "allow" "$d" \
        "an issue-* sibling that is NOT a real worktree is ALLOWED (name alone must not trigger a deny)"
}
test_deny_real_peer_beside_the_decoy() {
    jq_required || return 0
    # The discriminating half: same parent, same issue-* shape, but a genuine
    # worktree. If this ever allows, the narrowing above went too far.
    run_guard "$WT_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a REAL peer worktree in that same parent is still denied (the narrowing did not defeat the rule)"
}

# --- A DISGUISED session must still read its OWN tree ----------------------
# 10-peer-deny.sh pins that a session whose identity is forged via a rewritten
# gitlink is still DENIED a peer read. That is only half the branch. The same
# code path (`_find_enclosing_primary` -> DISGUISED=1 -> `_derive_wt_root_poison`
# -> the own-worktree-first allow) can fail the OTHER way: if the recovered root
# is wrong, the session is denied reads of its own files — the wedge-a-golem
# outcome this guard's whole design argues against, and the direction no other
# case here covers.
#
# Every other allow/deny pairing in this suite is deliberately symmetric; this
# one was asymmetric until review caught it.
test_allow_own_read_under_forged_gitlink_session() {
    jq_required || return 0
    local poisoned="$FIXTURE/poison-allow"
    command mkdir -p "$poisoned" || {
        skip_test "poison fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" init -q 2>/dev/null || {
        skip_test "poison fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" config user.email "test@example.com"
    git_clean -C "$poisoned" config user.name "Test"
    printf 'x\n' >"$poisoned/f"
    git_clean -C "$poisoned" add f 2>/dev/null
    git_clean -C "$poisoned" -c commit.gpgsign=false commit -qm s 2>/dev/null
    git_clean -C "$poisoned" worktree add -q -b feature/issue-71 \
        "$poisoned/.worktrees/issue-71" >/dev/null 2>&1 || {
        skip_test "poison fixture unavailable"
        return 0
    }
    local pmain pwt
    pmain="$(cd "$poisoned" && pwd)"
    pwt="$pmain/.worktrees/issue-71"
    printf 'mine\n' >"$pwt/own.txt"

    # THE FORGE, identical to the deny-side case.
    command mkdir -p "$pwt/decoy"
    git_clean -C "$pwt/decoy" init -q 2>/dev/null || {
        skip_test "decoy init unavailable"
        return 0
    }
    printf 'gitdir: %s/decoy/.git\n' "$pwt" >"$pwt/.git"

    # Arm check: the forge must have taken, or this exercises the ordinary path.
    local gd gc
    gd="$(git_clean -C "$pwt" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    gc="$(git_clean -C "$pwt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$gd" ] || [ "$gd" != "$gc" ]; then
        skip_test "gitlink forge did not take in this environment"
        return 0
    fi

    run_guard "$pwt" "Read" "file_path" "$pwt/own.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "a disguised session can still read its OWN worktree (the recovered root is right, not merely non-empty)"
}

# --- ...but legitimate RELATIVE targets must keep working -------------------
# The relative-traversal fix is where an over-broad deny is most likely to creep
# in: relative paths are the common case for a golem searching its own tree, so
# a join that mis-anchored (or a rule that denied relatives outright) would wedge
# routine work. Each of these is a shape a golem issues constantly.
test_allow_relative_own_subdir() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "plugins/workflow"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "a relative path inside my own worktree is allowed"
}
test_allow_relative_dot_prefixed() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "./seed.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "a ./-prefixed relative target in my own tree is allowed"
}
test_allow_relative_status_dir() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "../.status/feed.jsonl"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "the relative spelling of the shared .status feed is allowed"
}
test_allow_relative_repo_root() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "../../"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "a relative path resolving to the repo root (above the worktree dir) is allowed"
}
