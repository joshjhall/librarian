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
#   fanin-cap — the `count <= seam_max_fanin` guard dropped, BOTH -> 1 case red
#   fanin-callers — the `and callers` guard dropped, BOTH impls  -> 1 case red
#   rs-pending — the standalone-#[test] attribute carry, BOTH impls-> 1 case red
#   split-shape— every SPLIT_SHAPE value emptied, BOTH impls        -> 1 case red
#   shape-gate — `seams > 0` relaxed to `over || seams > 0`, BOTH   -> 1 case red
#   bundle-pre — the bundle early return/exit dropped, BOTH impls   -> 2 cases red
# All went red under mutation and green on revert.
#
# The bundle-precedence case (#725) is the one that had to be REBUILT after its
# mutation: the obvious fixture — an index of unrelated `## Golem`/`## Review`
# topics — produces no markdown seam at all, so it emitted no generic shape row
# with the suppression AND none without it. Green either way, proving nothing.
# Its headings are now a same-family cluster, which is what makes the negative
# assertion arm ([[gate-and-evidence-converge-tautology]]).
#
# The last six were added by the pre-PR review. Cycle 1: the fourth decline
# reason and the two whole-file test-REGION markers were exercised only by the
# Codecov corpus, which asserts nothing — so a broken region regex would have
# shown green coverage and a green suite simultaneously. Note `decline-order`:
# it pins the BRANCH ORDER, not just the predicate, since a reason chosen by the
# wrong arm is still a wrong finding. Cycle 3: the third fan-in evidence shape
# (a bare `fan-in N`, reached both over the cap and when no reference resolves
# to a top-level unit) had no assertion at all — its case carries a control that
# raises the cap so the same fixture DOES name its callers, so the bare-count
# assertion cannot pass merely because caller resolution broke.
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
# Fixtures are `.js`/`.test.js`, NOT `.ts` (#726). They were `.ts` while ts was
# an ALIAS of js, which made them exercise the js arm through the alias. Now
# that ts is its own key with its own noun and shape, a `.ts` fixture here would
# silently be testing the TypeScript segmenter under a test named for js — and
# the js arm would go uncovered. TypeScript has its own case, test_seam_typescript.
test_seam_js() {
    local d f list
    d="$(fresh_dir)"
    f="$d/app.js"
    command cat >"$f" <<'EOF'
export function mainEntry(x) {
  return renderHeader(x);
}

export function renderHeader(x) {
  const a = 1;
  return x + a;
}

export function renderBody(x) {
  const b = 2;
  return x + b;
}

export function renderFooter(x) {
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
    f="$d/app.test.js"
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
# TypeScript segmenter (#726)
# ============================================================================
# TS is its OWN language key, not a js alias. Before #726 `EXT_LANG` mapped
# ts/tsx to js, whose unit regex matches only value-level forms — so every
# type-level declaration was invisible and a types.ts full of interfaces
# segmented to ~0 units and was DECLINED as a "single cohesive unit". That is a
# confident wrong answer, strictly worse than silence, which is why the seam
# assertion below is the regression this test exists to hold.
test_seam_typescript() {
    local d f list out

    # --- AC2: the issue's own six-declaration file segments to 6, not 1 ------
    # Each line is a DIFFERENT type-level form, so this doubles as per-form
    # coverage: reverting any one alternative drops the count below 6 (the
    # mutation round in the PR body records each form going red individually).
    d="$(fresh_dir)"
    f="$d/types.ts"
    command cat >"$f" <<'EOF'
export interface Alpha { a: string }
export interface Beta { b: number }
export type Gamma = Alpha | Beta
export enum Delta { X, Y }
export namespace Eps { export const z = 1 }
export const realFn = () => 1
EOF
    list="$(list_of "$f")"

    # The unit COUNT is asserted, not merely "a row fired" — the count is the
    # quantity the decline path reads, and it is what distinguishes a real fix
    # from an anchor that never matched ([[anchored-regex-tautological-test]]).
    assert_fires "$list" file-length "6 top-level units" \
        "ts: all six type-level declaration forms segment as units (#726 AC2)"

    # --- more forms: const enum / declare / abstract class ------------------
    # `const enum` and `abstract class` are the two-word forms, and they are the
    # PARITY trap: python re is leftmost-first while POSIX awk ERE is
    # leftmost-longest, so with bare `const` ordered first python captures the
    # name `enum` and awk captures `Flag`. assert_fires runs BOTH impls, so a
    # regression in that ordering fails here rather than in the parity gate.
    d="$(fresh_dir)"
    f="$d/forms.ts"
    command cat >"$f" <<'EOF'
export const enum Flag { None, Rush }
export declare function helperOne(x: string): string
export abstract class BaseThing { abstract run(): void }
export module LegacyNs { }
export declare const declaredConst: string
export const enum Mode { On, Off }
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "6 top-level units" \
        "ts: const enum / declare fn / abstract class / module all segment (#726)"

    # The COUNT above cannot see a `const enum` regression, and the mutation
    # round proved it: dropping the two-word `const[ \t]+enum` alternative still
    # matches the line via bare `const`, so the count stays 6 while the captured
    # NAME silently becomes `enum` instead of `Mode`. That is the leftmost-first
    # vs leftmost-longest hazard the ts arm is ordered to avoid, and the name is
    # what reaches the seam family and the target path — so it is asserted
    # directly. Same for `abstract class`, whose bare-`class` fallback would
    # capture `class`.
    #
    # A NAME-family seam is the observable that carries the captured name, so
    # the fixture below gives each two-word form a clusterable family.
    d="$(fresh_dir)"
    f="$d/named.ts"
    command cat >"$f" <<'EOF'
export const enum ModeAlpha {
  On,
  Off,
}
export const enum ModeBeta {
  On,
  Off,
}
export const enum ModeGamma {
  On,
  Off,
}
export const enum ModeDelta {
  On,
  Off,
}
export abstract class ShapeAlpha {
  abstract run(): void;
}
export abstract class ShapeBeta {
  abstract run(): void;
}
export abstract class ShapeGamma {
  abstract run(): void;
}
export abstract class ShapeDelta {
  abstract run(): void;
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declaration mode_* family" \
        "ts: const enum captures the TYPE name, not the keyword \`enum\` (#726)"
    assert_fires "$list" decomposition-seam "declaration shape_* family" \
        "ts: abstract class captures the TYPE name, not the keyword \`class\` (#726)"

    # --- AC5: a type-heavy file over threshold SEAMS, not declines ----------
    # The regression this issue exists to fix. Two name families of five, each
    # contiguous, so both cluster and clear the seam minimums.
    d="$(fresh_dir)"
    f="$d/model.ts"
    command cat >"$f" <<'EOF'
export interface UserProfile { id: string }
export interface UserSettings { theme: string }
export interface UserSession { token: string }
export interface UserAudit { at: number }
export interface UserPrefs { locale: string }
export interface UserBadge { kind: string }
export interface UserQuota { max: number }
export interface UserRole { name: string }
export type OrderStatus = "new" | "paid"
export type OrderLine = { sku: string }
export type OrderTotal = { cents: number }
export type OrderRefund = { cents: number }
export type OrderNote = { text: string }
export enum OrderKind { Retail, Wholesale }
export type OrderDraft = { id: string }
export type OrderPaid = { id: string }
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declaration user_* family" \
        "ts: a type-heavy file yields a real seam (#726 AC5)"
    assert_fires "$list" decomposition-seam "declaration order_* family" \
        "ts: the second type family seams too (#726 AC5)"

    # The decline it used to emit must be GONE — asserting the seam alone would
    # still pass if both rows fired.
    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "single cohesive unit" \
        "ts: a type-heavy file is no longer declined as cohesive (bash, #726 AC5)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "single cohesive unit" \
            "ts: a type-heavy file is no longer declined as cohesive (python, #726 AC5)"
    fi

    # --- AC4: the shape is the TS one, not js's ----------------------------
    assert_fires "$list" decomposition-seam "split shape for ts: types/ dir split by domain" \
        "ts: split shape is domain-split types/ + barrel (#726 AC4)"

    # --- AC3: a .d.ts declines as a declaration file, with no seam ---------
    # Sized and examined, NOT skipped: a skip would be indistinguishable from
    # "not scanned", which is the silent shape this whole issue removes.
    d="$(fresh_dir)"
    f="$d/api.d.ts"
    command cat >"$f" <<'EOF'
export declare interface ApiUser { id: string }
export declare interface ApiOrder { id: string }
export declare interface ApiCart { id: string }
export declare interface ApiItem { id: string }
export declare interface ApiPlan { id: string }
export declare interface ApiSeat { id: string }
export declare function apiFetch(u: string): Promise<string>
export declare function apiPost(u: string): Promise<string>
export declare function apiPut(u: string): Promise<string>
export declare function apiDelete(u: string): Promise<string>
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: type declaration file — no runtime units to extract" \
        "ts: a .d.ts declines with the declaration-file reason (#726 AC3)"
    assert_fires "$list" file-length "10 production LOC" \
        "ts: a .d.ts is still SIZED, not skipped (#726 AC3)"

    # No seam and no shape row beside the decline — the api_* family would
    # otherwise cluster, so this genuinely exercises the suppression.
    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "api_* family" \
        "ts: a .d.ts emits no seam despite a clusterable family (bash, #726 AC3)"
    assert_not_contains "$out" "split shape for" \
        "ts: a .d.ts emits no shape row beside its decline (bash, #726 AC3)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "api_* family" \
            "ts: a .d.ts emits no seam despite a clusterable family (python, #726 AC3)"
        assert_not_contains "$out" "split shape for" \
            "ts: a .d.ts emits no shape row beside its decline (python, #726 AC3)"
    fi

    # A .d.ts ALSO banner-marked generated keeps the declaration-file reason —
    # the more specific fact wins, which is why that arm is ordered first.
    d="$(fresh_dir)"
    f="$d/gen.d.ts"
    command cat >"$f" <<'EOF'
// Code generated by tool. DO NOT EDIT.
export declare interface GenOne { id: string }
export declare interface GenTwo { id: string }
export declare interface GenThree { id: string }
export declare interface GenFour { id: string }
export declare interface GenFive { id: string }
export declare interface GenSix { id: string }
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined: type declaration file" \
        "ts: declaration-file reason outranks the generated banner (#726)"

    # --- Counter: .js is NOT swept into the ts arm -------------------------
    # The alias removal must not leak the other way. A plain .js interface line
    # is not a unit there, and js keeps the barrel shape.
    d="$(fresh_dir)"
    f="$d/legacy.js"
    command cat >"$f" <<'EOF'
export function renderHeader(x) { return x; }
export function renderBody(x) { return x; }
export function renderFooter(x) { return x; }
export function renderAside(x) { return x; }
export function renderMain(x) { return x; }
export function renderNav(x) { return x; }
export function renderFoot(x) { return x; }
export function renderSide(x) { return x; }
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "function render_* family" \
        "js: .js still segments as js with the js noun (#726 counter)"
    assert_fires "$list" decomposition-seam "split shape for js: sibling modules" \
        "js: .js keeps the js barrel shape, not the ts one (#726 counter)"
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

    # A STANDALONE top-level `#[test]` attribute (no `mod tests` wrapper) is a
    # THIRD, distinct mechanism: the attribute line sets a pending flag that
    # marks the NEXT unit as test code. The fixture above never reaches it —
    # its #[test] sits indented inside a #[cfg(test)] block, which the
    # whole-file region marker already excluded to EOF. Valid Rust, own branch,
    # so it needs its own fixture.
    f="$d/standalone.rs"
    command cat >"$f" <<'EOF'
pub fn main_entry(s: &str) -> String {
    parse_a(s)
}

fn parse_a(s: &str) -> String {
    s.to_string()
}

#[test]
fn helper_one() {
    assert!(true);
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "3 test-excluded" \
        "rust: a standalone top-level #[test] attribute excludes the next unit"
    # Control: the two production fns are still counted, so the assertion above
    # cannot pass by the file being excluded wholesale.
    assert_fires "$list" file-length "2 top-level units" \
        "rust: the standalone-#[test] file still counts its production units"
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
# Split SHAPE (#725) — the audit lens names a DESTINATION, not just a span
# ============================================================================
# Before #725 the shape table lived on the review lens alone, which was
# backwards: this lens files a backlog somebody picks up weeks later, with none
# of the PR context that makes `seam 412-680` interpretable. The unified table
# is shared via `# >>> shared:split-shape-{py,awk}` and pinned against drift by
# tests/validate-shared-scanner-sync.sh; what THIS gate proves is that the audit
# lens actually CONSULTS it — a synced-but-unread table would pass that gate and
# still emit nothing here.
#
# Each arm asserts its OWN string, which pins distinctness as well as presence:
# a copy-paste leaving two languages sharing one shape would satisfy a per-arm
# "contains something" check and nothing else would notice.
test_split_shape_per_language() {
    local d f list entry ext lang expect i

    d="$(fresh_dir)"

    # ext:lang:expected-substring — one entry per shape arm. md is covered
    # separately below (its fixture needs headings, not units).
    for entry in \
        "py:py:__init__.py" \
        "js:js:sibling modules" \
        "ts:ts:types/ dir split by domain" \
        "rs:rs:mod.rs" \
        "go:go:same package" \
        "sh:sh:sourced fragment"; do
        ext="${entry%%:*}"
        lang="${entry#*:}"
        lang="${lang%%:*}"
        expect="${entry##*:}"

        f="$d/shape.$ext"
        : >"$f"
        i=0
        # A same-family cluster large enough to clear the seam floor — the shape
        # row is gated on a REAL seam, so a fixture that produced none would
        # prove nothing about the table.
        while [ "$i" -lt 6 ]; do
            case "$ext" in
                py) command printf 'def parse_%d(s):\n    return s\n\n' "$i" >>"$f" ;;
                js) command printf 'export function parseUnit%d(s) {\n  return s;\n}\n\n' "$i" >>"$f" ;;
                # A TYPE-level family, so the ts arm is reached through the
                # forms only its own segmenter matches (#726) rather than
                # through a function the js arm would have caught anyway.
                ts) command printf 'export interface ParseUnit%d { s: string }\n\n\n' "$i" >>"$f" ;;
                rs) command printf 'fn parse_%d() {\n    let _ = %d;\n}\n\n' "$i" "$i" >>"$f" ;;
                go) command printf 'func parse_%d() int {\n    return %d\n}\n\n' "$i" "$i" >>"$f" ;;
                sh) command printf 'parse_%d() {\n    echo %d\n}\n\n' "$i" "$i" >>"$f" ;;
            esac
            i=$((i + 1))
        done
        list="$(list_of "$f")"

        assert_fires "$list" decomposition-seam "split shape for ${lang}:" \
            "shape: the ${lang} arm names its language"
        assert_fires "$list" decomposition-seam "$expect" \
            "shape: the ${lang} arm gives ${lang}-shaped guidance"
    done

    # --- markdown: progressive disclosure, not a module move ----------------
    # The one arm structurally unlike its siblings, and the surface this repo
    # churns fastest (#589).
    f="$d/guide.md"
    command cat >"$f" <<'EOF'
## Install on Linux

Steps.

## Install on Mac

Steps.

## Install on Windows

Steps.
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "split shape for md: progressive disclosure" \
        "shape: markdown guidance is progressive disclosure"
    assert_fires "$list" decomposition-seam "one-line pointer" \
        "shape: markdown guidance says to leave a pointer behind"
    # Distinctness, asserted negatively: markdown must not receive a sibling
    # language's advice. A table whose arms all collapsed to one string would
    # pass every positive assertion above.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam)" "barrel index.ts" \
        "shape: markdown does not get the JS shape (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam)" "barrel index.ts" \
            "shape: markdown does not get the JS shape (python)"
    fi
}

# The shape row accompanies a SEAM, never a decline.
#
# The `over && seams == 0` arm emits a reasoned decline — "no low-coupling seam
# found", "single cohesive unit". A shape row beside it would contradict its own
# neighbour: build a package dir out of a file the scanner just said has nothing
# to cut. That is why the emit is gated on `seams > 0` rather than on `over`,
# and this is the fixture that pins the gate — with `over` it would still be
# green everywhere except here.
test_split_shape_not_emitted_beside_a_decline() {
    local d f list out

    d="$(fresh_dir)"
    # One long cohesive unit: over threshold, no seam, so the decline fires.
    f="$d/cohesive.py"
    command printf '%s\n' "def only(x):" >"$f"
    i=0
    while [ "$i" -lt 30 ]; do
        command printf '    x = x + %d\n' "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "    return x" >>"$f"
    list="$(list_of "$f")"

    # Control: the decline IS firing, so the negative below cannot pass merely
    # because the file was never classified as over-threshold.
    assert_fires "$list" decomposition-seam "declined: single cohesive unit" \
        "shape: the cohesive-decline control fires"

    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "split shape for" \
        "shape: a declined file gets no shape row (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "split shape for" \
            "shape: a declined file gets no shape row (python)"
    fi
}

# BUNDLE PRECEDENCE (#725 AC4, preserving #700).
#
# A memory index/concept must keep its bundle-specific guidance and must NOT
# start receiving generic `md` shape advice as a side effect of the
# unification. An index splits by TOPIC CLUSTER and a concept by extracting its
# second lesson plus an index line — neither is "move detail to linked files".
#
# It holds by CONSTRUCTION today (the bundle branch returns before the language
# path), which is exactly why it is fixtured: an invariant nothing asserts is
# one refactor away from not holding, and its loss would be silent — a plausible
# extra row, not an error.
#
# THE HEADINGS ARE A SAME-FAMILY CLUSTER (`## Install on {Linux,Mac,Windows}`)
# AND THAT IS LOad-BEARING. A negative assertion only means something if the
# thing it forbids would otherwise appear. The obvious fixture — an index of
# unrelated `## Golem` / `## Review` / `## Release` topics — produces no
# markdown seam at all, so it emits no shape row with the suppression AND none
# without it: green either way, proving nothing
# ([[gate-and-evidence-converge-tautology]]). Verified by deleting the bundle
# early-return in both impls: with these headings the generic
# `split shape for md` row appears and this case goes red; with unrelated
# headings it stayed green.
#
# BOTH halves are asserted, per the AC: index and concept.
test_split_shape_suppressed_for_memory_bundles() {
    local d f list out

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index half ---------------------------------------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "## Install on Linux" "" "Steps for linux." "" \
        "## Install on Mac" "" "Steps for mac." "" \
        "## Install on Windows" "" "Steps for windows." >"$f"
    list="$(list_of "$f")"

    # Control: bundle guidance is present, so the negative cannot pass because
    # the file fell under budget and emitted nothing at all.
    assert_fires "$list" decomposition-seam "index split: 3 topic clusters" \
        "bundle: the index keeps its own split guidance" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # The generic markdown SEAM is suppressed too (#700) — the row the shape
    # would have accompanied. Asserting both is what distinguishes "the shape is
    # suppressed" from "the seam that carries it never fired".
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "seam 1-" "bundle: an index gets no line-range seam (bash)"

    out="$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)"
    assert_not_contains "$out" "split shape for md" \
        "bundle: an index gets no generic md shape advice (bash)"
    assert_not_contains "$out" "progressive disclosure" \
        "bundle: an index is not told to use progressive disclosure (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)"
        assert_not_contains "$out" "split shape for md" \
            "bundle: an index gets no generic md shape advice (python)"
        assert_not_contains "$out" "progressive disclosure" \
            "bundle: an index is not told to use progressive disclosure (python)"
    fi

    # --- concept half -------------------------------------------------------
    # Same-family headings for the same reason as the index above: `## Extract
    # the {First,Second} Lesson` clusters, so a lost suppression WOULD produce a
    # markdown seam plus its shape row. `extract_*` also keeps the second
    # section's slug distinct, which the concept-split assertion reads.
    f="$d/.claude/memory/two-lessons.md"
    command printf '%s\n' "## Extract One Lesson" "" "text here for one." "" \
        "## Extract Two Lesson" "" "text here for two." "" \
        "## Extract Three Lesson" "" "text here for three." >"$f"
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "concept split: extract extract_two_lesson" \
        "bundle: the concept keeps its own split guidance" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
        "seam 1-" "bundle: a concept gets no line-range seam (bash)"

    out="$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)"
    assert_not_contains "$out" "split shape for md" \
        "bundle: a concept gets no generic md shape advice (bash)"
    assert_not_contains "$out" "progressive disclosure" \
        "bundle: a concept is not told to use progressive disclosure (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)"
        assert_not_contains "$out" "split shape for md" \
            "bundle: a concept gets no generic md shape advice (python)"
        assert_not_contains "$out" "progressive disclosure" \
            "bundle: a concept is not told to use progressive disclosure (python)"
    fi
}

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
# companion_md (#589) — skills/<name>/<other>.md, the reference prose a SKILL.md
# loads on demand. Before this arm a companion matched NO bloat glob and fell
# through to the production-LOC CODE thresholds — sized by a rule written for
# source, on the largest prose files in the repo. Same defect #700 fixed for the
# memory bundle.
#
# THE ORDERING CASE IS THE POINT. `*/skills/*/*.md` also matches a SKILL.md, so
# the narrower SKILL.md arm must come FIRST in both impls (`case` takes the first
# match; the Python arms are sequential ifs). A fixture must therefore straddle
# the two budgets — over SKILL_HIGH but under COMPANION_HIGH — because that band
# is the ONLY place a hoisted companion arm is observable. Sized under both, or
# over both, the test passes with and without the bug.
# ============================================================================
test_companion_md_bloat() {
    local d f list
    d="$(fresh_dir)"

    command mkdir -p "$d/skills/orch"
    f="$d/skills/orch/mode-protocol.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"

    # High arm.
    assert_fires "$list" ai-file-bloat "skill companion exceeds high threshold" \
        "companion_md: companion over high threshold flagged" \
        COMPANION_WARN=2 COMPANION_HIGH=3

    # Warning arm.
    assert_fires "$list" ai-file-bloat "skill companion exceeds warning threshold" \
        "companion_md: companion over warning threshold flagged" \
        COMPANION_WARN=3 COMPANION_HIGH=99

    # Counter: under both -> silent (the arm must not over-fire).
    assert_silent "$list" ai-file-bloat \
        "companion_md: companion under thresholds is silent" \
        COMPANION_WARN=50 COMPANION_HIGH=99

    # ORDERING: a SKILL.md in the band between the two budgets must be judged as
    # a SKILL definition, never as a companion. With SKILL_HIGH=3 and
    # COMPANION_HIGH=99, a 5-line SKILL.md is over the skill budget and under the
    # companion one — so a hoisted companion arm would report nothing here.
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "companion_md: SKILL.md keeps its own tighter budget (arm ordering)" \
        SKILL_WARN=2 SKILL_HIGH=3 COMPANION_WARN=50 COMPANION_HIGH=99
    # And it must not ALSO be reported as a companion — one file, one verdict.
    assert_silent "$list" doc-file-bloat \
        "companion_md: a SKILL.md emits no doc-file-bloat row" \
        SKILL_WARN=2 SKILL_HIGH=3 COMPANION_WARN=50 COMPANION_HIGH=99
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
# Size-verdict exclusivity (#701) — a classified file gets its per-type budget
# and NOT the generic production-LOC file-length verdict.
#
# Before #701 both size checks ran unconditionally, so classified markdown got
# TWO rows for one problem (two categories, two different numbers), and a docs
# page comfortably UNDER its own doc_md budget was still flagged against the
# code thresholds. BASE_ENV pins DECOMP_LOC_WARN=5, so every fixture here is
# far over the code threshold — that is what makes each "file-length silent"
# assertion sharp rather than vacuous: pre-fix it fired on all of them.
# ============================================================================
test_size_verdict_exclusivity() {
    local d f list i

    # --- Classified AND over its own budget: exactly ONE row ----------------
    # Pre-fix this file emitted ai-file-bloat AND file-length together.
    d="$(fresh_dir)"
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "---" "description: d" "---" "## Workflow" "a" "b" "c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "exclusivity: a classified file still gets its per-type verdict" \
        SKILL_WARN=2 SKILL_HIGH=3
    assert_silent "$list" file-length \
        "exclusivity: a classified file does NOT also get the code file-length verdict (#701)" \
        SKILL_WARN=2 SKILL_HIGH=3

    # --- Classified and UNDER its own budget: NO size row at all ------------
    # The disposition-recall-tally-613.md shape from the issue: a docs page
    # under doc_md warn that the code lens flagged anyway. Both categories must
    # be silent — the type budget is the only verdict, and it says "fine".
    command mkdir -p "$d/docs"
    f="$d/docs/tally.md"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        command printf 'Row %s of a running tally that is supposed to grow.\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_silent "$list" doc-file-bloat \
        "exclusivity: a docs page under its own budget gets no bloat row" \
        DOC_WARN=500 DOC_HIGH=800
    assert_silent "$list" file-length \
        "exclusivity: a docs page under its own budget is NOT flagged by the code lens (#701)" \
        DOC_WARN=500 DOC_HIGH=800

    # --- Unclassified files are UNAFFECTED ----------------------------------
    # The fix must narrow only the classified path. Three languages, because a
    # regression that keyed off "is markdown" rather than "is classified" would
    # still pass on a single .py fixture.
    f="$d/mid.py"
    command cat >"$f" <<'EOF'
def alpha(x):
    return x

def beta(x):
    return x

def gamma(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: an unclassified .py still gets file-length"

    f="$d/tool.sh"
    command cat >"$f" <<'EOF'
run_alpha() {
    do_work
}

run_beta() {
    do_work
}

run_gamma() {
    do_work
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: an unclassified .sh still gets file-length"

    # Unclassified MARKDOWN specifically: a README is not matched by any
    # bloat_spec() arm, so the code lens remains its ONLY size lens. That is
    # the #700 case and is deliberately out of scope here — pinning it stops a
    # future widening of bloat_spec() from silently changing this file's
    # behavior without a test going red.
    f="$d/README.md"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8; do
        command printf '## Section %s\n\nProse.\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: unclassified markdown (README) keeps the code lens (#700 scope)"

    # --- Segmentation still runs on classified markdown ---------------------
    # This is about the size VERDICT, not the analysis: an oversized SKILL.md
    # must still yield a decomposition seam naming the sections to extract.
    f="$d/skills/big/SKILL.md"
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
    assert_fires "$list" decomposition-seam "section install_* family (3 units," \
        "exclusivity: seam analysis still runs on classified markdown" \
        SKILL_WARN=2 SKILL_HIGH=3

    # --- The size finding still pairs with a seam-or-decline ----------------
    # `over` is now set by the BLOAT verdict, so the reasoned-decline emit must
    # still fire for a classified file with no cuttable seam. If `over` had
    # been left keyed to file-length, this row would vanish silently and
    # audit-decomposition.md's pairing contract would lose its coverage for the
    # bloat categories.
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "## Only Section" "" "One cohesive block." "" "More prose." >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined:" \
        "exclusivity: a classified over-budget file still records a decline (over-flag pairing)" \
        SKILL_WARN=2 SKILL_HIGH=3
    # Counter: UNDER budget -> not over -> no decline row either. Pins that the
    # decline follows the verdict rather than firing on every classified file.
    assert_silent "$list" decomposition-seam \
        "exclusivity: an under-budget classified file records no decline" \
        SKILL_WARN=500 SKILL_HIGH=800
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

# ============================================================================
# Memory-bundle classification (#700).
#
# Before #700, `.claude/memory/**` matched no bloat_spec() arm and fell through
# to the CODE thresholds (DECOMP_LOC_WARN/HIGH, production LOC) — prose sized by
# a rule written for source, silently. These cases pin the bundle as a
# first-class file type with index/concept budgets.
#
# BASE_ENV pins DECOMP_LOC_WARN=5, so every fixture here is far over the code
# threshold. That is what makes the "file-length silent" assertion sharp rather
# than vacuous: pre-fix it fired on all of them.
# ============================================================================
test_memory_bundle_bloat() {
    local d f list

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index arm ---------------------------------------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Golem" "- a" "" "## Review" "- b" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: index over high threshold flagged" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" ai-file-bloat "memory index exceeds warning threshold" \
        "memory: index over warning threshold flagged" \
        MEMORY_INDEX_WARN=3 MEMORY_INDEX_HIGH=99
    assert_silent "$list" ai-file-bloat \
        "memory: index under thresholds is silent" \
        MEMORY_INDEX_WARN=50 MEMORY_INDEX_HIGH=99

    # THE REGRESSION GUARD: a bundle file is NEVER judged by the code
    # thresholds. BASE_ENV's DECOMP_LOC_WARN=5 is far below this file's size,
    # so pre-fix this assertion failed.
    assert_silent "$list" file-length \
        "memory: index is never reported against DECOMP_LOC_* code thresholds" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_silent "$list" file-length \
        "memory: index under its own budget is still not code-sized" \
        MEMORY_INDEX_WARN=50 MEMORY_INDEX_HIGH=99

    # --- concept arm (a DIFFERENT budget family from index) ----------------
    f="$d/.claude/memory/some-lesson.md"
    command printf '%s\n' "# Lesson" "" "## First" "text" "" "## Second" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory concept exceeds high threshold" \
        "memory: concept over high threshold flagged" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_silent "$list" file-length \
        "memory: concept is never reported against DECOMP_LOC_* code thresholds" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # The discriminator is real: index env vars do NOT move a concept file.
    assert_silent "$list" ai-file-bloat \
        "memory: concept ignores the index budget (the two arms are distinct)" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3 \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99
    # ...and symmetrically, concept env vars do not move an index file.
    assert_silent "$(list_of "$d/.claude/memory/MEMORY.md")" ai-file-bloat \
        "memory: index ignores the concept budget" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3 \
        MEMORY_INDEX_WARN=99 MEMORY_INDEX_HIGH=99

    # index-*.md is an index, not a concept (the sub-index naming this repo uses).
    f="$d/.claude/memory/index-golem.md"
    command printf '%s\n' "# Golem" "" "## A" "x" "" "## B" "y" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: index-*.md classifies as index, not concept" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3 \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99

    # --- non-markdown inside a bundle is CODE, not bundle prose ------------
    # A .py in the bundle keeps the code thresholds — bundle classification is
    # about prose, and treating a script as prose would be the mirror defect.
    f="$d/.claude/memory/helper.py"
    command printf '%s\n' "def a(x):" "    return x" "" "def b(x):" "    return x" \
        "" "def c(x):" "    return x" >"$f"
    assert_fires "$(list_of "$f")" file-length "production LOC" \
        "memory: a .py inside the bundle is still code-sized"

    # --- configurable root -------------------------------------------------
    # A bundle somewhere else entirely classifies when the root points at it.
    d="$(fresh_dir)"
    command mkdir -p "$d/knowledge"
    f="$d/knowledge/MEMORY.md"
    command printf '%s\n' "# Index" "" "## A" "- a" "" "## B" "- b" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: bundle root is configurable, not hardcoded" \
        MEMORY_BUNDLE_ROOT=knowledge MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # Every spelling of the same root must decide alike — an unnormalized root
    # misses the glob, falls back to the code thresholds, and still exits 0.
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: trailing-slash root normalizes to the same decision" \
        MEMORY_BUNDLE_ROOT=knowledge/ MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: leading-./ root normalizes to the same decision" \
        MEMORY_BUNDLE_ROOT=./knowledge MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # A root carrying GLOB METACHARACTERS must be matched LITERALLY, and both
    # impls must agree. Python matched it with fnmatch (which reads `[x]` as a
    # character class and misses) while bash `case` matches a QUOTED expansion
    # literally (and hit) — so the same file classified in one impl and not the
    # other, silently, at exit 0. assert_fires runs BOTH impls, so it is the
    # parity assertion as well as the behavior one.
    d="$(fresh_dir)"
    command mkdir -p "$d/weird[x]root"
    f="$d/weird[x]root/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: a root with glob metacharacters matches literally in BOTH impls" \
        "MEMORY_BUNDLE_ROOT=weird[x]root" MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # --- no bundle configured: no classification, NO error ------------------
    # An empty root disables memory classification entirely. The file then
    # takes the ordinary code path (it is no longer a bundle file at all), and
    # the scan still succeeds.
    #
    # THE FIXTURE MUST SIT AT THE DEFAULT ROOT. An earlier draft reused the
    # `knowledge/` fixture above, which is only ever a bundle file when
    # MEMORY_BUNDLE_ROOT=knowledge is passed explicitly — so with an empty root
    # it was never going to be classified whether the disable path worked or
    # not, and the assertion passed either way. Proven: making an empty root
    # fall back to the default instead of disabling left the suite GREEN.
    # A file UNDER `.claude/memory` is what makes the silence mean something:
    # it WOULD be classified with the default root in effect, so silence here
    # can only come from the disable actually firing.
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    list="$(list_of "$f")"
    # Control: with the DEFAULT root this same file IS classified. Without this
    # the silence below could come from the fixture rather than from the disable.
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: the empty-root fixture IS classified under the default root" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_silent "$list" ai-file-bloat \
        "memory: empty root disables memory classification" \
        MEMORY_BUNDLE_ROOT= MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    local rc=0
    /usr/bin/env MEMORY_BUNDLE_ROOT= PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" "$list" \
        >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "memory: no bundle configured exits 0, not an error"

    # A bundle root NESTED below the tree root — the second match arm
    # (`*/root/*` in bash, the `"/" + root + "/" in path` disjunct in python).
    # Every root fixture above puts the root at the START of the path, so that
    # arm had no coverage and a "simplification" to prefix-only would not fail.
    d="$(fresh_dir)"
    command mkdir -p "$d/proj/sub/.claude/memory"
    f="$d/proj/sub/.claude/memory/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: a bundle root nested below the tree root still classifies" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # --- healthy bundle produces ZERO findings ------------------------------
    # Realistic sizes under the shipped defaults; nothing at all is emitted.
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Topic" "- [a](a.md) — hook" >"$f"
    command printf '%s\n' "# Lesson" "" "The lesson." >"$d/.claude/memory/a.md"
    list="$(list_of "$f" "$d/.claude/memory/a.md")"
    assert_output_empty "$(/usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" "$list" 2>/dev/null)" \
        "memory: healthy bundle produces zero findings (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(python3 "$PY" "$list" 2>/dev/null)" \
            "memory: healthy bundle produces zero findings (python)"
    fi
}

# ============================================================================
# Memory-bundle split guidance (#700) — a bundle splits by TOPIC CLUSTER (index)
# or by extracting a second lesson WITH its index line (concept). The generic
# markdown heading-cluster seam is suppressed: a `seam <n>-<n>:` row would be
# actively wrong guidance for a bundle.
# ============================================================================
test_memory_split_guidance() {
    local d f list

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index: topic clusters, NOT line ranges -----------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Golem" "- a" "" "## Review" "- b" \
        "" "## Release" "- c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "index split: 3 topic clusters" \
        "memory: index guidance names topic clusters" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" decomposition-seam "golem, review, release" \
        "memory: index guidance names the actual cluster topics" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # The AC, asserted negatively: no line-range seam for a bundle file. The
    # markdown segmenter WOULD produce one here without the suppression.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "seam " "memory: index guidance carries no line-range seam (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
            "seam " "memory: index guidance carries no line-range seam (python)"
    fi

    # Topic clusters come from the `##` sections, NOT the shallowest-heading
    # top-level units — which for a `# Title` + `## topics` file is the lone
    # title. Keying off those would make every index decline. This assertion is
    # what pins that: it requires 3 clusters from a file with ONE `#`.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "no topic clusters" "memory: a titled index still finds its ## clusters (bash)"

    # --- concept: extraction ALWAYS carries the index-line requirement -------
    f="$d/.claude/memory/two-lessons.md"
    command printf '%s\n' "# Lessons" "" "## First Thing" "text" "" \
        "## Second Thing" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "concept split: extract second_thing" \
        "memory: concept guidance extracts the second lesson" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # THE ANTI-ORPHAN AC: a split that would leave the extracted half unindexed
    # must be flagged, never proposed. The requirement is unconditional.
    assert_fires "$list" decomposition-seam "AND add its index line" \
        "memory: concept split requires the extracted half get an index line" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_fires "$list" decomposition-seam "orphan" \
        "memory: concept guidance names the orphan failure it prevents" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # The extraction target sits under the bundle root, not a hardcoded one.
    # For a FLAT bundle the source file's own directory IS the root, so #713's
    # fix leaves the relative shape of this case unmoved — it is now derived
    # rather than assumed. `$d`-anchored like every other target assertion here
    # (`> $d/mod/parse.py`): a target is spelled the way its source was, which
    # is what makes it a path the reader can actually act on.
    assert_fires "$list" decomposition-seam "to $d/.claude/memory/second_thing.md" \
        "memory: extraction target sits beside a flat concept, in the bundle root" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3

    # --- guidance is gated on being OVER budget -----------------------------
    # A bundle file inside its budget gets no guidance at all — guidance is a
    # consequence of the size verdict, not an unconditional annotation.
    assert_silent "$list" decomposition-seam \
        "memory: an in-budget concept gets no split guidance" \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99

    # --- NESTED concept: the target is a SIBLING, not a root refugee (#713) --
    # bundle_kind() supports a concept nested below the root (its `*/root/*`
    # arm), and the guidance used to anchor the target at the bundle root
    # unconditionally — silently dropping the `topics/` segment, which followed
    # literally moves the extracted lesson OUT of its subdirectory. Both impls
    # shared that defect, so the same-output parity gate could never catch it;
    # assert_fires runs both, making this the parity assertion as well.
    f="$d/.claude/memory/topics/two-lessons.md"
    command mkdir -p "$d/.claude/memory/topics"
    command printf '%s\n' "# Lessons" "" "## First Thing" "text" "" \
        "## Second Thing" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "to $d/.claude/memory/topics/second_thing.md" \
        "memory: a nested concept extracts beside itself, not to the bundle root" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # Asserted negatively too: the root-anchored target must be GONE, not merely
    # accompanied. The positive assertion above is a SUBSTRING check, and
    # `.../topics/second_thing.md` does not contain `.../memory/second_thing.md`
    # — but an emit that named both targets would still satisfy it. This pins
    # that the wrong one is absent rather than merely outvoted.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
        "to $d/.claude/memory/second_thing.md" \
        "memory: nested concept does not propose the root-anchored target (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
            "to $d/.claude/memory/second_thing.md" \
            "memory: nested concept does not propose the root-anchored target (python)"
    fi

    # --- unsplittable bundle files decline with a reason --------------------
    # One lesson, one section: nothing to extract. A decline is a RESULT, not
    # silence (the same contract the code path's reasoned decline carries).
    f="$d/.claude/memory/single.md"
    command printf '%s\n' "# One" "" "text" "more" >"$f"
    assert_fires "$(list_of "$f")" decomposition-seam "declined: single lesson" \
        "memory: a single-lesson concept declines with a reason" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3

    # The INDEX decline arm — the fourth of the bundle branch's four outcomes,
    # and the one an index-kind fixture is needed for: an over-budget index with
    # fewer than 2 topic clusters has nothing to split along. Without this the
    # arm had no assertion in either the gate or the coverage corpus, which is
    # the "rule with zero failing tests" shape the mutation round exists to find.
    f="$d/.claude/memory/index-flat.md"
    command printf '%s\n' "# Flat" "" "one" "two" "three" >"$f"
    assert_fires "$(list_of "$f")" decomposition-seam "declined: index has no topic clusters" \
        "memory: an index with no topic clusters declines with a reason" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
}

# ============================================================================
# Reachability (#578) — "explicit path still honors gitignore".
#
# rumdl/ruff re-apply .gitignore when handed a DIRECTORY, which is why
# tests/lint-markdown.sh exists. This scanner is structurally different: it
# reads an explicit newline file LIST and never walks the tree itself, so a
# gitignored bundle is reachable. #700 asked for that to be PROVEN by fixture
# rather than assumed — a consuming repo may well gitignore part of its bundle
# (this one gitignores .claude/memory/tmp/).
#
# The residual risk is therefore in LIST CONSTRUCTION (checker.md's manifest),
# not in the scanner — this case pins the scanner half so a future change that
# made it walk the tree would fail here.
# ============================================================================
test_memory_gitignored_reachability() {
    local d f list
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # A real git repo whose .gitignore excludes the whole bundle.
    command git -C "$d" init -q 2>/dev/null || skip_test "git unavailable"
    command printf '%s\n' ".claude/memory/" >"$d/.gitignore"

    f="$d/.claude/memory/ignored-lesson.md"
    command printf '%s\n' "# Lesson" "" "## A" "x" "" "## B" "y" >"$f"

    # Precondition — the fixture is genuinely gitignored. Without this the case
    # would pass vacuously on a tree where the ignore never applied.
    local rc=0
    command git -C "$d" check-ignore -q ".claude/memory/ignored-lesson.md" || rc=$?
    assert_exit 0 "$rc" "reachability: the fixture bundle really is gitignored"

    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory concept exceeds high threshold" \
        "reachability: a gitignored bundle file is still classified (#578)" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
}

run_test test_seam_python "python: def-family seam, span/fan-in/target, test exclusion"
run_test test_seam_js "js: camelCase family seam + describe() test exclusion"
run_test test_seam_typescript "ts: type-level units, seam-not-decline, .d.ts decline, ts shape (#726)"
run_test test_seam_rust "rust: fn-family seam + #[cfg(test)] region exclusion"
run_test test_seam_go "go: func-family seam + func Test exclusion"
run_test test_seam_shell "shell: function-family seam + comment exclusion"
run_test test_seam_markdown "markdown: heading-cluster seam + fenced-block counter"
run_test test_split_shape_per_language "shape: every language arm is reachable and language-specific (#725)"
run_test test_split_shape_not_emitted_beside_a_decline "shape: a declined file gets a reason, not a destination (#725)"
run_test test_split_shape_suppressed_for_memory_bundles "shape: bundle guidance pre-empts generic md advice (#725/#700)"
run_test test_fanin_over_cap "fan-in: bare-count shape (over cap, and module-level references)"
run_test test_adjacency_required "adjacency: interleaved family rejected, contiguous family accepted"
run_test test_decline_reasons "decline: generated / cohesive / mutually-referential, each with a reason"
run_test test_ai_file_bloat "ai-file-bloat: warn/high arms, flat+nested agent globs (moved from #204 gate)"
run_test test_companion_md_bloat "companion_md: skills/*/other.md arms + SKILL.md ordering (#589)"
run_test test_doc_file_bloat "doc-file-bloat: docs/*.md arms, not ai-file-bloat (moved from #204 gate)"
run_test test_size_verdict_exclusivity "exclusivity: one size verdict per file — type budget XOR file-length (#701)"
run_test test_god_module "god-module: concern spread required, size alone insufficient"
run_test test_skips_and_thresholds "skips: lock files; thresholds: project-overridable"
run_test test_memory_bundle_bloat "memory: bundle index/concept budgets, configurable root, never code-sized (#700)"
run_test test_memory_split_guidance "memory: topic-cluster index split, anti-orphan concept split (#700)"
run_test test_memory_gitignored_reachability "memory: a gitignored bundle file is still classified (#578/#700)"

generate_report
