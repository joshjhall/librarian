#!/usr/bin/env bash
# Spell-check gate for the repo prose + code (#679 follow-on).
#
# `typos` (crate-ci/typos, config in _typos.toml) was previously wired ONLY into
# the lefthook pre-push hook. That left a real hole: `just lint` and
# `tests/run-all.sh` both passed while pre-push rejected the push, and because CI
# runs run-all.sh rather than lefthook, **CI never spell-checked at all**. A typo
# could therefore reach main via any path that did not go through a local
# pre-push (a web edit, a merge commit, a contributor with hooks uninstalled).
# Promoting it here fixes both halves at once: CI enforces it, and a committer
# sees the same result from `just test` that pre-push will produce.
#
# Whole-repo scan (`typos .`), matching the hook's no-file-list branch, so the
# gate's verdict does not depend on which files happen to be staged.
# _typos.toml owns the exclusions (containers/ submodule, CHANGELOG.md) and the
# extend-words dictionary for legitimate technical terms.
#
# When typos is absent (bare host without the devcontainer's tooling) the gate
# exits the reserved sentinel 77, which run-all.sh renders `[SKIP] … did not run`
# rather than `[ok]` (#538/#571). A silent skip is indistinguishable from a pass,
# which is how a gate sits inert unnoticed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Spell check (typos)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
SKIP_EXIT_CODE=77

if ! command -v typos >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — typos not available (install typos-cli to spell-check the repo)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# The config must exist and be the one typos actually reads: without it the
# extend-words dictionary is absent, every legitimate technical term (BRE, ba,
# updat, styl, mis) fires, and the gate fails for the wrong reason.
test_config_present() {
    assert_file_exists "$REPO_ROOT/_typos.toml" \
        "_typos.toml must exist (it carries the exclusions + technical-term dictionary)"
}

# The gate itself. typos exits non-zero on any finding and prints file:line:col
# with the suggested correction, which is surfaced verbatim on failure.
test_repo_spelling() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && command typos . 2>&1)" || rc=$?
    assert_equals "0" "$rc" \
        "typos must report no misspellings across the repo
$out"
}

run_test test_config_present "_typos.toml is present (dictionary + exclusions)"
run_test test_repo_spelling "typos: no misspellings across the repo"

generate_report
