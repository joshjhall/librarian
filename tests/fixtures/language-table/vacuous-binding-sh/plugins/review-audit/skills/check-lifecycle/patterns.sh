#!/usr/bin/env bash
# Fixture stub — mirror image of vacuous-binding/ (#847). Not runnable.
#
# The bash half does NOT emit `unclosed-handle`, so that column's binding is
# vacuous in this runtime only — the case that pins the `if not got_sh` branch.
# Its Python twin emits both categories.

scan_file() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            ;;
    esac
}
