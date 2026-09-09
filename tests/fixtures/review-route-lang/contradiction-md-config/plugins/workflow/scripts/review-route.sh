#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# The remaining cell of the contradiction matrix: markdown in the CONFIG arm.
# `cls == "config"` with `want == "doc"` is a branch no other fixture drives —
# the three siblings all exercise `want == "source"` — so a bug specific to it
# (a wrong direction label, or the loop skipping `config` as a class) would go
# uncaught. Reported as over-review: routing markdown as config costs a full
# fan-out, never a skipped one.
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
        *.rst)
            command printf 'doc\n'
            ;;
        *.json | *.md)
            command printf 'config\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}
