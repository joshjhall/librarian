#!/usr/bin/env bash
# Python lint + format gate (ruff).
#
# The pre-scan tools ship a Python 3.11+ primary implementation
# (plugins/*/skills/*/patterns.py) behind the language-agnostic TSV contract; see
# CLAUDE.md § Key conventions. This gate runs ruff over them — `ruff check`
# (pyflakes / pycodestyle / isort / bugbear per ruff.toml) and
# `ruff format --check` (formatting drift) — so the Python matches the same
# lint+format discipline the repo applies to JSON/YAML/TOML/markdown via
# dprint/taplo/rumdl.
#
# Skips gracefully when ruff is absent (bare host without the devcontainer's
# tooling), mirroring the node/jq skips in run-all.sh — CI installs ruff so the
# gate actually runs there. Config lives in ruff.toml at the repo root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Python lint + format (ruff)"

if ! command -v ruff >/dev/null 2>&1; then
    skip_test "ruff not available (install ruff to lint the Python pre-scan tools)"
    generate_report
    return 0 2>/dev/null || exit 0
fi

# List every Python file under plugins/ (absolute paths, sorted). Currently the
# patterns.py ports; a find keeps new Python covered automatically.
list_python_files() {
    command find "$PLUGINS_DIR" -type f -name '*.py' 2>/dev/null | command sort
}

py_files="$(list_python_files)"

# Guard: the gate must actually inspect something. A gate that silently checks
# zero files (dir moved, glob regressed) is worse than no gate.
test_corpus_non_empty() {
    assert_not_empty "$py_files" "At least one Python file must be present to lint"
}

# `ruff check` — lint rules from ruff.toml (real bugs + import order + style).
test_ruff_check() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && command ruff check plugins 2>&1)" || rc=$?
    assert_equals "0" "$rc" "ruff check must pass over plugins/ (see output below)
$out"
}

# `ruff format --check` — no formatting drift. Reports the files that would be
# reformatted; `ruff format plugins` (or `just fmt`) fixes them.
test_ruff_format_check() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && command ruff format --check plugins 2>&1)" || rc=$?
    assert_equals "0" "$rc" "ruff format --check must pass over plugins/ — run 'ruff format plugins' to fix
$out"
}

run_test test_corpus_non_empty "Python corpus is non-empty (gate is not a no-op)"
run_test test_ruff_check "ruff check passes over plugins/"
run_test test_ruff_format_check "ruff format --check passes over plugins/ (no drift)"

generate_report
