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

# --- credential-helper seeding (#810) ---------------------------------------
#
# Every golem worktree used to start unable to push over HTTPS ("fatal: could
# not read Username"), because git had no credential helper wired to the token
# `gh`/`glab` already holds. worktree-new.sh now seeds one. These cases pin the
# decisions that block makes — IS a helper written, for WHICH host, naming WHICH
# cli — plus the no-op arms that must stay silent.
#
# new_sandbox creates a repo with NO remote, and run_in pins GOLEM_BASE_REF=HEAD
# (no remote component), so every case here sets its own remote and invokes
# directly with GOLEM_BASE_REF=origin/main, mirroring the direct-env pattern of
# test_worktree_new_copies_local_files above.

# _cred_run <sandbox> <issue-n> [stub-dir]
# Run worktree-new in the sandbox with a real remote in play. When <stub-dir> is
# given it becomes the ENTIRE PATH (holding only symlinks to the real
# bash/git/env), which is how the cli-absent arm is FORCED rather than skipped —
# a skip-if-absent test would only ever exercise the cli-PRESENT arm on a host
# that has gh. Sets RUN_RC/RUN_OUT like run_in.
#
# BASH_ENV is unset for the same reason gate_age_unit's nojq arm unsets it
# (tests/lib/golem-sandbox.sh): this image points BASH_ENV at /etc/bash_env,
# which every non-interactive bash sources and which REBUILDS PATH — silently
# restoring `gh` and turning the cli-absent case into a second cli-present case
# that passes for the wrong reason. Measured here: without the unset,
# `command -v gh` still resolved /usr/bin/gh under a PATH of just the stub dir.
# A 4th optional arg overrides GOLEM_BASE_REF (e.g. `upstream/main`), so the
# `cred_remote` reuse of a NON-default remote name can be exercised.
_cred_run() {
    local sb="$1" n="$2" stub="${3:-}" path_env base_ref="${4:-origin/main}" _cr_t
    if [ -n "$stub" ]; then
        # A symlink FARM: every executable on the real PATH except gh/glab, so
        # the ONLY difference from a normal run is the absent platform cli.
        # Enumerating the handful of tools the script "needs" instead is the
        # wrong shape — it is an ever-growing list that fails 127 at a new tool
        # each time (measured: dirname, then basename/uname via git-submodule,
        # then mktemp via seed-worktree-trust.sh), and each such failure looks
        # like the no-op arm being exercised when it is really a broken fixture.
        command mkdir -p "$stub"
        local _cr_d _cr_f
        for _cr_d in $(command printf '%s\n' "$PATH" | command tr ':' ' '); do
            [ -d "$_cr_d" ] || continue
            for _cr_f in "$_cr_d"/*; do
                [ -x "$_cr_f" ] || continue
                _cr_t="${_cr_f##*/}"
                case "$_cr_t" in
                    gh | glab) continue ;;
                esac
                # First PATH dir wins, mirroring real PATH resolution order.
                [ -e "$stub/$_cr_t" ] || command ln -sf "$_cr_f" "$stub/$_cr_t"
            done
        done
        command ln -sf "$REAL_BASH" "$stub/bash"
        path_env="$stub"
    else
        path_env="$PATH"
    fi
    # No remote configured ⇒ no origin/main ref either, and `worktree add` would
    # die 128 on the invalid reference LONG before the credential block runs —
    # the fixture would then "fail" for a reason that has nothing to do with what
    # it is pinning. Fall back to HEAD, which is also the realistic shape: a repo
    # with no remote has no remote-tracking base ref to fork from.
    # Probe the remote the CALLER's base_ref actually names, not a hardcoded
    # `origin` — an upstream/main fixture has no `origin` and would otherwise be
    # forced to HEAD, silently skipping the very remote-reuse it exists to test.
    if [ -z "$(_cred_helper_remote_url "$sb" "${base_ref%%/*}")" ]; then
        base_ref="HEAD"
    fi
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" PATH="$path_env" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF="$base_ref" \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" "$n" 2>&1)" || RUN_RC=$?
}

# _cred_helper_remote_url <sandbox> — the sandbox's origin URL, or empty when it
# has no origin. Used by _cred_run to pick a base ref that actually resolves.
# _cred_helper_remote_url <sandbox> [remote-name] — that remote's URL, or empty.
_cred_helper_remote_url() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$1" remote get-url "${2:-origin}" 2>/dev/null || true
}

# _cred_set_remote <sandbox> <url> [remote-name]
# Give the sandbox a remote (default `origin`) plus a local <remote>/main ref,
# so GOLEM_BASE_REF=<remote>/main resolves with no network. The name is a
# parameter so a fixture can prove worktree-new REUSES the remote derived from
# GOLEM_BASE_REF rather than always landing on the `:-origin` fallback.
_cred_set_remote() {
    local sb="$1" url="$2" name="${3:-origin}"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" remote add "$name" "$url"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" update-ref "refs/remotes/$name/main" HEAD
}

# _cred_helper_of <sandbox> <host> — the configured helper for <host>, or empty.
_cred_helper_of() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$1" config --get "credential.$2.helper" 2>/dev/null || true
}

# _cred_any_helper <sandbox> — EVERY credential.*.helper key set anywhere in the
# repo config, so a no-op arm is asserted against all hosts rather than only the
# one host the test happened to think of.
_cred_any_helper() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$1" config --get-regexp '^credential\..*\.helper$' 2>/dev/null || true
}

# AC1/AC2: an https GitHub remote with `gh` present gets the gh helper, keyed on
# the derived host. This is the arm that fixes the reported bug.
test_worktree_new_seeds_credential_helper_github() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://github.com/acme/widget.git"
    _cred_run "$sb" 81
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with an https GitHub remote"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://github.com")" \
        "the gh credential helper is seeded for https://github.com (#810)"
    assert_contains "$RUN_OUT" "seeded git credential helper" \
        "reports the seeding, so a silent no-op is distinguishable from success"
}

# AC3: the platform cli absent → a clean no-op. No config for ANY host, no hard
# failure, and the worktree is still created.
test_worktree_new_credential_helper_no_cli_is_noop() {
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://github.com/acme/widget.git"
    _cred_run "$sb" 82 "$sb/stub-bin"
    assert_exit 0 "$RUN_RC" "worktree-new still exits 0 when the platform cli is absent"
    assert_output_empty "$(_cred_any_helper "$sb")" \
        "no credential helper is written for any host when gh is absent (#810 AC3)"
    assert_true "[ -d \"$sb/.worktrees/issue-82\" ]" \
        "the worktree is still created — credential seeding is best-effort"
    assert_not_contains "$RUN_OUT" "WARNING — could not seed" \
        "an absent cli is a silent no-op, not a warning"
}

# AC3: an ssh remote authenticates with keys and needs no helper — configuring
# one would be spurious config for no benefit. scp-short form.
test_worktree_new_credential_helper_ssh_remote_is_noop() {
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "git@github.com:acme/widget.git"
    _cred_run "$sb" 83
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with an ssh remote"
    assert_output_empty "$(_cred_any_helper "$sb")" \
        "no credential helper is written for an ssh remote (#810 AC3)"
}

# AC3, and the case that actually pins the https-only guard. The scp-short form
# above is NOT sufficient: dropping the `https://*` guard leaves it deriving the
# nonsense host `https://github.com:acme` (the `:` is a path separator in that
# form, not a port), which matches no entry in the platform table, so it no-ops
# for the WRONG reason and the mutation survives — measured. The `ssh://` URL
# form has a real `/`-delimited host, so with the guard dropped it derives
# `https://github.com`, selects gh, and writes a helper for a remote that never
# needed one. This fixture is the one where guarded and unguarded diverge.
test_worktree_new_credential_helper_ssh_url_form_is_noop() {
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "ssh://git@github.com/acme/widget.git"
    _cred_run "$sb" 87
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with an ssh:// URL remote"
    assert_output_empty "$(_cred_any_helper "$sb")" \
        "an ssh:// remote gets no credential helper — the https-only guard holds (#810 AC3)"
}

# The cli choice is DERIVED, not hardcoded to gh: a GitLab host selects glab.
# This is the case that fails if the platform table collapses to a single cli.
test_worktree_new_seeds_credential_helper_gitlab() {
    if ! command -v glab >/dev/null 2>&1; then
        skip_test "glab not available — cannot exercise the GitLab cli arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://gitlab.com/acme/widget.git"
    _cred_run "$sb" 84
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with an https GitLab remote"
    assert_equals "!glab auth git-credential" \
        "$(_cred_helper_of "$sb" "https://gitlab.com")" \
        "a GitLab remote selects the glab helper, not gh (#810 host generality)"
}

# Host generality: a self-hosted GHE remote keys the config on ITS OWN host, and
# carries userinfo the derivation must strip. A github.com fixture cannot show
# this — the host must DIFFER from the hardcoded value for the assertion to have
# teeth, which is why the negative assertion below names github.com explicitly.
test_worktree_new_credential_helper_self_hosted_host() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://bot@ghe.example.com/acme/widget.git"
    _cred_run "$sb" 85
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a self-hosted GHE remote"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://ghe.example.com")" \
        "the helper is keyed on the derived host, with userinfo stripped (#810)"
    assert_output_empty "$(_cred_helper_of "$sb" "https://github.com")" \
        "nothing is written for github.com — the host is derived, not hardcoded"

    # userinfo is stripped up to the LAST `@`, not the first: a URL-embedded
    # password may itself contain one. With a first-`@` strip this URL derives
    # the host `ss@ghe.example.com`, which matches no anchored pattern and
    # silently no-ops — so a single-`@` fixture cannot tell the two apart.
    new_sandbox sb
    _cred_set_remote "$sb" "https://bot:p@ss@ghe.example.com/acme/widget.git"
    _cred_run "$sb" 185
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on a multi-@ userinfo URL"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://ghe.example.com")" \
        "userinfo is stripped to the LAST @, so the host is still derived (#810)"
}

# No remote at all → nothing to derive a host from; a clean no-op.
test_worktree_new_credential_helper_no_remote_is_noop() {
    local sb
    new_sandbox sb
    _cred_run "$sb" 86
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with no remote configured"
    assert_output_empty "$(_cred_any_helper "$sb")" \
        "no credential helper is written when there is no remote (#810 AC3)"
}

# The verify/WARNING arm (#810 review, blocking). The other cases only ever
# reach the git-config write on a happy path, so the fail-loud branch the source
# comment promises ("Verify rather than assume") had ZERO coverage — untested
# error handling, which this repo's failure-class list flags explicitly.
#
# Forcing it needs the write to SILENTLY NOT TAKE, which is the exact scenario
# the verify exists to catch. `chmod 444 .git/config` does NOT do that (measured:
# git writes via a lockfile + rename, so the set still succeeds); instead shadow
# `git` with a wrapper that swallows only the credential-helper SET and passes
# every other invocation — including the `--get` read-back — through to the real
# binary. The worktree must still be created and the exit still 0: seeding is
# best-effort, and a credential failure must never abort an otherwise-good
# worktree.
test_worktree_new_credential_helper_verify_failure_warns() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb realgit
    new_sandbox sb
    realgit="$(command -v git)"
    _cred_set_remote "$sb" "https://github.com/acme/widget.git"

    command mkdir -p "$sb/swallow-bin"
    command cat >"$sb/swallow-bin/git" <<EOF
#!/usr/bin/env bash
# Swallow ONLY the credential-helper set (a set carries a value after the key;
# a --get does not). Everything else, the read-back included, passes through.
for a in "\$@"; do
    case "\$a" in
        credential.*.helper)
            case " \$* " in
                *" --get "*) : ;;
                *) exit 0 ;;
            esac
            ;;
    esac
done
exec "$realgit" "\$@"
EOF
    command chmod +x "$sb/swallow-bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/swallow-bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=origin/main \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_NEW" 88 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" \
        "a failed credential seed does NOT abort the worktree (best-effort)"
    assert_contains "$RUN_OUT" "WARNING" \
        "the verify failure warns rather than passing silently (#810 fail-loud)"
    assert_contains "$RUN_OUT" "https://github.com" \
        "the warning names the host it could not seed"
    assert_not_contains "$RUN_OUT" "seeded git credential helper" \
        "a failed seed does not also claim success"
    assert_true "[ -d \"$sb/.worktrees/issue-88\" ]" \
        "the worktree is still created despite the credential failure"
    assert_output_empty "$(_cred_helper_of "$sb" "https://github.com")" \
        "the helper genuinely did not land — the warning is not a false alarm"
}

# Hostname anchoring (#810 review, blocking-security). An UNANCHORED `*github.com`
# glob also matches `evil-github.com` and `notarealgithub.com` (measured: both
# selected gh), and `*ghe.*` matches that sequence anywhere. Nothing leaks a
# credential — gh/glab each gate on hosts they recognize — but the block would
# still write a `credential.<lookalike>.helper` entry into the SHARED .git/config
# keyed off attacker-influenceable URL text, from inside a credential-wiring
# path. A `github.com` fixture cannot show this: the host must be a LOOKALIKE for
# anchored and unanchored to diverge.
#
# EVERY arm of the case table gets its own lookalike, because the mutation round
# proved a single github.com lookalike is not enough: un-anchoring ONLY the
# `ghe.` arm left this test green (asymmetric mutation survives a partially
# neutered predicate). One lookalike per arm — github.com, ghe., gitlab.com,
# gitlab. — is what makes each arm independently pinned.
test_worktree_new_credential_helper_lookalike_host_is_noop() {
    if ! command -v gh >/dev/null 2>&1 || ! command -v glab >/dev/null 2>&1; then
        skip_test "gh and glab both required — this pins BOTH cli arms"
        return 0
    fi
    local sb n=89 host
    # One lookalike per case-table arm. Each would be matched by the
    # corresponding UNANCHORED glob and must be rejected by the anchored one.
    for host in evil-github.com evil-ghe.example.com evil-gitlab.com notagitlab.com; do
        new_sandbox sb
        _cred_set_remote "$sb" "https://$host/acme/widget.git"
        _cred_run "$sb" "$n"
        assert_exit 0 "$RUN_RC" "worktree-new exits 0 on lookalike host $host"
        assert_output_empty "$(_cred_any_helper "$sb")" \
            "lookalike host $host matches no anchored pattern — NO helper (#810)"
        n=$((n + 100))
    done
}

# The other half of anchoring: a legitimate SUBDOMAIN must still match. Pinning
# only the lookalike rejection would be satisfied by a pattern that rejects
# everything, so this is what stops the anchoring from being over-tightened.
test_worktree_new_credential_helper_subdomain_host_seeds() {
    if ! command -v gh >/dev/null 2>&1 || ! command -v glab >/dev/null 2>&1; then
        skip_test "gh and glab both required — this pins BOTH cli arms"
        return 0
    fi
    local sb
    # ghe. arm — a genuine GitHub Enterprise subdomain.
    new_sandbox sb
    _cred_set_remote "$sb" "https://ghe.corp.example.com/acme/widget.git"
    _cred_run "$sb" 91
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on a ghe. subdomain host"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://ghe.corp.example.com")" \
        "a genuine ghe.* host still matches after anchoring (#810)"

    # github.com arm — a real subdomain of github.com.
    new_sandbox sb
    _cred_set_remote "$sb" "https://api.github.com/acme/widget.git"
    _cred_run "$sb" 191
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://api.github.com")" \
        "a genuine *.github.com subdomain still matches after anchoring (#810)"

    # gitlab arm — both a self-hosted gitlab.* host and gitlab.com itself are
    # covered elsewhere; this pins the anchored *.gitlab.com subdomain.
    new_sandbox sb
    _cred_set_remote "$sb" "https://registry.gitlab.com/acme/widget.git"
    _cred_run "$sb" 291
    assert_equals "!glab auth git-credential" \
        "$(_cred_helper_of "$sb" "https://registry.gitlab.com")" \
        "a genuine *.gitlab.com subdomain still matches after anchoring (#810)"
}

# An https remote whose host matches NEITHER platform pattern, with the cli
# present — a third, distinct no-op reason the source comment enumerates
# ("unrecognized host"), separate from 'ssh remote' and 'cli absent'. This is
# the arm that catches the case table silently widening.
test_worktree_new_credential_helper_unrecognized_host_is_noop() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://bitbucket.org/acme/widget.git"
    _cred_run "$sb" 92
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on an unrecognized host"
    assert_output_empty "$(_cred_any_helper "$sb")" \
        "an unrecognized https host gets no helper, cli present (#810 AC3)"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "an unrecognized host is a silent no-op, not a warning"
}

# A ported host (#810 cycle-2 review). The source comment claims the `:port` is
# stripped for the MATCH but KEPT in the config key — an assertion no fixture
# checked, which is this repo's "comment asserts an intent the code may not
# implement" class. Both halves are pinned here: the helper is written (so the
# match saw a port-free host) AND it is keyed WITH the port (because git's
# credential lookup matches the full URL, so a port-less key would never be
# consulted for this remote).
#
# The host MUST be one matched by a fully ANCHORED arm. A `ghe.example.com:8443`
# fixture cannot detect the strip at all: `ghe.*` is a prefix match, so it
# matches with the port still attached and the test passes either way (measured
# — the mutation survived it). `github.com:8443` matches only once the port is
# gone, which is what makes this fixture divergent.
test_worktree_new_credential_helper_ported_host_seeds() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://github.com:8443/acme/widget.git"
    _cred_run "$sb" 93
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 on a ported host"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://github.com:8443")" \
        "a ported host still matches, and is keyed WITH its port (#810)"
    assert_output_empty "$(_cred_helper_of "$sb" "https://github.com")" \
        "the port is NOT stripped from the config key — git looks up the full URL"
}

# An `@` in the PATH with no userinfo at all (#810 cycle-2 review). A greedy
# `##*@` over the whole post-scheme string eats the host too:
# `https://ghe.example.com/org/repo@release.git` derived the host `release.git`
# (verified). Splitting the authority off BEFORE stripping userinfo fixes it.
# Neither the plain fixture nor the multi-@ userinfo one can catch this — the
# divergent input needs an `@` after the first `/`.
test_worktree_new_credential_helper_at_in_path_still_derives_host() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://ghe.example.com/org/repo@release.git"
    _cred_run "$sb" 94
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with an @ in the remote path"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://ghe.example.com")" \
        "an @ in the PATH does not corrupt the derived host (#810)"
    assert_output_empty "$(_cred_helper_of "$sb" "https://release.git")" \
        "nothing is keyed on the path tail — the authority is split off first"
}

# `cred_remote="${base_remote:-origin}"` is meant to REUSE whatever remote name
# GOLEM_BASE_REF derived, so there is one notion of "which remote". Every other
# fixture uses `origin`, which is indistinguishable from the `:-origin` fallback
# firing — the reuse branch was untested. This drives an `upstream`-only sandbox
# with GOLEM_BASE_REF=upstream/main: with reuse working the helper is seeded from
# upstream's URL; if the code ignored base_remote and hardcoded `origin`, the
# lookup would find no remote and silently no-op.
test_worktree_new_credential_helper_reuses_non_origin_remote() {
    if ! command -v gh >/dev/null 2>&1; then
        skip_test "gh not available — cannot exercise the cli-present arm"
        return 0
    fi
    local sb
    new_sandbox sb
    _cred_set_remote "$sb" "https://github.com/acme/widget.git" upstream
    _cred_run "$sb" 95 "" "upstream/main"
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a non-origin base remote"
    assert_equals "!gh auth git-credential" \
        "$(_cred_helper_of "$sb" "https://github.com")" \
        "the credential remote is the one GOLEM_BASE_REF derived, not always origin (#810)"
}
