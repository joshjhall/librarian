# shellcheck shell=bash
# Python segmenter — check-decomposition detector tests (issue #760 split).
#
# The def-family seam and its span/fan-in/target evidence, plus the whole-file
# `if __name__` test-region exclusion from production LOC.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Python segmenter
# ============================================================================
test_seam_python() {
    local d f list
    d="$(fresh_dir)"
    f="$d/mod.py"
    command cat >"$f" <<'EOF'
def main_entry(x):
    return parse_entry(x)

def parse_entry(s):
    return parse_header(s)

def parse_header(s):
    out = []
    for line in s.splitlines():
        out.append(line)
    return out

def parse_body(s):
    return [ln.strip() for ln in s.splitlines()]

def test_parse_entry():
    assert parse_entry("x")
EOF
    list="$(list_of "$f")"

    # The seam: three consecutive parse_* defs starting at line 4, named family,
    # fan-in through main_entry. The SPAN and FAMILY are the assertion — a
    # scanner that merely noticed the file was long would not produce this.
    assert_fires "$list" decomposition-seam "seam 4-15: def parse_* family (3 units," \
        "python: parse_* seam span and family"
    assert_fires "$list" decomposition-seam "fan-in 2 <- main_entry, test_parse_entry" \
        "python: seam fan-in names its callers"
    assert_fires "$list" decomposition-seam "> $d/mod/parse.py" \
        "python: seam proposes a concrete target module"

    # test_parse_entry is excluded from production LOC (2 test lines).
    assert_fires "$list" file-length "2 test-excluded" \
        "python: test unit excluded from production LOC"

    # Whole-file test-REGION marker: `if __name__` excludes to EOF. This is a
    # different mechanism from the per-unit test exclusion above (TEST_REGION_RE
    # vs TEST_UNIT_RE) and needs its own fixture — the coverage corpus carries
    # the marker but asserts nothing, so without this a broken region regex
    # would show green coverage and a green suite at the same time.
    f="$d/withmain.py"
    command cat >"$f" <<'EOF'
def alpha(x):
    return x

def beta(x):
    return x

def gamma(x):
    return x

def delta(x):
    return x

if __name__ == "__main__":
    alpha(1)
    beta(2)
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "3 test-excluded" \
        "python: if __name__ region excluded to EOF from production LOC"

    # Counter: one small cohesive file has no seam and is not over threshold.
    f="$d/small.py"
    command printf '%s\n' "def only(x):" "    return x" >"$f"
    list="$(list_of "$f")"
    assert_silent "$list" decomposition-seam "python: a short single-unit file emits no seam"
    assert_silent "$list" file-length "python: a short file is not over threshold"
}
