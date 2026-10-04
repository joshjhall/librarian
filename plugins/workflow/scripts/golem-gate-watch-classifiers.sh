#!/usr/bin/env bash
# golem-gate-watch-classifiers.sh — the PANE CLASSIFIERS of golem-gate-watch.sh,
# extracted as a sourced fragment (issue #1109).
#
# Sourced, not executed. golem-gate-watch.sh sources it IN PLACE — between
# emit_transitions and panes_snapshot, exactly where these lines used to sit —
# so the top-level consts below (MULTI_Q_RE, OWN_WORK_RE, PROMPT_GLYPH,
# PROMPT_NBSP) are assigned in the same order as before the split:
#
#     # shellcheck source=./golem-gate-watch-classifiers.sh
#     . "$SCRIPT_DIR/golem-gate-watch-classifiers.sh"
#
# WHY THIS CLUSTER. These are pure text predicates over a captured pane — the
# overlay, fork, multi-question-form, own-work, prompt-line, turn-end and
# API-error reads — and they are what every footer redesign touches. The
# channels that CALL them (panes_snapshot, confirm_turn_end, pane_liveness_class,
# liveness_snapshot) stay in golem-gate-watch.sh. Do not source this file on its
# own: it reads the parent's portable tool paths ($GREP, $HEAD, $TAIL, $TR), its
# pane tunables ($pane_footer_lines, $pane_error_lines, $pane_scrollback_lines),
# $SCRIPT_DIR, and config.sh's / bounded-run.sh's functions. Callers that need a
# matcher (golem-handoff-relaunch.sh, golem-mode-check.sh) source
# golem-gate-watch.sh, which is main-guarded and pulls this in.
#
# Function bodies moved byte-identical; split-verify.sh pinned the move.
# shellcheck disable=SC2154  # tool paths + pane tunables are assigned by golem-gate-watch.sh

# Modal prompt-overlay patterns. A live golem at a permission/plan gate — or an
# AskUserQuestion escalation fork (#257) — paints one of these over its
# alt-screen; matching them is reliable (unlike scraping scrolling work output).
# Extend these lists as new prompt shapes appear. pane_is_turn_end (#447) is the
# odd one out — NOT a modal overlay but a turn-ended/idle-at-prompt footer read —
# and so runs as panes_snapshot's LAST-RESORT branch, after all three modals.
#
# Like pane_is_fork and pane_liveness_class, both matchers are ANCHORED to the
# pane's FOOTER region (last $pane_footer_lines lines, where a modal overlay
# renders) — NOT the whole scrollback — the #246 protection (#452). The trigger
# phrases (`Here is Claude's plan`, `Do you want to proceed`, …) appear in this
# script's own comments, in tests/golem-gate-watch.sh, and in golem work output;
# a golem editing/`cat`-ing such a file would otherwise self-trip a false
# plan/permission gate push.
pane_is_plan_gate() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Ready to code"*) return 0 ;;
        *"ready to code"*) return 0 ;;
        *"Would you like to proceed"*) return 0 ;;
        *"Here is Claude's plan"*) return 0 ;;
        *"Yes, and use auto mode"*) return 0 ;;
    esac
    return 1
}

# Generic permission-decision overlay (Bash/Edit/push/PR `ask` rules etc.).
# Footer-anchored for the same #246/#452 reason as pane_is_plan_gate above.
pane_is_gate() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Do you want to proceed"*) return 0 ;;
    esac
    return 1
}

# AskUserQuestion escalation-fork overlay (issue #257). A golem parked at a
# numbered architectural/scoping decision — an ESCALATION gate per
# `orchestrate/autonomy-levels.md`, human at L1–L3 — paints a selection modal
# whose stable signature is the footer line `Enter to select` (rendered with
# `↑/↓ to navigate` / `Tab/Arrow keys to navigate`). This overlay matches
# neither pane_is_plan_gate nor pane_is_gate, so before this matcher a fork was
# silently missed by the pane channel.
#
# `Enter to select` is the generic Claude Code selection-modal footer, not unique
# to AskUserQuestion, so this is a BEST-EFFORT label of last resort: run only
# AFTER the plan-gate and generic-gate matchers, it names an overlay they didn't
# recognize an "escalation" on the assumption it is a fork. That is right for a
# real AskUserQuestion fork and errs toward surfacing (an unrecognized overlay is
# reported rather than dropped); the tradeoff is that a plan/permission overlay
# whose exact wording drifts out of those matchers could surface here mislabelled
# rather than silently missed. Two guards keep the footer phrase from
# over-matching:
#   1. panes_snapshot() checks pane_is_plan_gate AND pane_is_gate FIRST — the
#      fork is the last-resort branch, so a plan overlay (which may share the
#      `Yes, and use auto mode` line and an `Enter to select` footer) or a
#      routine permission gate (whose own selection menu may paint the same
#      footer) is classified as itself, never downgraded to an escalation.
#   2. The match is ANCHORED to the pane's FOOTER region (last $pane_footer_lines
#      lines, where the modal footer renders) — NOT the whole scrollback — the
#      same protection pane_liveness_class uses for #246. `Enter to select` now
#      appears in this script's own comments and in tests/golem-gate-watch.sh, so
#      a golem cat-ing/grepping those files would otherwise self-trip the matcher
#      into a false `escalation` notification.
pane_is_fork() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"Enter to select"*) return 0 ;;
    esac
    return 1
}

# Multi-question AskUserQuestion form (issue #467). A golem raising 2+ questions
# in ONE prompt paints a TABBED widget — a per-question tab bar with `☐`/`☒`
# checkboxes and a trailing `✔ Submit` tab — over the same `Enter to select`
# footer a single-question fork paints. It is therefore a strictly MORE SPECIFIC
# fork, and panes_snapshot() runs it BEFORE pane_is_fork so the general branch
# cannot shadow it (the same precedence discipline plan-gate/generic-gate already
# use, and the same reason pane_is_api_error runs before pane_is_turn_end).
#
# WHY IT EARNS ITS OWN CLASS. This widget takes DIFFERENT keystrokes from the
# single-question prompt, and the documented brokers fail on it in ways that
# RESOLVE THE GATE WRONG rather than merely failing:
#   - The plan-gate broker (`tmux send-keys -t golem-{N} 1 Enter`) assumes one
#     question. Observed live: a digit did nothing in one incident and landed on
#     the WRONG question in another (the widget needs `↑/↓`+`Enter`), and after
#     an out-of-order answer `Tab` cycled between the answered question and the
#     Submit screen without ever reaching the still-`☐` one. The review screen
#     then offered `Submit` with a question unanswered — one stray Enter submits
#     a HALF-ANSWERED form the golem acts on as the operator's decision.
#   - The inbox broker (`golem-inbox.sh answer <golem> <gate-id> <option>`)
#     carries ONE option per gate-id; a form has no single answer. (And a
#     plan-time fork is not inbox-routed at all — the data-only invariant, #227.)
# A form IS brokerable — answer forward-order with `↑/↓`+`Enter` and submit only
# at all-`☒`, falling back to cancel-then-text-directive when an earlier answer
# needs revising (orchestrate/monitor-protocol.md). But since the keystrokes
# differ by widget, a broker must BRANCH on single-vs-multi, and that branch is
# what this matcher exists to enable — see the message const above.
#
# DETECTION FAILED BEFORE KEYSTROKES DID — the reason this is not footer-anchored
# like its siblings. The `☐/☒` tab bar renders ABOVE the footer, and in a live
# incident the first capture-pane showed only ONE of a form's TWO questions (the
# second had scrolled out of view), so an orchestrator reading the footer alone
# would broker a two-question form believing it single. So this matcher follows
# the pane_is_api_error shape instead: a footer-anchored VETO plus a wider
# content scan. It deliberately reuses $pane_error_lines rather than adding a
# knob — a new env var would need a README env-table row and would otherwise
# trip tests/lint-env-var-drift.sh.
#
# TWO SIGNALS ARE REQUIRED, and neither alone is sufficient:
#   footer `Enter to select` — without it this is not a selection modal at all;
#   a widget glyph in the wider window — without it this is the ORDINARY
#   single-question fork that pane_is_fork already handles.
#
# THE GLYPH SIGNAL IS LINE-ANCHORED, and that is load-bearing rather than
# cosmetic. The two signals are independent substring tests over different
# windows, so nothing ties the glyph to the widget that painted the footer: with
# a bare `☐|☒|✔ Submit` scan, an ORDINARY single-question fork preceded within 40
# lines by unrelated text containing a checkbox misclassifies as a form. That is
# not hypothetical — the prose describing this very feature
# (escalation-protocol.md, monitor-protocol.md, this comment block, and the test
# fixtures) all contain those glyphs literally, so a golem reading any of them
# while at a normal fork would self-trip. A conjunction of two independently
# satisfiable signals is not a self-trip guard, however it is described.
#
# What separates them is SHAPE, not vocabulary: a real tab bar is its own short
# line STARTING with a checkbox (optionally behind the `←` scroll arrow), while
# prose carries the same glyphs mid-sentence. Anchoring to the line start rejects
# every prose form above while still matching the live widget — and the
# unanswered-questions warning gets the same treatment for the same reason.
# The `esc to interrupt` veto runs first as a further guard: a golem actively
# WORKING is never at a gate, whatever its scrollback holds.
#
# LINE-ANCHORING ALONE DOES NOT SEPARATE SINGLE FROM MULTI (#986). The anchor
# above answers "is this a widget or prose?", but the question this matcher
# exists to answer is "one question or several?" — and a SINGLE-question
# AskUserQuestion also paints a line starting with `☐`. Observed live (golem-699):
# a one-question form labelled multi. What actually distinguishes the widgets is
# how many tabs the bar carries, and whether it has a `✔ Submit` tab at all, so
# the checkbox arm requires a SECOND signal later on the SAME line: another
# checkbox, or `✔ Submit`.
#
# BOTH SIGNALS ARE NEEDED, and the conjunct must be same-LINE. A two-question bar
# scrolled behind the `←` arrow may show only one checkbox — but it still carries
# `✔ Submit`. And the second signal cannot be sought anywhere in the window: the
# window-wide scan is exactly what let prose and a single-question widget satisfy
# the test independently (the #467 lesson, arriving one level down).
#
# The third arm covers the extreme-scroll rendering where NO checkbox is visible
# and only `✔ Submit` remains. The `←` scroll arrow is OPTIONAL here: a bar
# scrolled to its last tab may render without one (nothing further right to
# scroll to), and requiring it would silently miss that pane — the exact
# false-negative shape this matcher exists to prevent. A line starting with `✔`
# (arrow or not) is a shape prose never takes — measured zero occurrences across
# plugins/ tests/ docs/ README.md — so this arm needs no second conjunct.
#
# `Submit` IS WORD-ANCHORED at both sites, and dropping the arrow is exactly why.
# The tab label is the literal word `Submit`; without the trailing
# `([^[:alnum:]]|$)` guard, a progress line like `✔ Submitted 3 files` or
# `✔ Submitting…` satisfies the arm. That was unreachable while the `←` was
# mandatory (measured old=0), so the loosening above is what makes the guard
# load-bearing — a widening that needs its own boundary, not a free one. BSD-safe:
# a bracket negation, never `\b`.
#
# THE FALSE NEGATIVE WAS FIXED CAPTURE-SIDE, NOT HERE (#1010). A real
# two-question form could go UNLABELLED because `tmux capture-pane -p` returns
# only the VISIBLE pane: a form whose option text overflows scrolls its tab bar
# off the TOP, measured absent in 0-of-229 live captures (#986) and reproduced in
# 152-of-152 paired captures (#1010). No change to this regex could ever fix
# that — a glyph that was never captured cannot be matched by any pattern — so
# the fix is in Guard 3 below, which takes its own wider `-S` read. Do not "fix"
# anything here by loosening the arms; the arms were never the defect.
#
# WHICH MAKES THE `^` ANCHORS ABOVE LOAD-BEARING IN A NEW WAY. Before #1010 the
# glyph scan saw only the visible pane, so the prose self-trip it guarded against
# had to be on screen. It now reads SCROLLBACK, where a golem's recently-read
# file content lives — including this very comment block, the skills prose, and
# the test fixtures. The anchoring is what keeps that from reading as a widget,
# and it is measured: the live capture in
# docs/verification/multi-question-capture-scrollback-e2e-1010.md carries
# glyph-bearing prose on two lines directly above the genuine bar, and only the
# bar matches. Removing an anchor turns
# test_pane_multi_question_form_scrolled_off_top_prose red.
MULTI_Q_RE='^[[:space:]]*(←[[:space:]]*)?(☐|☒).*(☐|☒|✔[[:space:]]*Submit([^[:alnum:]]|$))|^[[:space:]]*(←[[:space:]]*)?✔[[:space:]]*Submit([^[:alnum:]]|$)|^[[:space:]]*⚠[^`]*not answered all'
# pane_is_multi_question_form <pane-text> [<session>]
#
# The optional SECOND argument is what closes #1010, and it is deliberately
# optional. Given a session name, Guard 3 — and only Guard 3 — reads its own
# wider `capture-pane -S` scrollback; Guards 1 and 2 go on reading the caller's
# already-captured VISIBLE text, as do all eight sibling matchers. So the other
# matchers are fed bytes identical to before this existed, and their #246/#452
# anchoring is not loosened by one character.
#
# WHY NOT WIDEN THE SHARED CAPTURE. Nine matchers share it. Handing them all
# scrollback makes every trigger phrase they key on matchable in arbitrary file
# content a golem happens to be reading — the #246/#452 self-trip class this repo
# has hit repeatedly. This file's own comments already record an earlier proposal
# to change the shared capture being rejected on exactly those grounds, with the
# template followed here: "take a separate local read and feed the matchers that"
# (see pane_suggestion_suffix). #1010 chose that template over the one-line `-S`.
#
# THE CAPTURE DEPTH AND THE SCAN WINDOW ARE THE SAME NUMBER BY CONSTRUCTION: the
# read asks for $pane_scrollback_lines and the scan covers all of what comes
# back. There is no second knob to widen and forget, which is the drift that
# makes a widened window buy nothing.
#
# TWO READS, TWO INSTANTS, and a STALE-BAR window. Guards 1 and 2 read the
# caller's already-captured text; Guard 3 re-reads the live pane a moment later,
# so the two can observe different screen states. Accepted rather than closed by
# capturing scrollback once in panes_snapshot, because that would hand the wider
# text to the CALLER — one refactor away from feeding it to the other eight
# matchers, which is the whole thing this design exists to avoid. Same shape as
# pane_suggestion_suffix's documented non-atomicity, one matcher over.
#
# BE PRECISE ABOUT THE DIRECTION, because the obvious claim is FALSE. An earlier
# draft of this comment said the divergence "can only lose a detection, never
# invent one". Measured, it can invent one: a form the golem ALREADY answered
# leaves its tab bar in scrollback, so a later ORDINARY fork whose footer passes
# Guards 1-2 matches that stale bar and is labelled a form. Nothing in the two
# reads ties the bar to the widget painting the footer — the same independence
# the #467 line-anchoring note describes, now reachable from further away.
#
# Left as-is deliberately, and it is the SAFE direction of the two. Labelling a
# fork as a form sends the operator to monitor-protocol.md's Path A — present the
# questions, then `↑/↓`+`Enter` per question. Checked against that protocol rather
# than assumed: Path A drives the SAME AskUserQuestion widget a single-question
# fork paints, and the digit the fork broker uses is only a shortcut for the same
# selection, so Path A resolves a one-question prompt correctly. The operator
# spends an extra keystroke and reads one question where the label implied
# several. The converse — a form labelled a fork, which is #1010
# itself — sends a digit into a two-question widget and submits it
# half-answered. A false form is a slower gate; a false fork is a wrong
# decision. Pinned by test_pane_multi_question_form_stale_bar_in_scrollback so
# the tradeoff is a recorded choice and not an unnoticed regression.
#
# FAIL-OPEN TO THE OLD CHECK, NEVER TO A FABRICATED FORM. No session, no tmux, or
# an empty capture all fall back to scanning the caller's visible text over
# $pane_error_lines — exactly today's behavior. A detector that could not look
# wider has learned nothing extra, so it reports what the narrow check reports;
# it cannot invent a match, and every text-only caller keeps working unchanged.
pane_is_multi_question_form() {
    local pane="$1" sess="${2:-}" footer window wide
    # Guard 1 (footer-anchored): an active run-spinner means the golem is working.
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$pane")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # Guard 2 (footer-anchored): it must be a selection modal.
    case "$footer" in
        *"Enter to select"*) ;;
        *) return 1 ;;
    esac
    # Guard 3 (wider window): the tab bar that makes it MULTI-question. It renders
    # ABOVE the footer and — the #1010 case — can sit above the visible pane
    # entirely, so prefer a scrollback read when the caller named a session.
    window=""
    if [ -n "$sess" ] && command -v tmux >/dev/null 2>&1; then
        wide="$(tmux capture-pane -p -S -"$pane_scrollback_lines" -t "$sess" 2>/dev/null || true)"
        [ -n "$wide" ] && window="$wide"
    fi
    # Fallback (and the no-session path): today's visible-pane tail.
    [ -z "$window" ] && window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    command printf '%s\n' "$window" | "$GREP" -qE "$MULTI_Q_RE"
}

# Own-work-pending guard for pane_is_turn_end / pane_liveness_class (issue #517). A
# golem parked BETWEEN turns waiting on its OWN background `Monitor` tasks — e.g.
# ship-issue's review-harness dynamic workflow plus a CI/force-push Monitor — has
# no `esc to interrupt` run-spinner (its turn technically ended; the monitors are
# what it awaits), so the idle-footer heuristic alone would classify it "idle at
# prompt awaiting input" and false-fire the #447 push (and the #38 liveness idle
# read). But it is NOT awaiting a human — it has a queued next action gated only on
# its own monitors. This predicate returns 0 when the footer advertises that
# pending own-work, so the caller can exclude it. The two-poll debounce
# (confirm_turn_end) does NOT separate this from a real idle: the footer holds this
# shape across many polls while the monitors run, confirming the false idle — the
# matcher itself must exclude.
#
# Matched with `grep -E` per line (NOT a bash case-glob): case-globs can't express a
# word boundary and match across embedded newlines, so an unanchored `*[0-9]
# monitor*` fires on prose like "Filed 3 monitor-related bugs" and an unbounded
# `*[0-9]/[0-9]*" agents done"*` matches a digit on one line and "agents done" on
# another (issue #517 cycle-2 review). Each signature is anchored to a STRONG,
# chrome-specific LEAD-IN — a footer glyph or a fixed phrase, never a lone digit or a
# bare comma — so ordinary completion prose that merely mentions these words does NOT
# suppress a genuine idle (that would itself be the #517 false-negative):
#   `· N monitor(s)` OR `N shell, N monitor(s)`  the real monitor-count footer chrome
#                               — the count must follow the `·` bullet separator or
#                               the `N shell,` token, NOT any comma (cycle-3 review:
#                               a bare comma matches ordinary prose like "he noted, 4
#                               monitors flagged"). Covers `N monitor still running`
#                               and the `N monitors` plural.
#   `Waiting for … dynamic workflow` / `Waiting for … to finish`  the in-flight wait
#                               lines (ship-issue's review workflow and the CI/force-
#                               push Monitor). Anchored on the `Waiting for` prefix
#                               (the real signal), which also rules out prose like
#                               "the dynamic workflow finished" that has no prefix —
#                               and covers the issue's second `*to finish*` body
#                               pattern (e.g. "Waiting for the force-push … to finish").
#   `N/M agents done`           the `next-issue-review … N/M agents done` harness
#                               footer (fraction immediately before the phrase).
#                               Kept for older Claude Code builds; newer ones render
#                               the row below instead.
#   `▰▰▰…▱▱ N/M`                the background-Workflow progress row that replaced
#                               `agents done` (#1089): `◯ <name>  <▰▱ bar>  N/M ·
#                               <elapsed> · ↓ <tokens>`. Anchored on 3+ bar glyphs
#                               IMMEDIATELY followed by the step fraction, so a bare
#                               `N/M` in prose (`PR #12/34`, `step 6/7`) cannot match.
#                               The glyphs are an ALTERNATION, not a `[▰▱]` bracket:
#                               each is 3 bytes, and under a byte locale (LC_ALL=C,
#                               GNU grep measured) a bracket degrades to a set of four
#                               bytes, so a 2-glyph `▰▰ 3/4` (6 bytes) clears `{3,}`.
# Same FOOTER anchoring as the sibling matchers (#246) — reuses the
# $pane_footer_lines window, no wider scan. This is the shared #517 chrome list;
# both the push matcher (pane_is_turn_end) and the pull classifier
# (pane_liveness_class) call it so their idle reads stay consistent.
OWN_WORK_RE='(·[[:space:]]*|[0-9]+[[:space:]]+shells?,[[:space:]]*)[0-9]+[[:space:]]+monitors?([[:space:]]|$)'
OWN_WORK_RE="${OWN_WORK_RE}|[Ww]aiting for.*dynamic workflow"
OWN_WORK_RE="${OWN_WORK_RE}|[Ww]aiting for.*to finish"
OWN_WORK_RE="${OWN_WORK_RE}|[0-9]+/[0-9]+[[:space:]]+agents[[:space:]]+done"
OWN_WORK_RE="${OWN_WORK_RE}|(▰|▱){3,}[[:space:]]+[0-9]+/[0-9]+"
pane_pending_own_work() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    command printf '%s\n' "$footer" | "$GREP" -qE "$OWN_WORK_RE"
}

# pane_registry_has_work <n> — the STRUCTURED backstop behind OWN_WORK_RE (#1097).
# Every footer redesign re-opened the false idle (#517/#890/#1089) because the
# text list can only match chrome someone has already seen; a background `git
# push` (`· 1 shell ·`) matched nothing, yet the golem had registered it. So the
# pane idle reads also ask the #949 registry, via the same observer call the
# transcript tier makes (`count --worktree`, which reaps dead-pid/aged-out
# entries). Returns 0 only for a positive count. Every failure — no worktree, the
# bound firing (124), no number — returns 1, so the caller keeps today's text-only
# verdict: the detector fails OPEN, never into a silent mute. Bounded because it
# runs once per idle-looking golem per poll.
pane_registry_has_work() {
    local root wt out
    root="$(repo_root 2>/dev/null || true)"
    wt="$root/$GOLEM_WORKTREE_DIR/issue-$1"
    [ -n "$root" ] && [ -d "$wt" ] && [ -x "$SCRIPT_DIR/golem-work.sh" ] || return 1
    if bounded_run_available; then
        out="$(bounded_run "${GOLEM_PANE_REGISTRY_TIMEOUT:-3}" \
            "$SCRIPT_DIR/golem-work.sh" count --worktree "$wt" 2>/dev/null)" || return 1
    else
        out="$("$SCRIPT_DIR/golem-work.sh" count --worktree "$wt" 2>/dev/null)" || return 1
    fi
    case "$out" in
        '' | *[!0-9]* | 0) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Prompt-line classifier (issue #977)
# ---------------------------------------------------------------------------
# Tells an autocomplete SUGGESTION at the input line from real QUEUED INPUT.
#
# The failure it closes: golem panes intermittently show a plausible next-step
# instruction sitting at the prompt that nobody typed — five instances across two
# orchestration runs. Every pane reader here saw it as indistinguishable from
# text the operator had queued, and two of the five were outward or
# gate-bypassing actions (`merge it once CI is green`; `push it` on a golem that
# had explicitly stated it was withholding the push), so an operator reading the
# pane would believe someone queued them.
#
# The submit half of that worry is now MEASURED AWAY (#995): `Enter` does not
# submit a suggestion, and the plan-gate broker's `1 Enter` submits the digit and
# DISCARDS the suggestion (a printable character replaces the ghost text rather
# than appending). So this classifier earns its keep on the READING side — what a
# human or a fleet reader believes the pane shows — not as a guard against a
# stray keystroke. Evidence: docs/verification/phantom-suggestion-e2e-995.md.
#
# THE DISCRIMINATOR IS THE DIM ATTRIBUTE, AND IT IS MEASURED
# ----------------------------------------------------------
# Claude Code renders the suggestion in SGR 2 (dim); real typed input carries no
# such run. Captured 2026-09-09 from two live golems and a disposable control
# session (escapes shown as ESC):
#
#   suggestion   ESC[39m<glyph> ESC[2mopen the PR once it lands ESC[0m
#   real input   ESC[39m<glyph> rebase onto main and push
#   empty        ESC[39m<glyph>
#
# WHY THIS TAKES A SESSION NAME, NOT PANE TEXT
# --------------------------------------------
# Every sibling matcher above takes already-captured pane TEXT. This one cannot:
# the callers capture with `tmux capture-pane -p`, which STRIPS the SGR run — the
# discriminating bytes never reach them. That stripping is exactly why the
# distinction was invisible. So this function takes a session name and runs its
# own `capture-pane -p -e`.
#
# It deliberately does NOT switch the shared capture to `-e`. That would inject
# escape sequences into the footer text pane_is_turn_end / pane_is_api_error /
# pane_is_fork / pane_pending_own_work match against — silently loosening every
# matcher whose anchoring discipline (#246/#452) is load-bearing. The existing
# plain capture is untouched; this is a second, narrow read.
#
# UNKNOWN IS NOT EMPTY
# --------------------
# A pane that could not be read, or that has no prompt line, yields `unknown` —
# never `empty`. `empty` asserts "the prompt is clear", a positive claim; a
# detector that could not look learned nothing and must say so, or a headless
# golem would gain a false all-clear. Callers annotate only on `suggestion`, so
# every other class (including both no-information ones) leaves output
# byte-identical to before this existed.
#
# Footer-anchored to the same $pane_footer_lines window as its siblings, for the
# same #246 reason: this script and its tests necessarily discuss these very
# shapes, so a whole-scrollback match would self-trip on a golem reading them.
# The glyph and the escape are built from printf octal escapes rather than
# written literally (mirroring golem-mode-check.sh's MODE_GLYPH_*), so this file
# contains no matchable prompt line even inside a displayed footer window.
#
# The LAST prompt-glyph line in the window is the live one: SUBMITTED history
# entries keep their glyph in the scrollback (measured on the control session),
# so taking the first would classify an old command as the current buffer.
PROMPT_GLYPH="$(command printf '\342\235\257')" # the input-line marker
# _has_dim <text> — 0 when <text> carries the SGR DIM (2) attribute.
#
# Not a substring test for the standalone `ESC[2m`: dim is a PARAMETER, and a
# terminal is free to bundle it with others in one escape (`ESC[1;2m`,
# `ESC[0;2m`). Every byte captured from a live pane here uses the standalone
# form, so a substring match works today — but the failure if that ever changes
# is the silent one this whole function guards against: the annotation simply
# vanishes and a real suggestion reads as queued input.
#
# So parse the parameter list. The trap is that a naive search for a `2`
# matches `22` (dim OFF) and `38;5;246` (a colour) — both emitted constantly by
# this very TUI — so each parameter is compared WHOLE, between `;` delimiters.
_has_dim() {
    _hd_rest="$1"
    while :; do
        case "$_hd_rest" in
            *$'\033['*) ;;
            *) return 1 ;;
        esac
        _hd_rest="${_hd_rest#*$'\033['}"
        # Parameters of THIS escape, up to its `m`; skip a non-SGR sequence.
        case "$_hd_rest" in
            m* | [0-9\;]*m*) _hd_params="${_hd_rest%%m*}" ;;
            *) continue ;;
        esac
        # Whole-parameter scan: surround with `;` so `2` cannot match `22`.
        case ";${_hd_params};" in
            *';2;'*) return 0 ;;
        esac
    done
}
PROMPT_NBSP="$(command printf '\302\240')" # the NBSP the prompt pads with

# _strip_sgr <text> — text with CSI ... m sequences removed, so a caller can ask
# "is there any VISIBLE text here?" without the attributes confusing the answer.
# Parameter expansion rather than sed: BSD sed reads \x1b as a literal and the
# repo bans GNU-only regex, so a sed spelling would silently no-op on macOS —
# which for this function would turn every empty prompt into `input`.
#
# An UNTERMINATED CSI (a capture clipped mid-escape) breaks the loop rather than
# stripping a `ESC[` prefix whose terminator never arrives. Measured, so the
# claim is not overstated: without the guard the visible text still survives
# (`real text` + a stray `2`), so this is about not leaking escape debris into
# the visible-text test — NOT about preventing a false `empty`, which the
# unguarded form does not cause either. The behavior that actually matters is
# pinned by test_strip_sgr_unterminated_csi.
_strip_sgr() {
    local v="$1" pre post
    while :; do
        case "$v" in
            *$'\033['*) ;;
            *) break ;;
        esac
        pre="${v%%$'\033['*}"
        post="${v#*$'\033['}"
        # Require a well-formed SGR sequence: parameter bytes ([0-9;]) followed
        # by the `m` terminator. A bare `*m*` test would match an `m` ANYWHERE
        # later in the line, so a non-SGR CSI (say ESC[K) plus an unrelated `m`
        # in the visible text ("merge") would strip the real text between them.
        # Measured: tmux `capture-pane -e` emitted only `m`-terminated sequences
        # across live panes here (72/72), so this is belt-and-braces rather than
        # an observed failure — but it costs one case arm and removes the
        # dependency on that staying true.
        case "$post" in
            m* | [0-9\;]*m*) ;;
            *) break ;;
        esac
        post="${post#*m}"
        v="$pre$post"
    done
    command printf '%s' "$v"
}

# pane_prompt_line_class <session> — echo suggestion | input | empty | unknown.
pane_prompt_line_class() {
    local sess="$1" pane footer l line rest visible
    command -v tmux >/dev/null 2>&1 || {
        command echo "unknown"
        return 0
    }
    pane="$(tmux capture-pane -p -e -t "$sess" 2>/dev/null || true)"
    if [ -z "$pane" ]; then
        command echo "unknown"
        return 0
    fi
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$pane")"
    line=""
    while IFS= read -r l; do
        case "$l" in
            *"$PROMPT_GLYPH"*) line="$l" ;;
        esac
    done <<<"$footer"
    if [ -z "$line" ]; then
        command echo "unknown"
        return 0
    fi
    # Everything after the FIRST prompt PREFIX (glyph + NBSP) is the buffer
    # region. Two choices here, both reached by measurement after getting them
    # wrong:
    #
    #   * The PAIR, not the bare glyph. The buffer text can itself CONTAIN the
    #     glyph (a suggestion that mentions it, or pasted text).
    #   * The FIRST occurrence, not the last. `##` (greedy) anchors on the LAST
    #     match, so text containing the PAIR re-created the same bug one level
    #     down — narrower trigger, identical failure. `#` takes the first, which
    #     is what the composer prompt actually IS: this line's own leading
    #     marker. The "last" instinct came from telling a SUBMITTED history line
    #     from the live one, but that is a choice between LINES, already settled
    #     above by taking the last glyph-bearing line; WITHIN that line, first is
    #     correct and cannot be shifted by content.
    #
    # Both guard one silent false negative: the dim run falls outside the slice,
    # a real suggestion reports as queued `input`, and the annotation simply
    # vanishes while the pane reads as ordinary typed text — the worst outcome
    # for this feature. Measured on the real composer shape
    # (ESC[...m <glyph> <NBSP> ...), which pads with U+00A0 on every live golem
    # checked; a selection MENU uses glyph + plain space, so the fallback keeps
    # that shape working (such a pane is classified as a modal gate first).
    case "$line" in
        *"$PROMPT_GLYPH$PROMPT_NBSP"*) rest="${line#*"$PROMPT_GLYPH$PROMPT_NBSP"}" ;;
        *) rest="${line#*"$PROMPT_GLYPH"}" ;;
    esac
    visible="$(_strip_sgr "$rest")"
    visible="${visible//$PROMPT_NBSP/ }"
    visible="$(command printf '%s' "$visible" | "$TR" -d '[:space:]')"
    if [ -z "$visible" ]; then
        command echo "empty"
        return 0
    fi
    if _has_dim "$rest"; then
        command echo "suggestion"
        return 0
    fi
    command echo "input"
}

# Turn-ended / idle-at-prompt overlay (issue #447). NOT a modal overlay: a golem
# that finished its turn and sits at an empty prompt awaiting human input — e.g.
# commit signing halted on a locked 1Password vault, so the golem correctly
# stopped rather than spin — paints only the ordinary `⏵⏵ auto mode on` footer
# with no `esc to interrupt` run-spinner above it. The other three matchers detect
# a MODAL prompt (plan/permission/fork), so this stall class slips past every push
# channel — the exact hours-costing gap #447 describes. This matcher mirrors the
# GLYPH arm of pane_liveness_class (the auto-mode-on footer with no spinner) — NOT
# its `Unknown command` arm: that #229 error signature stays pull-only on the
# liveness channel; the push channel deliberately reports only the turn-ended-at-
# prompt footer here. So the pane push channel emits it too, letting it flow
# through emit_transitions' dedup (fired once on the transition into the idle
# state, re-fired only after it clears) — the turn-ended signal belongs on the
# edge-triggered pane push channel, not the periodic liveness heartbeat.
#
# Same two guards as pane_liveness_class (see #246): the match is ANCHORED to the
# FOOTER region (last $pane_footer_lines lines) — this very script's comments carry
# `auto mode on` and `esc to interrupt`, so a whole-scrollback match would
# self-trip — and it requires the `⏵⏵` box-drawing glyph so a bare-words mention
# stays unmatched. The run-spinner is checked FIRST: a working golem still paints
# the `auto mode on` footer, so `esc to interrupt` present ⇒ NOT idle.
#
# This is a SINGLE-poll match. The two-consecutive-poll confirmation the issue
# asks for — so a momentary between-turns render does not fire a false idle — is
# layered on top in the --stream-panes drive arm via confirm_turn_end(), NOT here,
# so --once-panes and the unit tests can assert the raw matcher in isolation.
#
# A second guard (issue #517) sits between the spinner check and the positive
# footer match: pane_pending_own_work returns 0 when the golem is parked on its OWN
# background monitors / a running dynamic workflow / the review harness — alive
# with a queued next action, NOT awaiting a human — so that legitimate between-turns
# park does not false-fire the idle push (the debounce cannot separate it; see
# pane_pending_own_work). Only when the spinner is absent AND no own-work is pending
# is the golem genuinely idle-at-prompt awaiting a human (the #447 target case).
pane_is_turn_end() {
    local footer
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$1")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # #517: parked on its own monitors / dynamic workflow / review harness ⇒ not a
    # human-awaiting idle, even though the run-spinner is absent.
    if pane_pending_own_work "$1"; then
        return 1
    fi
    case "$footer" in
        *"⏵⏵"*"auto mode on"*) return 0 ;;
    esac
    return 1
}

# API-error death read (issue #446). A golem whose `claude` process died on a
# transient API error (429/5xx) or a terminal one (auth/quota) stops and sits at
# the ordinary `⏵⏵ auto mode on` prompt — indistinguishable from a finished turn
# by the footer alone — while the error line (`API Error: ...`) sits a few lines
# ABOVE, in the scrollback. So unlike the gate/turn-end matchers this scans the
# wider `$pane_error_lines` tail, not just the 8-line footer, to catch the error
# line. Best-effort, like pane_is_turn_end / the #229 idle read.
#
# Two guards keep it from over-matching (same discipline as pane_liveness_class,
# #246): (1) a live golem still WORKING (spinner up) is never a death — if the
# FOOTER carries `esc to interrupt`, return no-match regardless of scrollback, so
# a golem reading an old error in its own transcript while actively working does
# not self-trip. (2) The signature is the specific Claude Code `API Error` string
# followed by a status code, not a bare word, so a golem discussing "api error"
# in prose stays unmatched. panes_snapshot() also runs this BEFORE pane_is_turn_end
# so a died pane (which also paints the bare turn-end footer) is classified as the
# more-specific death, never downgraded to turn-end.
pane_is_api_error() {
    local pane="$1" footer window
    # Guard 1: an active run-spinner in the footer means the process is alive and
    # working — never a death, whatever the scrollback holds.
    footer="$("$TAIL" -n "$pane_footer_lines" <<<"$pane")"
    case "$footer" in
        *"esc to interrupt"*) return 1 ;;
    esac
    # Guard 2: the specific `API Error` signature with a status code, scanned over
    # the wider death window. grep -E over the tail (not a bash glob) so the digit
    # class is exact; anchored to `API Error` immediately preceding the code.
    window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    if command printf '%s\n' "$window" |
        "$GREP" -qE 'API Error[^0-9]*(4[0-9][0-9]|5[0-9][0-9])'; then
        return 0
    fi
    return 1
}

# Classify a died pane's API error as retriable (transient — auto-resume
# candidate) or terminal (auth/quota — needs a human), for the emitted message.
# 429 and 5xx are transient; 401/403 (auth) and 402 (quota/billing) are terminal;
# any other 4xx defaults to terminal (conservative — surface for a human rather
# than auto-resume into a wall). Prints "retriable (NNN)" or "terminal (NNN)";
# "unknown" when no code is found (shouldn't happen — pane_is_api_error matched a
# code — but never emit a bare classification).
pane_api_error_class() {
    local pane="$1" window code
    window="$("$TAIL" -n "$pane_error_lines" <<<"$pane")"
    code="$(command printf '%s\n' "$window" |
        "$GREP" -oE 'API Error[^0-9]*(4[0-9][0-9]|5[0-9][0-9])' |
        "$GREP" -oE '(4[0-9][0-9]|5[0-9][0-9])' | "$HEAD" -n1)"
    case "$code" in
        429 | 5??) command echo "retriable ($code)" ;;
        '') command echo "unknown" ;;
        *) command echo "terminal ($code)" ;;
    esac
}
