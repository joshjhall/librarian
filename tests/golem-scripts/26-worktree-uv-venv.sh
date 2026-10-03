# shellcheck shell=bash
# worktree-new.sh / worktree-rm.sh — per-worktree uv venv OFF the repo mount
# (issue #1091).
#
# The prevention half of containers#1004: a uv `.venv` on the case-insensitive
# virtiofs+bindfs stack leaves a phantom `.venv/Lib` that cannot be unlinked.
# worktree-new.sh seeds `env.UV_PROJECT_ENVIRONMENT=<GOLEM_UV_CACHE_DIR>/issue-N`
# into the worktree's `.claude/settings.local.json` through the SAME
# seed_cache_env body #944 uses for CARGO_TARGET_DIR, gated on the worktree
# being a uv/pyproject project; worktree-rm.sh removes that directory on
# teardown.
#
# The probe arms (absent / unwritable / wedging fs / symlink / unignored /
# malformed / no-jq) are covered once, through the cargo key, in
# 25-worktree-new-cargo.sh — they are one shared function, so repeating each per
# key would test the same lines twice. This area pins what is NEW: the uv
# project gate, the second key's coexistence with the first, and teardown.
#
# Its own area file: 40-worktree-rm.sh is already over its LOC budget.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts and
# sources tests/lib/golem-sandbox.sh BEFORE this file. That library pins
# GOLEM_UV_CACHE_DIR at a nonexistent sandbox path; these tests pass their own.

# --- helpers (used only by this area, so they stay here) --------------------

# _uv_env <sandbox> <uv-cache> <cargo-cache> — the hermetic env both scripts
# run under here: local-file copy ENABLED (the seed writes the copied settings
# file) and BOTH cache roots set by the caller, never inherited.
_uv_env() {
    _UV_ENV=(
        HOME="$1"
        GOLEM_PLUGIN_PROBE="$1/no-plugin-probe"
        TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$1/.tmux}"
        GOLEM_WORKTREE_DIR=.worktrees
        GOLEM_STATUS_DIR=.worktrees/.status
        GOLEM_BASE_REF=HEAD
        GOLEM_WORKTREE_LOCAL_FILES=".claude/settings.local.json"
        GOLEM_UV_CACHE_DIR="$2"
        GOLEM_CARGO_CACHE_DIR="$3"
    )
}

# _uv_run <script> <sandbox> <uv-cache> <issue-N> [cargo-cache]
# Run worktree-new.sh or worktree-rm.sh from the sandbox. The cargo cache
# defaults to a nonexistent path so the cargo seed stays out of the output.
# Captures combined output in RUN_OUT / exit code in RUN_RC.
_uv_run() {
    local script="$1" dir="$2" uvc="$3" n="$4" cc="${5:-$2/no-cargo-cache}"
    _uv_env "$dir" "$uvc" "$cc"
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" "${_UV_ENV[@]}" \
            "$REAL_BASH" "$script" "$n" 2>&1)" || RUN_RC=$?
}

# _uv_project <sandbox> [file...] — commit the TRACKED .gitignore real repos
# carry for the settings file, plus the named uv marker files (default
# pyproject.toml). Committed, not merely written: the worktree is cut from HEAD,
# so an uncommitted marker would never reach it.
_uv_project() {
    local dir="$1" f
    shift
    [ "$#" -gt 0 ] || set -- pyproject.toml
    command printf '.claude/settings.local.json\n.worktrees/\n' >"$dir/.gitignore"
    for f in "$@"; do
        command printf '# %s\n' "$f" >"$dir/$f"
    done
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$dir" add .gitignore "$@" 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm uv-project 2>/dev/null
}

# _uv_key_of <sandbox> <issue-N> [key] — echo an env key from the worktree's
# seeded settings file, or nothing when absent/unparseable.
_uv_key_of() {
    command jq -r --arg k "${3:-UV_PROJECT_ENVIRONMENT}" '.env[$k] // empty' \
        "$1/.worktrees/issue-$2/.claude/settings.local.json" 2>/dev/null
}

_uv_need_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    skip_test "jq unavailable — the seed is jq-gated by design"
    return 1
}

# --- seeding ----------------------------------------------------------------

# AC1: a uv project with a suitable cache root gets a per-worktree
# UV_PROJECT_ENVIRONMENT outside the repo, the directory exists, and the keys the
# operator's copied settings already carried survive the merge.
test_worktree_new_uv_seeds_project_environment() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    command mkdir -p "$sb/.claude"
    command printf '{"permissions":{"allow":["Bash(marker)"]}}\n' \
        >"$sb/.claude/settings.local.json"
    local cache="$sb/venvs"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$sb" "$cache" 81
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 when seeding the uv venv"
    assert_equals "$cache/issue-81" "$(_uv_key_of "$sb" 81)" \
        "UV_PROJECT_ENVIRONMENT is seeded per-worktree into settings.local.json"
    assert_contains "$RUN_OUT" "seeded UV_PROJECT_ENVIRONMENT=$cache/issue-81" \
        "reports the uv seed"
    assert_true "[ -d \"$cache/issue-81\" ]" "The per-worktree venv dir is created"
    local kept
    kept="$(command jq -r '.permissions.allow[0] // empty' \
        "$sb/.worktrees/issue-81/.claude/settings.local.json" 2>/dev/null)"
    assert_equals "Bash(marker)" "$kept" \
        "the pre-existing settings keys survive the env merge"
}

# Per-worktree, never shared: two golems resolving deps into one venv would race
# each other's `uv sync`.
test_worktree_new_uv_venv_is_per_worktree() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$sb" "$cache" 82
    _uv_run "$WT_NEW" "$sb" "$cache" 83
    assert_equals "$cache/issue-82" "$(_uv_key_of "$sb" 82)" "issue 82 gets its own venv"
    assert_equals "$cache/issue-83" "$(_uv_key_of "$sb" 83)" "issue 83 gets its own venv"
}

# The gate's second arm: `uv.lock` with no pyproject.toml still counts. Without
# this the `||` could lose an arm and every other test would stay green.
test_worktree_new_uv_lock_alone_triggers_seed() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb" uv.lock
    local cache="$sb/venvs"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$sb" "$cache" 84
    assert_equals "$cache/issue-84" "$(_uv_key_of "$sb" 84)" \
        "a uv.lock alone marks the worktree as a uv project"
}

# AC3: a repo with neither marker is a no-op — no key, no output line, and no
# directory provisioned. Run with a SUITABLE cache and the gitignore in place,
# so the project gate is the only thing that can decline; the control below
# proves the same setup does seed once a marker exists.
test_worktree_new_uv_noop_without_uv_project() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    command printf '.claude/settings.local.json\n.worktrees/\n' >"$sb/.gitignore"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$sb" add .gitignore 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" -c commit.gpgsign=false commit -qm gitignore 2>/dev/null
    local cache="$sb/venvs"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$sb" "$cache" 85
    local subject_rc="$RUN_RC" subject_out="$RUN_OUT"
    assert_exit 0 "$subject_rc" "worktree-new exits 0 in a repo without uv"
    assert_not_contains "$subject_out" "UV_PROJECT_ENVIRONMENT" \
        "emits no uv line for a repo with no pyproject.toml / uv.lock"
    assert_equals "" "$(_uv_key_of "$sb" 85)" "writes no UV_PROJECT_ENVIRONMENT"
    assert_true "[ ! -e \"$cache/issue-85\" ]" "provisions no venv dir for a non-uv repo"

    # Control: identical sandbox shape plus a marker DOES seed.
    local sb2
    new_sandbox sb2
    _uv_project "$sb2"
    command mkdir -p "$sb2/venvs"
    _uv_run "$WT_NEW" "$sb2" "$sb2/venvs" 85
    assert_equals "$sb2/venvs/issue-85" "$(_uv_key_of "$sb2" 85)" \
        "control: the same setup with a pyproject.toml DOES seed"
}

# The off switch: an absent cache root leaves a uv project unseeded. This is the
# property the sandbox pins rely on — and the shipped default on any machine
# where /cache/venv does not exist.
test_worktree_new_uv_absent_cache_is_noop() {
    local sb
    new_sandbox sb
    _uv_project "$sb"

    _uv_run "$WT_NEW" "$sb" "$sb/no/such/venvs" 86
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with no uv cache location"
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" \
        "emits no uv line when the cache location is absent"
    assert_true "[ ! -e \"$sb/no\" ]" "does not provision the absent cache location"
}

# Both seeds land in ONE env object: the second jq merge must add to what the
# first wrote, not replace it. A `.env = {...}` regression would drop cargo.
test_worktree_new_uv_coexists_with_cargo_seed() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    command mkdir -p "$sb/venvs" "$sb/targets"

    _uv_run "$WT_NEW" "$sb" "$sb/venvs" 87 "$sb/targets"
    assert_equals "$sb/targets/issue-87" "$(_uv_key_of "$sb" 87 CARGO_TARGET_DIR)" \
        "CARGO_TARGET_DIR survives the uv merge"
    assert_equals "$sb/venvs/issue-87" "$(_uv_key_of "$sb" 87)" \
        "UV_PROJECT_ENVIRONMENT sits alongside it"
}

# --- teardown ---------------------------------------------------------------

# AC2 end-to-end: create → venv populated → teardown removes it, and the seed
# left the worktree CLEAN so teardown was not refused. Sibling venvs and the
# cache root itself survive — the path is keyed by THIS issue only.
test_worktree_rm_removes_uv_venv() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs"
    command mkdir -p "$cache/issue-99/bin"
    command printf 'sibling\n' >"$cache/issue-99/bin/python"

    _uv_run "$WT_NEW" "$sb" "$cache" 88
    assert_equals "$cache/issue-88" "$(_uv_key_of "$sb" 88)" \
        "the seed landed (guards a vacuous teardown pass below)"
    # What `uv sync` would leave behind, including the lib64 symlink that is
    # the containers#1004 trigger shape.
    command mkdir -p "$cache/issue-88/bin" "$cache/issue-88/lib"
    command printf 'py\n' >"$cache/issue-88/bin/python"
    command ln -s lib "$cache/issue-88/lib64"

    _uv_run "$WT_RM" "$sb" "$cache" 88
    assert_exit 0 "$RUN_RC" "teardown succeeds after the uv seed — no dirty refusal"
    assert_not_contains "$RUN_OUT" "uncommitted" "teardown reports no uncommitted changes"
    assert_contains "$RUN_OUT" "removed uv venv $cache/issue-88" "reports the venv removal"
    assert_true "[ ! -e \"$cache/issue-88\" ]" "The per-worktree venv is gone"
    assert_true "[ -f \"$cache/issue-99/bin/python\" ]" "A sibling issue's venv is untouched"
    assert_true "[ -d \"$cache\" ]" "The cache root itself is untouched"
}

# No venv to remove: teardown stays quiet about it. Guards an unconditional
# `removed uv venv` line (or a removal of something that was never there).
test_worktree_rm_without_uv_venv_is_quiet() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs"
    command mkdir -p "$cache"
    _uv_run "$WT_NEW" "$sb" "$cache" 89
    _uv_run "$WT_RM" "$sb" "$cache" 89
    assert_exit 0 "$RUN_RC" "teardown exits 0 with no venv present"
    assert_not_contains "$RUN_OUT" "uv venv" "says nothing about a venv that never existed"
}

# A refused teardown keeps the venv. The removal sits AFTER every refusal, so a
# worktree holding uncommitted work keeps its environment too — deleting it
# while the worktree survives would strand that work without its deps.
test_worktree_rm_dirty_refusal_keeps_uv_venv() {
    local sb
    new_sandbox sb
    _uv_project "$sb"
    local cache="$sb/venvs"
    command mkdir -p "$cache"
    _uv_run "$WT_NEW" "$sb" "$cache" 90
    command mkdir -p "$cache/issue-90/bin"
    command printf 'wip\n' >"$sb/.worktrees/issue-90/seed.txt"

    _uv_run "$WT_RM" "$sb" "$cache" 90
    assert_exit 1 "$RUN_RC" "worktree-rm refuses the dirty worktree"
    assert_true "[ -d \"$cache/issue-90/bin\" ]" "The refused worktree's venv survives"
    assert_not_contains "$RUN_OUT" "removed uv venv" "reports no venv removal on refusal"
}

# Name mode has no venv: worktree-new keys venvs by issue number only. A
# name-mode teardown must not reach into the cache at all, even when a dir of a
# colliding-looking name exists there.
test_worktree_rm_name_mode_leaves_uv_cache_alone() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs"
    command mkdir -p "$cache/issue-scratch" "$cache/scratch"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q .worktrees/scratch -b scratch 2>/dev/null

    _uv_run "$WT_RM" "$sb" "$cache" scratch
    assert_exit 0 "$RUN_RC" "name-mode teardown exits 0"
    assert_true "[ ! -e \"$sb/.worktrees/scratch\" ]" \
        "the named worktree was removed (guards a vacuous pass)"
    assert_true "[ -d \"$cache/issue-scratch\" ] && [ -d \"$cache/scratch\" ]" \
        "name mode touches nothing under the uv cache"
}
