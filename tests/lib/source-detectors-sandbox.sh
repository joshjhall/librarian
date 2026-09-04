# shellcheck shell=bash
# Shared drivers for the validate-source-detectors split suite (issue #859).
#
# The suite exercises two review-audit source scanners (check-security and
# check-code-health) through purpose-built fixtures. Everything in this file is
# used by BOTH area fragments; anything used by only one of them stays in that
# fragment, per CLAUDE.md's rule that the shared library must not accrete
# single-use code.
#
# HAVE_PY and REAL_BASH live here rather than in a fragment because both halves
# read them: assert_fires/assert_silent gate the python arm on HAVE_PY, and the
# code-health fragment's own drivers invoke "$REAL_BASH" directly.
#
# Sourced by tests/validate-source-detectors.sh AFTER tests/lib/harness.sh.
# Pure bash-3.2 + coreutils.

# python3>=3.11 availability. The python arm is SKIPPED (not failed) when absent
# — the same posture as validate-python-ports.sh; bash is still asserted.
HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL SKILLDIR LIST CAT [ENV...] — the rows one impl emits for a
# single category. IMPL is "py" or "sh"; extra args are VAR=VALUE env overrides.
emit_rows() {
    local impl="$1" skill="$2" list="$3" cat="$4"
    shift 4
    if [ "$impl" = py ]; then
        /usr/bin/env "$@" python3 "$skill/patterns.py" "$list" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$@" "$REAL_BASH" "$skill/patterns.sh" "$list" 2>/dev/null
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires SKILLDIR LIST CAT NEEDLE MSG [ENV...] — the category fires (rows
# contain NEEDLE) in BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local skill="$1" list="$2" cat="$3" needle="$4" msg="$5"
    shift 5
    assert_contains "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_silent SKILLDIR LIST CAT MSG [ENV...] — the category emits NOTHING in
# both impls.
assert_silent() {
    local skill="$1" list="$2" cat="$3" msg="$4"
    shift 4
    assert_output_empty "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path resolution is clean.
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        command printf '%s\n' "$p" >>"$out"
    done
    command printf '%s' "$out"
}
