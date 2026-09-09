#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# A table that is CORRECT in every direction. POSITIVE fixture: it must
# produce no finding at all, and must REACH the no-contradiction assertion.
#
# The gate PARSES this file; nothing executes it. It still prints, so every arm
# is genuinely reachable code, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Pp][Yy] | *.[Rr][Ss])
            command printf 'source\n'
            ;;
        *.md | *.rst)
            command printf 'doc\n'
            ;;
        *.json | *.yaml)
            command printf 'config\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}
