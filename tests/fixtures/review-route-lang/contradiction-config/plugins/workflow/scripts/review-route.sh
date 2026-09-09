#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# The same fail-open direction by the other cheap-adjacent class: `.py` is a
# source language per EXT_LANG, classified `config`.
#
# The gate PARSES this file; nothing executes it. It still prints, so every arm
# is genuinely reachable code, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Rr][Ss])
            command printf 'source\n'
            ;;
        *.md)
            command printf 'doc\n'
            ;;
        *.json | *.[Pp][Yy])
            command printf 'config\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}
