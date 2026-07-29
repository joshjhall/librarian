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
#
# The version is PINNED (#542) and read from ruff.toml's required-version via
# bin/ruff-version.sh, so this container, CI, the release gate, and both uvx
# fallbacks all land on one release. That pin is enforced by ruff itself — a
# mismatched binary refuses to run — which is why the already-on-PATH branch
# below re-installs on a version mismatch instead of accepting whatever is there:
# accepting it would leave the container with a ruff that hard-fails every lint.
echo "==> Ensuring ruff (Python lint + format)..."
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUFF_VERSION="$(bash "$PROJECT_ROOT/bin/ruff-version.sh")"
echo "    Pinned version: $RUFF_VERSION"

# Echo the running ruff's version, or nothing when ruff is absent or its
# `--version` output is not the expected `ruff X.Y.Z`.
#
# The shape is VALIDATED rather than trusted, mirroring bin/ruff-version.sh's
# check on the declared pin. A positional `awk '{print $2}'` alone would silently
# yield a wrong string if a future ruff prefixed a warning line or appended build
# metadata — and since this function feeds both the reinstall decision and the
# post-install verification below, a malformed read could compare equal to itself
# and report the pin as landed when it had not.
installed_ruff_version() {
    command -v ruff >/dev/null || return 1
    ruff --version 2>/dev/null | awk '
        $1 == "ruff" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }
    '
}

# ruff_install_action <current> <pinned> <has_uv> <has_pipx>
#   Decide what to do about ruff, as a PURE function of the four inputs —
#   echoes one of: skip | uv | pipx | error-mismatch | error-no-installer.
#
# Split out from the imperative install below so the decision is testable. The
# rest of this script only runs on a real container create, which is why the
# branching here previously had no coverage at all: the gate could only grep it
# for substrings. tests/validate-lint-gates.sh now slices this function out of
# the file and drives all five outcomes directly — the same "slice the pure
# helper and eval it" idiom run_stage and extract_lint_recipe_body use.
#
# Keep it pure: no `command -v`, no installs, no echo beyond the verdict. The
# caller resolves availability and owns every side effect.
ruff_install_action() {
    _cur="$1"
    _pin="$2"
    _uv="$3"
    _pipx="$4"

    if [ "$_cur" = "$_pin" ]; then
        echo "skip"
    elif [ "$_uv" = "yes" ]; then
        echo "uv"
    elif [ "$_pipx" = "yes" ]; then
        echo "pipx"
    elif [ -n "$_cur" ]; then
        # On PATH at the wrong version with no way to correct it. Distinct from
        # the no-installer case below: ruff EXISTS, it is just unusable against
        # this repo's pin, so the message has to say that rather than "cannot
        # install".
        echo "error-mismatch"
    else
        echo "error-no-installer"
    fi
}

current_ruff="$(installed_ruff_version || true)"
have_uv=no
have_pipx=no
command -v uv >/dev/null && have_uv=yes
command -v pipx >/dev/null && have_pipx=yes

case "$(ruff_install_action "$current_ruff" "$RUFF_VERSION" "$have_uv" "$have_pipx")" in
    skip)
        echo "    Already on PATH at the pinned version — skipping install."
        ;;
    uv)
        if [ -n "$current_ruff" ]; then
            echo "    On PATH at $current_ruff, want $RUFF_VERSION — reinstalling via uv..."
        else
            echo "    Installing via uv tool install..."
        fi
        uv tool install --force "ruff==$RUFF_VERSION"
        ;;
    pipx)
        if [ -n "$current_ruff" ]; then
            echo "    On PATH at $current_ruff, want $RUFF_VERSION — reinstalling via pipx..."
        else
            echo "    Installing via pipx..."
        fi
        pipx install --force "ruff==$RUFF_VERSION"
        ;;
    error-mismatch)
        echo "ERROR: ruff on PATH is $current_ruff but ruff.toml pins $RUFF_VERSION,"
        echo "       and neither uv nor pipx is available to correct it."
        echo "       ruff refuses to run on a version mismatch, so every lint would fail."
        exit 1
        ;;
    *)
        echo "ERROR: cannot install ruff — no uv or pipx on PATH."
        echo "       ruff lints the Python pre-scan tools (tests/lint-python.sh)."
        echo "       Install uv (https://docs.astral.sh/uv/) or pipx, or install ruff directly."
        exit 1
        ;;
esac

command -v ruff >/dev/null || {
    echo "ERROR: ruff still not on PATH after install (is the tool bin dir on PATH?)"
    exit 1
}

# Verify the PIN landed, not merely that some ruff did. An install that resolved
# a different version leaves a container whose every lint invocation hard-fails
# on ruff's required-version check — better to say so here, once, than to have it
# surface as a confusing lint error later.
resolved_ruff="$(installed_ruff_version || true)"
[ "$resolved_ruff" = "$RUFF_VERSION" ] || {
    echo "ERROR: ruff on PATH is '$resolved_ruff' but ruff.toml pins $RUFF_VERSION."
    echo "       ruff refuses to run on a mismatch, so lint would fail everywhere."
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
