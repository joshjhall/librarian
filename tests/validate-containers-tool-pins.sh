#!/usr/bin/env bash
# Behavior gate for tests/lint-containers-tool-pins.sh — every arm, against a
# throwaway superproject + containers repo, so the gate is proven to FIRE and not
# only to pass on today's tree. Each case is built on the arm that disagrees when
# its logic is removed:
#
#   pins agree                      -> 0   (the control)
#   template drifts from containers -> 1, naming both values
#   containers pins a tool twice    -> 1   (the image's version is undefined)
#   containers lib/ parses 0 pins   -> 1   (the floor, not a vacuous pass)
#   template parses 0 core pins     -> 1   (the template-side floor)
#   no tool matches (mapping broke) -> 1   (everything "unpinned" must not pass)
#   recorded commit not available   -> 77, never 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

GATE="$SCRIPT_DIR/lint-containers-tool-pins.sh"

test_suite "lint-containers-tool-pins fires on every arm"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Isolate from any ambient git state the caller runs under.
GIT_SCRUB=(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR)
g() { /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -c user.email=t@t -c user.name=t "$@"; }

# make_case <varname> <containers-lib-body> <core-versions> [uv] [ruff]
# A superproject whose `containers` gitlink points at a commit in a sibling
# containers repo, exposed at <sp>/containers via symlink so `git -C` reaches it.
make_case() {
    local __out="$1" lib="$2" core="$3" uv="${4:-0.13.7}" ruff="${5:-0.17.4}" _d _c _sp _sha
    _d="$(command mktemp -d "$WORKDIR/case.XXXXXX")"
    _c="$_d/containers-repo"
    _sp="$_d/sp"
    command mkdir -p "$_c/lib/features" "$_sp"
    g init -q "$_c"
    command printf '%b' "$lib" >"$_c/lib/features/tools.sh"
    g -C "$_c" add -A && g -C "$_c" commit -qm c
    _sha="$(g -C "$_c" rev-parse HEAD)"
    g init -q "$_sp"
    local T="$_sp/plugins/dev-core/skills/repo-baseline/templates"
    command mkdir -p "$T/core" "$T/shell" "$T/python"
    command printf '%b' "$core" >"$T/core/tools.versions"
    command printf '# shell slice\n' >"$T/shell/tools.versions"
    command printf 'required-version = "==%s"\n' "$uv" >"$T/python/uv.toml.tmpl"
    command printf 'required-version = "==%s"\n' "$ruff" >"$T/python/ruff.toml.tmpl"
    g -C "$_sp" add -A
    g -C "$_sp" update-index --add --cacheinfo "160000,$_sha,containers"
    g -C "$_sp" commit -qm sp
    command ln -s "$_c" "$_sp/containers"
    printf -v "$__out" '%s' "$_sp"
}

LIB_OK='UV_VERSION="${UV_VERSION:-0.13.7}"\nTYPOS_VERSION="${TYPOS_VERSION:-1.52.0}"\nJUST_VERSION="${JUST_VERSION:-1.59.0}"\n'
CORE_OK='typos=1.52.0\njust=1.59.0\n'

OUT=""
RC=0
run_gate() {
    RC=0
    OUT="$(CONTAINERS_PINS_REPO_ROOT="$1" CONTAINERS_PINS_MIN_SHARED="${2:-2}" \
        bash "$GATE" 2>&1)" || RC=$?
}

test_agreeing_pins_pass() {
    local sp
    make_case sp "$LIB_OK" "$CORE_OK"
    run_gate "$sp"
    assert_equals "0" "$RC" "agreeing pins pass (control)"
}

test_drift_fails_and_names_both_values() {
    local sp
    make_case sp "$LIB_OK" 'typos=1.51.1\njust=1.59.0\n'
    run_gate "$sp"
    assert_equals "1" "$RC" "template drift fails"
    assert_contains "$OUT" "typos: template 1.51.1" "the template value is named"
    assert_contains "$OUT" "1.52.0" "and the containers value"
}

test_python_pin_drift_fails() {
    local sp
    make_case sp "$LIB_OK" "$CORE_OK" 0.12.23
    run_gate "$sp"
    assert_equals "1" "$RC" "a uv required-version drift fails (the case that started this)"
}

test_duplicate_containers_default_fails() {
    local sp
    make_case sp "${LIB_OK}UV_VERSION=\"\${UV_VERSION:-0.13.6}\"\n" "$CORE_OK"
    run_gate "$sp"
    assert_equals "1" "$RC" "one tool with two containers defaults fails"
    assert_contains "$OUT" "ONE default version" "and says why"
}

test_unparseable_containers_lib_fails() {
    local sp
    make_case sp 'export UV=0.13.7\n' "$CORE_OK"
    run_gate "$sp"
    assert_equals "1" "$RC" "0 parsed containers pins fails rather than comparing nothing"
}

test_empty_template_fails() {
    local sp
    make_case sp "$LIB_OK" '# nothing pinned\n'
    # MIN_SHARED=0 so the template-side floor is the ONLY thing that can fail
    # this case; with the default the shared-count floor fires first and the
    # template floor could be deleted unnoticed (measured by mutation).
    run_gate "$sp" 0
    assert_equals "1" "$RC" "0 parsed template core pins fails rather than comparing nothing"
    assert_contains "$OUT" "parsed no tools.versions pins" "and it is the template floor that fired"
}

test_no_shared_tools_fails() {
    local sp
    make_case sp 'OTHER_VERSION="${OTHER_VERSION:-1.0.0}"\n' 'typos=1.52.0\njust=1.59.0\n' 0.13.7
    run_gate "$sp" 2
    assert_equals "1" "$RC" "everything 'not pinned by containers' must not pass as agreement"
}

test_absent_commit_skips_with_77() {
    local sp
    make_case sp "$LIB_OK" "$CORE_OK"
    g -C "$sp" update-index --cacheinfo "160000,1111111111111111111111111111111111111111,containers"
    g -C "$sp" commit -qm absent
    run_gate "$sp"
    assert_equals "77" "$RC" "an unavailable submodule commit is a skip (77), never a pass"
}

# The live tree, so the suite also notices if the real pins drift — but only
# where the real submodule is present; elsewhere the gate's own 77 is expected.
test_live_tree_is_aligned_or_skips() {
    RC=0
    OUT="$(bash "$GATE" 2>&1)" || RC=$?
    case "$RC" in
        0 | 77) assert_true "true" "live tree: aligned (0) or submodule absent (77), got $RC" ;;
        *) assert_equals "0" "$RC" "live tree pins agree with the containers build" ;;
    esac
}

run_test test_agreeing_pins_pass "agreeing pins -> 0"
run_test test_drift_fails_and_names_both_values "core drift -> 1, both values named"
run_test test_python_pin_drift_fails "python required-version drift -> 1"
run_test test_duplicate_containers_default_fails "duplicate containers default -> 1"
run_test test_unparseable_containers_lib_fails "0 containers pins -> 1"
run_test test_empty_template_fails "0 template pins -> 1"
run_test test_no_shared_tools_fails "no tool matched -> 1"
run_test test_absent_commit_skips_with_77 "absent submodule commit -> 77"
run_test test_live_tree_is_aligned_or_skips "live tree aligned or skipped"

generate_report
