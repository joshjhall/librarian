#!/usr/bin/env bash
# Fixture stub — the SAME-LINE `;;` arm-delimiting trap (#847). Not runnable.
#
# The skip-list arm below ends `;;` on the PATTERN LINE ITSELF, exactly as the
# real check-lifecycle/patterns.sh does. A splitter that scans forward for `;;`
# without checking the pattern line first runs straight past this arm and keeps
# absorbing lines until the NEXT `;;` — swallowing the `*.[Rr][Ss])` arm below
# and attributing its `rs` extension to this skip-list arm's region.
#
# The matrix marks `rs` as unsupported, and that is TRUE of the real dispatch:
# there is no `unreaped-subprocess` arm for it. The phantom coverage exists only
# in a broken splitter, which then reports "marked unsupported, patterns.sh has
# an arm" — a defect in the GATE presented as a defect in the scanner.
#
# Same shape as an end-marker that silently over-grows its region: the start
# matched, so nothing errors; the region just quietly grows.

scan_file() {
    # `rs` is skipped by an arm whose `;;` sits on the PATTERN LINE ITSELF, and
    # the very next arm emits `unreaped-subprocess` for `py`.
    #
    # A splitter that scans forward for `;;` without checking the pattern line
    # first treats the `rs` arm as unterminated, runs on to the NEXT `;;` — the
    # `py` arm's — and absorbs that arm's body into the `rs` region. `rs` then
    # reads as `unreaped-subprocess`-covered, contradicting its `—` cell.
    #
    # TWO THINGS ARE LOAD-BEARING. The over-grown region belongs to the arm with
    # the same-line `;;`, so that must be the `rs` arm — not a neighbour. And the
    # emitting arm must be the one IMMEDIATELY after it, or the runaway region
    # stops at an intervening `;;` and never reaches the emission, leaving a
    # fixture that passes with a broken splitter too.
    case "$1" in
        *.[Rr][Ss]) return 0 ;;
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            ;;
    esac
}
