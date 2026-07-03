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
# Skips gracefully when shellcheck is absent (bare host without the devcontainer's
# tooling), mirroring the node/jq skips in run-all.sh — CI installs shellcheck so
# the gate actually runs there.
#
# Scope: plugins/ tests/ bin/ only. The containers/ submodule is a separate repo
# with its own CI — out of scope here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Shellcheck (bundled shell scripts)"

if ! command -v shellcheck >/dev/null 2>&1; then
    skip_test "shellcheck not available (install shellcheck to lint the shell scripts)"
    generate_report
    return 0 2>/dev/null || exit 0
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
