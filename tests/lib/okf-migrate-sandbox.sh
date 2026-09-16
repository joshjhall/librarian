# shellcheck shell=bash
# Shared fixture plumbing for tests/validate-okf-migrate.sh (issue #671).
#
# Sourced by the entry point, used by every fragment. A helper used by exactly
# ONE area stays in that area's fragment — the shared library must not accrete
# single-use code.
#
# The engine has a MODE-SHAPED CLI (check|plan|apply), not the file-list shape
# every pre-scan uses, so these drivers pass a mode rather than a list path.

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while git and realpath-based code resolve the
# same dir to /private/var/... Any prefix match between the two spellings fails,
# silently dropping rows or refusing valid paths (#932).
okf_migrate_workdir() {
    local d
    d="$(command mktemp -d)"
    (cd "$d" && command pwd -P)
}

# fresh_bundle WORKDIR — a new empty bundle, printing its ROOT.
#
# The root is always `<case>/.claude/memory`, the tool's own default spelling,
# so a fixture exercises the real discovery path rather than an env override
# that happens to work.
fresh_bundle() {
    local case_dir
    case_dir="$(command mktemp -d "$1/case.XXXXXX")"
    command mkdir -p "$case_dir/.claude/memory"
    command printf '%s' "$case_dir/.claude/memory"
}

# write_concept ROOT RELPATH BODY — a concept file, parent dirs created.
write_concept() {
    local root="$1" rel="$2" body="$3" dir
    dir="$(command dirname "$root/$rel")"
    command mkdir -p "$dir"
    command printf '%s\n' "$body" >"$root/$rel"
}

# run_py MODE ROOT [ARGS...] — the python primary.
# run_sh MODE ROOT [ARGS...] — the bash fallback, forced.
#
# BOTH SET TWO GLOBALS AND PRINT NOTHING: OKF_OUT (stdout+stderr) and OKF_RC
# (exit code). They deliberately do NOT print the output for `$( )` capture,
# because a command substitution runs in a SUBSHELL — an OKF_RC assigned there
# dies with it, and the caller reads either a stale value or, under `set -u`,
# dies with `OKF_RC: unbound variable`. Measured: that is exactly how the first
# run of this suite failed, on the first case that read OKF_RC after a capture.
#
# So callers read the globals:
#
#     run_sh plan "$root"
#     assert_exit 0 "$OKF_RC" "plan exits 0"
#     assert_contains "$OKF_OUT" "+++ b/" "plan renders a diff"
#
# $OKF_MIGRATE_CONFIG_DIR is passed THROUGH (empty unless a caller set it) so a
# case can point the engine at a fixture thresholds.yml — the move-concept cases
# need a configured taxonomy, whose shipped default is deliberately empty.
#
# OKF_TODAY is not injected (this engine judges no dates), but the VERSION PIN
# is injected in every case: a fixture that inherited the repo's pin would start
# failing the day someone bumps it, which is a silent false verdict rather than
# a red test.
# shellcheck disable=SC2034  # OKF_OUT/OKF_RC are the documented cross-file
# contract of these drivers; every consumer is a sourced fragment.
run_py() {
    local mode="$1" root="$2"
    shift 2
    OKF_RC=0
    OKF_OUT="$(OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        OKF_MIGRATE_CONFIG_DIR="${OKF_MIGRATE_CONFIG_DIR:-}" \
        command python3 "$OKF_MIGRATE_PY" "$mode" "$@" 2>&1)" || OKF_RC=$?
}

# shellcheck disable=SC2034  # its OWN directive: a bare one covers only the
# NEXT statement, so run_py's does not reach here (CLAUDE.md § split suites).
run_sh() {
    local mode="$1" root="$2"
    shift 2
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        OKF_MIGRATE_CONFIG_DIR="${OKF_MIGRATE_CONFIG_DIR:-}" \
        command bash "$OKF_MIGRATE_SH" "$mode" "$@" 2>&1)" || OKF_RC=$?
}

# NO run_impl DISPATCHER HERE, deliberately. validate-okf-detectors.sh has one
# because every case there asserts against BOTH impls; here the correctness
# fragments drive the bash fallback (the portable floor) and 60-parity.sh calls
# run_py/run_sh directly to compare them. A dispatcher nobody calls is exactly
# the single-use accretion the shared library is supposed to stay free of.

# validator_rows ROOT — the REAL check-okf-conformance rows for ROOT.
#
# SETS TWO GLOBALS AND PRINTS NOTHING, for the same reason run_sh/run_py do: a
# `$( )` capture is a SUBSHELL, so an OKF_LISTED assigned inside one dies with
# it and the caller's guard reads unbound. Callers use $OKF_ROWS and $OKF_LISTED.
#
# THE VACUITY GUARD IS THE POINT. patterns.py takes a newline FILE LIST as
# argv[1], never a bundle directory — handed a directory it scans nothing and
# still exits 0, so a reversibility assertion against it would pass while
# checking nothing. This publishes the list length as OKF_LISTED, which every
# caller asserts non-zero BEFORE trusting a zero-row result. The trap is
# documented at tests/validate-okf-authoring.sh:849-866.
# shellcheck disable=SC2034  # OKF_ROWS/OKF_LISTED are read by the fragments.
validator_rows() {
    local root="$1" list
    list="$(command mktemp)"
    command find "$root" -type f -name '*.md' | command sort >"$list"
    OKF_LISTED="$(command wc -l <"$list" | command tr -d ' ')"
    OKF_ROWS="$(OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command python3 "$OKF_VALIDATOR_PY" "$list" 2>/dev/null)" || OKF_ROWS=""
    command rm -f "$list"
}

# tree_digest ROOT — a stable digest of every file's path and content, for
# byte-comparing two applied trees (idempotence, cross-impl parity).
tree_digest() {
    local root="$1" f
    command find "$root" -type f | command sort | while IFS= read -r f; do
        command printf '=== %s\n' "${f#"$root"/}"
        command cat "$f"
    done
}
