#!/usr/bin/env bash
# Fixture stub — the `fn` binding kind (#847). Not runnable.
#
# Mirrors its Python twin. Function names match the real BINDINGS entries
# (scan_debug_prints / scan_debugger_statements) because the map keys on them.
#
# The closing `}` in column zero after each function is load-bearing: it is what
# resets the tracked function name. Without that reset a later top-level `case`
# would still be attributed to the last function seen — the real defect this
# tracking was fixed for.

scan_debug_prints() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "debug-statement" "stub"
            ;;
    esac
}

scan_debugger_statements() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "debug-statement" "stub"
            ;;
        *.[Rr][Ss])
            emit_row "$1" "debug-statement" "stub"
            ;;
    esac
}
