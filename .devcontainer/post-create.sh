#!/usr/bin/env bash
# post-create.sh — Runs once when the devcontainer is first created.
# Librarian is a docs + shell + node repo, so there's nothing to compile or
# warm; just verify the tooling the containers submodule is meant to provide.

set -euo pipefail

echo "==> Verifying lefthook..."
command -v lefthook >/dev/null || {
    echo "ERROR: lefthook not on PATH (expected from the containers dev-tools feature)"
    exit 1
}

echo "==> Verifying Node (MCP servers + bundled scripts)..."
command -v node >/dev/null || {
    echo "ERROR: node not on PATH (expected from the containers node feature)"
    exit 1
}

# ruff powers tests/lint-python.sh (lint + format of the Python pre-scan tools)
# and the lefthook pre-commit hooks. It is a lint dependency of the same standing
# as lefthook and node above, so it gets the same fail-loud treatment rather than
# the warn-and-skip the optional codegraph index gets below — an absent ruff is
# what let the Python gate sit vacuous (#538). The gate itself now falls back to
# `uvx ruff`, so this install is the belt to that suspenders: a fresh container
# gets a real ruff binary instead of paying uvx resolution on every run.
echo "==> Ensuring ruff (Python lint + format)..."
if command -v ruff >/dev/null; then
    echo "    Already on PATH — skipping install."
elif command -v uv >/dev/null; then
    echo "    Installing via uv tool install..."
    uv tool install ruff
elif command -v pipx >/dev/null; then
    echo "    Installing via pipx..."
    pipx install ruff
else
    echo "ERROR: cannot install ruff — no uv or pipx on PATH."
    echo "       ruff lints the Python pre-scan tools (tests/lint-python.sh)."
    echo "       Install uv (https://docs.astral.sh/uv/) or pipx, or install ruff directly."
    exit 1
fi

command -v ruff >/dev/null || {
    echo "ERROR: ruff still not on PATH after install (is the tool bin dir on PATH?)"
    exit 1
}

# Build the codegraph knowledge-graph index for the codegraph MCP server. The
# index (.codegraph -> /cache/codegraph) lives on a named volume that survives
# rebuilds, so only initialize when it's actually missing; an existing index is
# left as-is (drop the volume to force a clean re-index).
echo "==> Ensuring codegraph index..."
if command -v codegraph >/dev/null; then
    if codegraph status 2>&1 | grep -q "Not initialized"; then
        echo "    No index found — running codegraph init..."
        codegraph init
    else
        echo "    Index already present — skipping."
    fi
else
    echo "    codegraph not on PATH — skipping (MCP server unavailable)."
fi

echo "==> Post-create setup complete."
