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
# project gate, the second key's coexistence with the first, and teardown. Two
# arms ARE driven through uv too, because a key-specific regression would slip
# past the cargo-only reading: the leaf-link refusal, and the fs-type refusal
# end-to-end (#1114).
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

# _uv_venv <sandbox> <cache> <issue-N> — the venv path the scripts derive:
# <cache>/<golem_repo_key>/issue-N. Computed by CALLING config.sh's function,
# not re-spelling it, so a change to the key cannot leave the tests asserting a
# stale shape that both scripts have moved away from.
_uv_venv() {
    local key
    key="$(
        # shellcheck source=/dev/null
        . "$SCRIPTS/config.sh"
        golem_repo_key "$1"
    )"
    command printf '%s/%s/issue-%s\n' "$2" "$key" "$3"
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

    local venv
    venv="$(_uv_venv "$sb" "$cache" 81)"
    _uv_run "$WT_NEW" "$sb" "$cache" 81
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 when seeding the uv venv"
    assert_equals "$venv" "$(_uv_key_of "$sb" 81)" \
        "UV_PROJECT_ENVIRONMENT is seeded per-repo, per-worktree into settings.local.json"
    assert_contains "$RUN_OUT" "seeded UV_PROJECT_ENVIRONMENT=$venv" \
        "reports the uv seed"
    assert_true "[ -d \"$venv\" ]" "The per-worktree venv dir is created"
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
    assert_equals "$(_uv_venv "$sb" "$cache" 82)" "$(_uv_key_of "$sb" 82)" "issue 82 gets its own venv"
    assert_equals "$(_uv_venv "$sb" "$cache" 83)" "$(_uv_key_of "$sb" 83)" "issue 83 gets its own venv"
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
    assert_equals "$(_uv_venv "$sb" "$cache" 84)" "$(_uv_key_of "$sb" 84)" \
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
    assert_equals "" "$(command ls -A "$cache")" "provisions nothing under the cache for a non-uv repo"

    # Control: identical sandbox shape plus a marker DOES seed.
    local sb2
    new_sandbox sb2
    _uv_project "$sb2"
    command mkdir -p "$sb2/venvs"
    _uv_run "$WT_NEW" "$sb2" "$sb2/venvs" 85
    assert_equals "$(_uv_venv "$sb2" "$sb2/venvs" 85)" "$(_uv_key_of "$sb2" 85)" \
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
    assert_equals "$(_uv_venv "$sb" "$sb/targets" 87)" "$(_uv_key_of "$sb" 87 CARGO_TARGET_DIR)" \
        "CARGO_TARGET_DIR survives the uv merge"
    assert_equals "$(_uv_venv "$sb" "$sb/venvs" 87)" "$(_uv_key_of "$sb" 87)" \
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
    local cache="$sb/venvs" venv sibling
    venv="$(_uv_venv "$sb" "$cache" 88)"
    sibling="$(_uv_venv "$sb" "$cache" 99)"
    command mkdir -p "${sibling}/bin"
    command printf 'sibling\n' >"$sibling/bin/python"

    _uv_run "$WT_NEW" "$sb" "$cache" 88
    assert_equals "$venv" "$(_uv_key_of "$sb" 88)" \
        "the seed landed (guards a vacuous teardown pass below)"
    # What `uv sync` would leave behind, including the lib64 symlink that is
    # the containers#1004 trigger shape.
    command mkdir -p "$venv/bin" "$venv/lib"
    command printf 'py\n' >"$venv/bin/python"
    command ln -s lib "$venv/lib64"

    _uv_run "$WT_RM" "$sb" "$cache" 88
    assert_exit 0 "$RUN_RC" "teardown succeeds after the uv seed — no dirty refusal"
    assert_not_contains "$RUN_OUT" "uncommitted" "teardown reports no uncommitted changes"
    assert_contains "$RUN_OUT" "removed uv venv $venv" "reports the venv removal"
    assert_true "[ ! -e \"$venv\" ]" "The per-worktree venv is gone"
    assert_true "[ -f \"$sibling/bin/python\" ]" "A sibling issue's venv is untouched"
    assert_true "[ -d \"$cache\" ]" "The cache root itself is untouched"
}

# The cache is ONE mount shared by every repo in the container, and issue
# numbers are per-repo. Two repos each tearing down "issue 42" must not share —
# and so must not delete — one venv. This is the review finding the repo key
# answers: keyed by issue alone, finishing repo A's golem rm -rf'd repo B's live
# environment.
test_worktree_rm_spares_another_repos_same_issue_venv() {
    local a b
    new_sandbox a
    new_sandbox b
    _uv_need_jq || return 0
    _uv_project "$a"
    _uv_project "$b"
    local cache="$WORKDIR/shared-venvs-$$"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$a" "$cache" 42
    _uv_run "$WT_NEW" "$b" "$cache" 42
    local va vb
    va="$(_uv_key_of "$a" 42)"
    vb="$(_uv_key_of "$b" 42)"
    assert_not_empty "$va" "repo A seeded (guards a vacuous pass)"
    assert_not_empty "$vb" "repo B seeded (guards a vacuous pass)"
    assert_true "[ \"$va\" != \"$vb\" ]" \
        "The same issue number in two repos gets two DIFFERENT venvs"
    command printf 'b\n' >"$vb/marker"

    _uv_run "$WT_RM" "$a" "$cache" 42
    assert_exit 0 "$RUN_RC" "repo A's teardown exits 0"
    assert_true "[ ! -e \"$va\" ]" "repo A's venv is removed"
    assert_true "[ -f \"$vb/marker\" ]" "repo B's venv for the SAME issue number survives"
}

# A symlinked leaf is refused, never followed: `rm -rf link` would only unlink,
# but the guard exists so a planted link can never redirect the delete, and the
# target's content must survive either way.
test_worktree_rm_refuses_symlinked_uv_venv() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 91)"
    command mkdir -p "$sb/precious" "${venv%/*}"
    command printf 'keep\n' >"$sb/precious/file"
    command ln -s "$sb/precious" "$venv"
    _uv_run "$WT_NEW" "$sb" "$cache" 91

    _uv_run "$WT_RM" "$sb" "$cache" 91
    assert_exit 0 "$RUN_RC" "teardown exits 0 with a symlinked venv path"
    assert_not_contains "$RUN_OUT" "removed uv venv" "does not remove a symlinked leaf"
    assert_contains "$RUN_OUT" "refusing to remove uv venv $venv" \
        "says it refused — a silent skip would read as 'nothing to remove'"
    assert_true "[ -f \"$sb/precious/file\" ]" "The symlink target's content survives"
    assert_true "[ -L \"$venv\" ]" "The symlink itself is left in place"
}

# The INTERMEDIATE component is checked too (#1091 review c2), not just the
# leaf: a planted `<cache>/<repo-key> -> elsewhere` must not let teardown follow
# it and rm -rf `elsewhere/issue-N`. The cache is a shared mount and the key is
# predictable, so this is the link an attacker would actually plant.
test_worktree_rm_refuses_symlinked_uv_repo_key_dir() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 94)"
    command mkdir -p "$cache" "$sb/elsewhere/issue-94"
    command printf 'keep\n' >"$sb/elsewhere/issue-94/file"
    command ln -s "$sb/elsewhere" "${venv%/*}"
    assert_true "[ -d \"$venv\" ] && [ ! -L \"$venv\" ]" \
        "fixture: the LEAF resolves as a real dir, so only a parent check can refuse"
    _uv_run "$WT_NEW" "$sb" "$cache" 94

    _uv_run "$WT_RM" "$sb" "$cache" 94
    assert_exit 0 "$RUN_RC" "teardown exits 0 with a symlinked repo-key dir"
    assert_not_contains "$RUN_OUT" "removed uv venv" "does not delete through the link"
    assert_contains "$RUN_OUT" "refusing to remove uv venv $venv" \
        "the parent check was REACHED and refused (guards a vacuous pass)"
    assert_true "[ -f \"$sb/elsewhere/issue-94/file\" ]" \
        "The link target's issue dir survives"
}

# Positive control for the parent check: a cache ROOT that is itself a symlink
# (e.g. /cache -> /mnt/x) is a legitimate layout, and canonicalizing the root
# as well as the parent is what lets it still match. Without this, a regression
# that compared the RAW root against the canonical parent would refuse every
# venv on such a host — leaking them all while the refusal tests stayed green.
test_worktree_rm_removes_uv_venv_under_symlinked_cache_root() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    command mkdir -p "$sb/real-venvs"
    command ln -s "$sb/real-venvs" "$sb/venvs"
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 95)"
    _uv_run "$WT_NEW" "$sb" "$cache" 95
    assert_equals "$venv" "$(_uv_key_of "$sb" 95)" "the seed landed through the root link"
    command mkdir -p "$venv/bin"

    _uv_run "$WT_RM" "$sb" "$cache" 95
    assert_exit 0 "$RUN_RC" "teardown exits 0 under a symlinked cache root"
    assert_contains "$RUN_OUT" "removed uv venv $venv" "a symlinked ROOT still removes the venv"
    assert_not_contains "$RUN_OUT" "refusing" "a symlinked root is not mistaken for a planted link"
    assert_true "[ -d \"$sb/real-venvs\" ]" "The real cache root survives"
}

# A root that canonicalizes to `/` is refused even though it passes the
# absolute-path check: `//` is absolute, and would otherwise put the venv parent
# at /<key>. Teardown still exits 0.
test_worktree_rm_refuses_slash_slash_uv_cache_root() {
    local sb
    new_sandbox sb
    _uv_run "$WT_NEW" "$sb" "$sb/no-cache" 96
    _uv_run "$WT_RM" "$sb" // 96
    assert_exit 0 "$RUN_RC" "teardown exits 0 with GOLEM_UV_CACHE_DIR=//"
    assert_not_contains "$RUN_OUT" "removed uv venv" "nothing is removed under a '//' root"
}

# The UNVERIFIABLE arm: when `readlink -f` cannot run, teardown cannot prove
# the path is free of symlinks, so it must not delete — and must say so rather
# than skip silently. A PATH stub fails only `readlink -f`, passing every other
# readlink call through, so the rest of teardown runs normally. -uBASH_ENV
# because this image's /etc/bash_env re-exports a full PATH into every
# non-interactive bash, which would silently restore the real readlink.
test_worktree_rm_unverifiable_uv_venv_path_is_refused() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv real_rl
    venv="$(_uv_venv "$sb" "$cache" 97)"
    _uv_run "$WT_NEW" "$sb" "$cache" 97
    command mkdir -p "$venv/bin"
    real_rl="$(command -v readlink)"
    command mkdir -p "$sb/stubbin"
    command printf '#!/usr/bin/env bash\n[ "$1" = "-f" ] && exit 1\nexec %s "$@"\n' \
        "$real_rl" >"$sb/stubbin/readlink"
    command chmod +x "$sb/stubbin/readlink"

    _uv_env "$sb" "$cache" "$sb/no-cargo-cache"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV "${_UV_ENV[@]}" \
            PATH="$sb/stubbin:$PATH" \
            "$REAL_BASH" "$WT_RM" 97 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "teardown exits 0 when readlink -f cannot run"
    assert_contains "$RUN_OUT" "refusing to remove uv venv $venv" \
        "an unverifiable path is refused out loud"
    assert_true "[ -d \"$venv/bin\" ]" "The unverifiable venv is left in place"
    assert_contains "$RUN_OUT" "removed worktree" "the rest of teardown still ran"
}

# The SEED side refuses the same planted link teardown does (#1091 review c5):
# a `<cache>/<repo-key> -> elsewhere` must not make worktree-new create the venv
# dir — or point UV_PROJECT_ENVIRONMENT — through it. Positive control: the same
# fixture without the link seeds (test_worktree_new_uv_seeds_project_environment).
test_worktree_new_uv_refuses_symlinked_repo_key_dir() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 98)"
    command mkdir -p "$cache" "$sb/elsewhere"
    command ln -s "$sb/elsewhere" "${venv%/*}"

    _uv_run "$WT_NEW" "$sb" "$cache" 98
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a planted repo-key link"
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "does not seed through the link"
    assert_equals "" "$(_uv_key_of "$sb" 98)" "writes no UV_PROJECT_ENVIRONMENT"
    assert_true "[ ! -e \"$sb/elsewhere/issue-98\" ]" \
        "Nothing is created in the link target"
}

# The seed refuses a planted LEAF link too, not only a planted key dir: an
# `<cache>/<key>/issue-N -> elsewhere` would otherwise be "created" by mkdir -p
# (a no-op on an existing link) and seeded, sending uv's venv to elsewhere.
test_worktree_new_uv_refuses_symlinked_venv_leaf() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 77)"
    command mkdir -p "${venv%/*}" "$sb/elsewhere"
    command ln -s "$sb/elsewhere" "$venv"

    _uv_run "$WT_NEW" "$sb" "$cache" 77
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a planted leaf link"
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "does not seed through a leaf link"
    assert_equals "" "$(_uv_key_of "$sb" 77)" "writes no UV_PROJECT_ENVIRONMENT"
}

# The fs-type refusal reaches the uv key END-TO-END (#1114). 25's arm test reads
# the case statement's text, which a regression gating the check on the key
# (cargo-only) would leave intact. So run the WHOLE worktree-new.sh — from a
# scripts copy whose /proc/mounts is rewritten to a fixture that mounts the cache
# root as the type under test — and assert uv seeds nothing and creates no
# <cache>/<key> dir (the probe precedes that mkdir). Positive control in-test:
# the same harness with a benign type DOES seed, so the refusals are the
# fstype's doing, not the harness's.
test_worktree_new_uv_refuses_wedging_filesystems() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs" copy="$sb/scripts-copy" real n=60 fs venv
    command mkdir -p "$cache"
    command cp -R "$SCRIPTS" "$copy"
    command sed "s#/proc/mounts#$sb/mounts#g" "$WT_NEW" >"$copy/worktree-new.sh"
    # Vacuity guards: a copy still reading the real /proc/mounts (an upstream
    # rename the substitution missed) would refuse or seed for the wrong reason.
    assert_equals "0" "$(command grep -c '/proc/mounts' "$copy/worktree-new.sh")" \
        "the scripts copy no longer reads the real /proc/mounts"
    assert_true "command grep -q '$sb/mounts' '$copy/worktree-new.sh'" \
        "The scripts copy reads the fixture mounts file"
    real="$(command readlink -f "$cache")"
    # Refused types first, so "no <cache>/<key> dir" holds absolutely; the
    # benign control runs last and is the pass that creates it.
    for fs in virtiofs fuse.bindfs 9p ext4; do
        n=$((n + 1))
        command printf '/dev/root / overlay rw 0 0\nhost %s %s rw 0 0\n' \
            "$real" "$fs" >"$sb/mounts"
        venv="$(_uv_venv "$sb" "$cache" "$n")"
        _uv_run "$copy/worktree-new.sh" "$sb" "$cache" "$n"
        assert_exit 0 "$RUN_RC" "worktree-new exits 0 with the uv cache on $fs"
        if [ "$fs" = ext4 ]; then
            assert_equals "$venv" "$(_uv_key_of "$sb" "$n")" \
                "positive control: a benign fstype through the same fixture seeds"
            continue
        fi
        assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "does not seed onto $fs"
        assert_equals "" "$(_uv_key_of "$sb" "$n")" "writes no UV_PROJECT_ENVIRONMENT on $fs"
        assert_true "[ ! -e \"${venv%/*}\" ]" "No <cache>/<key> dir is created on $fs"
    done
}

# The gitignore refusal reaches the uv call site too: in a uv project whose
# settings file is NOT ignored, writing it would dirty the worktree and block
# teardown. Nothing is seeded and nothing is provisioned under the cache.
# Positive control: test_worktree_new_uv_seeds_project_environment, identical
# but with the settings file ignored.
test_worktree_new_uv_unignored_settings_is_noop() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    command printf '# pyproject\n' >"$sb/pyproject.toml"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$sb" add pyproject.toml 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" -c commit.gpgsign=false commit -qm pyproject 2>/dev/null
    local cache="$sb/venvs"
    command mkdir -p "$cache"

    _uv_run "$WT_NEW" "$sb" "$cache" 76
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 in a uv repo that does not ignore the settings"
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "does not seed an un-ignored settings file"
    local st
    st="$(cd "$sb/.worktrees/issue-76" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git status --porcelain 2>&1)"
    assert_equals "" "$st" "the worktree stays CLEAN"
}

# A FAILED repo key skips the uv seed (#1091 pr-review c2). Inline, a failure
# substituted "" and seeded the un-namespaced <cache>/issue-N — shared across
# repos and never removed by teardown, which requires a key. A PATH stub fails
# only cksum (the key's one external), so everything else runs normally;
# -uBASH_ENV so this image's /etc/bash_env cannot restore the real PATH.
# Positive control: test_worktree_new_uv_seeds_project_environment.
test_worktree_new_uv_failed_repo_key_skips_seed() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    local cache="$sb/venvs"
    command mkdir -p "$cache" "$sb/stubbin"
    # The stub leaves a marker, so the test proves cksum was the thing that
    # failed — not some other reason the seed declined.
    command printf '#!/usr/bin/env bash\n: >"%s/cksum-ran"\nexit 1\n' "$sb" \
        >"$sb/stubbin/cksum"
    command chmod +x "$sb/stubbin/cksum"

    _uv_env "$sb" "$cache" "$sb/no-cargo-cache"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV "${_UV_ENV[@]}" \
            PATH="$sb/stubbin:$PATH" \
            "$REAL_BASH" "$WT_NEW" 75 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 when the repo key cannot be computed"
    assert_file_exists "$sb/cksum-ran" "the failing cksum stub was actually invoked"
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "no uv seed without a repo key"
    assert_contains "$RUN_OUT" "could not derive the repo key" \
        "announced even with NO cargo cache root — the uv root alone triggers it (#1117)"
    assert_equals "" "$(command ls -A "$cache")" \
        "nothing is provisioned — in particular no un-namespaced issue-N"
}

# The rm-side mirror of the failed-key case (#1091 pr-review c4): with no repo
# key there is no path to verify, so teardown must neither guess one (an empty
# key would aim rm -rf at <cache>//issue-N) nor skip in silence. The venv
# survives, a warning names the cache, and teardown exits 0. The cksum stub
# leaves a marker so the skip is attributed to the key failure.
test_worktree_rm_failed_repo_key_warns_and_keeps_venv() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 74)"
    _uv_run "$WT_NEW" "$sb" "$cache" 74
    command mkdir -p "$venv/bin" "$cache/issue-74" "$sb/stubbin"
    command printf '#!/usr/bin/env bash\n: >"%s/cksum-ran"\nexit 1\n' "$sb" \
        >"$sb/stubbin/cksum"
    command chmod +x "$sb/stubbin/cksum"

    _uv_env "$sb" "$cache" "$sb/no-cargo-cache"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV "${_UV_ENV[@]}" \
            PATH="$sb/stubbin:$PATH" \
            "$REAL_BASH" "$WT_RM" 74 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "teardown exits 0 when the repo key cannot be computed"
    assert_file_exists "$sb/cksum-ran" "the failing cksum stub was actually invoked"
    assert_contains "$RUN_OUT" "could not derive the repo key" "the skip is announced"
    assert_not_contains "$RUN_OUT" "removed uv venv" "nothing is removed without a key"
    assert_true "[ -d \"$venv/bin\" ]" "The keyed venv survives"
    assert_true "[ -d \"$cache/issue-74\" ]" \
        "An un-namespaced <cache>/issue-N is NOT deleted (an empty key never becomes a path)"
}

# golem_repo_key's uniqueness rests on the cksum suffix: two repos that share a
# BASENAME (two checkouts of one project) must still get different keys. The
# cross-repo teardown test uses mktemp-named sandboxes whose basenames already
# differ, so it cannot see a regression that drops the cksum — this can.
test_golem_repo_key_separates_same_basename() {
    local a b
    a="$(
        # shellcheck source=/dev/null
        . "$SCRIPTS/config.sh"
        golem_repo_key /one/proj
    )"
    b="$(
        # shellcheck source=/dev/null
        . "$SCRIPTS/config.sh"
        golem_repo_key /two/proj
    )"
    assert_contains "$a" "proj-" "the key leads with the repo basename"
    assert_true "[ -n \"$a\" ] && [ \"$a\" != \"$b\" ]" \
        "Two repos with the SAME basename get DIFFERENT keys"
    case "$a" in
        */*) assert_true "false" "the key is a single path segment (no '/')" ;;
    esac
}

# A removal that fails must warn and still exit 0 — teardown is past its
# destructive git steps, so failing here would strand a removed worktree behind
# a non-zero exit. A read-only parent makes the rm fail; root defeats that, so
# skip rather than assert a false pass.
test_worktree_rm_failed_uv_venv_removal_warns_and_exits_0() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" venv
    venv="$(_uv_venv "$sb" "$cache" 92)"
    _uv_run "$WT_NEW" "$sb" "$cache" 92
    command mkdir -p "$venv/bin"
    command chmod 555 "${venv%/*}" 2>/dev/null || true
    if [ -w "${venv%/*}" ]; then
        command chmod 755 "${venv%/*}" 2>/dev/null || true
        skip_test "venv parent still writable after chmod 555 (running as root?)"
        return
    fi

    _uv_run "$WT_RM" "$sb" "$cache" 92
    local rc="$RUN_RC" out="$RUN_OUT"
    command chmod 755 "${venv%/*}" 2>/dev/null || true
    assert_exit 0 "$rc" "teardown still exits 0 when the venv cannot be removed"
    assert_contains "$out" "could not remove uv venv $venv" "warns, naming the venv"
    assert_not_contains "$out" "removed uv venv" "does not claim a removal that failed"
    assert_contains "$out" "removed worktree" "the worktree teardown itself still happened"
}

# A RELATIVE cache root is refused by both scripts: it would resolve against the
# repo checkout — the mount the whole feature exists to avoid — and on teardown
# would aim rm -rf at a path inside the repo. Positive control: the same
# relative dir, made absolute, does seed.
test_worktree_uv_relative_cache_root_is_refused() {
    local sb
    new_sandbox sb
    _uv_need_jq || return 0
    _uv_project "$sb"
    command mkdir -p "$sb/relvenvs"

    _uv_run "$WT_NEW" "$sb" relvenvs 93
    assert_not_contains "$RUN_OUT" "UV_PROJECT_ENVIRONMENT" "a relative cache root is not seeded"
    assert_equals "" "$(command ls -A "$sb/relvenvs")" "nothing is provisioned under it"

    local key
    key="$(_uv_venv "$sb" relvenvs 93)"
    command mkdir -p "$sb/$key"
    _uv_run "$WT_RM" "$sb" relvenvs 93
    assert_true "[ -d \"$sb/$key\" ]" "teardown does not rm -rf under a relative cache root"

    local sb2
    new_sandbox sb2
    _uv_project "$sb2"
    command mkdir -p "$sb2/relvenvs"
    _uv_run "$WT_NEW" "$sb2" "$sb2/relvenvs" 93
    assert_equals "$(_uv_venv "$sb2" "$sb2/relvenvs" 93)" "$(_uv_key_of "$sb2" 93)" \
        "control: the same dir spelled absolutely DOES seed"
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
    local venv
    venv="$(_uv_venv "$sb" "$cache" 90)"
    _uv_run "$WT_NEW" "$sb" "$cache" 90
    command mkdir -p "$venv/bin"
    command printf 'wip\n' >"$sb/.worktrees/issue-90/seed.txt"

    _uv_run "$WT_RM" "$sb" "$cache" 90
    assert_exit 1 "$RUN_RC" "worktree-rm refuses the dirty worktree"
    assert_true "[ -d \"$venv/bin\" ]" "The refused worktree's venv survives"
    assert_not_contains "$RUN_OUT" "removed uv venv" "reports no venv removal on refusal"
}

# Name mode has no venv: worktree-new keys venvs by issue number only. A
# name-mode teardown must not reach into the cache at all, even when a dir of a
# colliding-looking name exists there.
test_worktree_rm_name_mode_leaves_uv_cache_alone() {
    local sb
    new_sandbox sb
    local cache="$sb/venvs" key_dir
    key_dir="$(_uv_venv "$sb" "$cache" scratch)"
    key_dir="${key_dir%/*}"
    command mkdir -p "$key_dir/issue-scratch" "$key_dir/scratch"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q .worktrees/scratch -b scratch 2>/dev/null

    _uv_run "$WT_RM" "$sb" "$cache" scratch
    assert_exit 0 "$RUN_RC" "name-mode teardown exits 0"
    assert_true "[ ! -e \"$sb/.worktrees/scratch\" ]" \
        "the named worktree was removed (guards a vacuous pass)"
    assert_true "[ -d \"$key_dir/issue-scratch\" ] && [ -d \"$key_dir/scratch\" ]" \
        "name mode touches nothing under the uv cache"
}
