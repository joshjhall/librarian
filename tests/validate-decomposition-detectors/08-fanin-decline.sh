# shellcheck shell=bash
# Fan-in, adjacency and the reasoned decline — detector tests (#760 split).
#
# Three cross-language rules about whether a seam is REAL and how it is
# evidenced: the over-cap bare `fan-in N` shape, the adjacency requirement (an
# interleaved family is not a movable seam), and the four decline reasons, whose
# BRANCH ORDER is pinned — a reason chosen by the wrong arm is still a wrong
# finding.
#
# Both the adjacency and fan-in cases carry a positive control, and for the same
# reason: a negative assertion that passes because the segmenter stopped matching
# entirely proves nothing. The adjacency case asserts the same family, contiguous,
# MUST still be a seam; the fan-in case raises the cap so the same fixture DOES
# name its callers. The adjacency rule is here BECAUSE the first mutation round
# found it was the one rule with no failing test
# ([[mutation-round-finds-the-untested-rule]]).
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# fan-in: the OVER-CAP shape — a bare "fan-in N" with no caller list
# ============================================================================
test_fanin_over_cap() {
    local d f list

    # Three fan-in evidence shapes exist: "no external references" (count 0),
    # "fan-in N <- callers" (count <= max_fanin AND a caller resolved), and a
    # bare "fan-in N". The other cases here cover the first two; this covers the
    # third, which is otherwise reachable only through the Codecov corpus (which
    # asserts nothing). Both of its arms are exercised:
    #   (a) count > DECOMP_SEAM_MAX_FANIN — the cap arm, below;
    #   (b) count > 0 with NO caller resolvable to a top-level unit — the
    #       module-level-reference arm, in the second fixture.
    d="$(fresh_dir)"
    f="$d/overcap.py"
    command cat >"$f" <<'EOF'
def parse_a(x):
    return x

def parse_b(x):
    return x

def parse_c(x):
    return x

def caller_one(x):
    return parse_a(x)

def caller_two(x):
    return parse_b(x)

def caller_three(x):
    return parse_c(x)

def caller_four(x):
    return parse_a(x)

def caller_five(x):
    return parse_b(x)
EOF
    list="$(list_of "$f")"
    # Over the fan-in cap: the caller list is dropped, leaving a bare count.
    assert_fires "$list" decomposition-seam "fan-in 5)" \
        "fan-in: over the cap, evidence is a bare count with no caller list" \
        DECOMP_SEAM_MAX_FANIN=2
    # ...and with the cap raised past the count, the SAME file names its
    # callers. Without this control the assertion above could pass merely
    # because caller resolution broke entirely.
    assert_fires "$list" decomposition-seam "fan-in 5 <- caller_five" \
        "fan-in: under a raised cap, the same file names its callers" \
        DECOMP_SEAM_MAX_FANIN=9

    # Arm (b): references exist but sit at module level, outside any top-level
    # unit, so no caller name resolves and the "<- " form is skipped even though
    # the count is under the cap.
    # NB: the references must sit ABOVE the cluster. A cluster's span runs to
    # the next unit header or EOF, so trailing module-level lines would fall
    # INSIDE the span and not count as external at all.
    f="$d/modlevel.py"
    command cat >"$f" <<'EOF'
import sys

TABLE = {
    "a": "parse_a",
    "b": "parse_b",
}

def zzz_anchor(x):
    return x

def parse_a(x):
    return x

def parse_b(x):
    return x

def parse_c(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "fan-in 2)" \
        "fan-in: module-level references yield a bare count (no caller unit)"
}

# ============================================================================
# Adjacency — a family INTERLEAVED with other units is not a movable seam
# ============================================================================
test_adjacency_required() {
    local d f list
    d="$(fresh_dir)"

    # render_* units separated by test units. Clustering by same-prefix ORDER
    # (skipping test units without breaking the run) would merge these three
    # into one 20+ line "seam" that cannot actually be lifted out — the tests
    # sit inside the span. Adjacency is by unit INDEX, so this is NOT a seam.
    f="$d/interleaved.sh"
    command cat >"$f" <<'EOF'
render_one() {
    printf 'a
'
    printf 'b
'
}

test_one() {
    render_one
    render_one
}

render_two() {
    printf 'c
'
    printf 'd
'
}

test_two() {
    render_two
    render_two
}

render_three() {
    printf 'e
'
    printf 'f
'
}
EOF
    list="$(list_of "$f")"
    assert_output_empty \
        "$(emit_rows sh "$list" decomposition-seam | command awk -F '\t' '$4 ~ /^seam /' || true)" \
        "adjacency: an interleaved family is not proposed as a seam (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty \
            "$(emit_rows py "$list" decomposition-seam | command awk -F '\t' '$4 ~ /^seam /' || true)" \
            "adjacency: an interleaved family is not proposed as a seam (python)"
    fi

    # Positive control: the SAME three render_* units, now contiguous, ARE a
    # seam. Without this the assertion above could pass for the wrong reason
    # (e.g. the shell segmenter silently not matching at all).
    f="$d/contiguous.sh"
    command cat >"$f" <<'EOF'
main_entry() {
    render_one
}

render_one() {
    printf 'a
'
    printf 'b
'
}

render_two() {
    printf 'c
'
    printf 'd
'
}

render_three() {
    printf 'e
'
    printf 'f
'
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "function render_* family (3 units," \
        "adjacency: the same family, contiguous, IS a seam (positive control)"
}

# ============================================================================
# The reasoned decline — a long file with no seam is a RESULT, not a silence
# ============================================================================
test_decline_reasons() {
    local d f list
    d="$(fresh_dir)"

    # Generated artifact: long and correct, regenerate rather than split.
    f="$d/table.py"
    command cat >"$f" <<'EOF'
# @generated by codegen; DO NOT EDIT
LOOKUP = {
    "a": 1,
    "b": 2,
    "c": 3,
    "d": 4,
    "e": 5,
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: generated file" \
        "decline: a generated file is declined, with the reason recorded"

    # Single cohesive unit: one class, nothing to cut.
    f="$d/single.py"
    command cat >"$f" <<'EOF'
class OneBigThing:
    def a(self):
        return 1
    def b(self):
        return 2
    def c(self):
        return 3
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: single cohesive unit" \
        "decline: a single-unit file is declined, with the reason recorded"

    # Mutually referential units: no low-coupling cut exists.
    f="$d/web.go"
    command cat >"$f" <<'EOF'
package main

func Alpha(s string) string {
	return Beta(s)
}

func Beta(s string) string {
	return Gamma(s)
}

func Gamma(s string) string {
	return s
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: no low-coupling seam found" \
        "decline: mutually referential units are declined, with the reason recorded"

    # Majority prose/comment: the length is documentation, not logic. Needs
    # MORE than cohesive_max_units units so it does not fall into the
    # single-cohesive-unit branch first — that branch order is what this
    # fixture pins, alongside the comment_pct >= 50 predicate itself.
    f="$d/documented.py"
    command cat >"$f" <<'EOF'
# This module is mostly explanation.
# Every function below carries a long comment block describing why it
# exists, what it assumes, and how it fails. That is deliberate: the file
# is a reference, and the prose is the point.
def alpha(x):
    return x

# Beta exists for the same reason as alpha, and its comment is just as
# long, because the explanation is the deliverable here rather than the
# three lines of code it accompanies.
def beta(x):
    return x

# Gamma closes the set. The comment-to-code ratio across this file is
# well over half, which is what the decline predicate keys on.
def gamma(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: majority prose/comment" \
        "decline: a comment-majority file is declined, with the reason recorded"

    # THE POINT OF THE CATEGORY: a declined file is never silent. An empty
    # findings list is not evidence that nothing needed doing, so every
    # over-threshold file yields either a seam or a recorded decline.
    assert_fires "$list" file-length "production LOC" \
        "decline: the declined file still reports its size"
}
