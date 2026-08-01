#!/usr/bin/env bash
# Shellcheck gate for the bundled shell scripts.
#
# Every `*.sh` in librarian-proper (plugins/ tests/ bin/) is checked with
# `shellcheck --severity=warning` — the same invocation the lefthook pre-commit
# hook runs, promoted here into tests/run-all.sh so CI (and pre-push) enforce it,
# not just the committer's machine. This complements tests/lint-shell-portability.sh
# (which bans bash-4 constructs for macOS bash-3.2) with shellcheck's broader
# correctness/quoting analysis.
#
# When shellcheck is absent (bare host without the devcontainer's tooling) the
# gate exits the reserved sentinel 77, which run-all.sh renders `[SKIP] … did not
# run` rather than `[ok]` (#571, the same inert-gate fix #538 made for the Python
# gate). A silent skip is indistinguishable from a pass, which is how a gate can
# sit inert unnoticed. CI installs shellcheck so the gate actually runs there.
#
# Scope: plugins/ tests/ bin/ only. The containers/ submodule is a separate repo
# with its own CI — out of scope here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Shellcheck (bundled shell scripts)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
SKIP_EXIT_CODE=77

if ! command -v shellcheck >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — shellcheck not available (install shellcheck to lint the shell scripts)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# List librarian-proper shell scripts (absolute paths, sorted). Excludes the
# containers/ submodule (separate repo).
list_shell_scripts() {
    command find "$REPO_ROOT/plugins" "$REPO_ROOT/tests" "$REPO_ROOT/bin" \
        -type f -name '*.sh' 2>/dev/null | command sort
}

scripts_list="$(list_shell_scripts)"

# Guard: the gate must actually inspect something.
test_corpus_non_empty() {
    assert_not_empty "$scripts_list" "At least one shell script must be present to lint"
}

# Per-file shellcheck at --severity=warning (matches the lefthook hook). Any
# warning or error fails the gate for that file, surfacing shellcheck's output.
CUR_FILE=""
test_file_shellcheck() {
    local out rc=0
    out="$(command shellcheck --severity=warning "$CUR_FILE" 2>&1)" || rc=$?
    assert_equals "0" "$rc" \
        "shellcheck (warning) must pass for ${CUR_FILE#"$REPO_ROOT"/}
$out"
}

run_test test_corpus_non_empty "Shell-script corpus is non-empty (gate is not a no-op)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_shellcheck "${f#"$REPO_ROOT"/}: shellcheck --severity=warning"
done <<<"$scripts_list"

generate_report
