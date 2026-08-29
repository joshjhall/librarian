#!/usr/bin/env bash
# Fixture stub — the bash half dispatches on .py ONLY. The matrix marks .rs as
# modeled and the Python half has an arm for it, so the missing arm here is the
# divergence assertion 4 must catch. This is the shape of #836. Not runnable.
#
# The arm emits the `injection-risk` tag for the reason its Python twin does:
# the gate binds that matrix column to the arms carrying the tag (#847).

scan_file() {
    case "$1" in
        *.[Pp][Yy]) emit_row "$1" "injection-risk" "stub" ;;
    esac
}
