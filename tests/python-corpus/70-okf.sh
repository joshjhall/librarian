# shellcheck shell=bash
# check-okf-conformance corpus — python coverage fixtures (issue #668).
#
# Builds a memory bundle exercising every OKF conformance branch: the four
# detector categories, the permissive §11 MUST-NOTs, and the reserved-file
# routing.
#
# Sourced by tests/coverage-python.sh, which creates WORKDIR and its EXIT trap
# BEFORE this file. This fragment only BUILDS FIXTURES and exports the path-list
# variables the driver section then feeds to each port under `coverage run`.
#
# NOTE: unlike the tests/ fragments, nothing here asserts — coverage-python.sh is
# a Codecov driver, not a test suite (it has zero run_test calls and is not wired
# into tests/run-all.sh). The behavioural gate for these detectors lives in
# tests/validate-okf-detectors.sh, and this corpus is kept in lockstep with it.

# The path-list / fixture-path variables below are the corpus's EXPORT surface:
# they are read by the driver loop in tests/coverage-python.sh, which sources
# this file. shellcheck analyses one file at a time and so cannot see those
# uses.
# shellcheck disable=SC2034  # consumed by the driver in tests/coverage-python.sh

# --- check-okf-conformance corpus (#668) ------------------------------------
# The OKF port scans ONLY markdown under the configured bundle root, so none of
# its branches execute under the generic corpus — every fixture must live inside
# a bundle-shaped path. The driver runs this port with OKF_BUNDLE_ROOT pointing
# at the same relative root these fixtures are built under.
#
# Covered branches: scan_index (root + nested, drift + match + absent version),
# scan_log (ISO + non-ISO + fenced), scan_concept (present / absent / empty
# type), parse_frontmatter (all four outcomes: clean, no-block, unterminated,
# bad-line), the extension-tolerance path, and the non-markdown / outside-bundle
# skips. Correctness is pinned by the gate, not here.
OKF_ROOT_REL=".claude/memory"
OKFDIR="$FIXDIR/okf/$OKF_ROOT_REL"
mkdir -p "$OKFDIR/sub"

# Bundle-root index.md declaring a DRIFTED version — drives scan_index's
# at-root arm, the okf_version lookup, and _okf_version_line.
{
    printf -- '---\n'
    printf -- 'okf_version: "9.9"\n'
    printf -- '---\n'
    printf -- '\n# Index\n\n* [Minimal](minimal.md) - a thing\n'
} >"$OKFDIR/index.md"

# Root log.md: an ISO heading (silent), a non-ISO heading (fires), and a
# date-shaped heading inside a fence (skipped) — all three scan_log branches.
{
    printf -- '# Log\n\n'
    printf -- '```\n## Not-A-Date-In-A-Fence\n```\n\n'
    printf -- '## 2026-08-19\n* **Update**: a thing\n\n'
    printf -- '## March 2026\n* **Update**: another thing\n'
} >"$OKFDIR/log.md"

# A minimal conformant concept — `type` alone is the whole floor.
{
    printf -- '---\ntype: user\n---\n\nBody.\n'
} >"$OKFDIR/minimal.md"

# A rich concept: comments, list items, nested mappings, and local extension
# keys. Drives parse_frontmatter's nested/list/comment arms and the
# extension-tolerance path (no findings).
{
    printf -- '---\n'
    printf -- '# a comment inside the block\n'
    printf -- 'type: Some Entirely Invented Type\n'
    printf -- 'title: A thing\n'
    printf -- 'tags:\n  - one\n  - two\n'
    printf -- 'metadata:\n  status: stable\n'
    printf -- 'stale_check: "what specifically rots"\n'
    printf -- '---\n\nBody with a [broken link](does-not-exist.md).\n'
} >"$OKFDIR/rich.md"

# The three concept-level failure branches.
printf -- '---\ndescription: no type here\n---\n\nBody.\n' >"$OKFDIR/no-type.md"
printf -- '---\ntype:\n---\n\nBody.\n' >"$OKFDIR/empty-type.md"
printf -- 'No frontmatter block at all.\n' >"$OKFDIR/bare.md"

# The two remaining parse_frontmatter failure branches.
printf -- '---\ntype: user\nTHIS LINE HAS NO COLON\n---\n' >"$OKFDIR/badline.md"
printf -- '---\ntype: user\n' >"$OKFDIR/unterminated.md"

# Nested: a concept, and an index.md with frontmatter (fires — §8 permits it
# only at the bundle root). Drives is_bundle_root_file's negative arm.
printf -- '---\ntype: project\n---\n\nNested body.\n' >"$OKFDIR/sub/nested.md"
printf -- '---\ntitle: Not allowed here\n---\n\n# Sub index\n' >"$OKFDIR/sub/index.md"

# A non-markdown file inside the bundle (skipped) and a markdown file OUTSIDE it
# (skipped) — the two early-continue arms in main().
printf -- 'type = not markdown\n' >"$OKFDIR/notes.txt"
printf -- '---\ntype: user\n---\n\nOutside the bundle.\n' >"$FIXDIR/okf/README.md"

OKF_LIST="$WORKDIR/okf-list.txt"
{
    printf '%s\n' ""
    printf '%s\n' "$OKFDIR/index.md"
    printf '%s\n' "$OKFDIR/log.md"
    printf '%s\n' "$OKFDIR/minimal.md"
    printf '%s\n' "$OKFDIR/rich.md"
    printf '%s\n' "$OKFDIR/no-type.md"
    printf '%s\n' "$OKFDIR/empty-type.md"
    printf '%s\n' "$OKFDIR/bare.md"
    printf '%s\n' "$OKFDIR/badline.md"
    printf '%s\n' "$OKFDIR/unterminated.md"
    printf '%s\n' "$OKFDIR/sub/nested.md"
    printf '%s\n' "$OKFDIR/sub/index.md"
    printf '%s\n' "$OKFDIR/notes.txt"
    printf '%s\n' "$FIXDIR/okf/README.md"
    # A ghost path inside the bundle — drives the per-file OSError continue.
    printf '%s\n' "$OKFDIR/ghost.md"
} >"$OKF_LIST"

# A list pointing at a path that does not exist — the file-list-not-found arm.
OKF_NOFILE_LIST="$WORKDIR/okf-nofile-list.txt"
printf '%s\n' "$WORKDIR/definitely-not-here/list.txt" >"$OKF_NOFILE_LIST"

# A thresholds.yml with NO pin, beside a copy of the port — drives the
# unresolvable-pin fail-loud branch, which the real skill dir can never reach.
OKF_NOPIN_DIR="$WORKDIR/okf-nopin"
mkdir -p "$OKF_NOPIN_DIR"
cp "$PLUGINS_DIR/review-audit/skills/check-okf-conformance/patterns.py" "$OKF_NOPIN_DIR/"
printf -- 'severity:\n  okf-missing-type:\n    absent_or_empty: medium\n' \
    >"$OKF_NOPIN_DIR/thresholds.yml"
OKF_NOPIN_PY="$OKF_NOPIN_DIR/patterns.py"
