#!/usr/bin/env bash
# golem-status-signals.sh — the two PER-GOLEM SIGNAL families read and rendered
# by golem-status.sh, extracted as a sourced fragment (issue #800).
#
# Sourced, not executed. Source it near the top of golem-status.sh, after
# config.sh and the $scrape / $ctxbudget const assignments and ABOVE both render
# functions and the main-guard:
#
#     # shellcheck source=./golem-status-signals.sh
#     . "$SCRIPT_DIR/golem-status-signals.sh"
#
# WHY BOTH FAMILIES, AND WHY TOGETHER. Each family is a cache READER plus its
# RENDER half, and the two are structurally parallel:
#
#   scrape_and_persist_tokens  + render_token_block           (#371/#390)
#   read_context_budget        + render_context_budget_block  (#784)
#
# They answer opposite questions off the same transcript — "is this golem still
# producing work?" (a CUMULATIVE output counter, whose FREEZE is the interesting
# event) versus "is this golem's context too big to keep working in?" (a POINT
# reading of the newest request's input side, whose GROWTH is the interesting
# event). That symmetry is the whole reason they live in ONE file: extracting
# only the newer half would scatter two parallel signals across two files and
# make the code less coherent while making a line count look better. Whichever
# signal is added next belongs here too.
#
# THE INVARIANTS THIS FILE CARRIES (do not weaken them when editing):
#
#   * scrape_and_persist_tokens is the SOLE WRITER of a golem's
#     top_level_tokens / top_level_tokens_at cache fields (#371), and must run
#     AT MOST ONCE PER SWEEP — a second call in the same sweep re-baselines the
#     frozen-since anchor and resets the checkpoint burn Δ. This is why
#     golem-status.sh's `--checkpoint` and verbose renders are mutually
#     exclusive (one `render_fn`, chosen once) rather than additive.
#   * read_context_budget is deliberately READ-ONLY and holds no "frozen since"
#     anchor: a context size is a point reading, not a cumulative counter, so it
#     needs no history. Do NOT "harmonize" the siblings by giving it
#     persistence — that is what makes it safe to call from both render paths.
#   * The _rcb_* / _sapt_* locals are function-scoped BY PREFIX CONVENTION, not
#     by `local`. Adding `local` is the tempting tidy-up; the multi-golem case in
#     tests/golem-scripts/85-context-budget.sh exists precisely because a stale
#     value leaking between loop iterations is invisible with one golem.
#
# PARENT-OWNED STATE. This fragment deliberately reads state the sourcing script
# owns rather than re-deriving it: the `cache` array (populated by
# collect_cache, which stays in golem-status.sh because render_checkpoint shares
# it), $root, $status_dir, $scrape, $ctxbudget, $GOLEM_WORKTREE_DIR, $RM, and the
# time helpers _now_iso / _iso_to_epoch / _fmt_dur. Same coupling the sibling
# sourced fragments in this directory accept (bounded-run.sh, threshold-check.sh)
# — sourcing is what makes it a fragment rather than a script.
#
# bash-3.2 clean, per CLAUDE.md § Runtime policy.

# The parent-owned state listed above is assigned in golem-status.sh, which the
# linter cannot see from here — it analyses one file at a time. Suppressed
# file-wide rather than per-read: every one of these is the same fact, and a
# per-line directive would have to be re-applied by anyone moving a line.
# (Do not start a comment line here with the linter's own name — it parses such
# a line as a malformed directive.)
# shellcheck disable=SC2154  # root/status_dir/scrape/ctxbudget/cache are assigned by the sourcing script

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
        _fp_now="$("$DATE" -u +%s)"
        _fp_d=$((_fp_now - _fp_epoch))
        [ "$_fp_d" -lt 0 ] && _fp_d=0
        command echo "$_fp_cur tokens, frozen $(_fmt_dur "$_fp_d")"
    else
        command echo "$_fp_cur tokens, frozen since $_fp_at"
    fi
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
        command mv "$_sapt_tmp" "$_sapt_f" 2>/dev/null || "$RM" -f "$_sapt_tmp"
    else
        [ -n "$_sapt_tmp" ] && "$RM" -f "$_sapt_tmp"
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

# read_context_budget <cache-file> — the CURRENT context size + verdict for one
# golem (issue #784), as a TAB tuple:
#
#   state ∈ container | unknown | ok | advise | handoff
#   ctx   = the context-size reading in tokens (empty for container/unknown)
#   pct   = ctx as a whole-number percent of the threshold (empty likewise)
#
# READ-ONLY, unlike its scrape_and_persist_tokens sibling above. There is no
# "frozen since" anchor to maintain because a context size is a POINT reading of
# the newest request, not a cumulative counter: the question is "how big is it
# now", which needs no history and so needs no persisted state. That also means
# this helper is safe to call from both render paths without the double-sweep
# hazard that forces the token persist to run exactly once per sweep.
#
# Mode 3 (container) golems return `container`: context-budget.sh reads a
# host-side transcript, and a container golem's transcript lives inside the
# container. Unlike the token signal there is no POSTed equivalent to fall back
# on, so this renders a plain not-available note rather than inventing one — the
# alternative would be a blank where an operator expects a number, which reads as
# "fine" (see #390 for the token half's history here).
read_context_budget() {
    _rcb_f="$1"
    _rcb_ctr="$(jq -r '.container // empty' "$_rcb_f" 2>/dev/null)"
    if [ -n "$_rcb_ctr" ]; then
        command printf 'container\t\t\n'
        return 0
    fi
    _rcb_issue="$(jq -r '.issue // empty' "$_rcb_f" 2>/dev/null)"
    # NUMERIC-GUARD .issue before it builds a path. The cache is a co-written JSON
    # file, so every field read from it is treated as untrusted here — the same
    # defense-in-depth the ELAPSED computation below applies to this very field
    # (see its `case "$_ecr_issue"` guard). Without it a corrupted or hand-edited
    # `.issue` carrying `../` would build a worktree path outside .worktrees/,
    # which context-budget.sh then turns into a projects-dir slug and probes. A
    # non-numeric value degrades to `unknown`, which is the honest answer.
    case "$_rcb_issue" in
        '' | *[!0-9]*) _rcb_issue="" ;;
    esac
    _rcb_out=""
    if [ -n "$_rcb_issue" ] && [ -x "$ctxbudget" ]; then
        _rcb_wt="$root/$GOLEM_WORKTREE_DIR/issue-$_rcb_issue"
        # `|| true` absorbs the script's fail-loud non-zero exits (2 no
        # transcript / 3 no jq) into the `unknown` render below. Absorbing the
        # STATUS is correct here — a status sweep must not die because one golem
        # has no transcript yet — but the stderr MESSAGE is redirected in the same
        # breath, deliberately: without the 2>/dev/null it would interleave raw
        # into the rendered table (the redirect-order-leaks-the-diagnostic class).
        _rcb_out="$("$ctxbudget" check "$_rcb_wt" 2>/dev/null || true)"
    fi
    if [ -z "$_rcb_out" ]; then
        command printf 'unknown\t\t\n'
        return 0
    fi
    # Parse the `key=value` lines. Field-scoped greps rather than one loose match
    # so a value can never be picked up from the wrong key.
    _rcb_ctx="$(command printf '%s\n' "$_rcb_out" | command sed -n 's/^context_tokens=//p')"
    _rcb_pct="$(command printf '%s\n' "$_rcb_out" | command sed -n 's/^pct_of_threshold=//p')"
    _rcb_v="$(command printf '%s\n' "$_rcb_out" | command sed -n 's/^verdict=//p')"
    # Numeric-guard the reading and allowlist the verdict before either reaches
    # the render. The script is trusted, but a truncated/partial capture must
    # degrade to `unknown` rather than print a half-parsed row that reads as a
    # real measurement.
    case "$_rcb_ctx" in
        '' | *[!0-9]*)
            command printf 'unknown\t\t\n'
            return 0
            ;;
    esac
    case "$_rcb_pct" in
        '' | *[!0-9]*)
            command printf 'unknown\t\t\n'
            return 0
            ;;
    esac
    case "$_rcb_v" in
        ok | advise | handoff) ;;
        *)
            command printf 'unknown\t\t\n'
            return 0
            ;;
    esac
    command printf '%s\t%s\t%s\n' "$_rcb_v" "$_rcb_ctx" "$_rcb_pct"
}

# render_token_block — the TOP-LEVEL TOKENS section of the verbose render, the
# display half of scrape_and_persist_tokens above. Reads the parent's `cache`
# array; emits nothing when jq is absent or no golem is cached (the section is
# omitted rather than rendered empty).
#
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
render_token_block() {
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
}

# render_context_budget_block — the CONTEXT BUDGET section of the verbose
# render, the display half of read_context_budget above. Same cache/jq gating as
# render_token_block, and deliberately emitted immediately after it: the two
# sections read as a pair.
#
# CONTEXT BUDGET (issue #784) — the bounded-session-length signal. Distinct
# from the TOP-LEVEL TOKENS block above and deliberately adjacent to it: that
# one answers "is this golem still producing work?" (a CUMULATIVE output
# counter, whose freeze is the interesting event), this one answers "is this
# golem's context too big to keep working in?" (a POINT reading of the newest
# request's input side, whose GROWTH is the interesting event). Same
# transcript, opposite questions — which is why they are two scripts and two
# blocks rather than one merged row that would blur them.
render_context_budget_block() {
    if command -v jq >/dev/null 2>&1 && [ "${#cache[@]}" -gt 0 ]; then
        command echo ""
        command echo "CONTEXT BUDGET (session-length signal — #784 handoff threshold):"
        for f in "${cache[@]}"; do
            g="$(jq -r '.golem // "?"' "$f" 2>/dev/null)"
            IFS=$'\t' read -r cbstate cbctx cbpct < <(read_context_budget "$f")
            case "$cbstate" in
                container)
                    command echo "  $g — context not readable (container golem)"
                    ;;
                unknown)
                    command echo "  $g — context unknown (no transcript)"
                    ;;
                ok)
                    command echo "  $g — ${cbctx} tokens (${cbpct}% of threshold)"
                    ;;
                advise)
                    # Advisory only, at every level and in every mode: an
                    # interactive session is NEVER force-cycled (#784 AC5), and a
                    # golem uses this to prefer finishing its current step over
                    # starting a new one.
                    command echo "  $g — ${cbctx} tokens (${cbpct}% of threshold — approaching handoff)"
                    ;;
                handoff)
                    command echo "  $g — ${cbctx} tokens (${cbpct}% of threshold — HANDOFF DUE)"
                    ;;
            esac
        done
    fi
}
