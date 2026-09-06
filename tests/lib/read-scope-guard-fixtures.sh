# shellcheck shell=bash
# Shared fixtures + runner for the read-scope guard test fragments (issue #630).
#
# Sourced by tests/validate-read-scope-guard.sh BEFORE its area fragments under
# tests/read-scope-guard/. Like its sibling tests/lib/worktree-guard-fixtures.sh,
# most of this file is module-scope fixture CONSTRUCTION rather than function
# definitions: the repo topology is built ONCE at source time and shared
# read-only by every fragment. Sourcing therefore has side effects on disk, all
# confined to $FIXTURE and cleaned by its EXIT trap.
#
# Why a real repo rather than mocks: the guard's subject is git TOPOLOGY plus the
# on-disk SIBLING STRUCTURE of the worktree directory. It tells a linked worktree
# from a primary by comparing git-dir against git-common-dir, and it derives the
# peer set from the parent of its own worktree root. A fixture that faked either
# would not exercise the thing under test.
#
# TOPOLOGY BUILT HERE — deliberately mirrors a real golem batch:
#
#   $MAIN_DIR/                    the primary checkout (orchestrator's tree)
#     .worktrees/                 $WT_PARENT — the worktree dir
#       issue-1/                  $WT_DIR    — "my" worktree (the caller)
#       issue-2/                  $PEER_DIR  — a PEER golem's worktree
#       .status/                  $STATUS_DIR — the shared feed (NOT issue-*)
#
# TWO peer worktrees' worth of structure is the point: `issue-2` is what the deny
# rule must catch, and `.status` is the sibling it must NOT catch. A fixture with
# only one worktree could not distinguish "denies peers" from "denies everything
# outside my root" — which is exactly the over-broad rule #630 warns against.
#
# The worktree dir is named `.worktrees` here only because that is the default;
# the guard never reads the name (it uses the parent of its own root), and
# 20-carve-outs.sh pins that property with a SECOND topology under a differently
# named directory.
#
# GUARD / REAL_BASH / REAL_GIT / GIT_SCRUB are defined by the entry point before
# it sources this file.

# shellcheck disable=SC2034  # the fixture path consts + GUARD_OUT are read by the area fragments

# git_clean <args...> — run git with the hook-exported env scrubbed, so this
# OUTER repo's GIT_DIR cannot pin the fixture (or the hook's own `git -C`) to the
# wrong tree. Same GIT_SCRUB convention as validate-golem-scripts.sh.
git_clean() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_GIT" "$@"
}

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

WT_PARENT="$MAIN_DIR/.worktrees"
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-1 "$WT_PARENT/issue-1" >/dev/null 2>&1
git_clean -C "$MAIN_DIR" worktree add -q -b feature/issue-2 "$WT_PARENT/issue-2" >/dev/null 2>&1
command mkdir -p "$WT_PARENT/.status"
printf '{"event":"idle"}\n' >"$WT_PARENT/.status/feed.jsonl"

# Canonicalize (mktemp under /tmp may be a symlink to /private/tmp on macOS); the
# hook resolves roots with `cd … && pwd`, so compare against the same.
MAIN_DIR="$(cd "$MAIN_DIR" && pwd)"
WT_PARENT="$(cd "$WT_PARENT" && pwd)"
WT_DIR="$(cd "$WT_PARENT/issue-1" && pwd)"
PEER_DIR="$(cd "$WT_PARENT/issue-2" && pwd)"
STATUS_DIR="$WT_PARENT/.status"

# A file inside the peer, so deny cases target something that genuinely exists
# (the guard is lexical and does not stat, but a real path keeps the fixture
# honest and lets 30-search-surface.sh reuse it).
printf 'peer content\n' >"$PEER_DIR/peer-file.txt"

# --- Second topology: a DIFFERENTLY NAMED worktree dir (#626 forward-compat) -
# The guard must never key off the literal `.worktrees`. #626 moves the worktree
# root to `.claude/worktrees/`, and GOLEM_WORKTREE_DIR is env-overridable today,
# so a rule that hardcoded the name would silently stop enforcing the moment
# either changed — a guard that fails OPEN and silent is the outcome this repo
# keeps re-learning to avoid. Build the same shape under `wt-custom/` so a
# dedicated case can prove the peer deny still fires there.
ALT_OK=0
ALT_MAIN=""
ALT_WT=""
ALT_PEER=""
if _alt="$FIXTURE/alt" && command mkdir -p "$_alt" &&
    git_clean -C "$_alt" init -q 2>/dev/null &&
    git_clean -C "$_alt" config user.email "test@example.com" &&
    git_clean -C "$_alt" config user.name "Test" &&
    { printf 'a\n' >"$_alt/a"; } &&
    git_clean -C "$_alt" add a 2>/dev/null &&
    git_clean -C "$_alt" -c commit.gpgsign=false commit -qm a 2>/dev/null &&
    git_clean -C "$_alt" worktree add -q -b feature/issue-7 "$_alt/wt-custom/issue-7" >/dev/null 2>&1 &&
    git_clean -C "$_alt" worktree add -q -b feature/issue-8 "$_alt/wt-custom/issue-8" >/dev/null 2>&1; then
    ALT_MAIN="$(cd "$_alt" && pwd)"
    ALT_WT="$(cd "$_alt/wt-custom/issue-7" && pwd)"
    ALT_PEER="$(cd "$_alt/wt-custom/issue-8" && pwd)"
    ALT_OK=1
fi

# --- Runner -----------------------------------------------------------------
# run_guard <cwd> <tool> <path-field> <path> [nojq] — build a PreToolUse payload
# and pipe it to the REAL hook with git env scrubbed; capture stdout in
# GUARD_OUT. Pass the literal string `-` as <path-field> to omit tool_input's
# path entirely (the Grep/Glob "search cwd" shape, which must ALLOW). In "nojq"
# mode the child runs under a PATH holding only bash+git, forcing the pure-bash
# fallback.
GUARD_OUT=""
run_guard() {
    local cwd="$1" tool="$2" field="$3" path="$4" mode="${5:-}"
    local payload
    if [ "$field" = "-" ]; then
        payload="$(printf '{"cwd":"%s","tool_name":"%s","tool_input":{}}' "$cwd" "$tool")"
    else
        payload="$(printf '{"cwd":"%s","tool_name":"%s","tool_input":{"%s":"%s"}}' \
            "$cwd" "$tool" "$field" "$path")"
    fi
    if [ "$mode" = "nojq" ] || [ "$mode" = "nogit" ]; then
        # Two stripped-PATH modes sharing one builder, differing by ONE symlink:
        #   nojq  — bash + git, no jq  -> forces the pure-bash extraction fallback
        #   nogit — bash only          -> forces the git-unavailable fail-open
        # They get SEPARATE stub dirs. A single shared dir would leave the `git`
        # symlink from an earlier nojq case lying around for a later nogit one,
        # so the git-absent test would silently exercise the git-PRESENT path and
        # pass for the wrong reason — the "shimmed PATH didn't hide the tool"
        # failure, which is invisible precisely because the assertion still goes
        # green.
        local stub="$FIXTURE/stub-bin-$mode"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        if [ "$mode" = "nojq" ]; then
            command ln -sf "$REAL_GIT" "$stub/git"
        fi
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    else
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    fi
}

# decision <stdout> — echo the permissionDecision, or "allow" when the hook
# emitted nothing. Requires jq; jq-dependent callers are guarded by jq_required.
decision() {
    local out="$1"
    if [ -z "$out" ]; then
        printf 'allow\n'
        return 0
    fi
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'parse-error\n'
}

# deny_reason <stdout> — the permissionDecisionReason text.
deny_reason() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null
}

jq_required() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable"
        return 1
    fi
    return 0
}
