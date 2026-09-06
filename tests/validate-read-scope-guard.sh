#!/usr/bin/env bash
# Coverage for the PreToolUse read-scope guard hook
# plugins/workflow/hooks/read-scope-guard.sh (issue #630).
#
# A golem was isolated on the WRITE side (worktree-guard.sh, #475) but not on the
# READ side: nothing stopped its Read/Grep/Glob from wandering into a PEER
# golem's worktree, and in parallel /workflow:orchestrate batches the golems
# visibly discussed each other's work. Peer files sit on a DIFFERENT BRANCH AT A
# DIFFERENT BASE, so reasoning from them produces the stale-base class that has
# already reverted merged work here twice.
#
# THE FAILURE DIRECTION IS INVERTED VERSUS THE SIBLING WRITE GUARD, and that
# shapes this whole suite. An over-broad WRITE deny is a safe false positive (the
# golem re-issues against the path the message names). An over-broad READ deny
# WEDGES a golem mid-turn with no recovery path — it cannot read what it needs
# and no alternate spelling helps. So the guard denies only PEER `issue-*`
# worktrees, and the ALLOW cases here carry as much weight as the DENY ones:
#
#   1. POSITIVE-BLOCK — a golem reading a peer worktree must be DENIED, across
#      all three read tools and through `..`/slash normalization. A scoping
#      regression that turned the guard into a permanent no-op is what these
#      catch (10-peer-deny.sh).
#   2. CARVE-OUTS — my own worktree, the shared `.status/` feed, out-of-repo
#      paths, the MAIN checkout (deliberately allowed; #630 says extend later
#      behind evidence), the orchestrator session, and a relative or ABSENT
#      target. Each is exactly what a too-broad rule breaks, so each gets its own
#      case (20-carve-outs.sh).
#   3. SEARCH SURFACE — a repo-rooted search from a golem must return no peer
#      matches. Already true via `.gitignore` and measured so before implementing;
#      the fragment PINS it, with a leak fixture proving the exclusion has teeth
#      (30-search-surface.sh).
#   4. FAIL-OPEN + LOUD, the no-jq fallback, and registration (40-failure-modes.sh).
#
# The discriminator is git-worktree scope plus the on-disk SIBLING structure of
# the worktree directory, so — like validate-worktree-guard.sh and unlike
# validate-bash-guard.sh, whose discriminator is a payload field — each case runs
# against a REAL on-disk fixture: a `git init` main checkout, TWO linked
# worktrees (mine and a peer), and a `.status/` sibling. A second topology under
# a differently named worktree directory pins that the guard never reads the
# directory's NAME, so GOLEM_WORKTREE_DIR overrides and #626's move to
# `.claude/worktrees/` keep working. git's hook-exported environment is scrubbed
# so it cannot pin the hook's `git -C "$cwd"` to this OUTER repo — same GIT_SCRUB
# convention as validate-golem-scripts.sh.
#
# The guard's decision travels in its STDOUT JSON (permissionDecision deny) or
# its absence (allow), not the exit code (always 0). The no-jq path is exercised
# via a PATH-stub (bash + git only) to prove the pure-bash fallback still enforces
# AND still allows. A hooks.json-integrity block asserts the guard is registered —
# per CLAUDE.md a script alone is not.
#
# Pure bash + coreutils (+ jq for decision parsing, which skips cleanly when jq
# is absent), reached via absolute /usr/bin/* paths per project convention. Uses
# the shared harness assertions.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-area
# fragments under tests/read-scope-guard/, and the shared repo fixtures plus the
# run_guard/decision runner live in tests/lib/read-scope-guard-fixtures.sh. The
# explicit FRAGMENTS list below fixes the source order and is guarded, so an
# unwired fragment cannot silently contribute zero tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# All read by tests/lib/read-scope-guard-fixtures.sh and the area fragments, both
# sourced below — shellcheck analyses one file at a time and so cannot see those
# uses. The `{ ... }` group is what gives the directive block scope; a bare
# directive line only covers the statement that follows it.
# shellcheck disable=SC2034  # consumed by the sourced fixtures/fragments, not by this file
{
    GUARD="$REPO_ROOT/plugins/workflow/hooks/read-scope-guard.sh"
    HOOKS_JSON="$REPO_ROOT/plugins/workflow/hooks/hooks.json"

    # Resolve the real bash + git once so the no-jq case (which strips PATH) still
    # finds an interpreter and git.
    REAL_BASH="$(command -v bash)"
    REAL_GIT="$(command -v git)"

    # git env that must NOT leak into the fixture or the hook's own `git -C` — else
    # the OUTER repo's GIT_DIR pins scope to the wrong tree. Held as an array so the
    # `${arr[@]/#/--unset=}` expansion (bash-3.2 clean) yields one arg per var.
    GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "read-scope-guard.sh PreToolUse hook (#630)"

# --- Shared fixtures + area fragments ---------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# Sourcing this BUILDS the repo topologies under $FIXTURE (side-effecting by
# design — see the file header) and defines run_guard/decision/deny_reason/
# jq_required.
# shellcheck source=tests/lib/read-scope-guard-fixtures.sh
source "$SCRIPT_DIR/lib/read-scope-guard-fixtures.sh"

source_fragments "$SCRIPT_DIR/read-scope-guard" \
    10-peer-deny.sh \
    20-carve-outs.sh \
    30-search-surface.sh \
    40-failure-modes.sh

# --- Dispatch ---------------------------------------------------------------
run_fragment_test test_deny_peer_read "deny: golem->peer Read"
run_fragment_test test_deny_peer_grep "deny: golem->peer Grep (path field)"
run_fragment_test test_deny_peer_glob "deny: golem->peer Glob (path field)"
run_fragment_test test_deny_peer_notebook_read "deny: golem->peer NotebookRead (notebook_path)"
run_fragment_test test_allow_own_notebook_read "allow: my own NotebookRead"
run_fragment_test test_nojq_denies_peer_notebook_read "no-jq: denies a peer NotebookRead"
run_fragment_test test_hooks_matcher_covers_notebook_read "hooks.json matcher covers NotebookRead"
run_fragment_test test_deny_reason_names_peer_and_rule "deny reason names peer + rule + recourse"
run_fragment_test test_deny_peer_via_dotdot "deny: \$WT/../issue-N traversal (normalized)"
run_fragment_test test_deny_peer_via_relative_dotdot "deny: RELATIVE ../issue-N traversal (cycle-3 HIGH)"
run_fragment_test test_deny_peer_via_relative_grep_path "deny: RELATIVE peer path in Grep's path field"
run_fragment_test test_deny_worktree_dir_via_relative "deny: relative spelling of the worktree DIR"
run_fragment_test test_nojq_denies_relative_peer "no-jq: denies a relative peer traversal"
run_fragment_test test_deny_peer_double_slash "deny: doubled-slash peer path"
run_fragment_test test_deny_peer_trailing_slash "deny: trailing-slash peer dir"
run_fragment_test test_deny_peer_custom_worktree_dir "#626: peer deny fires under a custom worktree dir"
run_fragment_test test_deny_worktree_dir_itself "deny: search rooted at the shared worktree DIR"
run_fragment_test test_deny_worktree_dir_trailing_slash "deny: worktree DIR, trailing-slash spelling"
run_fragment_test test_deny_worktree_dir_reason_points_at_own_root "worktree-DIR deny reason points at my own root"
run_fragment_test test_deny_peer_from_forged_gitlink_session "#506: forged-gitlink session detected, degrades LOUDLY"
run_fragment_test test_deny_peer_survives_core_worktree_poison "#501: core.worktree poison cannot disarm the guard"
run_fragment_test test_allow_own_worktree "allow: my own worktree"
run_fragment_test test_allow_own_worktree_nested "allow: nested path in my own worktree"
run_fragment_test test_allow_status_dir "allow: the shared .status feed"
run_fragment_test test_allow_status_dir_glob "allow: globbing the .status dir"
run_fragment_test test_allow_out_of_repo_tmp "allow: out-of-repo /tmp target"
run_fragment_test test_allow_out_of_repo_home "allow: out-of-repo \$HOME target"
run_fragment_test test_allow_main_checkout_read "allow: MAIN checkout (narrow-by-design, #630)"
run_fragment_test test_allow_main_session_reading_peer "allow: orchestrator reading a worktree"
run_fragment_test test_allow_nested_primary_repo_silently "allow: nested independent repo, SILENTLY"
run_fragment_test test_allow_main_session_grep_all_worktrees "allow: orchestrator searching all worktrees"
run_fragment_test test_allow_relative_target "allow: relative target"
run_fragment_test test_allow_relative_own_subdir "allow: relative path in my own worktree"
run_fragment_test test_allow_relative_dot_prefixed "allow: ./-prefixed relative target"
run_fragment_test test_allow_relative_status_dir "allow: relative .status feed"
run_fragment_test test_allow_relative_repo_root "allow: relative path to the repo root"
run_fragment_test test_allow_absent_path_field "allow: Grep with no path (searches cwd)"
run_fragment_test test_allow_own_tree_custom_worktree_dir "#626: own tree allowed under a custom worktree dir"
run_fragment_test test_allow_own_read_under_forged_gitlink_session "#506: disguised session still reads its OWN tree"
run_fragment_test test_allow_non_worktree_issue_named_sibling "allow: issue-* sibling that is not a worktree"
run_fragment_test test_deny_real_peer_beside_the_decoy "deny: a REAL peer in that same parent"
run_fragment_test test_search_surface_excludes_peer "AC#4: repo-rooted search returns no peer matches"
run_fragment_test test_search_surface_exclusion_has_teeth "AC#4: the exclusion has teeth (leak fixture)"
run_fragment_test test_repo_gitignore_excludes_worktree_roots "this repo's .gitignore carries both worktree roots"
run_fragment_test test_parse_empty_allows "parse-fail: empty stdin allows"
run_fragment_test test_parse_empty_is_loud "parse-fail: empty stdin is loud"
run_fragment_test test_parse_nonjson_allows "parse-fail: non-JSON allows"
run_fragment_test test_no_cwd_allows_and_is_loud "no cwd: allows, and is loud"
run_fragment_test test_relative_target_no_cwd_allows_and_is_loud "relative target + no cwd: allows, and is loud"
run_fragment_test test_cwd_outside_repo_allows "cwd outside a git repo: allows"
run_fragment_test test_no_git_allows_and_is_loud "git unavailable: allows, and is loud"
run_fragment_test test_root_escaping_target_allows_and_is_loud "root-escaping target: allows, and is loud"
run_fragment_test test_redirected_root_fails_open_loudly "redirected worktree root degrades LOUDLY"
run_fragment_test test_nojq_denies_peer_read "no-jq: still denies a peer read"
run_fragment_test test_nojq_allows_own_worktree "no-jq: still allows my own worktree"
run_fragment_test test_nojq_allows_status_dir "no-jq: still allows the .status feed"
run_fragment_test test_nojq_allows_main_session "no-jq: still allows the orchestrator"
run_fragment_test test_nojq_grep_path_field_denies "no-jq: still denies a Grep via the path field"
run_fragment_test test_nojq_quoted_pattern_does_not_bypass_peer_deny "no-jq: quoted sibling field does NOT bypass the peer deny"
run_fragment_test test_nojq_truncated_path_fails_open_loudly "no-jq: truncated PATH fails open LOUDLY"
run_fragment_test test_hooks_registered "hooks.json registers the guard"
run_fragment_test test_hooks_json_valid "hooks.json has three PreToolUse matchers"
run_fragment_test test_guard_executable "read-scope-guard.sh is executable"

generate_report
