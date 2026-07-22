#!/usr/bin/env bash
# PreToolUse worktree-scope guard hook for golem worktree sessions (issue #475).
#
# A golem runs in an isolated linked worktree (.worktrees/issue-N/, branch
# feature/issue-N), but its Edit/Write calls sometimes carry a MAIN-CHECKOUT
# absolute path (/workspace/librarian/plugins/...) instead of the worktree path
# (/workspace/librarian/.worktrees/issue-N/plugins/...). The edit then lands in
# the MAIN checkout's working tree, not the golem's branch. It is SILENT — the
# worktree's `git status` stays clean — and dangerous: the main checkout is
# often on a STALE base, so a naive recovery (blind-copy into the worktree, or
# commit from main) can REVERT an already-merged PR (observed twice in one
# /orchestrate session; the stale-base-squash-reverts-merged-pr class).
#
# This is the deferred preventive guard from #475, the PREFERRED fix. It mirrors
# the sibling read-only Bash guard (bash-guard.sh, #448/#450) — same PreToolUse
# mechanism, same deny-envelope + fail-open-loud + jq-optional + bash-3.2-clean
# contract — but a DIFFERENT rule and a DIFFERENT caller signal.
#
# Mechanism: Claude Code fires PreToolUse before every Write/Edit/MultiEdit/
# NotebookEdit call, session-wide, and pipes the call's JSON on stdin. The stdin
# schema (same envelope bash-guard documents) carries, for these tools:
#   { session_id, transcript_path, cwd, ..., tool_name,
#     tool_input:{ file_path | notebook_path, ... }, ... }
# `cwd` is the session's working directory — for a golem it is the worktree root
# (the tmux launch sets `-c <worktree>`). `file_path` (Write/Edit/MultiEdit) or
# `notebook_path` (NotebookEdit) is the tool's target.
#
# CALLER SIGNAL — git-worktree scope, NOT agent_id. The leak happens in the
# golem's own MAIN loop (not a subagent), so bash-guard's agent_id signal is
# wrong here. Instead, resolve from `cwd`:
#   git-dir  = git -C "$cwd" rev-parse --git-dir
#   common   = git -C "$cwd" rev-parse --git-common-dir
# git-dir != common  => a LINKED worktree (a golem). git-dir == common => the
# PRIMARY checkout (the human/orchestrator main session), which is the same idiom
# golem/SKILL.md and ship-issue/execute-protocol.md use. The main session is
# NEVER blocked — its legitimate edits to its own tree must always pass.
#
# GATING — DENY iff ALL of:
#   1. `cwd` is inside a LINKED worktree (git-dir != git-common-dir). The main
#      checkout is structurally in the ALLOW path.
#   2. The target is an ABSOLUTE path. A relative path resolves against `cwd`
#      (the worktree) and cannot leak — allowed untouched.
#   3. The resolved target is under the MAIN checkout root (parent of the shared
#      git-common-dir) but NOT under this worktree's root. That is precisely the
#      leak: a write aimed at the main tree from a worktree session.
#   To DENY: exit 0 with the JSON permissionDecision:"deny" envelope + a reason
#   naming the leaked path, the worktree it should have used, and the recovery
#   rule. Everything else exits 0 silently (allow):
#     - main-session call (git-dir == common),
#     - target under the worktree root (the correct destination),
#     - target OUTSIDE the repo entirely (/tmp, $HOME/.claude.json that
#       worktree-new.sh legitimately seeds, etc.),
#     - relative target, or no target path in the payload.
#
# ACCEPTED OUT-OF-SCOPE GAPS (documented, deliberately not covered):
#   - The `Bash` tool. Scanning arbitrary shell for a leaked write target is
#     noisy (a mere `cat /workspace/<repo>/...` read is not a leak) and the
#     sibling bash-guard already owns the Bash matcher for its own rule. The
#     golem SKILL prompt guidance (always use worktree-relative / $PWD-anchored
#     paths, never a bare /workspace/<repo>/... root) is the belt for Bash.
#   - A symlink whose target escapes the worktree. Path resolution here is
#     lexical (prefix + `..` rejection), not a realpath() through symlinks.
#   These pass silently BY DESIGN; the prompt belt + human review back them up.
#
# FAILURE MODE — fail-open, fail-LOUD on trouble (mirrors bash-guard, #448). On
# any parse/resolution failure (empty stdin, non-JSON, `cwd` not in a git repo,
# git unavailable) emit a loud stderr diagnostic then ALLOW. Fail-closed would,
# if the input shape regressed, block legitimate edits for EVERY session — the
# worse outcome. This guard is a SECOND layer behind the prompt belt, so a
# detectable degraded-allow (loud on stderr, and validate-worktree-guard.sh
# asserts the positive-block path so a permanent no-op fails CI) is tolerable.
#
# jq is used when present; a pure-bash fallback still enforces when jq is absent
# (base macOS ships no jq), so the guard never silently weakens for lack of jq.
#
# Input  (stdin):  PreToolUse hook JSON (see schema above).
# Output (stdout): nothing (allow) OR the permissionDecision:"deny" JSON envelope.
# Exit:            always 0 — the decision travels in the JSON, not the code.
set -uo pipefail

DIAG_TAG="librarian-worktree-guard"

# --- Read stdin -------------------------------------------------------------
payload="$(/bin/cat 2>/dev/null || true)"
if [ -z "$payload" ]; then
    printf '%s: empty PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
    exit 0
fi

# --- Extract cwd + target path ----------------------------------------------
# Prefer jq; fall back to a pure-bash scraper so the guard enforces without jq.
# The target is file_path (Write/Edit/MultiEdit) OR notebook_path (NotebookEdit).
cwd=""
target=""
have_fields=0
if command -v jq >/dev/null 2>&1; then
    # have_fields gates on whether jq PARSED the payload as JSON (jq empty), not
    # on any particular field's presence — once the bytes parse, jq's extraction
    # is authoritative and more robust than the sed fallback (mirrors #448).
    if printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
        have_fields=1
        cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
        target="$(printf '%s' "$payload" |
            jq -r '(.tool_input.file_path // .tool_input.notebook_path) // empty' 2>/dev/null || true)"
        # A parsed payload with no target path is not an edit we can scope —
        # nothing to enforce against, so allow.
        if [ -z "$target" ]; then
            exit 0
        fi
    fi
fi

if [ "$have_fields" -eq 0 ]; then
    # jq absent or parse failed — hand-roll extraction. These simple scrapes can
    # only ADD enforcement (find a cwd/target jq would have found), never relax
    # it, and any miss lands in the fail-open+loud branch below.
    cwd="$(printf '%s' "$payload" |
        /usr/bin/sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        /usr/bin/head -n1)"
    target="$(printf '%s' "$payload" |
        /usr/bin/sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        /usr/bin/head -n1)"
    if [ -z "$target" ]; then
        target="$(printf '%s' "$payload" |
            /usr/bin/sed -n 's/.*"notebook_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            /usr/bin/head -n1)"
    fi
    if [ -z "$target" ]; then
        printf '%s: could not parse a target path from PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
        exit 0
    fi
fi

# --- Only absolute targets can leak -----------------------------------------
# A relative path resolves against `cwd` (the worktree), so it cannot land in the
# main checkout. Allow it untouched — this also sidesteps needing to resolve it.
case "$target" in
    /*) ;;
    *) exit 0 ;;
esac

# --- Reject `..` traversal (fail-open + loud) -------------------------------
# Path scoping below is lexical prefix matching; a `..` segment could escape the
# worktree prefix and defeat it. Rather than mis-scope, fail open loudly.
case "$target" in
    *"/../"* | *"/..")
        printf '%s: target contains a .. traversal (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$target" >&2
        exit 0
        ;;
esac

# --- Caller gate: resolve the worktree + main roots from cwd ----------------
if [ -z "$cwd" ]; then
    printf '%s: no cwd in PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    printf '%s: git unavailable; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
    exit 0
fi

git_dir="$(git -C "$cwd" rev-parse --git-dir 2>/dev/null || true)"
common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$git_dir" ] || [ -z "$common_dir" ]; then
    printf '%s: cwd (%s) is not inside a git repo; NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi

# Absolutize both so the equality test and the parent-of-common derivation are
# reliable regardless of whether git returned a relative or absolute path.
git_dir_abs="$(cd "$cwd" && cd "$git_dir" 2>/dev/null && pwd || true)"
common_dir_abs="$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd || true)"
if [ -z "$git_dir_abs" ] || [ -z "$common_dir_abs" ]; then
    printf '%s: could not resolve git dirs for cwd (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi

# Main session: git-dir == git-common-dir. NEVER block it — its edits to its own
# working tree are legitimate no matter the path.
if [ "$git_dir_abs" = "$common_dir_abs" ]; then
    exit 0
fi

# Linked worktree. Its own root is the toplevel of `cwd`; the MAIN checkout root
# is the parent of the shared git-common-dir (…/<repo>/.git -> …/<repo>).
# main_root = parent of the shared git-common-dir (…/<repo>/.git -> …/<repo>).
# Pure parameter expansion — no `dirname` binary, so it works even under a
# stripped PATH (the fail-open+loud test showed a bare `dirname` is unavailable).
worktree_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
main_root="${common_dir_abs%/*}"
if [ -z "$worktree_root" ] || [ -z "$main_root" ]; then
    printf '%s: could not resolve worktree/main roots for cwd (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi

# --- Path scope: worktree (allow) BEFORE main (deny) ------------------------
# The worktree lives INSIDE main_root, so a target under the worktree also
# matches main_root — test the worktree prefix first and allow it.
case "$target" in
    "$worktree_root" | "$worktree_root"/*) exit 0 ;;
esac

# Not under the worktree. Deny only when it is under the MAIN checkout root —
# a target outside the repo entirely (/tmp, $HOME/.claude.json, another repo) is
# not this guard's concern and passes.
case "$target" in
    "$main_root" | "$main_root"/*) ;;
    *) exit 0 ;;
esac

# --- Deny -------------------------------------------------------------------
# Map the leaked main-checkout path to where it SHOULD have gone in the worktree,
# so the reason both explains and offers the fix.
rel="${target#"$main_root"/}"
suggested="$worktree_root/$rel"
reason="Blocked a worktree-escaping edit (#475): this golem session runs in the worktree \`${worktree_root}\`, but the target \`${target}\` is in the MAIN checkout \`${main_root}\`. Edits here land silently in main (the worktree \`git status\` stays clean) and can revert an already-merged PR on recovery. Use the worktree path instead: \`${suggested}\`. If a file was already leaked into main, restore ONLY it there (\`git -C ${main_root} checkout -- ${rel}\`) and re-apply it fresh in the worktree on the correct base — never blind-copy from main (stale-base revert risk)."

if command -v jq >/dev/null 2>&1; then
    jq -cn --arg reason "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
        2>/dev/null && exit 0
fi
# No jq: hand-roll the deny envelope. Sanitize the reason (drop backslashes and
# control chars that can't be JSON-escaped without a real encoder, then escape
# double quotes) so the output stays valid JSON.
reason_safe="$(printf '%s' "${reason//\\/}" | /usr/bin/tr -d '[:cntrl:]')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "${reason_safe//\"/\\\"}"
exit 0
