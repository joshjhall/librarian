#!/usr/bin/env bash
# Fixture stub — the `file` binding kind (#847). Not runnable.
#
# Mirrors its Python twin: `py` and `rs` arms, no `rlib`. Emits no category tag,
# so this column can only be bound whole-file.

scan_file() {
    case "$1" in
        *.[Pp][Yy]) : ;;
        *.[Rr][Ss]) : ;;
    esac
}
