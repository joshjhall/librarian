# shellcheck shell=bash
# Peer-worktree DENY cases — read-scope guard tests (issue #630).
#
# The positive-block half of the contract: a golem session (cwd inside a linked worktree) reading a PEER `issue-*` worktree is denied, across all three read tools, through `..`/slash normalization, and under a differently named worktree directory.
#
# Sourced by tests/validate-read-scope-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/read-scope-guard-fixtures.sh (building the topologies)
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.
#
# These are the cases that fail CI if a scoping regression turns the guard into a
# permanent no-op — the failure a silence-only or allow-only suite cannot see.

# --- The three read tools ---------------------------------------------------
# Read carries the target in `file_path`; Grep and Glob carry it in `path`. A
# guard that read only one field would silently allow the other two, so each tool
# gets its own case rather than one parameterized over a field name.
test_deny_peer_read() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt"
    assert_valid_json "$GUARD_OUT" "deny output is valid JSON"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "golem->peer Read denied"
}
test_deny_peer_grep() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "$PEER_DIR"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "golem->peer Grep (path field) denied"
}
test_deny_peer_glob() {
    jq_required || return 0
    run_guard "$WT_DIR" "Glob" "path" "$PEER_DIR/plugins"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "golem->peer Glob (path field) denied"
}

# --- The deny reason must be actionable -------------------------------------
# AC#1 asks for "a reason naming the peer path and the rule". A denial a golem
# cannot act on is how an over-broad read guard wedges a turn, so the message is
# part of the contract, not decoration: it must name what was blocked, and say
# what to do instead.
test_deny_reason_names_peer_and_rule() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt"
    local reason
    reason="$(deny_reason "$GUARD_OUT")"
    # Match the peer root WITH its closing backtick. The bare path would also be
    # a substring of the TARGET (`$PEER_DIR/peer-file.txt`), so a bare
    # assert_contains passes even when the message never names the peer ROOT at
    # all — the gate and its evidence converging into a tautology. Mutation-
    # verified: replacing `${peer_root}` in the reason with prose leaves a bare
    # check green and fails this one.
    assert_contains "$reason" "$PEER_DIR\`" "deny reason names the peer worktree ROOT (not merely the target)"
    assert_contains "$reason" "$WT_DIR" "deny reason names the session's own worktree"
    assert_contains "$reason" "#630" "deny reason cites the rule"
    assert_contains "$reason" ".status" "deny reason points at the readable coordination path"
}

# --- Normalization bypasses (#506 class, re-armed for the read rule) --------
# Scoping is lexical prefix matching, so `$WT/../issue-2/x` — the NATURAL shape
# of a peer read, since a golem knows its own root and reaches sideways — must
# normalize before the comparison. The doubled/trailing-slash variants are the
# #506 pre-PR finding: filesystem-equivalent spellings that open the same inode
# while defeating a strict lexical match.
test_deny_peer_via_dotdot() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$WT_DIR/../issue-2/peer-file.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "\$WT/../issue-2 traversal into a peer denied"
}
test_deny_peer_double_slash() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "$WT_PARENT//issue-2//peer-file.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "doubled-slash peer path denied"
}
test_deny_peer_trailing_slash() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "$PEER_DIR/"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "trailing-slash peer dir denied"
}

# --- The worktree directory's NAME is never read (#626 forward-compat) ------
# The peer set is derived from the parent of the session's OWN root, so a
# deployment whose worktrees live under `wt-custom/` (or #626's
# `.claude/worktrees/`, or any GOLEM_WORKTREE_DIR override) enforces identically.
# A guard that hardcoded `.worktrees` would pass every case above and silently
# stop enforcing the day the directory moved.
test_deny_peer_custom_worktree_dir() {
    jq_required || return 0
    if [ "$ALT_OK" -ne 1 ]; then
        skip_test "alt-topology fixture unavailable"
        return 0
    fi
    run_guard "$ALT_WT" "Read" "file_path" "$ALT_PEER/a"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "peer deny fires under a non-default worktree dir name"
}

# --- The #506 forged-gitlink disarm must not work here either ---------------
# The caller gate trusts `git-dir == git-common-dir` to mean "main session, never
# blocked". A golem can FORGE that by overwriting its own `<wt>/.git` gitlink to
# a decoy repo it `git init`s inside its own tree — after which both resolve to
# the decoy, the gate fires, and the guard is disarmed. This is not hypothetical:
# it is exactly how #506 defeated the WRITE guard, and this guard inherits the
# same gate, so it inherits the same attack.
#
# The cross-check that survives the poison is structural and OUTSIDE the worktree
# (`_find_enclosing_primary`): the real main checkout still physically encloses
# cwd and still holds a real `.git` DIRECTORY, and the golem cannot change either
# without destroying its own repo. Without this case the entire cross-check is
# untested — a mutation dropping it and trusting the identity unconditionally
# passed every other test in this suite.
test_deny_peer_from_forged_gitlink_session() {
    jq_required || return 0
    local poisoned="$FIXTURE/poison"
    command mkdir -p "$poisoned" || {
        skip_test "poison fixture unavailable"
        return 0
    }
    # A fresh main + two worktrees, so poisoning one cannot disturb the shared
    # topology every other case reads.
    git_clean -C "$poisoned" init -q 2>/dev/null || {
        skip_test "poison fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" config user.email "test@example.com"
    git_clean -C "$poisoned" config user.name "Test"
    printf 'x\n' >"$poisoned/f"
    git_clean -C "$poisoned" add f 2>/dev/null
    git_clean -C "$poisoned" -c commit.gpgsign=false commit -qm s 2>/dev/null
    git_clean -C "$poisoned" worktree add -q -b feature/issue-41 \
        "$poisoned/.worktrees/issue-41" >/dev/null 2>&1 || {
        skip_test "poison fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" worktree add -q -b feature/issue-42 \
        "$poisoned/.worktrees/issue-42" >/dev/null 2>&1 || {
        skip_test "poison fixture unavailable"
        return 0
    }
    local pmain pwt ppeer
    pmain="$(cd "$poisoned" && pwd)"
    pwt="$pmain/.worktrees/issue-41"
    ppeer="$pmain/.worktrees/issue-42"

    # THE FORGE: git init a decoy inside the golem's own tree and repoint the
    # gitlink at it, so `git -C $pwt rev-parse --git-dir` == `--git-common-dir`.
    command mkdir -p "$pwt/decoy"
    git_clean -C "$pwt/decoy" init -q 2>/dev/null || {
        skip_test "decoy init unavailable"
        return 0
    }
    printf 'gitdir: %s/decoy/.git\n' "$pwt" >"$pwt/.git"

    # Arm check: the forge must actually have taken, or this case proves nothing
    # (an unarmed poison would "pass" through the ordinary linked-worktree path).
    local gd gc
    gd="$(git_clean -C "$pwt" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    gc="$(git_clean -C "$pwt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$gd" ] || [ "$gd" != "$gc" ]; then
        skip_test "gitlink forge did not take in this environment"
        return 0
    fi

    # PR SCOPE: this PR DETECTS the disguise but does not ENFORCE against it —
    # recovering the true worktree root when both the gitlink and the registry
    # are golem-controlled is the follow-up PR's subject. So the contract pinned
    # here is the one that actually matters at this stage: the forged identity
    # must NOT be mistaken for a genuine main session and silently allowed. It
    # fails open LOUDLY instead, which an operator can see.
    #
    # The distinction is the whole point. Without `_find_enclosing_primary`, a
    # forged gitlink reads as `git-dir == git-common-dir` -> "genuine main
    # session" -> unconditional silent allow. With it, the session is recognised
    # as disguised and degrades loudly. Asserting the stderr, not the decision,
    # is what makes this test true of THIS PR rather than of the next one.
    local payload err out
    payload="$(printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/f"}}' "$pwt" "$ppeer")"
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_output_empty "$out" \
        "a disguised session fails OPEN (the read guard never wedges a session it cannot scope)"
    assert_contains "$err" "could not resolve the worktree root" \
        "...and does so LOUDLY — the forged identity is detected, not mistaken for a genuine main session and silently allowed (#506 class)"
}

# --- The worktree root must come from a NON-POISONABLE source (#501 class) ---
# The guard resolves its own root from the linked worktree's `<git_dir>/gitdir`
# pointer file, written once at `git worktree add` time — NOT from `git rev-parse
# --show-toplevel`, whose answer `core.worktree` can redirect. That key lives in
# the SHARED common-dir config, which the very golem this guard polices can
# rewrite: with `extensions.worktreeConfig=true` plus `git config --worktree
# core.worktree <main>`, `--show-toplevel` returns the MAIN checkout.
#
# For THIS guard the consequence is a self-disarm rather than a leak, and it is
# quiet: a root redirected to the main checkout makes the peer set the siblings
# of MAIN — of which there are none — so every peer read silently ALLOWS. One
# `git config` command and the control is off for the session. A mutation
# replacing the gitdir-pointer derivation with the `--show-toplevel` fallback
# passed every other test in this suite, which is what this case exists to stop.
test_deny_peer_survives_core_worktree_poison() {
    jq_required || return 0
    local poisoned="$FIXTURE/cwpoison"
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
    git_clean -C "$poisoned" worktree add -q -b feature/issue-51 \
        "$poisoned/.worktrees/issue-51" >/dev/null 2>&1 || {
        skip_test "poison fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" worktree add -q -b feature/issue-52 \
        "$poisoned/.worktrees/issue-52" >/dev/null 2>&1 || {
        skip_test "poison fixture unavailable"
        return 0
    }
    local pmain pwt ppeer
    pmain="$(cd "$poisoned" && pwd)"
    pwt="$pmain/.worktrees/issue-51"
    ppeer="$pmain/.worktrees/issue-52"

    # THE POISON, issued from the worktree exactly as a golem would.
    git_clean -C "$pwt" config extensions.worktreeConfig true 2>/dev/null || {
        skip_test "worktreeConfig unsupported in this git"
        return 0
    }
    git_clean -C "$pwt" config --worktree core.worktree "$pmain" 2>/dev/null || {
        skip_test "per-worktree config unsupported in this git"
        return 0
    }

    # ARM CHECK — the poison must actually have redirected --show-toplevel, or
    # this case passes for the wrong reason (an unpoisoned tree denies anyway,
    # so a silent no-op poison would look identical to a working guard).
    local top
    top="$(git_clean -C "$pwt" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$top" != "$pmain" ]; then
        skip_test "core.worktree poison did not redirect --show-toplevel here"
        return 0
    fi

    run_guard "$pwt" "Read" "file_path" "$ppeer/f"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a core.worktree-poisoned worktree still cannot disarm its own read guard (#501 class)"
}

# --- The worktree DIRECTORY itself is a peer read in disguise ---------------
# The per-peer rule above matches paths UNDER an `issue-*` sibling. A `Grep` or
# `Glob` rooted at the shared worktree directory is not under any of them — it is
# their PARENT — yet it descends into every one, making it the single most
# effective way to read all peers at once. Found by probing the implementation
# rather than the acceptance criteria: measured on the live repo, a term planted
# in a peer worktree WAS returned by a search rooted at `.worktrees`, while the
# guard allowed the call.
#
# The deny stops at the directory itself and does not walk up: `<repo>` and `/`
# also contain peers, but denying those would block the main checkout and
# everything else — the over-broad read deny this guard is built to avoid. The
# carve-out cases in 20-carve-outs.sh pin that those ancestors stay allowed.
test_deny_worktree_dir_itself() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "$WT_PARENT"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a search rooted at the shared worktree DIR (the parent of every peer) is denied"
}
test_deny_worktree_dir_trailing_slash() {
    jq_required || return 0
    run_guard "$WT_DIR" "Glob" "path" "$WT_PARENT/"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "the trailing-slash spelling of the worktree dir is denied too (normalized)"
}
test_deny_worktree_dir_reason_points_at_own_root() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "$WT_PARENT"
    local reason
    reason="$(deny_reason "$GUARD_OUT")"
    assert_contains "$reason" "$WT_DIR" "the reason names the session's own root as the place to search"
    assert_contains "$reason" ".status" "the reason still points at the readable coordination path"
}

# --- NotebookRead is its own tool name, and its own target field ------------
# A PreToolUse `matcher` is matched against the FULL tool name, so `Read` does
# NOT match `NotebookRead` — which is precisely why the sibling write guard
# spells out `NotebookEdit` instead of relying on `Edit`. Two independent things
# therefore had to be right, and neither was: the matcher had to enumerate
# NotebookRead, and the extraction had to read `notebook_path` (the guard read
# only `file_path`/`path`, so even a firing matcher would have seen "no target"
# and allowed).
#
# Review-reported and dynamically reproduced: a NotebookRead of a peer `.ipynb`
# was ALLOWED before this. The pair below pins both halves — a peer notebook
# denies, my own notebook still allows — because a fix that denied every
# NotebookRead would satisfy the deny half alone.
test_deny_peer_notebook_read() {
    jq_required || return 0
    run_guard "$WT_DIR" "NotebookRead" "notebook_path" "$PEER_DIR/analysis.ipynb"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "NotebookRead of a peer notebook is denied (notebook_path is a third target field)"
}
test_allow_own_notebook_read() {
    jq_required || return 0
    run_guard "$WT_DIR" "NotebookRead" "notebook_path" "$WT_DIR/analysis.ipynb"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "NotebookRead of my OWN notebook is allowed (the fix did not blanket-deny the tool)"
}
test_nojq_denies_peer_notebook_read() {
    # The sed fallback needed a THIRD scrape; without it the no-jq path sees no
    # target and allows, silently unguarding NotebookRead on every jq-less host
    # (base macOS ships no jq).
    run_guard "$WT_DIR" "NotebookRead" "notebook_path" "$PEER_DIR/analysis.ipynb" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' \
        "no-jq path also denies a peer NotebookRead (the notebook_path scrape exists)"
}
test_hooks_matcher_covers_notebook_read() {
    local content
    content="$(command cat "$HOOKS_JSON")"
    assert_contains "$content" "NotebookRead" \
        "hooks.json matcher enumerates NotebookRead (a full-tool-name match; 'Read' does not cover it)"
}

# --- RELATIVE targets traverse to peers too (the cycle-3 HIGH bypass) -------
# An earlier draft allowed every non-absolute target outright, on the stated
# reasoning that "a relative path resolves against cwd (my own worktree) and
# cannot reach a peer". That is false for any value containing `..`:
# `../issue-2/x` from a golem's cwd lands squarely in a peer. Review reproduced
# it dynamically — the relative form was ALLOWED while the absolute form of the
# SAME file was denied.
#
# It is the "comment asserts intent, not code" failure in its most dangerous
# shape: the comment did not merely fail to describe the code, it justified the
# hole. And relative targets are not hypothetical here — the suite's own
# test_allow_relative_target exercises exactly that shape for Grep.
#
# Relative targets are now joined to cwd and normalized like any absolute one,
# so both spellings traverse identically.
test_deny_peer_via_relative_dotdot() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "../issue-2/peer-file.txt"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a RELATIVE ../issue-N traversal into a peer is denied (not merely the absolute spelling)"
}
test_deny_peer_via_relative_grep_path() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" "../issue-2"
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "a RELATIVE peer path in Grep's path field is denied"
}
test_deny_worktree_dir_via_relative() {
    jq_required || return 0
    run_guard "$WT_DIR" "Grep" "path" ".."
    assert_equals "deny" "$(decision "$GUARD_OUT")" \
        "the relative spelling of the shared worktree DIR is denied"
}
test_nojq_denies_relative_peer() {
    run_guard "$WT_DIR" "Read" "file_path" "../issue-2/peer-file.txt" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' \
        "no-jq path also resolves and denies a relative peer traversal"
}
