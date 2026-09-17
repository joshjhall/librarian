#!/usr/bin/env bash
# Regenerate the classifier-lang fixture trees (#1073).
#
# NOT run by the suite — the fixtures are COMMITTED, for the reason stated in
# this directory's README. This script exists so a future EXT_LANG change can
# re-derive them in one step instead of by hand-editing seven trees, and so the
# tamper applied to each is recorded as code rather than inferred from a diff.
#
# Run from the repo root:  bash tests/fixtures/classifier-lang/.build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOC_REL="plugins/review-audit/skills/check-decomposition/loc_engine.py"
CR_REL="plugins/dev-core/agents/code-reviewer.md"
OP_REL="plugins/review-audit/skills/codebase-audit/orchestration-protocol.md"

# The normative stub: just the EXT_LANG literal the gate parses. Kept minimal
# rather than copied whole — the gate reads one dict, and a 900-line copy would
# rot against the real file for no benefit.
write_loc() {
    local dest="$1" body="$2"
    command mkdir -p "$(command dirname "$dest")"
    command cat >"$dest" <<EOF
# Fixture stub — the normative table only. See .build.sh.
EXT_LANG = {
$body
}
EOF
}

NORMATIVE_BODY='    "py": "py",
    "js": "js",
    "jsx": "js",
    "mjs": "js",
    "cjs": "js",
    "ts": "ts",
    "tsx": "ts",
    "rs": "rs",
    "go": "go",
    "sh": "sh",
    "bash": "sh",
    "md": "md",
    "markdown": "md",
    "swift": "swift",'

# A classifier stub: the two rows the gate reads, nothing else.
write_reviewer() {
    local dest="$1" source_row="$2" docs_row="$3"
    command mkdir -p "$(command dirname "$dest")"
    command cat >"$dest" <<EOF
<!-- Fixture stub: code-reviewer.md Step 2 table only. See .build.sh -->

| Type     | Extensions / Paths |
| -------- | ------------------ |
| source   | $source_row |
| docs     | $docs_row |
EOF
}

write_protocol() {
    local dest="$1" source_row="$2" doc_row="$3"
    command mkdir -p "$(command dirname "$dest")"
    command cat >"$dest" <<EOF
<!-- Fixture stub: orchestration-protocol.md classification table only. See .build.sh -->

| Classification | Extensions / Patterns |
| -------------- | --------------------- |
| Source         | $source_row |
| Doc            | $doc_row |
EOF
}

# The correct rows, matching the real tree.
GOOD_SOURCE='`.py`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`, `.rs`, `.go`, `.sh`, `.bash`, `.swift`, `.rb`, `.java`, `.kt`, `.c`, `.cpp`'
GOOD_DOCS='`.md`, `.markdown`, `.rst`, `.adoc`'
GOOD_PROTO_SOURCE="$GOOD_SOURCE, \`.h\`"

# fixture NAME — lay down a fully-correct tree, then the caller tampers it.
fixture() {
    local dir="$HERE/$1"
    command rm -rf "$dir"
    write_loc "$dir/$LOC_REL" "$NORMATIVE_BODY"
    write_reviewer "$dir/$CR_REL" "$GOOD_SOURCE" "$GOOD_DOCS"
    write_protocol "$dir/$OP_REL" "$GOOD_PROTO_SOURCE" "$GOOD_DOCS"
    command printf '%s' "$dir"
}

# --- clean: no tamper at all -------------------------------------------------
fixture clean >/dev/null

# --- empty-normative: EXT_LANG present but empty (assertion 1) ---------------
d="$(fixture empty-normative)"
write_loc "$d/$LOC_REL" ""

# --- missing-normative: loc_engine.py ABSENT ENTIRELY (assertion 1) ----------
# The OTHER way to reach an empty normative table: `empty-normative` writes a
# file whose EXT_LANG literal is empty, this one omits the file, so the parser
# takes its `os.path.exists(...)` false branch instead of its empty-literal one.
# Both must surface as a failed anti-vacuity check rather than as a silent
# nothing-to-compare — kept separate for the same reason `no-table` is separate
# from `empty-normative` on the subject side (cycle-2 review).
d="$(fixture missing-normative)"
command rm -f "$d/$LOC_REL"

# --- no-table: the source row heading is renamed (assertion 2) ---------------
# Renamed rather than deleted: a deleted table and a renamed row are the same
# defect from the gate's side (the row does not resolve), and renaming keeps the
# file otherwise plausible, which is the realistic shape of the mistake.
d="$(fixture no-table)"
write_reviewer "$d/$CR_REL" "$GOOD_SOURCE" "$GOOD_DOCS"
command sed -i.bak 's/^| source /| sources /' "$d/$CR_REL"
command rm -f "$d/$CR_REL.bak"

# --- missing-swift: THIS ISSUE'S OWN DEFECT (assertion 4) --------------------
d="$(fixture missing-swift)"
write_reviewer "$d/$CR_REL" \
    '`.py`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`, `.rs`, `.go`, `.sh`, `.bash`, `.rb`, `.java`, `.kt`, `.c`, `.cpp`' \
    "$GOOD_DOCS"

# --- contradiction-doc: a source language in the docs row (assertion 3) ------
# The FAIL-OPEN direction.
d="$(fixture contradiction-doc)"
write_reviewer "$d/$CR_REL" "$GOOD_SOURCE" "$GOOD_DOCS, \`.go\`"

# --- contradiction-inverse: markdown in the source row (assertion 3) ---------
# The SAFE direction — still forbidden.
d="$(fixture contradiction-inverse)"
write_reviewer "$d/$CR_REL" "$GOOD_SOURCE, \`.md\`" "$GOOD_DOCS"

# --- undeclared-source: an unknown extension in the source row (assertion 5) -
# `.lua` is absent from EXT_LANG and from UNSEGMENTED_SOURCE, so nothing states
# whether it is a deliberate coarsening or drift.
d="$(fixture undeclared-source)"
write_reviewer "$d/$CR_REL" "$GOOD_SOURCE, \`.lua\`" "$GOOD_DOCS"

# --- second-subject: the SECOND file is tampered, the first is correct -------
# Proves assertion 4 does not stop after SUBJECTS[0].
d="$(fixture second-subject)"
write_protocol "$d/$OP_REL" \
    '`.py`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`, `.rs`, `.go`, `.sh`, `.bash`, `.rb`, `.java`, `.kt`, `.c`, `.cpp`, `.h`' \
    "$GOOD_DOCS"

# --- second-subject-contradiction / -undeclared ------------------------------
# The SAME per-subject proof for assertions 3 and 5, which `second-subject`
# above establishes only for assertion 4 (found by this PR's own review).
#
# Without these, assertions 3 and 5 are proven to fire against code-reviewer.md
# and NOTHING proves they fire against orchestration-protocol.md — precisely the
# "enforced on the copy someone remembered" shape this whole issue is about,
# reappearing inside the gate written to end it.
#
# The two subjects spell their doc row DIFFERENTLY (`docs` vs `Doc`), so this is
# not a theoretical asymmetry: a typo in the second tuple's row name would make
# `table_row_exts` return None for it. Assertion 2 would catch a wholly
# unresolvable row, but a row name that resolves to the WRONG row would not be
# caught by anything else — a doc-row tamper is what exercises that path.
d="$(fixture second-subject-contradiction)"
write_protocol "$d/$OP_REL" "$GOOD_PROTO_SOURCE" "$GOOD_DOCS, \`.go\`"

d="$(fixture second-subject-undeclared)"
write_protocol "$d/$OP_REL" "$GOOD_PROTO_SOURCE, \`.lua\`" "$GOOD_DOCS"

command printf 'fixtures rebuilt under %s\n' "$HERE"
