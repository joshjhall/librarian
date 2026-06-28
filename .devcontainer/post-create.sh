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

echo "==> Post-create setup complete."
