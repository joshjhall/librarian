#!/usr/bin/env bash
# Fixture stub for tests/lint-review-route-lang.sh (#913).
#
# A CORRECT table. This tree's defect is in its loc_engine.py stub, whose
# EXT_LANG is empty — so assertion 1 fires and nothing else does.
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
