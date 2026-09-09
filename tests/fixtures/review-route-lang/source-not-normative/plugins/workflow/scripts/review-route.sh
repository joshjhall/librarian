#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# `.rb` sits in the source arm but is absent from EXT_LANG, so the subset claim
# in review-route.sh's header is false. Contradicts nothing — arms assertion 4.
#
# The gate PARSES this file; nothing executes it. It still prints, so every arm
# is genuinely reachable code, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Pp][Yy] | *.[Rr][Bb])
            command printf 'source\n'
            ;;
        *.md)
            command printf 'doc\n'
            ;;
        *.json)
            command printf 'config\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}
