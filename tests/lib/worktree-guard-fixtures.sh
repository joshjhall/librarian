# shellcheck shell=bash
# Shared fixtures + runner for the worktree-scope guard test fragments
# (issue #564 — extracted from tests/validate-worktree-guard.sh).
#
# Sourced by tests/validate-worktree-guard.sh BEFORE its area fragments under
# tests/worktree-guard/. Unlike the sibling libraries, most of this file is
# module-scope fixture CONSTRUCTION, not just function definitions: the three
# repo topologies (main+linked worktree, submodule-vendored, bare-repo host) are
# built ONCE at source time and shared read-only by every fragment. Sourcing this
# file therefore has side effects on disk, all confined to $FIXTURE and cleaned
# by its EXIT trap.
#
# Why real repos rather than mocks: the guard's whole subject is git TOPOLOGY —
# it compares git-dir against git-common-dir to tell a linked worktree from a
# main checkout — so a fixture that fakes those paths would not exercise the
# thing under test. See #475/#501/#506 for the three topologies and the
# config-poisoning bypasses they close.
#
# GUARD / REAL_BASH / REAL_GIT / GIT_SCRUB are defined by the entry point before
# it sources this file.

# shellcheck disable=SC2034  # the fixture path consts + GUARD_OUT are read by the area fragments

# git_clean <args...> — run git with the hook-exported env scrubbed.
git_clean() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_GIT" "$@"
}

# --- Fixture: a main checkout + a real linked worktree ----------------------
# MAIN_DIR is the primary checkout; WT_DIR is a linked worktree of it. Both are
# real on disk so the hook's `git -C "$cwd" rev-parse` returns true roots.
FIXTURE="$(command mktemp -d)"
trap 'command rm -rf "$FIXTURE"' EXIT
MAIN_DIR="$FIXTURE/repo"
command mkdir -p "$MAIN_DIR"
git_clean -C "$MAIN_DIR" init -q
git_clean -C "$MAIN_DIR" config user.email "test@example.com"
git_clean -C "$MAIN_DIR" config user.name "Test"
printf 'seed\n' >"$MAIN_DIR/seed.txt"
git_clean -C "$MAIN_DIR" add seed.txt
git_clean -C "$MAIN_DIR" -c commit.gpgsign=false commit -qm seed
# Linked worktree at repo/.worktrees/issue-1 on a new branch.
WT_DIR="$MAIN_DIR/.worktrees/issue-1"
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-1 "$WT_DIR" >/dev/null 2>&1

# Canonicalize (mktemp under /tmp may be a symlink to /private/tmp on macOS); the
# hook resolves roots with `cd … && pwd`, so compare against the same.
MAIN_DIR="$(cd "$MAIN_DIR" && pwd)"
WT_DIR="$(cd "$WT_DIR" && pwd)"

# --- Submodule fixture (#475 pre-PR review finding #1) ----------------------
# In a submodule-vendored deployment, git-common-dir is <super>/.git/modules/<n>,
# whose parent is a git-internal dir, NOT the submodule's checkout root. Deriving
# main_root from parent-of-common would MIS-SCOPE and silently ALLOW a real leak,
# so the guard fails open LOUDLY for this topology instead. Build it so the test
# can assert that (skips cleanly if submodule wiring is unavailable in the env).
SM_OK=0
SM_SUPER=""
SM_WT=""
SM_SUB=""
if _sub_src="$FIXTURE/sub_src" && command mkdir -p "$_sub_src" &&
    git_clean -C "$_sub_src" init -q 2>/dev/null &&
    git_clean -C "$_sub_src" config user.email "test@example.com" &&
    git_clean -C "$_sub_src" config user.name "Test" &&
    { printf 'x\n' >"$_sub_src/f"; } &&
    git_clean -C "$_sub_src" add f 2>/dev/null &&
    git_clean -C "$_sub_src" -c commit.gpgsign=false commit -qm s 2>/dev/null; then
    SM_SUPER="$FIXTURE/outer"
    command mkdir -p "$SM_SUPER"
    if git_clean -C "$SM_SUPER" init -q 2>/dev/null &&
        git_clean -C "$SM_SUPER" config user.email "test@example.com" &&
        git_clean -C "$SM_SUPER" config user.name "Test" &&
        git_clean -C "$SM_SUPER" -c protocol.file.allow=always \
            -c commit.gpgsign=false submodule add -q "$_sub_src" sub 2>/dev/null &&
        git_clean -C "$SM_SUPER" -c commit.gpgsign=false commit -qm add-sub 2>/dev/null &&
        git_clean -C "$SM_SUPER/sub" worktree add -q -b feature/issue-20 \
            "$SM_SUPER/sub_wt20" >/dev/null 2>&1; then
        SM_SUPER="$(cd "$SM_SUPER" && pwd)"
        SM_WT="$(cd "$SM_SUPER/sub_wt20" && pwd)"
        SM_SUB="$SM_SUPER/sub"
        SM_OK=1
    fi
fi

# --- Bare-repo worktree-host fixture (#501) ---------------------------------
# A bare repo has NO working tree of its own, so a linked-worktree session there
# has no "main checkout" for an edit to leak INTO — the worktree-escaping-leak
# class is structurally impossible. The guard must ALLOW (a correct allow), and —
# unlike the interim submodule fail-open — do so WITHOUT a loud diagnostic (there
# is nothing degraded about it). Build `bare.git` (core.bare=true) + a linked
# worktree; skip cleanly if bare-worktree wiring is unavailable in the env.
BARE_OK=0
BARE_GITDIR=""
BARE_WT=""
if _bseed="$FIXTURE/bare_seed" && command mkdir -p "$_bseed" &&
    git_clean -C "$_bseed" init -q 2>/dev/null &&
    git_clean -C "$_bseed" config user.email "test@example.com" &&
    git_clean -C "$_bseed" config user.name "Test" &&
    { printf 'a\n' >"$_bseed/a"; } &&
    git_clean -C "$_bseed" add a 2>/dev/null &&
    git_clean -C "$_bseed" -c commit.gpgsign=false commit -qm a 2>/dev/null &&
    git_clean clone -q --bare "$_bseed" "$FIXTURE/bare.git" 2>/dev/null &&
    git_clean -C "$FIXTURE/bare.git" worktree add -q -b feature/issue-30 \
        "$FIXTURE/bare_wt30" >/dev/null 2>&1; then
    BARE_GITDIR="$(cd "$FIXTURE/bare.git" && pwd)"
    BARE_WT="$(cd "$FIXTURE/bare_wt30" && pwd)"
    BARE_OK=1
fi

# --- Runner -----------------------------------------------------------------
# run_guard <cwd> <tool> <path-field> <path> [nojq] — build a PreToolUse payload
# and pipe it to the REAL hook with git env scrubbed; capture stdout in
# GUARD_OUT. In "nojq" mode the child runs under a PATH containing only bash+git
# (no jq) to force the pure-bash fallback.
GUARD_OUT=""
run_guard() {
    local cwd="$1" tool="$2" field="$3" path="$4" mode="${5:-}"
    local payload
    payload="$(printf '{"cwd":"%s","tool_name":"%s","tool_input":{"%s":"%s"}}' \
        "$cwd" "$tool" "$field" "$path")"
    if [ "$mode" = "nojq" ]; then
        local stub="$FIXTURE/stub-bin"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        command ln -sf "$REAL_GIT" "$stub/git"
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    else
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    fi
}

# decision <stdout> — echo the permissionDecision, or "allow" when the hook
# emitted nothing. Requires jq; jq-dependent callers are guarded.
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

# --- Exotic / separate-git-dir gitdir: cross-tree fails open LOUDLY, immune to
# --- core.bare poisoning (#501 cycle-2 CRITICAL) -----------------------------
# A `git init --separate-git-dir=<store>` main checkout gives a common-dir that
# matches neither `*/.git` nor `*/.git/modules/*` — the residual branch. #501 must
# fail open LOUDLY there, AND must NOT be flippable to a silent allow by a
# worktree-side `git config core.bare true` (the exact cycle-2 repro). This is the
# genuinely-exotic case, built from a real git feature (not a hand-mangled gitdir).
_exotic_sgd_fixture() {
    # Sets EX_MAIN / EX_WT / EX_STORE; returns 1 (skip) if the env can't build it.
    EX_ROOT="$FIXTURE/sgd_$1"
    command mkdir -p "$EX_ROOT" || return 1
    EX_MAIN="$EX_ROOT/work"
    EX_STORE="$EX_ROOT/store"
    command mkdir -p "$EX_MAIN" || return 1
    git_clean -C "$EX_MAIN" init -q --separate-git-dir="$EX_STORE" 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" config user.email "test@example.com"
    git_clean -C "$EX_MAIN" config user.name "Test"
    { printf 'x\n' >"$EX_MAIN/seed.txt"; } || return 1
    git_clean -C "$EX_MAIN" add seed.txt 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" -c commit.gpgsign=false commit -qm s 2>/dev/null || return 1
    git_clean -C "$EX_MAIN" worktree add -q -b "feature/issue-$1" "$EX_ROOT/wt" >/dev/null 2>&1 || return 1
    EX_MAIN="$(cd "$EX_MAIN" && pwd)"
    EX_WT="$(cd "$EX_ROOT/wt" && pwd)"
    # Confirm the common-dir really landed in the residual (non-.git, non-module) shape.
    local cd
    cd="$(git_clean -C "$EX_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$cd" in
        "" | */.git | */.git/modules/*) return 1 ;;
    esac
    return 0
}
