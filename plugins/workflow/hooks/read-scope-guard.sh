#!/usr/bin/env bash
# PreToolUse read-scope guard hook for golem worktree sessions (issue #630).
#
# A golem is isolated on the WRITE side (worktree-guard.sh, #475) but was not on
# the READ side: nothing stopped its Read/Grep/Glob from wandering into a PEER
# golem's worktree. In a parallel /workflow:orchestrate batch the golems visibly
# talked about each other's work.
#
# The cost is not merely noise. A peer worktree is a DIFFERENT BRANCH AT A
# DIFFERENT BASE, so reasoning from its files produces the stale-base class this
# repo has already been bitten by (the stale-base-squash-reverts-merged-pr and
# edits-landed-in-main-not-worktree failure modes that motivated #475). It also
# burns tokens on irrelevant context and invites a golem to "helpfully" act on a
# peer's issue.
#
# SIBLING OF worktree-guard.sh, NOT A WIDENING OF IT. The caller SIGNAL is
# identical (git-dir != git-common-dir => a linked worktree), but the deny RULE
# is different, so the two stay separate scripts:
#
#   worktree-guard.sh (write)  DENY the whole MAIN checkout outside my worktree.
#   read-scope-guard.sh (read) DENY only PEER `issue-*` worktrees.
#
# FAILURE DIRECTION IS INVERTED, AND THAT IS WHY THIS RULE IS NARROW. An
# over-broad WRITE deny is a safe false positive — the golem re-issues the edit
# against the worktree path the message names and continues. An over-broad READ
# deny can WEDGE a golem mid-turn with no recovery path: it cannot read the file
# it needs, and there is no alternate spelling that helps. So this guard denies
# the narrowest genuinely-harmful target (a peer worktree) and deliberately
# ALLOWS everything else, including the main checkout — a golem legitimately
# reads CLAUDE.md and .claude/memory/*.md, whose worktree copies are frequently
# the same bytes and whose main-checkout spelling is a routine mistake, not a
# leak. Widening to the main checkout is a LATER change behind evidence (#630
# says so explicitly); it is not a free tightening.
#
# Mechanism: Claude Code fires PreToolUse before every Read/Grep/Glob call and
# pipes the call's JSON on stdin. The envelope (same shape the two sibling guards
# document) carries:
#   { session_id, transcript_path, cwd, ..., tool_name, tool_input:{...}, ... }
# `cwd` is the session's working directory — for a golem, its worktree root.
# The TARGET field differs by tool and ALL THREE must be read:
#   Read         -> tool_input.file_path
#   Grep/Glob    -> tool_input.path          (the search root; OPTIONAL)
#   NotebookRead -> tool_input.notebook_path
#
# NotebookRead is enumerated in the matcher SEPARATELY, and that is load-bearing:
# a PreToolUse `matcher` is matched against the FULL tool name, so `Read` does NOT
# match `NotebookRead` (which is exactly why the sibling write guard spells out
# `NotebookEdit` rather than relying on `Edit`). Miss it and a golem reads a
# peer's `.ipynb` through a tool the guard never sees — review-reported and
# dynamically reproduced: the call was ALLOWED before this was added.
# An ABSENT path on Grep/Glob means "search cwd", which IS the golem's own tree —
# so a missing field must ALLOW. Denying on a missing field would block the
# single most common search a golem runs.
#
# GATING — DENY iff ALL of:
#   1. `cwd` is inside a LINKED worktree (git-dir != git-common-dir), OR is a
#      worktree DISGUISED as a primary by a rewritten gitlink (#506's forge; see
#      _find_enclosing_primary). A genuine main/orchestrator session is NEVER
#      blocked — it must keep reading every worktree, which is its whole job.
#   2. The target resolves — after joining a relative one onto `cwd` — under a
#      peer. A relative path is NOT waved through: `../issue-2/x` from a golem's
#      cwd lands squarely in a peer, so relative targets are joined to `cwd` and
#      then normalized exactly like absolute ones. (An earlier draft asserted
#      "a relative path resolves against cwd and cannot reach a peer" and
#      allowed them unconditionally — false for any value containing `..`, and
#      dynamically reproduced as a live bypass in review.)
#   3. The normalized target is under a PEER worktree: a sibling of MY worktree
#      root whose basename matches `issue-*`, and which is not my own root.
#   Everything else exits 0 SILENTLY (allow).
#
# PEER DETECTION IS STRUCTURAL AND SIBLING-DERIVED — the #630 design note's
# non-poisonable-signal requirement, and the reason this needs no config at all.
# Take MY OWN worktree root, take its parent, and treat any `issue-*` child other
# than my own as a peer. Three properties fall out for free:
#
#   - GOLEM_WORKTREE_DIR is honored WITHOUT reading it. The directory is never
#     named here; it is whatever directory my own worktree actually lives in. So
#     #626's move of the worktree root to `.claude/worktrees/` needs no change to
#     this file, and the two issues can land in either order.
#   - The shared `<worktree-dir>/.status/` feed stays readable BY CONSTRUCTION,
#     not by a carve-out: `.status` does not match `issue-*`. That matters —
#     golem-notify.sh writes it and golem-inbox.sh relays escalation gates down
#     through it, so blanket-denying the worktree root's siblings would break the
#     escalation path itself. A rule with no exception cannot have its exception
#     forgotten.
#   - Nothing is read from `git worktree list` or from any config key a linked
#     worktree can write. #501 and #506 both landed because a guard trusted
#     something the golem could rewrite (core.worktree / core.bare; a forged
#     $WT/.git). A `git config` write cannot relocate a directory on disk.
#
# ACCEPTED OUT-OF-SCOPE GAPS (documented, deliberately not covered):
#   - The `Bash` tool. A read-only `cat`/`grep` of a peer path from Bash is not
#     gated here: scanning arbitrary shell for read targets is noisy, and
#     bash-guard.sh already owns the Bash matcher for its own rules. The belt is
#     twofold — `.gitignore` carries the worktree root, so a repo-rooted search
#     does not descend into peers even without a guard (measured: a planted peer
#     file did not match while an own-tree file with the same term did), and
#     golem/SKILL.md states the read-side rule in prose.
#   - The MAIN checkout, deliberately — see the failure-direction note above.
#   - A symlink whose target escapes into a peer. Resolution here is LEXICAL
#     (segment collapse of `.`/`..`), not a realpath() through symlinks — the
#     same filesystem-free design the sibling guards use.
#   - A DISGUISED session (a golem that rewrote its own `.git` gitlink to a decoy
#     repo, #506's forge) is DETECTED but not ENFORCED in this PR: the true
#     worktree root cannot be recovered without the layout analysis that is split
#     into the follow-up PR, so such a session fails open LOUDLY rather than being
#     scoped. Detection is what matters here — without it the forged identity
#     would read as a genuine main session and allow everything silently.
#   - CASE-FOLDING. Scoping is byte-exact string comparison, so on a
#     case-INSENSITIVE filesystem (macOS APFS by default — a supported target)
#     a target spelled `/…/.Worktrees/Issue-2/f` does not prefix-match the
#     recorded `/…/.worktrees/issue-2` and is ALLOWED, though the OS resolves
#     both to the same file. Accepted for the same reason as the symlink gap:
#     case-folding correctly requires knowing the filesystem's collation, which
#     this filesystem-free design deliberately does not consult. Recorded as a
#     decision, not an oversight.
#   - A SUBMODULE gitlink is shaped exactly like a worktree gitlink (a plain
#     `.git` FILE holding `gitdir:`), so an `issue-*`-named submodule checked out
#     beside the worktrees would be treated as a peer and denied. Left as-is
#     rather than parsing the gitlink's target for `/.git/worktrees/`: that
#     layout is not one this marketplace produces, and the failure is a denial
#     with a message naming the path — recoverable — whereas a parser that
#     mis-read a real peer's gitlink would silently ALLOW.
#   - A peer whose gitlink is MISSING (a half-torn-down or hand-mangled tree) is
#     treated as "not a worktree" and ALLOWED. That direction is deliberate: the
#     peer check narrows, so a broken peer costs a stale read, whereas the other
#     direction would wedge a live golem on a directory that merely matched
#     `issue-*` (review-reported, dynamically reproduced — see the peer
#     confirmation below).
#
# FAILURE MODE — fail-open, fail-LOUD (mirrors bash-guard.sh #448 and
# worktree-guard.sh #475). On any parse/resolution failure (empty stdin,
# non-JSON, `cwd` not in a git repo, git unavailable) emit a loud stderr
# diagnostic then ALLOW. Fail-closed here would be far worse than for the write
# guard: a regressed input shape would block READS for every session, and a
# session that cannot read cannot work at all.
#
# jq is used when present; a pure-bash fallback still enforces when jq is absent
# (base macOS ships no jq), so the guard never silently weakens for lack of jq.
#
# Input  (stdin):  PreToolUse hook JSON (see schema above).
# Output (stdout): nothing (allow) OR the permissionDecision:"deny" JSON envelope.
# Exit:            always 0 — the decision travels in the JSON, not the code.
set -uo pipefail

DIAG_TAG="librarian-read-scope-guard"

# --- Portable tool resolution (#443) ----------------------------------------
# Same rationale as worktree-guard.sh: hooks run with a potentially minimal
# environment, but hardcoded /usr/bin/<tool> paths are WRONG on macOS. Honor PATH
# first via the `command -v` builtin (needs no external binary), then fall back
# to scanning standard bin dirs so it still resolves under a stripped PATH. The
# candidate list is bare DIRECTORIES, so lint-shell-portability.sh's #443 ban
# does not flag them.
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
CAT="$(_bin cat)"
SED="$(_bin sed)"
HEAD="$(_bin head)"
TR="$(_bin tr)"

# --- Disguised-worktree detection (#506, same anchor as worktree-guard.sh) ---
# The main-session identity gate below trusts `git-dir == git-common-dir`. A
# golem can FORGE that identity by rewriting its own `<cwd>/.git` gitlink to
# point at a decoy repo it `git init`s inside its own tree — after which both
# resolve to the decoy and the gate fires. The trust anchor that survives the
# poison is STRUCTURAL and OUTSIDE the worktree: the real main checkout stays a
# genuine primary that PHYSICALLY ENCLOSES cwd, and the golem cannot make it stop
# enclosing cwd without destroying `<main>/.git` and breaking its own repo.
#
# `_find_enclosing_primary cwd` walks the strict ancestors of cwd and echoes the
# OUTERMOST ancestor holding a real `.git` DIRECTORY, or "" if none. OUTERMOST —
# not nearest — defeats a decoy the golem `git init`s at a writable ancestor.
#
# It deliberately does NOT call `git rev-parse --show-toplevel` /
# `--is-bare-repository` on the ancestor: those READ core.worktree / core.bare
# from the SHARED common-dir config, which a linked-worktree golem CAN rewrite.
# A `git config` write cannot turn an on-disk `.git` DIRECTORY into something
# else, so only that structure is trusted. Copied from worktree-guard.sh rather
# than shared: hooks are standalone scripts invoked by path, with no shared-lib
# mechanism (that guard duplicates `_bin` from bash-guard.sh for the same
# reason). Pure ancestor walk via `${a%/*}` — bash-3.2 clean.
_find_enclosing_primary() {
    _fep_cwd="$1"
    _fep_a="$1"
    _fep_out=""
    while [ -n "$_fep_a" ] && [ "$_fep_a" != "/" ]; do
        _fep_a="${_fep_a%/*}"
        [ -n "$_fep_a" ] || _fep_a="/"
        # Only an ancestor that ENCLOSES cwd can be its main checkout. `/`
        # encloses EVERY absolute path, but the generic test cannot say so: the
        # pattern expands to `"/"/*`, i.e. a literal `//` prefix, which no
        # single-slash cwd matches — so the walk used to break at `/` WITHOUT
        # ever testing `/.git`. On a deployment whose primary checkout sits at
        # the filesystem root (an unusual but real container/CI layout), the walk
        # then reported "no enclosing primary", which the caller reads as a
        # genuine main session and ALLOWS unconditionally — silently disarming
        # the #506 disguise defense at that one shape. Special-case the root.
        if [ "$_fep_a" = "/" ]; then
            case "$_fep_cwd" in
                /*) ;;
                *) break ;;
            esac
        else
            case "$_fep_cwd" in
                "$_fep_a"/*) ;;
                *) continue ;;
            esac
        fi
        if [ -d "$_fep_a/.git" ]; then
            _fep_out="$_fep_a" # keep walking -> outermost match wins
        fi
        [ "$_fep_a" = "/" ] && break
    done
    printf '%s' "$_fep_out"
}

# `_derive_wt_root_poison cwd main_root` would recover this session's true
# worktree root on the DISGUISED path, where the gitlink and common-dir are the
# decoy and useless. THIS PR DOES NOT ATTEMPT THAT RECOVERY.
#
# DELIBERATE, BOUNDED SCOPE. Detecting the disguise (`_find_enclosing_primary`,
# above) is what stops a forged gitlink from being read as a genuine main session
# and silently ALLOWING everything. Recovering the true root afterwards — so the
# session can be *enforced* rather than merely flagged — is a second, much denser
# problem: it must work when both trust anchors (the gitlink and the worktree
# registry) are golem-controlled or deleted, which rules out every signal except
# the on-disk layout. That work, and the four adversarial fixtures it needs, is
# split into its own PR so it is reviewed on its own merits instead of inside the
# noise of this one.
#
# Until then this returns EMPTY, and the caller turns empty into a LOUD fail-open
# ("could not resolve the worktree root"). That is the honest degradation for a
# READ guard: a disguised session is not enforced, but the operator sees a
# diagnostic saying so, rather than a guard that looks like it is working. A
# silent allow is the one outcome avoided everywhere in this file.
_derive_wt_root_poison() {
    printf ''
}

# `_emit_deny reason` writes the PreToolUse deny envelope (jq when present, a
# sanitized hand-roll otherwise) and exits 0 — the decision travels in the JSON,
# not the exit code.
_emit_deny() {
    _ed_reason="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg reason "$_ed_reason" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
            2>/dev/null && exit 0
    fi
    # No jq: hand-roll. Sanitize the reason (drop backslashes and control chars
    # that cannot be JSON-escaped without a real encoder, then escape double
    # quotes) so the output stays valid JSON.
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
# The target is file_path (Read), path (Grep/Glob), or notebook_path
# (NotebookRead). Prefer jq; fall back to a pure-bash scraper so the guard
# enforces without jq. Note the `path` scrape runs BEFORE `notebook_path` but
# both are anchored on their own key name, so a NotebookRead payload (which has
# no `path` key) falls through to the third scrape rather than mis-reading.
cwd=""
target=""
have_fields=0
if command -v jq >/dev/null 2>&1; then
    # have_fields gates on whether jq PARSED the payload as JSON, not on any
    # field's presence — once the bytes parse, jq's extraction is authoritative
    # and more robust than the sed fallback (mirrors #448/#475).
    if printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
        have_fields=1
        cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
        target="$(printf '%s' "$payload" |
            jq -r '(.tool_input.file_path // .tool_input.path // .tool_input.notebook_path) // empty' 2>/dev/null || true)"
        # A parsed payload with NO target is a Grep/Glob searching cwd — the
        # golem's OWN tree. Allow; never deny on an absent field.
        if [ -z "$target" ]; then
            exit 0
        fi
    fi
fi

if [ "$have_fields" -eq 0 ]; then
    # jq absent or parse failed — hand-roll. These simple scrapes take the
    # shortest span to the first unescaped closing quote, so a path value holding
    # a literal escaped quote is TRUNCATED (jq would decode it). Accepted no-jq
    # gap, matching both sibling guards: a truncated target either still scopes
    # correctly or lands in a fail-open branch. Paths with embedded quotes are
    # pathological; the jq path handles the exact bytes.
    cwd="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    target="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$target" ]; then
        target="$(printf '%s' "$payload" |
            "$SED" -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -n1)"
    fi
    if [ -z "$target" ]; then
        target="$(printf '%s' "$payload" |
            "$SED" -n 's/.*"notebook_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -n1)"
    fi
    # No target at all: either a Grep/Glob over cwd (allow, as above) or an
    # unparseable payload. Both ALLOW; only the latter is worth a diagnostic, and
    # they are indistinguishable here, so stay silent rather than emit a loud
    # line on the single most common search a golem runs.
    if [ -z "$target" ]; then
        exit 0
    fi

    # TRUNCATION DETECTOR — scoped to the SCRAPED VALUE, never the whole payload.
    # The scrapes above take the shortest span to the first `"`, so a path holding
    # an escaped quote is cut short — and a cut landing BEFORE the `issue-N`
    # segment yields a DIFFERENT path that no longer looks like a peer, which the
    # structural check then allows SILENTLY. That is the one outcome this guard
    # must never produce, so such a payload fails open LOUDLY instead.
    #
    # SCOPING IS THE WHOLE POINT, and an earlier draft got it catastrophically
    # wrong: it matched `\"` anywhere in `$payload`. The PreToolUse envelope
    # carries OTHER golem-controlled fields beside the path — Grep's `pattern`
    # above all — so grepping a peer for a string containing a quote (searching
    # for `"description":`, or any quoted literal in code: an everyday search)
    # tripped the fail-open and skipped the peer deny entirely. Not a corner
    # case: a routine call, cleanly-scraped peer path, guard bypassed. Verified
    # live before and after (review-reported, HIGH).
    #
    # So re-derive the span for the key we actually used and test only that. The
    # `[^"]*` scrape stops at the first quote, so an escaped quote INSIDE the
    # value shows up as a trailing backslash on the captured text — that is the
    # signal, and it cannot be forged from a sibling field.
    case "$target" in
        *\\) _rsg_trunc=1 ;;
        *) _rsg_trunc=0 ;;
    esac
    case "$cwd" in
        *\\) _rsg_trunc=1 ;;
    esac
    if [ "$_rsg_trunc" -eq 1 ]; then
        printf '%s: the scraped path ends in a backslash, so jq-less extraction truncated it at an escaped quote and it cannot be scoped reliably (target %s); NOT enforcing (fail-open)\n' \
            "$DIAG_TAG" "$target" >&2
        exit 0
    fi
fi

# --- Resolve a relative target against `cwd` --------------------------------
# A relative target is resolved by the tool against the session's cwd, so
# `../issue-2/x` from a golem reaches its PEER — the same traversal the absolute
# form spells `$WT/../issue-2/x`, which this guard already treats as the natural
# shape of a peer read. Join it and let the normalization below collapse the
# `..`, so both spellings take the identical path through every check.
#
# An empty `cwd` cannot anchor a relative target; that is a fail-open+loud case,
# handled by the cwd check further down — reached because the join is skipped
# here rather than the target being allowed outright.
case "$target" in
    /*) ;;
    *)
        if [ -n "$cwd" ]; then
            target="$cwd/$target"
        fi
        ;;
esac

# --- Lexically normalize `.` / `..` / redundant slashes ---------------------
# Scoping below is lexical prefix matching, so a `..` segment would defeat it —
# and `$WT/../issue-2/x` is precisely the natural shape of a peer read, NOT an
# edge to wave through. Collapse in pure bash (no realpath/stat, no symlink
# resolution — consistent with the sibling guards' filesystem-free design).
# The trigger also fires on a doubled or trailing slash, so `$PEER//f` and
# `$PEER/` canonicalize — the #506 slash-variant bypass class.
# A `..` popping past the filesystem root is a malformed absolute path we cannot
# scope: that case alone fails open loudly.
case "$target" in
    *"/./"* | *"/." | *"/../"* | *"/.." | *"//"* | */)
        _norm=""
        _rest="${target#/}"
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
        target="${_norm:-/}"
        ;;
esac

# --- Caller gate: is this session a linked worktree? ------------------------
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

git_dir_abs="$(cd "$cwd" && cd "$git_dir" 2>/dev/null && pwd || true)"
common_dir_abs="$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd || true)"
if [ -z "$git_dir_abs" ] || [ -z "$common_dir_abs" ]; then
    printf '%s: could not resolve git dirs for cwd (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi

# Candidate main/orchestrator session: git-dir == git-common-dir. That identity
# is forgeable from inside a worktree (#506), so cross-check for an enclosing
# genuine primary before trusting it. NONE => a true main session, which must
# keep reading every worktree => ALLOW. One FOUND => cwd is a worktree disguised
# as main; recover the true worktree root and enforce.
DISGUISED=0
worktree_root=""
if [ "$git_dir_abs" = "$common_dir_abs" ]; then
    # An enclosing primary is necessary but NOT sufficient to call this a
    # disguise. #506's forge works by rewriting a linked worktree's `<root>/.git`
    # GITLINK FILE to point at a decoy repo — so the forged session's own
    # `.git` is still a FILE. A directory that holds a `.git` DIRECTORY was never
    # a worktree and cannot be a forged one: it is an ordinary nested repo (a
    # vendored checkout, a scratch `git init`, an example project), and those are
    # common.
    #
    # Without this discriminator the guard emitted its disguise diagnostic on
    # EVERY read from such a cwd — and since hooks.json registers it globally,
    # not only for golem sessions, that is every read in any session working
    # inside a nested repo. The decision stayed a safe allow, but the noise
    # trains an operator to ignore the single line that signals a REAL forge,
    # which is the whole value of detecting one (review-reported, reproduced).
    #
    # Walk up to the enclosing checkout root and ask what shape ITS `.git` is.
    # `--show-toplevel` is not consulted (worktree-writable, #501); `cwd` comes
    # from the payload and the walk is structural.
    _enc="$(_find_enclosing_primary "$cwd")"
    if [ -z "$_enc" ]; then
        exit 0 # genuine main/orchestrator session — never blocked
    fi
    # Find the nearest ancestor-or-self of cwd carrying a `.git` entry; that is
    # this session's own checkout root as git sees it.
    _own_root="$cwd"
    while [ -n "$_own_root" ] && [ "$_own_root" != "/" ] && [ ! -e "$_own_root/.git" ]; do
        _own_root="${_own_root%/*}"
        [ -n "$_own_root" ] || _own_root="/"
    done
    if [ -d "$_own_root/.git" ]; then
        exit 0 # a nested PRIMARY repo, not a disguised worktree — allow silently
    fi
    DISGUISED=1
    worktree_root="$(_derive_wt_root_poison "$cwd" "$_enc")"
fi

# Linked worktree. Resolve its own root — but NOT via `rev-parse --show-toplevel`,
# whose answer a worktree-writable `core.worktree` can redirect (the #501 cycle-3
# CRITICAL). Derive it STRUCTURALLY from the linked worktree's gitdir pointer file
# `<git_dir>/gitdir` (written once at `git worktree add` time, NOT a config
# value): it holds `<worktree>/.git`, so stripping the trailing `/.git` yields the
# true root. Fall back to `--show-toplevel` only when that file is absent, and in
# BOTH cases cross-check that `cwd` (which comes from the PreToolUse JSON, not
# from any git-config-derived value) really lives under the resolved root; a
# mismatch means the derivation was redirected, so fail open LOUDLY.
if [ "$DISGUISED" -eq 0 ]; then
    if [ -f "$git_dir_abs/gitdir" ]; then
        _gf="$("$CAT" "$git_dir_abs/gitdir" 2>/dev/null | "$HEAD" -n1)"
        _gf="${_gf%/.git}"
        case "$_gf" in
            /*) worktree_root="$(cd "$_gf" 2>/dev/null && pwd || true)" ;;
        esac
    fi
    if [ -z "$worktree_root" ]; then
        worktree_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    fi
fi
if [ -z "$worktree_root" ]; then
    printf '%s: could not resolve the worktree root for cwd (%s); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$cwd" >&2
    exit 0
fi
case "$cwd" in
    "$worktree_root" | "$worktree_root"/*) ;;
    *)
        printf '%s: resolved worktree root (%s) does not contain cwd (%s) — worktree scope untrustworthy (possible core.worktree redirect); NOT enforcing (fail-open)\n' "$DIAG_TAG" "$worktree_root" "$cwd" >&2
        exit 0
        ;;
esac

# --- Own-worktree-first ALLOW -----------------------------------------------
# A target inside MY worktree is always correct. Clear it before any peer
# derivation, so the common case costs nothing and cannot be caught by a later
# rule. This also makes the peer rule below unambiguous: anything it matches is
# genuinely NOT mine.
case "$target" in
    "$worktree_root" | "$worktree_root"/*) exit 0 ;;
esac

# --- Peer derivation: siblings of MY worktree root named `issue-*` ----------
# The worktree DIR is the parent of my own root — never the literal
# `.worktrees`, so GOLEM_WORKTREE_DIR (and #626's move to `.claude/worktrees/`)
# is honored without being read. A root at the filesystem root has no meaningful
# parent and cannot have peers; treat it as undecidable and allow.
wt_parent="${worktree_root%/*}"
if [ -z "$wt_parent" ] || [ "$wt_parent" = "$worktree_root" ]; then
    exit 0
fi

# THE WORKTREE DIR ITSELF is a peer read in disguise, and denying only paths
# UNDER a peer would miss it. A `Grep`/`Glob` rooted at `<worktree-dir>` descends
# into EVERY peer — measured: a term planted in a peer is returned by a search
# rooted here — so the narrow per-peer rule below would allow the single most
# effective way to read them all at once. Deny the container, and say so
# specifically: the fix is to search your own root, which the reason names.
#
# Only the DIRECTORY itself, never its parent chain: `<repo>` and `/` also
# "contain" peers, but denying those would block the main checkout and the whole
# filesystem — the over-broad read deny this guard exists to avoid. A search
# rooted at the repo does not reach peers anyway (the worktree dir is in
# `.gitignore`, pinned by tests/read-scope-guard/30-search-surface.sh), which is
# exactly why the container needs naming and the ancestors do not.
if [ "$target" = "$wt_parent" ]; then
    _wd_reason="Blocked a read rooted at the shared worktree directory (#630): \`${wt_parent}\` contains EVERY golem's worktree, so a search here descends into your peers' trees — which are on different branches at different bases, and reasoning from them produces stale-base conclusions. Search your OWN worktree instead: \`${worktree_root}\`. The status feed \`${wt_parent}/.status/\` is readable directly if you need coordination state."
    _emit_deny "$_wd_reason"
fi

# Is the target under a SIBLING of my root? Strip my parent's prefix and take the
# first remaining segment — that segment is the sibling's name.
case "$target" in
    "$wt_parent"/*) ;;
    *) exit 0 ;; # outside the worktree dir entirely: main checkout, /tmp, $HOME
esac
_sib_rest="${target#"$wt_parent"/}"
_sib="${_sib_rest%%/*}"
[ -n "$_sib" ] || exit 0

# `.status` and any other non-`issue-*` sibling stays readable BY CONSTRUCTION —
# the escalation path (golem-notify.sh writes the feed, golem-inbox.sh relays
# gates through it) depends on it, and a rule with no exception cannot have its
# exception forgotten.
case "$_sib" in
    issue-*) ;;
    *) exit 0 ;;
esac

# My own root was already cleared by the own-worktree-first allow above, so any
# `issue-*` sibling reaching here is a PEER. Belt-and-suspenders: never deny my
# own root even if that allow is ever reordered away.
peer_root="$wt_parent/$_sib"
[ "$peer_root" != "$worktree_root" ] || exit 0

# CONFIRM IT IS REALLY A WORKTREE — the name alone is not enough. `issue-*` is a
# naming convention, not a guarantee: a human's `issue-999-scratch-notes/`, a
# kept backup of a torn-down tree, or any directory tooling drops beside the
# worktrees matches the pattern while being nobody's worktree. Denying those is
# the over-broad READ deny this guard's own header argues against — it wedges a
# golem on a path with no peer behind it (dynamically reproduced: a bare
# `mkdir issue-999-scratch-notes` was denied before this check existed).
#
# The structural signal is the linked worktree's gitlink FILE `<peer>/.git`,
# written by `git worktree add` — a plain file (not the `.git` DIRECTORY a
# primary checkout has), holding `gitdir: <path>`. Test the STRUCTURE only, never
# `git -C "$peer_root" rev-parse`: shelling into a peer to decide whether to
# block reading it would both cost a process on the hot path and consult config
# that a linked worktree can rewrite — the poisonable-signal class #501/#506
# closed. A `.git` file is not something a `git config` write can conjure.
#
# FAILURE DIRECTION: absent gitlink => NOT a worktree => ALLOW. That keeps this
# check strictly narrowing, so it can only ever remove a false denial, never add
# a new one. A peer that somehow lacks its gitlink is already broken and its
# stale bytes are the lesser risk against wedging a live golem.
if [ ! -f "$peer_root/.git" ]; then
    exit 0
fi

# --- Deny -------------------------------------------------------------------
reason="Blocked a read into a PEER golem's worktree (#630): this session works in \`${worktree_root}\`, but the target \`${target}\` is inside \`${peer_root}\`, which belongs to another golem. That worktree is on a DIFFERENT BRANCH AT A DIFFERENT BASE, so reasoning from its files produces stale-base conclusions (the class that has twice reverted merged work here) and invites acting on another issue. Read the copy in YOUR OWN worktree instead (\`${worktree_root}/...\`). The shared status feed under \`${wt_parent}/.status/\` IS readable if you need coordination state; anything else about a peer's work belongs to the orchestrator, so escalate rather than reading it."
_emit_deny "$reason"
