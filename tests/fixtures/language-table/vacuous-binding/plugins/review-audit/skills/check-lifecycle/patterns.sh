#!/usr/bin/env bash
# Fixture stub — a binding that resolves to NO arm (#847). Not runnable.
#
# ASYMMETRIC ON PURPOSE, and this is the whole point of the fixture. The bash
# half DOES emit `unclosed-handle`; only the Python twin does not. So the column
# is vacuous in exactly ONE runtime.
#
# A fixture vacuous in BOTH runtimes cannot distinguish the two detection
# branches: either `if not got_py` or `if not got_sh` alone still reports, so
# deleting one branch is a mutation that survives. Measured — with a symmetric
# fixture both single-branch mutations survived and only the both-branches
# mutation was caught. The `unclosed-handle` sibling fixture below (the .py file)
# arms the py branch; this file's emission is what leaves the sh branch clean, so
# each branch is pinned by a case only it can report.

scan_file() {
    case "$1" in
        *.[Pp][Yy])
            emit_row "$1" "unreaped-subprocess" "stub"
            emit_row "$1" "unclosed-handle" "stub"
            ;;
    esac
}
