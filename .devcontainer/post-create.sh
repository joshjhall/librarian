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
