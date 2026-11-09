#!/usr/bin/env bash
# Gate: the repo-baseline template tool pins agree with the containers build.
#
# WHY. The devcontainer is built from the pinned `containers` submodule, which
# installs its own copy of most of the tools the repo-baseline templates pin
# (uv, typos, dprint, lefthook, ...). The two are separate pin sets for the same
# binaries, and when they drift the rendered repo's own version gate refuses the
# devcontainer's tool: a template pinning uv 0.13.7 while the image ships 0.12.23
# fails `validate-repo-baseline-templates` AC1 in every developer's pre-push —
# measured on the 2026-11 dependency sweep, where conform had also drifted
# (template alpha.33, image alpha.32) without anything noticing.
#
# WHAT IT COMPARES. For every tool in the template pin files
# (core/ + shell/ tools.versions, python/ ruff.toml + uv.toml required-version),
# the containers default `<TOOL>_VERSION="${<TOOL>_VERSION:-X}"` read from
# lib/** at the EXACT commit the superproject records for the submodule — not
# the working checkout, which may sit on any commit. A tool containers does not
# pin (shellcheck, bats, ruff today) is reported and allowed: there is nothing
# to agree with. A tool pinned twice inside containers with two different values
# fails too, since "the image's version" is then undefined.
#
# EXIT CODES
#   0   every shared pin agrees
#   1   drift (named, with both values)
#   77  did not run: the recorded submodule commit is not available locally
#       (CI checks out without submodules). Never 0 — a skip must not read as a
#       pass (#538/#571). Run `git submodule update --init containers` to enable.
#
# Offline by construction: reads only local git objects, never the network.
# bash-3.2 / BSD clean per CLAUDE.md § Runtime policy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CONTAINERS_PINS_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKIP_EXIT_CODE=77
T="$REPO_ROOT/plugins/dev-core/skills/repo-baseline/templates"
SUB="$REPO_ROOT/containers"

test_suite "repo-baseline template pins agree with the containers build"

# --- the pinned containers commit -----------------------------------------
PIN="$(command git -C "$REPO_ROOT" ls-tree HEAD containers 2>/dev/null |
    command awk '$2 == "commit" { print $3 }')"
if [ -z "$PIN" ]; then
    command printf 'lint-containers-tool-pins: no containers gitlink in HEAD\n' >&2
    exit 1
fi
if ! command git -C "$SUB" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    skip_test "GATE DID NOT RUN — containers commit $PIN not available locally (git submodule update --init containers)"
    generate_report
    exit "$SKIP_EXIT_CODE"
fi

# --- containers side: TOOL VERSION per default, from lib/** at $PIN --------
WORK="$(command mktemp -d)" || exit 2
trap 'command rm -rf "$WORK"' EXIT

command git -C "$SUB" grep -h -E \
    '^[[:space:]]*[A-Z0-9_]+_VERSION="\$\{[A-Z0-9_]+_VERSION:-[^}]+\}"' \
    "$PIN" -- 'lib/' 2>/dev/null |
    command sed -E 's/^[[:space:]]*([A-Z0-9_]+)_VERSION="\$\{[A-Z0-9_]+_VERSION:-([^}]+)\}".*/\1 \2/' |
    command sort -u >"$WORK/containers"

# A defensive floor: zero parsed pins means the pattern stopped matching, not
# that containers stopped pinning — fail rather than compare against nothing.
if [ ! -s "$WORK/containers" ]; then
    command printf 'lint-containers-tool-pins: parsed 0 version defaults from containers@%s — the pattern no longer matches\n' "$PIN" >&2
    exit 1
fi

# --- template side ---------------------------------------------------------
{
    for f in "$T/core/tools.versions" "$T/shell/tools.versions"; do
        command awk -F= '/^[a-z]/ { print $1 " " $2 }' "$f"
    done
    for t in ruff uv; do
        v="$(command sed -n 's/^required-version = "==\(.*\)"$/\1/p' "$T/python/$t"*.toml.tmpl)"
        [ -n "$v" ] && command printf '%s %s\n' "$t" "$v"
    done
} >"$WORK/template"

# The same floor on the template side. A format change (an uppercase key, a
# leading space, a renamed required-version line) yields zero template rows, and
# a zero-row comparison passes with no drift — a green gate over nothing. Both
# python pins are required, and the core list must be non-empty.
for t in ruff uv; do
    if ! command awk -v k="$t" '$1 == k { f = 1 } END { exit !f }' "$WORK/template"; then
        command printf 'lint-containers-tool-pins: no %s required-version parsed from %s/python/%s.toml.tmpl\n' "$t" "$T" "$t" >&2
        exit 1
    fi
done
if [ "$(command awk 'END { print NR }' "$WORK/template")" -le 2 ]; then
    command printf 'lint-containers-tool-pins: parsed no tools.versions pins under %s — the format no longer matches\n' "$T" >&2
    exit 1
fi

test_containers_pins_are_unambiguous() {
    local dup
    dup="$(command awk '{ print $1 }' "$WORK/containers" | command uniq -d)"
    assert_equals "" "$dup" \
        "each containers tool has ONE default version (two values make the image's version undefined)"
}

test_template_pins_match_containers() {
    local tool ver upper cver drift="" unpinned=""
    while read -r tool ver; do
        upper="$(command printf '%s' "$tool" | command tr '[:lower:]-' '[:upper:]_')"
        cver="$(command awk -v k="$upper" '$1 == k { print $2; exit }' "$WORK/containers")"
        if [ -z "$cver" ]; then
            unpinned="$unpinned $tool"
        elif [ "$cver" != "$ver" ]; then
            drift="$drift
  $tool: template $ver, containers@${PIN:0:7} $cver"
        fi
    done <"$WORK/template"
    [ -n "$unpinned" ] && command printf '  not pinned by containers (allowed):%s\n' "$unpinned"
    assert_equals "" "$drift" \
        "every template tool pin matches the containers build at the pinned submodule commit"
}

# "Not pinned by containers" is allowed per tool, so a broken name mapping would
# route EVERY tool there and pass with no drift. Require a floor of tools that
# actually matched a containers pin — today 11 of 14; MIN_SHARED is well below.
MIN_SHARED="${CONTAINERS_PINS_MIN_SHARED:-5}"
test_enough_tools_were_compared() {
    local tool ver upper shared=0
    while read -r tool ver; do
        upper="$(command printf '%s' "$tool" | command tr '[:lower:]-' '[:upper:]_')"
        command awk -v k="$upper" '$1 == k { f = 1 } END { exit !f }' "$WORK/containers" &&
            shared=$((shared + 1))
    done <"$WORK/template"
    assert_true "[ $shared -ge $MIN_SHARED ]" \
        "at least $MIN_SHARED template tools matched a containers pin (got $shared) — fewer means the mapping broke, not that the pin sets diverged"
}

run_test test_containers_pins_are_unambiguous "containers pins each shared tool once"
run_test test_template_pins_match_containers "template pins match containers@pin"
run_test test_enough_tools_were_compared "enough tools were actually compared"

generate_report
