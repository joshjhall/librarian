#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/main-index-lock-check.sh (issue #1193).
#
# The checker reports a stale `.git/index.lock` in the main checkout — the ghost
# entry the devcontainer's bindfs-over-virtiofs mount leaves behind after git
# renames the lock over the index (docs/verification/bindfs-index-lock-e2e-1193.md).
# The behaviours whose silent regression would hurt:
#
#   1. THE #1193 SIGNATURE — an old lock with the same size, mtime and bytes as
#      the index must read `verdict=stale` AND `identical=yes`. The fixture is a
#      `cp -p` (preserves the mtime) then a backdate of BOTH files, so the
#      identity comparison has to look at the fine-grained mtime, not just age.
#   2. IDENTICAL IS EARNED — an old lock that differs from the index in bytes
#      only (same size, same mtime) must read `identical=no`. Without this case a
#      checker that compared size+mtime and skipped `cmp` would pass case 1.
#   3. YOUNG IS INFLIGHT — a fresh lock is a live git write; reporting it stale
#      invites someone to delete a lock in use, which is how an index corrupts.
#   4. UNAVAILABLE IS NEVER NONE — a repo with no `.git` must say `unavailable`
#      with a reason. `none` would read as "all clear" from a check that never
#      looked (the #538/#571 inert-gate shape).
#   5. READ-ONLY — after every verdict, `index` and `index.lock` keep their
#      inode and mtime and the lock still exists. The script exists to be run
#      against a checkout under suspicion; it must not become a second writer.
#
# Sandboxes are plain directories with a hand-built `.git/` — the checker runs
# no git, so a real `git init` would only add a dependency to no purpose.
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$REPO_ROOT/plugins/workflow/scripts/main-index-lock-check.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "main-index-lock-check.sh stale main index.lock detector (#1193)"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf -- "${WORKDIR:?}"' EXIT

# An old timestamp in touch -t form ([[CC]YY]MMDDhhmm.ss), accepted by GNU and
# BSD touch alike — `touch -d` is GNU-only (CLAUDE.md runtime policy (5)).
OLD_STAMP=202001010000.00

# new_repo <varname> — a dir holding .git/ with a 4 KiB random index.
new_repo() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/repo.XXXXXX")" || return 1
    command mkdir -p "$dir/.git"
    command head -c 4096 /dev/urandom >"$dir/.git/index"
    printf -v "$__out" '%s' "$dir"
}

# fingerprint <file> — inode + mtime, to prove the checker wrote nothing.
fingerprint() {
    command stat -c '%i %y' "$1" 2>/dev/null || command stat -f '%i %Fm' "$1"
}

OUT=""
RC=0
run_check() {
    RC=0
    OUT="$(bash "$CHECK" "$@" 2>&1)" || RC=$?
}

test_identical_old_lock_is_stale_identical() {
    local r before_i before_l
    new_repo r
    command cp -p "$r/.git/index" "$r/.git/index.lock"
    command touch -t "$OLD_STAMP" "$r/.git/index" "$r/.git/index.lock"
    before_i="$(fingerprint "$r/.git/index")"
    before_l="$(fingerprint "$r/.git/index.lock")"
    run_check --repo "$r"
    assert_exit 0 "$RC" "a stale verdict is a report, not a failure"
    assert_contains "$OUT" "verdict=stale" "old lock reads stale"
    assert_contains "$OUT" "identical=yes" "same size+mtime+bytes is the #1193 ghost signature"
    assert_contains "$OUT" "recovery=" "a stale report names the recovery"
    assert_equals "$before_i" "$(fingerprint "$r/.git/index")" "index untouched"
    assert_equals "$before_l" "$(fingerprint "$r/.git/index.lock")" "lock untouched (never removed)"
}

test_same_size_mtime_different_bytes_is_not_identical() {
    local r
    new_repo r
    command head -c 4096 /dev/urandom >"$r/.git/index.lock"
    command touch -t "$OLD_STAMP" "$r/.git/index" "$r/.git/index.lock"
    run_check --repo "$r"
    assert_contains "$OUT" "verdict=stale" "old lock reads stale"
    assert_contains "$OUT" "identical=no" "differing bytes must not read as identical"
}

test_old_lock_different_mtime_is_not_identical() {
    local r
    new_repo r
    command cp -p "$r/.git/index" "$r/.git/index.lock"
    command touch -t "$OLD_STAMP" "$r/.git/index.lock"
    run_check --repo "$r"
    assert_contains "$OUT" "verdict=stale" "old lock reads stale"
    assert_contains "$OUT" "identical=no" "same bytes but a different mtime is not the ghost signature"
}

test_young_lock_is_inflight() {
    local r
    new_repo r
    command cp -p "$r/.git/index" "$r/.git/index.lock"
    command touch "$r/.git/index.lock"
    run_check --repo "$r" --min-age 3600
    assert_contains "$OUT" "verdict=inflight" "a fresh lock is a live write"
    assert_not_contains "$OUT" "verdict=stale" "never call a live lock stale"
    assert_file_exists "$r/.git/index.lock" "inflight lock left in place"
}

test_no_lock_is_none() {
    local r
    new_repo r
    run_check --repo "$r"
    assert_equals "verdict=none" "$OUT" "no lock reads none"
}

test_no_git_dir_is_unavailable_never_none() {
    local r
    r="$(command mktemp -d "$WORKDIR/nogit.XXXXXX")"
    run_check --repo "$r"
    assert_exit 0 "$RC" "unavailable is a verdict, not a crash"
    assert_contains "$OUT" "verdict=unavailable" "no .git reads unavailable"
    assert_contains "$OUT" "reason=" "unavailable names its reason"
    assert_not_contains "$OUT" "verdict=none" "a check that could not look must not report all-clear"
}

test_bad_min_age_fails_loud() {
    local r
    new_repo r
    run_check --repo "$r" --min-age abc
    assert_exit 2 "$RC" "a malformed --min-age is a usage error"
    assert_not_contains "$OUT" "verdict=" "a usage error emits no verdict"
}

test_unknown_flag_fails_loud() {
    run_check --bogus
    assert_exit 2 "$RC" "an unknown flag is a usage error"
}

run_test test_identical_old_lock_is_stale_identical "stale: cp -p ghost lock → stale + identical=yes, files untouched"
run_test test_same_size_mtime_different_bytes_is_not_identical "stale: same size+mtime, different bytes → identical=no"
run_test test_old_lock_different_mtime_is_not_identical "stale: same bytes, different mtime → identical=no"
run_test test_young_lock_is_inflight "inflight: a lock younger than --min-age is left alone"
run_test test_no_lock_is_none "none: no index.lock"
run_test test_no_git_dir_is_unavailable_never_none "unavailable: no .git → unavailable + reason, never none"
run_test test_bad_min_age_fails_loud "usage: non-numeric --min-age → exit 2, no verdict"
run_test test_unknown_flag_fails_loud "usage: unknown flag → exit 2"

generate_report
