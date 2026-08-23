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
