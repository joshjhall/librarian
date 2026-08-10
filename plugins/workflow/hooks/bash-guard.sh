#!/usr/bin/env bash
# PreToolUse Bash-guard hook for read-only review/analysis subagents (issue #448).
#
# #426 showed a nominally read-only reviewer subagent can run destructive shell
# (`rm -rf`) against the LIVE working tree and be technically compliant: the
# harness READONLY prompt banned file/VCS mutation but not destructive shell
# exec, and every review agent holds `Bash`. #426 shipped the belt (strengthened
# prose + a regression lint) and scope-locked the ONE origin agent
# (code-reviewer) at the tool level. This hook is the deferred remainder: it
# enforces the destructive-shell ban at the TOOL level for EVERY Bash-capable
# review/analysis subagent (checker, audit-*, the default orchestrate poll agent)
# that still holds unscoped `Bash` and is guarded only by prose.
#
# Mechanism: Claude Code fires PreToolUse before every Bash call, session-wide,
# and pipes the call's JSON on stdin. A plugin hook cannot be scoped to
# subagents-only at the matcher level, so this script does the branching. The
# stdin schema (verified empirically against the running CLI, 2.1.215, by
# capturing a live subagent Bash call) is:
#   { session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
#     hook_event_name, tool_name, tool_input:{command}, tool_use_id,
#     agent_id, agent_type }
# where `agent_id` + `agent_type` are present ONLY for a subagent call — a
# main-session Bash call carries NO agent_id. That presence is the caller signal.
#
# GATING — TWO independent deny rules, evaluated against the SAME deny-set match.
#
# RULE A (#448) — SUBAGENT destructive shell. DENY iff ALL of:
#   1. Positive subagent: stdin `agent_id` (or camelCase `agentId`) is non-empty.
#   2. Destructive head: the command (normalized, split on ; && || | ( $( )
#      matches the deny-set — the file-removing/renaming/truncating tokens and
#      the working-tree-resetting git verbs (clean, reset-hard, checkout-dashdash)
#      plus `>`/`>>` redirection — lifted from the READONLY_POLL / READONLY /
#      checker.md prose constants.
#   3. Not scratch-confined: allow when the command stages a mktemp sandbox or the
#      destructive target resolves under /tmp, $TMPDIR, or /var/tmp (the
#      sandbox carve-out those same prose constants grant).
#
# RULE B (#662) — MAIN-SESSION destructive git aimed at ANOTHER tree's worktree.
# The main session (no agent_id) was historically an UNCONDITIONAL allow, on the
# reasoning that it is the human's own session and its worktree-teardown deletes
# must never be at risk. #662 showed that blanket exemption is too wide in one
# specific direction: an ORCHESTRATOR is the main session, it routinely runs
# `git -C <worktree> …` for status polling and rebase resolution, and a
# `git reset --hard` slipped into that routine destroyed a golem's uncommitted
# work. A golem worktree is BY DESIGN the densest concentration of uncommitted
# work in the topology — no reflog entry, no stash, no PR — so the blast radius
# there is strictly LARGER than the same command in the main checkout, while
# being the less-guarded of the two. DENY iff ALL of:
#   1. Main session: NO agent_id (a subagent is Rule A's business).
#   2. The deny-set match is one of the four GIT verbs (`git reset --hard`,
#      `git clean`, `git checkout --`, `git worktree remove --force`).
#      Deliberately NOT the whole deny-set:
#      `rm`/`mv`/`truncate`/redirection keep their unconditional main-session
#      allow, so `rm -rf .worktrees/issue-N` teardown still works and
#      worktree-rm.sh (which does its own dirty check) stays the owner of
#      deliberate teardown.
#
#      `git worktree remove --force` was added by #665, which #662 deferred
#      BECAUSE the verb is itself a teardown verb — the one shape that sits
#      against, rather than merely extending, the git-verbs-only scope decision.
#      DECISION: DENY, on two grounds.
#      (a) The objection does not hold. It was that denying would break the
#          sanctioned `scripts/worktree-rm.sh`, which runs `git worktree remove
#          --force` internally. It cannot: this is a PreToolUse hook on the BASH
#          TOOL, so it only ever sees the command string the model submits.
#          worktree-rm.sh is invoked as `bash .../worktree-rm.sh N`; the forced
#          remove inside it is a SUBPROCESS OF THE SCRIPT and never reaches this
#          hook. Verified by piping that exact payload in — allow, no output —
#          and pinned by test_worktree_rm_still_works. So the sanctioned path is
#          unaffected BY CONSTRUCTION, not by a carve-out that could rot.
#      (b) `--force` is precisely the case with something to lose. The PLAIN form
#          already refuses a dirty worktree, so an operator reaches for `--force`
#          exactly WHEN the tree is dirty — Rule B's stated rationale verbatim.
#      Corollary, and the reason the scope is `--force`-only: plain `git worktree
#      remove` stays ALLOWED. It has its own dirty-refusal and thus no
#      unrecoverable work to destroy; denying it would block a safe verb and push
#      operators toward the forced form, which is the opposite of the goal.
#   3. CROSS-TREE into a linked worktree: the command's resolved TARGET tree is a
#      linked worktree (its git-dir != its git-common-dir) AND is not the calling
#      session's OWN tree. The second half is load-bearing, not a nicety — it is
#      what lets a golem reset ITS OWN worktree, and what keeps a bare-repo
#      worktree host's own work unblocked. A rule of merely "target is a
#      worktree" would break both.
#
# To DENY (either rule): exit 0 with the JSON permissionDecision:"deny" envelope
# + a reason the model can act on. Everything else exits 0 silently (allow).
#
# FAILURE MODE — fail-open for the session, fail-LOUD on parse trouble (operator
# decision, #448). On any parse failure (empty stdin, non-JSON, no agent_id
# resolvable) emit a loud stderr diagnostic then ALLOW. Rationale: fail-closed
# would, if the input shape ever regresses, deny the MAIN session's teardown rm —
# breaking the happy path for every session, the worse outcome. This guard is a
# SECOND layer behind #426's shipped prose+lint belt, so a *detectable* degraded-
# allow (loud on stderr, and validate-bash-guard.sh asserts the positive-block
# path so a permanent no-op fails CI) is tolerable where a false main-session
# block is not. Note the exit contract is INVERTED from the sibling golem-notify
# hook (which always exits 0 / never blocks) — this one must be able to deny.
#
# Rule B keeps that posture and inherits an extra class of it: every way the
# TARGET-TREE resolution can fail — no `cwd` in the payload, `git` not on PATH,
# the target not inside a git repo, a `rev-parse` that errors — ALLOWS, which is
# exactly the main session's historical behavior. Combined with Rule B's
# git-verbs-only scope, the #662 change can therefore only ever ADD a denial and
# can never remove one; that property is what makes it safe on a hook that fires
# before EVERY Bash call in the session. Rule B's resolution is also LAZY: it runs
# only after a destructive verb has already matched (see the caller gate's
# placement below), so an ordinary main-session command pays no `git` cost at all.
#
# DETECTION SCOPE — a pragmatic tokenizer, NOT a shell parser or a sandbox. It is
# the second enforcement layer behind #426's shipped prose+lint belt, and it
# biases toward blocking with a clear reason (a false negative silently defeats a
# safety control; a false positive costs one denial the agent can react to by
# re-running under `mktemp -d`). It catches the common, non-adversarial shapes:
# separators (`;` `&&` `||` `&` `|` newline), pipes and subshells, quoted/escaped
# heads (`"rm"`/`\rm`), wrapper prefixes (`env`/`sudo`/`time`/`exec`/`xargs`),
# compound-command keywords (`if…then rm…fi`, `case`, `while…do`, brace groups),
# per-operand scratch checks, and full redirect-target scanning.
#
# ACCEPTED OUT-OF-SCOPE GAPS (documented, deliberately not covered — matching
# #426's literal-token prose; a real shell would be needed to close these, which
# is a non-goal for a defense-in-depth layer):
#   - command INDIRECTION: `b=rm; $b -rf x`, `$(which rm) -rf x`, `eval`.
#   - argument INDIRECTION: `xargs rm`, `find … -delete`, `find … -exec rm`.
#   - obfuscation/encoding: `base64 -d | sh`, char-by-char reconstruction.
#   - non-standard binaries: `busybox rm`, `/usr/local/bin/rm`, `perl -e unlink`.
#   - statement-ORDER edge: the contrived reverse `d=src; rm -rf $d;
#     d=$(mktemp -d)` (delete a live var BEFORE its name is reassigned to a
#     scratch dir) — the natural `mktemp-then-delete` forms ARE covered.
# Rule B (#662) adds three of its own, same spirit:
#   - TARGETING forms other than `-C <path>` and a preceding `cd <path>`:
#     `git --git-dir=<wt>/.git --work-tree=<wt> reset --hard` in EITHER the
#     attached (`--git-dir=<p>`) or separated (`--git-dir <p>`) form, and `$GIT_DIR`
#     set in the environment. Both `--git-dir` forms are consumed as global options
#     by the subcommand scanner so the verb is still detected, but neither is
#     re-parsed as a target — only `-C`'s operand is captured. `-C` is what an
#     orchestrator actually types (it is the form the polling and rebase paths
#     use) and `cd` is the natural hand-typed alternative.
#   - an operand that is a VARIABLE or command substitution (`cd "$wt" && git
#     reset --hard`, `git -C "$wt" …`): the target is not knowable without
#     evaluating the shell, so it resolves to the payload `cwd` like a bare
#     command would. `~/…` is NOT in this class — it is expanded from $HOME
#     below, because leaving it unexpanded was a live silent bypass.
#   - `~user/...` (another user's home): expanding it needs a passwd lookup this
#     hook has no business doing, so it falls through to the fail-open path.
#     (REPEATED `-C a -C b` is NOT in this gap list — it is implemented, chaining
#     each relative operand onto the previous exactly as git's successive chdirs
#     do. It was briefly documented here as an accepted gap "that fails toward
#     allow"; that claim was FALSE and the review caught it — resolving only the
#     last operand points at `<cwd>/b` rather than `<cwd>/a/b`, so an unrelated
#     linked worktree at that path is denied by NAME, a wrong-deny rather than a
#     missed one. Kept as a note because "we simplified X and it is safe" is the
#     shape of comment worth distrusting.)
# #665 adds one more, from the fourth verb's different targeting shape:
#   - `git worktree remove` takes its target POSITIONALLY, not via `-C` — the
#     path names the tree being deleted, whereas `-C` only says where git runs.
#     So that arm scans operands for the first non-flag token instead of reusing
#     `_rule_b_target` ALONE — it JOINS the two, because git resolves a relative
#     operand against the `-C`/`cd` cwd (see the arm's own comment). A
#     `$var`/backtick operand is unresolvable: it falls back to the `-C`/`cd`/cwd
#     chain, i.e. fail-open, same as everywhere else.
#   - a worktree path whose basename starts with `-` (`git worktree remove
#     --force -mytree`) is read as a FLAG by the operand scanner, so the target
#     falls back to the `-C`/`cd`/cwd base. Accepted, not fixed: `-`-led
#     directory names are pathological, git itself needs `--` to accept one, and
#     the fallback lands on the fail-open side. Recorded here so it is a decision
#     rather than an oversight (#677 review). The `--`-separated spelling of the
#     same command IS handled — `--` is skipped as a flag and the path after it
#     resolves normally.
#   - a worktree path containing a SPACE (`git worktree remove --force "my wt"`)
#     splits on IFS like every other operand in this file, so the scanner takes
#     the first fragment (`my`) as the target; it resolves nowhere and the `-d`
#     check fail-opens. Accepted for the same reason the whole DETECTION SCOPE
#     section gives — this is a pragmatic tokenizer, not a shell parser, and
#     honoring quotes properly means implementing quote-aware word splitting for
#     every operand path here, not just this one. Called out explicitly (#677
#     review cycle 2) because a space in a path is far more ORDINARY than the
#     `-`-led case above, so its absence from this list would read as coverage.
#     Note the guard still denies a spaceless path that is merely QUOTED — the
#     quote-stripping covers that, and it is the common spelling.
#   - the operand scan is an unquoted `for … in $_wt_rest`, so it inherits this
#     file's existing word-splitting AND pathname expansion (no `set -f` is in
#     effect anywhere here; the same is true of the `for tok in $seg` scan that
#     predates it). A glob operand can therefore expand against whatever cwd the
#     hook happens to run in. Accepted rather than special-cased: `git worktree
#     remove` takes ONE worktree, a glob is not a spelling anyone uses for it,
#     and the expansion cannot silently target a DIFFERENT tree than the shell
#     would — the shell expands the same glob in the same cwd before git ever
#     runs, so the guard and the command see the same operand. Recorded because
#     this is a NEW use of that pattern driving a destructive verb's target
#     resolution, which is exactly the kind of inheritance worth stating.
# These are logged nowhere and pass silently BY DESIGN; the belt (#426 prose) and
# human PR review remain the backstop for them.
#
# jq is used when present; a pure-bash fallback still enforces when jq is absent
# (base macOS ships no jq), so the guard never silently weakens for lack of jq.
#
# Input  (stdin):  PreToolUse hook JSON (see schema above).
# Output (stdout): nothing (allow) OR the permissionDecision:"deny" JSON envelope.
# Exit:            always 0 — the decision travels in the JSON, not the code.
set -uo pipefail

DIAG_TAG="librarian-bash-guard"

# --- Portable tool resolution (#443) ----------------------------------------
# Claude Code invokes PreToolUse hooks with a potentially minimal environment, so
# this hook historically hardcoded /usr/bin/<tool> to survive a stripped PATH.
# Those absolute paths are WRONG on macOS (core utils in /bin) and hard-crash the
# hook there. `_bin <tool>` honors PATH first (the `command -v` builtin needs no
# external binary), then falls back to scanning the standard bin dirs so it still
# resolves under a stripped PATH, then yields the bare name. The candidate list is
# bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint does not flag
# them. NOTE: the deny-set `case` patterns below (e.g. `rm | /bin/rm |
# /usr/bin/rm`) are match DATA — the absolute-path command forms this guard must
# DETECT in a scanned subagent command — NOT invocations, so they stay literal.
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

# `_emit_deny_reason <reason>` writes the PreToolUse deny envelope (jq when
# present, a sanitized hand-roll otherwise) and exits 0 — the decision travels in
# the JSON, not the exit code. Shared by BOTH deny rules (#448's subagent rule and
# #662's main-session worktree rule) so the jq/no-jq emission logic lives once;
# the sibling worktree-guard.sh factors its `_emit_deny` the same way.
_emit_deny_reason() {
    _edr_reason="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg reason "$_edr_reason" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
            2>/dev/null && exit 0
    fi
    # No jq: hand-roll the deny envelope. Sanitize the reason (drop backslashes and
    # control chars that can't be JSON-escaped without a real encoder, then escape
    # double quotes) so the output stays valid JSON.
    _edr_safe="$(printf '%s' "${_edr_reason//\\/}" | "$TR" -d '[:cntrl:]')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
        "${_edr_safe//\"/\\\"}"
    exit 0
}

# `_abs_git_dir <dir> <--git-dir|--git-common-dir>` echoes that git dir as an
# ABSOLUTE path, or "" when <dir> is not in a repo / git errors. Used only by Rule
# B (#662), whose whole comparison is git-dir identity — a relative answer would
# make two different trees' `.git` compare equal and silently disarm the rule.
#
# Deliberately NOT `rev-parse --path-format=absolute`, despite that flag reading
# cleaner and having precedent elsewhere in this repo (config.sh,
# golem-event-listener.py). It requires git >= 2.31, and on an older git it does
# not degrade to a relative path — it FAILS, yielding "" and thus a permanent
# silent fail-open. A guard that quietly stops guarding on an old git is the one
# outcome worth extra lines to avoid, and this hook's whole point is running
# identically on host / bare-linux / container / base macOS. So absolutize the
# way the sibling worktree-guard.sh does: `cd` into the answer and `pwd`, which
# works on every git and needs no version gate.
_abs_git_dir() {
    _agd_raw="$(git -C "$1" rev-parse "$2" 2>/dev/null || true)"
    [ -n "$_agd_raw" ] || return 0
    (cd "$1" 2>/dev/null && cd "$_agd_raw" 2>/dev/null && pwd) || true
}

# --- Read stdin -------------------------------------------------------------
payload="$("$CAT" 2>/dev/null || true)"
if [ -z "$payload" ]; then
    printf '%s: empty PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
    exit 0
fi

# --- Extract agent_id + command + cwd ---------------------------------------
# Prefer jq; fall back to a pure-bash extractor so the guard enforces without jq.
# `cwd` (the session's working directory) is read for Rule B (#662) only: it is
# both the fallback target tree for a command that names none, and the base a
# relative `git -C <path>` / `cd <path>` resolves against. Rule A ignores it, so
# an absent cwd costs Rule A nothing and merely fails Rule B open.
agent_id=""
command_str=""
cwd=""
have_fields=0
if command -v jq >/dev/null 2>&1; then
    # `have_fields` gates on whether jq successfully PARSED the payload as JSON —
    # not on the presence of any particular field. Once the bytes parse, jq's
    # extraction of agent_id/command is authoritative and MORE robust than the sed
    # fallback, so we must not discard it and re-derive via the weaker scraper just
    # because some unrelated field is absent (#448 review). `jq empty` succeeds iff
    # the input is valid JSON.
    if printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
        have_fields=1
        # `// empty` yields "" for absent/null. agentId is read as a defensive
        # alternate spelling (the verified field is snake_case agent_id).
        agent_id="$(printf '%s' "$payload" | jq -r '(.agent_id // .agentId) // empty' 2>/dev/null || true)"
        command_str="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
        cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
        # A parsed payload with no command is not a Bash call we can evaluate —
        # nothing to enforce against, so allow (no destructive command present).
        if [ -z "$command_str" ]; then
            exit 0
        fi
    fi
fi

if [ "$have_fields" -eq 0 ]; then
    # jq absent or parse failed — hand-roll extraction. These are deliberately
    # simple string scrapes over the raw JSON: they can only ADD enforcement
    # (find an agent_id / command that jq would have found), never relax it, and
    # any miss lands in the fail-open+loud branch below.
    #
    # agent_id: capture the value after "agent_id"|"agentId" : "..." — a sed
    # regex tolerating whitespace around the colon. Empty if absent.
    agent_id="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$agent_id" ]; then
        agent_id="$(printf '%s' "$payload" |
            "$SED" -n 's/.*"agentId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -n1)"
    fi
    # command: value of "command":"..." inside tool_input. A command string may
    # contain escaped quotes; the scrape takes the shortest span to the first
    # unescaped closing quote, which is conservative — a truncated command can
    # only DROP trailing deny-tokens (fail toward allow), and the primary jq path
    # handles the exact bytes whenever jq is present.
    command_str="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    # cwd for Rule B (#662). Same shortest-span caveat as the scrape above; an
    # empty or truncated result only fails Rule B OPEN (allow), never closed.
    cwd="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$command_str" ]; then
        printf '%s: could not parse PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
        exit 0
    fi
fi

# --- Caller gate is DEFERRED (#662) -----------------------------------------
# This is where the main-session gate USED to short-circuit (`[ -z "$agent_id" ]
# && exit 0`). It cannot any more: Rule B denies a main-session destructive GIT
# verb aimed at another tree's linked worktree, so the main session must reach
# the deny-set scan. The gate now lives AFTER that scan — see "Caller gate" near
# the end of this file — which also means the ordering is a deliberate
# PERFORMANCE property, not an accident: an ordinary main-session command never
# matches a deny-head, so it exits on the `[ -z "$matched" ]` path below without
# ever forking `git`. Only an already-destructive command pays for the two
# `rev-parse` calls Rule B needs.

# --- Deny-set detection -----------------------------------------------------
# Normalize in TWO steps so statement separators survive. A real newline inside
# tool_input.command is itself a statement separator, so translate newlines (and
# carriage returns) to a literal `;` FIRST, before collapsing the remaining
# control chars to spaces — otherwise a multi-line script would join two
# statements into one segment and hide a destructive second line (#448 review).
norm="$(printf '%s' "$command_str" |
    "$TR" '\n\r' ';;' |
    "$TR" '[:cntrl:]' ' ' |
    "$TR" -s ' ')"

# The ONLY sanctioned variable-target carve-out is deleting the very directory a
# `mktemp -d` was assigned to: `d=$(mktemp -d); ... "$d"`. `mktemp_var` holds that
# exact variable NAME so operand_ok can allow a reference to `$d`/`"$d"`/`${d}` and
# NOTHING else — an unrelated live variable like `$HOME/repo` must not piggyback on
# a stray mktemp (#448 review #2). Detection runs on a STATEMENT-level split (only
# `;`/`&&`/`||`/`&`/newline, NOT the finer `$(`/`|`/`(` command-level split) so the
# `VAR=$(mktemp -d)` assignment stays intact in one piece to match. mktemp_var is
# then set as each statement is walked below, so a `$d` use is excused only if its
# mktemp assignment already appeared EARLIER in statement order (#448 review #3).
# Starts empty; the `VAR=$(mktemp)-then-use` ordering is what the carve-out targets.
# Detect the name once, on a STATEMENT-level split (only `;`/`&&`/`||`/`&`/newline,
# NOT the finer `$(`/`|`/`(` command-level split used for head-matching) so a
# `VAR=$(mktemp -d)` assignment stays intact in one piece to match. Boundary-
# anchored so a longer `.*` prefix cannot shave leading chars off the name.
# ACCEPTED GAP (#448 review #3, documented out-of-scope): detection is not
# statement-ORDER-aware, so the contrived reverse form `d=src; rm -rf $d;
# d=$(mktemp -d)` (assign live, delete, THEN stage a scratch dir under the same
# name) is not caught — the natural forms `d=$(mktemp -d); rm -rf "$d"` are.
# `sed -E` (ERE), not the default BRE (#679): the `\|` alternation in `\(^\|…\)`
# is a GNU extension. Under BSD sed the substitution never fired, mktemp_var came
# back EMPTY, and the scratch-dir carve-out silently stopped recognizing its own
# subject — the guard then over-blocks a legitimate `rm -rf "$d"`. That direction
# is fail-safe, but it is still a macOS-only behaviour difference in a security
# hook. Verified to select the same names as the BRE on both sed flavors.
mktemp_var="$(printf '%s' "$norm" |
    "$TR" ';&|' '\n\n\n' |
    "$SED" -E -n 's/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=[`$]{1}[({]*mktemp[[:space:]].*/\2/p' |
    "$HEAD" -n1)"

# `_rule_b_target` echoes the target directory frozen at a git-verb match: the
# chained `-C` operand when this invocation had a usable one, else the `cd` in
# effect at this point in statement order, else "" meaning "the payload cwd".
#
# It exists so the poison rule lives in ONE place. `git_C_bad` is set when any
# `-C` operand in the invocation was unresolvable (a `$var`/backtick), and it must
# discard the WHOLE chain rather than just that operand — git re-chdirs on every
# `-C`, so an earlier literal says nothing about where the command actually lands.
# Falling back to `cd_dir`/cwd is the fail-open direction. Three call sites (one
# per git verb) route through here; inlining the rule would be the
# harden-one-knob-grep-every-sibling class waiting to happen (#662 review 3).
_rule_b_target() {
    if [ "${git_C_bad:-0}" = "1" ] || [ -z "${git_C:-}" ]; then
        printf '%s' "${cd_dir:-}"
        return 0
    fi
    printf '%s' "$git_C"
}

# is_scratch <path> -> return 0 only when the path is PREFIX-anchored under a
# recognized scratch root (/tmp, /var/tmp, $TMPDIR). A substring match would
# wrongly carve out a live path that merely contains `/tmp/` (`src/tmp/live`) or
# one that escapes via `..` (`/tmp/../etc`), so anchor to the prefix and reject
# any `..` traversal segment (#448 review).
is_scratch() {
    case "$1" in
        *".."*) return 1 ;; # a traversal can escape the sandbox
    esac
    case "$1" in
        /tmp | /var/tmp) return 0 ;;
        /tmp/* | /var/tmp/*) return 0 ;;
        '$TMPDIR'* | '${TMPDIR}'*) return 0 ;;
        '"$TMPDIR"'* | '"${TMPDIR}"'*) return 0 ;;
    esac
    return 1
}

# Redirection to a NON-scratch path is destructive regardless of the command
# head (e.g. `echo x > tracked.py`). Check EVERY `>` target, not just the last:
# a command can pair an early destructive redirect with a trailing scratch one
# (`cmd 2> tracked.py > /tmp/log`) — inspecting only the final `>` would miss the
# first (#448 review). Split on `>` and test each following token. (Defined after
# is_scratch — shell functions must exist before this scan runs.)
redir_bad=1
case "$norm" in
    *">"*)
        _rest="$norm"
        while :; do
            case "$_rest" in
                *">"*) ;;
                *) break ;;
            esac
            # Drop everything through the next `>`, then a leading `>` (from `>>`)
            # and any whitespace, so `_tgt` is the redirect's actual file token.
            _rest="${_rest#*>}"
            _rest="${_rest#>}"                         # second `>` of `>>`
            _rest="${_rest#"${_rest%%[![:space:]]*}"}" # trim leading spaces
            _tgt="${_rest%%[[:space:]]*}"              # token up to next whitespace
            _tgt="${_tgt#&}"                           # `>&2` fd-dup, not a file — strip &
            [ -n "$_tgt" ] || continue
            case "$_tgt" in
                [0-9]) continue ;; # `2>`/`>&1` fd number, not a file
            esac
            is_scratch "$_tgt" || {
                redir_bad=0
                break
            }
        done
        ;;
esac

# operand_ok <token> -> return 0 when a single destructive operand is safe: a
# scratch-confined path, or a reference to the EXACT variable that a `mktemp -d`
# was assigned to (`$d`/`"$d"`/`${d}` when `d=$(mktemp -d)` staged it). A generic
# "any $-operand" allowance is unsafe — `$HOME/repo` is not scratch — so we bind
# strictly to `mktemp_var` (#448 review #2).
operand_ok() {
    is_scratch "$1" && return 0
    if [ -n "$mktemp_var" ]; then
        case "$1" in
            '$'"$mktemp_var" | '"$'"$mktemp_var"'"' | \
                '${'"$mktemp_var"'}' | '"${'"$mktemp_var"'}"') return 0 ;;
            '$'"$mktemp_var"/* | '"$'"$mktemp_var"'"'/* | \
                '${'"$mktemp_var"'}'/* | '"${'"$mktemp_var"'}"'/*) return 0 ;;
        esac
    fi
    return 1
}

# target_ok <segment> -> return 0 (safe, skip the deny) ONLY when EVERY path-like
# operand of the destructive command is safe (operand_ok). A single live-literal
# target makes the whole segment unsafe — so `rm -rf src/live` is never excused by
# a sibling `mktemp -d`, and `rm /tmp/a live/b` (mixed) is denied. Flags (leading
# `-`) and the git subcommand token are skipped; a segment with NO path operand at
# all is NOT auto-safe (returns 1) so a bare destructive verb still denies.
target_ok() {
    local seg="$1" tok saw_path=1 skip_next=0 is_truncate=1
    # Drop the command head (and, for git, the subcommand) — operands follow.
    case "$1" in
        truncate\ * | /usr/bin/truncate\ *) is_truncate=0 ;; # lint-allow-path: deny-set match DATA, not an invocation
    esac
    seg="${seg#* }"
    case "$1" in
        git\ * | /usr/bin/git\ *) seg="${seg#* }" ;; # lint-allow-path: deny-set match DATA, not an invocation
    esac
    for tok in $seg; do
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            # The skipped token is a size/reference VALUE — but if it looks like a
            # path (contains `/`), don't blindly trust it: fall through and check
            # it as an operand so `truncate -s live/file.py x` can't hide a live
            # target in the size slot (#448 review #2).
            case "$tok" in
                */*) ;;        # path-like: check it below
                *) continue ;; # a bare size/ref value: not a path
            esac
        fi
        # Only `truncate` takes a separated value flag whose next token is a size
        # or a reference file, not the target (`truncate -s 0 f`, `-r ref f`).
        # `-r` must NOT be treated this way for rm/mv/git-clean, where it is the
        # boolean recursive switch (#448 review #1) — hence the truncate scoping.
        if [ "$is_truncate" -eq 0 ]; then
            case "$tok" in
                -s | -r | --size | --reference)
                    skip_next=1
                    continue
                    ;;
            esac
        fi
        case "$tok" in
            -*) continue ;;  # a flag, not a path operand
            *=*) continue ;; # inline assignment, not a target
        esac
        saw_path=0
        operand_ok "$tok" || return 1 # any unsafe operand -> not safe
    done
    # No path operand seen -> cannot prove scratch-confinement -> not safe.
    [ "$saw_path" -eq 0 ]
}

# Split the normalized command into segments on shell separators so a deny-head
# after any of them is caught (e.g. a delete chained after `ls &&`, `sleep 1 &`,
# or a newline — already mapped to `;` above). Order matters: collapse the
# two-char operators `&&`/`||` to a break FIRST, then the single-char `&`/`|`, so
# the two-char forms are not shredded into stray single breaks (#448 review).
# bash-3.2 clean — translate every separator to a newline, then read the lines.
segments="$(printf '%s' "$norm" |
    "$SED" 's/&&/\n/g; s/||/\n/g; s/&/\n/g; s/;/\n/g; s/|/\n/g; s/\$(/\n/g; s/`/\n/g; s/(/\n/g; s/)/\n/g')"

# Rule B (#662) target-tree tracking, threaded through the SAME ordered segment
# walk that finds the deny-head — which is what makes it statement-ORDER-correct
# for free, with none of the separate-scan machinery `mktemp_var` needed. The
# segments are already in execution order, so a `cd` recorded here necessarily
# appeared BEFORE the git verb that later reads it. `cd_dir` holds the most recent
# literal `cd` operand; `matched_dir` freezes the target at the moment a git verb
# matches (`-C <path>` when present, else whatever `cd` was in effect).
cd_dir=""
matched_dir=""
matched=""
while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # Trim leading whitespace.
    seg="${seg#"${seg%%[![:space:]]*}"}"
    # Strip leading `VAR=value ` assignments, and a leading `env`/`sudo` /
    # `command`/`builtin` wrapper, so the real head is exposed. Each arm must
    # make progress (consume a token) or break, so a segment that is ONLY an
    # assignment / wrapper with no following command (`first` has no trailing
    # space) terminates the loop instead of spinning.
    while :; do
        first="${seg%% *}"
        # No space left -> `first` IS the whole segment; nothing follows to
        # expose as a head, so stop (covers a bare `d=$(mktemp` fragment).
        case "$seg" in
            *" "*) ;;
            *) break ;;
        esac
        case "$first" in
            */*) break ;; # a path, not a bare VAR=/wrapper
            *=*)
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            env | sudo | command | builtin | nice | nohup | time | exec | xargs)
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            # Bash compound-command reserved words that can PRECEDE a command in a
            # split segment (`if …; then rm …; fi` splits to a segment headed by
            # `then`). Strip them so the real deny-head is exposed — a common
            # cleanup idiom, not an adversarial trick (#448 review 3).
            if | then | elif | else | fi | for | while | until | do | done | \
                case | 'esac' | 'in' | '{' | '}' | '!')
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            *) break ;;
        esac
    done

    # Head token and the segment tail (for two-word git heads + target scan).
    head="${seg%% *}"
    # Strip shell quoting/escaping that a real shell resolves away before running
    # the binary, so `"rm"`, `'rm'`, and `\rm` (the classic alias-bypass idiom)
    # all normalize to `rm` before the exact-token case-match (#448 review).
    head="${head#\\}" # leading backslash-escape
    head="${head#\"}"
    head="${head%\"}" # surrounding double quotes
    head="${head#\'}"
    head="${head%\'}" # surrounding single quotes
    case "$head" in
        # Rule B (#662): record a literal `cd <dir>` so a later `git reset --hard`
        # in the same command resolves against it (`cd <wt> && git reset --hard`
        # must decide identically to `git -C <wt> reset --hard` — the two forms
        # are interchangeable to the operator, so a cwd-only check would miss the
        # realistic one). Only a LITERAL operand is honored: a `$var` / `$(…)`
        # operand cannot be resolved without evaluating the shell, so it is left
        # unset and the target falls back to the payload cwd (a documented gap
        # above, and one that fails toward allow). NOT a deny-head itself — the
        # walk continues to the real command.
        cd)
            _cdop="${seg#* }"
            _cdop="${_cdop%% *}"
            case "$_cdop" in
                '' | -*) ;;                 # `cd` alone, or an option: no literal target
                *'$'* | *'`'*) cd_dir="" ;; # unresolvable: fall back to payload cwd
                *)
                    _cdop="${_cdop#\"}"
                    _cdop="${_cdop%\"}"
                    _cdop="${_cdop#\'}"
                    _cdop="${_cdop%\'}"
                    cd_dir="$_cdop"
                    ;;
            esac
            ;;
        rm | /bin/rm | /usr/bin/rm) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="rm"
            break
            ;;
        mv | /bin/mv | /usr/bin/mv) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="mv"
            break
            ;;
        truncate | /usr/bin/truncate) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="truncate"
            break
            ;;
        git | /usr/bin/git) # lint-allow-path: deny-set match DATA, not an invocation
            rest="${seg#"$head"}"
            rest="${rest# }"
            # Skip git's global options so `sub` lands on the real subcommand:
            # `git -C src clean -fd` must still read as `clean` (#448 review 4).
            # `-C`/`-c`/`--git-dir`/`--work-tree`/`--namespace` (separated forms)
            # take a following argument; the `--opt=val` attached forms are single
            # tokens. Loop until the head is no longer a global option.
            # Rule B (#662): `git_C` captures a literal `-C <path>` operand as it
            # is skipped, so the same pass that finds the subcommand also learns
            # the target tree. Reset per segment — a `-C` belongs to ITS OWN git
            # invocation and must never leak into a later one.
            git_C=""
            git_C_bad=0 # set when any `-C` operand in THIS invocation is unresolvable
            while :; do
                sub="${rest%% *}"
                case "$rest" in *" "*) ;; *) break ;; esac
                case "$sub" in
                    -C | -c | --git-dir | --work-tree | --namespace)
                        rest="${rest#* }"
                        rest="${rest# }" # drop opt
                        _optval="${rest%% *}"
                        if [ "$sub" = "-C" ]; then
                            case "$_optval" in
                                # UNRESOLVABLE operand. It is not enough to skip
                                # it: git re-chdirs on EVERY `-C`, so a later
                                # `-C "$var"` fully re-targets the tree. Leaving a
                                # `git_C` accumulated from an earlier LITERAL
                                # operand would make the hook decide about a tree
                                # the command may never touch — wrong in BOTH
                                # directions (a false allow if the real target is
                                # a peer worktree, or a wrong-tree deny naming an
                                # uninvolved one). So POISON the whole invocation
                                # and fall back to the cwd-only fail-open path
                                # (#662 review cycle 3, dynamically repro'd).
                                '' | *'$'* | *'`'*) git_C_bad=1 ;;
                                *)
                                    _optval="${_optval#\"}"
                                    _optval="${_optval%\"}"
                                    _optval="${_optval#\'}"
                                    _optval="${_optval%\'}"
                                    # Expand `~` PER OPERAND, before it is folded
                                    # into the chain: once joined, a mid-chain
                                    # tilde becomes `a/~`, which matches neither
                                    # `~` nor `~/*` at the end and so is never
                                    # expanded — it lands on the nonexistent
                                    # `<cwd>/a/~` and fail-opens. A leading tilde
                                    # only worked by string-shape luck (#662
                                    # review cycle 3, dynamically repro'd). Like
                                    # real chdir, an expanded (absolute) `~`
                                    # RESETS the chain.
                                    # shellcheck disable=SC2088  # the quoted `~` is
                                    # a literal match PATTERN for the operand as
                                    # typed; the $HOME substitution on the right is
                                    # exactly what SC2088 asks for.
                                    case "$_optval" in
                                        "~") [ -n "${HOME:-}" ] && _optval="$HOME" ;;
                                        "~/"*) [ -n "${HOME:-}" ] && _optval="$HOME/${_optval#\~/}" ;;
                                    esac
                                    # CHAIN repeated `-C`, matching real git: each
                                    # `-C` is a chdir relative to the PREVIOUS one,
                                    # so `-C a -C b` targets `<cwd>/a/b`. Keeping
                                    # only the last operand would resolve `b`
                                    # against cwd instead — a DIFFERENT directory,
                                    # which is not merely a missed deny: if some
                                    # unrelated `<cwd>/b` happens to be a linked
                                    # worktree, the guard denies naming the WRONG
                                    # tree (dynamically repro'd, #662 review cycle
                                    # 2). An absolute operand resets the chain,
                                    # exactly as chdir does.
                                    case "$_optval" in
                                        /*) git_C="$_optval" ;;
                                        *) git_C="${git_C:+$git_C/}$_optval" ;;
                                    esac
                                    ;;
                            esac
                        fi
                        rest="${rest#* }"
                        rest="${rest# }"
                        ;; # drop its value
                    --*=* | -*)
                        rest="${rest#* }"
                        rest="${rest# }"
                        ;; # attached/boolean opt
                    *) break ;;
                esac
            done
            sub="${rest%% *}"
            # Rule B (#662): freeze this invocation's target tree alongside the
            # match — `-C` when it named one, else the `cd` in effect at this
            # point in statement order, else "" meaning "the payload cwd". Set on
            # the same line as `matched` so the two can never disagree about which
            # invocation they describe.
            case "$sub" in
                clean)
                    target_ok "$seg" && continue
                    matched="git clean"
                    matched_dir="$(_rule_b_target)"
                    break
                    ;;
                reset)
                    case " $rest " in
                        *" --hard"*)
                            matched="git reset --hard"
                            matched_dir="$(_rule_b_target)"
                            break
                            ;;
                    esac
                    ;;
                checkout)
                    # `$rest` is padded with a trailing space in the case word,
                    # so a trailing `--` becomes `-- ` and `*" -- "*` matches both
                    # `git checkout -- file` and a bare `git checkout --`.
                    case " $rest " in
                        *" -- "*)
                            matched="git checkout --"
                            matched_dir="$(_rule_b_target)"
                            break
                            ;;
                    esac
                    ;;
                worktree)
                    # Rule B verb #4 (#665). `git worktree remove --force <wt>`
                    # destroys the whole worktree directory INCLUDING uncommitted
                    # work, against the identical target the other three verbs are
                    # denied for. Only the FORCED form is denied: plain `git
                    # worktree remove` refuses a dirty tree on its own, so it has
                    # nothing unrecoverable to destroy, and denying it would block
                    # a safe verb for no benefit.
                    #
                    # Target resolution differs from every other verb here and is
                    # the load-bearing part: `worktree remove` names its target
                    # POSITIONALLY, not via `-C`. Routing it through
                    # `_rule_b_target` alone would resolve to the caller's cwd —
                    # the MAIN checkout, which is a primary tree — so the rule
                    # would fail the linked-worktree test and ALLOW every time: a
                    # silent no-op that reads as a fix. So scan the operands for
                    # the positional path, and fall back to `_rule_b_target` only
                    # when there is none to find.
                    _wt_sub="${rest#* }"
                    _wt_sub="${_wt_sub%% *}"
                    [ "$_wt_sub" = "remove" ] || continue
                    # `--force`/`-f` anywhere in the operand list, including the
                    # doubled `-f -f` / `--force --force` form git demands when the
                    # tree also holds untracked files. One `-f` is enough to match;
                    # the doubled form is a superset, not a separate shape.
                    case " $rest " in
                        *" --force "* | *" -f "*) ;;
                        *) continue ;;
                    esac
                    # First non-flag token after `remove` is the worktree path.
                    # An unresolvable operand (`$var`/backtick) is left empty so
                    # the fallback runs and the command fail-opens, matching every
                    # other unresolvable-target gap in this hook.
                    _wt_path=""
                    _wt_rest="${rest#* }"     # drop `worktree`
                    _wt_rest="${_wt_rest#* }" # drop `remove`
                    for _wt_tok in $_wt_rest; do
                        case "$_wt_tok" in
                            -*) continue ;;         # a flag
                            *'$'* | *'`'*) break ;; # unresolvable: fail open
                            *)
                                _wt_tok="${_wt_tok#\"}"
                                _wt_tok="${_wt_tok%\"}"
                                _wt_tok="${_wt_tok#\'}"
                                _wt_tok="${_wt_tok%\'}"
                                _wt_path="$_wt_tok"
                                break
                                ;;
                        esac
                    done
                    matched="git worktree remove --force"
                    # COMBINE the positional path with the `-C`/`cd` context —
                    # never either one alone. git resolves a RELATIVE operand
                    # against its effective cwd, which `-C <dir>` and a preceding
                    # `cd <dir>` both move. Assigning `matched_dir="$_wt_path"`
                    # outright (the first version of this arm) made the caller
                    # gate later join the relative path onto the PAYLOAD cwd
                    # instead, computing a DIFFERENT directory than the command
                    # actually deletes — so `cd <peer-wt> && git worktree remove
                    # --force .` resolved to the main checkout, saw a primary
                    # tree, and ALLOWED the very deletion Rule B exists to stop
                    # (repro'd against a live fixture, #677 review cycle 1).
                    #
                    # Note this is NOT the documented fail-open direction: an
                    # unresolvable target declines to decide and allows, which is
                    # deliberate, whereas this computed a confidently WRONG
                    # target. Same class as #662's unexpanded-`~` bypass: a path
                    # must be fully expanded BEFORE it is scoped, and every
                    # spelling of one target must decide alike.
                    _wt_base="$(_rule_b_target)"
                    # shellcheck disable=SC2088  # the quoted `~` patterns below
                    # are literal match PATTERNS for the operand as typed, never
                    # expansions — expansion happens in the caller gate, which is
                    # the single place that owns it.
                    case "$_wt_path" in
                        # No positional operand. NOT a real git usage — `git
                        # worktree remove` requires a <worktree> argument and
                        # exits with a usage error without one (verified), so
                        # there is no "remove the tree I am standing in" form.
                        # This is a defensive fallback for a degenerate or
                        # mis-scanned invocation (e.g. the `-`-led basename gap
                        # above): fall back to the `-C`/`cd` base rather than
                        # leaving the target unset.
                        '') matched_dir="$_wt_base" ;;
                        # Absolute: self-contained, the base is irrelevant —
                        # exactly as an absolute operand resets a `-C` chain. The
                        # `~` forms are passed through UNEXPANDED on purpose: the
                        # caller gate expands them against $HOME right before the
                        # `-d` test, so expanding here too would be duplicate
                        # logic that could drift (#662 made the unexpanded-tilde
                        # bypass a live finding, so the expansion lives in exactly
                        # one place).
                        /* | '~' | '~/'*) matched_dir="$_wt_path" ;;
                        # Relative: join onto the base when there is one, else
                        # let the caller gate resolve it against the payload cwd
                        # (correct when no `-C`/`cd` moved the effective cwd).
                        *) matched_dir="${_wt_base:+$_wt_base/}$_wt_path" ;;
                    esac
                    break
                    ;;
            esac
            ;;
    esac
done <<EOF
$segments
EOF

# Redirection to a non-scratch target is its own deny reason (redir_bad=0 means
# the scan above found at least one `>` target outside a scratch root).
if [ -z "$matched" ] && [ "$redir_bad" = "0" ]; then
    matched="output redirection to a tracked path"
fi

if [ -z "$matched" ]; then
    exit 0
fi

# --- Caller gate (#662) -----------------------------------------------------
# A destructive command has matched. WHO ran it decides which rule applies:
#   subagent (agent_id set) -> Rule A: deny, tree-independent (unchanged, #448).
#   main session (no agent_id) -> Rule B: deny ONLY a git verb aimed at another
#   tree's linked worktree; everything else keeps its historical allow.
if [ -z "$agent_id" ]; then
    # Rule B applies to the three GIT verbs only. rm/mv/truncate/redirection from
    # the main session stay unconditionally allowed — that is what keeps
    # `rm -rf .worktrees/issue-N` teardown working (worktree-rm.sh owns the
    # deliberate path and has its own dirty check).
    case "$matched" in
        "git reset --hard" | "git clean" | "git checkout --" | \
            "git worktree remove --force") ;;
        *) exit 0 ;;
    esac

    # Resolve the target tree. Every failure below ALLOWS — the main session's
    # historical behavior — so Rule B can only ever add a denial (see FAILURE
    # MODE in the header).
    command -v git >/dev/null 2>&1 || exit 0

    # `matched_dir` is the `-C`/`cd` operand frozen at the match, "" meaning "no
    # explicit target, so the session's own cwd". A relative operand resolves
    # against cwd, which is exactly how the shell would resolve it.
    target_dir="${matched_dir:-$cwd}"

    # Expand a leading `~/` (and a bare `~`) to $HOME BEFORE the absolute-vs-
    # relative test. Tilde expansion is the shell's job and happens before git
    # ever sees the operand, so `git -C ~/wt reset --hard` and
    # `git -C $HOME/wt reset --hard` are the SAME command — but `~/wt` is not
    # absolute by the `/*` test below, so without this it would be glued onto cwd
    # as `<cwd>/~/wt`, a path that does not exist, and the `-d` check would then
    # fail-open. That turns a routine idiom into a SILENT BYPASS of Rule B: the
    # identical worktree denies via an absolute path and allows via `~`
    # (dynamically repro'd, #662 pre-PR review). `~user/...` is deliberately NOT
    # expanded — resolving another user's home needs passwd lookups this hook has
    # no business doing — so it falls through to the fail-open path below, which
    # is the safe direction and is recorded as an accepted gap in the header.
    # shellcheck disable=SC2088  # the quoted `~` is a literal match PATTERN (the
    # unexpanded operand as it arrived in the payload), never an expansion — the
    # expansion is the $HOME substitution on the right-hand side, which is exactly
    # what SC2088 asks for.
    case "$target_dir" in
        "~") [ -n "${HOME:-}" ] && target_dir="$HOME" ;;
        "~/"*) [ -n "${HOME:-}" ] && target_dir="$HOME/${target_dir#\~/}" ;;
    esac

    case "$target_dir" in
        /*) ;;
        *)
            [ -n "$cwd" ] || exit 0 # nothing to resolve a relative path against
            target_dir="$cwd/$target_dir"
            ;;
    esac
    [ -d "$target_dir" ] || exit 0

    # A linked worktree has git-dir != git-common-dir; a primary checkout has them
    # equal. This is the repo-standard idiom (golem/SKILL.md,
    # ship-issue/execute-protocol.md, worktree-guard.sh) — and deriving
    # worktree-ness from git itself rather than from a literal `.worktrees/` path
    # means the env-overridable GOLEM_WORKTREE_DIR is honored for free.
    tgt_git="$(_abs_git_dir "$target_dir" --git-dir)"
    tgt_common="$(_abs_git_dir "$target_dir" --git-common-dir)"
    { [ -n "$tgt_git" ] && [ -n "$tgt_common" ]; } || exit 0
    [ "$tgt_git" != "$tgt_common" ] || exit 0 # target is a primary checkout: allow

    # The target IS a linked worktree. Allow only when it is the caller's OWN tree
    # — a golem resetting its own worktree, or a bare-repo worktree host working
    # in its only tree. Comparing GIT-DIRS (not paths) is what makes this exact:
    # each linked worktree has a distinct .git/worktrees/<id> dir, so two peers
    # never compare equal, while `cd <own-wt> && git reset --hard` and a bare
    # `git reset --hard` from the same session both resolve to the same one.
    #
    # An UNRESOLVABLE caller tree fails open: cwd is required to establish "own",
    # and without it every worktree target would look foreign — turning a missing
    # payload field into a broad new denial, the one direction this change must
    # never take.
    [ -n "$cwd" ] || exit 0
    own_git="$(_abs_git_dir "$cwd" --git-dir)"
    [ -n "$own_git" ] || exit 0
    [ "$tgt_git" != "$own_git" ] || exit 0 # the caller's own worktree: allow

    reason="Blocked destructive git (\`$matched\`) from the MAIN session against the linked worktree \`${target_dir}\` (#662). That worktree belongs to another session (a golem): it is by design full of UNCOMMITTED work, so this command has no recovery path — no reflog entry, no stash, no PR. Read-only inspection (\`git -C ${target_dir} status\`/\`log\`/\`diff\`) is allowed and is what polling should use. To tear the worktree down deliberately, run \`\${CLAUDE_PLUGIN_ROOT}/scripts/worktree-rm.sh <issue-number>\`, which refuses to discard uncommitted work. To reset YOUR OWN tree, run the command without \`-C\` from your own checkout."
    _emit_deny_reason "$reason"
fi

# --- Deny (Rule A: subagent) ------------------------------------------------
reason="Blocked destructive shell (\`$matched\`) in read-only review/analysis subagent ${agent_id}: this agent must not delete or mutate the live working tree (#426/#448). If you must reproduce something, do it inside a fresh \`mktemp -d\` sandbox, never against the checkout."
_emit_deny_reason "$reason"
