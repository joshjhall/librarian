# shellcheck shell=bash
# prompt-line classifier (#977) — golem-gate-watch tests (issue #564 split).
#
# Covers pane_prompt_line_class (the dim-SGR suggestion-vs-queued-input read),
# _has_dim / _strip_sgr, and the suggestion ANNOTATION as it flows through
# panes_snapshot, liveness_snapshot, confirm_turn_end's #447 debounce and
# emit_transitions' dedup.
#
# Split out of 30-helpers-and-modes.sh, which this block had grown past the
# repo's per-language shell warning threshold (741 production LOC vs 700) and to
# ~2.5x its largest sibling. It is a self-contained area — its own driver
# (_pane_e_class) and no dependency on the #82 helper/mode content it sat under.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh for the shared drivers BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.
# ---------------------------------------------------------------------------
# Prompt-line classifier (#977)
# ---------------------------------------------------------------------------
# The pane readers could not tell an autocomplete SUGGESTION at the prompt from
# text the operator had QUEUED — five phantom instances across two orchestration
# runs, two of them outward or gate-bypassing (`merge it once CI is green`;
# `push it` on a golem that had said it was withholding the push).
#
# THE FIXTURES BELOW ARE THE REAL CAPTURED BYTES, not invented shapes. Captured
# 2026-09-09 with `tmux capture-pane -p -e` from live golem-840 / golem-938 and a
# disposable control session. That matters: the whole fix rests on the claim that
# a suggestion carries SGR 2 (dim) and real input does not, so a fixture someone
# made up would test the implementation against itself.
#
# _pane_e_class drives the REAL pane_prompt_line_class through a flag-aware tmux
# stub, so it exercises the `-e` capture the classifier makes — not just the
# string logic. The stub returns $2 for `-e` and a DIFFERENT plain-capture text
# for everything else, mirroring the real divergence (`-p` strips the SGR run;
# `-p -e` keeps it) that made this bug invisible in the first place.
_pane_e_class() {
    local esc_text="$1" tmp stub_bin real_bash out
    tmp="$(command mktemp -d)" || return 1
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    command ln -s "$real_bash" "$stub_bin/bash"
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    capture-pane)
        for _a in "$@"; do
            if [ "$_a" = "-e" ]; then
                command printf '%s\n' "${FAKE_E:-}"
                exit 0
            fi
        done
        # Plain capture: the SGR-stripped view, which is what the pre-#977
        # readers saw and why they could not classify.
        command printf '%s\n' "${FAKE_PLAIN:-}"
        ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"
    out="$(
        /usr/bin/env -uBASH_ENV PATH="$stub_bin:$PATH" \
            FAKE_E="$esc_text" FAKE_PLAIN="stripped-plain-view" \
            "$real_bash" -c '
                . "$1"
                pane_prompt_line_class golem-9
            ' _ "$GATE_WATCH" 2>/dev/null
    )"
    command rm -rf "$tmp"
    command printf '%s' "$out"
}

# The three positive classes, from the real captured bytes.
test_pane_prompt_line_class() {
    local esc glyph nbsp
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"

    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2mopen the PR once it lands${esc}[0m")" \
        "A dim (SGR 2) prompt line is an autocomplete suggestion (live golem-840 bytes)"
    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2mrebase onto main and push${esc}[0m")" \
        "The second live phantom (golem-938 bytes) classifies the same way"
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} rebase onto main and push")" \
        "The SAME TEXT typed for real, with no dim run, is queued input — the whole distinction"
    assert_equals "empty" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[39m")" \
        "A prompt line with only attributes and padding is empty"

    # Dim is a PARAMETER, so a terminal may bundle it with others in one escape
    # (#977 cycle-5). Live panes use the standalone form today, but a substring
    # match would lose the annotation silently if that ever changed.
    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[1;2mbold dim text${esc}[0m")" \
        "Dim combined with another parameter (ESC[1;2m) is still a suggestion"
    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[0;2mreset dim text${esc}[0m")" \
        "Dim after a reset in the same escape (ESC[0;2m) is still a suggestion"
    # The traps a naive "contains a 2" scan would fall into — both emitted
    # constantly by this very TUI, so a false positive here would annotate
    # ordinary typed text as inert.
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[22mdim-OFF text")" \
        "SGR 22 (dim OFF) is NOT dim — a whole-parameter match, not a substring"
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[38;5;246mcoloured text")" \
        "A 256-colour parameter containing a 2 is NOT dim"
}

# `unknown` is NOT `empty`. A reader that could not look learned nothing, and
# must never emit the positive claim "the prompt is clear" — otherwise a headless
# or unreadable golem gains a false all-clear, which is the silence-reads-as-a-
# pass shape this repo keeps filing issues about (#538/#571).
test_pane_prompt_line_class_unknown_not_empty() {
    assert_equals "unknown" "$(_pane_e_class "")" \
        "An unreadable/empty capture is unknown, NOT empty"
    assert_equals "unknown" \
        "$(_pane_e_class "just some scrolling build output"$'\n'"  auto mode on")" \
        "A pane with no prompt-glyph line at all is unknown, NOT empty"

    # tmux missing from PATH entirely (#977 cycle-3 review) — a distinct early
    # return from "capture-pane came back empty", and the one a tmux-less host
    # takes. It must answer `unknown` and exit 0, never crash the callers that
    # wrap it. Every other case here installs a tmux stub, so this branch was
    # unexercised.
    local tmp real_bash out rc
    tmp="$(command mktemp -d)" || return 1
    real_bash="$(command -v bash)"
    command mkdir -p "$tmp/stub-bin"
    command ln -s "$real_bash" "$tmp/stub-bin/bash"
    rc=0
    out="$(
        /usr/bin/env -uBASH_ENV PATH="$tmp/stub-bin" \
            "$real_bash" -c '. "$1"; pane_prompt_line_class golem-9' _ "$GATE_WATCH" 2>/dev/null
    )" || rc=$?
    command rm -rf "$tmp"
    assert_equals "unknown" "$out" \
        "With tmux absent from PATH the classifier answers unknown (not empty, not a crash)"
    assert_equals "0" "$rc" \
        "...and returns 0, so pane_suggestion_suffix's callers are never broken by a tmux-less host"
}

# Footer anchoring (#246 discipline, as every sibling matcher): this very file
# and golem-gate-watch.sh discuss the dim escape, so a golem cat-ing/grepping
# either must not self-trip a false suggestion.
test_pane_prompt_line_class_footer_anchored() {
    local esc glyph nbsp filler
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    # The scrolled dim line is the ONLY glyph line, so last-line-wins cannot mask
    # a missing anchor: without footer anchoring this reads `suggestion`, with it
    # `unknown`. (The first draft of this case put an empty prompt below the
    # filler, which last-line-wins alone already handled — it passed against a
    # whole-scrollback mutant, i.e. it tested nothing.)
    assert_equals "unknown" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2mscrolled phantom text${esc}[0m"$'\n'"$filler")" \
        "A dim prompt line scrolled ABOVE the footer window does not fake a suggestion"
    # Control: the SAME line inside the window does classify — proving the
    # assertion above fails for the anchoring reason and not because the fixture
    # is unmatchable.
    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2mscrolled phantom text${esc}[0m")" \
        "...and the same line INSIDE the window is still detected (anchor, not blindness)"
}

# The LAST glyph line wins: submitted history entries keep their prompt glyph in
# the scrollback (measured on the control session), so reading the FIRST would
# report an already-submitted command as the current buffer — reporting queued
# input where the prompt is actually clear.
test_pane_prompt_line_class_last_line_wins() {
    local esc glyph nbsp
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"
    assert_equals "empty" \
        "$(_pane_e_class "${esc}[39m${glyph} an earlier submitted command"$'\n'"${esc}[39m${glyph}${nbsp} ${esc}[39m")" \
        "A submitted history line above an empty prompt does not read as queued input"
}

# The annotation is appended on a suggestion and ABSENT otherwise — the
# byte-identical guarantee that keeps this from disturbing #447/#517 semantics.
# Drives the REAL panes_snapshot() end-to-end, so the wiring is pinned, not just
# the classifier.
test_panes_snapshot_suggestion_annotation() {
    local esc glyph nbsp idle_footer
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"
    idle_footer="  ⏵⏵ auto mode on"

    PANE_TEXT_E="${esc}[39m${glyph}${nbsp} ${esc}[2mpush it${esc}[0m"$'\n'"$idle_footer" \
        _run_panes_snapshot_tmux "$idle_footer"
    assert_contains "$PANES_OUT" "suggestion shown (inert, not queued input)" \
        "An idle golem showing a suggestion is annotated (#977)"
    assert_contains "$PANES_OUT" "idle at prompt" \
        "The annotation is ADDITIVE — the idle verdict itself is unchanged"

    PANE_TEXT_E="${esc}[39m${glyph}${nbsp} ${esc}[39m"$'\n'"$idle_footer" \
        _run_panes_snapshot_tmux "$idle_footer"
    assert_not_contains "$PANES_OUT" "suggestion shown" \
        "A plain idle golem's line is byte-identical — no annotation"
    assert_contains "$PANES_OUT" "idle at prompt" \
        "...and it still reports idle"
}

# The annotation is VOLATILE: a suggestion appears and vanishes while the golem
# sits equally idle. liveness_stabilize must strip it, or its arrival/departure
# reads as a class change and re-fires the per-golem line — the exact noise that
# function exists to suppress.
test_liveness_stabilize_strips_suggestion_annotation() {
    local out annotated
    annotated="⚠ idle at prompt — process up, not advancing (check pane) · suggestion shown (inert, not queued input)"
    out="$(
        . "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-1\t%s\n' "$annotated")"
    )"
    assert_not_contains "$out" "suggestion shown" \
        "liveness_stabilize strips the volatile suggestion annotation from the dedup key"
    assert_contains "$out" "idle at prompt" \
        "...while preserving the idle class the dedup actually keys on"

    # A suggestion flicker must NOT look like a transition.
    local with without
    with="$(
        . "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-1\t%s\n' "$annotated")"
    )"
    without="$(
        . "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-1\t⚠ idle at prompt — process up, not advancing (check pane)\n')"
    )"
    assert_equals "$without" "$with" \
        "Annotated and un-annotated idle stabilize to the SAME key (no false transition)"
}

# confirm_turn_end must not be fooled by the annotation (#977 review finding).
# The debounce gates on an EXACT $TURN_END_MSG match, so an annotated idle line
# failed that test and fell through the `else` arm — emitted on the FIRST poll,
# skipping the #447 confirmation entirely, and dropped from $PENDING_TURN_END so
# a suggestion that then cleared re-suppressed the standing line for an extra
# poll. Reproduced before the fix: an annotated line emitted on poll 1 while the
# identical plain line was correctly withheld.
#
# This is the sibling-channel instance of the hazard liveness_stabilize() already
# handled on --stream-liveness: harden one knob, grep every sibling.
test_confirm_turn_end_suggestion_annotation() {
    local out annot
    out="$(
        . "$GATE_WATCH"
        annot="${TURN_END_MSG}${SUGGESTION_ANNOT}"
        # shellcheck disable=SC2034  # read by the sourced confirm_turn_end
        PENDING_TURN_END=" "
        # Poll 1: annotated idle must be WITHHELD, exactly as a plain idle is.
        confirm_turn_end "$(command printf 'golem-1\t%s\n' "$annot")"
        command printf '[p1]%s' "$CONFIRMED_SNAPSHOT"
        # Poll 2: confirmed — emits, and the annotation still reaches the operator.
        confirm_turn_end "$(command printf 'golem-1\t%s\n' "$annot")"
        command printf '[p2]%s' "$CONFIRMED_SNAPSHOT"
        # Poll 3: the suggestion clears. The golem is still idle and still
        # confirmed, so the standing line must keep coming — not be re-suppressed.
        confirm_turn_end "$(command printf 'golem-1\t%s\n' "$TURN_END_MSG")"
        command printf '[p3]%s' "$CONFIRMED_SNAPSHOT"
    )"
    assert_contains "$out" "[p1][p2]golem-1" \
        "An annotated idle line is WITHHELD on the first poll (the #447 debounce still applies)"
    assert_contains "$out" "suggestion shown (inert, not queued input)" \
        "...and the annotation survives to the confirmed output line"
    assert_contains "$out" "[p3]golem-1" \
        "A cleared suggestion does not re-suppress the standing idle line for an extra poll"

    # A real gate line still passes straight through, annotated or not.
    out="$(
        . "$GATE_WATCH"
        # shellcheck disable=SC2034  # read by the sourced confirm_turn_end
        PENDING_TURN_END=" "
        confirm_turn_end "$(command printf 'golem-2\tplan gate — ExitPlanMode awaiting approval\n')"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
    )"
    assert_contains "$out" "plan gate" \
        "A non-idle gate line is still immediate (the annotation split did not gate it)"
}

# _strip_sgr's unterminated-CSI guard (#977 review, deferrable-but-cheap). The
# A capture clipped mid-escape must not make a populated prompt read as `empty`.
# Note what this does and does not prove: removing the `*m*)` guard still passes
# these assertions (measured), because the unguarded form leaves the visible text
# intact plus a stray char. So this pins the BEHAVIOR that matters to callers —
# real text never reports empty — rather than crediting the guard with preventing
# a failure it does not actually prevent.
test_strip_sgr_unterminated_csi() {
    local out esc
    esc="$(command printf '\033')"
    out="$(
        . "$GATE_WATCH"
        _strip_sgr "real text${esc}[2"
    )"
    assert_contains "$out" "real text" \
        "An unterminated CSI does not swallow the visible text before it"

    # The consequence the comment names: such a line must not read as `empty`.
    local glyph nbsp
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} real text${esc}[2")" \
        "A truncated-escape prompt line reports input, never a false empty"

    # A NON-SGR CSI must not let an unrelated later `m` swallow the text between
    # them (#977 cycle-4). Measured: tmux -e emitted only m-terminated sequences
    # across live panes (72/72), so this guards an assumption rather than an
    # observed failure — but "merge" is exactly the kind of word that would make
    # it a silent one.
    out="$(
        . "$GATE_WATCH"
        _strip_sgr "${esc}[Kmerge the branch"
    )"
    assert_contains "$out" "merge the branch" \
        "A non-SGR CSI plus a later 'm' does not eat the visible text between them"
}

# The CHAINED path (#977 cycle-2 review): confirm_turn_end -> emit_transitions,
# exactly as the --stream-panes drive arm wires them. The isolated debounce test
# above passes even while a flicker re-pushes the standing line, because the
# re-push happens in emit_transitions' dedup — which the isolated test never
# reaches. Measured before the fix: an idle golem whose suggestion toggled
# emitted on EVERY toggle while it sat equally idle.
#
# This is the sibling of test_liveness_stream_dedup on the --stream-liveness
# channel; --stream-liveness routes through liveness_stabilize (which strips
# earlier), --stream-panes does not, so the strip lives in emit_transitions to
# cover both.
test_panes_stream_suggestion_flicker_dedup() {
    local out
    out="$(
        . "$GATE_WATCH"
        # A bare directive covers only the NEXT statement, so both assignments
        # are wrapped in a block to keep it in scope (the repo's documented trap).
        # shellcheck disable=SC2034  # both read by the sourced functions
        {
            PENDING_TURN_END=" "
            LAST_EMIT=""
        }
        annot="${TURN_END_MSG}${SUGGESTION_ANNOT}"
        _step() {
            confirm_turn_end "$(command printf 'golem-1\t%s\n' "$1")"
            command printf '[%s]' "$2"
            emit_transitions "$CONFIRMED_SNAPSHOT" "$3"
        }
        _step "$annot" p1 0
        _step "$annot" p2 0
        _step "$TURN_END_MSG" p3 0
        _step "$annot" p4 0
    )"
    # The PRIME path stores a key too (#977 cycle-5). --stream-panes seeds with
    # prime=1, so if priming stored the raw annotated message the first real poll
    # after it would look like a change and replay the line on startup.
    local primed
    primed="$(
        . "$GATE_WATCH"
        # shellcheck disable=SC2034  # both read by the sourced functions
        {
            PENDING_TURN_END=" golem-1 "
            LAST_EMIT=""
        }
        annot="${TURN_END_MSG}${SUGGESTION_ANNOT}"
        confirm_turn_end "$(command printf 'golem-1\t%s\n' "$annot")"
        emit_transitions "$CONFIRMED_SNAPSHOT" 1
        command printf '[primed]'
        confirm_turn_end "$(command printf 'golem-1\t%s\n' "$TURN_END_MSG")"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
    )"
    assert_equals "[primed]" "$primed" \
        "Priming on an ANNOTATED line stores the stripped key, so the next poll is not a false change"
    assert_contains "$out" "[p1][p2]golem-1" \
        "The confirmed idle line is emitted once, on the second poll"
    assert_contains "$out" "suggestion shown (inert, not queued input)" \
        "...carrying the annotation, so the operator still sees it"
    assert_contains "$out" "[p3][p4]" \
        "A suggestion that clears and returns does NOT re-emit the standing idle line"
}

# The `input` class at an integration call site (#977 cycle-2 review). The
# classifier's four classes are unit-tested, but the emitting call sites only
# covered `suggestion` and an `empty` control — never a real non-dim string at
# the prompt, which is the very case the feature exists to distinguish. Without
# this, a future edit that annotated `input` too would pass every test.
test_panes_snapshot_input_not_annotated() {
    local esc glyph nbsp idle_footer
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"
    idle_footer="  ⏵⏵ auto mode on"

    PANE_TEXT_E="${esc}[39m${glyph}${nbsp} genuinely queued text"$'\n'"$idle_footer" \
        _run_panes_snapshot_tmux "$idle_footer"
    assert_not_contains "$PANES_OUT" "suggestion shown" \
        "Real queued input at the prompt is NOT annotated as a suggestion"
    assert_contains "$PANES_OUT" "idle at prompt" \
        "...and the golem is still reported idle"

    # The `unknown` class THROUGH the wrapper (#977 cycle-5): an unreadable -e
    # capture while the plain capture still shows an idle footer. Asserted at the
    # call site, not just on the classifier, because pane_suggestion_suffix's
    # case has no explicit unknown) arm — it relies on fallthrough, which a
    # future edit could break without any classifier test noticing.
    PANE_TEXT_E="" _run_panes_snapshot_tmux "$idle_footer"
    assert_not_contains "$PANES_OUT" "suggestion shown" \
        "An unreadable -e capture annotates nothing (unknown never claims inert)"
    assert_contains "$PANES_OUT" "idle at prompt" \
        "...and the idle verdict from the plain capture is unaffected"
}

# Embedded-glyph false negative (#977 cycle-3 review). The buffer text can itself
# contain the prompt glyph — a suggestion that mentions it, or pasted text — and
# splitting on the LAST bare glyph then sliced from inside the text, dropping the
# opening dim run and reporting a real suggestion as queued `input`. Measured
# before the fix. That is the worst failure mode for this feature and a SILENT
# one: the annotation is simply absent and the pane reads as ordinary typed text.
# Anchoring on the composer's glyph+NBSP pair fixes it.
test_pane_prompt_line_class_glyph_in_text() {
    local esc glyph nbsp
    esc="$(command printf '\033')"
    glyph="$(command printf '\342\235\257')"
    nbsp="$(command printf '\302\240')"

    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2msee the ${glyph} marker docs${esc}[0m")" \
        "A suggestion whose TEXT contains the prompt glyph is still a suggestion"
    # The narrower recurrence (#977 cycle-4): anchoring on the pair fixed the
    # bare-glyph case but `##` still took the LAST match, so text containing the
    # PAIR itself re-created the identical silent misclassification one level
    # down. Taking the FIRST match is what actually closes the class — the
    # composer prompt is this line's leading marker, so no content can shift it.
    assert_equals "suggestion" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} ${esc}[2msee ${glyph}${nbsp} here${esc}[0m")" \
        "A suggestion whose text contains the glyph+NBSP PAIR is still a suggestion"
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} type ${glyph}${nbsp} to continue")" \
        "Real input containing the PAIR is still input (first-match did not invert the classes)"
    assert_equals "input" \
        "$(_pane_e_class "${esc}[39m${glyph}${nbsp} type ${glyph} to continue")" \
        "Real input containing the glyph is still input (the fix did not invert the classes)"
    # A selection MENU pads with a plain space, not the NBSP; the bare-glyph
    # fallback must keep working for any line without the pair.
    assert_equals "input" \
        "$(_pane_e_class "${esc}[38;5;153m${glyph}${esc}[39m Yes, proceed")" \
        "A glyph+SPACE line (menu shape, no NBSP) still classifies via the fallback"
}
