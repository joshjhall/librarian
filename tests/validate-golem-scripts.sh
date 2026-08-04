#!/usr/bin/env bash
# Coverage for the bundled golem/worktree helper scripts in
# plugins/workflow/scripts/ that had ZERO tests (issue #82): golem-launch.sh,
# worktree-new.sh, worktree-rm.sh, golem-attach.sh, and golem-status.sh.
#
# These scripts drive the orchestrate golem flow (worktree create/teardown,
# tmux dispatch, attach, status table). A silent regression in any exit code or
# guard — a botched usage exit, a preflight that stops surfacing missing rules,
# a worktree-rm that stops refusing dirty trees — would ship unnoticed because
# nothing exercised them. This gate pins the deterministic, side-effect-free
# paths: argument validation, exit codes, and the offline preflight/status
# rendering. It deliberately does NOT spin up real tmux sessions or docker
# containers — `launch` is driven only to its missing-worktree exit, and
# `golem-attach` only to its no-session-no-container exit.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The cases live in per-subsystem
# fragments under tests/golem-scripts/, and the shared sandbox plumbing lives in
# tests/lib/golem-sandbox.sh. Adding a case means editing the ONE fragment that
# owns that script; the explicit FRAGMENTS list below fixes the source order and
# is guarded so an unwired fragment cannot silently contribute zero tests.
#
# Test shape mirrors tests/validate-seed-worktree-trust.sh: each case runs the REAL
# script inside a fresh `git init` sandbox under a module-level `mktemp -d`, so
# the script's repo_root resolves the sandbox (never the librarian checkout).
# Every git call and script invocation is wrapped in
# `/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"` so git's hook-exported environment
# (GIT_DIR / GIT_COMMON_DIR / …) cannot pin repo_root to the OUTER repo when the
# suite runs from a `git push` pre-push hook — the failure mode root-caused in
# golem-gate-watch (PR #62). HOME is repointed at the sandbox for worktree-new
# because it transitively seeds trust into $HOME/.claude.json via
# seed-worktree-trust.sh — without the override a sandbox run would write the
# operator's real config.
#
# Pure bash + coreutils + git (+ jq for the preflight/status cases, which skip
# cleanly when jq is absent), reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/workflow/scripts"
# The scripts under test. Read by the area fragments under tests/golem-scripts/
# and by tests/lib/golem-sandbox.sh, all sourced below — shellcheck analyses one
# file at a time and so cannot see those uses, hence the block-scoped SC2034
# suppression. The `{ ... }` group is what gives the directive block scope; a
# bare directive line only covers the statement that follows it.
# shellcheck disable=SC2034  # consumed by the sourced fragments, not by this file
{
    LAUNCH="$SCRIPTS/golem-launch.sh"
    WT_NEW="$SCRIPTS/worktree-new.sh"
    WT_RM="$SCRIPTS/worktree-rm.sh"
    ATTACH="$SCRIPTS/golem-attach.sh"
    STATUS="$SCRIPTS/golem-status.sh"
    SCRAPE="$SCRIPTS/golem-token-scrape.sh"
    TRANSCRIPT_LIVENESS="$SCRIPTS/golem-transcript-liveness.sh"
    MODE_CHECK="$SCRIPTS/golem-mode-check.sh"
    INBOX="$SCRIPTS/golem-inbox.sh"
    CONFIG="$SCRIPTS/config.sh"
    # The Mode-3 container entrypoint lives as a bash code block inside this skill
    # doc (not a bundled script), so its write_status() is tested by extraction
    # (#415, mirrors validate-template-sync.sh's inline-template extraction).
    PROVISION_PROTOCOL="$REPO_ROOT/plugins/workflow/skills/provision-agent/provision-protocol.md"
}

# Both are read by the sourced fragments/library rather than by this file — same
# cross-file invisibility as the path consts above.
# shellcheck disable=SC2034  # consumed by the sourced fragments, not by this file
{
    # Resolve the real bash once so child invocations work even when PATH is
    # deliberately stripped (the no-jq cases).
    REAL_BASH="$(command -v bash)"

    # Git's hook-exported environment — scrub per invocation so each sandbox is
    # hermetic even under a pre-push hook (see validate-seed-worktree-trust.sh).
    GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
}

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem/worktree helper scripts (#82)"

# --- Shared plumbing + area fragments ---------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/golem-sandbox.sh
source "$SCRIPT_DIR/lib/golem-sandbox.sh"

# Area fragments, in source order. The numeric prefixes mirror the subsystem
# order the dispatch block below uses. Guarded by source_fragments: a *.sh in
# tests/golem-scripts/ that is missing from this list FAILS the suite rather
# than silently contributing nothing.
source_fragments "$SCRIPT_DIR/golem-scripts" \
    10-launch.sh \
    20-worktree-new.sh \
    30-config-repo-root.sh \
    40-worktree-rm.sh \
    50-attach.sh \
    60-status.sh \
    70-status-checkpoint.sh \
    80-token-scrape.sh \
    90-transcript-liveness.sh \
    100-mode-check.sh

# --- Run all tests ----------------------------------------------------------

# Every sandbox is built with `git init` + a commit, so the whole suite needs
# git. Gate it from inside a run_test-dispatched body so the counters stay
# consistent (skip_test is designed for within-test use).
git_unavailable() { ! command -v git >/dev/null 2>&1; }

test_git_available() {
    if git_unavailable; then
        skip_test "git not available — cannot build sandbox repos"
        return
    fi
    assert_true "command -v git" "git is available for sandbox construction"
}

run_test test_git_available "git is available (suite prerequisite)"

if git_unavailable; then
    generate_report
    exit $?
fi

run_fragment_test test_launch_no_arg_exits_2 "golem-launch: no subcommand exits 2"
run_fragment_test test_launch_bad_subcommand_exits_2 "golem-launch: unknown subcommand exits 2"
run_fragment_test test_launch_print_emits_new_session "golem-launch: print <N> emits a tmux new-session line"
run_fragment_test test_launch_print_non_numeric_exits_2 "golem-launch: print with a non-numeric issue exits 2"
run_fragment_test test_launch_print_level_flag_substituted "golem-launch: print <N> --level 3 substitutes the level, not hardcoded 4 (#301)"
run_fragment_test test_launch_print_level_defaults_to_4 "golem-launch: print <N> with no level defaults to 4 (#301)"
run_fragment_test test_launch_print_level_env_fallback "golem-launch: GOLEM_LEVEL is the env fallback for the level (#301)"
run_fragment_test test_launch_print_level_flag_beats_env "golem-launch: --level flag overrides GOLEM_LEVEL env (#301)"
run_fragment_test test_launch_print_level_out_of_range_exits_2 "golem-launch: --level out of range exits 2 (#301)"
run_fragment_test test_launch_print_level_missing_value_exits_2 "golem-launch: bare --level with no value exits 2 (#301)"
run_fragment_test test_launch_print_model_unset_omits_flag "golem-launch: unset GOLEM_MODEL emits no --model, byte-identical line (#487)"
run_fragment_test test_launch_print_model_set_both_claude_calls "golem-launch: GOLEM_MODEL splices --model into both claude calls (#487)"
run_fragment_test test_launch_dispatch_model_both_claude_calls "golem-launch: GOLEM_MODEL reaches the real launch dispatch, both claude calls (#487)"
run_fragment_test test_launch_dispatch_model_shell_metachars_escaped "golem-launch: GOLEM_MODEL shell-metachars are escaped, no injection (#487)"
run_fragment_test test_launch_missing_worktree_exits_2 "golem-launch: launch with a missing worktree exits 2"
run_fragment_test test_launch_preflight_rules_present_exits_0 "golem-launch: preflight with all rules present exits 0"
run_fragment_test test_launch_preflight_rules_missing_exits_3 "golem-launch: preflight with a missing rule exits 3"
run_fragment_test test_launch_version_match_passes "golem-launch: matched plugin version passes the skew guard"
run_fragment_test test_launch_version_skew_refuses_exit_3 "golem-launch: version skew refuses dispatch (exit 3)"
run_fragment_test test_launch_version_skew_escape_hatch "golem-launch: GOLEM_SKIP_VERSION_CHECK downgrades skew to a warning"
run_fragment_test test_launch_version_unknown_sentinel_skips "golem-launch: 'unknown' sentinel version skips the guard (no false positive)"
run_fragment_test test_launch_unset_home_does_not_crash "golem-launch: unset HOME does not crash the version guard"
run_fragment_test test_launch_version_undeterminable_skips "golem-launch: undeterminable version skips the guard"
run_fragment_test test_launch_auth_cache_injects_token "golem-launch: cache token is injected via tmux -e, never echoed (#244)"
run_fragment_test test_launch_auth_no_source_no_injection "golem-launch: no token source → no injection, no warning (#244)"
run_fragment_test test_launch_auth_op_hang_is_bounded "golem-launch: a hanging op read is time-bounded, dispatch completes (#244)"
run_fragment_test test_launch_auth_cache_marker_no_token_warns "golem-launch: cache marker but no token warns, still dispatches (#244)"
run_fragment_test test_worktree_new_non_integer_exits_2 "worktree-new: non-integer arg exits 2"
run_fragment_test test_worktree_new_creates_worktree "worktree-new: creates the issue worktree + branch"
run_fragment_test test_worktree_new_duplicate_exits_1 "worktree-new: duplicate worktree exits 1"
run_fragment_test test_worktree_new_existing_branch_exits_1 "worktree-new: lingering branch exits 1"
run_fragment_test test_worktree_new_no_hardcoded_usr_bin "worktree-new: no hardcoded /usr/bin/* tool paths (#228)"
run_fragment_test test_worktree_new_copies_local_files "worktree-new: copies GOLEM_WORKTREE_LOCAL_FILES into the worktree (#228)"
run_fragment_test test_worktree_new_inits_submodules "worktree-new: populates submodules in the fresh worktree (#325)"
run_fragment_test test_worktree_new_from_submodule_placement "worktree-new: from inside a submodule lands the worktree at <super>/.worktrees (#338, #324)"
run_fragment_test test_worktree_new_scrubs_tainted_git_env_for_mutations "worktree-new: scrubs a tainted GIT_DIR so the branch ref lands in the right repo (#328)"
run_fragment_test test_worktree_new_scrubs_git_config_injection_for_mutations "worktree-new: scrubs a GIT_CONFIG_* injection so the branch+worktree mutation lands in the right repo (#376, #328)"
run_fragment_test test_worktree_new_from_submodule_placement_under_taint "worktree-new: from inside a submodule UNDER a tainted git env lands worktree + branch at <super>, not .git/modules or the outer repo (#365, #338, #328)"
run_fragment_test test_worktree_new_readonly_tainted_git_env_fails_loud "worktree-new: aborts fail-loud (non-zero, no mutation) under a readonly-tainted GIT_DIR (#368)"
run_fragment_test test_config_repo_root_no_hardcoded_usr_bin "config.sh: repo_root has no hardcoded /usr/bin/* tool paths (#278)"
run_fragment_test test_config_repo_root_honors_path "config.sh: repo_root resolves via PATH, not command git (#278)"
run_fragment_test test_config_repo_root_dirname_root_edge "config.sh: repo_root returns '/' for a /.git common dir (#278)"
run_fragment_test test_config_repo_root_relative_common_dir "config.sh: repo_root absolutizes a relative common dir via command pwd (#278)"
run_fragment_test test_config_repo_root_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR/GIT_COMMON_DIR (#279)"
run_fragment_test test_config_repo_root_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR via env -u fallback (#328)"
run_fragment_test test_config_repo_root_scrubs_git_config_injection "config.sh: repo_root scrubs an injected GIT_CONFIG_* config value (#355)"
run_fragment_test test_config_repo_root_scrubs_git_config_parameters "config.sh: repo_root scrubs a GIT_CONFIG_PARAMETERS-injected config value (#355)"
run_fragment_test test_config_repo_root_scrubs_git_ceiling_directories "config.sh: repo_root scrubs a GIT_CEILING_DIRECTORIES discovery block (#355)"
run_fragment_test test_config_repo_root_scrubs_git_config_global "config.sh: repo_root scrubs a GIT_CONFIG_GLOBAL file-injected config value (#376, #355)"
run_fragment_test test_config_repo_root_scrubs_git_config_system "config.sh: repo_root scrubs a GIT_CONFIG_SYSTEM file-injected config value (#376, #355)"
run_fragment_test test_config_repo_root_scrubs_git_config_nosystem "config.sh: repo_root scrubs a GIT_CONFIG_NOSYSTEM invalid-bool taint (#376, #355)"
run_fragment_test test_config_repo_root_scrubs_git_discovery_across_filesystem "config.sh: repo_root scrubs a GIT_DISCOVERY_ACROSS_FILESYSTEM invalid-bool taint (#376, #355)"
run_fragment_test test_config_repo_root_submodule_superproject "config.sh: repo_root returns the superproject root inside a submodule (#324)"
run_fragment_test test_config_repo_root_submodule_superproject_scrubs_tainted_git_env "config.sh: repo_root scrubs a tainted GIT_DIR in the super_root probe inside a submodule (#337, #279)"
run_fragment_test test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env "config.sh: repo_root scrubs a READONLY tainted GIT_DIR in the super_root probe inside a submodule (#363, #337, #328)"
run_fragment_test test_config_repo_root_relative_super_root "config.sh: repo_root absolutizes a relative --show-superproject-working-tree via command pwd (#336)"
run_fragment_test test_config_git_env_scrub_vars_single_source "config.sh: GIT_ENV_SCRUB_VARS is the single source for the git-env scrub list (#356)"
run_fragment_test test_worktree_rm_non_integer_exits_2 "worktree-rm: non-integer arg exits 2"
run_fragment_test test_worktree_rm_absent_is_noop "worktree-rm: absent issue is a clean no-op (exit 0)"
run_fragment_test test_worktree_rm_round_trip "worktree-rm: round-trip removes worktree + branch"
run_fragment_test test_worktree_rm_kills_session_despite_has_session_false "worktree-rm: kills golem-N unconditionally despite a racy has-session false (#486)"
run_fragment_test test_worktree_rm_kill_session_failure_is_quiet_noop "worktree-rm: a failed kill-session stays a quiet exit-0 no-op, no phantom removal (#486)"
run_fragment_test test_worktree_rm_no_tmux_server_is_quiet_noop "worktree-rm: a host with no tmux server stays a silent exit-0 no-op (#533)"
run_fragment_test test_worktree_rm_kill_session_classifier "worktree-rm: tmux_kill_outcome separates an absent session from a real failure (#533)"
run_fragment_test test_worktree_rm_warns_on_unexpected_kill_failure "worktree-rm: an unexpected kill-session error warns instead of reporting a clean no-op (#533)"
run_fragment_test test_worktree_rm_warns_on_locked_socket "worktree-rm: a locked/wedged socket warns instead of passing as an absent server (#533)"
run_fragment_test test_worktree_rm_failed_warning_is_well_formed "worktree-rm: the failed warning handles empty stderr and strips control characters (#533)"
run_fragment_test test_worktree_rm_pins_c_locale_for_tmux "worktree-rm: tmux runs under LC_ALL=C so a translated strerror cannot cause spurious warnings (#533)"
run_fragment_test test_worktree_rm_kill_dispatch_handles_every_outcome "worktree-rm: the kill dispatch handles every classifier outcome explicitly (#533)"
run_fragment_test test_worktree_rm_emits_reaped_feed_line "worktree-rm: teardown emits a reaped feed line with the right id (#446)"
run_fragment_test test_worktree_rm_scrubs_tainted_git_env_for_mutations "worktree-rm: scrubs a tainted GIT_DIR so deletions target the right repo (#328)"
run_fragment_test test_worktree_rm_scrubs_git_config_injection_for_mutations "worktree-rm: scrubs a GIT_CONFIG_* injection so the teardown mutation targets the right repo (#376, #328)"
run_fragment_test test_worktree_rm_readonly_tainted_git_env_fails_loud "worktree-rm: aborts fail-loud (non-zero, no mutation) under a readonly-tainted GIT_DIR (#368)"
run_fragment_test test_worktree_rm_forces_past_clean_submodule "worktree-rm: forces past a clean populated submodule (#325)"
run_fragment_test test_worktree_rm_refuses_dirty_regular_file_with_submodule "worktree-rm: refuses dirty regular file even with a submodule (#325)"
run_fragment_test test_worktree_rm_repairs_stale_core_worktree "worktree-rm: repairs a stale main-repo core.worktree (#258)"
run_fragment_test test_worktree_rm_preserves_valid_core_worktree "worktree-rm: preserves a valid core.worktree (#258)"
run_fragment_test test_attach_non_integer_exits_2 "golem-attach: non-integer arg exits 2"
run_fragment_test test_attach_no_session_exits_1 "golem-attach: no session/container exits 1"
run_fragment_test test_status_empty_reports_no_golems "golem-status: empty state reports no active golems"
run_fragment_test test_status_renders_planted_row "golem-status: planted cache row renders in the table"
run_fragment_test test_status_blocked_shows_gate_age "golem-status: BLOCKED render shows a (gated Nm ago) gate-age suffix (#422)"
run_fragment_test test_gate_age_suffix_no_ts_empty "golem-status: _gate_age_suffix emits nothing for a no-ts line (#432)"
run_fragment_test test_gate_age_suffix_bad_ts_empty "golem-status: _gate_age_suffix emits nothing for an unparsable ts (#432)"
run_fragment_test test_gate_age_suffix_no_jq_empty "golem-status: _gate_age_suffix emits nothing when jq is absent (#432)"
run_fragment_test test_status_blocked_no_ts_omits_gate_age "golem-status: a no-ts BLOCKED line renders without a (gated Nm ago) suffix (#432)"
run_fragment_test test_status_bad_ts_does_not_blank_blocked_list "golem-status: a malformed ts on one golem doesn't blank the whole BLOCKED list (#432)"
run_fragment_test test_status_annotates_blocked_inbox_state "golem-status: annotates a BLOCKED escalation line with the inbox state (#395)"
run_fragment_test test_status_inbox_state_awaiting_and_consumed "golem-status: inbox annotation renders awaiting + consumed (#395)"
run_fragment_test test_status_inbox_annotation_uses_bracketed_gate "golem-status: annotation keys on the bracketed [gate-…] token, not a stray mention (#395)"
run_fragment_test test_status_unknown_arg_exits_2 "golem-status: unknown argument exits 2 (#304)"
run_fragment_test test_status_watch_bad_level_exits_2 "golem-status: --watch --level out of range exits 2 (#304)"
run_fragment_test test_status_watch_bad_interval_exits_2 "golem-status: --watch --interval non-integer exits 2 (#304)"
run_fragment_test test_status_watch_loops_with_env_override "golem-status: --watch re-renders; GOLEM_SWEEP_INTERVAL overrides the level default (#304)"
run_fragment_test test_status_watch_uses_resolver_default "golem-status: --watch uses the resolver's level-scaled default cadence (#304)"
run_fragment_test test_status_checkpoint_suppresses_noop_sweep "golem-status: --checkpoint --watch suppresses no-op sweeps (full table once, then heartbeat) (#488)"
run_fragment_test test_status_checkpoint_reemits_on_state_change "golem-status: --checkpoint re-emits promptly on a row state change after suppression (#488)"
run_fragment_test test_status_verbose_no_raw_feed_dump "golem-status: verbose render shows a feed count, not the raw JSON tail (#488)"
run_fragment_test test_status_checkpoint_gap_clears_suppression "golem-status: an empty-state gap clears suppression — a reappearing golem re-renders, not a heartbeat (#488)"
run_fragment_test test_status_checkpoint_pool_header_blank_line "golem-status: --checkpoint keeps the blank line between pool header and title (#488)"
run_fragment_test test_status_checkpoint_oneshot_shows_cache_mirror_note "golem-status: one-shot --checkpoint still shows the cache-mirror caveat (#488)"
run_fragment_test test_status_checkpoint_zero_golem_heartbeat_single_line "golem-status: zero-golem heartbeat count is a clean single-line 0, not a split grep -c (#488)"
run_fragment_test test_status_checkpoint_multi_golem_batch_suppression "golem-status: multi-golem batch suppresses unchanged sweep + re-emits whole table on a single-row flip (#488)"
run_fragment_test test_scrape_sums_top_level_only "golem-token-scrape: sums top-level output_tokens only, excludes sidechain (#371)"
run_fragment_test test_scrape_missing_transcript_fails_loud "golem-token-scrape: missing transcript fails loud (exit 2), never a silent 0 (#371)"
run_fragment_test test_scrape_no_arg_exits_1 "golem-token-scrape: empty worktree arg fails loud (#371)"
run_fragment_test test_scrape_newest_session_wins "golem-token-scrape: newest-mtime session transcript wins (#371)"
run_fragment_test test_scrape_tolerates_truncated_trailing_line "golem-token-scrape: tolerates a truncated trailing JSONL line (#371)"
run_fragment_test test_scrape_no_jq_exits_3 "golem-token-scrape: missing jq on PATH exits 3 fail-loud (#371)"
run_fragment_test test_status_token_first_then_frozen "golem-status: token section shows first-reading then frozen; persists fields (#371)"
run_fragment_test test_status_token_advancing_on_change "golem-status: a grown top-level count reads as advancing, not frozen (#371)"
run_fragment_test test_status_token_container_pending "golem-status: an unposted Mode-3 container golem shows the awaiting-push note, never scraped (#390)"
run_fragment_test test_status_token_container_populated "golem-status: a posted Mode-3 container golem renders the mechanical frozen phrase, read-only (#390)"
run_fragment_test test_status_token_container_malformed_degrades "golem-status: a Mode-3 container row with a corrupt count / non-ISO anchor degrades to container-pending (#390)"
run_fragment_test test_status_token_container_partial_post "golem-status: a Mode-3 container row with only one of count/anchor posted degrades to container-pending (#390)"
run_fragment_test test_status_token_unknown_no_transcript "golem-status: a Mode-2 golem with no transcript shows tokens unknown (#371)"
run_fragment_test test_status_frozen_iso_parse_failure_raw_render "golem-status: an unparsable anchor renders the raw 'frozen since <iso>' fallback (#392)"
run_fragment_test test_status_fmt_dur_seconds_arm "golem-status: _fmt_dur seconds arm — a sub-60s freeze renders 'frozen Ns' (#392)"
run_fragment_test test_status_fmt_dur_minute_arm "golem-status: _fmt_dur minutes arm — a >=60s freeze renders 'frozen Nm' (#392)"
run_fragment_test test_scrape_relative_worktree_path "golem-token-scrape: a relative worktree arg resolves like an absolute one (#392)"
run_fragment_test test_liveness_working "golem-transcript-liveness: turn-in-flight -> working (#248)"
run_fragment_test test_liveness_idle "golem-transcript-liveness: turn-ended -> idle (#248)"
run_fragment_test test_liveness_errored_api "golem-transcript-liveness: isApiErrorMessage -> errored (#248)"
run_fragment_test test_liveness_errored_unknown_command "golem-transcript-liveness: trailing Unknown command (no turn) -> errored (#248)"
run_fragment_test test_liveness_errored_unknown_command_after_idle_turn "golem-transcript-liveness: idle turn + trailing Unknown command -> errored (#248)"
run_fragment_test test_liveness_sidechain_not_masking "golem-transcript-liveness: sidechain tool_use does not mask a top-level idle (#248)"
run_fragment_test test_liveness_missing_transcript_fails_loud "golem-transcript-liveness: missing transcript exits 2 fail-loud (#248)"
run_fragment_test test_liveness_indeterminate_exits_2 "golem-transcript-liveness: no top-level turn is indeterminate, exits 2 (#248)"
run_fragment_test test_liveness_no_arg_exits_1 "golem-transcript-liveness: empty worktree arg exits 1 (#248)"
run_fragment_test test_liveness_no_jq_exits_3 "golem-transcript-liveness: missing jq on PATH exits 3 fail-loud (#248)"
run_fragment_test test_liveness_relative_worktree_path "golem-transcript-liveness: a relative worktree arg resolves like an absolute one (#248)"
run_fragment_test test_liveness_stale_working_demoted "golem-transcript-liveness: a stale 'working' transcript is demoted to indeterminate (#248)"
run_fragment_test test_liveness_stale_working_threshold_overridable "golem-transcript-liveness: GOLEM_STALL_THRESHOLD widens the staleness window (#248)"
run_fragment_test test_liveness_stale_idle_not_demoted "golem-transcript-liveness: a stale idle transcript is not demoted (#248)"
run_fragment_test test_liveness_stale_working_stat_failure_fails_open "golem-transcript-liveness: an unreadable mtime fails open on the staleness guard (#248)"
run_fragment_test test_liveness_newest_session_wins "golem-transcript-liveness: newest-mtime session wins (#248)"
run_fragment_test test_liveness_tolerates_truncated_trailing_line "golem-transcript-liveness: tolerates a truncated trailing JSONL line (#248)"
run_fragment_test test_scrape_and_status_zero_tokens "golem-token-scrape/status: an all-sidechain transcript is a real 0, not tokens unknown (#392)"
run_fragment_test test_status_no_jq_skips_token_block "golem-status: no jq on PATH skips the TOP-LEVEL TOKENS block, still exits 0 (#392)"
run_fragment_test test_status_cache_row_missing_issue_tokens_unknown "golem-status: a cache row missing 'issue' shows tokens unknown (#392)"
run_fragment_test test_status_checkpoint_renders_table_and_footer "golem-status: --checkpoint renders the per-track table + batch-totals footer (#283)"
run_fragment_test test_status_checkpoint_delta_across_sweeps "golem-status: --checkpoint computes the burn Δ across two sweeps (#283)"
run_fragment_test test_status_checkpoint_no_tracks_untracked_group "golem-status: --checkpoint with no tracks.json renders every golem in the untracked group (#283)"
run_fragment_test test_status_checkpoint_excludes_tracks_json "golem-status: tracks.json is excluded from the golem-row glob, not a bogus row (#283)"
run_fragment_test test_status_checkpoint_attention_markers "golem-status: --checkpoint STATE column carries ⚠ markers, no ANSI colour (#283)"
run_fragment_test test_status_checkpoint_watch_composes "golem-status: --checkpoint composes with --watch/--level (#283)"
run_fragment_test test_status_checkpoint_reset_on_count_drop "golem-status: --checkpoint renders a count drop as (reset), excluded from burn Δ — no negative delta (#283)"
run_fragment_test test_status_checkpoint_corrupt_prev_tokens_no_drop "golem-status: --checkpoint numeric-guards a corrupt persisted token value, never drops the row (#283)"
run_fragment_test test_status_checkpoint_session_gone_marker "golem-status: --checkpoint flags a vanished-session golem ⚠ gone when a sibling is up (#283)"
run_fragment_test test_status_checkpoint_stage_prefers_phase_detail "golem-status: --checkpoint STAGE prefers .phase_detail over .phase/.state (#283)"
run_fragment_test test_status_checkpoint_ci_and_shipped_markers "golem-status: --checkpoint ⚠ CI (non-blocking) + merged→shipped tally (#283)"
run_fragment_test test_status_checkpoint_container_and_unknown_tokens "golem-status: --checkpoint renders unposted-container n/a + transcript-less — token cells (#283)"
run_fragment_test test_status_checkpoint_container_populated_tokens "golem-status: --checkpoint folds a posted container's count into Σtokens with a (frozen) tag (#390)"
run_fragment_test test_status_checkpoint_elapsed_from_started "golem-status: --checkpoint ELAPSED renders a real duration from .started, not — (#415)"
run_fragment_test test_status_checkpoint_elapsed_fallback_no_started "golem-status: --checkpoint ELAPSED falls back to a ~-marked worktree-mtime age when .started is absent (#515)"
run_fragment_test test_status_checkpoint_elapsed_fallback_malformed_started "golem-status: --checkpoint ELAPSED falls back to the mtime anchor on a malformed .started too (#515)"
run_fragment_test test_status_checkpoint_elapsed_no_anchor_stays_dash "golem-status: --checkpoint ELAPSED stays — with no worktree anchor, never a fabricated ~age (#515)"
run_fragment_test test_status_checkpoint_empty_and_no_jq_guards "golem-status: --checkpoint empty-state + jq-missing early returns exit 0 (#415)"
run_fragment_test test_status_checkpoint_pool_header "golem-status: --checkpoint renders the pool.json header ahead of the table (#415)"
run_fragment_test test_status_checkpoint_live_tail_row "golem-status: --checkpoint renders a (live) tail row for a cache-less session (#415)"
run_fragment_test test_status_checkpoint_lane_boundary_padding "golem-status: --checkpoint lane membership pads exactly (issue 4 does not capture 42) (#415)"
run_fragment_test test_status_checkpoint_derive_stage_fallbacks "golem-status: --checkpoint STAGE falls back .phase → .state → — individually (#415)"
run_fragment_test test_status_checkpoint_container_never_gone "golem-status: --checkpoint never flags a container golem ⚠ gone (#415)"
run_fragment_test test_status_checkpoint_issueless_row_not_gone "golem-status: --checkpoint issue-less (?) row is not wildcard-matched ⚠ gone (#415)"
run_fragment_test test_status_checkpoint_double_lane_claim_dedup "golem-status: --checkpoint dedups a double-lane-claimed golem — one row, tokens once (#415)"
run_fragment_test test_provision_write_status_started_idempotent "provision-agent: write_status() stamps started once and preserves it + sibling fields on same-issue writes (#415/#428)"
run_fragment_test test_provision_write_status_issue_reassignment_resets_stale_fields "provision-agent: write_status() clears issue-scoped fields but preserves container/branch identity on issue reassignment (#428)"
run_fragment_test test_mode_class_plan "golem-mode-check: the plan-mode footer classifies as plan (#659)"
run_fragment_test test_mode_class_auto "golem-mode-check: the auto-mode footer classifies as auto (#659)"
run_fragment_test test_mode_class_accept_edits "golem-mode-check: the accept-edits footer classifies as accept-edits (#659)"
run_fragment_test test_mode_class_unknown_when_no_footer "golem-mode-check: a footerless pane is unknown, never a violation (#659)"
run_fragment_test test_mode_class_bare_words_do_not_match "golem-mode-check: bare words without the glyph do not match (#659)"
run_fragment_test test_mode_class_scrollback_does_not_self_trip "golem-mode-check: a plan footer in scrollback does not self-trip the matcher (#246/#659)"
run_fragment_test test_mode_planning_golem_is_not_drift "golem-mode-check: a legitimately-planning golem is NOT drift (#659)"
run_fragment_test test_mode_planning_golem_is_not_corrected "golem-mode-check: --fix never corrects a legitimately-planning golem (#659)"
run_fragment_test test_mode_drift_detected_via_commits "golem-mode-check: plan mode with commits beyond base is drift (#659)"
run_fragment_test test_mode_drift_detected_via_state_file "golem-mode-check: the state-file phase arm detects drift standing alone (#659)"
run_fragment_test test_mode_drift_detected_without_state_file "golem-mode-check: the commit-count arm detects drift with no state file (#659)"
run_fragment_test test_mode_auto_while_implementing_is_not_drift "golem-mode-check: auto mode past planning is healthy, not drift (#659)"
run_fragment_test test_mode_fix_corrects_and_confirms "golem-mode-check: --fix corrects, re-scrapes to confirm, and reports loudly (#659)"
run_fragment_test test_mode_fix_bounded_then_escalates "golem-mode-check: --fix bounds attempts and escalates rather than looping (#659)"
run_fragment_test test_mode_fix_attempts_env_override "golem-mode-check: GOLEM_MODE_FIX_ATTEMPTS bounds the auto-correct (#659)"
run_fragment_test test_mode_verify_send_confirms_delivery "golem-mode-check: verify-send confirms a delivered send by re-scrape (#659)"
run_fragment_test test_mode_verify_send_detects_swallowed "golem-mode-check: verify-send detects a send swallowed by an open modal (#659)"
run_fragment_test test_mode_missing_tmux_fails_loud "golem-mode-check: missing tmux fails loud (exit 2), never a clean no-drift (#659)"
run_fragment_test test_mode_unknown_arg_exits_2 "golem-mode-check: an unknown argument exits 2 (#659)"
run_fragment_test test_mode_bad_interval_exits_2 "golem-mode-check: a non-positive --interval exits 2 (#659)"

generate_report
