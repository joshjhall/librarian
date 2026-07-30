# shellcheck shell=bash
# Shared sandbox helpers for the release-toolchain test fragments
# (issue #564 — extracted from tests/validate-release.sh).
#
# Sourced by tests/validate-release.sh BEFORE its group fragments under
# tests/release/. Only the two sandbox constructors used by more than one group
# live here; a group's own stubs (gc_stub_curl, run_git_automation, ...) stay in
# that group's fragment.
#
# Each sandbox is a fresh subdir under the module-level WORKDIR, so a per-helper
# RETURN trap (which would fire when the helper returns, before the test body
# runs) is unnecessary — WORKDIR is cleaned once when the suite exits.
#
# REPO_ROOT is defined by the entry point before it sources this file.

# shellcheck disable=SC2034  # WORKDIR is read by the group fragments

# Module-level scratch dir, cleaned up once when the suite exits. Each sandbox is
# a fresh subdir under it, so a per-helper RETURN trap (which would fire when the
# helper returns, before the test body runs) is unnecessary.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# make_bin_sandbox <varname>
# Creates a fresh sandbox subdir with a copy of bin/ and a synthetic VERSION
# (1.2.3), and assigns its path to the caller's named variable. Enough for
# release.sh's pre-node error paths and for generate-release-notes.sh (which
# sources nothing).
make_bin_sandbox() {
    local __out="$1"
    local dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    command cp -R "$REPO_ROOT/bin" "$dir/bin"
    command printf '1.2.3\n' >"$dir/VERSION"
    printf -v "$__out" '%s' "$dir"
}

# make_full_sandbox <varname>
# As make_bin_sandbox, plus the manifests and validator release.sh stamps on its
# happy path: tests/validate-manifests.mjs, .claude-plugin/, and plugins/. The
# copied manifests are internally valid; release.sh restamps them all to the new
# version, so the initial VERSION≠manifest skew is harmless.
make_full_sandbox() {
    local __out="$1"
    local dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    command cp -R "$REPO_ROOT/bin" "$dir/bin"
    command mkdir -p "$dir/tests"
    command cp "$REPO_ROOT/tests/validate-manifests.mjs" "$dir/tests/"
    command cp -R "$REPO_ROOT/.claude-plugin" "$dir/.claude-plugin"
    command cp -R "$REPO_ROOT/plugins" "$dir/plugins"
    command printf '1.2.3\n' >"$dir/VERSION"
    printf -v "$__out" '%s' "$dir"
}
