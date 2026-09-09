#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# The SAFE direction, which ADR 0002 forbids just the same: `.md` is markdown
# per EXT_LANG, classified `source`. Costs review budget, never safety.
#
# The gate PARSES this file; nothing executes it. It still prints, so every arm
# is genuinely reachable code, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    _cr_base="${1##*/}"

    case "$_cr_base" in
        *.[Pp][Yy] | *.md)
            command printf 'source\n'
            ;;
        *.rst)
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
