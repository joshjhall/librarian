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
    command printf -- '---\nokf_version: "0.2"\n---\n\n# Index\n\n* [A](a.md) - a thing\n' >"$b/index.md"
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
    command printf -- '---\ntype: feedback\nstale_after: 2026-10-31\nstale_check: "what specifically rots"\nwholly_invented_key: 42\n---\n\nBody.\n' >"$b/ext.md"
    list="$(make_list "$b/../../../l" "$b/ext.md")"
    assert_no_rows "$list" "okf: unrecognized extra keys incl. a stale_check extension are conformant"

    # §11/§12: a bundle-root index.md with NO okf_version is fine — declaring one
    # is optional.
    b="$(fresh_bundle)"
    command printf -- '# Index\n\n* [A](a.md) - thing\n' >"$b/index.md"
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
    command cp "$SK/patterns.py" "$SK/patterns.sh" "$fake/"
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
    command cp "$SK/patterns.py" "$SK/patterns.sh" "$cfg/"
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

generate_report
