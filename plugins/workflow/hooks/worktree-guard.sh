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
#   - The `Bash` tool, for THIS guard's rule (golem -> main). Scanning arbitrary
#     shell for a leaked write target is noisy (a mere `cat /workspace/<repo>/...`
#     read is not a leak) and the sibling bash-guard already owns the Bash matcher.
#     The golem SKILL prompt guidance (always use worktree-relative /
#     $PWD-anchored paths, never a bare /workspace/<repo>/... root) is the belt for
#     Bash. Note the OPPOSITE direction (main -> golem worktree) IS covered on the
#     Bash surface, by bash-guard's Rule B (#662) — but only for the three
#     destructive git verbs, where the target tree is decidable from `-C`/`cd`
#     without parsing arbitrary write targets.
#   - A symlink whose target escapes the worktree. Path resolution here is
#     lexical (segment collapse of `.`/`..`), not a realpath() through symlinks.
#   - A bare-host or EXOTIC gitdir (above) whose scope cannot be derived from the
#     path structure: fails open with a loud stderr diagnostic BY DESIGN; the
#     prompt belt + human review back it up.
#   - A golem REWRITING its own `$worktree/.git` gitlink file to point at a decoy
#     repo used to defeat the git-dir==common-dir main-session gate ABOVE (making
#     its cwd look like an un-blockable primary checkout). CLOSED in #506: the
#     identity gate now cross-checks whether an OUTERMOST enclosing genuine primary
#     (a structural anchor above the worktree the golem cannot forge) owns cwd, and
#     if so re-derives scope and enforces — so the forged identity no longer
#     disarms the guard regardless of the write vector (gitlink rewrite OR
#     `git config`). The disarming Edit/Write to `$worktree/.git` is ALSO denied
#     outright (defense in depth). The residual `Bash`-tool vector (a `printf` /
#     `rm` from the golem's own MAIN loop) is neutralized by that re-derivation,
#     not blocked — bash-guard does not gate a main-loop `rm`/`printf` (since #662
#     it gates main-session commands too, but only the three destructive GIT verbs,
#     and only when aimed at ANOTHER tree's linked worktree — a golem writing
#     inside its OWN tree is exactly the allowed case), and the main loop must stay
#     un-blocked. See the disguised-worktree detection below.
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

# --- Disguised-worktree detection (#506) ------------------------------------
# The main-session identity gate below trusts `git-dir == git-common-dir`. For a
# linked worktree that identity is controlled by the plaintext gitlink FILE
# `<cwd>/.git` (`gitdir: <path>`), which the golem can OVERWRITE to point at a
# decoy repo it `git init`s inside its own tree — after which BOTH git-dir and
# git-common-dir resolve to the decoy, the gate fires, and every edit is treated
# as a main session (the guard is disarmed). The trust anchor that survives the
# poison is STRUCTURAL and OUTSIDE the worktree: the real main checkout stays a
# genuine primary (`git-dir==git-common-dir`, `--show-toplevel==itself`) that
# PHYSICALLY ENCLOSES cwd — the golem cannot make it stop enclosing cwd, or stop
# being a primary, without destroying `<main>/.git` (which breaks its own repo).
#
# `_find_enclosing_primary cwd` walks the strict ancestors of cwd and echoes the
# OUTERMOST ancestor that is a standard checkout enclosing cwd, or "" if none. It is
# the disambiguator between a genuine main session (no such ancestor → allow) and a
# worktree disguised as one (found → enforce scope against it). OUTERMOST — not
# nearest — defeats a nearer-ancestor decoy the golem `git init`s at a writable
# ancestor (e.g. `<main>/.worktrees`): the real main still encloses that decoy, so
# the outermost match is the true main_root.
#
# TRUST ANCHOR — the primary test is STRUCTURAL: a real `.git` DIRECTORY at the
# ancestor. It deliberately does NOT call `git rev-parse --show-toplevel` /
# `--is-bare-repository` on the ancestor: those READ `core.worktree` / `core.bare`
# from the SHARED common-dir config, which a linked-worktree golem CAN rewrite
# (those keys are not worktree-scoped) — `git config core.worktree <decoy>` /
# `core.bare true` would then redirect/blank the ancestor's `--show-toplevel` and
# flip this detector back to a silent allow, re-opening the exact leak (dynamic
# repro, #506 pre-PR review CRITICAL — the same poisonable-signal class #501
# eliminated elsewhere). A `git config` write CANNOT turn the on-disk `<a>/.git`
# DIRECTORY into something else, so only that structure is trusted. Selecting the
# OUTERMOST match keeps main_root as LARGE as possible, so the failure direction is
# over-DENY (a conservative false positive), never a leak-enabling under-scope.
# Pure ancestor walk via `${a%/*}` (no dirname/mapfile/declare -A; bash-3.2 clean).
_find_enclosing_primary() {
    _fep_cwd="$1"
    _fep_a="$1"
    _fep_out=""
    while [ -n "$_fep_a" ] && [ "$_fep_a" != "/" ]; do
        _fep_a="${_fep_a%/*}"
        [ -n "$_fep_a" ] || _fep_a="/"
        # Only an ancestor that ENCLOSES cwd can be its main checkout.
        case "$_fep_cwd" in
            "$_fep_a"/*) ;;
            *) [ "$_fep_a" = "/" ] && break || continue ;;
        esac
        # Structural primary: a real `.git` DIRECTORY (a standard checkout's
        # git-dir). Non-poisonable — see the TRUST ANCHOR note above.
        if [ -d "$_fep_a/.git" ]; then
            _fep_out="$_fep_a" # keep walking → outermost match wins
        fi
        [ "$_fep_a" = "/" ] && break
    done
    printf '%s' "$_fep_out"
}

# `_derive_wt_root_poison cwd main_root` finds this session's true worktree root on
# the disguised path, where the gitlink/common-dir are the decoy and useless. It
# takes the LONGEST `worktree <P>` from the real main's `worktree list` that is
# under main_root, is not main_root itself, and encloses cwd. That registry lives
# at `<main>/.git/worktrees/<id>/` (outside the worktree); a golem can DELETE it
# with unguarded Bash, so this FALLS BACK to cwd when no admissible entry is found.
# Both the fallback and any forged/registry entry are safe for scope: a leak target
# under main_root but outside the true worktree stays outside every admissible P,
# so the scope `case` still DENIES it. Longest-prefix avoids collapsing to main_root
# (which `worktree list` also reports as enclosing cwd).
_derive_wt_root_poison() {
    _dwr_cwd="$1"
    _dwr_main="$2"
    _dwr_best=""
    _dwr_list="$(git -C "$_dwr_main" worktree list --porcelain 2>/dev/null || true)"
    # Iterate the `worktree <path>` lines (bash-3.2: here-string + read loop).
    while IFS= read -r _dwr_line; do
        case "$_dwr_line" in
            "worktree "*) _dwr_p="${_dwr_line#worktree }" ;;
            *) continue ;;
        esac
        [ -n "$_dwr_p" ] || continue
        [ "$_dwr_p" != "$_dwr_main" ] || continue
        case "$_dwr_p" in
            "$_dwr_main"/*) ;;
            *) continue ;;
        esac
        # Must enclose cwd (or equal it).
        case "$_dwr_cwd" in
            "$_dwr_p" | "$_dwr_p"/*) ;;
            *) continue ;;
        esac
        # Keep the longest such path.
        if [ "${#_dwr_p}" -gt "${#_dwr_best}" ]; then
            _dwr_best="$_dwr_p"
        fi
    done <<EOF
$_dwr_list
EOF
    printf '%s' "${_dwr_best:-$_dwr_cwd}"
}

# `_emit_deny reason` writes the PreToolUse deny envelope (jq when present, a
# sanitized hand-roll otherwise) and exits 0 — the decision travels in the JSON,
# not the exit code. Shared by every deny path (the standard/submodule leak reason
# and the #506 gitlink-write reason) so the jq/no-jq emission logic lives once.
_emit_deny() {
    _ed_reason="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg reason "$_ed_reason" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
            2>/dev/null && exit 0
    fi
    # No jq: hand-roll the deny envelope. Sanitize the reason (drop backslashes and
    # control chars that can't be JSON-escaped without a real encoder, then escape
    # double quotes) so the output stays valid JSON.
    _ed_safe="$(printf '%s' "${_ed_reason//\\/}" | "$TR" -d '[:cntrl:]')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "${_ed_safe//\"/\\\"}"
    exit 0
}

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

# --- Lexically normalize `.` / `..` / redundant slashes ---------------------
# Path scoping below is lexical prefix matching, so a `..` segment would defeat
# it — and `$WT/../seed.txt` (which resolves to a MAIN-checkout path) is exactly
# the natural leak shape #475 exists to catch, NOT an edge to wave through. So
# collapse `.`/`..` here in pure bash (no realpath/stat, no symlink resolution —
# consistent with the guard's lexical, filesystem-free design) BEFORE scoping.
# A `..` that would pop past the filesystem root is a malformed absolute path we
# cannot scope — that case alone fails open loudly.
#
# The trigger ALSO fires on a doubled slash (`//`) or a trailing slash: the loop
# drops empty segments, so `$WT//.git` and `$WT/.git/` canonicalize to `$WT/.git`.
# Without this the strict gitlink-write equality below (#506 FIX B) — and every
# other lexical comparison — would be bypassable by a filesystem-equivalent
# `$WT//.git` / `$WT/.git/` that opens the same inode (#506 pre-PR review, HIGH,
# dynamic-repro'd: the worktree-first-allow glob matched those variants while the
# strict gitlink-deny did not, so the disarming write slipped through).
case "$target" in
    *"/./"* | *"/." | *"/../"* | *"/.." | *"//"* | */)
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

# Candidate main session: git-dir == git-common-dir. Historically an unconditional
# ALLOW ("main session, never block"), but a golem can FORGE this identity by
# rewriting its own `<cwd>/.git` gitlink to a decoy repo — disarming the guard
# (#506). So before trusting it, cross-check whether cwd is really enclosed by a
# genuine primary checkout (a signal the poison cannot forge from inside the
# worktree — see `_find_enclosing_primary`). If NONE encloses cwd it is a true main
# session (standard top-level OR a legit `--separate-git-dir` main, whose cwd/.git
# is also a FILE with git-dir==common) → ALLOW as before. If one DOES, cwd is a
# worktree DISGUISED as main: adopt that primary as main_root, recover the true
# worktree root structurally, and fall through to the SAME scope enforcement a
# normal linked worktree gets (the decoy common-dir is skipped as useless).
DISGUISED=0
worktree_root=""
main_root=""
topology=""
if [ "$git_dir_abs" = "$common_dir_abs" ]; then
    _enc="$(_find_enclosing_primary "$cwd")"
    if [ -z "$_enc" ]; then
        exit 0 # genuine main session — never blocked
    fi
    DISGUISED=1
    main_root="$_enc"
    topology="standard"
    worktree_root="$(_derive_wt_root_poison "$cwd" "$main_root")"
    if [ -z "$worktree_root" ]; then
        printf '%s: could not resolve the worktree root for a disguised session (cwd %s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
        exit 0
    fi
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
#
# On the DISGUISED path (#506) this whole block is skipped: git_dir is the decoy,
# so its `gitdir` pointer is untrustworthy — worktree_root was already recovered
# from the enclosing primary's registry above.
if [ "$DISGUISED" -eq 0 ]; then
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
    # inside its own worktree. If it is not, worktree_root was redirected (a
    # poisoned core.worktree, or a stale/mismatched gitdir file) — do not trust it.
    case "$cwd" in
        "$worktree_root" | "$worktree_root"/*) ;;
        *)
            printf '%s: resolved worktree root (%s) does not contain cwd (%s) — worktree scope untrustworthy (possible core.worktree redirect); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$worktree_root" "$cwd" >&2
            exit 0
            ;;
    esac
fi

# --- Gitlink DENY (#506, before the worktree-first allow) --------------------
# The worktree's own `.git` gitlink FILE is the disarm vector: overwriting it to
# point at a decoy repo forges the main-session identity gate (FIX A now re-detects
# and neutralizes that, but block the write itself too — defense in depth, AC#2).
# It sits INSIDE the worktree, so the worktree-first allow below would otherwise
# permit it — this deny must come FIRST. `target` is already `.`/`..`-normalized.
if [ "$target" = "$worktree_root/.git" ]; then
    _gl_reason="Blocked a write to this worktree's \`.git\` gitlink (#506): overwriting \`${worktree_root}/.git\` repoints the session at a decoy repo and disarms the worktree-scope guard (it makes a worktree look like an un-blockable main session). This file is managed by \`git worktree\`; do not edit it. If you meant to change tracked content, target a path UNDER \`${worktree_root}\` instead."
    _emit_deny "$_gl_reason"
fi

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
#
# On the DISGUISED path (#506) main_root/topology were already set from the
# enclosing primary (common_dir is the decoy, so this derivation is skipped).
if [ "$DISGUISED" -eq 0 ]; then
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

_emit_deny "$reason"
