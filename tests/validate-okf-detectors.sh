#!/usr/bin/env bash
# check-okf-conformance detector behavioral gate (issue #668).
#
# check-okf-conformance validates a memory bundle against the OKF v0.2 SCHEMA
# FLOOR (§11): parseable frontmatter, a non-empty `type`, and reserved files
# (`index.md`, `log.md`) following §8/§9. Like every scanner in this family, its
# bash<->python parity is covered by tests/validate-python-ports.sh and
# tests/validate-prescan-differential.sh — neither of which can catch a
# regression where BOTH impls break the same way (#684). This gate is the
# behavioral half: purpose-built fixtures driven through the scanner, asserting
# the SPECIFIC category each must emit and — just as importantly — that the
# permissive cases stay SILENT.
#
# THE CENTRAL PROPERTY THIS GATE EXISTS TO PIN is the split between two kinds of
# failure, which the motivating epic (#664) says is how this lands wrong when
# conflated:
#
#   * THE BUNDLE is never rejected. Unknown `type` values, unrecognized extra
#     keys, a missing okf_version, an absent index.md, and version DRIFT are all
#     findings-or-silence at EXIT 0 (§11, §12). test_permissive_conformance and
#     test_version_drift own this.
#   * THE TOOL fails loud. An unresolvable/malformed version pin, a usage error,
#     and a missing file list exit NON-ZERO with an actionable message
#     (#538/#571). test_fail_loud_runtime owns this, with separate fixtures from
#     the permissive side so neither can drift into the other.
#
# The HEALTHY-BUNDLE fixture (test_healthy_bundle_is_silent) is the guard against
# the classic failure of a validator like this: a detector that fires on
# everything still passes every positive fixture. A conformant bundle exercising
# every file kind must produce EXACTLY ZERO rows.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# The port reads only file CONTENT plus the bundle-root env vars, so its CWD is
# irrelevant and every fixture runs from $WORKDIR with absolute paths.
#
# SKIPS (does not fail) the python assertions when a python3>=3.11 is unavailable
# — the same posture as validate-lifecycle-detectors.sh; the bash path is still
# asserted.
#
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-okf-conformance detector fixtures (#668)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

SK="$SKILLS_DIR/check-okf-conformance"

# The bundle root every fixture uses. Set explicitly rather than relying on the
# default so a fixture's absolute /tmp path is still "inside the bundle": the
# root matcher accepts a root nested anywhere in the path (`*/ROOT/*`), which is
# what makes an out-of-tree fixture testable at all.
FIXTURE_ROOT=".claude/memory"

# --- Scanner drivers ---------------------------------------------------------
# run_impl IMPL LIST — every row one impl emits. IMPL is "py" or "sh".
# Env overrides are passed through from the caller's environment.
run_impl() {
    local impl="$1" list="$2"
    if [ "$impl" = py ]; then
        python3 "$SK/patterns.py" "$list" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null
    fi
}

# emit_rows IMPL LIST CAT — the rows one impl emits for a single category.
emit_rows() {
    local impl="$1" list="$2" cat="$3"
    OKF_BUNDLE_ROOT="${OKF_BUNDLE_ROOT-$FIXTURE_ROOT}" run_impl "$impl" "$list" |
        command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires LIST CAT NEEDLE MSG — the category fires (rows contain NEEDLE) in
# BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local list="$1" cat="$2" needle="$3" msg="$4"
    assert_contains "$(emit_rows sh "$list" "$cat")" "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$list" "$cat")" "$needle" "$msg (python)"
    fi
}

# assert_silent LIST CAT MSG — the category emits NOTHING in both impls.
assert_silent() {
    local list="$1" cat="$2" msg="$3"
    assert_output_empty "$(emit_rows sh "$list" "$cat")" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$list" "$cat")" "$msg (python)"
    fi
}

# assert_no_rows LIST MSG — the scanner emits NOTHING AT ALL in both impls.
# Stronger than assert_silent (which is per-category) and the shape the
# healthy-bundle fixture needs.
assert_no_rows() {
    local list="$1" msg="$2"
    assert_output_empty \
        "$(OKF_BUNDLE_ROOT="${OKF_BUNDLE_ROOT-$FIXTURE_ROOT}" run_impl sh "$list")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty \
            "$(OKF_BUNDLE_ROOT="${OKF_BUNDLE_ROOT-$FIXTURE_ROOT}" run_impl py "$list")" \
            "$msg (python)"
    fi
}

# fresh_bundle — a unique scratch bundle root per fixture; echoes the bundle dir
# (i.e. <scratch>/.claude/memory), so a caller writes concepts straight into it.
fresh_bundle() {
    local d
    d="$(command mktemp -d "$WORKDIR/case.XXXXXX")"
    command mkdir -p "$d/$FIXTURE_ROOT"
    command printf '%s' "$d/$FIXTURE_ROOT"
}

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

# list_bundle BUNDLE — a file list of every *.md in BUNDLE, sorted.
list_bundle() {
    local b="$1" out="$1/../../../list.txt"
    command find "$b" -name '*.md' 2>/dev/null | command sort >"$out"
    command printf '%s' "$out"
}

# ============================================================================
# HEALTHY BUNDLE — zero findings.
#
# The guard against a detector that fires on everything: a validator whose rules
# are all slightly too eager still passes every positive fixture below, and only
# this case catches it. Deliberately exercises EVERY file kind the scanner routes
# — root index.md with a matching okf_version, root log.md, a bundle-root
# concept, a NESTED concept, and a nested index.md with no frontmatter — so a
# rule that over-fires on any one of them shows up here.
# ============================================================================
test_healthy_bundle_is_silent() {
    local b list
    b="$(fresh_bundle)"
    command mkdir -p "$b/sub"

    # Root index.md: frontmatter permitted, carrying ONLY okf_version (§8/§12),
    # and matching the pin so there is no drift.
    #
    # The index NAMES THE REAL ROOT CONCEPTS (#669). It used to point at a lone
    # `a.md` that the fixture never created — invisible while the scanner was
    # per-file, but a genuine `memory-dangling-index` once slice B reads the
    # bundle as a graph, and it left both root concepts orphaned besides. A
    # bundle this fixture calls "fully conformant" must now also be structurally
    # healthy, or it cannot serve as the zero-rows baseline for either pass.
    command printf -- '---\nokf_version: "0.2"\n---\n\n# Index\n\n* [Minimal](minimal.md) - a thing\n* [Rich](rich.md) - another thing\n' >"$b/index.md"
    # Root log.md with a conformant ISO date heading (§9).
    command printf -- '# Log\n\n## 2026-08-19\n* **Update**: a thing\n' >"$b/log.md"
    # A minimal concept: `type` alone is FULLY conformant (§4.1) — the floor and
    # nothing more.
    command printf -- '---\ntype: user\n---\n\nBody.\n' >"$b/minimal.md"
    # A rich concept: recommended keys, a nested mapping, and a list value.
    command printf -- '---\ntype: Reference\ntitle: A thing\ndescription: one line\ntags: [a, b]\nmetadata:\n  status: stable\n---\n\nBody.\n' >"$b/rich.md"
    # A NESTED concept, and a nested index.md with NO frontmatter (the normal
    # conformant shape for a non-root index).
    command printf -- '---\ntype: project\n---\n\nNested body.\n' >"$b/sub/nested.md"
    command printf -- '# Sub index\n\n* [Nested](nested.md) - a nested thing\n' >"$b/sub/index.md"

    list="$(list_bundle "$b")"
    assert_no_rows "$list" "okf: a fully conformant bundle produces ZERO findings"
}

# ============================================================================
# okf-missing-type — `type` is the sole always-required key (§4.1)
# ============================================================================
test_missing_type() {
    local b list

    # No `type` key at all, despite other keys being present.
    b="$(fresh_bundle)"
    command printf -- '---\ndescription: has everything but type\ntitle: A\n---\n\nBody.\n' >"$b/no-type.md"
    list="$(make_list "$b/../../../l" "$b/no-type.md")"
    assert_fires "$list" okf-missing-type "Concept frontmatter has no type key" \
        "okf: a concept with no type key fires"

    # Present but EMPTY — asserted separately from absent, because they are
    # different branches with different evidence labels and a regression can
    # break one while the other still fires.
    b="$(fresh_bundle)"
    command printf -- '---\ntype:\n---\n\nBody.\n' >"$b/empty-type.md"
    list="$(make_list "$b/../../../l" "$b/empty-type.md")"
    assert_fires "$list" okf-missing-type "Concept type is present but empty" \
        "okf: a concept with an empty type fires"

    # Whitespace-only is also empty.
    b="$(fresh_bundle)"
    command printf -- '---\ntype:   \n---\n\nBody.\n' >"$b/ws-type.md"
    list="$(make_list "$b/../../../l" "$b/ws-type.md")"
    assert_fires "$list" okf-missing-type "Concept type is present but empty" \
        "okf: a whitespace-only type fires"
}

# ============================================================================
# okf-unparseable-frontmatter — §11 item 1
# ============================================================================
test_unparseable_frontmatter() {
    local b list

    # No frontmatter block at all.
    b="$(fresh_bundle)"
    command printf -- 'Just a body, no frontmatter.\n' >"$b/bare.md"
    list="$(make_list "$b/../../../l" "$b/bare.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Concept has no frontmatter block" \
        "okf: a concept with no frontmatter block fires"

    # An opening delimiter that is never closed.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\n' >"$b/unterminated.md"
    list="$(make_list "$b/../../../l" "$b/unterminated.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Frontmatter block is not terminated" \
        "okf: an unterminated frontmatter block fires"

    # A line inside the block that is neither a key, a list item, a comment, nor
    # indented continuation.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\nTHIS LINE HAS NO COLON\n---\n\nBody.\n' >"$b/badline.md"
    list="$(make_list "$b/../../../l" "$b/badline.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Frontmatter line is not parseable" \
        "okf: an unparseable frontmatter line fires"

    # An empty file has no block either.
    b="$(fresh_bundle)"
    : >"$b/empty.md"
    list="$(make_list "$b/../../../l" "$b/empty.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Concept has no frontmatter block" \
        "okf: an empty concept file fires"

    # scan_index has its OWN parse_frontmatter call and its OWN unparseable
    # emit, reached only when an index.md OPENS a block (first line `---`) that
    # then fails to parse. Every fixture above routes through scan_concept, so
    # without these two the index-side error path is unexecuted in both impls —
    # including whether the bad-line LINE NUMBER is reported correctly there.
    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: "0.2"\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Frontmatter block is not terminated" \
        "okf: an index.md with an unterminated block fires via scan_index"

    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: "0.2"\nTHIS LINE HAS NO COLON\n---\n\n# Index\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_fires "$list" okf-unparseable-frontmatter "Frontmatter line is not parseable" \
        "okf: an index.md with a bad interior line fires via scan_index"
    # ...at the offending line (3), not at line 1 — the index path passes
    # FM_ERR_LINE through just as the concept path does.
    assert_contains "$(emit_rows sh "$list" okf-unparseable-frontmatter)" "	3	" \
        "okf: the index.md bad-line finding points at the offending line (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$list" okf-unparseable-frontmatter)" "	3	" \
            "okf: the index.md bad-line finding points at the offending line (python)"
    fi

    # An unparseable index.md reports ONLY the parse error — the structure and
    # drift rules downstream of the parse must not also fire on a block that
    # could not be read.
    assert_silent "$list" okf-reserved-file-structure \
        "okf: an unparseable index.md does not also emit a structure finding"
    assert_silent "$list" okf-version-drift \
        "okf: an unparseable index.md does not also emit a drift finding"

    # NEGATIVE: comments, list items, and nested mappings inside the block are
    # all parseable and must NOT fire. Without this, tightening the grammar to
    # "keys only" would pass every positive case above.
    b="$(fresh_bundle)"
    command printf -- '---\n# a comment\ntype: user\ntags:\n  - one\n  - two\nnested:\n  key: value\n---\n\nBody.\n' >"$b/rich.md"
    list="$(make_list "$b/../../../l" "$b/rich.md")"
    assert_silent "$list" okf-unparseable-frontmatter \
        "okf: comments, list items and nested mappings are parseable (silent)"
}

# ============================================================================
# okf-reserved-file-structure — §8 (index.md) and §9 (log.md)
# ============================================================================
test_reserved_file_structure() {
    local b list

    # §8: a NON-ROOT index.md may carry no frontmatter at all.
    b="$(fresh_bundle)"
    command mkdir -p "$b/sub"
    command printf -- '---\ntitle: Not allowed here\n---\n\n# Sub index\n' >"$b/sub/index.md"
    list="$(make_list "$b/../../../l" "$b/sub/index.md")"
    assert_fires "$list" okf-reserved-file-structure "index.md carries frontmatter" \
        "okf: a nested index.md with frontmatter fires"

    # §8: a ROOT index.md may carry okf_version — but NOTHING ELSE.
    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: "0.2"\ntitle: Also not allowed\n---\n\n# Index\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_fires "$list" okf-reserved-file-structure "index.md carries frontmatter" \
        "okf: a root index.md with keys beyond okf_version fires"

    # ROOT-vs-NESTED, isolated. The two cases above both carry a key OTHER than
    # okf_version, so they fire through the "extra keys" arm and would still fire
    # if the root/nested distinction were erased entirely. This fixture is the
    # one that isolates it: a NESTED index.md carrying ONLY okf_version. §8
    # permits that key at the bundle ROOT alone, so it must fire here — and a
    # mutation making every index look like the root leaves it silent.
    b="$(fresh_bundle)"
    command mkdir -p "$b/sub"
    command printf -- '---\nokf_version: "0.2"\n---\n\n# Sub index\n' >"$b/sub/index.md"
    list="$(make_list "$b/../../../l" "$b/sub/index.md")"
    assert_fires "$list" okf-reserved-file-structure "index.md carries frontmatter" \
        "okf: a NESTED index.md carrying only okf_version still fires (§8 is root-only)"

    # ...and that nested declaration is NOT a drift signal even when it differs
    # from the pin: §12 scopes okf_version to the bundle-root index.md, so a
    # nested one is a structure problem, not a version statement.
    b="$(fresh_bundle)"
    command mkdir -p "$b/sub"
    command printf -- '---\nokf_version: "9.9"\n---\n\n# Sub index\n' >"$b/sub/index.md"
    list="$(make_list "$b/../../../l" "$b/sub/index.md")"
    assert_silent "$list" okf-version-drift \
        "okf: a nested index.md okf_version is not read as a bundle version declaration"

    # §9: a non-ISO date heading in a log.md.
    b="$(fresh_bundle)"
    command printf -- '# Log\n\n## March 2026\n* **Update**: a thing\n' >"$b/log.md"
    list="$(make_list "$b/../../../l" "$b/log.md")"
    assert_fires "$list" okf-reserved-file-structure "log.md date heading is not ISO 8601" \
        "okf: a non-ISO log.md date heading fires"

    # NEGATIVE: a conformant ISO heading stays silent.
    b="$(fresh_bundle)"
    command printf -- '# Log\n\n## 2026-08-19\n* **Update**: a thing\n' >"$b/log.md"
    list="$(make_list "$b/../../../l" "$b/log.md")"
    assert_silent "$list" okf-reserved-file-structure \
        "okf: an ISO 8601 log.md date heading is silent"

    # NEGATIVE: a date-shaped heading inside a FENCED block is example text, not
    # a heading, and must not fire.
    b="$(fresh_bundle)"
    command printf -- '# Log\n\n```\n## Not-A-Date\n```\n\n## 2026-08-19\n* thing\n' >"$b/log.md"
    list="$(make_list "$b/../../../l" "$b/log.md")"
    assert_silent "$list" okf-reserved-file-structure \
        "okf: a heading inside a fenced block is not a log date heading"

    # The reserved files are EXEMPT from concept-level rules. Neither carries a
    # `type`, and neither may be reported for lacking one — this is the §3.1
    # routing, and a regression that treated reserved files as concepts would
    # light up every bundle in existence.
    b="$(fresh_bundle)"
    command printf -- '# Index\n\n* [A](a.md) - thing\n' >"$b/index.md"
    command printf -- '# Log\n\n## 2026-08-19\n* thing\n' >"$b/log.md"
    list="$(make_list "$b/../../../l" "$b/index.md" "$b/log.md")"
    assert_silent "$list" okf-missing-type \
        "okf: index.md and log.md are exempt from the required-type rule"
    assert_silent "$list" okf-unparseable-frontmatter \
        "okf: index.md and log.md are exempt from the frontmatter rule"
}

# ============================================================================
# okf-version-drift — LOW, and EXIT 0 (§12)
# ============================================================================
test_version_drift() {
    local b list rc out

    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: "9.9"\n---\n\n# Index\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_fires "$list" okf-version-drift "Bundle declares okf_version 9.9" \
        "okf: a declared version differing from the pin fires"

    # The row is LOW — drift is worth surfacing, never worth failing over.
    assert_contains "$(emit_rows sh "$list" okf-version-drift)" "LOW" \
        "okf: version drift is emitted at LOW certainty (bash)"

    # ...AND THE SCAN EXITS 0. This is the acceptance criterion in the issue and
    # the §12 "best-effort consumption rather than refusing" rule. Asserted on
    # the exit STATUS, not just the row, because a rule that emitted the finding
    # and then exited non-zero would satisfy every assertion above.
    rc=0
    out="$(OKF_BUNDLE_ROOT="$FIXTURE_ROOT" /usr/bin/env PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" || rc=$?
    assert_exit 0 "$rc" "okf: version drift exits 0, it does not reject the bundle (bash)"
    assert_contains "$out" "okf-version-drift" "okf: the drift row is present on that exit-0 run (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc=0
        out="$(OKF_BUNDLE_ROOT="$FIXTURE_ROOT" python3 "$SK/patterns.py" "$list" 2>/dev/null)" || rc=$?
        assert_exit 0 "$rc" "okf: version drift exits 0, it does not reject the bundle (python)"
        assert_contains "$out" "okf-version-drift" "okf: the drift row is present on that exit-0 run (python)"
    fi

    # A MATCHING version is silent.
    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: "0.2"\n---\n\n# Index\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_silent "$list" okf-version-drift \
        "okf: a declared version matching the pin is silent"

    # An UNQUOTED declaration is the same value — the unquote step must not make
    # `0.2` and `"0.2"` disagree.
    b="$(fresh_bundle)"
    command printf -- '---\nokf_version: 0.2\n---\n\n# Index\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_silent "$list" okf-version-drift \
        "okf: an unquoted matching okf_version is silent"

    # The PIN IS READ FROM ONE PLACE. Overriding it flips the verdict on the SAME
    # fixture: what was conformant becomes drift. This is what proves no impl
    # carries a hardcoded version of its own — a literal "0.2" buried in the
    # detector would keep this fixture silent.
    assert_contains \
        "$(OKF_PINNED_VERSION="1.0" emit_rows sh "$list" okf-version-drift)" \
        "pinned 1.0" \
        "okf: the pin is read from ONE source — overriding it flips the same fixture to drift (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains \
            "$(OKF_PINNED_VERSION="1.0" emit_rows py "$list" okf-version-drift)" \
            "pinned 1.0" \
            "okf: the pin is read from ONE source — overriding it flips the same fixture to drift (python)"
    fi
}

# ============================================================================
# PERMISSIVE CONFORMANCE (§11) — the MUST-NOTs.
#
# Each of these is a thing the spec explicitly forbids rejecting a bundle for.
# They are the reason this scanner is a reporter and not a gate, and each gets
# its own fixture so a regression cannot take out one while the others hold.
# ============================================================================
test_permissive_conformance() {
    local b list

    # §4.1: an UNKNOWN type value is fully conformant. Consumers MUST tolerate
    # unknown types — there is no registry to check against.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: Some Entirely Invented Type\n---\n\nBody.\n' >"$b/unknown.md"
    list="$(make_list "$b/../../../l" "$b/unknown.md")"
    assert_no_rows "$list" "okf: an unknown type value is conformant (no rows at all)"

    # §4.1 Extensions: unrecognized extra keys MUST NOT cause rejection — and a
    # `stale_check`-style LOCAL EXTENSION specifically, which is this repo's own
    # (#631) and exactly the kind of producer-defined key a portable validator
    # must not flag.
    b="$(fresh_bundle)"
    # `type: reference`, not `feedback`: this case is about EXTRA KEYS being
    # tolerated, and the type is incidental to that. `feedback` carries a
    # configured body requirement (#669), so using it here would drag an
    # unrelated health rule into a conformance assertion and make the fixture
    # test two things at once. The body-requirement rule gets its own fixture in
    # test_memory_missing_why, where a missing **Why:** is the point.
    command printf -- '---\ntype: reference\nstale_after: 2026-10-31\nstale_check: "what specifically rots"\nwholly_invented_key: 42\n---\n\nBody.\n' >"$b/ext.md"
    list="$(make_list "$b/../../../l" "$b/ext.md")"
    assert_no_rows "$list" "okf: unrecognized extra keys incl. a stale_check extension are conformant"

    # §11/§12: a bundle-root index.md with NO okf_version is fine — declaring one
    # is optional.
    b="$(fresh_bundle)"
    # The index names a concept that EXISTS. Pointing at an absent `a.md` was
    # invisible to the per-file passes but is a real `memory-dangling-index`
    # under slice B (#669) — and it has nothing to do with okf_version, which is
    # what this case is about.
    command printf -- '---\ntype: user\n---\n\nBody.\n' >"$b/thing.md"
    command printf -- '# Index\n\n* [A](thing.md) - thing\n' >"$b/index.md"
    list="$(make_list "$b/../../../l" "$b/index.md")"
    assert_no_rows "$list" "okf: a root index.md without okf_version is conformant"

    # §11: a MISSING index.md is not a finding. A bundle of concepts alone, with
    # no index at all, is conformant.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\n---\n\nBody.\n' >"$b/lonely.md"
    list="$(make_list "$b/../../../l" "$b/lonely.md")"
    assert_no_rows "$list" "okf: a bundle with no index.md at all is conformant"

    # §11: BROKEN CROSS-LINKS must not be rejected. A link to a file that does
    # not exist is explicitly on the MUST-NOT list; the graph slice (#669) is
    # where link health lives, not here.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\n---\n\nSee [gone](does-not-exist.md) and [[missing-wikilink]].\n' >"$b/links.md"
    list="$(make_list "$b/../../../l" "$b/links.md")"
    assert_no_rows "$list" "okf: broken cross-links are not a conformance finding"
}

# ============================================================================
# BUNDLE DISCOVERY — root override, normalization, and no-bundle exit 0
# ============================================================================
test_bundle_discovery() {
    local b list d rc out alt

    # A repo with NO bundle exits 0 and reports nothing. The file list is a real
    # markdown file that simply is not under any bundle root.
    d="$(command mktemp -d "$WORKDIR/case.XXXXXX")"
    command printf -- 'Not a bundle file.\n' >"$d/README.md"
    list="$(make_list "$d/l" "$d/README.md")"
    rc=0
    out="$(OKF_BUNDLE_ROOT="$FIXTURE_ROOT" /usr/bin/env PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" || rc=$?
    assert_exit 0 "$rc" "okf: a repo with no bundle exits 0 (bash)"
    assert_output_empty "$out" "okf: a repo with no bundle reports nothing (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc=0
        out="$(OKF_BUNDLE_ROOT="$FIXTURE_ROOT" python3 "$SK/patterns.py" "$list" 2>/dev/null)" || rc=$?
        assert_exit 0 "$rc" "okf: a repo with no bundle exits 0 (python)"
        assert_output_empty "$out" "okf: a repo with no bundle reports nothing (python)"
    fi

    # An EMPTY root means no bundle is configured: silent, and still exit 0.
    b="$(fresh_bundle)"
    command printf -- '---\ndescription: no type\n---\n\nBody.\n' >"$b/no-type.md"
    list="$(make_list "$b/../../../l" "$b/no-type.md")"
    rc=0
    out="$(OKF_BUNDLE_ROOT="" /usr/bin/env PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" || rc=$?
    assert_exit 0 "$rc" "okf: an empty bundle root exits 0 (bash)"
    assert_output_empty "$out" "okf: an empty bundle root disables classification (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc=0
        out="$(OKF_BUNDLE_ROOT="" python3 "$SK/patterns.py" "$list" 2>/dev/null)" || rc=$?
        assert_exit 0 "$rc" "okf: an empty bundle root exits 0 (python)"
        assert_output_empty "$out" "okf: an empty bundle root disables classification (python)"
    fi

    # ROOT NORMALIZATION: every spelling of one root must decide ALIKE. An
    # unnormalized root would simply miss, emit nothing, and still exit 0 — a
    # silent fail-open indistinguishable from a clean bundle (#662).
    for alt in "$FIXTURE_ROOT" "./$FIXTURE_ROOT" "$FIXTURE_ROOT/"; do
        assert_contains \
            "$(OKF_BUNDLE_ROOT="$alt" run_impl sh "$list")" "okf-missing-type" \
            "okf: root spelling '$alt' still matches the bundle (bash)"
        if [ "$HAVE_PY" -eq 1 ]; then
            assert_contains \
                "$(OKF_BUNDLE_ROOT="$alt" run_impl py "$list")" "okf-missing-type" \
                "okf: root spelling '$alt' still matches the bundle (python)"
        fi
    done

    # MEMORY_BUNDLE_ROOT is the fallback when OKF_BUNDLE_ROOT is unset — the
    # shared convention with check-decomposition (#700), so one setting moves
    # both scanners.
    assert_contains \
        "$(/usr/bin/env -u OKF_BUNDLE_ROOT MEMORY_BUNDLE_ROOT="$FIXTURE_ROOT" \
            PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" \
        "okf-missing-type" \
        "okf: MEMORY_BUNDLE_ROOT is honored when OKF_BUNDLE_ROOT is unset (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains \
            "$(/usr/bin/env -u OKF_BUNDLE_ROOT MEMORY_BUNDLE_ROOT="$FIXTURE_ROOT" \
                python3 "$SK/patterns.py" "$list" 2>/dev/null)" \
            "okf-missing-type" \
            "okf: MEMORY_BUNDLE_ROOT is honored when OKF_BUNDLE_ROOT is unset (python)"
    fi

    # ...and OKF_BUNDLE_ROOT WINS when both are set. Without this, the two
    # variables could be silently interchangeable and the documented precedence
    # would be untested.
    assert_output_empty \
        "$(OKF_BUNDLE_ROOT="somewhere/else" MEMORY_BUNDLE_ROOT="$FIXTURE_ROOT" \
            /usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" \
        "okf: OKF_BUNDLE_ROOT takes precedence over MEMORY_BUNDLE_ROOT (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty \
            "$(OKF_BUNDLE_ROOT="somewhere/else" MEMORY_BUNDLE_ROOT="$FIXTURE_ROOT" \
                python3 "$SK/patterns.py" "$list" 2>/dev/null)" \
            "okf: OKF_BUNDLE_ROOT takes precedence over MEMORY_BUNDLE_ROOT (python)"
    fi

    # A NON-markdown file inside the bundle is not OKF content and is skipped.
    b="$(fresh_bundle)"
    command printf -- 'type = not markdown\n' >"$b/notes.txt"
    list="$(make_list "$b/../../../l" "$b/notes.txt")"
    assert_no_rows "$list" "okf: a non-markdown file inside the bundle is skipped"
}

# ============================================================================
# FAIL LOUD — the TOOL side, kept strictly apart from bundle permissiveness
#
# Separate fixtures from test_permissive_conformance on purpose: the epic warns
# that conflating "the bundle declares something unfamiliar" (never fatal) with
# "the tool cannot run" (always fatal) is how this lands wrong. These assert the
# non-zero half.
# ============================================================================
test_fail_loud_runtime() {
    local b list rc out err

    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\n---\n\nBody.\n' >"$b/ok.md"
    list="$(make_list "$b/../../../l" "$b/ok.md")"

    # A MALFORMED pin exits non-zero with an actionable message. Note the fixture
    # is a perfectly CONFORMANT bundle — so this cannot pass by accident on a
    # bundle-side finding; only the tool-side gate can produce it.
    rc=0
    err="$(OKF_PINNED_VERSION="not-a-version" /usr/bin/env PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$SK/patterns.sh" "$list" 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "okf: a malformed version pin exits non-zero (bash)"
    assert_contains "$err" "ERROR" "okf: a malformed pin prints an error (bash)"
    assert_contains "$err" "not-a-version" "okf: the error names the offending pin (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc=0
        err="$(OKF_PINNED_VERSION="not-a-version" python3 "$SK/patterns.py" "$list" 2>&1 >/dev/null)" || rc=$?
        assert_exit 1 "$rc" "okf: a malformed version pin exits non-zero (python)"
        assert_contains "$err" "ERROR" "okf: a malformed pin prints an error (python)"
        assert_contains "$err" "not-a-version" "okf: the error names the offending pin (python)"
    fi

    # An UNRESOLVABLE pin — no env override, and a thresholds.yml that carries no
    # `okf.pinned_version`. Driven by pointing the scanner at a COPY of the skill
    # whose thresholds.yml has had the pin removed, since the real one always has
    # it. This is the arm that would otherwise only ever run in a broken checkout.
    local fake="$WORKDIR/fake-skill"
    command mkdir -p "$fake"
    # bundle_graph.py travels with patterns.py (#669): it is a REQUIRED sibling
    # imported at module load, not an optional add-on, so a copy of the skill
    # without it is not a copy of the skill. Omitting it here made the pin
    # assertions fail on a ModuleNotFoundError — which would have passed the
    # "exits non-zero" half for entirely the wrong reason.
    command cp "$SK/patterns.py" "$SK/patterns.sh" "$SK/bundle_graph.py" "$fake/"
    command printf -- 'severity:\n  okf-missing-type:\n    absent_or_empty: medium\n' >"$fake/thresholds.yml"
    rc=0
    err="$(/usr/bin/env -u OKF_PINNED_VERSION PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$fake/patterns.sh" "$list" 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "okf: an absent version pin exits non-zero (bash)"
    assert_contains "$err" "no OKF version pin" "okf: the absent-pin error is actionable (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc=0
        err="$(/usr/bin/env -u OKF_PINNED_VERSION python3 "$fake/patterns.py" "$list" 2>&1 >/dev/null)" || rc=$?
        assert_exit 1 "$rc" "okf: an absent version pin exits non-zero (python)"
        assert_contains "$err" "no OKF version pin" "okf: the absent-pin error is actionable (python)"
    fi

    # ...and the SAME copied skill with the pin RESTORED scans normally. Without
    # this, the two assertions above could pass because the copy is broken in
    # some unrelated way rather than because the pin is missing.
    command printf -- 'okf:\n  pinned_version: "0.2"\n' >"$fake/thresholds.yml"
    rc=0
    out="$(OKF_BUNDLE_ROOT="$FIXTURE_ROOT" /usr/bin/env -u OKF_PINNED_VERSION \
        PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$fake/patterns.sh" "$list" 2>/dev/null)" || rc=$?
    assert_exit 0 "$rc" "okf: restoring the pin makes the same copied skill scan (bash)"
    assert_output_empty "$out" "okf: ...and the conformant fixture stays silent (bash)"

    # Usage error: no argument.
    rc=0
    err="$(/usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" </dev/null 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "okf: no argument exits 1 (bash)"
    assert_contains "$err" "Usage" "okf: no argument prints usage (bash)"

    # File list not found.
    rc=0
    err="$(/usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" \
        "$WORKDIR/nope.txt" 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "okf: a missing file list exits 1 (bash)"
    assert_contains "$err" "not found" "okf: a missing file list says so (bash)"
}

# ============================================================================
# Evidence truncation parity — >80-char multibyte evidence, bash == python
# ============================================================================
# Drives emit()'s EVIDENCE_CAP=80 CHARACTER truncation and the bash
# truncate_chars char-vs-byte slicing (#17) for THIS port: a log.md heading
# padded past 80 characters with a multibyte em-dash. The two impls must emit
# byte-identical truncated evidence (char-count, not byte-count).
test_evidence_truncation_parity() {
    local b list long
    b="$(fresh_bundle)"
    long="$(command printf '%0.s—' $(command seq 1 60))"
    command printf -- '# Log\n\n## %s\n' "$long" >"$b/log.md"
    list="$(make_list "$b/../../../l" "$b/log.md")"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_equals \
            "$(emit_rows sh "$list" okf-reserved-file-structure)" \
            "$(emit_rows py "$list" okf-reserved-file-structure)" \
            "okf: >80-char multibyte evidence truncates identically (bash==python)"
    else
        skip_test "okf: truncation parity needs python3>=3.11 (bash path still runs)"
        emit_rows sh "$list" okf-reserved-file-structure >/dev/null
    fi
}

# ============================================================================
# PIN RESOLUTION PARITY — the two impls must resolve the pin IDENTICALLY
#
# Both cases here were live parity breaks found in pre-PR review. Neither is
# reachable through the ordinary fixtures: every other test either sets a
# well-formed OKF_PINNED_VERSION or leaves it unset, and the real thresholds.yml
# always parses. They matter because the pin decides which SIDE of the
# fail-loud/permissive split a run lands on, so a divergence here means the same
# environment scans clean under one runtime and dies under the other.
#
# Asserted on EXIT STATUS as well as output: the whole failure mode is one impl
# exiting 0 while the other exits 1, which a rows-only assertion cannot see.
# ============================================================================
test_pin_resolution_parity() {
    local b list rc_sh rc_py out_sh out_py cfg

    b="$(fresh_bundle)"
    command printf -- '---\ntype: user\n---\n\nBody.\n' >"$b/ok.md"
    list="$(make_list "$b/../../../l" "$b/ok.md")"

    # A WHITESPACE-ONLY override must be treated as unset by BOTH impls, so both
    # fall through to thresholds.yml. Bash tested the RAW value with `-n` (a
    # space is non-empty) while python applied .strip() first — so bash exited 1
    # "malformed pin" where python scanned normally. A CI template expanding to
    # nothing produces exactly this value.
    rc_sh=0
    out_sh="$(OKF_PINNED_VERSION=" " OKF_BUNDLE_ROOT="$FIXTURE_ROOT" \
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null)" || rc_sh=$?
    assert_exit 0 "$rc_sh" "okf: a whitespace-only pin override falls through to thresholds.yml (bash)"
    assert_output_empty "$out_sh" "okf: ...and the conformant fixture stays silent (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc_py=0
        out_py="$(OKF_PINNED_VERSION=" " OKF_BUNDLE_ROOT="$FIXTURE_ROOT" \
            python3 "$SK/patterns.py" "$list" 2>/dev/null)" || rc_py=$?
        assert_exit 0 "$rc_py" "okf: a whitespace-only pin override falls through to thresholds.yml (python)"
        assert_output_empty "$out_py" "okf: ...and the conformant fixture stays silent (python)"
        assert_equals "$rc_sh" "$rc_py" "okf: both impls agree on a whitespace-only pin override"
        assert_equals "$out_sh" "$out_py" "okf: ...and both emit identical output under it"
    fi

    # A top-level LIST ITEM in thresholds.yml ends the `okf:` block in both
    # impls. Bash reset in_okf on its `-` case arm; python's guard skipped the
    # whole assignment for a `-` line and kept the PRIOR value — so python read
    # an indented pinned_version that bash had already stepped out of. The
    # config is documented as consumer-overridable, so its parse is a real
    # surface, and the two runtimes must not read one file differently.
    cfg="$WORKDIR/pin-parity"
    command mkdir -p "$cfg"
    # bundle_graph.py travels with patterns.py — see the note at the fake-skill
    # copy above; a skill copy missing it fails on an import, not on the pin.
    command cp "$SK/patterns.py" "$SK/patterns.sh" "$SK/bundle_graph.py" "$cfg/"
    command printf -- 'okf:\n  other: x\n- a top-level list item\n  pinned_version: "9.9"\n' \
        >"$cfg/thresholds.yml"
    rc_sh=0
    /usr/bin/env -u OKF_PINNED_VERSION PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$cfg/patterns.sh" "$list" >/dev/null 2>&1 || rc_sh=$?
    assert_exit 1 "$rc_sh" "okf: a top-level list item ends the okf: block — pin unresolvable (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc_py=0
        /usr/bin/env -u OKF_PINNED_VERSION python3 "$cfg/patterns.py" "$list" >/dev/null 2>&1 || rc_py=$?
        assert_exit 1 "$rc_py" "okf: a top-level list item ends the okf: block — pin unresolvable (python)"
        assert_equals "$rc_sh" "$rc_py" "okf: both impls step out of the okf: block at the same line"
    fi

    # ...and the SAME config WITHOUT the stray list item resolves in both, so the
    # two assertions above fail for the list item specifically rather than
    # because the copied skill is broken in some unrelated way.
    command printf -- 'okf:\n  other: x\n  pinned_version: "9.9"\n' >"$cfg/thresholds.yml"
    rc_sh=0
    /usr/bin/env -u OKF_PINNED_VERSION OKF_BUNDLE_ROOT="$FIXTURE_ROOT" PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$cfg/patterns.sh" "$list" >/dev/null 2>&1 || rc_sh=$?
    assert_exit 0 "$rc_sh" "okf: without the stray list item the same config resolves (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        rc_py=0
        /usr/bin/env -u OKF_PINNED_VERSION OKF_BUNDLE_ROOT="$FIXTURE_ROOT" \
            python3 "$cfg/patterns.py" "$list" >/dev/null 2>&1 || rc_py=$?
        assert_exit 0 "$rc_py" "okf: without the stray list item the same config resolves (python)"
    fi
}

# ============================================================================
# SLICE B (#669) — the whole-bundle graph + health pass.
#
# These categories are properties of the BUNDLE AS A GRAPH, which no per-file
# rule above can decide. Every one is a FINDING AT EXIT 0, exactly like the
# conformance categories: §11 forbids rejecting a bundle for broken links or a
# missing index, and a health observation is further still from a rejection.
# ============================================================================

# graph_bundle — a bundle with one index naming one real concept. The healthy
# baseline the graph fixtures perturb, so each asserts ONE deviation.
graph_bundle() {
    local b
    b="$(fresh_bundle)"
    command printf -- '# Index\n\n* [Kept](kept.md) - a thing\n' >"$b/MEMORY.md"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$b/kept.md"
    command printf '%s' "$b"
}

test_memory_orphan() {
    local b list

    # A concept no index names. THE central slice-B category: the file is
    # written, conformant, and unrecallable.
    b="$(graph_bundle)"
    command printf -- '---\ntype: reference\n---\n\nNobody points here.\n' >"$b/lonely.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" memory-orphan "Concept is named by no index" \
        "okf: a concept no index names is an orphan"
    # ...and the INDEXED sibling in the same bundle is NOT reported. Without
    # this the fixture would pass on a detector that flags every concept.
    assert_not_contains "$(emit_rows sh "$list" memory-orphan)" "kept.md" \
        "okf: an indexed concept is not an orphan (bash)"

    # §11: a bundle with NO index at all has no orphans. A bundle that does not
    # route through indexes is conformant, and reporting every concept in it is
    # the "fires on everything" failure.
    b="$(fresh_bundle)"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$b/solo.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" memory-orphan "okf: no index in the bundle means no orphans"

    # A PLAIN-LIST INDEX WORKS TOO, not only a linked one. index_targets() falls
    # back to a bare `some-file.md` mention on any line carrying no markdown
    # link, and that fallback (python's _BARE_MD_RE with its negative
    # lookbehind, mirrored by the awk `n == 0` branch and its `pre ~` exclusion)
    # was reachable by no fixture in either runtime — the same untested-mirror
    # shape that produced this PR's two parity defects.
    b="$(fresh_bundle)"
    command printf -- '# Index\n\nplain-listed.md\n\n* [Linked](linked.md) - x\n' >"$b/MEMORY.md"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$b/plain-listed.md"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$b/linked.md"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$b/unlisted.md"
    list="$(list_bundle "$b")"
    assert_not_contains "$(emit_rows sh "$list" memory-orphan)" "plain-listed.md" \
        "okf: a bare-mention index line names its concept (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" memory-orphan)" "plain-listed.md" \
            "okf: a bare-mention index line names its concept (python)"
    fi
    # Teeth: the genuinely unlisted concept in the SAME bundle still fires, so
    # this cannot pass by orphan detection going silent.
    assert_fires "$list" memory-orphan "unlisted.md" \
        "okf: ...and an unmentioned concept in the same bundle is still an orphan"

    # A DANGLING WIKI-LINK IS NOT A FINDING (#669 AC). OKF tolerates a link to
    # knowledge not yet written; this repo's own MEMORY.md tells authors to link
    # liberally to names that do not exist yet. Distinct from a dangling INDEX
    # line, which IS flagged (below).
    # OVERWRITE the indexed concept rather than appending: `>>` would have left
    # a second frontmatter block inside the body, making this an unparseable-
    # frontmatter fixture instead of a wiki-link one.
    b="$(graph_bundle)"
    command printf -- '---\ntype: reference\n---\n\nSee [[not-yet-written]].\n' >"$b/kept.md"
    list="$(make_list "$b/../../../wl" "$b/kept.md")"
    assert_no_rows "$list" "okf: a dangling [[wiki-link]] is tolerated, not flagged"
}

test_memory_dangling_index() {
    local b list

    # An index line promising a file that is not there.
    b="$(graph_bundle)"
    command printf -- '* [Ghost](ghost.md) - never written\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" memory-dangling-index "ghost.md" \
        "okf: an index line naming an absent file fires"

    # An index naming ANOTHER INDEX is ordinary structure, not a dangling
    # pointer — a root index listing its sub-indexes is the documented shape.
    b="$(graph_bundle)"
    command printf -- '* [Sub](index-extra.md)\n' >>"$b/MEMORY.md"
    command printf -- '# Extra\n\n* [Kept](kept.md) - a thing\n' >"$b/index-extra.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" memory-dangling-index \
        "okf: an index naming a sibling index is not dangling"
}

test_memory_multi_index() {
    local b list

    # One concept claimed by two DIFFERENT indexes.
    b="$(graph_bundle)"
    command printf -- '# Extra\n\n* [Kept](kept.md) - also here\n' >"$b/index-extra.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" memory-multi-index "Concept is named by more than one index" \
        "okf: a concept in two indexes fires"
    # The evidence NAMES BOTH indexes — a row that said only "duplicated" would
    # leave the reader to find them.
    assert_fires "$list" memory-multi-index "index-extra.md" \
        "okf: the multi-index evidence names the second index"

    # One index naming the same concept TWICE is a duplicate line, not a
    # multi-index: the category is about two indexes claiming ownership, and
    # counting repeats would fire on any index that mentions a file in both a
    # heading and a list.
    b="$(graph_bundle)"
    command printf -- '* [Kept again](kept.md) - same index\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" memory-multi-index \
        "okf: one index naming a concept twice is not a multi-index"
}

test_memory_stale() {
    local b list

    # THE DATE IS INJECTED, NEVER READ FROM THE CLOCK (#669 AC). The SAME
    # fixture is driven from both sides of its own stale_after, so the case
    # cannot rot into a false pass when the real date rolls past it — which is
    # exactly how a staleness test quietly stops testing anything.
    b="$(graph_bundle)"
    # The stale_check text is kept SHORT on purpose: evidence is capped at 80
    # CHARACTERS, and a longer quote is truncated mid-word, so an assertion on
    # the full sentence would fail for the cap rather than for the behavior.
    command printf -- '---\ntype: reference\nstale_after: 2026-06-30\nstale_check: "re-derive it"\n---\n\nBody.\n' >"$b/dated.md"
    command printf -- '* [Dated](dated.md) - a thing\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"

    OKF_TODAY=2026-09-05 assert_fires "$list" memory-stale "past its stale_after" \
        "okf: a past stale_after fires when today is after it"
    # THE FINDING QUOTES THE MEMORY'S OWN stale_check (#669 AC) — that field
    # names the sentence to re-verify, which beats "may be out of date".
    OKF_TODAY=2026-09-05 assert_fires "$list" memory-stale "re-derive it" \
        "okf: the stale finding quotes the memory's own stale_check"
    # The SAME fixture, before the date: silent. This is the arm that proves the
    # date is genuinely injected rather than incidental.
    OKF_TODAY=2026-01-01 assert_silent "$list" memory-stale \
        "okf: the same fixture is silent when today precedes stale_after"

    # `status: deprecated` is stale regardless of any date.
    b="$(graph_bundle)"
    command printf -- '---\ntype: reference\nmetadata:\n  status: deprecated\n---\n\nBody.\n' >"$b/old.md"
    command printf -- '* [Old](old.md) - a thing\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    OKF_TODAY=2026-01-01 assert_fires "$list" memory-stale "status: deprecated" \
        "okf: status deprecated is stale under a nested metadata block"
}

test_memory_missing_why() {
    local b list

    # A configured type whose required body sections are absent.
    b="$(graph_bundle)"
    command printf -- '---\ntype: feedback\n---\n\nGuidance with no why.\n' >"$b/fb.md"
    command printf -- '* [FB](fb.md) - a thing\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" memory-missing-why "**Why:**" \
        "okf: a feedback memory with no Why section fires"

    # The same type WITH both sections is silent — the arm that stops this
    # passing on a detector that fires for every configured type.
    b="$(graph_bundle)"
    command printf -- '---\ntype: feedback\n---\n\n**Why:** because.\n\n**How to apply:** like so.\n' >"$b/fb.md"
    command printf -- '* [FB](fb.md) - a thing\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" memory-missing-why \
        "okf: a feedback memory carrying both sections is silent"

    # AN UNCONFIGURED TYPE HAS NO REQUIREMENT — the portability default, and a
    # §4.1 obligation: types are not registered centrally and consumers must
    # tolerate unfamiliar ones, so requiring sections of a type nobody
    # configured would invent a rule the spec forbids.
    b="$(graph_bundle)"
    command printf -- '---\ntype: wholly-unfamiliar\n---\n\nNo sections at all.\n' >"$b/x.md"
    command printf -- '* [X](x.md) - a thing\n' >>"$b/MEMORY.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" memory-missing-why \
        "okf: an unconfigured type carries no body requirement"
}

# ============================================================================
# PORTABILITY (#669 AC) — a bundle with a DIFFERENT type vocabulary and
# DIFFERENT index naming validates correctly with ZERO code changes.
#
# This is the acceptance criterion that keeps librarian's own conventions as
# DEFAULTS rather than the contract. It is asserted by configuration alone.
# ============================================================================
test_health_is_configurable() {
    local b list

    b="$(fresh_bundle)"
    command printf -- '# Contents\n\n* [Alpha](alpha.md) - a thing\n' >"$b/toc.md"
    command printf -- '---\ntype: recipe\n---\n\nNo Why section anywhere.\n' >"$b/alpha.md"
    command printf -- '---\ntype: recipe\n---\n\nUnlisted.\n' >"$b/beta.md"
    list="$(list_bundle "$b")"

    # With the DEFAULT config, `toc.md` is not an index — so nothing routes, and
    # the no-index rule keeps orphan detection silent rather than reporting the
    # whole bundle. This arm is what makes the next one meaningful.
    assert_silent "$list" memory-orphan \
        "okf: an unrecognized index name leaves the bundle unrouted, not all-orphaned"

    # Naming the repo's real index makes the graph resolve: the listed concept
    # is fine, the unlisted one is an orphan. Configuration only.
    OKF_INDEX_NAMES="toc.md" assert_fires "$list" memory-orphan "beta.md" \
        "okf: a repo whose index is toc.md gets correct orphans by config alone"
    assert_not_contains "$(OKF_INDEX_NAMES="toc.md" emit_rows sh "$list" memory-orphan)" \
        "alpha.md" "okf: the concept toc.md names is not an orphan (bash)"

    # An unfamiliar type vocabulary produces NO body-requirement findings, with
    # no code change — `recipe` is configured nowhere.
    OKF_INDEX_NAMES="toc.md" assert_silent "$list" memory-missing-why \
        "okf: an unfamiliar type vocabulary yields no missing-why rows"

    # A CONFIGURED NAME CARRYING A GLOB METACHARACTER MUST STILL MATCH ITSELF.
    # An index literally called `notes[1].md` is a plain filename to its
    # operator, but reads as a character class to both fnmatch and bash `case` —
    # and `[1]` does not match the literal text `[1]`, so the file fails to
    # match its own configured name. The bundle's only index is then classified
    # as a concept: the index goes unread and EVERY memory is reported orphaned.
    #
    # Both impls got this identically wrong, so the parity gates stayed green
    # while neither worked — the shared-defect shape parity cannot see. Fixed by
    # trying literal equality for every name before any glob interpretation.
    b="$(fresh_bundle)"
    command printf -- '# Bracketed\n\n* [Alpha](alpha.md) - a thing\n' >"$b/notes[1].md"
    command printf -- '---\ntype: reference\n---\n\nIndexed.\n' >"$b/alpha.md"
    command printf -- '---\ntype: reference\n---\n\nNot indexed.\n' >"$b/gamma.md"
    list="$(list_bundle "$b")"
    # The index is READ: the concept it names is not an orphan...
    assert_not_contains "$(OKF_INDEX_NAMES="notes[1].md" emit_rows sh "$list" memory-orphan)" \
        "alpha.md" "okf: a bracketed index name matches itself, so its concept is indexed (bash)"
    # ...and the genuinely unindexed one still is, so this cannot pass by the
    # whole bundle simply going silent.
    OKF_INDEX_NAMES="notes[1].md" assert_fires "$list" memory-orphan "gamma.md" \
        "okf: with a bracketed index name the unindexed concept is still an orphan"
}

# ============================================================================
# FRONTMATTER SCOPING + KEY LOOKUP — two parity defects found by review cycle 1.
#
# Both are cases where bash and python read THE SAME FILE DIFFERENTLY, which the
# whole-repo differential could not catch because no file in this repo has the
# shape that triggers them. Each fixture below is built to be that shape.
# ============================================================================
test_frontmatter_scoping_parity() {
    local b list

    # (1) fm_get scoping. A bare key is visible at the TOP LEVEL or one level
    # under `metadata:` — NOT under an arbitrary parent, and not at any depth.
    # The bash twin used to strip indentation from every line and return the
    # first bare-key match anywhere, so a producer's own structured data under an
    # unrelated key was read as OKF metadata.
    b="$(graph_bundle)"
    command printf -- '* [Unrelated](unrelated.md) - x\n' >>"$b/MEMORY.md"
    command printf -- '---\ntype: reference\nsome_other_block:\n  status: deprecated\n---\n\nBody.\n' \
        >"$b/unrelated.md"
    list="$(list_bundle "$b")"
    # `status: deprecated` under a NON-metadata parent must not make it stale.
    assert_silent "$list" memory-stale \
        "okf: a status under an unrelated nested block is not read as OKF metadata"

    # ...and the SAME key under `metadata:` IS read — otherwise the assertion
    # above would pass on a twin that simply stopped reading nested keys at all.
    b="$(graph_bundle)"
    command printf -- '* [Deprecated](dep.md) - x\n' >>"$b/MEMORY.md"
    command printf -- '---\ntype: reference\nmetadata:\n  status: deprecated\n---\n\nBody.\n' \
        >"$b/dep.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" memory-stale "status: deprecated" \
        "okf: the same key under metadata: IS read (the scoping is narrow, not off)"

    # (2) A nested `type:` appearing BEFORE the real top-level one. The bash twin
    # returned the nested value, so a document legitimately declaring
    # `type: feedback` was reported okf-missing-type and never reached its
    # body-requirement check.
    b="$(graph_bundle)"
    command printf -- '* [Shadowed](shadow.md) - x\n' >>"$b/MEMORY.md"
    command printf -- '---\nsome_block:\n  type: nested-first\ntype: feedback\n---\n\nNo why here.\n' \
        >"$b/shadow.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" okf-missing-type \
        "okf: a nested type: does not shadow the real top-level one"
    assert_fires "$list" memory-missing-why "**Why:**" \
        "okf: ...and the top-level type still routes to its body requirement"
}

test_fm_has_finds_a_non_first_key() {
    local b list

    # fm_has matched `<TAB>key<TAB>` against the whole FM_KEYS blob, which can
    # only align on the FIRST row — every later row is preceded by a NEWLINE. So
    # any concept whose `type` was not the very first frontmatter key was
    # reported okf-missing-type despite declaring one.
    #
    # THE FIXTURE PUTS type LAST, which is the divergent case: a fixture with
    # `type` first passes with and without the fix. This repo's own 215 memories
    # all write name:/description: before type:, so this fired on every one.
    b="$(graph_bundle)"
    command printf -- '* [Late](late.md) - x\n' >>"$b/MEMORY.md"
    command printf -- '---\nname: late-type\ndescription: type is the third key\ntype: reference\n---\n\nBody.\n' \
        >"$b/late.md"
    list="$(list_bundle "$b")"
    assert_silent "$list" okf-missing-type \
        "okf: a type declared after other keys is found (fm_has is not first-row-only)"

    # Teeth: a concept that genuinely has NO type must still fire, so the
    # assertion above cannot pass by the detector going silent everywhere.
    b="$(graph_bundle)"
    command printf -- '* [None](none.md) - x\n' >>"$b/MEMORY.md"
    command printf -- '---\nname: no-type-at-all\ndescription: really none\n---\n\nBody.\n' \
        >"$b/none.md"
    list="$(list_bundle "$b")"
    assert_fires "$list" okf-missing-type "no type key" \
        "okf: a concept with no type at all still fires"
}

# ============================================================================
# UNIT: the config parser and the index matcher, called DIRECTLY (#669).
#
# Every fixture above drives these through the scanner end-to-end, which proves
# the behavior but leaves the helpers unreferenced by name — `untested-public-api`
# flags exactly that, and it is right to: an end-to-end fixture exercises only
# the input shapes the bundle happens to contain, so a boundary no fixture spells
# (an absent key vs a key configured empty, a name that is both a literal and a
# pattern) is asserted nowhere. check-decomposition's sibling module is unit-
# tested the same way, and its own comment names literal-vs-glob root matching
# "the arm most at risk of a parity split" — the class the is_index bug landed in.
#
# Asserted against BOTH runtimes, since a helper is where the two can silently
# diverge while the TSV still matches on this repo's own bundle.
# ============================================================================
test_config_helpers_direct() {
    local cfg out

    if [ "$HAVE_PY" -eq 1 ]; then
        # No env override needed: every call below passes its names explicitly,
        # so read_index_names() (the only reader of $OKF_INDEX_NAMES) is not on
        # this path.
        out="$(python3 -c "
import sys
sys.path.insert(0, '$SK')
from bundle_graph import is_index, read_config_list

# is_index: a name that is simultaneously a valid literal and a valid glob must
# match ITSELF. This is the divergent case — a fixture using 'index-*.md' passes
# with and without the two-pass literal-first order.
print('bracket-literal', is_index('notes[1].md', ['notes[1].md']))
print('glob-still-works', is_index('index-extra.md', ['index-*.md']))
print('glob-no-false-hit', is_index('MEMORY.md', ['index-*.md']))
print('question-literal', is_index('a?b.md', ['a?b.md']))

# read_config_list: ABSENT key vs key-present-with-no-items are different
# answers (None vs []), and the caller depends on the difference to tell 'use the
# default' from 'the operator configured none'. Collapsing them would make a rule
# impossible to turn off, and no end-to-end fixture can see it.
print('absent-key', read_config_list('$SK/thresholds.yml', 'no_such_key_here') is None)
print('present-key', read_config_list('$SK/thresholds.yml', 'index_names'))
" 2>&1)" || true

        assert_contains "$out" "bracket-literal True" \
            "okf/unit: a bracketed index name matches itself (python)"
        assert_contains "$out" "glob-still-works True" \
            "okf/unit: a genuine glob default still matches (python)"
        assert_contains "$out" "glob-no-false-hit False" \
            "okf/unit: the glob does not match an unrelated name (python)"
        assert_contains "$out" "question-literal True" \
            "okf/unit: a '?'-bearing literal name matches itself (python)"
        assert_contains "$out" "absent-key True" \
            "okf/unit: an ABSENT config key returns None, not an empty list (python)"
        assert_contains "$out" "MEMORY.md" \
            "okf/unit: a present config key returns its items (python)"
    fi

    # The bash twin, driven through the same is_index contract. Sourcing
    # patterns.sh would execute it, so the function is exercised by invoking the
    # scanner with an OKF_INDEX_NAMES override and observing the classification
    # it produces — the only bash-side seam that does not require refactoring the
    # scanner into a library.
    local b list
    b="$(fresh_bundle)"
    command printf -- '# Bracketed\n\n* [Alpha](alpha.md) - a thing\n' >"$b/notes[1].md"
    command printf -- '---\ntype: reference\n---\n\nIndexed.\n' >"$b/alpha.md"
    command printf -- '---\ntype: reference\n---\n\nUnindexed.\n' >"$b/beta.md"
    list="$(list_bundle "$b")"
    # The bracketed name is honored as an index: its concept is not an orphan,
    # and the file it does NOT name still is.
    assert_not_contains "$(OKF_INDEX_NAMES="notes[1].md" emit_rows sh "$list" memory-orphan)" \
        "alpha.md" "okf/unit: bash honors a bracketed index name (bash)"
    OKF_INDEX_NAMES="notes[1].md" assert_fires "$list" memory-orphan "beta.md" \
        "okf/unit: bash still reports the genuinely unindexed concept (bash)"
}

# ============================================================================
# DELEGATION PIN (#669) — index SIZING belongs to check-decomposition.
#
# `memory-index-bloat` and the topic-clustered split recommendation are
# deliberately NOT implemented here: check-decomposition already emits both, and
# a second detector would fork the one authoritative prose-threshold table that
# #663/#589 exist to keep singular.
#
# That delegation is only safe while the upstream scanner actually still emits
# those rows. This test is what stops the delegation decaying into a silent gap
# — the absence of slice-B code would otherwise read as a missing feature to a
# future reader, and nothing would fail if upstream stopped emitting.
# ============================================================================
test_index_sizing_is_delegated() {
    local decomp="$SKILLS_DIR/check-decomposition/patterns.sh" b list out i

    if [ ! -f "$decomp" ]; then
        skip_test "check-decomposition is not installed alongside this skill"
        return
    fi

    b="$(fresh_bundle)"
    # An index over the memory_index high budget (250) with three clear topic
    # clusters for the seam finder to name.
    {
        command printf -- '# Memory index\n\n'
        command printf -- '## Alpha topics\n'
        i=0
        while [ "$i" -lt 90 ]; do
            command printf -- '* [Alpha %s](alpha-%s.md) - hook\n' "$i" "$i"
            i=$((i + 1))
        done
        command printf -- '\n## Beta topics\n'
        i=0
        while [ "$i" -lt 90 ]; do
            command printf -- '* [Beta %s](beta-%s.md) - hook\n' "$i" "$i"
            i=$((i + 1))
        done
        command printf -- '\n## Gamma topics\n'
        i=0
        while [ "$i" -lt 90 ]; do
            command printf -- '* [Gamma %s](gamma-%s.md) - hook\n' "$i" "$i"
            i=$((i + 1))
        done
    } >"$b/MEMORY.md"
    list="$(make_list "$b/../../../dl" "$b/MEMORY.md")"

    out="$(MEMORY_BUNDLE_ROOT="$FIXTURE_ROOT" PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$decomp" "$list" 2>/dev/null)"

    assert_contains "$out" "ai-file-bloat" \
        "okf: check-decomposition still sizes an oversized memory index (delegated)"
    assert_contains "$out" "memory index" \
        "okf: the delegated row is typed as a memory index, not generic prose"
    assert_contains "$out" "decomposition-seam" \
        "okf: check-decomposition still recommends a split for it (delegated)"
    # The AC is that the recommendation names CONCRETE CLUSTERS rather than
    # saying "consider splitting" — assert a cluster name, not just the row.
    assert_contains "$out" "alpha_topics" \
        "okf: the delegated split recommendation names concrete topic clusters"

    # ...and THIS scanner stays out of it: no index-sizing category of its own.
    assert_silent "$list" memory-index-bloat \
        "okf: check-okf-conformance does not emit its own index-bloat row"
}

run_test test_healthy_bundle_is_silent "check-okf-conformance: a conformant bundle produces ZERO findings"
run_test test_missing_type "check-okf-conformance: absent / empty / whitespace-only type"
run_test test_unparseable_frontmatter "check-okf-conformance: absent, unterminated, and malformed frontmatter"
run_test test_reserved_file_structure "check-okf-conformance: index.md §8 + log.md §9 + reserved-file exemption"
run_test test_version_drift "check-okf-conformance: drift is LOW at exit 0, and the pin has ONE source"
run_test test_permissive_conformance "check-okf-conformance: §11 MUST-NOTs stay silent (unknown type, extra keys, broken links)"
run_test test_bundle_discovery "check-okf-conformance: root override, normalization, precedence, no-bundle exit 0"
run_test test_fail_loud_runtime "check-okf-conformance: unresolvable pin / usage / missing list fail LOUD and non-zero"
run_test test_pin_resolution_parity "check-okf-conformance: bash/python resolve the version pin identically"
run_test test_evidence_truncation_parity "check-okf-conformance: >80-char multibyte evidence truncation parity"
run_test test_memory_orphan "check-okf-conformance: orphans, the no-index rule, and tolerated [[wiki-links]]"
run_test test_memory_dangling_index "check-okf-conformance: a dangling index line vs an index naming an index"
run_test test_memory_multi_index "check-okf-conformance: two indexes claiming one concept vs a repeated line"
run_test test_memory_stale "check-okf-conformance: staleness against an INJECTED date, quoting stale_check"
run_test test_memory_missing_why "check-okf-conformance: per-type body requirements, and unconfigured types"
run_test test_health_is_configurable "check-okf-conformance: a foreign vocabulary + index naming works by config alone"
run_test test_frontmatter_scoping_parity "check-okf-conformance: frontmatter keys are metadata-scoped, and a nested type does not shadow"
run_test test_fm_has_finds_a_non_first_key "check-okf-conformance: a type declared after other keys is found (fm_has row boundary)"
run_test test_config_helpers_direct "check-okf-conformance: is_index + read_config_list called directly (both runtimes)"
run_test test_index_sizing_is_delegated "check-okf-conformance: index sizing stays delegated to check-decomposition"

generate_report
