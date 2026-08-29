# shellcheck shell=bash
# JS and TypeScript segmenters — check-decomposition detector tests (#760 split).
#
# Two languages in one file because #726 is the reason they are separate at all:
# `ts` is its OWN language key rather than a js alias, so the JS fixtures had to
# move off `.ts` when TS grew type-level units, a `.d.ts` decline and its own
# split shape. Keeping both arms adjacent is what makes that boundary legible.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

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

    # #851 INVERTS what this case used to assert. It previously required a
    # describe()-only test file to be SILENT on file-length, on the reasoning
    # that its units were test-excluded — but that silence had two causes
    # stacked, and both were defects: the file scored ~0 production LOC because
    # the exclusion was unconditional, and TEST_UNIT_RE["js"] could not fire
    # anyway because a call expression was never a unit header. A 3,000-line
    # app.test.js is a 3,000-line file that should be split by area, so the
    # correct assertion is that it REPORTS.
    f="$d/app.test.js"
    command cat >"$f" <<'EOF'
describe('alpha', () => {
  it('b', () => { expect(1).toBe(1); });
  it('c', () => { expect(2).toBe(2); });
  it('d', () => { expect(3).toBe(3); });
});
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "5 production LOC" \
        "js: a describe()-only test file counts its tests as production (#851)" DECOMP_LOC_WARN=1
    assert_fires "$list" file-length "1 top-level units" \
        "js: a top-level describe() is a unit (#851)" DECOMP_LOC_WARN=1

    # The SAME body at a NON-test path must still exclude. This is the pairing
    # that keeps the fix from over-applying: `is_test` classification is
    # unchanged and only the SUBTRACTION is conditional, so a regression that
    # dropped the path predicate entirely would turn this case red while the
    # one above stayed green.
    f="$d/helpers.js"
    command cat >"$f" <<'EOF'
describe('alpha', () => {
  it('b', () => { expect(1).toBe(1); });
  it('c', () => { expect(2).toBe(2); });
  it('d', () => { expect(3).toBe(3); });
});
EOF
    list="$(list_of "$f")"
    assert_silent "$list" file-length \
        "js: the same describe() body at a NON-test path is still excluded (#851)" DECOMP_LOC_WARN=1
}

# ============================================================================
# #851 — separate-file tests measure as production, and describe() is reachable
# ============================================================================
# The issue's own reproduction, verbatim. Before the fix these two files
# DISAGREED with each other on the same construct: python identified its tests
# and then wrongly subtracted them (0 production LOC), while typescript never
# identified them at all (test_excluded 0, zero units). Neither answer is the
# one the sizing lens wants, and AC4 is that the two languages now agree.
test_separate_file_tests_are_production() {
    local d f list

    d="$(fresh_dir)"
    f="$d/example.test.ts"
    command cat >"$f" <<'EOF'
import { describe, it } from "node:test";
import assert from "node:assert";

describe("scoring", () => {
  it("cuts by title only", () => { assert.equal(1, 1); });
  it("keeps when in doubt", () => { assert.equal(2, 2); });
});
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "6 production LOC" \
        "ts: the issue's example.test.ts reports production, not ~0 (#851)" DECOMP_LOC_WARN=1
    # The unit is named for the LEADING IDENTIFIER OF THE TITLE, not the
    # keyword: describe("scoring", ...) -> `scoring`. That name becomes the
    # seam family and the proposed destination filename, so keying on the
    # keyword would put every block in one family and make a large test file
    # emit a single cluster spanning itself.
    assert_fires "$list" file-length "1 top-level units" \
        "ts: a top-level describe() is a unit, so TEST_UNIT_RE is reachable (#851)" DECOMP_LOC_WARN=1

    # AC4: python's half of the same reproduction. It used to measure 0.
    f="$d/test_example.py"
    command cat >"$f" <<'EOF'
def test_cuts_by_title_only():
    assert 1 == 1


def test_keeps_when_in_doubt():
    assert 2 == 2
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "4 production LOC" \
        "py: the issue's test_example.py reports production, not 0 (#851)" DECOMP_LOC_WARN=1
    assert_fires "$list" file-length "2 top-level units" \
        "py: a test file's test defs count toward the unit total (#851)" DECOMP_LOC_WARN=1
}

# The SAME-FILE conventions are untouched — the half of #851 that must NOT
# change. Both fixtures sit at NON-test paths, where the region marker keys off
# CONTENT rather than path, so the exclusion still applies exactly as before.
# Without these, the fix could over-apply to every language and no assertion
# would fail ([[fixture-must-express-the-divergent-case]]).
test_same_file_regions_still_exclude() {
    local d f list

    d="$(fresh_dir)"
    f="$d/lib.rs"
    command cat >"$f" <<'EOF'
pub fn alpha(x: u32) -> u32 {
    x + 1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(true); }
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "3 production LOC" \
        "rs: a #[cfg(test)] region at a non-test path still excludes (#851)" DECOMP_LOC_WARN=1

    f="$d/app.py"
    command cat >"$f" <<'EOF'
def alpha(x):
    return x


def test_beta():
    assert 1


if __name__ == "__main__":
    alpha(1)
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "2 production LOC" \
        "py: an if __name__ region at a non-test path still excludes (#851)" DECOMP_LOC_WARN=1
}

# is_test_file's DIRECTORY arms, and the SEAM inside a test file (#851).
#
# Both were found by the mutation round rather than written from the AC list:
# removing the `tests/**` directory arms, and removing the `test_file` gate from
# cluster_units / the patterns.sh cluster loop, each left every other test green.
# The gaps were real — every earlier fixture identified its test file by
# BASENAME, and none asserted anything but SIZE, so the seam half of the fix was
# unexercised in both runtimes.
#
# The seam is what makes the fix actionable rather than merely honest: without
# it an oversized `foo.test.ts` reports its true production LOC and then offers
# nothing to do about it. Naming the family `render` also pins the naming
# decision — a keyword-named unit would put all four suites in one family called
# `describe` and the family assertion below would read `describe_*`.
test_test_file_directory_arm_and_seam() {
    local d f list

    # A file whose ONLY test signal is its DIRECTORY: the basename `helpers.ts`
    # matches no name arm, so this case fails the moment the directory arms go.
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    f="$d/tests/helpers.ts"
    command cat >"$f" <<'EOF'
describe("renderHeader", () => {
  it("a", () => { expect(1).toBe(1); });
  it("b", () => { expect(2).toBe(2); });
});

describe("renderBody", () => {
  it("c", () => { expect(3).toBe(3); });
  it("d", () => { expect(4).toBe(4); });
});

describe("renderFooter", () => {
  it("e", () => { expect(5).toBe(5); });
  it("f", () => { expect(6).toBe(6); });
});
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "12 production LOC" \
        "ts: a tests/ DIRECTORY segment makes the file a test file (#851)" DECOMP_LOC_WARN=1
    # The seam: three adjacent render* suites cluster into one family. Under a
    # cluster loop that skips test units this row does not exist at all.
    assert_fires "$list" decomposition-seam "render_* family (3 units," \
        "ts: a test file's suites cluster into a seam (#851)" DECOMP_LOC_WARN=1

    # Counter: the SAME body one directory up is not a test file, so its suites
    # are excluded and there is nothing to size or cluster. This is what keeps
    # the assertions above from passing for a reason unrelated to the path.
    f="$d/helpers.ts"
    command cp "$d/tests/helpers.ts" "$f"
    list="$(list_of "$f")"
    assert_silent "$list" file-length \
        "ts: the same body outside tests/ is still excluded (#851)" DECOMP_LOC_WARN=1
}

# is_test_file's LEADING-segment arm, which only a RELATIVE path can reach.
#
# Found by the mutation round, and it took a narrowing pass to read correctly:
# removing both directory arms killed, removing the mid-path `/tests/` arm alone
# killed, but removing the leading-segment arm alone SURVIVED. Not a redundant
# arm — every other fixture in this tree writes into an absolute `mktemp` dir, so
# a path that BEGINS with `tests/` is never constructed and that arm is
# unreachable from the suite. Production callers pass repo-relative paths, which
# is precisely the form only this arm matches, so the untested arm was the one
# real deployments depend on most.
#
# The case therefore runs both scanners with cwd INSIDE the sandbox and lists a
# relative path. The `contest.ts` counter rides along because the same
# relative-path shape is where segment anchoring is easiest to get wrong: a
# substring test would match `contest` and silently suppress a real production
# file ([[path-guard-must-expand-before-scoping]]).
test_test_file_relative_leading_segment() {
    local d list

    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command cat >"$d/tests/suite.ts" <<'EOF'
describe("alpha", () => {
  it("a", () => { expect(1).toBe(1); });
  it("b", () => { expect(2).toBe(2); });
});
EOF
    # A relative path in the list, resolved against the sandbox cwd below.
    command printf '%s
' 'tests/suite.ts' >"$d/list-rel"

    local out
    out="$(cd "$d" && /usr/bin/env DECOMP_LOC_WARN=1 DECOMP_LOC_HIGH=400 \
        python3 "$PY" list-rel 2>/dev/null | command awk -F '\t' '$3 == "file-length"')"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$out" "4 production LOC" \
            "ts: a LEADING tests/ segment on a relative path is a test file (python, #851)"
    fi
    out="$(cd "$d" && /usr/bin/env PATTERNS_FORCE_BASH=1 DECOMP_LOC_WARN=1 DECOMP_LOC_HIGH=400 \
        "$REAL_BASH" "$SH" list-rel 2>/dev/null | command awk -F '\t' '$3 == "file-length"')"
    assert_contains "$out" "4 production LOC" \
        "ts: a LEADING tests/ segment on a relative path is a test file (bash, #851)"

    # Segment anchoring, same relative shape: `contest.ts` contains "test" but is
    # NOT a test file, so its suites stay excluded and it stays silent.
    command cp "$d/tests/suite.ts" "$d/contest.ts"
    command printf '%s
' 'contest.ts' >"$d/list-contest"
    out="$(cd "$d" && /usr/bin/env PATTERNS_FORCE_BASH=1 DECOMP_LOC_WARN=1 DECOMP_LOC_HIGH=400 \
        "$REAL_BASH" "$SH" list-contest 2>/dev/null | command awk -F '\t' '$3 == "file-length"')"
    assert_output_empty "$out" \
        "ts: contest.ts is NOT a test file — segment anchoring, not substring (bash, #851)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(cd "$d" && /usr/bin/env DECOMP_LOC_WARN=1 DECOMP_LOC_HIGH=400 \
            python3 "$PY" list-contest 2>/dev/null | command awk -F '\t' '$3 == "file-length"')"
        assert_output_empty "$out" \
            "ts: contest.ts is NOT a test file — segment anchoring, not substring (python, #851)"
    fi
}

# One fixture per is_test_file ARM that the coarse mutations could not prove.
#
# The mutation round removed TEST_DIR_SEGMENTS and TEST_BASENAME_GLOBS as whole
# loops, so both died on the `tests/` + `test_*.py` + `.test.ts` fixtures alone —
# leaving `spec`, `__tests__`, `__pycache__`, `*_spec.*` and `*.spec.*` asserted
# by nobody. A coarse mutation cannot tell a covered arm from an uncovered
# sibling ([[asymmetric-mutation-reads-as-untested]]), and dropping any one of
# these from either runtime's copy would silently score those files near zero
# again — the exact #851 defect, reached through a door no test was watching.
#
# Asserted through the MEASUREMENT path (production LOC), not by calling the
# predicate, so the python table and its awk mirror are both exercised.
test_test_file_remaining_arms() {
    local d f list arm

    # Directory-segment arms beyond `tests/`.
    for arm in spec __tests__ __pycache__; do
        d="$(fresh_dir)"
        command mkdir -p "$d/$arm"
        f="$d/$arm/helpers.ts"
        command cat >"$f" <<'EOF'
describe("alpha", () => {
  it("a", () => { expect(1).toBe(1); });
  it("b", () => { expect(2).toBe(2); });
});
EOF
        list="$(list_of "$f")"
        assert_fires "$list" file-length "4 production LOC" \
            "ts: a $arm/ directory segment makes the file a test file (#851)" DECOMP_LOC_WARN=1
    done

    # Basename glob arms beyond `test_*.*` / `*.test.*` / `*_test.*`.
    d="$(fresh_dir)"
    for f in api.spec.ts api_spec.ts; do
        command cat >"$d/$f" <<'EOF'
describe("alpha", () => {
  it("a", () => { expect(1).toBe(1); });
  it("b", () => { expect(2).toBe(2); });
});
EOF
        list="$(list_of "$d/$f")"
        assert_fires "$list" file-length "4 production LOC" \
            "ts: $f matches a spec basename glob (#851)" DECOMP_LOC_WARN=1
    done
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
