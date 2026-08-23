# shellcheck shell=bash
# Shared scratch dir + scanner drivers for the check-decomposition detector
# fragments (issue #760 — extracted from the 2,873-line
# tests/validate-decomposition-detectors.sh).
#
# Sourced by tests/validate-decomposition-detectors.sh BEFORE its area fragments
# under tests/validate-decomposition-detectors/. Every driver here is used by
# many fragments (assert_fires alone has ~127 call sites); a helper used by
# exactly one area stays in that area's file.
#
# The entry point defines PY / SH / REAL_BASH before sourcing this file — the
# two scanner paths and the resolved interpreter the bash fallback runs under.
#
# Two invariants to preserve when editing:
#
#   * Every assertion runs against BOTH impls — the Python primary (patterns.py)
#     and the bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh). That is free
#     parity reinforcement on top of validate-python-ports.sh's whole-corpus
#     diff, and it is why assert_fires/assert_silent each assert twice rather
#     than taking an impl argument.
#   * The Python side SKIPS (does not fail) when a python3>=3.11 is absent, via
#     the HAVE_PY probe below — the same posture as validate-python-ports.sh.
#     The bash path is still asserted where present, so a python-less host still
#     gets real coverage rather than a silently empty run.
#
# The scanner reads only file CONTENT (no git-rooting), so every fixture runs
# from $WORKDIR and CWD is irrelevant.
#
# Pure bash-3.2 + coreutils; full command paths per project convention.

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Compact thresholds so small fixtures reach the seam/size arms. Applied to
# every invocation unless a case overrides them.
BASE_ENV="DECOMP_LOC_WARN=5 DECOMP_LOC_HIGH=400 DECOMP_SEAM_MIN_LINES=8 DECOMP_SEAM_MIN_UNITS=3"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL LIST CAT [ENV...] — rows one impl emits for a single category.
emit_rows() {
    local impl="$1" list="$2" cat="$3"
    shift 3
    if [ "$impl" = py ]; then
        # shellcheck disable=SC2086  # BASE_ENV is a deliberate word-split list
        /usr/bin/env $BASE_ENV "$@" python3 "$PY" "$list" 2>/dev/null
    else
        # shellcheck disable=SC2086  # BASE_ENV is a deliberate word-split list
        /usr/bin/env PATTERNS_FORCE_BASH=1 $BASE_ENV "$@" "$REAL_BASH" "$SH" "$list" 2>/dev/null
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires LIST CAT NEEDLE MSG [ENV...] — the category fires (rows contain
# NEEDLE) in BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local list="$1" cat="$2" needle="$3" msg="$4"
    shift 4
    assert_contains "$(emit_rows sh "$list" "$cat" "$@")" "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$list" "$cat" "$@")" "$needle" "$msg (python)"
    fi
}

# assert_silent LIST CAT MSG [ENV...] — the category emits NOTHING in both impls.
assert_silent() {
    local list="$1" cat="$2" msg="$3"
    shift 3
    assert_output_empty "$(emit_rows sh "$list" "$cat" "$@")" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$list" "$cat" "$@")" "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path globs match cleanly.
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# list_of PATH... — write a newline file list into WORKDIR, echo its path.
list_of() {
    local lf
    lf="$(command mktemp "$WORKDIR/list.XXXXXX")"
    command printf '%s\n' "$@" >"$lf"
    command printf '%s\n' "$lf"
}
