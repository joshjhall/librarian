#!/usr/bin/env bash
# Fixture stub for tests/lint-language-table-sync.sh — a bash ext->lang table
# that CONTRADICTS the normative one: `.rs` is claimed to be `go`.
#
# The gate PARSES this file; nothing executes it. It still echoes `lang` so the
# variable is genuinely read, keeping the fixture shellcheck-clean without a
# suppression — a suppressed warning in a fixture is one more thing that can rot.

classify() {
    local lang=""
    case "$1" in
        *.[Pp][Yy]) lang="py" ;;
        *.[Rr][Ss]) lang="go" ;;
        *.[Gg][Oo]) lang="go" ;;
    esac
    printf '%s\n' "$lang"
}
