#!/usr/bin/env bash
# golem-work.sh — the golem BACKGROUND-WORK REGISTRY (issue #890).
#
# THE BUG THIS EXISTS FOR. golem-transcript-liveness.sh classifies a golem from
# the last top-level assistant record's `message.stop_reason`: `tool_use` =>
# working, `end_turn` => idle. That mapping is correct for a SYNCHRONOUS turn and
# WRONG whenever work outlives the turn that started it — a `run_in_background`
# Bash task, a `Monitor`, or a `Workflow` harness. The turn genuinely ends and the
# work genuinely continues, so "turn ended" and "parked at the prompt" are
# structurally indistinguishable from stop_reason alone. #890 measured five such
# false "idle" reports in ONE orchestration session, every one a golem doing real
# work (a test suite, a git push running the pre-push hook, a review harness
# mid-fan-out).
#
# Reproduced on-disk while designing this: in a real transcript every `Workflow`
# tool_use record is immediately followed by an `end_turn` record, and the gap to
# the next top-level record — the window in which the golem reads as idle while
# working — measured 2.7 min and 8.7 min.
#
# WHAT THIS FILE IS. A small, discrete way for a golem to say "I have background
# work open", so the golem and every external observer (the orchestrator, a host
# monitor) read the SAME FACT instead of inferring it from a process tree. It is
# ONE HALF of the fix. The other half lives in golem-transcript-liveness.sh and
# needs no cooperation from anyone; see "WHY TWO SIGNALS" below, which is the
# most important thing to understand before changing either file.
#
# WHY TWO SIGNALS, AND WHY THIS ONE CANNOT STAND ALONE
# ----------------------------------------------------
# A registry is an EXPLICIT signal, so its ABSENCE is ambiguous BY CONSTRUCTION:
#
#     "no registered work AND turn ended"   (genuinely idle)
#     "registration never happened"         (golem forgot; may be working)
#
# are the same empty file. Only the first is genuinely idle. A registry-only
# design must therefore either call both idle — reintroducing the exact bug for
# every unregistered path — or call both working, which is the mirror failure the
# GOLEM_STALL_THRESHOLD bound exists to prevent.
#
# So golem-transcript-liveness.sh carries a SECOND, IMPLICIT signal that requires
# no registration at all: the tool call in the record just BEFORE the `end_turn`.
# If that call is background-capable (Workflow / Monitor / a backgrounded Bash),
# the turn may well have left work behind, and the verdict degrades to
# INDETERMINATE rather than to `idle`. The rule, stated once:
#
#   registry | last pre-end_turn tool call     | verdict
#   ---------|---------------------------------|---------------------------
#   open     | anything                        | background  (working)
#   empty    | background-capable              | unknown -> exit 2
#   empty    | ordinary (Read/Edit/...) / none | idle       (as before)
#
# DEGRADE TOWARD UNKNOWN, NEVER TOWARD IDLE. Reaching `idle` now requires
# POSITIVE evidence that the last turn ended on something that cannot have left
# work behind. Reporting a working golem as idle is the bug being fixed, so when
# the two states above cannot be told apart the signal must go indeterminate and
# let the caller's mtime heartbeat answer.
#
# WHY JSONL, NOT THE `.work.json` OBJECT #890 SKETCHED. The file is written by a
# golem and read by an orchestrator concurrently, and `complete` races `register`.
# An append-only JSONL of register/complete EVENTS is atomic per line under
# O_APPEND and needs no read-modify-write, whereas rewriting a whole JSON object
# loses one of two interleaved writes. Open items are the REDUCTION of the log
# (register minus a later matching complete) — the same last-wins scan
# golem-inbox.sh uses over its answer/consumed pairs, for the same reason.
#
# THREE BOUNDS ON A STALE REGISTRATION. A leaked entry must never become the new
# permanent-`working` bug that the `tool_use` staleness bound exists to prevent
# (#890 states this as an explicit acceptance criterion):
#
#   1. DEAD PID   — an entry whose `pid` no longer exists is dropped on read.
#   2. AGE-OUT    — an entry older than GOLEM_WORK_MAX_AGE is dropped, which
#                   covers a pid-less entry and a recycled pid.
#   3. FAIL-SOFT  — an unreadable/absent registry (or missing jq) yields NO open
#                   items, leaving the caller's existing verdict unchanged. Never
#                   a fabricated `working`.
#
# Reaping happens ON READ, so there is no cleanup daemon and a crashed golem
# self-heals on the next sweep.
#
# WHY GOLEM_WORK_MAX_AGE IS NOT GOLEM_STALL_THRESHOLD. They bound different
# things: the stall threshold asks "has this transcript stopped moving?", this
# asks "could this background item still plausibly be running?". Measured
# background work in this repo runs 2.7-8.7 min, and a `git push` running the
# lefthook pre-push suite ~8 min, so the default 3600 is deliberately generous —
# a false `working` for an hour is bounded and self-healing, while a too-tight
# age-out silently restores the false `idle` this file exists to remove.
#
# MODE 3 (container golems). Unlike the transcript — which lives inside the
# container and is invisible to the host — this registry lives in the MAIN
# checkout's shared status dir, so a container golem can register and the host
# CAN read it. That makes it the first liveness signal Mode 3 has ever had; see
# golem-transcript-liveness.sh's registry-only path.
#
# Subcommands:
#   register <kind> <description> [--pid N] [--max-age S] [--golem G]
#       Open an item. <kind> is bash|monitor|workflow. Prints `id=work-<epoch>-<rand>`
#       on stdout (key=value, so a caller READS it rather than eval-ing it —
#       worktree-safe by construction, see next-issue/worktree-safe-recipes.md).
#       --pid is optional but strongly recommended: it is what makes bound (1)
#       work, so a crashed background job is reaped in seconds rather than after
#       GOLEM_WORK_MAX_AGE.
#   complete <id> [--golem G]
#       Close the item with that id. Idempotent — completing an unknown or
#       already-closed id is a no-op that exits 0, so a skill may call it
#       unconditionally in a cleanup path.
#   list [--golem G] [--status-dir D] [--worktree W]
#       Print the OPEN items (after reaping), one per line, as
#       `<id>\t<kind>\t<started>\t<pid>\t<description>`. Exit 0 with no output
#       when none are open.
#   count [--golem G] [--status-dir D] [--worktree W]
#       Print the number of open items (after reaping). Always exits 0 and always
#       prints an integer — `0` when the registry is absent/unreadable, which is
#       the fail-soft contract consumers depend on.
#
# <G> defaults to the golem id derived from the current worktree, exactly as
# hooks/golem-notify.sh derives it (GOLEM_ID, else `issue-N` basename, else
# AGENT_ID); a caller in the main checkout passes --golem explicitly.
#
# WRITER VS OBSERVER (issue #949) — the distinction the read path turns on.
# `register`/`complete` are called BY a golem about ITSELF, so resolving the
# registry from the ambient cwd and $GOLEM_ID is correct. `list`/`count` are
# also called by an OBSERVER — the gate-watch liveness sweep, running in the main
# checkout, asking about a golem — and there the ambient environment describes
# the ASKER, not the subject. An observer that resolves ambiently reads a
# different (empty) registry, which the fail-soft contract renders as "0 open",
# which renders as `idle`: the exact false verdict this whole feature exists to
# remove. So an observer passes `--worktree <subject>`, and BOTH the golem id and
# the status dir are derived from that one argument together
# (work_observe_target) rather than from two independent guesses that can
# silently disagree.
#
# Runtime policy: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,} /
# ;;&), coreutils via the `command` builtin and the `_bin` resolver (never a
# hardcoded /usr/bin path — #443), `set -uo pipefail` with errors handled
# per-call. The write path mirrors golem-inbox.sh: prefer `jq -cn` for correct
# escaping, fall back to a sanitizing hand-rolled printf when jq is absent, so
# every line stays valid JSON either way.
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# Same resolver as the sibling scripts: honor PATH first (the `command -v`
# builtin needs no external binary), then scan the standard bin dirs so this
# still resolves under the stripped PATH the tests use, then yield the bare name.
# Candidates are bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint
# does not flag them. Defined before SCRIPT_DIR so even that resolution is portable.
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
BASENAME="$(_bin basename)"
CAT="$(_bin cat)"
DATE="$(_bin date)"
DIRNAME="$(_bin dirname)"
GIT="$(_bin git)"
MKDIR="$(_bin mkdir)"
PS="$(_bin ps)"
TR="$(_bin tr)"

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

usage() {
    "$CAT" >&2 <<'EOF'
usage: golem-work.sh <subcommand> [args]

  register <kind> <description> [--pid N] [--max-age S] [--golem G]
      Open a background-work item (kind: bash|monitor|workflow).
      Prints `id=work-<epoch>-<rand>`.
  complete <id> [--golem G]
      Close the item with that id (idempotent).
  list [--golem G] [--status-dir D] [--worktree W]
      Print open items: <id>\t<kind>\t<started>\t<pid>\t<description>
  count [--golem G] [--status-dir D] [--worktree W]
      Print the number of open items (always an integer, always exit 0).

  Observer flags (for reading ANOTHER golem's registry from an unrelated cwd,
  as the gate-watch liveness sweep does):
    --worktree W    derive BOTH the golem id and the status dir from W, the
                    subject's worktree path — the safe default for an observer,
                    since ambient cwd/$GOLEM_ID describe the OBSERVER instead.
    --status-dir D  state the status dir outright. Wins over --worktree.
EOF
    return 0
}

# --- identity + paths -------------------------------------------------------

# A golem id must be a golem-<...> token — the same shape golem-notify.sh stamps
# on the feed. Reject anything else (and, critically, path metacharacters) so the
# id cannot traverse out of the status dir when it becomes a filename segment.
# Same validator, same reason, as golem-inbox.sh's inbox_valid_golem.
work_valid_golem() {
    case "$1" in
        golem-*)
            case "$1" in
                *[!A-Za-z0-9_.-]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# Derive this session's golem id the SAME way hooks/golem-notify.sh does, so an
# item registered by a golem is filed under the id the feed and the status cache
# already use for it. Rungs: GOLEM_ID (set by golem-launch.sh's tmux -e), else the
# worktree basename `issue-N` -> `golem-N`, else AGENT_ID, else empty (the caller
# must pass --golem). Unlike the notify hook this does NOT fall back to the
# `golem-?` orphan sentinel: that sentinel exists so a feed line is never dropped,
# whereas an un-attributable registration should FAIL rather than accumulate under
# a shared id that no liveness read would ever match.
work_default_golem() {
    local base
    case "${GOLEM_ID:-}" in
        golem-*)
            command echo "$GOLEM_ID"
            return 0
            ;;
    esac
    base="$("$BASENAME" "$("$GIT" rev-parse --show-toplevel 2>/dev/null || command pwd)")"
    case "$base" in
        issue-*)
            command echo "golem-${base#issue-}"
            return 0
            ;;
        golem-*)
            command echo "$base"
            return 0
            ;;
    esac
    case "${AGENT_ID:-}" in
        ?*)
            command echo "$AGENT_ID"
            return 0
            ;;
    esac
    return 1
}

# work_join_status_dir <root> — join GOLEM_STATUS_DIR onto a main-checkout root.
#
# THE ONE PLACE THE TWO KNOBS MEET, and therefore the one place worth reading
# carefully (issue #949). GOLEM_STATUS_DIR is documented as repo-root-relative
# and defaults to <GOLEM_WORKTREE_DIR>/.status — but an operator may set it to
# ANY relative path, or to an absolute one, and GOLEM_WORKTREE_DIR may be
# MULTI-SEGMENT (`nested/worktrees`): config.sh promises no single-segment
# restriction, so nothing may assume one.
#
# Two withdrawn attempts at this got it wrong in ways that each produced a
# working golem reported `idle` — the exact symptom #890 exists to remove:
#
#   1. A hardcoded `<worktree>/../.status` sibling, which silently ignores
#      GOLEM_STATUS_DIR entirely. Measured: a custom status dir with an open
#      item classified `idle`.
#   2. Resolving a relative GOLEM_STATUS_DIR against the worktree's
#      GRANDPARENT, which is the root only when GOLEM_WORKTREE_DIR is exactly
#      one segment. Measured with GOLEM_WORKTREE_DIR=nested/worktrees: the root
#      came out one level too deep, the registry read empty, verdict `idle`.
#
# Hence: never count path segments, never assume the default layout. Take the
# root from git (the caller's job) and join. An ABSOLUTE GOLEM_STATUS_DIR passes
# through untouched — joining a root onto it would produce a path that exists
# nowhere, which reads as an empty registry, which reads as idle.
work_join_status_dir() {
    case "$GOLEM_STATUS_DIR" in
        /*) command echo "$GOLEM_STATUS_DIR" ;;
        *) command echo "$1/$GOLEM_STATUS_DIR" ;;
    esac
}

# Resolve the MAIN checkout's status dir. The registry lives there even when a
# subcommand runs from inside a worktree — exactly like the feed and the inbox —
# which is precisely what lets a host-side reader see a container golem's items.
#
# This is the WRITER's resolution (a golem registering its own work), so
# repo_root — which reads the ambient cwd — is the correct source. An OBSERVER
# reading somebody else's registry must NOT come through here; see
# work_status_dir_for_worktree below and the --status-dir override.
work_resolve_status_dir() {
    local root
    root="$(repo_root 2>/dev/null || true)"
    [ -z "$root" ] && return 1
    work_join_status_dir "$root"
}

# work_status_dir_for_worktree <worktree> — the status dir of the golem that owns
# <worktree>, derived from the WORKTREE ARGUMENT rather than from the caller's
# cwd (issue #949).
#
# This is the OBSERVER's resolution. golem-transcript-liveness.sh is run BY the
# gate-watch sweep ABOUT a golem, from whatever directory the sweep happens to
# have, so `repo_root` there would describe the OBSERVER and resolve a different
# (usually empty) registry — which reads as "nothing open", which restores the
# false idle. A helper run by one actor about another must derive its paths from
# the SUBJECT.
#
# `--git-common-dir` is the repo-standard main-checkout idiom already used by
# config.sh's repo_root, the golem nesting guard, and
# ship-issue/execute-protocol.md: from a LINKED worktree it points at the main
# checkout's `.git`, whose dirname is the main root — correct at any
# GOLEM_WORKTREE_DIR depth, which is exactly what defect (2) above got wrong by
# counting segments instead. Prints nothing and returns 1 when the path is not
# in a repo, so the caller can fail soft rather than fabricate a verdict.
work_status_dir_for_worktree() {
    local wt="$1" gitdir root
    [ -n "$wt" ] || return 1
    gitdir="$("$GIT" -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$gitdir" ] || return 1
    root="$("$DIRNAME" "$gitdir")"
    [ -n "$root" ] || return 1
    work_join_status_dir "$root"
}

# Print the registry path for a golem, or return 1 if not inside a repo.
#
# $2, when non-empty, is an EXPLICIT status dir that overrides repo_root
# resolution. This exists because the registry has two very different callers:
# a GOLEM registering its own work (cwd is its worktree, so repo_root is right),
# and an OBSERVER asking about someone else's golem — golem-transcript-liveness.sh,
# invoked by the gate-watch sweep from whatever cwd the sweep happens to have.
# Without the override the observer silently resolved a DIFFERENT status dir and
# read an empty registry, which reads as "nothing open" and restores the false
# idle. Measured: the gate-watch wiring test failed exactly this way.
work_path_for() {
    local golem="$1" explicit="${2:-}" status_dir
    if [ -n "$explicit" ]; then
        status_dir="$explicit"
    else
        status_dir="$(work_resolve_status_dir)" || return 1
    fi
    command echo "$status_dir/$golem.work.jsonl"
}

# --- open-item reduction (the shared read path) -----------------------------
#
# Emits the OPEN items as `<id>\t<kind>\t<started>\t<pid>\t<description>`, after
# applying all three bounds. "Open" = a `register` line with no later `complete`
# line for the same id, whose pid is still alive (when it carries one) and whose
# age is under its max-age.
#
# The per-entry `max_age` recorded at registration wins over the ambient default,
# so a caller that knows its job is long (`--max-age`) is not reaped early, while
# everything else uses GOLEM_WORK_MAX_AGE.
#
# FAIL-SOFT: a missing file, an unreadable one, or absent jq all yield NO output
# and exit 0 — consumers treat "no open items" as "no signal", never as a
# fabricated verdict. The nojq path is a full peer, not a degraded stub, because
# the registry's whole value is being readable by an observer that may be running
# under a stripped environment.
work_open_items() {
    local registry="$1" now max_default
    [ -f "$registry" ] || return 0
    now="$("$DATE" -u +%s 2>/dev/null || command echo 0)"
    max_default="${GOLEM_WORK_MAX_AGE:-3600}"

    if command -v jq >/dev/null 2>&1; then
        work_open_items_jq "$registry" "$now" "$max_default"
    else
        work_open_items_nojq "$registry" "$now" "$max_default"
    fi
}

# jq reduction. Read each line RAW with `fromjson?` + `select(type=="object")` so
# ONE torn append (the file is append-only and grown by interruptible writers) is
# SKIPPED rather than aborting the whole read — the same resilience, and the same
# two-part guard, golem-inbox.sh documents: `fromjson?` swallows an unparsable
# line, but a line parsing to a valid NON-object scalar would still abort the
# pipeline when `.id` indexes it, which `fromjson?` does not catch.
#
# Reduction is into an ORDERED id list plus a map, rather than `group_by`, to keep
# registration order stable in the output (a caller rendering "N item(s)" does not
# care, but a human reading `list` while debugging very much does).
work_open_items_jq() {
    local registry="$1" now="$2" max_default="$3"
    jq -rc -Rn --argjson now "$now" --argjson maxd "$max_default" '
        reduce ( inputs | (fromjson? // empty) | select(type == "object") ) as $r
          ({order: [], items: {}};
            if ($r.event == "register" and ($r.id | type) == "string") then
              { order: (if (.items | has($r.id)) then .order else .order + [$r.id] end),
                items: (.items + {($r.id): $r}) }
            elif ($r.event == "complete" and ($r.id | type) == "string") then
              { order: [ .order[] | select(. != $r.id) ],
                items: (.items | del(.[$r.id])) }
            else . end)
        | [ .order[] as $id | .items[$id] ]
        | .[]
        | select(
            (($now - (.started_epoch // 0)) < ((.max_age // $maxd)))
          )
        | [ (.id // ""), (.kind // "-"), (.started // "-"),
            ((.pid // "-") | tostring), (.description // "") ]
        | @tsv
    ' "$registry" 2>/dev/null || true
}

# No-jq fallback. The register line has a stable, self-written shape, so pure-bash
# parameter expansion extracts the fields. Two ordered lists (ids + records) stand
# in for the associative array bash 3.2 does not have; a `complete` blanks the
# matching slot. O(n^2) over the log, which is fine: a registry holds a handful of
# items and is truncated whenever it empties (see work_compact).
work_open_items_nojq() {
    local registry="$1" now="$2" max_default="$3"
    local line ev id rest ids="" recs=""
    local IFS_SAVE="$IFS"
    while IFS= read -r line; do
        case "$line" in
            *'"event":"register"'*) ev="register" ;;
            *'"event":"complete"'*) ev="complete" ;;
            *) continue ;;
        esac
        rest="${line#*\"id\":\"}"
        id="${rest%%\"*}"
        [ -n "$id" ] || continue
        # Drop any existing slot for this id (a re-register or a complete).
        local newids="" newrecs="" i=0 keep_id keep_rec
        local oldids="$ids" oldrecs="$recs"
        IFS='
'
        set -- $oldrecs
        for keep_id in $oldids; do
            i=$((i + 1))
            eval "keep_rec=\${$i}"
            if [ "$keep_id" != "$id" ]; then
                newids="$newids$keep_id "
                newrecs="$newrecs$keep_rec
"
            fi
        done
        IFS="$IFS_SAVE"
        ids="$newids"
        recs="$newrecs"
        if [ "$ev" = "register" ]; then
            ids="$ids$id "
            recs="$recs$line
"
        fi
    done <"$registry"
    IFS="$IFS_SAVE"

    # Emit the survivors, applying the age bound. Field extraction mirrors the jq
    # arm's key set; a missing key yields an empty field, never a parse abort.
    local i=0 rec
    local oldrecs="$recs"
    IFS='
'
    set -- $oldrecs
    IFS="$IFS_SAVE"
    for id in $ids; do
        i=$((i + 1))
        eval "rec=\${$i:-}"
        [ -n "$rec" ] || continue
        local kind started pid desc started_epoch max_age
        kind="$(work_json_field "$rec" kind)"
        started="$(work_json_field "$rec" started)"
        desc="$(work_json_field "$rec" description)"
        pid="$(work_json_num "$rec" pid)"
        started_epoch="$(work_json_num "$rec" started_epoch)"
        max_age="$(work_json_num "$rec" max_age)"
        [ -n "$started_epoch" ] || started_epoch=0
        [ -n "$max_age" ] || max_age="$max_default"
        [ $((now - started_epoch)) -lt "$max_age" ] || continue
        # `-` sentinel for an absent field, never an empty one: TAB is an IFS
        # WHITESPACE character, so `read` collapses consecutive tabs and an empty
        # column would silently shift every later field left (measured: an empty
        # pid put the description into $pid). See work_reap_dead_pids.
        [ -n "$kind" ] || kind="-"
        [ -n "$started" ] || started="-"
        [ -n "$pid" ] || pid="-"
        command printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$started" "$pid" "$desc"
    done
}

# Extract a STRING field from one self-written JSON line. The writer escapes `"`
# as `\"` and drops backslashes, so `\"` is the only escape that can appear —
# split on the closing quote that is not preceded by a backslash by un-escaping
# after the cut, exactly as golem-inbox.sh's no-jq reader does.
work_json_field() {
    local line="$1" key="$2" rest
    case "$line" in
        *"\"$key\":\""*) ;;
        *)
            command echo ""
            return 0
            ;;
    esac
    rest="${line#*\"$key\":\"}"
    # The value ends at the first `","` (next key) or `"}` (last field). `%%`
    # removes the LONGEST suffix, i.e. cuts at the EARLIEST such delimiter — the
    # right end, since the writer escapes an embedded quote as `\"` and so can
    # never produce a bare `","` inside a value.
    rest="${rest%%\",\"*}"
    rest="${rest%\"\}}"
    command printf '%s' "${rest//\\\"/\"}"
}

# Extract a NUMERIC field (unquoted in the JSON) from one self-written line.
work_json_num() {
    local line="$1" key="$2" rest
    case "$line" in
        *"\"$key\":"*) ;;
        *)
            command echo ""
            return 0
            ;;
    esac
    rest="${line#*\"$key\":}"
    rest="${rest%%,*}"
    rest="${rest%\}}"
    # Reject a quoted value (wrong type for this key) and anything non-numeric.
    case "$rest" in
        '' | *[!0-9]*)
            command echo ""
            return 0
            ;;
    esac
    command printf '%s' "$rest"
}

# Drop entries whose pid is gone (bound 1). Reads TSV rows on stdin, writes the
# survivors. An entry with no pid (`-`) passes through — the age bound covers it.
#
# The `-` sentinel for an absent pid is load-bearing, not cosmetic: TAB is an IFS
# WHITESPACE character, so `read` COLLAPSES a run of them. An empty pid column
# would shift every later field left — measured, the description landed in $pid —
# and a description that happened to be numeric would then be probed as a pid.
#
# `kill -0` is a bash BUILTIN (no external binary, so it works under the stripped
# PATH) and tests for the existence of a signalable process. A pid the caller does
# not own returns EPERM, which still proves the process EXISTS, so treat only
# ESRCH ("no such process") as dead. Distinguishing them without `kill -l` parsing
# is not worth it here: both outcomes are non-zero, so this deliberately errs
# toward KEEPING the entry (the age bound reaps it later) rather than reaping a
# live job whose pid we merely cannot signal — degrade toward working, not idle.
work_reap_dead_pids() {
    local id kind started pid desc
    while IFS="$(command printf '\t')" read -r id kind started pid desc; do
        [ -n "$id" ] || continue
        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            if ! kill -0 "$pid" 2>/dev/null; then
                # Non-zero can be ESRCH (dead) or EPERM (alive, not ours). Only a
                # pid that is absent from the process table is reaped; `kill -0`
                # cannot tell us which, so confirm with a /proc probe where one
                # exists and keep the entry otherwise.
                if [ -d /proc ] && [ ! -e "/proc/$pid" ]; then
                    continue
                fi
                if [ ! -d /proc ]; then
                    # No procfs (macOS): `ps -p` is the portable existence test.
                    # If ps itself is unavailable (stripped PATH), KEEP the entry —
                    # the age bound still reaps it, and degrading toward `working`
                    # is the safe direction.
                    if [ -x "$PS" ] || command -v "$PS" >/dev/null 2>&1; then
                        if ! "$PS" -p "$pid" >/dev/null 2>&1; then
                            continue
                        fi
                    fi
                fi
            fi
        fi
        command printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$started" "$pid" "$desc"
    done
}

# The full read: reduce the log, then reap dead pids. One place, so `list` and
# `count` can never disagree about what "open" means.
work_open_reaped() {
    work_open_items "$1" | work_reap_dead_pids
}

# --- register ---------------------------------------------------------------

# work_valid_positive_int <value> — accept only a CANONICAL positive decimal
# integer: one or more digits, no leading zero, not zero itself (issue #949).
#
# WHY THE THREE CLAUSES ARE ONE CHECK, and why this is stricter than "is it
# digits". Both numeric flags this guards (`--pid`, `--max-age`) were withdrawn
# carrying the same defect, and it is worth stating exactly what it was, because
# the fix reads as gratuitous strictness until you see it:
#
#   * A LEADING ZERO is not merely ugly. The no-jq writer interpolates the value
#     into JSON directly, and JSON FORBIDS leading zeros — `{"pid":007}` is
#     invalid. `jq` happens to accept it (measured: it reads back as 7), so the
#     jq-path tests passed while a spec-compliant parser rejected the whole
#     line. Canonicalizing here means the writer cannot emit it at all, which is
#     a stronger guarantee than escaping it downstream.
#
#   * ZERO ITSELF is the sharp one, and it is why a plain digit test is not
#     enough. `kill -0 0` does not probe a process — it signals the caller's
#     entire PROCESS GROUP, and returns success. So a registration carrying pid
#     0 is forever alive: the dead-pid bound can never reap it, and the entry sits
#     `working` until the hour-long age-out. The withdrawn code did guard this,
#     with a literal `case "$pid" in 0)` — but that is a STRING compare, so
#     `00` and `000` sailed past it and `kill -0 00` is the same syscall.
#     Measured end-to-end; the guard reintroduced the bug it was written to
#     close.
#
# So the rule is: compare numbers as numbers, and admit exactly one spelling of
# each. `[!0-9]` rejects non-digits (including a sign and the empty string);
# `0*` with a further character rejects every padded form; the bare `0` arm
# rejects zero in its only remaining spelling.
work_valid_positive_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;; # non-digits, sign, or empty
        0) return 1 ;;             # zero: `kill -0 0` signals the process group
        0*) return 1 ;;            # padded: 00, 007 — invalid JSON, bypasses a string guard
        *) return 0 ;;
    esac
}

work_valid_kind() {
    case "$1" in
        bash | monitor | workflow) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_register() {
    local kind="" desc="" pid="" max_age="" golem="" seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pid)
                shift
                pid="${1:-}"
                ;;
            --max-age)
                shift
                max_age="${1:-}"
                ;;
            --golem)
                shift
                golem="${1:-}"
                ;;
            *)
                case "$seen" in
                    0) kind="$1" ;;
                    1) desc="$1" ;;
                    *)
                        command echo "golem-work register: too many arguments" >&2
                        return 2
                        ;;
                esac
                seen=$((seen + 1))
                ;;
        esac
        shift
    done

    if [ "$seen" -lt 2 ]; then
        command echo "golem-work register: need <kind> <description>" >&2
        return 2
    fi
    if ! work_valid_kind "$kind"; then
        command echo "golem-work register: invalid kind '$kind' (want bash|monitor|workflow)" >&2
        return 2
    fi
    # Both flags are optional; when present each must be a CANONICAL positive
    # integer — see work_valid_positive_int for why "digits only" is not enough
    # (pid 0 signals the process group and is unreapable; a padded value is
    # invalid JSON that only `jq` forgives). The message names the value it
    # rejected so an operator sees WHICH spelling was refused, not just that
    # something was.
    if [ -n "$pid" ] && ! work_valid_positive_int "$pid"; then
        command echo "golem-work register: --pid must be a positive integer with no leading zero, got '$pid'" >&2
        return 2
    fi
    if [ -n "$max_age" ] && ! work_valid_positive_int "$max_age"; then
        command echo "golem-work register: --max-age must be positive integer seconds with no leading zero, got '$max_age'" >&2
        return 2
    fi

    if [ -z "$golem" ]; then
        golem="$(work_default_golem)" || {
            command echo "golem-work register: cannot derive a golem id — pass --golem golem-N" >&2
            return 2
        }
    fi
    if ! work_valid_golem "$golem"; then
        command echo "golem-work register: invalid golem id '$golem'" >&2
        return 2
    fi

    local registry status_dir ts epoch rand id
    registry="$(work_path_for "$golem")" || {
        command echo "golem-work register: not inside a git repository" >&2
        return 1
    }
    status_dir="$("$DIRNAME" "$registry")"
    "$MKDIR" -p "$status_dir" 2>/dev/null || {
        command echo "golem-work register: cannot create $status_dir" >&2
        return 1
    }

    epoch="$("$DATE" -u +%s 2>/dev/null || command echo 0)"
    ts="$("$DATE" -u +%FT%TZ 2>/dev/null || command echo "")"
    rand="$(command printf '%04x' $((RANDOM & 0xffff)))"
    id="work-${epoch}-${rand}"

    # `max_age` is written per-entry so the read path needs no ambient knowledge
    # of what the writer intended; absent, the reader applies GOLEM_WORK_MAX_AGE.
    # `started_epoch` is written ALONGSIDE the ISO `started` deliberately: the
    # reader must do arithmetic on it, and re-parsing an ISO string portably
    # (GNU `date -d` vs BSD `date -j -f`) is exactly the kind of silent
    # cross-platform divergence this repo's runtime policy exists to avoid.
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg id "$id" --arg kind "$kind" --arg desc "$desc" \
            --arg ts "$ts" --arg golem "$golem" \
            --argjson epoch "$epoch" \
            --arg pid "$pid" --arg max_age "$max_age" \
            '{event: "register", id: $id, golem: $golem, kind: $kind,
              description: $desc, started: $ts, started_epoch: $epoch}
             + (if $pid == "" then {} else {pid: ($pid | tonumber)} end)
             + (if $max_age == "" then {} else {max_age: ($max_age | tonumber)} end)' \
            >>"$registry" 2>/dev/null || {
            command echo "golem-work register: write failed" >&2
            return 1
        }
    else
        # No jq: hand-roll the JSON. The description is caller-supplied, so
        # sanitize before interpolating — drop control chars and backslashes
        # (which cannot be escaped correctly without a real encoder and would let
        # a crafted value break out of the string literal), then escape any
        # remaining double quotes. Mirrors golem-inbox.sh / golem-notify.sh's
        # no-jq escaper so every line stays valid JSON on this path too.
        local desc_safe extra=""
        desc_safe="$(command printf '%s' "${desc//\\/}" | "$TR" -d '[:cntrl:]')"
        [ -n "$pid" ] && extra="$extra,\"pid\":$pid"
        [ -n "$max_age" ] && extra="$extra,\"max_age\":$max_age"
        command printf '{"event":"register","id":"%s","golem":"%s","kind":"%s","description":"%s","started":"%s","started_epoch":%s%s}\n' \
            "$id" "$golem" "$kind" "${desc_safe//\"/\\\"}" "$ts" "$epoch" "$extra" \
            >>"$registry" 2>/dev/null || {
            command echo "golem-work register: write failed" >&2
            return 1
        }
    fi

    # key=value on stdout, so a caller READS the id rather than eval-ing a command
    # substitution — the worktree-safe pattern (#815); see
    # next-issue/worktree-safe-recipes.md § Pattern 1.
    command echo "id=$id"
    return 0
}

# --- complete ---------------------------------------------------------------

# Idempotent by design: a skill's cleanup path may call this unconditionally, and
# completing an unknown/already-closed id must not fail the golem's turn. The
# `complete` line is appended regardless; the reduction treats a complete with no
# matching register as a no-op.
cmd_complete() {
    local id="" golem="" seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --golem)
                shift
                golem="${1:-}"
                ;;
            *)
                case "$seen" in
                    0) id="$1" ;;
                    *)
                        command echo "golem-work complete: too many arguments" >&2
                        return 2
                        ;;
                esac
                seen=$((seen + 1))
                ;;
        esac
        shift
    done

    if [ "$seen" -lt 1 ]; then
        command echo "golem-work complete: need <id>" >&2
        return 2
    fi
    case "$id" in
        work-*)
            case "$id" in
                *[!A-Za-z0-9_.-]*)
                    command echo "golem-work complete: invalid id '$id'" >&2
                    return 2
                    ;;
            esac
            ;;
        *)
            command echo "golem-work complete: invalid id '$id' (want work-<epoch>-<rand>)" >&2
            return 2
            ;;
    esac

    if [ -z "$golem" ]; then
        golem="$(work_default_golem)" || {
            command echo "golem-work complete: cannot derive a golem id — pass --golem golem-N" >&2
            return 2
        }
    fi
    if ! work_valid_golem "$golem"; then
        command echo "golem-work complete: invalid golem id '$golem'" >&2
        return 2
    fi

    local registry status_dir ts
    registry="$(work_path_for "$golem")" || {
        command echo "golem-work complete: not inside a git repository" >&2
        return 1
    }
    status_dir="$("$DIRNAME" "$registry")"
    "$MKDIR" -p "$status_dir" 2>/dev/null || return 1
    ts="$("$DATE" -u +%FT%TZ 2>/dev/null || command echo "")"

    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg id "$id" --arg golem "$golem" --arg ts "$ts" \
            '{event: "complete", id: $id, golem: $golem, ts: $ts}' \
            >>"$registry" 2>/dev/null || return 1
    else
        command printf '{"event":"complete","id":"%s","golem":"%s","ts":"%s"}\n' \
            "$id" "$golem" "$ts" >>"$registry" 2>/dev/null || return 1
    fi

    work_compact "$registry" "$golem"
    return 0
}

# Truncate the log once nothing is open. Without this the file grows forever in a
# long orchestration run, and every read re-reduces the whole history. Safe
# because an empty reduction means there is no state left to preserve: the file's
# only purpose is the set of OPEN items.
#
# Racy by nature (a `register` may land between the check and the truncate), so it
# is deliberately best-effort and non-fatal — and it truncates rather than
# deletes, so a concurrent appender's O_APPEND write is never lost to a recreated
# inode.
work_compact() {
    local registry="$1" open
    open="$(work_open_reaped "$registry")"
    [ -n "$open" ] && return 0
    : >"$registry" 2>/dev/null || true
    return 0
}

# --- list / count -----------------------------------------------------------

work_resolve_golem_arg() {
    local golem="$1"
    if [ -z "$golem" ]; then
        golem="$(work_default_golem)" || return 1
    fi
    work_valid_golem "$golem" || return 1
    command echo "$golem"
}

# work_golem_for_worktree <worktree> — the golem id owning <worktree>, from its
# BASENAME (`issue-N` -> `golem-N`, `golem-N` -> itself). The same mapping
# golem-notify.sh uses. Returns 1 for anything else: a path that is not a golem
# worktree has no registry to consult, and inventing an id for it would file
# reads under a name no writer ever used.
#
# Deliberately does NOT consult $GOLEM_ID / $AGENT_ID, unlike work_default_golem:
# those describe the process ASKING, and this function answers "who owns that
# directory?". An observer that fell back to its own ambient identity would read
# its own registry while believing it read the subject's.
work_golem_for_worktree() {
    local base
    base="$("$BASENAME" "$1")"
    case "$base" in
        issue-*) command echo "golem-${base#issue-}" ;;
        golem-*) command echo "$base" ;;
        *) return 1 ;;
    esac
}

# work_observe_target <worktree> — resolve BOTH halves of an observer's read in
# one call, into WORK_OBS_GOLEM and WORK_OBS_STATUS_DIR. Returns 1 (leaving both
# empty) when <worktree> is not a golem worktree inside a git repository.
#
# The two must be derived from the SAME subject or they disagree, and the way
# they disagree is silent: a correct id against the observer's OWN status dir
# reads an absent file, which the fail-soft contract renders as "0 open", which
# renders as `idle` — the very verdict this feature exists to stop fabricating.
# Resolving the pair together is what makes that mismatch unrepresentable at the
# call site (issue #949).
#
# Results come back in globals rather than on stdout because the only alternative
# — printing two lines and splitting them — needs `head`/`tail`, and this path is
# reached by the gate-watch sweep under a PATH stripped to a few stubs. A missing
# binary there would make the read die 127, the caller would see no number, and
# "no number" degrades to "nothing open": the false idle, restored through the
# back door. Same reasoning as cmd_count's pure-bash line counter below.
WORK_OBS_GOLEM=""
WORK_OBS_STATUS_DIR=""
work_observe_target() {
    local wt="$1" golem sd
    WORK_OBS_GOLEM=""
    WORK_OBS_STATUS_DIR=""
    golem="$(work_golem_for_worktree "$wt")" || return 1
    sd="$(work_status_dir_for_worktree "$wt")" || return 1
    WORK_OBS_GOLEM="$golem"
    WORK_OBS_STATUS_DIR="$sd"
    return 0
}

cmd_list() {
    local golem="" status_dir="" worktree=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --golem)
                shift
                golem="${1:-}"
                ;;
            --status-dir)
                shift
                status_dir="${1:-}"
                ;;
            --worktree)
                shift
                worktree="${1:-}"
                ;;
            *)
                command echo "golem-work list: unexpected argument '$1'" >&2
                return 2
                ;;
        esac
        shift
    done
    # An explicit --golem / --status-dir still wins: --worktree only FILLS what
    # the caller did not state, so the observer flag composes with the manual
    # overrides rather than overriding them.
    if [ -n "$worktree" ]; then
        work_observe_target "$worktree" || {
            command echo "golem-work list: '$worktree' is not a golem worktree in a git repository" >&2
            return 2
        }
        [ -n "$golem" ] || golem="$WORK_OBS_GOLEM"
        [ -n "$status_dir" ] || status_dir="$WORK_OBS_STATUS_DIR"
    fi
    golem="$(work_resolve_golem_arg "$golem")" || {
        command echo "golem-work list: cannot derive a valid golem id — pass --golem golem-N" >&2
        return 2
    }
    local registry
    registry="$(work_path_for "$golem" "$status_dir")" || return 1
    work_open_reaped "$registry"
    return 0
}

# ALWAYS prints an integer and ALWAYS exits 0 — including when the registry is
# absent, unreadable, or the golem id cannot be derived. This is the fail-soft
# contract golem-transcript-liveness.sh depends on: a consumer must be able to
# read a number without branching on an error, because an errored count that got
# treated as "0 open" would silently restore the false-idle verdict.
cmd_count() {
    local golem="" status_dir="" worktree="" n
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --golem)
                shift
                golem="${1:-}"
                ;;
            --status-dir)
                shift
                status_dir="${1:-}"
                ;;
            --worktree)
                shift
                worktree="${1:-}"
                ;;
            *) ;;
        esac
        shift
    done
    # Observer mode (issue #949). Unlike `list`, a failure here is NOT an error:
    # count's contract is that it always prints an integer and always exits 0, so
    # an unresolvable worktree falls through to the ambient resolution below and,
    # failing that, to the `0` that means "no signal". An explicit flag still wins.
    if [ -n "$worktree" ] && work_observe_target "$worktree"; then
        [ -n "$golem" ] || golem="$WORK_OBS_GOLEM"
        [ -n "$status_dir" ] || status_dir="$WORK_OBS_STATUS_DIR"
    fi
    golem="$(work_resolve_golem_arg "$golem" 2>/dev/null || true)"
    if [ -z "$golem" ]; then
        command echo 0
        return 0
    fi
    local registry
    registry="$(work_path_for "$golem" "$status_dir" 2>/dev/null || true)"
    if [ -z "$registry" ]; then
        command echo 0
        return 0
    fi
    # Counted in pure bash rather than with `grep -c`: this script is invoked by
    # the gate-watch liveness sweep, which runs under a PATH stripped to a few
    # stubs, and a missing `grep` there would make count die 127 -> the caller
    # reads no number -> "nothing open" -> the false idle comes back. The whole
    # value of this count is that it cannot fail, so it must not need a binary.
    n=0
    while IFS= read -r _line; do
        [ -n "$_line" ] && n=$((n + 1))
    done <<EOF
$(work_open_reaped "$registry")
EOF
    command echo "$n"
    return 0
}

# --- dispatch ---------------------------------------------------------------
#
# Main-guard: sourcing this file defines the functions without running anything,
# so the tests can exercise the reduction directly (the same sourceable shape
# golem-gate-watch.sh uses).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cmd="${1:-}"
    case "$cmd" in
        register)
            shift
            cmd_register "$@"
            exit $?
            ;;
        complete)
            shift
            cmd_complete "$@"
            exit $?
            ;;
        list)
            shift
            cmd_list "$@"
            exit $?
            ;;
        count)
            shift
            cmd_count "$@"
            exit $?
            ;;
        '' | -h | --help | help)
            usage
            exit 1
            ;;
        *)
            command echo "golem-work: unknown subcommand '$cmd'" >&2
            usage
            exit 1
            ;;
    esac
fi
