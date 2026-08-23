# shellcheck shell=bash
# Swift segmenter (#728) — check-decomposition detector tests (#760 split).
#
# Swift's unit forms, its `///` comment model, both test conventions
# (XCTest and Swift Testing), and the seam-not-decline arm.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Swift segmenter (#728)
# ============================================================================
# Before this, lang_of() returned "" for a .swift path, which returns EARLY —
# before the seam work — so a Swift file got a production-LOC count with no
# comment exclusion (every // and /// counted as production), no test exclusion,
# and permanent silence on decomposition. Not a false-positive storm: a WRONG
# NUMBER feeding a real threshold verdict, plus a confident cohesive decline.
test_seam_swift() {
    local d f list out

    # --- every unit form segments -----------------------------------------
    # One line per form, so reverting any single alternative drops the count
    # below 9 and this assertion goes red on its own (the mutation round in the
    # PR body records each form individually).
    d="$(fresh_dir)"
    f="$d/forms.swift"
    command cat >"$f" <<'EOF'
public struct FormStruct {
    let a: Int
}
public final class FormClass {
    let b: Int
}
@objc private static func formFunc() {}
extension FormStruct: Codable {
    func encode() {}
}
public protocol FormProtocol {}
public actor FormActor {}
indirect enum FormEnum { case leaf }
typealias FormAlias = () -> Void
public class func formTypeMethod() {}
internal struct FormInternal {
    let c: Int
}
fileprivate enum FormFilePrivate { case one }
open class FormOpen {
    let d: Int
}
override public func formOverride() {}
protocol FormAssoc {
associatedtype FormElement
}
EOF
    list="$(list_of "$f")"

    # The COUNT is the assertion, not merely "a row fired": the count is the
    # quantity the cohesive-decline path reads, so it distinguishes a real fix
    # from an anchor that never matched ([[anchored-regex-tautological-test]]).
    #
    # EVERY unit keyword and EVERY modifier appears exactly once, so dropping
    # any single alternative from either group changes this number and the
    # assertion goes red on its own. The mutation round is what put the last
    # four modifiers here: `internal`, `fileprivate`, `open` and `override`
    # SURVIVED a round against the first draft of this fixture, which used only
    # public/private/final/static/indirect — the rule with zero failures is the
    # one the round exists to find ([[mutate-every-rule-not-every-test]]).
    #
    # The FormAssoc protocol body is written UNINDENTED on purpose — legal
    # Swift, and the shape that proves `associatedtype` is not a unit keyword.
    # The issue's spec listed it, but Swift permits it only inside a protocol
    # body, so an arm for it is never a top-level declaration and, on exactly
    # this fixture, would lift FormElement into a phantom 15th unit and corrupt
    # the count the cohesive-decline and seam paths read. A mutation round found
    # the arm dead, and the reachability check that followed found it harmful
    # ([[surviving-mutation-may-be-a-real-no-op]]).
    assert_fires "$list" file-length "14 top-level units" \
        "swift: every unit form and modifier segments as a top-level unit (#728 AC1)"
    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "form_element" \
        "swift: associatedtype in an unindented protocol body is not a unit (bash, #728)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "form_element" \
            "swift: associatedtype in an unindented protocol body is not a unit (python, #728)"
    fi

    # --- AC2: /// doc comments are excluded from production LOC ------------
    # The issue notes the /// arm is caught by // "only by luck", so the
    # assertion is on the production NUMBER, which is what a threshold verdict
    # actually reads — not on the presence of a comment-shaped row.
    #
    # Two files identical but for the doc block: same units, different
    # production LOC. A comment model that counted /// as production would make
    # both numbers equal, and a single-file fixture could not tell the
    # difference ([[config-prose-satisfies-its-own-assertion]]).
    d="$(fresh_dir)"
    f="$d/nodoc.swift"
    command cat >"$f" <<'EOF'
public struct DocAlpha {
    let a: Int
}
public struct DocBeta {
    let b: Int
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "6 production LOC" \
        "swift: baseline production LOC without doc comments (#728 AC2)"

    f="$d/withdoc.swift"
    command cat >"$f" <<'EOF'
/// Doc line one.
/// Doc line two.
/** Block doc. */
public struct DocAlpha {
    let a: Int
}
/// Doc for beta.
public struct DocBeta {
    let b: Int
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "6 production LOC" \
        "swift: /// and /** doc comments are NOT production LOC (#728 AC2)"
    assert_fires "$list" file-length "4 comment" \
        "swift: the four doc lines are counted as comments (#728 AC2)"

    # --- AC3: BOTH test conventions excluded ------------------------------
    # XCTest (same-line `func test…` / `: XCTestCase`) and swift-testing (an
    # @Test ATTRIBUTE on the preceding line) both ship — the ecosystem is
    # mid-migration, so excluding only one silently inflates half the world's
    # Swift files.
    #
    # productionKeeper sits immediately after an attribute-marked unit on
    # purpose: it is the line that goes wrong if the attribute path consumes its
    # own header, and it is asserted through the production COUNT below.
    # The file must clear the 300-LOC warning threshold or NO file-length row is
    # emitted at all and every assertion below would read an empty string —
    # passing or failing for a reason unrelated to test exclusion. So the
    # production half is padded to 60 real units; the four test units carry the
    # behavior under test.
    d="$(fresh_dir)"
    f="$d/tests.swift"
    {
        command printf '@Test\nfunc swiftTestingTwoLine() {\n    work()\n}\n'
        command printf '@Test func swiftTestingOneLine() {\n    work()\n}\n'
        command printf 'func productionKeeper() {\n    work()\n}\n'
        command printf 'func testXCTestTopLevel() {\n    work()\n}\n'
        command printf 'final class ProfileTests: XCTestCase {\n    func testInner() {}\n}\n'
        i=0
        while [ "$i" -lt 59 ]; do
            command printf 'public struct PadThing%s {\n    let a: Int\n    let b: Int\n    let c: Int\n    let d: Int\n}\n' "$i"
            i=$((i + 1))
        done
    } >"$f"
    list="$(list_of "$f")"

    # 370 total - 12 test-excluded = 358 production (no blanks, no comments).
    assert_fires "$list" file-length "358 production LOC" \
        "swift: both test conventions excluded, production unit kept (#728 AC3)"
    # 12 lines across the four test units: the two @Test units (4 + 3), the
    # top-level XCTest func (3), and the XCTestCase class (3).
    assert_fires "$list" file-length "12 test-excluded" \
        "swift: XCTest and swift-testing units both excluded (#728 AC3)"

    # The one-line `@Test func` is the case a continue-first attribute path gets
    # WRONG in a way the line totals above could hide: it would swallow that
    # unit and mark the NEXT one — productionKeeper — as a test instead. The
    # production UNIT count is what pins which units survived: 1 keeper + 59
    # padding = 60. Under the broken shape productionKeeper is excluded and this
    # reads 59.
    assert_fires "$list" file-length "60 top-level units" \
        "swift: one-line @Test does not swallow the following production unit (#728 AC3)"

    # --- AC6: an over-threshold Swift file SEAMS with a Swift-shaped remedy -
    # The regression this issue exists to fix: units == [] used to trip the
    # cohesive-decline path, so a long Swift file was declined with
    # `deterministic` certainty — a confident wrong answer.
    d="$(fresh_dir)"
    f="$d/big.swift"
    {
        command printf '%s\n' "/// Module doc."
        i=0
        while [ "$i" -lt 30 ]; do
            command printf 'public struct UserThing%s {\n    let id: String\n    func describe() -> String {\n        return "u"\n    }\n}\n' "$i"
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt 30 ]; do
            command printf 'public struct OrderThing%s {\n    let sku: String\n    func total() -> Int {\n        return 0\n    }\n}\n' "$i"
            i=$((i + 1))
        done
    } >"$f"
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "declaration user_* family" \
        "swift: the user_* family seams (#728 AC6)"
    assert_fires "$list" decomposition-seam "declaration order_* family" \
        "swift: the second family seams too (#728 AC6)"
    assert_fires "$list" decomposition-seam \
        "split shape for swift: extensions in separate files (Type+Concern.swift)" \
        "swift: split shape is the Swift one, not a generic fallback (#728 AC5)"

    # The decline it used to emit must be GONE. Asserting the seam alone would
    # still pass if BOTH rows fired.
    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "single cohesive unit" \
        "swift: a long Swift file is no longer declined as cohesive (bash, #728)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "single cohesive unit" \
            "swift: a long Swift file is no longer declined as cohesive (python, #728)"
    fi

    # --- the reserved-name filter -----------------------------------------
    # `class` is in BOTH the modifier group and the keyword alternation, so
    # `open class override Bogus` parses `class` as the keyword and yields the
    # KEYWORD `override` as the unit name. That name is not a cosmetic mislabel:
    # it becomes a seam family and a god-module "concern" in evidence a human
    # reads, so it is a wrong FINDING.
    #
    # Asserted as an ABSENCE of the keyword-named family plus the surviving unit
    # count — a count alone cannot see which name was captured, the trap #726's
    # `const enum` case recorded.
    d="$(fresh_dir)"
    f="$d/bogus.swift"
    {
        i=0
        while [ "$i" -lt 8 ]; do
            command printf 'open class override BogusThing%s {\n    let x: Int\n}\n' "$i"
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt 8 ]; do
            command printf 'public struct RealThing%s {\n    let y: Int\n}\n' "$i"
            i=$((i + 1))
        done
    } >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" file-length "8 top-level units" \
        "swift: a keyword-named phantom unit is dropped, real ones kept (#728)"
    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "override_* family" \
        "swift: no seam family is named for a captured keyword (bash, #728)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "override_* family" \
            "swift: no seam family is named for a captured keyword (python, #728)"
    fi

    # --- the pending_test leak across a dropped reserved-name unit ---------
    # The two features above INTERACT, and the interaction was a live bug: an
    # attribute (@Test) marks the NEXT unit, but if that next header captures a
    # RESERVED name the unit is dropped — and the flag used to survive the drop
    # and land on the following GENUINE unit, marking a production unit as test.
    # Its lines then left production LOC, suppressing the very findings this
    # scanner exists to emit: the guard against one wrong answer manufactured
    # another ([[fix-reintroduces-its-own-failure]]).
    #
    # Neither the reserved-name fixture nor the test-convention fixture above
    # can see this — each exercises one feature alone. It needs the two ADJACENT,
    # which is what this fixture is for.
    d="$(fresh_dir)"
    f="$d/leak.swift"
    {
        command printf '@Test\nopen class override BogusOne {\n    let x: Int\n}\n'
        i=0
        while [ "$i" -lt 60 ]; do
            command printf 'public struct RealThing%s {\n    let a: Int\n    let b: Int\n    let c: Int\n    let d: Int\n}\n' "$i"
            i=$((i + 1))
        done
    } >"$f"
    list="$(list_of "$f")"

    # All 364 lines are production: the dropped header claims no span, so its
    # lines fall to the file rather than being excluded. With the leak, the
    # flag lands on RealThing0 and its 6 lines leave production — 358, and 59
    # units instead of 60. Both numbers were confirmed to move by reverting the
    # fix and re-running, so neither assertion is tautological.
    assert_fires "$list" file-length "364 production LOC" \
        "swift: pending_test does not leak past a dropped reserved-name unit (#728)"
    assert_fires "$list" file-length "60 top-level units" \
        "swift: the unit after a dropped reserved-name header stays production (#728)"

    # --- Counter: a short cohesive Swift file emits nothing ----------------
    d="$(fresh_dir)"
    f="$d/small.swift"
    command printf '%s\n' "public struct Only {" "    let a: Int" "}" >"$f"
    list="$(list_of "$f")"
    assert_silent "$list" decomposition-seam "swift: a short single-unit file emits no seam"
    assert_silent "$list" file-length "swift: a short file is not over threshold"
}
