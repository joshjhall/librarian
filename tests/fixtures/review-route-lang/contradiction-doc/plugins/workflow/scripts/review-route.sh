#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# The FAIL-OPEN direction, and the one AC1 of #913 names verbatim: `.rs` is a
# source language per EXT_LANG, classified `doc` — so its diff routes cheap.
#
# The gate PARSES this file; nothing executes it. It still prints, so every arm
# is genuinely reachable code, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Pp][Yy])
            command printf 'source\n'
            ;;
        *.md | *.[Rr][Ss])
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
