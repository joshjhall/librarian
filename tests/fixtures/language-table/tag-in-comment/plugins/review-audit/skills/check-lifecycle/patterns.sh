#!/usr/bin/env bash
# Fixture stub — a category tag MENTIONED in a comment (#847). Not runnable.
#
# Mirrors its Python twin: the `rs` arm emits `unreaped-subprocess` and only
# names `unclosed-handle` in a comment. Both runtimes carry the mention so a
# raw-body matcher fails for both, rather than reading as a py/sh divergence.

scan_file() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            emit_row "$1" "unclosed-handle" "stub"
            ;;
        *.[Rr][Ss])
            emit_row "$1" "unreaped-subprocess" "stub"
            # TODO: also emit "unclosed-handle" here once the Rust arms land.
            ;;
    esac
}
