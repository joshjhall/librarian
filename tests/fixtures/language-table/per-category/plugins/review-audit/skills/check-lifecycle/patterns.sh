#!/usr/bin/env bash
# Fixture stub — per-category divergence (#847). Not runnable.
#
# The bash half mirrors its Python twin exactly: `rs` has an
# `unreaped-subprocess` arm and no `unclosed-handle` one. Mirroring matters —
# the divergence under test is matrix-vs-source, NOT py-vs-sh, so keeping the
# two runtimes identical means the per-category assertion fails for the right
# reason and reports BOTH runtimes rather than reading as a #836-shaped split.

scan_file() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            emit_row "$1" "unclosed-handle" "stub"
            ;;
        *.[Rr][Ss])
            emit_row "$1" "unreaped-subprocess" "stub"
            ;;
    esac
}
