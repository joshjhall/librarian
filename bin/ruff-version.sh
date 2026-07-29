#!/usr/bin/env bash
# Print the pinned ruff version (#542).
#
# ruff.toml's top-level `required-version = "==X.Y.Z"` is the single source of
# that pin. Every path that installs or resolves ruff reads it through here
# rather than hardcoding a version of its own:
#
#   .devcontainer/post-create.sh     uv tool install / pipx install
#   .github/workflows/ci.yml         pipx install
#   .github/workflows/release.yml    pipx install
#   tests/lint-python.sh             uvx ruff@<v> fallback
#   justfile (lint recipe)           uvx ruff@<v> fallback
#
# One reader instead of five copies of the same sed: a hand-copied parse in each
# consumer is exactly how the versions drifted apart in the first place.
#
# Output: the bare version, e.g. `0.16.0` (no `==` prefix, no trailing newline
# beyond the single one) — the shape `pipx install "ruff==$V"` and
# `uvx "ruff@$V"` both want.
#
# FAILS LOUD rather than printing nothing when the pin is missing or malformed:
# an empty version would silently degrade every caller back to installing a
# floating ruff, which is the bug this closes (CLAUDE.md § Runtime policy).
#
# Usage: bash bin/ruff-version.sh [path/to/ruff.toml]
#   The optional argument is for tests; callers pass nothing and get the repo's
#   own ruff.toml, resolved from THIS script's location rather than $PWD so CI,
#   post-create, and just recipes can call it from any working directory.

set -euo pipefail

BIN_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(command dirname "$BIN_DIR")"
RUFF_TOML="${1:-$PROJECT_ROOT/ruff.toml}"

if [ ! -f "$RUFF_TOML" ]; then
    command printf 'ERROR: %s not found — cannot resolve the pinned ruff version.\n' \
        "$RUFF_TOML" >&2
    exit 1
fi

# Match only a TOP-LEVEL `required-version` — everything before the first
# `[table]` header. Column anchoring alone is NOT enough: in TOML a key at column
# 0 that follows `[format]` belongs to that table, and ruff rejects it there
# ("unknown field"). Matching it anyway would hand every caller a version ruff is
# itself ignoring — the pin would read as enforced while nothing enforced it.
version="$(command awk '
    /^[[:space:]]*\[/ { exit }
    match($0, /^required-version[[:space:]]*=[[:space:]]*"==[0-9][0-9.]*"/) {
        line = $0
        sub(/^[^"]*"==/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
    }
' "$RUFF_TOML")"

if [ -z "$version" ]; then
    command printf 'ERROR: no top-level `required-version = "==X.Y.Z"` in %s.\n' \
        "$RUFF_TOML" >&2
    command printf '       It is the single source of the ruff pin (#542); every\n' >&2
    command printf '       install path reads it through bin/ruff-version.sh.\n' >&2
    exit 1
fi

if ! command printf '%s' "$version" | command grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    command printf 'ERROR: required-version in %s is not an exact X.Y.Z pin: %s\n' \
        "$RUFF_TOML" "$version" >&2
    command printf '       A range would let the install paths drift apart again.\n' >&2
    exit 1
fi

command printf '%s\n' "$version"
