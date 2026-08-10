#!/usr/bin/env bash
# Markdown lint gate for .claude/memory/ (#578).
#
# NOT a duplicate of `just lint`'s `rumdl check .`. It exists because that
# command CANNOT SEE these files:
#
#   - `rumdl check .` walks the repo but SKIPS GITIGNORED PATHS. `.gitignore`
#     ignores `tmp/`, so everything under `.claude/memory/tmp/` is invisible to
#     it — the scratch notes that churn hardest between sessions.
#   - lefthook's rumdl hook passes `{staged_files}`. A gitignored file is never
#     staged, so it is never linted there either.
#
# Both documented entry points are therefore blind to exactly the files with the
# most churn. Verified by planting identical content in two locations: the
# tracked copy is flagged, the gitignored twin is not. Same bytes, same rule,
# different reachability.
#
# The fix is to pass the directory EXPLICITLY — rumdl honors an explicit path
# argument over its gitignore walk. This is a reachability gate, not a rule gate:
# MD018 and friends already fire correctly once the file is actually reached.
#
# Runner resolution and the skip sentinel follow lint-python.sh (#538): an absent
# tool exits 77 so run-all.sh renders `[SKIP] … did not run` rather than `[ok]`.
# A silent skip is indistinguishable from a pass, which is how a gate sits inert
# unnoticed — the same argument this repo already accepted for the Python gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Markdown lint (.claude/memory/)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
SKIP_EXIT_CODE=77

MEMORY_DIR="$REPO_ROOT/.claude/memory"

# Nothing to lint is a legitimate pass, not a skip: the gate ran, the corpus was
# empty. Distinct from "the linter is missing", which is the skip below.
if [ ! -d "$MEMORY_DIR" ]; then
    printf 'No .claude/memory/ directory — nothing to lint.\n\n'
    generate_report
    exit 0
fi

if ! command -v rumdl >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — rumdl not on PATH (install rumdl to lint .claude/memory/)"
    generate_report
    exit "$SKIP_EXIT_CODE"
fi

# THE POINT OF THE GATE, and `--respect-gitignore=false` is the whole of it.
#
# Passing the directory explicitly is NOT sufficient — that was the first draft,
# and it reproduced the very blindness this gate exists to close. rumdl's
# "does not apply to explicitly provided paths" exemption covers an explicit
# FILE, not a directory it then walks: `rumdl check .claude/memory/` still
# applied .gitignore and scanned 144 of 145 files, missing a planted MD018 in
# `tmp/` and exiting 0.
#
# With the flag, the same command scans 145 and catches it. If this is ever
# "simplified" by dropping the flag, the gate silently stops covering the
# gitignored tree it was written for while still reporting green — which is
# precisely the #578 failure mode, one layer up.
test_memory_markdown_is_clean() {
    local out rc=0
    out="$(command rumdl check --respect-gitignore=false "$MEMORY_DIR" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        command printf '%s\n' "$out"
    fi
    assert_equals "0" "$rc" "rumdl reports no findings under .claude/memory/"
}

# Typos over the same tree. Separate assertion so a spelling failure is not
# reported as a markdown-structure failure.
#
# `--no-ignore --hidden` for the SAME reason rumdl needs its flag: typos also
# honors .gitignore when walking a directory, and had the identical blind spot.
# Measured on a planted misspelling under `tmp/`: a bare `typos .claude/memory/`
# found 0, with the flags it found 3.
test_memory_has_no_typos() {
    if ! command -v typos >/dev/null 2>&1; then
        skip_test "typos not on PATH — spelling not checked"
        return 0
    fi

    local out rc=0
    out="$(command typos --no-ignore --hidden "$MEMORY_DIR" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        command printf '%s\n' "$out"
    fi
    assert_equals "0" "$rc" "typos reports no misspellings under .claude/memory/"
}

run_test test_memory_markdown_is_clean "rumdl is clean under .claude/memory/ (gitignored files included)"
run_test test_memory_has_no_typos "typos is clean under .claude/memory/"

generate_report
