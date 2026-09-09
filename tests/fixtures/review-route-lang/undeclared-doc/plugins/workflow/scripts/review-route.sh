#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# The residual fail-open case assertion 3 CANNOT see: `.rb` is absent from
# EXT_LANG, so nothing contradicts — yet Ruby source classified doc routes cheap.
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
        *.md | *.[Rr][Bb])
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
