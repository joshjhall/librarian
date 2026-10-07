#!/usr/bin/env bash
# post-create.sh's `.codegraph` link creation, driven behaviourally (#1173).
#
# #1105 untracked the `.codegraph -> /cache/codegraph` symlink (a tracked copy
# shipped in the release tarball), so .devcontainer/post-create.sh now recreates
# it on every container create. If that breaks, the codegraph MCP server loses
# its index in every fresh devcontainer — and nothing else would notice, because
# the script only runs on a real container create.
#
# The logic lives in `ensure_codegraph_link <project_root> <cache_dir>`, which
# this suite SLICES out of the committed script and runs against a sandbox root
# and a fake cache dir. Slicing rather than reimplementing is the point: a copy
# of the condition would keep passing while the shipped one broke. Same idiom as
# tests/validate-lint-gates.sh's ruff_install_action cases.
#
# Out of scope here: post-create's `codegraph init` branch and all of
# post-start.sh — both tracked by #948.
#
# BASH_ENV is unset for every child: in the devcontainer it points at
# /etc/bash_env, whose /etc/bashrc.d/ scripts would run inside the sliced
# function's shell. Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POST_CREATE="$REPO_ROOT/.devcontainer/post-create.sh"
REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SANDBOXES=()
cleanup() {
    local d
    for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
        command rm -rf "$d"
    done
}
trap cleanup EXIT

# new_sandbox <var> — a fresh dir holding root/ (the project) and cache/ (the
# volume), assigned to <var>. The cache dir is created; a case that needs it
# absent removes it.
new_sandbox() {
    local d
    d="$(command mktemp -d "${TMPDIR:-/tmp}/post-create.XXXXXX")" || return 1
    SANDBOXES+=("$d")
    command mkdir -p "$d/root" "$d/cache"
    eval "$1=\$d"
}

slice_helper() {
    command awk '/^ensure_codegraph_link\(\) \{/,/^\}/' "$POST_CREATE"
}

# run_link <root> <cache> — run the REAL sliced helper; prints its output.
run_link() {
    /usr/bin/env -uBASH_ENV "$REAL_BASH" -c '
        set -euo pipefail
        eval "$(command awk "/^ensure_codegraph_link\\(\\) \\{/,/^\\}/" "$1")"
        ensure_codegraph_link "$2" "$3"
    ' _ "$POST_CREATE" "$1" "$2" 2>&1
}

# NON-VACUITY FLOOR. If the helper is renamed or loses its column-0 braces, the
# awk slice is EMPTY, the eval defines nothing, and the call dies with "command
# not found" — every case below would fail, but for a reason that reads like a
# regression in the link logic. Name the real cause first.
test_helper_slices_out() {
    local body
    body="$(slice_helper)"
    assert_contains "$body" "ensure_codegraph_link() {" \
        "the helper slices out of post-create.sh by its column-0 anchor"
    assert_contains "$body" "ln -s" \
        "the sliced body is the link-creating one, not an empty match"
}

# The extraction must not leave the helper defined but uncalled — every
# behavioural case below would stay green while no container ever got a link.
# The cache path is pinned too: it is the volume docker-compose.yml mounts.
# Anchored at both ends (BRE) so a comment quoting the call cannot satisfy it.
test_script_calls_helper_with_the_volume_path() {
    assert_file_contains "$POST_CREATE" '^ensure_codegraph_link "\$PROJECT_ROOT" /cache/codegraph$' \
        "post-create.sh invokes the helper against the /cache/codegraph volume"
}

test_creates_link_when_absent_and_cache_present() {
    local sb out
    new_sandbox sb || return 1
    out="$(run_link "$sb/root" "$sb/cache")"
    assert_true "[ -L '$sb/root/.codegraph' ]" ".codegraph is created as a symlink"
    assert_equals "$sb/cache" "$(command readlink "$sb/root/.codegraph" 2>/dev/null || true)" \
        "…pointing at the cache dir"
    assert_contains "$out" "Linked .codegraph -> $sb/cache" "the creation is reported"
}

test_leaves_existing_directory_alone() {
    local sb out
    new_sandbox sb || return 1
    command mkdir "$sb/root/.codegraph"
    command touch "$sb/root/.codegraph/keep"
    out="$(run_link "$sb/root" "$sb/cache")"
    assert_true "[ -d '$sb/root/.codegraph' ] && [ ! -L '$sb/root/.codegraph' ]" \
        "an existing .codegraph directory is not replaced by a link"
    assert_file_exists "$sb/root/.codegraph/keep" "…and its contents survive"
    assert_equals "" "$out" "nothing is reported when nothing is linked"
}

# A link whose target does not exist fails `-e` but must still count as present:
# without the `! -L` clause, `ln -s` onto it fails with "File exists" and aborts
# post-create under `set -e`.
test_leaves_dangling_link_alone() {
    local sb out
    new_sandbox sb || return 1
    command ln -s "$sb/nowhere" "$sb/root/.codegraph"
    out="$(run_link "$sb/root" "$sb/cache")"
    assert_equals "$sb/nowhere" "$(command readlink "$sb/root/.codegraph" 2>/dev/null || true)" \
        "a dangling .codegraph link is left pointing where it pointed"
    assert_equals "" "$out" "the dangling link is treated as present, not re-created"
}

test_leaves_existing_link_alone() {
    local sb out
    new_sandbox sb || return 1
    command mkdir "$sb/elsewhere"
    command ln -s "$sb/elsewhere" "$sb/root/.codegraph"
    out="$(run_link "$sb/root" "$sb/cache")"
    assert_equals "$sb/elsewhere" "$(command readlink "$sb/root/.codegraph" 2>/dev/null || true)" \
        "an existing .codegraph link keeps its target"
    assert_true "[ ! -e '$sb/elsewhere/cache' ]" \
        "…and no link is nested inside the directory it points at"
    assert_equals "" "$out" "nothing is reported when nothing is linked"
}

test_no_link_when_cache_absent() {
    local sb out
    new_sandbox sb || return 1
    command rmdir "$sb/cache"
    out="$(run_link "$sb/root" "$sb/cache")"
    assert_true "[ ! -e '$sb/root/.codegraph' ] && [ ! -L '$sb/root/.codegraph' ]" \
        "no .codegraph is created when the cache volume is not mounted"
    assert_equals "" "$out" "nothing is reported when nothing is linked"
}

test_suite "devcontainer post-create .codegraph link (#1173)"

run_test test_helper_slices_out "the link helper slices out of post-create.sh"
run_test test_script_calls_helper_with_the_volume_path "post-create.sh calls the helper with /cache/codegraph"
run_test test_creates_link_when_absent_and_cache_present "absent link + mounted cache creates the link"
run_test test_leaves_existing_directory_alone "an existing .codegraph directory is left alone"
run_test test_leaves_dangling_link_alone "a dangling .codegraph link is left alone"
run_test test_leaves_existing_link_alone "an existing .codegraph link is left alone"
run_test test_no_link_when_cache_absent "no link when the cache dir is absent"

generate_report
