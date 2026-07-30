# shellcheck shell=bash
# worktree-new.sh — golem helper-script tests (issue #564 split).
#
# Covers worktree/branch creation, submodule placement, local-file copying, and tainted-git-env scrubbing.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- worktree-new.sh --------------------------------------------------------

# Non-integer argument → exit 2 before touching git.
test_worktree_new_non_integer_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" notanumber
    assert_exit 2 "$RUN_RC" "worktree-new with a non-integer arg exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# Happy path: creates .worktrees/issue-N on branch feature/issue-N from HEAD.
test_worktree_new_creates_worktree() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 31
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on a fresh issue"
    assert_contains "$RUN_OUT" "Worktree ready" "reports the worktree is ready"
    assert_file_exists "$sb/.worktrees/issue-31/seed.txt" \
        "the worktree checkout contains the repo's files"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-31")"
    assert_not_empty "$branches" "the feature/issue-31 branch was created"
}

# Idempotency guard: a second worktree-new for the SAME issue → exit 1 (worktree
# already exists), distinct from the bad-arg exit 2.
test_worktree_new_duplicate_exits_1() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 32
    assert_exit 0 "$RUN_RC" "first worktree-new succeeds"
    run_in "$sb" "$WT_NEW" 32
    assert_exit 1 "$RUN_RC" "second worktree-new for the same issue exits 1"
    assert_contains "$RUN_OUT" "already exists" "explains the worktree already exists"
}

# Distinct exit-1 arm: the worktree is gone but the branch still exists → exit 1
# naming the branch. Remove just the worktree (keep the branch) so the branch
# guard fires rather than the worktree guard.
test_worktree_new_existing_branch_exits_1() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 33
    assert_exit 0 "$RUN_RC" "first worktree-new succeeds"
    # Drop the worktree only (the branch lingers).
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" worktree remove .worktrees/issue-33 2>/dev/null
    run_in "$sb" "$WT_NEW" 33
    assert_exit 1 "$RUN_RC" "worktree-new with a lingering branch exits 1"
    assert_contains "$RUN_OUT" "branch" "explains the branch already exists"
}

# Regression (#228): the script must invoke coreutils/git via the `command`
# builtin (PATH-resolved, alias-proof), NOT hardcoded /usr/bin/* paths — those
# die with exit 127 on hosts where the tools live elsewhere (Nix/Homebrew,
# external-volume checkouts, non-standard macOS), AFTER the worktree already
# exists. Static guard: no /usr/bin/<tool> beyond the #!/usr/bin/env shebang.
test_worktree_new_no_hardcoded_usr_bin() {
    local hits
    hits="$(command grep -nE '/usr/bin/(mkdir|cp|dirname|git|grep)' "$WT_NEW" || true)"
    assert_output_empty "$hits" \
        "worktree-new.sh invokes tools via \`command\`, not hardcoded /usr/bin/*"
}

# Regression (#228): the local-file copy step (the arm that failed at exit 127)
# actually copies GOLEM_WORKTREE_LOCAL_FILES into the fresh worktree. The shared
# run_in helper pins GOLEM_WORKTREE_LOCAL_FILES="" so it never exercises this;
# override it here with a direct env invocation mirroring run_in's scrub/pin.
test_worktree_new_copies_local_files() {
    local sb
    new_sandbox sb
    command printf 'SECRET=1\n' >"$sb/.env"
    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES=".env" \
            "$REAL_BASH" "$WT_NEW" 35 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 when copying a local file"
    assert_file_exists "$sb/.worktrees/issue-35/.env" \
        "the machine-local .env was copied into the worktree"
    assert_contains "$out" "copied .env" "reports the .env copy"
}

# Regression (#325): `git worktree add` does NOT populate submodules, so in a
# consuming repo where a submodule ships the pre-commit fixer scripts the root
# lefthook hook calls, the fresh worktree can't commit with the hook enabled.
# worktree-new.sh must run `git submodule update --init --recursive` after the
# add so those scripts resolve inside the worktree. Build a super+submodule
# fixture (shared _make_super_with_submodule) whose submodule carries a marker
# bin/fix.sh, run worktree-new from the superproject, and assert the marker is
# present in the worktree's submodule checkout. Skips cleanly if `git submodule
# add` is unavailable (old git / file protocol disallowed).
test_worktree_new_inits_submodules() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 36
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a submodule present"
    assert_file_exists "$super/.worktrees/issue-36/mod/bin/fix.sh" \
        "the submodule's hook script is populated in the fresh worktree"
}

# Regression (#338, closing the loop on #324/PR #335): the end-to-end worktree
# PLACEMENT when worktree-new.sh is invoked from INSIDE a submodule working tree.
# The #324 bug: inside a submodule, `git rev-parse --git-common-dir` resolves to
# <super>/.git/modules/<name>, so a repo_root() that trusted the common dir
# returned that git-internal path, and worktree-new.sh — which cd's into
# repo_root() before `git worktree add` — landed the worktree at
# <super>/.git/modules/<name>/.worktrees/issue-N instead of
# <super>/.worktrees/issue-N. #324's --show-superproject-working-tree probe fixed
# repo_root(), and test_config_repo_root_submodule_superproject covers that at
# the repo_root() UNIT level — but no test drove the WHOLE script from inside a
# submodule to demonstrate the reported placement symptom is actually gone. This
# is that test: distinct from test_worktree_new_inits_submodules (#325), which
# runs from the SUPERPROJECT root and asserts submodule POPULATION, not placement.
# Run worktree-new from <super>/mod and assert the worktree lands at the
# superproject's .worktrees/ (carrying the superproject's tracked app.txt, so it
# forked <super> and not the submodule) and that NOTHING landed under
# .git/modules (the exact #324 bug path). Not via run_in — that cd's to the
# superproject root; this must invoke from the submodule subdir, so it mirrors
# run_in's scrub/pins directly (like test_worktree_new_copies_local_files) with
# `cd "$super/mod"`. Skips cleanly if `git submodule add` is unavailable.
test_worktree_new_from_submodule_placement() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1

    # Invoke worktree-new from INSIDE the submodule working tree (<super>/mod),
    # not the superproject root — the #324 reproduction path. Mirror run_in's
    # scrub/pins; HOME="$super" so $super/.gitconfig's protocol.file.allow is
    # honored and the seed-trust write stays sandboxed. Use a fully-local
    # out/rc pair (not the shared RUN_OUT/RUN_RC globals) since the invocation
    # bypasses run_in — matching the other hand-rolled tests in this file
    # (test_worktree_new_copies_local_files, ..._scrubs_tainted_git_env_for_mutations).
    local out rc=0
    out="$(cd "$super/mod" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$super" \
            TMUX= TMUX_TMPDIR="$super/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 44 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 when run from inside a submodule"
    assert_file_exists "$super/.worktrees/issue-44/app.txt" \
        "the worktree lands at <super>/.worktrees/issue-44 with the superproject's files"
    assert_true '[ ! -e "'"$super"'/.git/modules/mod/.worktrees" ]' \
        "nothing landed under <super>/.git/modules (the #324 bug path)"
}

# Regression (#328): worktree-new.sh runs its OWN git mutations (worktree add
# -b …) after repo_root(). #279 scrubbed only repo_root()'s rev-parse subshell,
# so a tainted GIT_DIR/GIT_COMMON_DIR forwarded from a git hook still redirected
# the caller's `git worktree add`: the worktree dir landed in the right repo but
# the new BRANCH REF landed in the OUTER/tainted repo — a split-brain (verified
# dynamically). The process-wide scrub added after `. config.sh` re-anchors all
# subsequent git calls to cwd. Invoke worktree-new UNDER taint (not via run_in,
# which the harness already scrubs) with GIT_DIR/GIT_COMMON_DIR pointed at a
# separate outer repo, and assert the branch lands in the SANDBOX and is ABSENT
# from outer. Mirrors test_config_repo_root_scrubs_tainted_git_env's taint setup.
test_worktree_new_scrubs_tainted_git_env_for_mutations() {
    local sb outer
    new_sandbox sb
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Run worktree-new from the sandbox with the git env TAINTED toward outer.
    # No GIT_SCRUB on this invocation — the taint is the whole point; the script's
    # own #328 scrub must clear it. Pin GOLEM_* / HOME like run_in does otherwise.
    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 78 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 despite a tainted git environment"

    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-78")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-78")"
    assert_not_empty "$sb_branch" \
        "the branch ref lands in the SANDBOX repo, not the tainted GIT_DIR target"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo (no split-brain)"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): the
# mutation-level companion to test_worktree_new_scrubs_tainted_git_env_for_mutations
# (#328), swapping the GIT_DIR taint for a GIT_CONFIG_COUNT/KEY_0/VALUE_0 config
# injection. #328 proved worktree-new.sh's process-wide scrub re-anchors its `git
# worktree add -b` after a GIT_DIR redirect; this proves the SAME scrub clears the
# dynamic GIT_CONFIG_* injection family end-to-end through the script's own
# mutation — not just at the repo_root() unit level. The injected core.hooksPath
# points at a hooks dir whose reference-transaction hook ALWAYS fails: if the scrub
# is dropped, `git worktree add -b` fires the hook and aborts the ref creation
# (script exits non-zero, no branch); with the scrub the injection is gone, the
# mutation runs clean, and the branch lands in the SANDBOX. No GIT_SCRUB on the
# invocation — the taint is the whole point; the script's own #328 scrub must
# clear it. Pin GOLEM_* / HOME like run_in does otherwise.
test_worktree_new_scrubs_git_config_injection_for_mutations() {
    local sb hooks
    new_sandbox sb
    _seed_failing_ref_hook "$sb" hooks

    local out rc=0
    out="$(cd "$sb" &&
        GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 76 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-new exits 0 despite a GIT_CONFIG_* injection taint"

    assert_file_exists "$sb/.worktrees/issue-76/seed.txt" \
        "the worktree is created in the sandbox despite the config injection"
    local sb_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-76")"
    assert_not_empty "$sb_branch" \
        "the branch ref lands in the sandbox despite the GIT_CONFIG_* injection (scrub clears the dynamic pairs)"
}

# Regression (#365, closing the last open cell of the worktree-new.sh × submodule
# × tainted-git-env coverage matrix — deferred from PR #364's pre-PR review). The
# two hardening dimensions are already tested only SEPARATELY: #338
# (test_worktree_new_from_submodule_placement) drives the whole script from
# inside a submodule but with a CLEAN env (placement only), and #328
# (test_worktree_new_scrubs_tainted_git_env_for_mutations) drives the whole
# script UNDER taint but from a PLAIN non-submodule sandbox (repo_root's
# common-dir arm). The exact fusion — the full worktree-new.sh from INSIDE a
# submodule AND under a tainted GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR — was
# untested end-to-end; #337 covers submodule+taint only at the repo_root() UNIT
# level, not the script's OWN post-repo_root() `git worktree add` mutation. This
# is that cell: worktree-new.sh's process-wide scrub (before repo_root and every
# mutation) must both keep the #324 super_root placement (worktree lands at
# <super>/.worktrees, nothing under .git/modules) AND keep the #328 branch ref in
# the superproject, not the tainted outer repo. Not via run_in (it cd's to the
# sandbox root); this must invoke from the submodule subdir, so it hand-rolls the
# env invocation mirroring run_in's pins with `cd "$super/mod"` (like
# test_worktree_new_from_submodule_placement) but WITHOUT the GIT_SCRUB unset —
# the taint is the whole point; the script's own scrub must clear it.
# GIT_WORK_TREE is included in the taint (load-bearing per #337/#363: it forces
# an unscrubbed super_root probe to miss the submodule). Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_worktree_new_from_submodule_placement_under_taint() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1

    # Third, unrelated outer repo whose .git the taint points at (the split-brain
    # target). Scrubbed setup so its own creation is not itself tainted.
    local outer
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Invoke worktree-new from INSIDE the submodule working tree (<super>/mod) with
    # the git env TAINTED toward outer. No GIT_SCRUB on this invocation — the
    # script's own #328 scrub must clear it; GIT_WORK_TREE is included so an
    # unscrubbed super_root probe would miss the submodule (#337/#363). Fully-local
    # out/rc pair (not the shared RUN_OUT/RUN_RC), since this bypasses run_in.
    local out rc=0
    out="$(cd "$super/mod" &&
        GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" GIT_COMMON_DIR="$outer/.git" \
            HOME="$super" \
            TMUX='' TMUX_TMPDIR="$super/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 45 2>&1)" || rc=$?
    assert_exit 0 "$rc" \
        "worktree-new exits 0 from inside a submodule despite a tainted git environment"
    assert_file_exists "$super/.worktrees/issue-45/app.txt" \
        "the worktree lands at <super>/.worktrees/issue-45 with the superproject's files"
    assert_true '[ ! -e "'"$super"'/.git/modules/mod/.worktrees" ]' \
        "nothing landed under <super>/.git/modules (the #324 bug path)"

    # The branch ref must land in the superproject, not the tainted outer repo
    # (#328 no-split-brain). Query through a scrubbed env so the check is not
    # itself tainted.
    local super_branch outer_branch
    super_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" branch --list "feature/issue-45")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-45")"
    assert_not_empty "$super_branch" \
        "the branch ref lands in the superproject, not the tainted GIT_DIR target"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo (no split-brain)"
}

# Regression (#368, deferred from PR #367's pre-PR review): worktree-new.sh's
# top-level `unset $(_git_env_scrub_names)` documents a deliberate FAIL-LOUD
# contract — "NO `|| true`: a readonly GIT_DIR makes `unset` fail, which under
# `set -e` aborts LOUDLY before any mutation." config.sh's repo_root has the
# analogous guarantee covered (test_config_repo_root_scrubs_readonly_tainted_git_env,
# #328), but the script itself had no test invoking it under a `declare -rx`
# taint, so a future edit adding `|| true` or restructuring the unset would
# silently regress the guarantee. This pins it: a readonly-exported
# GIT_DIR/GIT_COMMON_DIR must make worktree-new EXIT NON-ZERO and mutate NOTHING.
#
# The taint MUST be applied by SOURCING the script (not the plain `bash script`
# form run_in uses): the `declare -rx` READONLY attribute is dropped across
# `exec`, so a child bash launched to run the script would inherit only the
# exported VALUE, not the readonly-ness — its `unset` would succeed and the
# fail-loud path would never be exercised. Sourcing inside a bash that first
# declared the readonly vars keeps them readonly when the script's `unset` runs.
# Mirrors test_config_repo_root_scrubs_readonly_tainted_git_env's `declare -rx`
# setup, applied to the whole script. No GIT_SCRUB on the invocation — the taint
# is the whole point; the script's own guard must abort on it.
test_worktree_new_readonly_tainted_git_env_fails_loud() {
    local sb outer
    new_sandbox sb
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1

    # Source worktree-new inside a child bash that makes GIT_DIR/GIT_COMMON_DIR
    # `declare -rx` (readonly + exported) BEFORE the script's `unset` runs, so the
    # unset fails and `set -e` aborts. Pin GOLEM_* / HOME like run_in does.
    local out rc=0
    out="$(cd "$sb" &&
        HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" -c \
            'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1" 78' \
            _ "$WT_NEW" "$outer" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" \
        "worktree-new aborts NON-ZERO under a readonly-tainted git environment (fail-loud)"
    # The LOUD half of fail-loud (#368). The exit code alone does not distinguish
    # an abort that says why from one that dies silently, leaving an operator with
    # a non-zero status and no cause. `$out` captured both streams above and was
    # previously discarded — shellcheck flagged it unused once this file was split
    # out of the 5,787-line monolith, where a sibling `$out` read masked it.
    assert_contains "$out" "readonly variable" \
        "worktree-new names the readonly GIT_* variable it could not unset (the LOUD half of fail-loud, #368)"

    # No mutation: no branch in the sandbox OR the outer repo, and no worktree dir.
    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-78")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-78")"
    assert_output_empty "$sb_branch" \
        "no branch ref created in the sandbox (aborted before the mutation)"
    assert_output_empty "$outer_branch" \
        "no branch ref leaked into the outer/tainted repo"
    assert_true "[ ! -e \"$sb/.worktrees/issue-78\" ]" \
        "no worktree dir created (aborted before git worktree add)"
}
