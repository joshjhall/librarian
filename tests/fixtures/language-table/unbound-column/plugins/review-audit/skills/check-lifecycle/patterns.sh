#!/usr/bin/env bash
# Fixture stub — an M cell in a column with no binding (#847). Not runnable.
#
# Mirrors its Python twin, including the `future-detector` emission, so the only
# thing wrong with this tree is that BINDINGS has no entry for that column.

scan_file() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            emit_row "$1" "future-detector" "stub"
            ;;
    esac
}
