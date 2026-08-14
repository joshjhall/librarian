#!/usr/bin/env bash
# tracks-runbook.sh — render a BANKED track composition as an operator runbook
# (issue #673).
#
# `/workflow:orchestrate tracks [N]` normally runs the setup flow straight
# through — propose -> approve -> choose L1-L4 -> DISPATCH — so getting a plan
# means committing to N parallel golem burn rates at once. The `--runbook`
# variant of that flow stops after approval: it banks the composition to
# tracks.json with `dispatched: false` and calls this script to render a
# copy-pasteable command list. The operator then spins up ONE golem at a time by
# hand, spreading the burn across sessions or days.
#
# The deliverable is the point: a plan is only useful banked if it survives the
# session that made it. This script re-renders from tracks.json alone, so the
# operator can act on it days later with no recomposition and nothing re-derived.
#
# NEVER DISPATCHES. No tmux, no `golem-launch.sh launch`. It reads tracks.json,
# shells out to `golem-launch.sh print` for each pending lane head, and writes
# only to stdout. That is the whole contract, and tests/golem-scripts/
# 110-tracks-runbook.sh pins it with an instrumented tmux stub rather than by
# checking output — absent output would pass even if a dispatch had happened.
#
# One source of truth for the launch shape: the head command is obtained by
# INVOKING `golem-launch.sh print <head> --level M`, never hand-assembled here.
# A runbook command that drifts from what a real dispatch runs would fail
# silently and expensively — the operator pastes a line that no longer matches
# the pipeline. `print` shares `launch_line`/`resolve_level` with `launch`, so
# pinning the two byte-for-byte is what keeps them honest.
#
# A lane is SERIAL by construction (issue k+1 dispatches after issue k's PR
# merges), so only the lane HEAD gets a runnable command; the rest render as
# queued-behind, marked with the merge they wait on. Rendering a lane's issues as
# if they were parallel commands would be actively wrong.
#
# STALENESS IS SURFACED, NEVER ACTED ON. A banked plan ages: an issue may close,
# gain a `status/*` label, or gain a dependency after composition. Those are
# flagged inline and the entry is still rendered — the operator may have closed
# it deliberately, and silently dropping work from a plan they are executing is
# the worse failure. When `gh` is unavailable (or the query fails) the script
# says so explicitly rather than rendering as if fresh: reporting "nothing stale"
# because it could not look is indistinguishable from a working check, which is
# the fail-loud rule this repo applies to every scanner.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_STATUS_DIR   (.worktrees/.status) — holds tracks.json
#   GOLEM_WORKTREE_DIR (.worktrees)
#
# Usage:
#   tracks-runbook.sh render [--status-dir DIR] [--no-staleness]
#
# Exit codes:
#   0  rendered
#   2  usage error (unknown/missing subcommand, unknown flag)
#   3  no banked composition to render (tracks.json absent or unreadable)
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# This script is exercised under a deliberately stripped PATH (the no-jq and
# no-gh cases), so `command <tool>` alone would fail to find an external core
# utility there — yet a hardcoded /usr/bin/<tool> is wrong on macOS. `_bin
# <tool>` honors PATH first (the `command -v` builtin needs no external binary),
# then scans the standard bin dirs, then yields the bare name. Candidates are
# bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint does not flag
# them. Defined before SCRIPT_DIR so even that resolution is portable.
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
DIRNAME="$(_bin dirname)"
TR="$(_bin tr)"

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

LAUNCH="$SCRIPT_DIR/golem-launch.sh"

# --- tracks.json readers ----------------------------------------------------
#
# Every read goes through jq. The file is machine-written (by the setup flow,
# against tracks.schema.json), so a hand-rolled parse would buy nothing and risk
# a wrong answer on a nested field; jq absence is handled once, up front, as a
# hard failure rather than per-call.

# tr_jq <filter> [args...] — run a jq filter over $TRACKS, empty on any failure.
tr_jq() {
    local filter="$1"
    shift
    "$JQ" -r "$@" "$filter" "$TRACKS" 2>/dev/null || true
}

# tr_int <filter> <default> — read a filter expecting an integer; fall back to
# <default> on empty/non-numeric so a malformed field degrades to a sane render
# instead of propagating an empty string into arithmetic.
tr_int() {
    local v
    v="$(tr_jq "$1")"
    case "$v" in
        '' | *[!0-9]*) command echo "$2" ;;
        *) command echo "$v" ;;
    esac
}

# tr_issue <filter> — read a filter expecting an ISSUE NUMBER, printing nothing
# unless it is a plain non-negative integer.
#
# Deliberately takes NO default, which is the whole difference from tr_int. That
# one fills in a display value or a loop bound, where any sane number keeps the
# render usable; substituting a fallback ISSUE number would emit a launch command
# aimed at the wrong issue — worse than emitting none. So a bad value yields the
# empty string and the caller flags the entry as malformed.
#
# What this guards is narrower than it looks. These numbers reach `gh issue view`
# and `golem-launch.sh print` as QUOTED argv elements, never `eval`'d and never
# interpolated into a command string, so this is not an injection fix and must not
# be read as the thing standing between the renderer and a shell escape — the
# quoting discipline is. It is defense in depth for a corrupted plan: the up-front
# `jq -e .` check below catches an UNPARSABLE tracks.json, while this catches the
# narrower valid-JSON/wrong-type case (hand-edited, or written by a future caller
# that does not honor the schema), so a non-numeric entry fails loudly instead of
# reaching `gh` and rendering a confusing line.
tr_issue() {
    local v
    v="$(tr_jq "$1")"
    case "$v" in
        '' | *[!0-9]*) return 0 ;;
        *) command echo "$v" ;;
    esac
}

# --- Staleness --------------------------------------------------------------
#
# STALE_MODE is one of:
#   on      — gh present, queries attempted
#   off     — operator passed --no-staleness
#   absent  — gh not on PATH
# Anything but `on` is reported once in the header, so a runbook never implies a
# freshness check that did not run.
STALE_MODE="on"
STALE_NOTE=""

# stale_flags_for <issue> — print a "  ! ..." annotation line per detected drift,
# or nothing when the issue looks as planned. Never filters or drops an entry:
# the caller renders the issue either way, and this only appends context.
#
# Expects an issue number already validated by `tr_issue`. Callers skip this
# entirely for a malformed entry rather than passing one through: a `gh` query on
# a non-number fails, and the resulting "could not check" line would blame a
# flaky API for what is actually a corrupt plan.
#
# Checks: the issue closed; it picked up a status label that would make
# next-issue skip it (someone else is already on it); it gained a dependency
# after composition. A failed query is itself reported — silence must mean
# "checked and clean", never "could not look".
stale_flags_for() {
    local issue="$1" json state labels body
    [ "$STALE_MODE" = "on" ] || return 0

    json="$("$GH" issue view "$issue" --json state,labels,body 2>/dev/null)"
    if [ -z "$json" ]; then
        command echo "    ! could not check #$issue against the live backlog (query failed)"
        return 0
    fi

    state="$(command printf '%s' "$json" | "$JQ" -r '.state // ""' 2>/dev/null)"
    labels="$(command printf '%s' "$json" | "$JQ" -r '[.labels[].name] | join(" ")' 2>/dev/null)"
    body="$(command printf '%s' "$json" | "$JQ" -r '.body // ""' 2>/dev/null)"

    case "$state" in
        CLOSED | closed)
            command echo "    ! #$issue is CLOSED since composition — kept in the plan; drop it yourself if that was deliberate"
            ;;
    esac

    # Space-pad so a prefix match cannot fire on a longer sibling label.
    case " $labels " in
        *" status/in-progress "*)
            command echo "    ! #$issue is now status/in-progress — another golem may already own it"
            ;;
        *" status/pr-pending "*)
            command echo "    ! #$issue is now status/pr-pending — its PR is already open"
            ;;
        *" status/blocked "*)
            command echo "    ! #$issue is now status/blocked"
            ;;
        *" status/on-hold "*)
            command echo "    ! #$issue is now status/on-hold"
            ;;
    esac

    # A dependency declared after composition is the one drift that can make a
    # lane's ORDER wrong rather than just its membership. Same signal
    # next-issue/dependency-queue.md parses. POSIX classes only — BSD grep reads
    # \s/\w as literals, so a GNU-only spelling would silently match nothing
    # here and report every plan as dependency-free.
    if command printf '%s' "$body" |
        command grep -qiE '(blocked by|depends on)[[:space:]]*#[0-9]+' 2>/dev/null; then
        command echo "    ! #$issue declares a dependency (Blocked by / Depends on) — check it is placed ahead in this lane"
    fi
}

# --- Rendering --------------------------------------------------------------

render_header() {
    local dispatched nlanes overlap
    dispatched="$(tr_jq '.dispatched')"
    nlanes="$(tr_int '.tracks | length' 0)"
    overlap="$(tr_jq '.cross_track_overlap // "—"')"

    command echo "GOLEM RUNBOOK — $nlanes lane(s), cross-track overlap $overlap"
    command echo "  plan: $TRACKS"
    if [ "$dispatched" = "false" ]; then
        # A banked plan gets executed lane by lane, so report PROGRESS rather
        # than re-reading the top-level flag. That flag answers "was this
        # composition banked?" and stays `false` for the plan's whole life (the
        # re-render guard depends on it), so treating it as "has anything been
        # launched?" would keep printing "nothing started" after every lane was
        # up. Lane state is the single source of truth for what has actually
        # been launched; the header derives from it instead of duplicating it.
        local pending
        pending="$(tr_int "[.tracks[] | select(.dispatched == false)] | length" "$nlanes")"
        if [ "$pending" -eq 0 ] && [ "$nlanes" -gt 0 ]; then
            command echo "  status: BANKED, fully launched — every lane is in flight"
        elif [ "$pending" -eq "$nlanes" ]; then
            command echo "  status: BANKED (planned, not dispatched) — launch lanes yourself, one at a time"
        else
            command echo "  status: BANKED, partly launched — $pending of $nlanes lane(s) still to launch"
        fi
    else
        command echo "  status: dispatched — lanes below are already in flight"
    fi
    [ -n "$STALE_NOTE" ] && command echo "  $STALE_NOTE"
    command echo ""
}

# render_lane <index> — one lane: its head command (or in-flight marker), its
# queued remainder in serial order, and its honored dependency edges.
render_lane() {
    local idx="$1" laneno head_issue level lane_dispatched nissues i issue edges
    local prev prev_label
    laneno="$(tr_int ".tracks[$idx].lane // $idx" "$idx")"
    level="$(tr_int ".tracks[$idx].autonomy_level" 4)"
    lane_dispatched="$(tr_jq ".tracks[$idx].dispatched")"
    nissues="$(tr_int ".tracks[$idx].issues | length" 0)"

    command echo "LANE $laneno — L$level, $nissues issue(s), serial"

    if [ "$nissues" -eq 0 ]; then
        command echo "  (empty lane)"
        command echo ""
        return 0
    fi

    head_issue="$(tr_issue ".tracks[$idx].issues[0]")"

    # The head: a runnable command, unless the plan is corrupt here or this lane
    # is already under way.
    #
    # A malformed head is FLAGGED AND KEPT, never silently dropped — the same
    # rule the staleness checks follow. The operator may be midway through
    # executing this plan, and a lane that quietly vanished from the render is
    # indistinguishable from one they already finished.
    #
    # It does mean skipping both downstream uses: no `golem-launch.sh print`
    # (there is no issue to launch) and no `stale_flags_for` (querying `gh` with
    # a non-number yields a "could not check" line that would misattribute a
    # corrupt plan to a flaky API). The remainder of the lane still renders below.
    #
    # POLARITY MATTERS on the dispatched arm, and it is the same one
    # render_header uses: only an explicit `false` means pending. An ABSENT field
    # reads as DISPATCHED, per the schema's back-compat contract — every
    # tracks.json written before #673 came from a dispatching setup flow and has
    # no `dispatched` key at all. Testing `= "true"` instead would invert that
    # (jq prints "null" for an absent key, which is not "true"), so a pre-#673
    # plan would render every already-running lane as freshly launchable —
    # inviting the operator to double-launch a golem that is already up, while
    # the header one line above correctly said "already in flight".
    if [ -z "$head_issue" ]; then
        command echo "  (head) — MALFORMED ISSUE NUMBER in the plan"
        command echo "    ! lane $laneno's head is not a number — inspect it with: jq '.tracks[$idx].issues' $TRACKS"
    elif [ "$lane_dispatched" != "false" ]; then
        command echo "  #$head_issue — IN FLIGHT (already launched; no command pending)"
    else
        # The launch shape comes from golem-launch.sh, never from this script.
        #
        # Its stderr is FORWARDED, not swallowed. `print` warns there when this
        # helper's plugin version has skewed from the active install, meaning the
        # emitted line may target a command namespace that no longer resolves —
        # and a banked runbook is pasted days later, which is precisely when that
        # has had time to happen. Suppressing the warning would hand the operator
        # a confident-looking command that silently fails.
        #
        # Its EXIT STATUS is checked too, and separately from the substitution.
        # Under `set -uo pipefail` (no `-e`) a failed `print` merely yields empty
        # stdout, so inlining it into the echo would render "launch this:"
        # followed by a blank line and still exit 0 — a runbook whose single most
        # important line is missing, reported as success. That is precisely the
        # "clean report of nothing" this file's header rules out, and the same
        # standard already applied to the jq and gh paths.
        local head_cmd head_rc
        head_cmd="$("$LAUNCH" print "$head_issue" --level "$level")"
        head_rc=$?
        if [ "$head_rc" -ne 0 ] || [ -z "$head_cmd" ]; then
            command echo "  #$head_issue — LAUNCH COMMAND UNAVAILABLE"
            command echo "    ! golem-launch.sh print failed (exit $head_rc) — see stderr above."
            command echo "    ! Do NOT hand-assemble this command; fix the launcher and re-render."
        else
            command echo "  #$head_issue — launch this:"
            command echo ""
            command echo "    $head_cmd"
            command echo ""
        fi
    fi
    [ -n "$head_issue" ] && stale_flags_for "$head_issue"

    # The remainder is QUEUED, not parallel: each waits on the previous PR.
    #
    # Both reads are guarded, and for different failures: a malformed entry has
    # no `gh` query worth making, while a malformed PREDECESSOR would render a
    # wait-line pointing at nothing ("after #'s PR merges"). The predecessor
    # falls back to a described placeholder rather than being dropped, so the
    # serial ORDER — the thing this loop exists to convey — survives one bad
    # entry in the middle of a lane.
    i=1
    while [ "$i" -lt "$nissues" ]; do
        issue="$(tr_issue ".tracks[$idx].issues[$i]")"
        prev="$(tr_issue ".tracks[$idx].issues[$((i - 1))]")"
        prev_label="#$prev"
        [ -z "$prev" ] && prev_label="the previous (malformed) entry"
        if [ -z "$issue" ]; then
            command echo "  (position $i) — MALFORMED ISSUE NUMBER, queued after $prev_label"
            command echo "    ! not a number — inspect it with: jq '.tracks[$idx].issues' $TRACKS"
        else
            command echo "  #$issue — after $prev_label's PR merges"
            stale_flags_for "$issue"
        fi
        i=$((i + 1))
    done

    # Why this lane is ordered as it is (#462 build-order edges).
    edges="$(tr_jq ".tracks[$idx].deps_honored[]?" | "$TR" '\n' ' ')"
    if [ -n "${edges// /}" ]; then
        command echo "  build order: $edges"
    fi
    command echo ""
}

render_footer() {
    local deferred rationale
    rationale="$(tr_jq '.rationale[]?')"
    if [ -n "$rationale" ]; then
        command echo "WHY THESE LANES"
        command printf '%s\n' "$rationale" | while IFS= read -r line; do
            [ -n "$line" ] && command echo "  - $line"
        done
        command echo ""
    fi

    deferred="$(tr_jq '.deferred[]?' | "$TR" '\n' ' ')"
    if [ -n "${deferred// /}" ]; then
        command echo "DEFERRED (did not fit this composition; a later sweep can pick them up)"
        command echo "  $deferred"
        command echo ""
    fi
}

render() {
    render_header
    local nlanes idx
    nlanes="$(tr_int '.tracks | length' 0)"
    idx=0
    while [ "$idx" -lt "$nlanes" ]; do
        render_lane "$idx"
        idx=$((idx + 1))
    done
    render_footer
}

# --- Entry point ------------------------------------------------------------

usage() {
    command echo "Usage: tracks-runbook.sh render [--status-dir DIR] [--no-staleness]" >&2
}

cmd="${1:-}"
case "$cmd" in
    render) shift ;;
    '')
        command echo "tracks-runbook: needs a subcommand" >&2
        usage
        exit 2
        ;;
    *)
        command echo "tracks-runbook: unknown subcommand '$cmd'" >&2
        usage
        exit 2
        ;;
esac

STATUS_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --status-dir)
            if [ -z "${2:-}" ]; then
                command echo "tracks-runbook: --status-dir needs a directory" >&2
                exit 2
            fi
            STATUS_DIR="$2"
            shift 2
            ;;
        --no-staleness)
            STALE_MODE="off"
            shift
            ;;
        *)
            command echo "tracks-runbook: unknown flag '$1'" >&2
            usage
            exit 2
            ;;
    esac
done

if [ -z "$STATUS_DIR" ]; then
    root="$(repo_root 2>/dev/null || true)"
    if [ -z "$root" ]; then
        command echo "tracks-runbook: not inside a git repository (and no --status-dir given)" >&2
        exit 3
    fi
    STATUS_DIR="$root/$GOLEM_STATUS_DIR"
fi
TRACKS="$STATUS_DIR/tracks.json"

if [ ! -r "$TRACKS" ]; then
    command echo "tracks-runbook: no banked composition at $TRACKS" >&2
    command echo "  compose one with: /workflow:orchestrate tracks --runbook" >&2
    exit 3
fi

# AVAILABILITY IS A PATH QUESTION — deliberately NOT resolved through `_bin`.
#
# `_bin` exists to make a tool INVOCABLE under a stripped PATH, so it scans the
# standard bin dirs and yields an absolute path. That is exactly wrong for
# deciding whether an optional tool is *available*: `command -v /usr/bin/gh`
# succeeds whenever the file exists, whatever PATH says, so a `_bin`-resolved
# guard can never fire and the no-gh arm would be unreachable. jq and gh are
# ordinary PATH-installed tools (unlike the coreutils `_bin` covers), so a bare
# `command -v` is both the honest check and what every sibling script uses.
#
# jq is not optional: every field this script renders is read through it, so a
# missing jq means an EMPTY runbook — a plan that looks like it has no lanes.
# Fail loudly instead (a tool that cannot do its job exits non-zero rather than
# emitting a clean report of nothing).
if ! command -v jq >/dev/null 2>&1; then
    command echo "tracks-runbook: jq is required to read $TRACKS" >&2
    exit 3
fi
JQ="jq"

# The plan must PARSE, not merely be readable. `[ -r ]` above answers the wrong
# question: a truncated write, a full disk, or an editor caught mid-save leaves a
# file that opens fine and parses not at all. Every read here goes through
# `tr_jq`, which discards jq's exit status, so an unparsable plan degrades into
# empty strings — `nlanes` falls back to 0, the lane loop runs zero times, and
# `dispatched` reads as neither "false" nor "true", so the header announces
# "dispatched — lanes below are already in flight" above no lanes at all, exit 0.
# An operator would read that as their whole plan already being up.
#
# Validate once, here, where a single check covers every later read.
if ! "$JQ" -e . "$TRACKS" >/dev/null 2>&1; then
    command echo "tracks-runbook: $TRACKS is not valid JSON — refusing to render a partial plan" >&2
    command echo "  a truncated or half-written plan can look like an empty one; inspect it with: jq . $TRACKS" >&2
    exit 3
fi

# gh IS optional — its absence downgrades staleness checking, which is reported
# in the header rather than passed off as a clean check.
GH="gh"
if [ "$STALE_MODE" = "off" ]; then
    STALE_NOTE="staleness: NOT CHECKED (--no-staleness) — entries may have moved since composition"
elif ! command -v gh >/dev/null 2>&1; then
    STALE_MODE="absent"
    STALE_NOTE="staleness: NOT CHECKED (gh unavailable) — entries may have moved since composition"
fi

render
