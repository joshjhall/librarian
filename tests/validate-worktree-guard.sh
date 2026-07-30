#!/usr/bin/env bash
# Coverage for the PreToolUse worktree-scope guard hook
# plugins/workflow/hooks/worktree-guard.sh (issues #475, #501).
#
# #501 extends the guard from the standard topology to per-topology main_root
# derivation from the common-dir PATH STRUCTURE (NOT worktree-writable config): a
# SUBMODULE-vendored worktree leak into the submodule's real checkout is now
# DENIED (was an interim loud fail-open). A BARE-repo host / EXOTIC (e.g.
# separate-git-dir) gitdir cannot be scoped from the path alone, and the only
# remaining discriminator (core.bare) is worktree-poisonable, so a CROSS-TREE
# target there fails open LOUDLY — while the host's own-worktree edits pass the
# topology-independent worktree-first allow silently. Because the derivation must
# survive the golem poisoning core.bare/core.worktree in the shared config (two
# #501 pre-PR review CRITICALs, dynamic-repro'd), dedicated poison + stray-
# misconfig + separate-git-dir cases assert no such write yields a silent allow.
# #506 closes the remaining trust-anchor gap: a golem rewriting its own $WT/.git
# gitlink to a decoy repo used to forge the #475 main-session identity gate and
# disarm the guard. The identity gate now cross-checks an OUTERMOST enclosing
# genuine primary (a structural anchor above the worktree the golem cannot forge);
# dedicated gitlink-poison cases (+ registry-delete and nearer-decoy compounding
# vectors, + the disarming-write deny, + a separate-git-dir false-positive guard)
# assert the forged identity no longer yields a silent allow. Cases below.
#
# The guard blocks a golem worktree session from editing a MAIN-CHECKOUT path
# (the silent absolute-path leak that can revert a merged PR), while never
# blocking the main session or legitimate worktree/out-of-repo edits. The
# behaviours that carry the risk a silent regression would ship unnoticed:
#   1. POSITIVE-BLOCK — a worktree session (git-dir != git-common-dir) editing a
#      path under the MAIN checkout but outside its worktree must be DENIED. A
#      scoping regression that turned the guard into a permanent no-op would
#      silently defeat the control; the block-case assertions fail CI if it does.
#   2. WORKTREE + MAIN SAFETY — an edit to the CORRECT worktree path, and any
#      edit from the MAIN session (git-dir == git-common-dir), must be ALLOWED. A
#      guard that blocked either would break the happy path.
#   3. OUT-OF-REPO / RELATIVE carve-out — an absolute target outside the repo
#      (/tmp, $HOME/...) or a relative target must be ALLOWED (not this guard's
#      concern; a relative path resolves against the worktree cwd).
#
# Unlike bash-guard (which needs no git), the discriminator here is git-worktree
# scope, so each case runs against a REAL on-disk fixture: a `git init` sandbox
# (the "main" checkout) plus a real linked worktree via `git worktree add`. The
# payload's `cwd` selects which side the call comes from. git's hook-exported
# environment (GIT_DIR/GIT_COMMON_DIR/…) is scrubbed so it cannot pin the hook's
# `git -C "$cwd"` to this OUTER repo — same GIT_SCRUB convention as
# validate-golem-scripts.sh.
#
# The guard's decision travels in its STDOUT JSON (permissionDecision deny) or
# its absence (allow), not the exit code (always 0). The no-jq path is exercised
# via a PATH-stub (bash + git only) to prove the pure-bash fallback still
# enforces #1 and preserves #2. A hooks.json-integrity block asserts the guard
# is actually registered.
#
# Pure bash + coreutils (+ jq for decision parsing, which skips cleanly when jq
# is absent), reached via absolute /usr/bin/* paths per project convention. Uses
# the shared harness assertions.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-topology
# fragments under tests/worktree-guard/, and the three shared repo fixtures plus
# the run_guard/decision runner live in tests/lib/worktree-guard-fixtures.sh.
# The explicit FRAGMENTS list below fixes the source order and is guarded, so an
# unwired fragment cannot silently contribute zero tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# All read by tests/lib/worktree-guard-fixtures.sh and the area fragments, both
# sourced below — shellcheck analyses one file at a time and so cannot see those
# uses. The `{ ... }` group is what gives the directive block scope; a bare
# directive line only covers the statement that follows it.
# shellcheck disable=SC2034  # consumed by the sourced fixtures/fragments, not by this file
{
    GUARD="$REPO_ROOT/plugins/workflow/hooks/worktree-guard.sh"
    HOOKS_JSON="$REPO_ROOT/plugins/workflow/hooks/hooks.json"

    # Resolve the real bash + git once so the no-jq case (which strips PATH) still
    # finds an interpreter and git.
    REAL_BASH="$(command -v bash)"
    REAL_GIT="$(command -v git)"

    # git env that must NOT leak into the fixture or the hook's own `git -C` — else
    # the OUTER repo's GIT_DIR pins scope to the wrong tree. Held as an array so the
    # `${arr[@]/#/--unset=}` expansion (bash-3.2 clean) yields one arg per var — the
    # same idiom validate-golem-scripts.sh uses.
    GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "worktree-guard.sh PreToolUse hook (#475, #501)"

# --- Shared fixtures + area fragments ---------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# Sourcing this BUILDS the three repo topologies under $FIXTURE (side-effecting
# by design — see the file header) and defines run_guard/decision/jq_required.
# shellcheck source=tests/lib/worktree-guard-fixtures.sh
source "$SCRIPT_DIR/lib/worktree-guard-fixtures.sh"

source_fragments "$SCRIPT_DIR/worktree-guard" \
    10-basic-decisions.sh \
    20-submodule.sh \
    30-config-poisoning.sh \
    40-bare-and-exotic.sh \
    50-gitlink-disarm.sh \
    60-failure-modes.sh

# --- Dispatch ---------------------------------------------------------------
run_fragment_test test_deny_leak_edit "deny: worktree->main leak (Edit)"
run_fragment_test test_deny_leak_write_nested "deny: worktree->main leak (nested Write)"
run_fragment_test test_deny_leak_notebook "deny: worktree->main leak (NotebookEdit)"
run_fragment_test test_deny_reason_names_paths "deny reason names paths + recovery"
run_fragment_test test_allow_worktree_path "allow: correct worktree path"
run_fragment_test test_allow_worktree_nested_new "allow: new file under the worktree"
run_fragment_test test_allow_main_session "main-session: edit of own tree allowed"
run_fragment_test test_allow_out_of_repo_tmp "allow: out-of-repo /tmp target"
run_fragment_test test_allow_relative_path "allow: relative target"
run_fragment_test test_deny_dotdot_into_main "review2: \$WT/.. into main is denied (normalized)"
run_fragment_test test_allow_dot_within_worktree "review2: ./.. within worktree allowed"
run_fragment_test test_root_escape_failopen "review2: root-escaping .. fails open"
run_fragment_test test_submodule_deny_leak "#501: submodule leak into real checkout is DENIED"
run_fragment_test test_submodule_allow_own_worktree "#501: submodule worktree's own path allowed"
run_fragment_test test_submodule_poison_still_denies "#501: submodule config poison does NOT disarm"
run_fragment_test test_poison_core_bare_still_denies "#501: core.bare=true poison still denies (non-poisonable)"
run_fragment_test test_poison_core_worktree_still_denies "#501: core.worktree decoy poison still denies"
run_fragment_test test_poison_worktree_config_toplevel_still_denies "#501: worktreeConfig toplevel redirect still denies"
run_fragment_test test_stray_core_bare_misconfig_still_denies "#501: stray core.bare misconfig still denies"
run_fragment_test test_bare_host_own_worktree_allows_silently "#501: bare-host own worktree allowed silently"
run_fragment_test test_bare_host_cross_tree_failopen_is_loud "#501: bare-host cross-tree fails open LOUDLY"
run_fragment_test test_exotic_sgd_cross_tree_failopen_is_loud "#501: separate-git-dir cross-tree fails open LOUDLY"
run_fragment_test test_exotic_sgd_core_bare_poison_stays_loud "#501: core.bare poison stays loud (no silent-allow)"
run_fragment_test test_gitlink_poison_denies_leak "#506: gitlink-rewrite decoy still DENIES a leak"
run_fragment_test test_gitlink_poison_core_worktree_still_denies "#506: gitlink + core.worktree redirect still DENIES (CRITICAL)"
run_fragment_test test_gitlink_poison_core_bare_still_denies "#506: gitlink + core.bare poison still DENIES (CRITICAL)"
run_fragment_test test_gitlink_initdir_variant_denies "#506: git-init-the-worktree DIR-variant disguise DENIED"
run_fragment_test test_gitlink_poison_nested_cwd_denies "#506: poisoned session from a nested cwd still DENIES"
run_fragment_test test_gitlink_poison_allows_own_worktree "#506: poisoned worktree's own path still allowed"
run_fragment_test test_gitlink_poison_plus_registry_delete_denies "#506: poison + registry delete still DENIES (Bypass 1)"
run_fragment_test test_gitlink_poison_nearer_decoy_denies "#506: nearer-decoy still DENIES (Bypass 2, outermost wins)"
run_fragment_test test_gitlink_write_denied "#506: disarming write to \$WT/.git is DENIED (FIX B)"
run_fragment_test test_gitlink_write_slash_variants_denied "#506: slash-variant \$WT//.git / \$WT/.git/ write DENIED (HIGH)"
run_fragment_test test_gitlink_sgd_main_not_misdetected "#506: genuine separate-git-dir main not misdetected"
run_fragment_test test_gitlink_nojq_denies_leak "#506: no-jq path still denies a poisoned leak"
run_fragment_test test_gitlink_nojq_denies_write "#506: no-jq path still denies the gitlink write"
run_fragment_test test_parse_empty_allows "parse-fail: empty stdin allows"
run_fragment_test test_parse_empty_is_loud "parse-fail: empty stdin is loud"
run_fragment_test test_parse_nonjson_allows "parse-fail: non-JSON allows"
run_fragment_test test_no_target_allows "no target path: allows"
run_fragment_test test_nojq_denies_leak "no-jq: still denies a leak"
run_fragment_test test_nojq_allows_main "no-jq: still allows a main edit"
run_fragment_test test_nojq_allows_worktree "no-jq: still allows the worktree edit"
run_fragment_test test_hooks_registered "hooks.json registers the guard"
run_fragment_test test_guard_executable "worktree-guard.sh is executable"

generate_report
