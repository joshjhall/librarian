#!/usr/bin/env bash
# post-start.sh — Runs every time the devcontainer starts.
# Configures git identity, CLI auth, and installs git hooks.

set -euo pipefail

# --- Git & CLI setup (from the containers submodule's runtime) ---
echo "==> Configuring git..."
setup-git

echo "==> Configuring gh..."
setup-gh

# --- Git hooks via lefthook ---
if command -v lefthook >/dev/null 2>&1; then
    echo "==> Installing lefthook hooks..."
    # lefthook refuses to install when core.hooksPath is set.
    git config --unset-all core.hooksPath 2>/dev/null || true
    lefthook install
else
    echo "WARN: lefthook not found. Check that the containers submodule is present."
fi

echo "==> Post-start setup complete."
