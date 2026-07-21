#!/usr/bin/env bash
# golem-status.sh — show the central golem status table + which golems are
# BLOCKED (TTY-free).
#
# Replaces the containers `golems` just recipe so the golem flow runs WITHOUT
# `just`, on host / bare Linux / inside a devcontainer.
#
# Reads <GOLEM_STATUS_DIR>/*.json (per-golem status cache) + live golem-* tmux
# sessions and the Notification feed (<GOLEM_STATUS_DIR>/feed.jsonl); PR + issue
# -label state remains authoritative (the cache only fills gaps). pool.json and
# tracks.json are operator policy / track composition, NOT golem-status files, so
# they are excluded from the golem-row glob and surfaced separately (pool in the
# header; tracks as the --checkpoint grouping key).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_STATUS_DIR     (.worktrees/.status)
#   GOLEM_SWEEP_INTERVAL sweep cadence for --watch, seconds. Unset -> the
#                        level-scaled default from autonomy-resolve.sh (#304).
#
# Usage:
#   golem-status.sh                        one-shot verbose render (default)
#   golem-status.sh --checkpoint           one-shot COMPACT per-track status+burn
#                                          table + batch-totals footer (#283)
#   golem-status.sh [--checkpoint] --watch [--level N] [--interval S]
#                                          re-render on a level-scaled interval
#                                          until killed (orchestrator Phase M
#                                          default-on sweep, #304). --checkpoint
#                                          selects the compact render for the
#                                          sweep; without it the sweep is verbose.
#
# --watch interval precedence (first present wins):
#   --interval S  >  GOLEM_SWEEP_INTERVAL  >  autonomy-resolve sweep-interval
#   --level N  >  autonomy-resolve sweep-interval (L1 default).
#
# --checkpoint replaces the verbose render (mutually exclusive) — it re-drives the
# same token scrape/persist path, so running both in one sweep would reset the
# burn Δ baseline. In watch mode it also reports an aggregate token rate
# (Δ/interval); a one-shot --checkpoint prints rate=— (no prior sweep to diff).
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

root="$(repo_root)"
status_dir="$root/$GOLEM_STATUS_DIR"
feed="$status_dir/feed.jsonl"
pool="$status_dir/pool.json"
tracks="$status_dir/tracks.json"
scrape="$SCRIPT_DIR/golem-token-scrape.sh"
shopt -s nullglob

# _now_iso — current UTC time as an ISO-8601 Z timestamp (mirrors the
# golem-notify.sh feed-line idiom). The "frozen since" anchor for token freezes.
_now_iso() {
    command date -u +%FT%TZ
}

# _iso_to_epoch <iso> — parse an ISO-8601 Z timestamp to epoch seconds, trying
# GNU `date -d` then BSD `date -j -f` (mirrors _mtime_epoch's dual-toolchain
# approach in golem-gate-watch.sh so the frozen-duration math works on Linux and
# base macOS alike). Prints nothing on failure, so the caller falls back to
# showing the raw "frozen since <iso>" rather than a bogus minute count.
_iso_to_epoch() {
    _ie_iso="$1"
    [ -n "$_ie_iso" ] || return 0
    command date -u -d "$_ie_iso" +%s 2>/dev/null && return 0
    command date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$_ie_iso" +%s 2>/dev/null && return 0
    return 0
}

# _fmt_dur <seconds> — human-friendly "Nm" for >=60s else "Ns" (a non-negative
# second count). Matches golem-gate-watch.sh's _fmt_age wording.
_fmt_dur() {
    _fd_s="$1"
    if [ "$_fd_s" -ge 60 ]; then
        command echo "$((_fd_s / 60))m"
    else
        command echo "${_fd_s}s"
    fi
}

# _gate_age_suffix <golem> <feed> — a "  (gated Nm ago)" annotation for a golem's
# most-recent feed line, or empty when it can't be computed. Defense-in-depth for
# #422: the `resolved` clearing line (golem-resolve.sh) fixes the stale-BLOCKED
# false positive at the source, but showing the gate's age makes any RESIDUAL
# staleness self-evident — a reader can tell a 30-second-old real gate from a
# 38-minute-old missed-clear one at a glance. Reads the golem's LAST feed line
# (matching golem-gate-watch.sh's `group_by | map(.[-1])` most-recent-wins rule)
# and derives its `.ts`. A missing/empty/unparseable ts prints nothing (the
# render falls back to the bare line — never an error, never a bogus "0s").
# jq-gated like the rest of the feed read; a no-op without jq.
_gate_age_suffix() {
    _gas_golem="$1"
    _gas_feed="$2"
    [ -f "$_gas_feed" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    _gas_ts="$(/usr/bin/tail -n 200 "$_gas_feed" 2>/dev/null |
        jq -rs --arg g "$_gas_golem" '
            [ .[] | select(.golem == $g) ] | last | (.ts // "")
          ' 2>/dev/null)"
    [ -n "$_gas_ts" ] || return 0
    _gas_epoch="$(_iso_to_epoch "$_gas_ts")"
    [ -n "$_gas_epoch" ] || return 0
    _gas_now="$(command date -u +%s 2>/dev/null)" || return 0
    _gas_d=$((_gas_now - _gas_epoch))
    [ "$_gas_d" -lt 0 ] && _gas_d=0
    command printf '  (gated %s ago)' "$(_fmt_dur "$_gas_d")"
}

# _frozen_phrase <cur> <at> — the shared "how long has the counter been frozen"
# renderer for the verbose TOP-LEVEL TOKENS block. Given a cumulative count and
# its "frozen since" anchor ISO, echoes either "<cur> tokens, frozen <Xm>" (when
# the anchor parses to an epoch) or the raw "<cur> tokens, frozen since <iso>"
# fallback (when `date` cannot read the anchor — never a bogus computed "frozen
# 0s"; see #392). Used by BOTH the Mode-2 `frozen` arm and the Mode-3
# externally-posted `container` arm so the two render byte-identically (#390) —
# the #371/#392 frozen-render tests gate the shared form.
_frozen_phrase() {
    _fp_cur="$1"
    _fp_at="$2"
    _fp_epoch="$(_iso_to_epoch "$_fp_at")"
    if [ -n "$_fp_epoch" ]; then
        _fp_now="$(command date -u +%s)"
        _fp_d=$((_fp_now - _fp_epoch))
        [ "$_fp_d" -lt 0 ] && _fp_d=0
        command echo "$_fp_cur tokens, frozen $(_fmt_dur "$_fp_d")"
    else
        command echo "$_fp_cur tokens, frozen since $_fp_at"
    fi
}

# collect_cache — populate the module-level `cache` array with the per-golem
# status JSON files in $status_dir, EXCLUDING the operator-policy singletons
# (pool.json) and the track-composition file (tracks.json) — neither is a
# golem-status file, so including either would render a bogus "?" row (pool) or a
# spurious tracks row. pool.json is surfaced in the pool header; tracks.json is
# the --checkpoint grouping key. Shared by render_status and render_checkpoint so
# the exclusion set lives in ONE place (a future sibling singleton lands here).
collect_cache() {
    cache=()
    for f in "$status_dir"/*.json; do
        [ "$f" = "$pool" ] && continue
        [ "$f" = "$tracks" ] && continue
        cache+=("$f")
    done
}

# scrape_and_persist_tokens <cache-file> — the SOLE writer of a golem's
# top_level_tokens / top_level_tokens_at cache fields (issue #371). Scrapes the
# cumulative TOP-LEVEL token count from the golem's Claude Code transcript
# (golem-token-scrape.sh), reads the previously-persisted value + "frozen since"
# anchor, carries the anchor forward while the count is unchanged (resets it to
# now when the count moves or on first read), and merges the two fields back into
# the cache JSON atomically (mktemp beside $f + jq + mv — jq cannot edit in
# place; mktemp, NOT a predictable "$f.tmp.$$", so a pre-planted symlink can't
# redirect jq's write; the tempfile lands in $status_dir so the mv is atomic —
# same filesystem).
#
# Echoes ONE tab-separated line: "<state>\t<cur>\t<prev>\t<at>", where
#   state ∈ container | container-pending | unknown | first | advancing | reset | frozen
#   cur   = the scraped/read count (empty for container-pending/unknown)
#   prev  = the prior persisted count (empty when none / container*/unknown)
#   at    = the frozen-since anchor ISO (empty for container-pending/unknown)
# `reset` is cur < prev: the cumulative count DROPPED, which golem-token-scrape.sh
# documents as the expected shape of a fresh session (post-/clear, a new
# transcript file) — a new baseline, NOT negative work. Callers must render it as
# a reset and exclude it from any burn-Δ arithmetic, never as a negative delta.
# BOTH callers — the verbose TOP-LEVEL TOKENS block and the --checkpoint
# Tokens(Δ) column — drive their own DISPLAY off this one classification, so the
# risky scrape+persist+classify lives in exactly ONE place and the #371 token
# tests gate both.
#
# MODE per state:
#   * WORKTREE (Mode 2): scrape the host-readable transcript, persist the count +
#     "frozen since" anchor, and classify first/advancing/reset/frozen. Fail-loud:
#     a missing/unparsable transcript → state=unknown, never a bogus frozen=0 that
#     could trip a false takeover.
#   * CONTAINER (Mode 3, #390): a container golem's transcript runs INSIDE the
#     container and is not host-readable, so we never scrape here. Instead the
#     container POSTs its top-level usage back to the host (containers repo, the
#     producer side), writing top_level_tokens(+_at) into this same cache row. We
#     READ (never re-write — the producer owns the fields; a host rewrite would
#     race the POST) those two fields: a valid numeric count + an anchor → state=
#     container (a mechanical frozen render, exactly like Mode 2's `frozen`); a
#     missing / non-numeric count or absent anchor (not POSTed yet, or a legacy
#     row) → state=container-pending, a graceful note, never a bogus 0.
scrape_and_persist_tokens() {
    _sapt_f="$1"
    _sapt_ctr="$(jq -r '.container // empty' "$_sapt_f" 2>/dev/null)"
    _sapt_issue="$(jq -r '.issue // empty' "$_sapt_f" 2>/dev/null)"
    if [ -n "$_sapt_ctr" ]; then
        # Mode 3: READ the externally-POSTed usage; never scrape, never persist.
        _sapt_cctok="$(jq -r '.top_level_tokens // empty' "$_sapt_f" 2>/dev/null)"
        _sapt_ccat="$(jq -r '.top_level_tokens_at // empty' "$_sapt_f" 2>/dev/null)"
        # Numeric-guard the POSTed count with the SAME octal/overflow rules the
        # persisted prior uses below — the cache is co-written, so a corrupt /
        # leading-zero / overflow value must degrade to container-pending, never
        # reach a bogus frozen render.
        case "$_sapt_cctok" in
            0) ;; # canonical zero — a real posted count
            '' | 0* | *[!0-9]*) _sapt_cctok="" ;;
            *) [ "${#_sapt_cctok}" -gt 18 ] && _sapt_cctok="" ;;
        esac
        # Shape-guard the POSTed anchor the SAME way. `top_level_tokens_at` comes
        # from the untrusted external POST too, so it gets an allowlist, not just a
        # non-empty check: require EXACTLY the `%Y-%m-%dT%H:%M:%SZ` form _now_iso
        # writes (fully anchored — no free wildcard). This blanks anything else
        # (→ container-pending), closing two gaps at once: (1) a control/ANSI/tab
        # sequence in a hostile or buggy POST can no longer reach `command echo`
        # in _frozen_phrase (terminal-injection), and (2) a lenient-but-wrong
        # string like "now" or a bare number can no longer parse through GNU
        # `date -d` into a plausible-but-false frozen duration — a malformed anchor
        # degrades to the graceful pending note instead of a bogus "frozen Xm".
        case "$_sapt_ccat" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
            *) _sapt_ccat="" ;;
        esac
        if [ -n "$_sapt_cctok" ] && [ -n "$_sapt_ccat" ]; then
            # Emit prev == cur (the Mode-2 `frozen` tuple shape). This is NOT
            # cosmetic: `IFS=$'\t' read` collapses ADJACENT tabs (tab is IFS
            # whitespace), so an EMPTY prev field between cur and at would be
            # swallowed and `at` would read empty at the call sites. A non-empty
            # prev keeps the 4 fields aligned; no reader divides by prev for a
            # container row, so mirroring cur is harmless and semantically apt (a
            # posted container reading is a single frozen-window sample).
            command printf 'container\t%s\t%s\t%s\n' "$_sapt_cctok" "$_sapt_cctok" "$_sapt_ccat"
        else
            command printf 'container-pending\t\t\t\n'
        fi
        return 0
    fi
    _sapt_wt="$root/$GOLEM_WORKTREE_DIR/issue-$_sapt_issue"
    _sapt_cur=""
    if [ -n "$_sapt_issue" ] && [ -x "$scrape" ]; then
        _sapt_cur="$("$scrape" "$_sapt_wt" 2>/dev/null || true)"
    fi
    case "$_sapt_cur" in
        '' | *[!0-9]*)
            command printf 'unknown\t\t\t\n'
            return 0
            ;;
    esac
    _sapt_prev="$(jq -r '.top_level_tokens // empty' "$_sapt_f" 2>/dev/null)"
    _sapt_prev_at="$(jq -r '.top_level_tokens_at // empty' "$_sapt_f" 2>/dev/null)"
    # Numeric-guard the PERSISTED prior value: the cache is a co-written JSON file
    # (the orchestrator model also writes it), so a corrupted / hand-edited /
    # non-canonical field must NOT reach the `-gt`/`-lt` comparisons or `$(( ))`
    # below. The canonical scraper only ever writes `0` or `[1-9][0-9]*`; anything
    # else — a non-digit string, OR a LEADING-ZERO value like "089" that bash's
    # arithmetic treats as invalid octal ("value too great for base") — is treated
    # as "no prior" (→ a fresh `first` reading), never a thrown arithmetic error
    # that would leak into or DROP the row from the status table (the very
    # monitoring-integrity gap this signal exists to close). This is stricter than
    # _sapt_cur's all-digit guard above precisely because a leading zero is the
    # documented octal hazard; _sapt_cur comes straight from the scraper and is
    # canonical by construction, so it needs no de-octaling.
    case "$_sapt_prev" in
        0) ;; # canonical zero — safe
        '' | 0* | *[!0-9]*) _sapt_prev="" ;;
        # A purely-numeric, non-leading-zero value can still OVERFLOW bash's signed
        # 64-bit arithmetic (a hand-corrupted / runaway "9999…" throws "integer
        # expression expected" on `-gt`/`-lt` and would misclassify as frozen — a
        # false #369 takeover signal). 18 digits stays well inside 2^63-1 (~9.2e18);
        # anything longer is treated as corrupt → "no prior" (a safe first reading).
        *) [ "${#_sapt_prev}" -gt 18 ] && _sapt_prev="" ;;
    esac
    if [ -n "$_sapt_prev" ] && [ "$_sapt_cur" = "$_sapt_prev" ] && [ -n "$_sapt_prev_at" ]; then
        _sapt_at="$_sapt_prev_at"
    else
        _sapt_at="$(_now_iso)"
    fi
    _sapt_tmp="$(command mktemp "$status_dir/.tok.XXXXXX" 2>/dev/null)"
    if [ -n "$_sapt_tmp" ] && jq --argjson t "$_sapt_cur" --arg at "$_sapt_at" \
        '. + {top_level_tokens: $t, top_level_tokens_at: $at}' \
        "$_sapt_f" >"$_sapt_tmp" 2>/dev/null; then
        command mv "$_sapt_tmp" "$_sapt_f" 2>/dev/null || command rm -f "$_sapt_tmp"
    else
        [ -n "$_sapt_tmp" ] && command rm -f "$_sapt_tmp"
    fi
    if [ -z "$_sapt_prev" ]; then
        _sapt_state="first"
    elif [ "$_sapt_cur" -gt "$_sapt_prev" ]; then
        _sapt_state="advancing"
    elif [ "$_sapt_cur" -lt "$_sapt_prev" ]; then
        # Count dropped → fresh session (a new baseline), not negative work.
        _sapt_state="reset"
    else
        _sapt_state="frozen"
    fi
    command printf '%s\t%s\t%s\t%s\n' "$_sapt_state" "$_sapt_cur" "$_sapt_prev" "$_sapt_at"
}

# render_status — emit one complete status snapshot (pool header, golem table,
# BLOCKED list, liveness, recent feed). Re-globs the cache and re-scans tmux on
# every call so --watch reflects golems that appeared/finished since the last
# sweep. Never exits the process (returns 0) so the --watch loop can re-invoke it.
render_status() {
    collect_cache

    sessions="$(tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' || true)"
    if [ "${#cache[@]}" -eq 0 ] && [ -z "$sessions" ] && [ ! -f "$pool" ]; then
        command echo "No active golems (no $status_dir/*.json, no golem-* tmux sessions)."
        return 0
    fi

    # Pool header: size, slots in use, backlog depth, and the queue state.
    # Defensive `// "-"` fallbacks mirror the golem-row jq style for absent fields.
    if [ -f "$pool" ]; then
        jq -r '"Pool: size=\(.size // "-")  slots=\((.slots // []) | length)/\(.size // "-")  backlog=\(.backlog_depth // "-")  queue=\(.queue // .accepting // "-")"' \
            "$pool" 2>/dev/null || command echo "Pool: (unreadable $pool)"
        command echo ""
    fi

    /usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
        GOLEM ISSUE BRANCH PR STATE PHASE BLOCKING
    for f in "${cache[@]}"; do
        jq -r '[
            (.golem // "?"),
            (.issue // "?" | tostring),
            (.branch // "-"),
            (.pr // "-" | tostring),
            (.state // "-"),
            (.phase // "-"),
            (if .blocking then "YES" else "-" end)
        ] | @tsv' "$f" 2>/dev/null |
            while IFS=$'\t' read -r g i b p s ph bl; do
                /usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' "$g" "$i" "$b" "$p" "$s" "$ph" "$bl"
            done
    done

    # Live sessions with no cache file yet.
    for sess in $sessions; do
        n="${sess#golem-}"
        if [ ! -e "$status_dir/golem-$n.json" ] && [ ! -e "$status_dir/issue-$n.json" ]; then
            /usr/bin/printf '%-10s %-6s %-22s %-5s %-12s %-10s %-8s\n' \
                "$sess" "$n" "-" "-" "(live)" "-" "-"
        fi
    done

    command echo ""
    command echo "BLOCKED (needs a human decision):"
    blocked=0
    for f in "${cache[@]}"; do
        if [ "$(jq -r '.blocking // false' "$f" 2>/dev/null)" = "true" ]; then
            n="$(jq -r '.issue // empty' "$f" 2>/dev/null)"
            command echo "  golem-$n — golem-attach.sh $n"
            blocked=1
        fi
    done

    # Fresh-gate detection from the feed is delegated to golem-gate-watch.sh
    # (--once snapshot) so this BLOCKED list and the proactive `--stream` watch
    # share ONE source of truth and can never drift. The helper applies the same
    # rule: a golem is BLOCKED only when its most-recent feed line is a fresh `gate`
    # (legacy `blocked` honored, a mid-flight `escalation` per issue #176, or a
    # `dead-end` per issue #180) within GOLEM_BLOCK_TTL; an `idle` emitted once the
    # golem resumes supersedes and clears it. It emits "<golem>\t<message>", already
    # labelling an escalation "escalation — …" and a dead-end "dead-end — …";
    # reformat to the "  golem — message" display here.
    #
    # For an escalation/dead-end line, the message embeds the brokered-gate id as
    # "[gate-<epoch>-<rand>]" (#227). When present, annotate the line with the
    # inbox state (`golem-inbox.sh state`) so the operator can see, before
    # answering centrally, whether the gate is still `awaiting` a decision, has an
    # `answered` (unconsumed) decision waiting, or is already `consumed` — avoiding
    # a double-answer (#395). A routine permission `gate`/legacy `blocked` line
    # carries no gate-id, so it stays un-annotated (it is not inbox-brokered — the
    # #29 data-only invariant). Use a bash while-loop, not awk: awk cannot shell
    # out to `state` per line (same reason the TOP-LEVEL TOKENS loop below is bash).
    if [ -f "$feed" ] && [ -x "$SCRIPT_DIR/golem-gate-watch.sh" ]; then
        feed_out="$("$SCRIPT_DIR/golem-gate-watch.sh" --once 2>/dev/null)"
        if [ -n "$feed_out" ]; then
            /usr/bin/printf '%s\n' "$feed_out" |
                while IFS=$'\t' read -r g msg; do
                    [ -n "$g$msg" ] || continue # awk NF guard: skip blank lines
                    # Extract the correlation id from the BRACKETED "[gate-…]"
                    # token the escalation/dead-end protocol embeds — NOT an
                    # unanchored scan of the free-text message. A routine gate's
                    # command text can contain a gate-shaped substring (a branch
                    # or path like `fix/gate-123-x`) that an unanchored match would
                    # wrongly treat as a brokered gate-id and falsely annotate;
                    # and a message that mentions an older gate-id before its own
                    # bracketed one would match the wrong gate. The bracket anchor
                    # keys on exactly what golem-inbox mints, so a well-formed
                    # message yields its one real id and a token-less line yields
                    # empty (→ no annotation, correct for a non-brokered gate).
                    gate_id="$(command printf '%s' "$msg" |
                        /usr/bin/grep -oE '\[gate-[0-9]+-[0-9a-z]+\]' | /usr/bin/head -n1)"
                    # Strip the surrounding brackets before querying.
                    gate_id="${gate_id#[}"
                    gate_id="${gate_id%]}"
                    # Gate age (#422): "  (gated Nm ago)" so a stale-vs-fresh gate
                    # is visually obvious even if a clearing line was missed. Empty
                    # when the ts can't be derived (no jq / no ts) — never errors.
                    age="$(_gate_age_suffix "$g" "$feed")"
                    if [ -n "$gate_id" ] && [ -x "$SCRIPT_DIR/golem-inbox.sh" ]; then
                        st="$("$SCRIPT_DIR/golem-inbox.sh" state "$g" "$gate_id" 2>/dev/null || true)"
                        case "$st" in
                            # Fail-safe: only annotate on a recognized state; any
                            # unexpected output falls through to the plain line, so
                            # a broken sibling never blanks the BLOCKED list.
                            awaiting | answered | consumed)
                                /usr/bin/printf '  %s — %s  [inbox: %s]%s\n' "$g" "$msg" "$st" "$age"
                                ;;
                            *)
                                /usr/bin/printf '  %s — %s%s\n' "$g" "$msg" "$age"
                                ;;
                        esac
                    else
                        /usr/bin/printf '  %s — %s%s\n' "$g" "$msg" "$age"
                    fi
                done
            # Set OUTSIDE the pipe subshell (the loop above runs in a subshell, so
            # a `blocked=1` inside it would not survive) — key the flag off the
            # non-empty snapshot directly so the "(none)" fallthrough stays correct.
            blocked=1
        fi
    fi
    [ "$blocked" -eq 0 ] && command echo "  (none)"

    # Liveness/heartbeat (issue #38) — a SOFT, advisory signal, distinct from the
    # BLOCKED gate list above. Delegated to golem-gate-watch.sh --once-liveness so
    # the pulled status view and the proactive --stream-liveness watch share ONE
    # source of truth (same rule, same stall threshold) and can never drift. Each
    # line is "golem-N alive, working ..." (pane spinner OR transcript turn-in-
    # flight active), "golem-N ⚠ idle at prompt ..." (errored/idle — from the tmux
    # pane for a visible golem, issue #229, or from the on-disk transcript for a
    # headless one, issue #248), "golem-N alive (process up ...)" (mtime heartbeat
    # only), or "golem-N possible stall ..."; a golem at a fresh gate is reported
    # as gated here, not stalled. Never kills/blocks a golem — it only points the
    # operator at the suspect ones.
    if [ -x "$SCRIPT_DIR/golem-gate-watch.sh" ]; then
        command echo ""
        command echo "LIVENESS (advisory — heartbeat / possible stall):"
        liveness="$(
            "$SCRIPT_DIR/golem-gate-watch.sh" --once-liveness 2>/dev/null |
                /usr/bin/awk -F'\t' 'NF { printf "  %s — %s\n", $1, $2 }'
        )"
        if [ -n "$liveness" ]; then
            /usr/bin/printf '%s\n' "$liveness"
        else
            command echo "  (no liveness proxy available)"
        fi
    fi

    # TOP-LEVEL TOKENS (issue #371) — the mechanical frozen-counter signal feeding
    # #369's slow-review takeover contract. For each cached golem we scrape the
    # cumulative TOP-LEVEL token count from its Claude Code transcript
    # (golem-token-scrape.sh), persist it + a "frozen since" anchor back into the
    # golem's status JSON, and render how long the count has been frozen. The
    # operator reads "frozen Xm" here instead of attaching to each pane by eye.
    # A WORKTREE (Mode 2) golem is scraped here; a container (Mode 3) golem is not
    # host-scrapable but POSTs its top-level usage into the same cache fields, which
    # we READ and render with the identical "frozen Xm" form (#390) — falling back
    # to an "awaiting token push" note only until that POST lands.
    # jq-gated (needs jq to read/merge the cache and sum the transcript).
    if command -v jq >/dev/null 2>&1 && [ "${#cache[@]}" -gt 0 ]; then
        command echo ""
        command echo "TOP-LEVEL TOKENS (frozen-counter signal — #369 takeover contract):"
        for f in "${cache[@]}"; do
            g="$(jq -r '.golem // "?"' "$f" 2>/dev/null)"
            # scrape_and_persist_tokens owns the scrape+persist+classify (the SOLE
            # writer of top_level_tokens*); this block just formats the display.
            # The verbose render keys off tstate/cur/at only — the prior count
            # (prev, 3rd field) is unused here (the checkpoint column uses it for
            # Δ), so it is read into a throwaway.
            IFS=$'\t' read -r tstate cur _prev at < <(scrape_and_persist_tokens "$f")
            case "$tstate" in
                container-pending)
                    command echo "  $g — awaiting token push (container golem, see #390)"
                    ;;
                unknown)
                    command echo "  $g — tokens unknown (no transcript)"
                    ;;
                first)
                    command echo "  $g — $cur tokens (first reading)"
                    ;;
                advancing | reset)
                    # The verbose render prints only a word, no signed delta, so a
                    # reset (fresh-session count drop) reads as "advancing" here
                    # exactly as before the reset state was split out — the count
                    # moved. The checkpoint column is where reset renders distinctly.
                    command echo "  $g — $cur tokens (advancing)"
                    ;;
                frozen | container)
                    # A Mode-2 scraped freeze and a Mode-3 externally-posted count
                    # both render the identical frozen-duration phrase (#390): the
                    # takeover contract's 45–60 min frozen-window read is now
                    # mechanical for either mode.
                    command echo "  $g — $(_frozen_phrase "$cur" "$at")"
                    ;;
            esac
        done
    fi

    if [ -f "$feed" ]; then
        command echo ""
        command echo "Recent feed ($feed):"
        /usr/bin/tail -n 10 "$feed"
    fi
}

# ---------------------------------------------------------------------------
# --checkpoint mode (issue #283) — a COMPACT, per-track status+burn snapshot for
# the orchestrator's periodic monitor sweep. It REPLACES the verbose
# render_status render for that invocation (mutually exclusive, not additive):
# the token persist below is the frozen-counter baseline, and running it twice in
# one sweep would reset the Δ. One render path touches the cache per sweep.
# ---------------------------------------------------------------------------

# The one fixed-width row format, shared by the header, each golem row, and the
# session-only "(live)" row so the columns line up. 10 columns matching the #283
# table: Track Golem Issue Stage Elapsed Tokens(Δ) PR CI Review State. (Δ and ⚠
# are multibyte, so a marked cell is a couple of bytes wider than its glyph count
# — cosmetic only; the data stays readable.)
CHECKPOINT_ROW_FMT='%-5s %-9s %-5s %-13s %-7s %-15s %-4s %-8s %-10s %s\n'

# derive_stage <cache-file> — the compact "Stage" cell: prefer .phase_detail
# (e.g. "loop: make-it-tested"), else .phase, else .state, else "—". "review N/M"
# is NOT in the cache (pane-only, judged unreliable in #371), so a review cycle
# degrades to the .state token (e.g. "review-cycle") rather than a fake N/M.
derive_stage() {
    _ds_f="$1"
    _ds="$(jq -r '.phase_detail // .phase // .state // "—"' "$_ds_f" 2>/dev/null)"
    [ -n "$_ds" ] || _ds="—"
    command printf '%s' "$_ds"
}

# session_gone <issue-n> — 0 (gone) only when a golem-<n> tmux session is
# EXPECTED but absent while the server is demonstrably reachable. Conservative:
# decides "gone" solely when at least one golem-* session is visible in
# $cp_sessions (proving the server is the right one) but not this golem's. With
# NO sessions at all we cannot tell "server elsewhere / detached" from "all gone",
# so we return non-zero (not gone) — this is what keeps a hermetic/detached run
# (and the test sandbox, which has no tmux server) from flagging every row ⚠ gone.
# The caller skips this for container (Mode 3) golems — either token-state,
# `container` or `container-pending` — which never have a host tmux session.
session_gone() {
    _sg_n="$1"
    [ -n "$cp_sessions" ] || return 1
    case " $cp_sessions " in
        *" golem-$_sg_n "*) return 1 ;;
        *) return 0 ;;
    esac
}

# emit_checkpoint_row <cache-file> <track-label> — render ONE golem row and fold
# its numbers into the batch accumulators. MUST be called from a direct loop in
# render_checkpoint (never a pipe / subshell) so the cp_* accumulators it mutates
# survive for the footer. Pulls every column from the cache JSON (gh-free);
# Tokens(Δ) reuses the shared scrape/persist helper so the frozen baseline is
# written exactly once per sweep.
emit_checkpoint_row() {
    _ecr_f="$1"
    _ecr_track="$2"
    _ecr_g="$(jq -r '.golem // "?"' "$_ecr_f" 2>/dev/null)"
    _ecr_issue="$(jq -r '.issue // "?"' "$_ecr_f" 2>/dev/null)"
    _ecr_pr="$(jq -r '.pr // "—"' "$_ecr_f" 2>/dev/null)"
    _ecr_ci="$(jq -r '.ci // "—"' "$_ecr_f" 2>/dev/null)"
    _ecr_review="$(jq -r '.review // "—"' "$_ecr_f" 2>/dev/null)"
    _ecr_state="$(jq -r '.state // "—"' "$_ecr_f" 2>/dev/null)"
    _ecr_blocking="$(jq -r '.blocking // false' "$_ecr_f" 2>/dev/null)"
    _ecr_stage="$(derive_stage "$_ecr_f")"

    # Elapsed from .started (ISO; agent-written, so often absent → "—"). Do NOT
    # substitute .last_activity — a different semantic (last update, not launch).
    _ecr_started="$(jq -r '.started // empty' "$_ecr_f" 2>/dev/null)"
    _ecr_elapsed="—"
    if [ -n "$_ecr_started" ]; then
        _ecr_se="$(_iso_to_epoch "$_ecr_started")"
        if [ -n "$_ecr_se" ]; then
            _ecr_now="$(command date -u +%s)"
            _ecr_d=$((_ecr_now - _ecr_se))
            [ "$_ecr_d" -lt 0 ] && _ecr_d=0
            _ecr_elapsed="$(_fmt_dur "$_ecr_d")"
        fi
    fi

    # Tokens (Δ) via the shared scrape/persist helper (SOLE writer of the cache
    # token fields). Δ = cur - prev; only advancing/frozen have a prior reading.
    IFS=$'\t' read -r _ecr_tstate _ecr_cur _ecr_prev _ecr_at < <(scrape_and_persist_tokens "$_ecr_f")
    case "$_ecr_tstate" in
        container-pending) _ecr_tok="n/a" ;;
        container)
            # A container's POSTed count folds into the cumulative Σtokens total
            # (honest burn), but NEVER sets cp_have_delta: the per-sweep Δ / rate
            # need golem-status's OWN prior sample, which the read-only container
            # path deliberately doesn't keep. Render the count with a (frozen) tag
            # — a container reading is a mechanical frozen-window sample (#390).
            _ecr_tok="$_ecr_cur (frozen)"
            cp_total_tokens=$((cp_total_tokens + _ecr_cur))
            ;;
        unknown) _ecr_tok="—" ;;
        first)
            _ecr_tok="$_ecr_cur (first)"
            cp_total_tokens=$((cp_total_tokens + _ecr_cur))
            ;;
        advancing)
            _ecr_delta=$((_ecr_cur - _ecr_prev))
            _ecr_tok="$_ecr_cur (+$_ecr_delta)"
            cp_total_tokens=$((cp_total_tokens + _ecr_cur))
            cp_total_delta=$((cp_total_delta + _ecr_delta))
            cp_have_delta=1
            ;;
        reset)
            # Fresh-session count DROP — a new baseline, not negative burn. Render
            # it distinctly and keep it OUT of the Δ arithmetic (no negative delta,
            # no corrupted aggregate rate). Its tokens still count toward the total,
            # but it does NOT set cp_have_delta: a sweep whose only movement was a
            # reset has no meaningful burn rate to report.
            _ecr_tok="$_ecr_cur (reset)"
            cp_total_tokens=$((cp_total_tokens + _ecr_cur))
            ;;
        frozen)
            _ecr_tok="$_ecr_cur (+0)"
            cp_total_tokens=$((cp_total_tokens + _ecr_cur))
            cp_have_delta=1
            ;;
    esac

    # State cell — the load-bearing "needs attention" markers ride here (the
    # .ci/.review columns are near-always empty; nothing writes them). Priority:
    # BLOCKED (gate) > CI-failing > session-gone; else the plain .state token.
    if [ "$_ecr_blocking" = "true" ]; then
        _ecr_statecol="⚠ BLOCKED"
    elif [ "$_ecr_state" = "ci-failing" ]; then
        _ecr_statecol="⚠ CI"
    elif [ "${_ecr_tstate#container}" = "$_ecr_tstate" ] && [ "$_ecr_issue" != "?" ] && session_gone "$_ecr_issue"; then
        # The "$_ecr_issue" != "?" guard matters: a cache row missing .issue falls
        # back to the literal "?" above, and session_gone's glob `*" golem-? "*`
        # would treat "?" as a single-char wildcard (matching any live golem-N),
        # spuriously flagging the row ⚠ gone. An issue-less row can't be session-
        # checked, so it keeps its plain state instead.
        _ecr_statecol="⚠ gone"
    else
        _ecr_statecol="$_ecr_state"
    fi

    # Batch tally: shipped=merged; blocked=gate/blocked/ci-failing; live=rest.
    case "$_ecr_state" in
        merged) cp_shipped=$((cp_shipped + 1)) ;;
        *)
            if [ "$_ecr_blocking" = "true" ] || [ "$_ecr_state" = "blocked" ] || [ "$_ecr_state" = "ci-failing" ]; then
                cp_blocked=$((cp_blocked + 1))
            else
                cp_live=$((cp_live + 1))
            fi
            ;;
    esac

    # shellcheck disable=SC2059  # CHECKPOINT_ROW_FMT is a trusted constant format
    /usr/bin/printf "$CHECKPOINT_ROW_FMT" \
        "$_ecr_track" "$_ecr_g" "$_ecr_issue" "$_ecr_stage" "$_ecr_elapsed" \
        "$_ecr_tok" "$_ecr_pr" "$_ecr_ci" "$_ecr_review" "$_ecr_statecol"
}

# render_checkpoint [interval] — the compact per-track status+burn table + a
# batch-totals footer. Groups golem rows by track (joining each golem's .issue
# against tracks.json's lanes; no `track` field exists on the golem cache), then
# an untracked group for golems in no lane — so a standalone/pool run with no
# tracks.json renders every golem in the single untracked group (nlanes=0 → the
# lane loop is skipped). [interval] is the resolved --watch cadence in seconds;
# present only in watch mode, where the aggregate token rate (Δ/interval) is
# honest. Returns 0, never exits, so the --watch loop can re-invoke it.
render_checkpoint() {
    _rc_interval="${1:-}"
    collect_cache
    cp_sessions="$( (tmux ls 2>/dev/null | /usr/bin/grep -oE '^golem-[0-9]+' | /usr/bin/tr '\n' ' ') || true)"

    if [ "${#cache[@]}" -eq 0 ] && [ -z "$cp_sessions" ] && [ ! -f "$pool" ]; then
        command echo "No active golems (no $status_dir/*.json, no golem-* tmux sessions)."
        return 0
    fi

    # jq-gated: every column is a JSON read (mirrors the verbose token section).
    if ! command -v jq >/dev/null 2>&1; then
        command echo "golem-status --checkpoint: jq not found on PATH — cannot render checkpoint table" >&2
        return 0
    fi

    # Pool header (same shape as render_status).
    if [ -f "$pool" ]; then
        jq -r '"Pool: size=\(.size // "-")  slots=\((.slots // []) | length)/\(.size // "-")  backlog=\(.backlog_depth // "-")  queue=\(.queue // .accepting // "-")"' \
            "$pool" 2>/dev/null || command echo "Pool: (unreadable $pool)"
        command echo ""
    fi

    command echo "STATUS CHECKPOINT (per-track; burn Δ since last sweep):"
    # shellcheck disable=SC2059  # CHECKPOINT_ROW_FMT is a trusted constant format
    /usr/bin/printf "$CHECKPOINT_ROW_FMT" \
        TRACK GOLEM ISSUE STAGE ELAPSED "TOKENS(Δ)" PR CI REVIEW STATE

    # Batch accumulators (mutated by emit_checkpoint_row, read by the footer).
    cp_total_tokens=0
    cp_total_delta=0
    cp_have_delta=0
    cp_live=0
    cp_blocked=0
    cp_shipped=0

    # Pre-read each cache file's .issue once, aligned to cache[] by index (an
    # indexed array — bash-3.2 has no associative arrays). Used for the lane join
    # and the untracked pass without re-reading the JSON per lane.
    _rc_n=${#cache[@]}
    cache_issue=()
    _rc_i=0
    while [ "$_rc_i" -lt "$_rc_n" ]; do
        cache_issue[$_rc_i]="$(jq -r '.issue // empty' "${cache[$_rc_i]}" 2>/dev/null)"
        _rc_i=$((_rc_i + 1))
    done

    # Space-padded set of issues already emitted under a lane (so the untracked
    # pass skips them). Leading+trailing space so the ` $iss ` glob is exact.
    claimed=" "

    # Track lanes from tracks.json (absent/empty → nlanes=0 → skip straight to the
    # untracked group, which is the standalone/pool behavior).
    _rc_nlanes=0
    if [ -f "$tracks" ]; then
        _rc_nlanes="$(jq -r '.tracks | length' "$tracks" 2>/dev/null || command echo 0)"
        case "$_rc_nlanes" in
            '' | *[!0-9]*) _rc_nlanes=0 ;;
        esac
    fi

    _rc_lane=0
    while [ "$_rc_lane" -lt "$_rc_nlanes" ]; do
        _rc_laneno="$(jq -r ".tracks[$_rc_lane].lane // $_rc_lane" "$tracks" 2>/dev/null)"
        # This lane's issues as a space-padded string for the membership glob.
        _rc_laneissues=" $(jq -r ".tracks[$_rc_lane].issues[]?" "$tracks" 2>/dev/null | /usr/bin/tr '\n' ' ')"
        _rc_i=0
        while [ "$_rc_i" -lt "$_rc_n" ]; do
            _rc_iss="${cache_issue[$_rc_i]}"
            if [ -n "$_rc_iss" ]; then
                # Skip an issue an earlier lane already claimed — a malformed
                # tracks.json listing the same issue under two lanes would
                # otherwise emit the row (and double-count its tokens/Δ/tally)
                # once per lane. Same guard the untracked pass uses below.
                case "$claimed" in
                    *" $_rc_iss "*)
                        _rc_i=$((_rc_i + 1))
                        continue
                        ;;
                esac
                # Pad exactly " $iss " so 4 does not match 42.
                case "$_rc_laneissues " in
                    *" $_rc_iss "*)
                        emit_checkpoint_row "${cache[$_rc_i]}" "L$_rc_laneno"
                        claimed="${claimed}${_rc_iss} "
                        ;;
                esac
            fi
            _rc_i=$((_rc_i + 1))
        done
        _rc_lane=$((_rc_lane + 1))
    done

    # Untracked pass: any cache golem no lane claimed (also covers issue-less rows).
    _rc_i=0
    while [ "$_rc_i" -lt "$_rc_n" ]; do
        _rc_iss="${cache_issue[$_rc_i]}"
        _rc_is_claimed=0
        if [ -n "$_rc_iss" ]; then
            case "$claimed" in
                *" $_rc_iss "*) _rc_is_claimed=1 ;;
            esac
        fi
        if [ "$_rc_is_claimed" -eq 0 ]; then
            emit_checkpoint_row "${cache[$_rc_i]}" "—"
        fi
        _rc_i=$((_rc_i + 1))
    done

    # Live sessions with no cache file yet (mirror render_status's tail rows).
    for sess in $cp_sessions; do
        n="${sess#golem-}"
        if [ ! -e "$status_dir/golem-$n.json" ] && [ ! -e "$status_dir/issue-$n.json" ]; then
            # shellcheck disable=SC2059  # CHECKPOINT_ROW_FMT is a trusted constant format
            /usr/bin/printf "$CHECKPOINT_ROW_FMT" \
                "—" "$sess" "$n" "(live)" "—" "—" "—" "—" "—" "(live)"
        fi
    done

    command echo ""
    command echo "  PR/CI/Review are cache mirrors; authoritative CI/review live in the monitor PR poll (pr_status[])."

    # Aggregate rate — Δ/interval, WATCH mode only (an interval was resolved) and
    # only once a prior sweep exists (cp_have_delta); "—" otherwise, so a one-shot
    # render and the first watch iteration never fake a burn rate.
    _rc_rate="—"
    if [ -n "$_rc_interval" ] && [ "$cp_have_delta" -eq 1 ] && [ "$_rc_interval" -gt 0 ] 2>/dev/null; then
        _rc_rate="$((cp_total_delta * 3600 / _rc_interval))/hr"
    fi
    /usr/bin/printf 'BATCH: tokens=%s  Δ=%s  rate=%s  live=%s  blocked=%s  shipped=%s\n' \
        "$cp_total_tokens" "$cp_total_delta" "$_rc_rate" "$cp_live" "$cp_blocked" "$cp_shipped"

    return 0
}

# resolve_interval <level> — the --watch cadence in seconds, applying the
# precedence: an explicit --interval already short-circuits before this is
# called; here GOLEM_SWEEP_INTERVAL (env override) wins, else the level-scaled
# default from autonomy-resolve.sh (single source of truth for per-level
# dispositions, #190/#304). A non-numeric override or an unresolvable resolver
# value fails loud rather than silently spinning at a bogus cadence.
resolve_interval() {
    _ri_level="$1"
    if [ -n "${GOLEM_SWEEP_INTERVAL:-}" ]; then
        command printf '%s' "$GOLEM_SWEEP_INTERVAL"
        return 0
    fi
    _ri_out="$("$SCRIPT_DIR/autonomy-resolve.sh" sweep-interval --level "$_ri_level" 2>/dev/null || true)"
    _ri_secs="${_ri_out#sweep_interval_seconds=}"
    if [ -z "$_ri_secs" ] || [ "$_ri_secs" = "$_ri_out" ]; then
        command echo "golem-status: could not resolve sweep interval for level '$_ri_level'" >&2
        return 1
    fi
    command printf '%s' "$_ri_secs"
}

# is_positive_int <value> — 0 if value is a positive integer, else 1.
is_positive_int() {
    case "$1" in
        "" | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# --- drive ------------------------------------------------------------------
# Default (no args): one-shot render, exit. --watch: re-render on the resolved
# interval until the operator kills it — the orchestrator's Phase M default-on
# status sweep (#304). The loop carries no empty-poll exit (mirrors
# golem-gate-watch.sh --stream*): a transient zero-golem handoff window renders
# "No active golems" and keeps sweeping rather than terminating.
#
# Main-guard so the tests can SOURCE this file to unit-test the render helpers
# (_gate_age_suffix, _iso_to_epoch, …) in isolation without running the drive
# below (mirrors golem-resolve.sh:120 / golem-gate-watch.sh:842). When the file
# is executed, `${BASH_SOURCE[0]}` == `$0`, the guard is false, and the drive
# runs byte-identically; when it is sourced they differ and we return first.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi
watch=0
checkpoint=0
level=1
interval=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --watch) watch=1 ;;
        --checkpoint) checkpoint=1 ;;
        --level)
            [ "$#" -ge 2 ] || {
                command echo "golem-status: --level needs a value (1-4)" >&2
                exit 2
            }
            level="$2"
            shift
            ;;
        --interval)
            [ "$#" -ge 2 ] || {
                command echo "golem-status: --interval needs a value (seconds)" >&2
                exit 2
            }
            interval="$2"
            shift
            ;;
        *)
            command echo "golem-status: unknown argument '$1' (want [--checkpoint] [--watch] [--level N] [--interval S])" >&2
            exit 2
            ;;
    esac
    shift
done

case "$level" in
    1 | 2 | 3 | 4) ;;
    *)
        command echo "golem-status: --level must be 1-4, got '$level'" >&2
        exit 2
        ;;
esac

if [ -n "$interval" ] && ! is_positive_int "$interval"; then
    command echo "golem-status: --interval must be a positive integer, got '$interval'" >&2
    exit 2
fi

# Pick the render function once — compact checkpoint (#283) or verbose — so the
# one-shot and watch branches invoke the same choice. A command-NAME variable
# (not a bash-4 nameref) keeps this bash-3.2 clean. render_status ignores a
# trailing arg; render_checkpoint reads it as the resolved sweep interval (for
# the honest aggregate rate) — passed only in watch mode.
render_fn="render_status"
[ "$checkpoint" -eq 1 ] && render_fn="render_checkpoint"

if [ "$watch" -eq 0 ]; then
    # One-shot: no interval → render_checkpoint prints rate=— (no prior sweep).
    "$render_fn"
    exit 0
fi

# --watch: resolve the cadence once (interval > env > level default), then loop.
if [ -z "$interval" ]; then
    interval="$(resolve_interval "$level")" || exit 1
fi
if ! is_positive_int "$interval"; then
    command echo "golem-status: resolved sweep interval is not a positive integer: '$interval'" >&2
    exit 2
fi

command echo "Status sweep every ${interval}s (level $level). Ctrl-C to stop." >&2
while :; do
    "$render_fn" "$interval"
    command echo ""
    /usr/bin/sleep "$interval"
done
