#!/usr/bin/env bash
# Coverage for bin/probe-fuse-rename.sh (issue #1193).
#
# The probe replays git's index-lock protocol and counts filesystem anomalies;
# its findings are evidence in docs/verification/bindfs-index-lock-e2e-1193.md.
# What must not regress:
#
#   1. IT REPORTS A COUNT — a run prints `cycles=<n> anomalies=<n> fs=<type>`
#      and exits 0 or 1 by that count. Whether a given host shows anomalies is
#      the thing being measured, so this suite never asserts 0: on the bindfs
#      mount the probe exists to expose, a clean run is not guaranteed.
#   2. IT CLEANS ONLY ITS OWN SCRATCH — the parent dir keeps a sentinel file and
#      is left with no `probe-fuse-rename.*` subdir afterwards.
#   3. A FAULT IS REPORTED, AND THE PROBE'S OWN FAILURES ARE NOT FAULTS — a
#      PATH-stubbed `mv` that always fails must produce `rename-lost-source`
#      rows and exit 1, with each cycle counted ONCE (the cleanup in that branch
#      is what stops a leftover lock adding a second `exclusive-create-refused`
#      row). A payload that cannot be created must exit 2, never be reported as
#      a stream of `write-lost-file` filesystem faults.
#   4. IT REFUSES BAD INPUT LOUDLY — no args, a non-numeric cycle count, a
#      missing directory and `/` each exit 2. `/` matters most: an unguarded
#      path in a probe that deletes its scratch dir is how `rm -rf /*` happens.
#
# BASH_ENV is unset for the stubbed runs: this devcontainer's /etc/bash_env
# resets PATH, which would silently undo the stub dir.
#
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE="$REPO_ROOT/bin/probe-fuse-rename.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "probe-fuse-rename.sh index-lock rename probe (#1193)"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf -- "${WORKDIR:?}"' EXIT

OUT=""
RC=0
run_probe() {
    RC=0
    OUT="$(bash "$PROBE" "$@" 2>&1)" || RC=$?
}

test_reports_a_count_and_exits_by_it() {
    run_probe "$WORKDIR" 50
    assert_contains "$OUT" "cycles=50 anomalies=" "a run prints its cycle and anomaly counts"
    case "$RC" in
        0) assert_contains "$OUT" "anomalies=0 " "exit 0 means zero anomalies" ;;
        1) assert_contains "$OUT" "anomaly=" "exit 1 carries at least one anomaly row" ;;
        *) assert_exit 0 "$RC" "a run exits 0 or 1, never a usage code" ;;
    esac
}

test_cleans_only_its_own_scratch() {
    local d leftover
    d="$(command mktemp -d "$WORKDIR/parent.XXXXXX")"
    : >"$d/sentinel"
    run_probe "$d" 5
    assert_file_exists "$d/sentinel" "the parent's own files are untouched"
    leftover="$(command ls "$d" | command grep -c '^probe-fuse-rename\.' || true)"
    assert_equals "0" "$leftover" "the scratch subdir is removed on exit"
}

# stub_bin <name> <body> — a stub dir holding one failing tool, echoed.
stub_bin() {
    local dir
    dir="$(command mktemp -d "$WORKDIR/stub.XXXXXX")" || return 1
    command printf '#!/usr/bin/env bash\n%s\n' "$2" >"$dir/$1"
    command chmod +x "$dir/$1"
    command printf '%s' "$dir"
}

run_probe_stubbed() { # run_probe_stubbed <stubdir> <args...>
    local stub="$1"
    shift
    RC=0
    OUT="$(command env -uBASH_ENV PATH="$stub:$PATH" bash "$PROBE" "$@" 2>&1)" || RC=$?
}

test_failing_rename_is_counted_once_per_cycle() {
    local stub d
    stub="$(stub_bin mv 'exit 1')"
    d="$(command mktemp -d "$WORKDIR/mv.XXXXXX")"
    run_probe_stubbed "$stub" "$d" 5
    assert_exit 1 "$RC" "a fault exits 1"
    assert_contains "$OUT" "anomaly=rename-lost-source cycle=5" "every cycle's lost rename is reported"
    assert_contains "$OUT" "cycles=5 anomalies=5 " "one fault per cycle, not two"
    assert_not_contains "$OUT" "exclusive-create-refused" "the probe's leftover must not refuse the next create"
}

test_missing_payload_is_refused_not_a_fault() {
    local stub d
    stub="$(stub_bin head 'exit 1')"
    command printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/dd"
    command chmod +x "$stub/dd"
    d="$(command mktemp -d "$WORKDIR/payload.XXXXXX")"
    run_probe_stubbed "$stub" "$d" 5
    assert_exit 2 "$RC" "no payload is a setup error"
    assert_contains "$OUT" "cannot create the payload" "the refusal names the cause"
    assert_not_contains "$OUT" "write-lost-file" "setup failure is never blamed on the filesystem"
}

test_no_args_is_usage() {
    run_probe
    assert_exit 2 "$RC" "no directory is a usage error"
}

test_bad_cycles_is_usage() {
    run_probe "$WORKDIR" abc
    assert_exit 2 "$RC" "a non-numeric cycle count is a usage error"
    assert_not_contains "$OUT" "cycles=" "a usage error runs no cycles"
}

test_missing_dir_is_usage() {
    run_probe "$WORKDIR/does-not-exist" 5
    assert_exit 2 "$RC" "a missing directory is a usage error"
}

test_root_is_refused() {
    run_probe / 5
    assert_exit 2 "$RC" "the probe refuses to run at /"
    assert_contains "$OUT" "refusing" "the refusal says so"
}

run_test test_reports_a_count_and_exits_by_it "run: prints cycles/anomalies and exits 0|1 by the count"
run_test test_cleans_only_its_own_scratch "cleanup: removes only its own scratch subdir"
run_test test_failing_rename_is_counted_once_per_cycle "fault: stubbed failing mv → one rename-lost-source per cycle, exit 1"
run_test test_missing_payload_is_refused_not_a_fault "setup: no payload → exit 2, never write-lost-file"
run_test test_no_args_is_usage "usage: no args → exit 2"
run_test test_bad_cycles_is_usage "usage: non-numeric cycles → exit 2, no run"
run_test test_missing_dir_is_usage "usage: missing directory → exit 2"
run_test test_root_is_refused "usage: / is refused → exit 2"

generate_report
