#!/usr/bin/env bash
# check-decomposition detector behavioral gate (issue #663).
#
# check-decomposition is the single source of truth for production-LOC counting
# across the audit plugins: the per-language exclusion rules that
# audit-code-health, audit-architecture and audit-ai-config each carried as their
# own drifting prose copy now live in one scanner, and the deliverable is an
# actionable SEAM ("lines 412-680, the parse_* family, fan-in 1 -> parser/parse.rs")
# rather than a bare line count.
#
# This is the behavioral half of the #204 two-surface convention for that
# scanner. validate-python-ports.sh only asserts bash==python PARITY over a
# shared fixture tree, which — as its own header notes — "cannot catch a
# regression where both impls break the same way". This gate pins the actual
# detector output: for each of the six segmenters (Python, JS/TS, Rust, Go,
# Shell, Markdown) a purpose-built fixture must produce a seam with the RIGHT
# span, family and fan-in, and a counter-fixture must stay silent.
#
# It also carries the ai-file-bloat / doc-file-bloat cases MOVED here from
# tests/validate-checker-detectors.sh when #663 moved those categories off
# check-ai-config — including the #494 flat-vs-nested agent glob arms and the
# #222 "docs bloat does not emit under ai-file-bloat" counter. Moving them
# preserves the coverage across the ownership change instead of deleting it.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# MUTATION-VERIFIED (the #221 precedent, and the reason the issue demanded it).
# Every segmenter assertion below was proven to catch a regression by transiently
# breaking the scanner and confirming this gate goes red, then reverting. An
# unmutated fixture can pass with AND without the feature — see the
# anchored-regex-tautological-test and escaped-fixture-cannot-self-match lessons.
# The mutations checked, one per segmenter plus the shared machinery:
#   py       — UNIT_RE["py"] def/class arm made non-matching     -> 2 cases red
#   js       — UNIT_RE["js"] function arm made non-matching      -> 1 case  red
#   rs       — UNIT_RE["rs"] fn/impl arm made non-matching       -> 1 case  red
#   go       — UNIT_RE["go"] func arm made non-matching          -> 2 cases red
#   sh       — UNIT_RE["sh"] paren arm made non-matching         -> 1 case  red
#   md       — the heading regex in find_units made non-matching -> 1 case  red
#   fan_in   — early-returned (0, "")                            -> 4 cases red
#   test-excl— TEST_UNIT_RE["go"] made non-matching              -> 1 case  red
#   decline  — the decline emit branch disabled                  -> 1 case  red
#   god-mod  — the >= god_concerns requirement relaxed to >= 0   -> 1 case  red
#   adjacency— the index-adjacency guard dropped, in BOTH impls  -> 1 case  red
#              (py: `and idx == last_idx + 1`; sh: `clast[nc] == i - 1`)
#   prose-decline — comment_pct >= 50 raised to >= 99, BOTH impls -> 1 case red
#   decline-order — the cohesive branch disabled so prose wins    -> 1 case red
#   py-region — the `if __name__` marker, BOTH impls              -> 1 case red
#   sh-region — the `# --- tests ---` marker, BOTH impls          -> 1 case red
# All went red under mutation and green on revert.
#
# The last four were added by the pre-PR review (cycle 1): the fourth decline
# reason and the two whole-file test-REGION markers were exercised only by the
# Codecov corpus, which asserts nothing — so a broken region regex would have
# shown green coverage and a green suite simultaneously. Note `decline-order`:
# it pins the BRANCH ORDER, not just the predicate, since a reason chosen by the
# wrong arm is still a wrong finding.
#
# The adjacency case is here BECAUSE the first mutation round found it was the
# one rule with no failing test — the suite stayed green with the guard removed.
# That is the anchored-regex-tautological-test failure mode caught in the act:
# a rule nothing asserts is a rule that silently regresses. Its fixture carries a
# positive control (the same family, contiguous, MUST still be a seam) so the
# negative cannot pass merely because the segmenter stopped matching entirely.
#
# The scanner reads only file CONTENT (no git-rooting), so every fixture runs
# from $WORKDIR and CWD is irrelevant.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
# Pure bash-3.2 + coreutils; full command paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/check-decomposition"
PY="$SKILL_DIR/patterns.py"
SH="$SKILL_DIR/patterns.sh"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-decomposition detector fixtures (#663)"

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

# ============================================================================
# JS/TS segmenter
# ============================================================================
test_seam_js() {
    local d f list
    d="$(fresh_dir)"
    f="$d/app.ts"
    command cat >"$f" <<'EOF'
export function mainEntry(x: string) {
  return renderHeader(x);
}

export function renderHeader(x: string) {
  const a = 1;
  return x + a;
}

export function renderBody(x: string) {
  const b = 2;
  return x + b;
}

export function renderFooter(x: string) {
  return x;
}
EOF
    list="$(list_of "$f")"

    # camelCase family split: renderHeader/renderBody/renderFooter -> "render".
    assert_fires "$list" decomposition-seam "seam 5-17: function render_* family (3 units," \
        "js: camelCase render* seam span and family"
    assert_fires "$list" decomposition-seam "fan-in 1 <- mainEntry" \
        "js: seam fan-in names its caller"

    # Counter: a describe() test file's units are test-excluded, so the file is
    # not reported as production-oversized.
    f="$d/app.test.ts"
    command cat >"$f" <<'EOF'
describe('a', () => {
  it('b', () => { expect(1).toBe(1); });
  it('c', () => { expect(2).toBe(2); });
  it('d', () => { expect(3).toBe(3); });
});
EOF
    list="$(list_of "$f")"
    assert_silent "$list" file-length "js: a describe()-only test file is not production-oversized"
}

# ============================================================================
# Rust segmenter
# ============================================================================
test_seam_rust() {
    local d f list
    d="$(fresh_dir)"
    f="$d/parser.rs"
    command cat >"$f" <<'EOF'
pub fn main_entry(input: &str) -> Result<Doc> {
    let e = parse_entry(input)?;
    Ok(Doc::from(e))
}

pub fn parse_entry(s: &str) -> Result<Entry> {
    Ok(Entry { h: parse_header(s)? })
}

fn parse_header(s: &str) -> Result<Header> {
    let mut out = Header::default();
    for line in s.lines() { out.push(line); }
    Ok(out)
}

fn parse_body(s: &str) -> Result<Body> {
    Ok(Body::default())
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(true); }
}
EOF
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "seam 6-20: fn parse_* family (3 units," \
        "rust: parse_* seam span and family"
    assert_fires "$list" decomposition-seam "> $d/parser/parse.rs" \
        "rust: seam proposes a concrete target module"
    # #[cfg(test)] to EOF is excluded — the rule that used to be prose in two agents.
    assert_fires "$list" file-length "5 test-excluded" \
        "rust: #[cfg(test)] region excluded from production LOC"
}

# ============================================================================
# Go segmenter
# ============================================================================
test_seam_go() {
    local d f list
    d="$(fresh_dir)"
    f="$d/app.go"
    command cat >"$f" <<'EOF'
package main

func MainEntry(s string) string {
	return handleRequest(s)
}

func handleRequest(s string) string {
	return s + "a"
}

func handleResponse(s string) string {
	return s + "b"
}

func handleError(s string) string {
	return s + "c"
}

func TestMainEntry(t *testing.T) {
	MainEntry("x")
}
EOF
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "seam 7-18: func handle_* family (3 units," \
        "go: handle* seam span and family"
    assert_fires "$list" decomposition-seam "fan-in 1 <- MainEntry" \
        "go: seam fan-in names its caller"
    # func Test... excluded — the other rule that was duplicated prose.
    assert_fires "$list" file-length "3 test-excluded" \
        "go: func Test excluded from production LOC"
}

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

# ============================================================================
# ai-file-bloat — MOVED from validate-checker-detectors.sh by #663.
# Thresholds tuned down via env so a tiny fixture trips them.
# ============================================================================
test_ai_file_bloat() {
    local d f list
    d="$(fresh_dir)"

    # 5-line CLAUDE.md with HIGH driven to 3 -> exceeds high (HIGH).
    f="$d/CLAUDE.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "exceeds high threshold" \
        "ai-file-bloat: CLAUDE.md over high threshold flagged" \
        CLAUDE_MD_WARN=2 CLAUDE_MD_HIGH=3

    # Same file, WARN=3 HIGH=99 -> warning arm only (MEDIUM).
    assert_fires "$list" ai-file-bloat "exceeds warning threshold" \
        "ai-file-bloat: CLAUDE.md over warning threshold flagged" \
        CLAUDE_MD_WARN=3 CLAUDE_MD_HIGH=99

    # Counter: comfortably under both thresholds -> silent.
    assert_silent "$list" ai-file-bloat \
        "ai-file-bloat: CLAUDE.md under thresholds is silent" \
        CLAUDE_MD_WARN=50 CLAUDE_MD_HIGH=99

    # SKILL.md threshold arm (separate env family).
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "---" "description: d" "---" "## Workflow" "a" "b" "c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "ai-file-bloat: SKILL.md over high threshold flagged" \
        SKILL_WARN=2 SKILL_HIGH=3

    # Agent-definition arm — the FLAT layout agents/<name>.md (Claude Code's
    # discovery form). The bloat glob was */agents/*/*.md only, which does not
    # match a flat file, so a flat agent over threshold was silently missed (#494).
    command mkdir -p "$d/agents"
    f="$d/agents/rev.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "agent definition exceeds high threshold" \
        "ai-file-bloat: FLAT agent md over high threshold flagged (#494)" \
        AGENT_WARN=2 AGENT_HIGH=3

    # Counter: the widened glob must not OVER-fire — a flat agent comfortably
    # under threshold stays silent (mirrors the CLAUDE.md silent counter above).
    assert_silent "$list" ai-file-bloat \
        "ai-file-bloat: FLAT agent md under thresholds is silent (#494)" \
        AGENT_WARN=50 AGENT_HIGH=99

    # Agent-definition arm — the NESTED layout agents/<name>/<name>.md (a
    # harness-bearing agent's sibling md). Must still fire after the glob widened.
    command mkdir -p "$d/agents/nested"
    f="$d/agents/nested/nested.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "agent definition exceeds warning threshold" \
        "ai-file-bloat: NESTED agent md over warning threshold flagged" \
        AGENT_WARN=3 AGENT_HIGH=99
}

# ============================================================================
# doc-file-bloat — MOVED from validate-checker-detectors.sh by #663.
# */docs/*.md over DOC_WARN/DOC_HIGH; a docs file must emit doc-file-bloat and
# NOT ai-file-bloat (the #222 split).
# ============================================================================
test_doc_file_bloat() {
    local d f list
    d="$(fresh_dir)"

    command mkdir -p "$d/docs"
    f="$d/docs/guide.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"

    # 5-line docs file, HIGH driven to 3 -> exceeds high (HIGH), under doc-file-bloat.
    assert_fires "$list" doc-file-bloat "documentation exceeds high threshold" \
        "doc-file-bloat: docs/*.md over high threshold flagged" \
        DOC_WARN=2 DOC_HIGH=3
    # It must NOT surface under the ai-file-bloat slug (the split is the point).
    assert_silent "$list" ai-file-bloat \
        "doc-file-bloat: docs bloat does not emit under ai-file-bloat" \
        DOC_WARN=2 DOC_HIGH=3

    # Warning arm (MEDIUM).
    assert_fires "$list" doc-file-bloat "documentation exceeds warning threshold" \
        "doc-file-bloat: docs/*.md over warning threshold flagged" \
        DOC_WARN=3 DOC_HIGH=99

    # Counter: comfortably under both -> silent.
    assert_silent "$list" doc-file-bloat \
        "doc-file-bloat: docs/*.md under thresholds is silent" \
        DOC_WARN=50 DOC_HIGH=99
}

# ============================================================================
# god-module — size AND many units AND several concerns (never size alone)
# ============================================================================
test_god_module() {
    local d f list i
    d="$(fresh_dir)"

    # 15 units across 3 concern families -> god-module.
    f="$d/god.py"
    : >"$f"
    for i in 1 2 3 4 5; do
        command printf 'def parse_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    for i in 1 2 3 4 5; do
        command printf 'def render_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    for i in 1 2 3 4 5; do
        command printf 'def store_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_fires "$list" god-module "15 top-level units, 3 concerns" \
        "god-module: size + unit count + concern spread fires"

    # Counter: an equally LONG file with ONE concern is not a god module —
    # size alone must never be sufficient, which is the whole rule.
    f="$d/cohesive.py"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        command printf 'def parse_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_silent "$list" god-module \
        "god-module: a long SINGLE-concern file is not a god module (size alone insufficient)"
}

# ============================================================================
# Skips and thresholds
# ============================================================================
test_skips_and_thresholds() {
    local d f list
    d="$(fresh_dir)"

    # Lock/data files are skipped wholesale regardless of size.
    f="$d/package-lock.json"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" "l6" "l7" "l8" >"$f"
    list="$(list_of "$f")"
    assert_silent "$list" file-length "skip: a lock file is never size-reported"

    # Thresholds are genuinely project-overridable: the SAME file crosses or
    # stays under the line depending only on DECOMP_LOC_WARN.
    f="$d/mid.py"
    command cat >"$f" <<'EOF'
def a(x):
    return x

def b(x):
    return x

def c(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC (>5 warning)" \
        "thresholds: default compact warn threshold fires"
    assert_silent "$list" file-length \
        "thresholds: raising DECOMP_LOC_WARN silences the same file" \
        DECOMP_LOC_WARN=900
}

run_test test_seam_python "python: def-family seam, span/fan-in/target, test exclusion"
run_test test_seam_js "js/ts: camelCase family seam + describe() test exclusion"
run_test test_seam_rust "rust: fn-family seam + #[cfg(test)] region exclusion"
run_test test_seam_go "go: func-family seam + func Test exclusion"
run_test test_seam_shell "shell: function-family seam + comment exclusion"
run_test test_seam_markdown "markdown: heading-cluster seam + fenced-block counter"
run_test test_adjacency_required "adjacency: interleaved family rejected, contiguous family accepted"
run_test test_decline_reasons "decline: generated / cohesive / mutually-referential, each with a reason"
run_test test_ai_file_bloat "ai-file-bloat: warn/high arms, flat+nested agent globs (moved from #204 gate)"
run_test test_doc_file_bloat "doc-file-bloat: docs/*.md arms, not ai-file-bloat (moved from #204 gate)"
run_test test_god_module "god-module: concern spread required, size alone insufficient"
run_test test_skips_and_thresholds "skips: lock files; thresholds: project-overridable"

generate_report
