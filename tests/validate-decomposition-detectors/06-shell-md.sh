# shellcheck shell=bash
# Shell and Markdown segmenters — check-decomposition detector tests (#760 split).
#
# The two non-brace languages: shell's function-family seam with comment
# exclusion and its `# --- tests ---` whole-file region marker, and markdown's
# heading-cluster seam (hierarchy, not functions) with its fenced-block counter.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Shell segmenter
# ============================================================================
test_seam_shell() {
    local d f list
    d="$(fresh_dir)"
    f="$d/tool.sh"
    command cat >"$f" <<'EOF'
#!/usr/bin/env bash
main_entry() {
    render_header "$1"
}

render_header() {
    printf 'h\n'
}

render_body() {
    printf 'b\n'
}

render_footer() {
    printf 'f\n'
}
EOF
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "seam 6-16: function render_* family (3 units," \
        "shell: render_* seam span and family"
    assert_fires "$list" decomposition-seam "fan-in 1 <- main_entry" \
        "shell: seam fan-in names its caller"
    # The shebang comment is counted as a comment, not production code.
    assert_fires "$list" file-length "1 comment" \
        "shell: comment lines excluded from production LOC"

    # Whole-file test-REGION marker: `# --- tests ---` excludes to EOF. Same
    # distinct mechanism as the python `if __name__` case above.
    f="$d/withtests.sh"
    command cat >"$f" <<'EOF'
#!/usr/bin/env bash
alpha() {
    printf 'a
'
}

beta() {
    printf 'b
'
}

# --- tests ---
test_alpha() {
    alpha
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "4 test-excluded" \
        "shell: '# --- tests ---' region excluded to EOF from production LOC"
}

# ============================================================================
# Markdown segmenter — heading hierarchy, not functions
# ============================================================================
test_seam_markdown() {
    local d f list
    d="$(fresh_dir)"
    f="$d/guide.md"
    command cat >"$f" <<'EOF'
## Overview

Text.

## Install on Linux

Steps.

## Install on Mac

Steps.

## Install on Windows

Steps.
EOF
    list="$(list_of "$f")"

    # Sections are segmented at the SHALLOWEST heading depth present (## here,
    # with no lone # title), and the family comes from the slugged heading text.
    assert_fires "$list" decomposition-seam "seam 5-15: section install_* family (3 units," \
        "markdown: heading-cluster seam span and family"
    assert_fires "$list" decomposition-seam "no external references" \
        "markdown: prose sections report no fan-in"
    assert_fires "$list" decomposition-seam "> $d/guide/install.md" \
        "markdown: seam proposes a concrete target document"

    # Counter: a fenced code block containing #-comments is not a heading.
    f="$d/fenced.md"
    command cat >"$f" <<'EOF'
## Only Section

```bash
# install_one
# install_two
# install_three
```
EOF
    list="$(list_of "$f")"
    # A decline row is legitimate here (one section, nothing to cut); what must
    # NOT appear is a SEAM built from the fenced #-comments as if they were
    # headings. Assert on the seam text, not on category silence.
    # NB: match the evidence-column PREFIX. A plain 'seam ' substring also
    # appears inside the decline text "no internal seam to cut", which would
    # make this counter pass for the wrong reason.
    assert_output_empty \
        "$(emit_rows sh "$list" decomposition-seam | command awk -F '\t' '$4 ~ /^seam /' || true)" \
        "markdown: #-comments inside a fence are not headings (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty \
            "$(emit_rows py "$list" decomposition-seam | command awk -F '\t' '$4 ~ /^seam /' || true)" \
            "markdown: #-comments inside a fence are not headings (python)"
    fi
}
