#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# classify() does not resolve — the function is named something else. Every
# assertion downstream would otherwise compare against EMPTY SETS and pass for
# the worst possible reason, which is what assertion 2 exists to stop.
#
# The gate PARSES this file; nothing executes it.

route_classify_renamed() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Pp][Yy])
            command printf 'source\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}
