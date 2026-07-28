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
# Runner resolution (#538): `ruff` on PATH → `uvx ruff` → skip. The uvx fallback
# matters because a host can have no ruff binary while `uvx` (from uv) runs it
# with no install step; without it this gate sat inert on exactly such a host.
# The uvx branch is PROBED (`uvx ruff --version`) before being selected — uvx can
# be present but offline/uncached, and an unprobed `uvx ruff check` would turn a
# graceful skip into a hard gate failure.
#
# When neither runner resolves the gate skips (bare host without the
# devcontainer's tooling), mirroring the node/jq skips in run-all.sh — but it
# exits with the reserved SKIP sentinel 77 so run-all.sh renders it as `[SKIP] …
# did not run` rather than `[ok]`. A silent skip is indistinguishable from a pass
# in the suite summary, which is how this gate stayed vacuous unnoticed. CI
# installs ruff and asserts it is on PATH, so the gate genuinely runs there.
# Config lives in ruff.toml at the repo root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Python lint + format (ruff)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
SKIP_EXIT_CODE=77

# Wall-clock bound for the uvx probe below, seconds. Override for a slow link.
UVX_PROBE_TIMEOUT="${UVX_PROBE_TIMEOUT:-60}"

# probe_uvx — true when `uvx ruff` is actually usable.
#
# BOUNDED on purpose. uvx may need the network to resolve ruff, and a STALLED
# link (DNS resolves, connection hangs) is not the same as a cleanly offline one:
# unbounded, the probe blocks forever. run-all.sh deliberately does not wrap
# stages in `timeout` (it would perturb validate-golem-watch.sh's process-group
# signal delivery), so nothing upstream would bound it either — the whole suite
# would wedge until CI's 15m job timeout killed it with no hint that a network
# call was the cause. A hang is a worse failure than the inert pass this issue
# fixes, so the bound lives here.
#
# `timeout` is GNU coreutils and absent on base macOS, so it is used only when
# present; without it the probe runs unbounded (the pre-existing behaviour, and
# no worse than not probing at all).
probe_uvx() {
    if command -v timeout >/dev/null 2>&1; then
        command timeout "$UVX_PROBE_TIMEOUT" uvx ruff --version >/dev/null 2>&1
    else
        command uvx ruff --version >/dev/null 2>&1
    fi
}

# --- runner resolution: ruff on PATH → probed uvx ruff → skip ----------------
# RUFF_RUNNER is "" when nothing resolved. The uvx probe runs ONCE here rather
# than per test: it costs a subprocess, and a failing probe must degrade to the
# skip branch, not to a mid-suite hard failure. A successful probe also warms
# uvx's cache, so the later `uvx ruff check`/`format` dispatches resolve locally
# and do not reintroduce an unbounded network call.
RUFF_RUNNER=""
if command -v ruff >/dev/null 2>&1; then
    RUFF_RUNNER="ruff"
elif command -v uvx >/dev/null 2>&1 && probe_uvx; then
    RUFF_RUNNER="uvx"
fi

if [ -z "$RUFF_RUNNER" ]; then
    skip_test "GATE DID NOT RUN — no ruff runner (install ruff, or uv for 'uvx ruff', to lint the Python pre-scan tools)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# Announce the resolved runner. Without this the two branches are
# indistinguishable in the log, and "which ruff actually ran" is the first
# question when the gate disagrees with `just lint`.
printf 'Runner: %s\n\n' "$(if [ "$RUFF_RUNNER" = "uvx" ]; then
    printf 'uvx ruff (no ruff binary on PATH)'
else
    printf 'ruff on PATH'
fi)"

# run_ruff <args...> — invoke ruff via the resolved runner.
# A function, not an unquoted "$RUFF_CMD" expansion: word-splitting a command
# string is a shellcheck SC2086 trap and breaks on any future runner whose
# invocation carries an argument.
run_ruff() {
    if [ "$RUFF_RUNNER" = "uvx" ]; then
        command uvx ruff "$@"
    else
        command ruff "$@"
    fi
}

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
    out="$(cd "$REPO_ROOT" && run_ruff check plugins 2>&1)" || rc=$?
    assert_equals "0" "$rc" "ruff check must pass over plugins/ (see output below)
$out"
}

# `ruff format --check` — no formatting drift. Reports the files that would be
# reformatted; `ruff format plugins` (or `just fmt`) fixes them.
test_ruff_format_check() {
    local out rc=0
    out="$(cd "$REPO_ROOT" && run_ruff format --check plugins 2>&1)" || rc=$?
    assert_equals "0" "$rc" "ruff format --check must pass over plugins/ — run 'ruff format plugins' to fix
$out"
}

run_test test_corpus_non_empty "Python corpus is non-empty (gate is not a no-op)"
run_test test_ruff_check "ruff check passes over plugins/"
run_test test_ruff_format_check "ruff format --check passes over plugins/ (no drift)"

generate_report
