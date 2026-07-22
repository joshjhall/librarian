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
# TOPOLOGY COVERAGE (#501). The main-checkout root is derived per git topology
# from the common-dir PATH STRUCTURE (never from worktree-writable config keys —
# see the TRUST ANCHOR note at the derivation block below):
#   - STANDARD (common-dir = …/<repo>/.git): enforced — main root = its parent
#     (the original #475 case).
#   - SUBMODULE-vendored (common-dir …/.git/modules/<name>): enforced — main root =
#     the SUPERPROJECT (strip /.git/modules/…). A leak into the submodule's real
#     checkout (inside the superproject) is DENIED, not failed-open.
#   - BARE-repo host OR any EXOTIC gitdir (common-dir neither …/.git nor
#     …/.git/modules/…, e.g. a `--separate-git-dir` store): the main root is not
#     derivable from the path structure, and the only remaining bare-vs-exotic
#     discriminator (`core.bare` / `--is-bare-repository`) is worktree-poisonable,
#     so the guard FAILS OPEN LOUDLY rather than trust it. A bare host's legitimate
#     own-worktree edits already passed the topology-independent worktree-first
#     allow, so only a cross-tree target reaches this loud path.
#
# ACCEPTED OUT-OF-SCOPE GAPS (documented, deliberately not covered):
#   - The `Bash` tool. Scanning arbitrary shell for a leaked write target is
#     noisy (a mere `cat /workspace/<repo>/...` read is not a leak) and the
#     sibling bash-guard already owns the Bash matcher for its own rule. The
#     golem SKILL prompt guidance (always use worktree-relative / $PWD-anchored
#     paths, never a bare /workspace/<repo>/... root) is the belt for Bash.
#   - A symlink whose target escapes the worktree. Path resolution here is
#     lexical (segment collapse of `.`/`..`), not a realpath() through symlinks.
#   - A bare-host or EXOTIC gitdir (above) whose scope cannot be derived from the
#     path structure: fails open with a loud stderr diagnostic BY DESIGN; the
#     prompt belt + human review back it up.
#   - A golem REWRITING its own `$worktree/.git` gitlink file to point at a decoy
#     repo defeats the git-dir==common-dir main-session gate ABOVE (making its cwd
#     look like a primary checkout that is never blocked). That is a distinct,
#     pre-existing #475 trust-anchor gap — the disarming write itself is a normal
#     worktree-scoped edit this guard allows, and closing it needs a cross-cut fix
#     spanning this gate AND bash-guard's Bash matcher — tracked as its own
#     follow-up, out of #501's topology scope. (The RELATED `core.worktree` /
#     `extensions.worktreeConfig` toplevel-redirect vector IS closed here — see the
#     structural worktree_root derivation below.)
#   A silent leak is the one outcome avoided everywhere.
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

# --- Portable tool resolution (#443) ----------------------------------------
# Claude Code invokes PreToolUse hooks with a potentially minimal environment, so
# this hook historically hardcoded /usr/bin/<tool> to survive a stripped PATH.
# But those absolute paths are WRONG on macOS (core utils in /bin, no
# /usr/bin/realpath) and hard-crash the hook there. `_bin <tool>` reconciles
# both: it honors PATH first (via the `command -v` builtin, which needs no
# external binary — correct on macOS/Homebrew/normal shells), then falls back to
# scanning the standard bin dirs so it still resolves when PATH is stripped, and
# finally yields the bare name (let the shell's own PATH try). The candidate list
# is bare DIRECTORIES, not /usr/bin/<tool> literals, so
# tests/lint-shell-portability.sh's #443 ban does not flag them. Each tool is
# resolved ONCE into an explicit var below (no dynamic var names → no dependency
# on `tr`, which itself would need resolving).
_BIN_CANDIDATE_DIRS="/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin"
_bin() {
    _br="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$_br" ]; then
        for _bd in $_BIN_CANDIDATE_DIRS; do
            [ -x "$_bd/$1" ] && {
                _br="$_bd/$1"
                break
            }
        done
    fi
    printf '%s' "${_br:-$1}"
}
# Resolve the tools this hook uses, once, at load.
CAT="$(_bin cat)"
SED="$(_bin sed)"
HEAD="$(_bin head)"
TR="$(_bin tr)"

# --- Read stdin -------------------------------------------------------------
payload="$("$CAT" 2>/dev/null || true)"
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
    # jq absent or parse failed — hand-roll extraction. These simple scrapes take
    # the shortest span to the first unescaped closing quote, so a path value
    # containing a literal escaped quote (`\"`) is TRUNCATED (jq would decode it).
    # This is an ACCEPTED no-jq gap, matching bash-guard's own hand-roll: a
    # truncated target usually still scopes correctly (the truncation lands after
    # the root prefix) or lands in the fail-open+loud branch, but a path whose own
    # checkout-root segment contains a literal `"` could in principle mis-scope in
    # the no-jq fallback ONLY. Paths with embedded quotes are pathological; the jq
    # path (present in every normal deployment) handles the exact bytes.
    cwd="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    target="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$target" ]; then
        target="$(printf '%s' "$payload" |
            "$SED" -n 's/.*"notebook_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -n1)"
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

# --- Lexically normalize `.` / `..` segments --------------------------------
# Path scoping below is lexical prefix matching, so a `..` segment would defeat
# it — and `$WT/../seed.txt` (which resolves to a MAIN-checkout path) is exactly
# the natural leak shape #475 exists to catch, NOT an edge to wave through. So
# collapse `.`/`..` here in pure bash (no realpath/stat, no symlink resolution —
# consistent with the guard's lexical, filesystem-free design) BEFORE scoping.
# A `..` that would pop past the filesystem root is a malformed absolute path we
# cannot scope — that case alone fails open loudly.
case "$target" in
    *"/./"* | *"/." | *"/../"* | *"/..")
        _norm=""
        _rest="${target#/}" # strip the leading slash; segments follow
        _bad=0
        while [ -n "$_rest" ]; do
            _seg="${_rest%%/*}"
            case "$_rest" in
                */*) _rest="${_rest#*/}" ;;
                *) _rest="" ;;
            esac
            case "$_seg" in
                "" | ".") ;; # empty (//) or current-dir: drop
                "..")
                    if [ -z "$_norm" ]; then
                        _bad=1 # would escape past `/`
                        break
                    fi
                    _norm="${_norm%/*}" # pop the last kept segment
                    ;;
                *) _norm="$_norm/$_seg" ;;
            esac
        done
        if [ "$_bad" -ne 0 ]; then
            printf '%s: target escapes the filesystem root (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$target" >&2
            exit 0
        fi
        # A fully-collapsed path (every segment popped) means the root itself.
        target="${_norm:-/}"
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

# Linked worktree. Resolve its own root — but NOT via `rev-parse --show-toplevel`,
# whose answer a worktree-writable `core.worktree` can redirect: with
# `extensions.worktreeConfig=true` (a key in the shared common-dir config) plus a
# `git config --worktree core.worktree <main-checkout>`, both issued from the
# worktree cwd, `--show-toplevel` returns the MAIN checkout root — which would make
# the worktree-first allow below match main-checkout targets and SILENTLY ALLOW a
# leak (the #501 cycle-3 CRITICAL; a pre-existing #475 gap this restructure's
# "only the path structure is trustworthy" invariant must actually honor).
#
# Instead derive the root STRUCTURALLY from the linked worktree's gitdir pointer
# file `<git_dir>/gitdir` (written once at `git worktree add` time, NOT a
# `git config` value): it holds `<worktree>/.git`, so stripping the trailing
# `/.git` yields the true worktree root. Fall back to `--show-toplevel` only when
# that file is absent, and in BOTH cases cross-check that `cwd` (which comes from
# the PreToolUse JSON — Claude Code's own tmux launch, not any git-config-derived
# value) actually lives under the resolved root; a mismatch means the derivation
# was redirected, so fail open LOUDLY rather than trust a poisoned root.
worktree_root=""
if [ -f "$git_dir_abs/gitdir" ]; then
    _gf="$("$CAT" "$git_dir_abs/gitdir" 2>/dev/null | "$HEAD" -n1)"
    _gf="${_gf%/.git}" # `<worktree>/.git` -> `<worktree>`
    case "$_gf" in
        /*) worktree_root="$(cd "$_gf" 2>/dev/null && pwd || true)" ;;
    esac
fi
if [ -z "$worktree_root" ]; then
    worktree_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$worktree_root" ]; then
    printf '%s: could not resolve the worktree root for cwd (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi
# Cross-check against the (non-config-derived) cwd: the session's cwd must be
# inside its own worktree. If it is not, worktree_root was redirected (a poisoned
# core.worktree, or a stale/mismatched gitdir file) — do not trust it.
case "$cwd" in
    "$worktree_root" | "$worktree_root"/*) ;;
    *)
        printf '%s: resolved worktree root (%s) does not contain cwd (%s) — worktree scope untrustworthy (possible core.worktree redirect); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$worktree_root" "$cwd" >&2
        exit 0
        ;;
esac

# --- Worktree-first ALLOW (topology-independent) ----------------------------
# A target INSIDE this worktree is the correct destination in EVERY topology —
# standard, submodule, and bare-repo host alike — so allow it before any
# topology derivation. Doing this first means a bare-host golem's edits to its
# own tree pass SILENTLY (no diagnostic), and only a genuinely cross-tree target
# reaches the derivation below — so the derivation never has to carve out a
# silent-allow branch that a poisonable signal could be abused to reach.
case "$target" in
    "$worktree_root" | "$worktree_root"/*) exit 0 ;;
esac

# The MAIN checkout root that a cross-tree leak could land in depends on the git
# TOPOLOGY. #475 handled only the STANDARD case (common-dir = …/<repo>/.git, main
# root = its parent); #501 extends enforcement to the submodule topology.
#
# TRUST ANCHOR — derive the topology from the common-dir PATH STRUCTURE, NOT from
# config keys. `core.bare` / `core.worktree` live in the SHARED common-dir config,
# which the very golem worktree session this guard polices can rewrite with a plain
# `git config core.bare true` / `git config core.worktree <decoy>` (those keys are
# not worktree-scoped). Trusting ANY of them — including `--is-bare-repository`,
# which just reads `core.bare` — was a confirmed silent-bypass: a one-line command
# flips the guard into an allow branch, disabling the #475/#501 control for the
# session (#501 pre-PR review, two dynamic repros). A `git config` write CANNOT
# relocate the common-dir PATH, so only the path structure is trustworthy:
#
#   - SUBMODULE (common-dir matches …/.git/modules/…): the cross-tree leak target
#     is the whole SUPERPROJECT working tree — strip from the first `/.git/modules/`
#     to get its root (%% takes the longest suffix so nested module dirs resolve to
#     the outermost superproject). The submodule's real checkout lives INSIDE the
#     superproject, so a leak into it is DENIED. Structural, so a poisoned
#     core.worktree decoy cannot redirect it.
#   - STANDARD (common-dir = …/<repo>/.git): parent of the common-dir is the main
#     checkout (the original #475 derivation). Reached whenever common-dir ends in a
#     literal `/.git`, so a stray or poisoned `core.bare=true` on a normal checkout
#     (the documented core.bare-misconfig class) no longer flips it — the structural
#     match wins and enforcement stands.
#   - NEITHER (bare-repo host OR any exotic gitdir, e.g. a `--separate-git-dir`
#     store): the main-checkout root is not derivable from the path structure
#     alone, and the only remaining discriminators (`core.bare` /
#     `--is-bare-repository`) are worktree-poisonable — so DO NOT trust them. Fail
#     open LOUDLY. A genuine bare host loses nothing (its own-worktree edits already
#     passed the worktree-first allow above; only a cross-tree target lands here,
#     and that is precisely the case worth a loud diagnostic), and an exotic gitdir
#     gets the same detectable degraded-allow it always had — with no poisonable
#     silent-allow branch anywhere.
main_root=""
topology=""
case "$common_dir_abs" in
    */.git/modules/*)
        main_root="${common_dir_abs%%/.git/modules/*}"
        topology="submodule"
        ;;
    */.git)
        main_root="${common_dir_abs%/*}"
        topology="standard"
        ;;
    *)
        printf '%s: git-common-dir (%s) is neither a top-level .git nor a submodule module dir; worktree-scope not derivable from the path structure, and config signals (core.bare) are worktree-poisonable — NOT enforcing (fail-open)\n' "$DIAG_TAG" "$common_dir_abs" >&2
        exit 0
        ;;
esac
# Defensive: a common-dir at the filesystem root (…=/.git or /.git/modules/<n>)
# would strip to the empty string, and an empty main_root turns the scope `case`
# below into `"" | ""/*` — which glob-matches EVERY absolute target (over-block).
# Not reachable in this deployment (worktrees live under /workspace/<repo>/…), but
# cheap to close: an empty main_root is undecidable, so fail open LOUDLY.
if [ -z "$main_root" ]; then
    printf '%s: derived an empty main-checkout root from common-dir (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$common_dir_abs" >&2
    exit 0
fi

# --- Path scope: DENY a cross-tree target under the MAIN checkout root -------
# The worktree-first allow above already cleared targets inside this worktree, so
# a target still matching main_root here is genuinely cross-tree (in the submodule
# case that includes the submodule's real checkout, which sits under the
# superproject but outside this worktree). A target outside the repo entirely
# (/tmp, $HOME/.claude.json, another repo) is not this guard's concern and passes.
case "$target" in
    "$main_root" | "$main_root"/*) ;;
    *) exit 0 ;;
esac

# --- Deny -------------------------------------------------------------------
# Build the reason. In the STANDARD topology the worktree mirrors main_root's
# subtree, so the leaked path maps cleanly to `$worktree_root/$rel` and
# `git -C $main_root checkout -- $rel` is the correct restore. In the SUBMODULE
# topology the worktree is a checkout of the SUBMODULE repo (it does NOT mirror
# the superproject layout — the submodule lives at a subpath there, e.g. `sub/`),
# so that prefix-substitution would fabricate a non-existent path and a recovery
# command against an untracked pathspec (the #501 cycle-3 correctness finding).
# Give topology-accurate guidance instead of a wrong concrete path.
rel="${target#"$main_root"/}"
if [ "$topology" = "submodule" ]; then
    reason="Blocked a worktree-escaping edit (#475/#501): this golem session runs in the submodule worktree \`${worktree_root}\`, but the target \`${target}\` is in the SUPERPROJECT checkout \`${main_root}\` (outside this worktree). Edits here land silently in the superproject tree (this worktree's \`git status\` stays clean) and can revert already-merged work on recovery. Do NOT write there from this worktree: make the change in the correct checkout for that path (the submodule's own working tree, or the superproject checkout, whichever owns \`${target}\`) on the right base. If a file was already leaked, restore it in the tree that owns it — never blind-copy from a stale checkout (revert risk)."
else
    suggested="$worktree_root/$rel"
    reason="Blocked a worktree-escaping edit (#475): this golem session runs in the worktree \`${worktree_root}\`, but the target \`${target}\` is in the MAIN checkout \`${main_root}\`. Edits here land silently in main (the worktree \`git status\` stays clean) and can revert an already-merged PR on recovery. Use the worktree path instead: \`${suggested}\`. If a file was already leaked into main, restore ONLY it there (\`git -C ${main_root} checkout -- ${rel}\`) and re-apply it fresh in the worktree on the correct base — never blind-copy from main (stale-base revert risk)."
fi

if command -v jq >/dev/null 2>&1; then
    jq -cn --arg reason "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
        2>/dev/null && exit 0
fi
# No jq: hand-roll the deny envelope. Sanitize the reason (drop backslashes and
# control chars that can't be JSON-escaped without a real encoder, then escape
# double quotes) so the output stays valid JSON.
reason_safe="$(printf '%s' "${reason//\\/}" | "$TR" -d '[:cntrl:]')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "${reason_safe//\"/\\\"}"
exit 0
