#!/usr/bin/env bash
# Single entry point for the librarian test suite.
#
# The stage list lives in tests/shards/NN-<area>.sh, not here (#960). It used to
# be a ~95-line numbered comment block in this header, restating every dispatch
# below it — two lists of the same fact, which drifted (a gate could be renamed
# in one and not the other, and validate-okf-bundle-gate.sh had to assert both).
# Read tests/shards/ for what runs; `bash tests/run-all.sh --shard 10` runs one.
#
# Each stage is run to completion (no early exit) so a failure in one still
# lets the others report. Exits non-zero if any stage fails. No Docker; node +
# bash + coreutils only (jq is used opportunistically by the contract gate).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scrub git's hook-exported environment ONCE for the whole suite. A git hook
# (lefthook pre-push runs this entry point) exports GIT_DIR / GIT_WORK_TREE /
# GIT_INDEX_FILE / … into its child's environment; a test that shells out to
# `git` for a sandbox it built with `cd $sb` then silently resolves against the
# OUTER repo instead, because an inherited GIT_DIR overrides cwd-based discovery.
# That is a whole CLASS of "passes on a bare `bash tests/run-all.sh`, fails under
# `git push`" flakes (each individual test also scrubs where it must, but a
# missed site reopens it — so we belt-and-suspenders scrub here at the single
# entry point CI and the hook share, making the suite hook-environment-agnostic).
# `git rev-parse` any value we need is re-derived cwd-locally by the tests
# themselves. Unexport, don't just blank: a blank GIT_DIR="" still overrides
# discovery. Names mirror config.sh's PATH-redirect scrub class (#279/#328).
for _gv in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    unset "$_gv" 2>/dev/null || true
done
unset _gv

rc=0

# Names of the stages that FAILED, one per line, accumulated by run_stage (#854).
# A plain newline-delimited string rather than an array: bash-3.2 clean per the
# repo's portability floor, and the summary wants it as text anyway.
failed_stages=""

# Reserved exit code a stage returns to mean "did NOT run" (see run_stage below).
# Kept in sync with the same constant in tests/lint-python.sh.
SKIP_EXIT_CODE=77

# Diagnostic markers. A stage that hangs otherwise takes the whole job to the CI
# job-level timeout (15m) with no indication of WHICH stage stalled — and GitHub
# purges timed-out-job logs, so the culprit is unrecoverable afterward. The
# `[>>] <stage> :: entering at HH:MM:SS` line makes the LAST such line in the live
# log name the hung stage; `[ok] <stage> (Ns)` gives per-stage elapsed for
# spotting a slow (not yet hung) stage before it crosses the limit.
#
# NB: deliberately NO per-stage `timeout` wrapper. Some stages
# (validate-golem-watch.sh) deliver a GROUP signal (`kill -INT -<pgid>`) to
# exercise cleanup traps; wrapping the stage in `timeout`/`setsid` perturbs the
# process-group topology that delivery depends on and can make an escaped SIGINT
# kill run-all itself (exit 130). Markers alone name the culprit without touching
# signal behaviour — the robust minimal win. (A safe per-stage kill-budget is a
# follow-up once the golem-watch group-signal path is itself made CI-robust.)
#
# Skip reporting (#538): a stage that could not run — its linter is absent —
# exits with the reserved sentinel SKIP_EXIT_CODE (77, the autotools SKIP
# convention) and is rendered `[SKIP] … did not run`, NOT `[ok]`. Before this,
# tests/lint-python.sh's skip-if-absent branch exited 0 and the summary printed
# `[ok] Python lint + format (ruff) (0s)` — indistinguishable from a real pass,
# so the gate sat vacuous and unnoticed on a host with no ruff. A skip does not
# fail the suite (rc is untouched); it just stops lying about having run. Any
# future skip-if-absent gate gets the same treatment by returning 77.
#
# Step-summary escalation (#741). The `[SKIP]` line above fixes the confusion
# between "passed" and "did not run" only for someone READING the log. A gate
# that has quietly stopped running for weeks still looks like a gate that keeps
# passing to anyone glancing at a green check — the log line is buried in
# thousands of others and nobody scrolls a job that succeeded. So on GitHub the
# skip is also written to $GITHUB_STEP_SUMMARY, which renders on the run page
# itself. That is the whole point of the sentinel carried one surface further
# out: 77 stopped the gate lying to the log, this stops it lying to the summary.
#
# Emission is conditional on $GITHUB_STEP_SUMMARY being set and non-empty, so a
# local `just test` is completely unaffected — no file is created, nothing is
# printed differently. The `:-` is load-bearing, not defensive style: this
# script runs under `set -u` (above), where a bare `$GITHUB_STEP_SUMMARY` off
# GitHub is a FATAL unbound-variable error that would abort the whole suite at
# the first skipped gate. `:-` covers unset and empty in the same test.
#
# The header is written LAZILY, on the first skip only, tracked by a plain flag
# variable. Two properties, both deliberate: a run with no skips adds no section
# at all (an empty "Skipped gates" heading would be its own small lie), and a
# run with several adds one heading over a list rather than repeating it. A
# plain string flag rather than an associative array keeps this bash-3.2 clean
# per the repo's portability floor.
_skips_header_written=""

# Append one skipped stage to the GitHub run-page summary. No-op off GitHub.
#
# Failures are absorbed with `|| true`: the summary is a REPORTING nicety, and a
# read-only or full $GITHUB_STEP_SUMMARY must never turn a skipped stage into a
# failed suite. Losing the line is the correct degradation — the `[SKIP]` stdout
# line above still carries the signal.
#
# `2>/dev/null` comes BEFORE the append, and the order is load-bearing. Bash
# applies redirections left to right, so the familiar `>>"$f" 2>/dev/null`
# spelling opens the file FIRST — and when that open fails, the shell's
# "Is a directory" / "Permission denied" diagnostic is written to the stderr
# still in effect, i.e. the terminal. The failure is absorbed but its noise is
# not, which puts an alarming-looking error in the middle of a suite that is
# otherwise fine. Redirecting stderr first means the diagnostic lands in
# /dev/null along with everything else.
#
# `${_skips_header_written:-}` BELOW IS NOT BELT-AND-BRACES. The function's first
# line already guards $GITHUB_STEP_SUMMARY defensively; reading the flag bare on
# the very next line contradicted that, and under `set -u` an out-of-scope read
# is fatal rather than falsy. The top-level initialisation above covers the
# normal runner path — but this function is routinely SLICED out of this file
# with `sed` and eval'd in isolation (validate-skip-visibility.sh and
# validate-lint-gates.sh both do it), and a sed-extracted function body does not
# carry a top-level assignment. So every slicer had to hand-carry the
# declaration or die; matching the guard style retires that for all of them.
#
# The bug could only ever appear on CI: the whole branch is gated on
# $GITHUB_STEP_SUMMARY, which is set on a GitHub runner and nowhere else, so a
# local run returns before touching the flag. tests/validate-skip-visibility.sh
# pins it — deliberately slicing the function WITHOUT the initialisation.
note_skip_in_step_summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    if [ -z "${_skips_header_written:-}" ]; then
        _skips_header_written=1
        {
            printf '\n### Skipped gates\n\n'
            printf 'These gates did NOT run — their tooling was unavailable. '
            printf 'A gate that skips persistently is not a gate.\n\n'
        } 2>/dev/null >>"$GITHUB_STEP_SUMMARY" || true
    fi
    printf -- '- **%s** — did not run (exit %s)\n' "$1" "$SKIP_EXIT_CODE" \
        2>/dev/null >>"$GITHUB_STEP_SUMMARY" || true
}

run_stage() {
    local label="$1"
    shift
    printf '\n========================================\n'
    printf '  %s\n' "$label"
    printf '========================================\n'
    printf '[>>] %s :: entering at %s\n' "$label" "$(date -u +%H:%M:%S 2>/dev/null || echo '?')"
    local _start _end _elapsed
    _start="$(date +%s 2>/dev/null || echo 0)"
    # Capture the exit STATUS, not just pass/fail: 77 is a third outcome and an
    # `if "$@"; then` discards the code that distinguishes it from a failure.
    local _rc=0
    "$@" || _rc=$?
    _end="$(date +%s 2>/dev/null || echo 0)"
    _elapsed=$((_end - _start))
    if [ "$_rc" -eq 0 ]; then
        printf '[ok] %s (%ss)\n' "$label" "$_elapsed"
    elif [ "$_rc" -eq "$SKIP_EXIT_CODE" ]; then
        printf '[SKIP] %s — did not run (%ss)\n' "$label" "$_elapsed"
        note_skip_in_step_summary "$label"
    else
        printf '[FAIL] %s (%ss)\n' "$label" "$_elapsed"
        rc=1
        # `:-` so run_stage stays self-contained. The suite always initialises
        # failed_stages above, but tests/validate-lint-gates.sh SLICES this
        # function out of the source and eval's it alone under `set -u`, where a
        # bare $failed_stages is a fatal unbound-variable error — which would
        # break that gate's pass/fail rendering cases from a distance.
        failed_stages="${failed_stages:-}${label}
"
    fi
}

# --- Stage dispatch: the shard manifest (#960) -------------------------------
#
# The ~96 stages used to be listed inline here and run strictly in sequence,
# which was 97% of CI wall clock (22m03s of a 22m47s run). They now live in
# tests/shards/NN-<area>.sh so ci.yml can run them as a matrix.
#
# THE MANIFEST IS EXPLICIT AND ORDERED, NEVER A GLOB — same rule and same reason
# as tests/lib/fragments.sh and the workflow.src/ manifests. source_shards fails
# the suite in BOTH directions (a shard on disk nobody listed, a listed shard
# that is missing), because a glob would let a whole area of the suite stop
# running while every shard still reported green.
SHARDS="10-portability.sh 20-golem.sh 30-scanners.sh"

# shellcheck source=tests/lib/shards.sh
source "$SCRIPT_DIR/lib/shards.sh"

# WHICH SHARDS THIS INVOCATION RUNS. Default: all of them, in order — so `just
# test`, the lefthook pre-push hook, and a bare `bash tests/run-all.sh` are
# unchanged in behaviour, which is AC1. `--shard NN-name.sh` (or a bare prefix
# like `10`) runs exactly one, which is what the CI matrix passes.
#
# An unknown shard is a HARD ERROR, not an empty run. A typo'd matrix entry that
# silently ran nothing would report success for a shard that never executed —
# the #906 failure this whole issue is trying not to reproduce.
SELECTED="$SHARDS"
if [ "${1:-}" = "--shard" ]; then
    [ "$#" -ge 2 ] || {
        command printf 'FATAL: --shard needs a shard name\n' >&2
        exit 2
    }
    SELECTED=""
    for _s in $SHARDS; do
        case "$_s" in
            "$2" | "$2".sh | "$2"-*) SELECTED="$_s" ;;
        esac
    done
    [ -n "$SELECTED" ] || {
        command printf 'FATAL: unknown shard %s (have: %s)\n' "$2" "$SHARDS" >&2
        exit 2
    }
    command printf 'Running shard: %s\n' "$SELECTED"
    shift 2
fi

# THE PARTITION GATE RUNS FIRST, AND IN EVERY SHARD.
#
# It validates the manifest itself: that no shard file is unlisted, no listed
# shard is missing, no stage is claimed twice, and every tests/*.sh gate is
# dispatched by SOME shard. Running it in every shard rather than pinning it to
# one is deliberate — a matrix entry that silently ran nothing would otherwise be
# reported only by whichever shard happened to own the gate, and that shard is
# exactly the one that might not be running. It costs ~1s.
#
# Before source_shards, so a broken manifest is reported as a failed stage rather
# than as source_shards' bare FATAL abort with no suite summary.
run_stage "Shard partition (manifest + coverage)" bash "$SCRIPT_DIR/validate-shards.sh"

# shellcheck disable=SC2086  # word splitting is the point: SELECTED is a list
source_shards "$SCRIPT_DIR/shards" $SELECTED

# Render the end-of-run verdict (#854).
#
# WHY THE FAILURE HALF ALSO GOES TO STDERR. The natural way to read a suite that
# emits thousands of lines is `bash tests/run-all.sh | tail -45` — and a pipeline
# exits with the status of its LAST command, so the caller sees `tail`'s 0 no
# matter how red the suite was. A script cannot fix that from the inside: the
# `set -o pipefail` that would is a property of the INVOKING shell. What it can
# do is make the failure impossible to lose. stderr is not part of a stdout-only
# pipe, so mirroring the verdict there puts it on the terminal even when stdout
# has been piped, redirected, or truncated by `head`. Observed failure this
# closes: a run whose "Markdown lint (.claude/memory/)" stage failed reported
# exit 0 through `| tail`, and only a ~9-minute re-run with output captured to a
# file revealed it.
#
# This is the 77/[SKIP] hazard reached by another route — "a silent skip is
# indistinguishable from a pass" — except in the more dangerous direction, green
# when red, which is what an agent or script keys off before committing.
#
# THE PASSING PATH STAYS SILENT ON STDERR, deliberately. A mirror that also
# announced success would put text on stderr on every green run, which trains
# every caller to ignore the stream and costs exactly the signal this exists to
# add. Failure is the only thing worth interrupting for.
#
# THE FAILED-STAGE NAMES PRINT LAST, after the banner, for the same reason the
# mirror exists: `| tail -N` keeps the END of the output, so putting the list
# there means a truncating reader sees WHICH stage died rather than only that
# something did. stdout keeps the full verdict too — unchanged for anyone
# already reading it.
print_summary() {
    local _line
    printf '\n========================================\n'
    if [ "$rc" -eq 0 ]; then
        printf '  All test stages passed\n'
        printf '========================================\n'
        return 0
    fi
    printf '  One or more test stages FAILED\n'
    printf '========================================\n'
    printf '%s' "${failed_stages:-}" | while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        printf '  [FAIL] %s\n' "$_line"
    done
    printf '\nExit code is %s. NOTE: piping this suite (`| tail`, `| grep`)\n' "$rc"
    printf 'discards it — the pipeline reports the LAST command status. Capture\n'
    printf 'instead:  bash tests/run-all.sh > /tmp/run.log 2>&1; echo $?\n'
}

# Emit the verdict on every stream that must carry it. The stream DECISION lives
# here rather than at the call site so it is testable: tests/validate-run-all-
# reporting.sh slices this function out of the source and runs it over synthetic
# stages. A call site that inlined `|| print_summary >&2` would leave the test
# supplying the mirror itself — the fixture would then pass with the mirror
# removed, which is the tautology this split exists to prevent.
emit_summary() {
    print_summary
    # The failure half again on stderr, which a stdout-only pipe cannot swallow.
    [ "$rc" -eq 0 ] || print_summary >&2
}

emit_summary

exit "$rc"
