#!/usr/bin/env bash
# Install apt packages without letting the runner image's third-party sources
# fail the build (#983).
#
# THE FAILURE THIS CLOSES. `apt-get update` fails the WHOLE command on ANY
# source error. The ubuntu-latest image ships a Google Chrome apt source this
# repo does not use; on 2026-09-09 that source served a corrupt index and three
# CI shards plus the merge gate went red before a single test ran:
#
#     Err:18 https://dl.google.com/linux/chrome-stable/deb stable/main amd64 Packages
#       Hash Sum mismatch
#
# Neither jq nor shellcheck comes from dl.google.com — the failure was entirely
# collateral. Re-running clears it (the upstream index self-heals), but it burns
# a CI cycle and an operator decision per occurrence, and it is indistinguishable
# at a glance from a real gate failure.
#
# WHY THE WHOLE DIRECTORY, NOT google-chrome.list BY NAME. This repo needs only
# Ubuntu's own archives (jq, shellcheck). Every file in sources.list.d on a
# GitHub runner is a bundled third-party source we do not use, and ANY of them
# can serve a corrupt index the same way — naming one would leave the next one
# armed.
#
# WHY RENAME RATHER THAN rm. `<name>.disabled` is inspectable in the step log
# and non-destructive if the runner image is ever reused. apt only reads `.list`
# and `.sources`, so renaming is sufficient to take the source out of play.
#
# Acquire::Retries=3 is added as well. It does NOT fix a Hash Sum mismatch — a
# served-corrupt index reproduces on retry within the same window — but it costs
# nothing and covers the transient-network case that would otherwise be a second
# flake class.
#
# ONE ENTRY POINT, not an inline fix per step: the same one-reader pattern
# bin/ruff-version.sh uses for the ruff pin (#542). Two call sites exist today
# (ci.yml, release.yml) and tests/lint-apt-hardening.sh fails the tree if any
# workflow grows a third that calls apt-get directly.
#
# Usage: bash bin/apt-install.sh <package> [package...]
#
# Env overrides (for tests; both default to real behaviour):
#   APT_SOURCES_LIST_D   directory to disable sources in (default
#                        /etc/apt/sources.list.d) — lets the suite exercise the
#                        disable step in a sandbox, unprivileged.
#   APT_INSTALL_DRY_RUN  when 1, print the constructed apt-get commands instead
#                        of running them. The sources are still disabled (in
#                        whatever APT_SOURCES_LIST_D points at), so the suite
#                        covers both halves without root and without touching
#                        the host's apt.
#
# Pure bash + coreutils. bash-3.2 clean and BSD-clean per CLAUDE.md § Runtime
# policy: no `env --unset=`, no GNU-only regex, no `realpath -m`, no `grep -q`
# inside a pipeline.

set -euo pipefail

SOURCES_LIST_D="${APT_SOURCES_LIST_D:-/etc/apt/sources.list.d}"
DRY_RUN="${APT_INSTALL_DRY_RUN:-0}"

if [ "$#" -eq 0 ]; then
    command printf 'ERROR: bin/apt-install.sh needs at least one package name.\n' >&2
    command printf '       Usage: bash bin/apt-install.sh <package> [package...]\n' >&2
    exit 1
fi

# Run apt as root when we are not already (containers often are; runners are
# not). Resolved once into a variable rather than branching at each call site.
SUDO=""
if [ "$(command id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# --- Disable bundled third-party sources -------------------------------------
# A missing or empty directory is NOT an error: a minimal image may ship no
# sources.list.d at all, and there is nothing to harden in that case.
disabled_count=0
if [ -d "$SOURCES_LIST_D" ]; then
    # nullglob so an empty directory yields no iterations rather than the
    # literal glob pattern. `.sources` is apt's deb822 form; `.list` the legacy
    # one. Anything already `.disabled` is skipped by both patterns, which makes
    # a re-run idempotent.
    shopt -s nullglob
    for src in "$SOURCES_LIST_D"/*.list "$SOURCES_LIST_D"/*.sources; do
        [ -f "$src" ] || continue
        if $SUDO mv "$src" "$src.disabled"; then
            command printf 'apt-install: disabled third-party source %s\n' "$src"
            disabled_count=$((disabled_count + 1))
        else
            command printf 'ERROR: failed to disable apt source %s\n' "$src" >&2
            exit 1
        fi
    done
    shopt -u nullglob
fi

command printf 'apt-install: disabled %d third-party source(s) in %s\n' \
    "$disabled_count" "$SOURCES_LIST_D"

# --- Update + install ---------------------------------------------------------
# Retries cover a transient network blip. `set -e` plus the explicit checks below
# mean a failure here is loud and non-zero — never a silent partial install that
# leaves a later gate skipping for a missing tool (CLAUDE.md § Runtime policy).
UPDATE_CMD="$SUDO apt-get -o Acquire::Retries=3 update"
INSTALL_CMD="$SUDO apt-get -o Acquire::Retries=3 install -y $*"

if [ "$DRY_RUN" = "1" ]; then
    command printf 'apt-install: DRY RUN, not executing\n'
    command printf '%s\n' "$UPDATE_CMD"
    command printf '%s\n' "$INSTALL_CMD"
    exit 0
fi

if ! $SUDO apt-get -o Acquire::Retries=3 update; then
    command printf 'ERROR: apt-get update failed after disabling %d third-party source(s).\n' \
        "$disabled_count" >&2
    command printf '       This is NOT the #983 third-party-source failure — those are\n' >&2
    command printf '       already disabled above. Check the Ubuntu archives themselves.\n' >&2
    exit 1
fi

if ! $SUDO apt-get -o Acquire::Retries=3 install -y "$@"; then
    command printf 'ERROR: apt-get install failed for: %s\n' "$*" >&2
    exit 1
fi

command printf 'apt-install: installed %s\n' "$*"
