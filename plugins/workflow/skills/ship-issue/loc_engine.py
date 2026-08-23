#!/usr/bin/env python3
"""Production-LOC engine — the shared measurement half of the sizing scanners.

Extracted from the entry scanner in #772, when it and its opposite number both
went over the 800 production-LOC py budget. The regions moved here VERBATIM;
nothing was rewritten in the move.

WHY THIS IS A SIBLING MODULE AND NOT A SHARED LIBRARY. The audit lens
(review-audit/skills/check-decomposition) and the review lens
(workflow/skills/ship-issue) live in plugins that install INDEPENDENTLY and
declare no dependency on each other, so an import across them is impossible and
this file exists twice by deliberate duplication. The two copies are pinned
byte-for-byte by tests/validate-shared-scanner-sync.sh, which since #772 accepts
a pair member spanning several files.

WHAT LIVES HERE: the shared `loc-tables-py`, `loc-helpers-py`, `loc-unit-py`,
`loc-measure-py` and `split-shape-py` regions (named without their sentinel
markers on purpose — the gate counts marker occurrences per file, so quoting one
in prose would read as a second copy of the region)
— the per-language tables, the unit segmenters, the comment/test/blank
exclusion rules that decide what "production LOC" means, and the decomposition
shape advice. Everything here is lens-agnostic: it answers "how big is this
file, and what are its units", never "should this be reported".

COLUMN-ZERO RULE. Every shared region holds only module-level definitions.
The sync gate strips leading whitespace before comparing, which is free in awk
and bash but would hide a real divergence in Python, where indentation is
semantic. See the header of tests/validate-shared-scanner-sync.sh.
"""

from __future__ import annotations

import os
import re
import sys

# >>> shared:loc-tables-py (sync: check-decomposition/loc_engine.py)
# Per-language unit headers. Each maps a language key to the regex that starts a
# TOP-LEVEL unit. Anchored at line start (no leading indent) so nested defs are
# not mistaken for top-level ones — that anchoring is what makes a unit span a
# genuine cut point.
UNIT_RE = {
    "py": re.compile(r"^(?:async[ \t]+)?(?:def|class)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"),
    "js": re.compile(
        r"^(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?"
        r"(?:function|class|const|let|var)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)"
    ),
    # TypeScript is its OWN key, not a js alias (#726). The js arm above matches
    # only value-level forms, so every TYPE-level declaration — interface, type,
    # enum, namespace, declare, abstract class — was invisible as a unit, and a
    # types.ts full of interfaces segmented to ~0 units and was declined as a
    # "single cohesive unit". A confident wrong answer, not a silence.
    #
    # ALTERNATION ORDER IS LOAD-BEARING, and it is a two-runtime trap. Python re
    # is leftmost-FIRST (ordered alternation); POSIX awk ERE is leftmost-LONGEST.
    # With bare `const` listed before `const enum`, Python captures the NAME
    # `enum` from `export const enum Delta` while awk captures `Delta` — a silent
    # TSV divergence surfacing only as a parity failure. Listing the two-word
    # forms FIRST makes both runtimes agree by construction rather than by
    # dialect luck. Same reason `abstract class` precedes `class`.
    "ts": re.compile(
        r"^(?:export[ \t]+)?(?:default[ \t]+)?(?:declare[ \t]+)?(?:async[ \t]+)?"
        r"(?:const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var"
        r"|interface|type|enum|namespace|module)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)"
    ),
    # Rust (#727). `impl` is deliberately ONE unit spanning header -> next
    # top-level header, NOT its methods. This decision is load-bearing and will
    # be re-asked, so the reason lives here: (a) the engine's invariant is
    # column-zero anchoring — an indented item is never a unit — and segmenting
    # inside `impl` would break that for one language only, requiring
    # depth-aware segmentation nothing else in the engine has; (b) Rust's own
    # SPLIT_SHAPE ("new subdir module; mod.rs re-exports") moves whole ITEMS,
    # and splitting one type's impl across files is a real Rust smell, so a
    # method-level seam would propose a split the language discourages. The
    # cost is accepted and visible: a 400-line impl stays one unit and can reach
    # the "single cohesive unit" decline.
    #
    # `impl Trait for Type` captures the TYPE, not the trait, so `impl Display
    # for Foo` and `impl Debug for Foo` cluster with `impl Foo` under family
    # `foo` — the family then means "this type's surface". Capturing the trait
    # scattered one type across as many families as it had impls.
    #
    # CHECKED, CORRECT AS-IS (#727): a nested `mod foo { ... }` is a unit, but
    # the items INSIDE it are indented and therefore invisible — intended, and
    # the same column-zero rule that makes impl one unit. An inline module is a
    # cut point (it moves to its own file wholesale); its contents are not.
    # The visibility class admits `:` and `_` so `pub(in crate::foo)` matches
    # (#727). With `[a-z ]+` the parenthesized group failed, the whole `pub`
    # alternative failed with it, and the item went INVISIBLE — absorbed into
    # the previous unit's span. Pre-existing, but it is this issue's own defect
    # class, and it is one character to close. `pub(crate)` / `pub(super)` were
    # always fine; only the path form broke.
    "rs": re.compile(
        r"^(?:(?:pub(?:\([a-z:_ ]+\))?|default|async|unsafe|const"
        r"|extern(?:[ \t]+\"[^\"]*\")?)[ \t]+)*"
        r"(?:macro_rules![ \t]+([A-Za-z_][A-Za-z0-9_]*)"
        # The generic list must tolerate NESTING: `<[^>]*>` stops at the first
        # `>`, so a trait bound like `impl<T: Into<String>> Foo<T>` failed the
        # whole match and the impl went INVISIBLE — reintroducing the exact
        # defect this arm exists to fix, on the commonest form of generic impl.
        # Regex cannot balance arbitrarily; this covers three levels, which is
        # past anything real (`A<B<C>>` already exhausts two).
        # The optional `Trait for` clause is LINEAR-TIME by construction, and it
        # has to be: with `.*[ \t]+for`, a run of N spaces after `impl` can be
        # split between `.*` and `[ \t]+` in O(N) ways at each of O(N) offsets,
        # and the engine tries all of them before failing. Measured on the live
        # pattern: `"impl " + " "*N + "!"` took 0.25 s at N=1000, 1.9 s at
        # N=2000, 14.5 s at N=4000 — cubic, and reached by a stray line of
        # trailing whitespace, not only by a crafted one. Two changes make it
        # flat (0.7 ms at N=16000): the clause must START on a non-space, and
        # the separator before `for` is a SINGLE [ \t] so greedy `.*` has
        # exactly one way to hand off.
        #
        # Everything between `for` and the type is consumed: `&`, a lifetime,
        # `mut`, and `dyn`. Each of these was captured as the unit NAME —
        # a keyword as the family and as a god-module "concern" in human-read
        # evidence, the same wrong-finding class RESERVED_UNIT_NAME exists to
        # prevent for Swift. `dyn` is listed beside `mut` deliberately: fixing
        # one borrow marker and leaving its sibling is exactly the
        # [[harden-one-knob-grep-every-sibling]] recurrence, and trait objects
        # are idiomatic rather than exotic.
        #
        # The path prefix is consumed so the LAST segment is captured. Taking
        # the first meant `impl A for crate::Foo` landed in family `crate`
        # while `impl B for Foo` landed in `foo` — the same type in two
        # families, which is the precise failure the trait-vs-type capture was
        # changed to fix. `(?:IDENT::)*` is a bounded prefix loop, so it stays
        # linear (a 8000-segment path matches in 0.5 ms).
        r"|impl(?:<(?:[^<>]|<(?:[^<>]|<[^<>]*>)*>)*>)?[ \t]+"
        r"(?:[^ \t].*[ \t]for[ \t]+)?(?:&[ \t]*)?"
        r"(?:'[A-Za-z_][A-Za-z0-9_]*[ \t]+)?(?:mut[ \t]+)?(?:dyn[ \t]+)?"
        r"(?:[A-Za-z_][A-Za-z0-9_]*::)*"
        r"([A-Za-z_][A-Za-z0-9_]*)"
        r"|extern[ \t]+crate[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
        r"|(?:fn|struct|enum|trait|mod|type|static|const|union)"
        r"[ \t]+([A-Za-z_][A-Za-z0-9_]*))"
    ),
    # Go (#727). A METHOD is named `Receiver_Method`, so family_prefix's
    # split-at-first-underscore clusters every method on one receiver into one
    # family — which is exactly Go's SPLIT_SHAPE ("additional files in the same
    # package"). Before this the receiver clause made the match FAIL outright
    # (`(` is not in [A-Za-z_]), so methods were not mis-named, they were
    # INVISIBLE — silently absorbed into the preceding unit's span, and a
    # method-heavy file was declined as near-cohesive on a unit count of ~2.
    #
    # The final arm names a GROUPED declaration (`var (` / `const (` / `type (`)
    # for its keyword. Same reason: grouped blocks were invisible, not "one unit
    # each". One visible unit per block is the honest count — the engine cannot
    # see into a block it does not segment.
    #
    # ACCEPTED LIMITATION (#727): the header line carries no identifier, so the
    # keyword IS the name and two adjacent blocks of the same kind (two `var (`
    # runs back to back — legal, and gofmt does not merge them) share family
    # `var` and can cluster as one seam. Accepted rather than fixed: the
    # alternatives are worse. A running index would make the name
    # position-dependent, so inserting a block upstream renames every one below
    # it and the TSV churns on an unrelated edit; naming the block for its first
    # inner identifier would require reading past the header, which this
    # line-anchored engine deliberately does not do. The failure mode is also
    # benign — a seam proposing that two adjacent declaration groups move to one
    # file is a reasonable suggestion even when they are unrelated, unlike the
    # pre-#727 behavior where the blocks were invisible and the file was
    # declined as cohesive.
    #
    # CHECKED, CORRECT AS-IS (#727): `//go:generate` and build tags do not
    # interact with GENERATED_RE. That pattern looks for @generated /
    # "Code generated by" / DO NOT EDIT in the first 20 lines; a `//go:generate`
    # directive contains none of them, and the file it generates carries the
    # real "Code generated by ... DO NOT EDIT." banner that SHOULD match. So the
    # generator's source is sized normally and its output is declined as
    # generated — which is the intended split. No fixture: a test asserting a
    # pattern does not match an unrelated string cannot fail
    # ([[surviving-mutation-may-be-a-real-no-op]]).
    "go": re.compile(
        r"^func[ \t]*\([ \t]*(?:[A-Za-z_][A-Za-z0-9_]*[ \t]+)?\*?[ \t]*"
        r"([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?[ \t]*\)[ \t]*"
        r"([A-Za-z_][A-Za-z0-9_]*)"
        r"|^(?:func|type|var|const)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
        r"|^(var|const|type)[ \t]*\("
    ),
    # Swift (#728). Modifiers are a REPEATED optional group, not a fixed
    # sequence: `public final class`, `@objc private static func` and bare
    # `struct` are all real, and Swift imposes no canonical order on them. One
    # `(?:...)*` group covering access levels, `final`/`static`/`class`
    # (type-method), `override`, `@objc`/`@MainActor`-style attributes, and
    # `indirect` matches every ordering without enumerating permutations.
    #
    # `extension` is ONE unit, matching Rust's `impl` (#727). The two are the
    # same construct — a block bundling many methods onto a type — so they must
    # be segmented the same way or the cohesive-decline path treats equivalent
    # code differently by language. If #727 re-decides `impl`, this arm changes
    # in the SAME PR; neither may move alone.
    #
    # `associatedtype` is deliberately NOT here, though the issue listed it.
    # Swift allows it only INSIDE a protocol body, so it is never a top-level
    # declaration — and an arm for it is not merely dead, it is harmful: a
    # protocol whose body is written unindented (legal Swift) would have each
    # `associatedtype` lifted into a phantom top-level unit, corrupting the very
    # count the cohesive-decline and seam paths read. Found by the mutation
    # round: deleting the arm changed nothing, and the reachability check that
    # followed showed the only inputs it fires on are invalid Swift or that
    # false positive ([[surviving-mutation-may-be-a-real-no-op]]). It stays in
    # RESERVED_UNIT_NAME, since it is still a keyword no NAME may be.
    #
    # A keyword captured as the NAME is rejected downstream by
    # RESERVED_UNIT_NAME — see the note there for why that is a filter rather
    # than a negative lookahead.
    "swift": re.compile(
        r"^(?:(?:public|private|internal|fileprivate|open|final|static|class"
        r"|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*"
        r"(?:func|class|struct|enum|protocol|extension|actor|typealias)"
        r"[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "sh": re.compile(
        r"^(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\([ \t]*\)|"
        r"^function[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
    ),
}

# Comment-line shapes per language (used for the comment/production split).
COMMENT_RE = {
    "py": re.compile(r"^[ \t]*#"),
    "sh": re.compile(r"^[ \t]*#"),
    "js": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "ts": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "rs": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "go": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    # Swift (#728). `///` and `/**` doc comments are matched by the `//` and
    # `/*` alternatives respectively — the issue notes this works "by luck" for
    # the `//` arm, so the fixture asserts the production-LOC NUMBER changes on
    # a doc-commented file rather than trusting the shape by inspection.
    "swift": re.compile(r"^[ \t]*(?://|/\*|\*)"),
}

# A unit header that marks the unit as TEST code. Replaces the per-language
# exclusion prose the three agents each carried a drifting copy of. Because unit
# SPANS are already computed, exclusion is per-unit and exact rather than the
# "to end of file" approximation the prose specified.
TEST_UNIT_RE = {
    "py": re.compile(r"^(?:async[ \t]+)?def[ \t]+test_|^class[ \t]+Test"),
    "js": re.compile(r"^[ \t]*(?:describe|it|test)[ \t]*\("),
    "ts": re.compile(r"^[ \t]*(?:describe|it|test)[ \t]*\("),
    # NB: `rs` is deliberately absent — Rust marks tests with an ATTRIBUTE on
    # the preceding line, so it lives in ATTR_TEST_RE below. It USED to sit here
    # too, read by a hardcoded `lang == "rs"` attribute branch; #728 moved it to
    # the table that describes what it actually is. Keeping a copy here would be
    # two spellings of one fact, and now that the same-line path no longer
    # excludes rs by name, a stale copy would be live code.
    #
    # The optional receiver clause keeps a TESTIFY-style method
    # (`func (s *Suite) TestFoo`) test-classified (#727). Once UNIT_RE["go"]
    # learned to segment methods, anchoring on `^func[ \t]+Test` alone stopped
    # matching them — the suite method became a production unit and its body
    # counted toward production LOC.
    # The prefix needs a BOUNDARY. Go's rule is `func TestXxx` where Xxx does
    # not begin with a lowercase letter, so a bare prefix match classifies
    # `Testify`, `Benchmarking` and `Exampler` as test code and silently drops
    # their lines from production LOC and the unit count — a wrong number
    # feeding god-module, seam and decline verdicts, with no visible error.
    # Requiring an uppercase letter, `_`, or the end of the name (`(`) after
    # the prefix matches the convention exactly. The bare-func arm had this
    # weakness before #727; extending the prefix to every receiver METHOD would
    # have widened it considerably, so both arms are anchored here.
    "go": re.compile(
        r"^func[ \t]+(?:Test|Benchmark|Fuzz|Example)(?:[A-Z_]|[ \t]*\()"
        r"|^func[ \t]*\([^)]*\)[ \t]*(?:Test|Benchmark|Fuzz|Example)(?:[A-Z_]|[ \t]*\()"
    ),
    "sh": re.compile(r"^(?:function[ \t]+)?test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)"),
    # Swift XCTest (#728) — the SAME-LINE half of Swift's two test conventions:
    # a `func test…` (any modifier prefix) or an `XCTestCase` subclass. The
    # swift-testing half is an ATTRIBUTE on the preceding line and lives in
    # ATTR_TEST_RE below; both ship because the ecosystem is mid-migration.
    #
    # The class arm keys off the `: XCTestCase` conformance rather than a name
    # convention, since Swift test classes are not required to be named Test*.
    # `[^{]*` spans any other protocols in the conformance list without running
    # into the body.
    "swift": re.compile(
        r"^(?:(?:public|private|internal|fileprivate|open|final|static|class"
        r"|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*"
        r"(?:func[ \t]+test|class[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[^{]*XCTestCase)"
    ),
}

# An ATTRIBUTE line that marks the NEXT unit as test code (#728).
#
# Generalized from a hardcoded `lang == "rs"` branch in find_units(). Rust's
# `#[test]` and swift-testing's `@Test` are the same construct — a marker on the
# line BEFORE the unit header — and hardcoding a second language would have made
# three copies of one idea across four files. Table membership now drives the
# `pending_test` path, so a third attribute-marking language is one entry.
#
# A language may appear in BOTH tables: Swift does, since XCTest is same-line
# while swift-testing is attribute-marked, which is why find_units() checks the
# two paths independently rather than as an either/or.
ATTR_TEST_RE = {
    "rs": re.compile(r"^[ \t]*#\[(?:cfg\(test\)|test)\]"),
    "swift": re.compile(r"^[ \t]*@Test\b"),
}

# Words that must never be accepted as a captured unit NAME (#728).
#
# Swift's `class` is in both the modifier group and the keyword alternation of
# UNIT_RE, so a malformed-but-parseable spelling (`open class override Foo`)
# matches `class` as the keyword and hands back `override` as the name. That is
# not a cosmetic mislabel: the name becomes the seam family and a god-module
# "concern" in evidence a human reads, so a keyword there is a WRONG FINDING.
#
# Enforced as a post-match FILTER rather than a negative lookahead, on purpose.
# POSIX awk ERE has no lookahead at all, so a lookahead would be a Python-only
# construct — the two impls would disagree on exactly these lines, and the
# divergence would surface as a parity failure rather than as the fix it looks
# like. A set membership test transcribes to awk verbatim (is_reserved_name).
#
# Only `swift` populates this today; find_units consults it for every language
# so a future one needs no new branch.
RESERVED_UNIT_NAME = {
    "swift": {
        "public",
        "private",
        "internal",
        "fileprivate",
        "open",
        "final",
        "static",
        "class",
        "override",
        "indirect",
        "func",
        "struct",
        "enum",
        "protocol",
        "extension",
        "actor",
        "typealias",
        "associatedtype",
    },
}

# Whole-file test-region markers: everything from the match to EOF is test code.
# Kept for the two cases the prose named that are genuinely region-scoped rather
# than unit-scoped.
TEST_REGION_RE = {
    "py": re.compile(r"^if[ \t]+__name__"),
    # COLUMN-ZERO only (#727), matching the pending-test attribute guard in
    # find_units. The `[ \t]*` this used to carry made a NESTED marker — a
    # `#[cfg(test)] mod tests` indented inside an outer `mod` — engage the
    # whole-file region path. That marker is not itself a unit header (units are
    # column-zero anchored), so the stop-computation below latched onto whatever
    # top-level unit happened to follow and excluded everything in between:
    # measured on a 16-line fixture, 11 lines test-excluded and a production fn
    # swallowed whole, for 4 production LOC instead of 10. A nested test module
    # is already covered per-unit by its enclosing unit's span; the region path
    # exists for the CONVENTIONAL trailing placement, which is column-zero.
    "rs": re.compile(r"^#\[cfg\(test\)\]"),
    "sh": re.compile(r"^#[ \t]*-+[ \t]*tests?[ \t]*-+"),
}

# Indent width used to convert leading whitespace into a nesting depth.
NEST_UNIT = {
    "py": 4,
    "js": 2,
    "ts": 2,
    "rs": 4,
    "go": 4,
    "sh": 4,
    "md": 2,
    "swift": 4,
}

# Blankness and indent are defined by REGEX, not str.strip()/str.lstrip(): the
# latter are unicode-aware (\x0b, \x0c, \x85, NBSP...) while the awk fallback
# under LC_ALL=C is not. Pinning both impls to [ \t] is what keeps the TSV
# byte-identical on a file with exotic whitespace.
BLANK_RE = re.compile(r"^[ \t]*$")
INDENT_RE = re.compile(r"^[ \t]*")

EXT_LANG = {
    "py": "py",
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
    "swift": "swift",
}
# <<< shared:loc-tables-py


# >>> shared:split-shape-py (sync: check-decomposition/loc_engine.py)
# LANGUAGE-SHAPED SPLIT GUIDANCE — shared by BOTH lenses (#725).
#
# Introduced on the review lens alone (#695), which was backwards: the AUDIT lens
# is the one that files a backlog somebody picks up weeks later, with none of the
# PR context that makes a bare line range interpretable. That reader needs the
# shape spelled out most, and had it least — the exact "too generic to act on, so
# nothing gets decomposed" failure #663 was filed against.
#
# Keyed by the same language keys the segmenters use (EXT_LANG's values), so
# advice and measurement can never disagree about what a file IS. That invariant
# is asserted structurally: a language with a segmenter and no shape, or a shape
# for a language nothing segments, fails tests/validate-shared-scanner-sync.sh.
# It is what makes adding a language (#726 TypeScript, #727 Rust/Go, #728 Swift)
# a one-table edit rather than two that must be remembered together.
#
# Each string names the SHAPE of the split, not a generic "consider splitting" —
# the finding has to be actionable or it is noise.
SPLIT_SHAPE = {
    "rs": "new subdir module; mod.rs re-exports the decomposed units",
    "py": "package dir with __init__.py re-exporting the public surface",
    "js": "sibling modules + a barrel index.ts",
    # DIFFERENT from js on purpose (#726). The js shape moves runtime modules;
    # an oversized TypeScript file is usually type-heavy, and its real remedy is
    # to group types by DOMAIN under types/ with a re-exporting barrel — a
    # different instruction, which is why ts needs its own key rather than
    # inheriting the js one through an alias.
    "ts": "types/ dir split by domain + a re-exporting barrel index.ts",
    "go": "additional files in the same package (no import churn)",
    # Swift's idiomatic decomposition is extensions in separate files (#728) —
    # `Foo+Networking.swift`, `Foo+Codable.swift`. DIFFERENT from every other
    # shape here because it needs no re-exporting barrel and no module: Swift
    # types are open for extension across files within a module, so a split
    # costs zero import churn at the call site. Naming the `Type+Concern.swift`
    # convention is what makes the row actionable rather than "consider
    # splitting".
    "swift": "extensions in separate files (Type+Concern.swift), same module",
    "sh": "sourced fragment + an explicit ordered list (split-suite convention)",
    "md": (
        "progressive disclosure: move detail to linked files, leave a one-line pointer"
    ),
}

# The shape for a file whose extension has NO segmenter (.rb, .java, .c, .cpp,
# .kt — all scanned, since none are skipped). Weaker than a language-shaped
# string but still a real destination, which is what keeps every actionable
# over-threshold file yielding exactly one seam row.
#
# It lives INSIDE the shared region on purpose. As a bare literal at each call
# site it was two more unpinned copies of the same fact — the precise shape of
# duplication this region exists to end.
SPLIT_SHAPE_FALLBACK = "extract a cohesive unit into a sibling module"


def split_shape(lang: str) -> str:
    """The split shape for LANG, falling back for an unsegmented language.

    Every consumer goes through this rather than indexing SPLIT_SHAPE directly,
    so the fallback cannot fork the way it already had."""
    return SPLIT_SHAPE.get(lang, SPLIT_SHAPE_FALLBACK)


# <<< shared:split-shape-py


# >>> shared:loc-helpers-py (sync: check-decomposition/loc_engine.py)
def _int_env(name: str, default: int) -> int:
    """Read an integer threshold from the environment, falling back to DEFAULT.
    Mirrors _int_env in check-ai-config/patterns.py (and the ${VAR:-N} defaults
    in every patterns.sh) so thresholds.yml values can be passed through by the
    orchestrator without either impl diverging."""
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(path: str, line_no: int, category: str, evidence: str, certainty: str) -> None:
    """Write one TSV finding row."""
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, certainty)) + "\n"
    )


def lang_of(path: str) -> str:
    """Language key from the file extension, or '' when unrecognized (metrics
    only, no segmenter)."""
    if "." not in path:
        return ""
    return EXT_LANG.get(path.rsplit(".", 1)[-1].lower(), "")


DECL_SUFFIX = ".d.ts"


def is_decl_file(path: str) -> bool:
    """A TypeScript DECLARATION file (*.d.ts), which is type-level by
    construction and has no runtime units to extract (#726).

    Deliberately NOT added to SKIP_GLOBS. A skip makes an over-budget .d.ts
    indistinguishable from an unscanned one, and this scanner's whole discipline
    is that a decline is a RESULT while silence is the bug. So the file is
    measured and sized as usual; only its SEAM is suppressed, and it declines
    with its own reason.

    Matched on the full lowercased path (a case-insensitive suffix test), so
    `Foo.D.TS` on a case-insensitive filesystem classifies the same as
    `foo.d.ts` — the same target must decide alike in every spelling."""
    return path.lower().endswith(DECL_SUFFIX)


# <<< shared:loc-helpers-py


# >>> shared:loc-unit-py (sync: check-decomposition/loc_engine.py)
def family_prefix(name: str) -> str:
    """The family key a unit name belongs to — the shared stem that makes
    `parse_entry` / `parse_header` / `parse_body` one cluster.

    snake_case splits at the first underscore; camelCase and PascalCase split at
    the first internal uppercase letter. The result is lowercased so `ParseEntry`
    and `parse_entry` land in the same family.
    """
    cut = name.find("_")
    if cut > 0:
        return name[:cut].lower()
    i = 1
    while i < len(name) and not ("A" <= name[i] <= "Z"):
        i += 1
    return name[:i].lower()


def md_slug(text: str) -> str:
    """Markdown heading text -> an identifier-shaped slug so family_prefix()
    applies unchanged ('Install on Linux' -> 'install_on_linux')."""
    out = []
    prev_us = False
    for ch in INDENT_RE.sub("", text.rstrip()).lower():
        if ("a" <= ch <= "z") or ("0" <= ch <= "9"):
            out.append(ch)
            prev_us = False
        elif not prev_us:
            out.append("_")
            prev_us = True
    return "".join(out).strip("_")


class Unit:
    """One top-level declaration: its name, family, header line and span.

    THE shared representation for both lenses (#730). The review lens
    (ship-issue/sizing.py) previously carried a parallel 4-tuple shape, which was
    the structural reason the two `find_units` bodies could never be compared
    byte-for-byte — and so the reason the Python halves drifted while their awk
    twins stayed pinned. `prefix` is what the audit lens clusters on; the review
    lens does not cluster, but carrying one field it ignores is far cheaper than
    two representations neither gate can align.
    """

    __slots__ = ("name", "prefix", "start", "end", "is_test")

    def __init__(self, name: str, start: int) -> None:
        self.name = name
        self.prefix = family_prefix(name)
        self.start = start
        self.end = start
        self.is_test = False


def find_units(lines: list[str], lang: str) -> list[Unit]:
    """Top-level units in file order, each spanning from its header line to the
    line before the next header (or EOF).

    For markdown, 'top-level' means the shallowest heading depth present, so a
    doc whose sections are all `##` segments by `##` rather than by a lone `#`
    title."""
    units: list[Unit] = []
    if lang == "md":
        heads: list[tuple[int, int, str]] = []  # (depth, line_no, text)
        fenced = False
        for idx, line in enumerate(lines, start=1):
            if line.startswith("```") or line.startswith("~~~"):
                fenced = not fenced
                continue
            if fenced:
                continue
            m = re.match(r"^(#{1,6})[ \t]+(.*)$", line)
            if m:
                heads.append((len(m.group(1)), idx, m.group(2)))
        if not heads:
            return []
        top = min(h[0] for h in heads)
        for depth, line_no, text in heads:
            if depth == top:
                units.append(Unit(md_slug(text) or "section", line_no))
    else:
        rx = UNIT_RE.get(lang)
        if rx is None:
            return []
        test_rx = TEST_UNIT_RE.get(lang)
        attr_rx = ATTR_TEST_RE.get(lang)
        pending_test = False
        for idx, line in enumerate(lines, start=1):
            m = rx.match(line)
            # An attribute line marks the NEXT unit as test code (Rust #[test],
            # swift-testing @Test). Table-driven since #728 — it was a hardcoded
            # `lang == "rs"` branch.
            #
            # ORDER MATTERS, and differs from the pre-#728 code: the unit match
            # is attempted FIRST, and the attribute only CONSUMES the line when
            # the line is not itself a unit header. Rust's `#[test]` always
            # stands alone so this is a no-op there, but swift-testing writes
            # `@Test func foo()` on ONE line — under the old continue-first
            # shape that line would set the flag and be skipped, losing the unit
            # entirely and marking the NEXT (production) unit as a test instead.
            # Only a COLUMN-ZERO attribute may set the flag (#727). Both
            # ATTR_TEST_RE patterns tolerate leading whitespace — rs because the
            # same spelling doubles as the TEST_REGION_RE marker — so an
            # INDENTED attribute inside a block (`#[test]` within
            # `mod tests { ... }`, `@Test` within an XCTestCase body) used to
            # set this flag and then mark the next TOP-LEVEL unit, a PRODUCTION
            # declaration after the block, as test code — silently dropping its
            # lines from production LOC. The guard is language-agnostic because
            # the invariant is: units are column-zero anchored, so an indented
            # attribute cannot be marking one.
            if attr_rx is not None and not line[:1].isspace() and attr_rx.search(line):
                pending_test = True
                if m is None:
                    continue
            if not m:
                continue
            # Join every group that matched. Most arms set exactly one (the
            # rest are None), so this is the old "group(1) else group(2)" for
            # them; Go's method arm sets TWO — receiver and method — and joins
            # them into `Repo_Get`, the underscore family_prefix then splits on.
            name = "_".join(g for g in m.groups() if g)
            if not name:
                continue
            # A keyword captured as a name means the line parsed a modifier as
            # the unit keyword — drop the bogus unit rather than seed a seam
            # family called "override" (#728). The line is still counted by
            # measure(); only the phantom unit disappears.
            #
            # pending_test MUST be cleared on this path. The dropped header is
            # what the attribute was marking, so leaving the flag set carries it
            # onto the NEXT genuine unit and silently marks a PRODUCTION unit as
            # test — removing its lines from production LOC and suppressing the
            # very findings this scanner exists to emit. The guard against one
            # wrong answer would otherwise manufacture another
            # ([[fix-reintroduces-its-own-failure]]).
            if name in RESERVED_UNIT_NAME.get(lang, ()):
                pending_test = False
                continue
            u = Unit(name, idx)
            if pending_test:
                u.is_test = True
                pending_test = False
            elif test_rx is not None and test_rx.search(line):
                # No longer excludes the attribute-marked languages by name
                # (#728). Rust has no TEST_UNIT_RE entry, so dropping the old
                # `lang != "rs"` guard cannot change its behavior; Swift needs
                # BOTH paths live, since XCTest is same-line while swift-testing
                # is attribute-marked.
                u.is_test = True
            units.append(u)

    for i, u in enumerate(units):
        u.end = units[i + 1].start - 1 if i + 1 < len(units) else len(lines)
    return units


# <<< shared:loc-unit-py


# >>> shared:loc-measure-py (sync: check-decomposition/loc_engine.py)
def measure(lines: list[str], lang: str, units: list[Unit]) -> dict:
    """The generic sizing layer: total / blank / comment / test-excluded /
    production LOC, max nesting depth, and top-level unit count.

    The audit lens (check-decomposition/patterns.py) and the review lens
    (ship-issue/sizing.py) carry byte-identical copies, pinned by
    tests/validate-shared-scanner-sync.sh; the same computation is transcribed
    into awk in the shared:loc-measure-awk region of both bash fallbacks."""
    total = len(lines)
    comment_rx = COMMENT_RE.get(lang)
    region_rx = TEST_REGION_RE.get(lang)

    # Lines inside a test unit, or after a whole-file test-region marker.
    test_lines = set()
    for u in units:
        if u.is_test:
            test_lines.update(range(u.start, u.end + 1))
    if region_rx is not None:
        for idx, line in enumerate(lines, start=1):
            if region_rx.search(line):
                # The region runs to the end of the unit the marker INTRODUCES,
                # not unconditionally to EOF (#727). For the conventional
                # trailing placement these are the same line — the marked unit
                # is the last one — so this is a no-op there. It differs only
                # for a marker in the MIDDLE of a file, where running to EOF
                # excluded every production unit that followed: a `#[cfg(test)]
                # mod tests` at line 5 of an 18-line file excluded 14 lines and
                # reported 3 production LOC instead of 9.
                #
                # Falling back to EOF when no unit follows keeps a marker with
                # no unit after it (a trailing `if __name__` block in py, a
                # `# --- tests ---` banner in sh) excluding its tail as before.
                stop = total
                for u in units:
                    if u.start >= idx:
                        stop = u.end
                        break
                test_lines.update(range(idx, stop + 1))
                break

    blank = 0
    comment = 0
    test_excluded = 0
    max_depth = 0
    nest_unit = NEST_UNIT.get(lang, 4)
    for idx, line in enumerate(lines, start=1):
        if idx in test_lines:
            test_excluded += 1
            continue
        if BLANK_RE.match(line):
            blank += 1
            continue
        if comment_rx is not None and comment_rx.match(line):
            comment += 1
            continue
        depth = len(INDENT_RE.match(line).group(0)) // nest_unit
        if depth > max_depth:
            max_depth = depth

    production = total - blank - comment - test_excluded
    return {
        "total": total,
        "blank": blank,
        "comment": comment,
        "test_excluded": test_excluded,
        "production": production,
        "max_depth": max_depth,
        "units": len([u for u in units if not u.is_test]),
        "comment_pct": (comment * 100 // total) if total else 0,
    }


# <<< shared:loc-measure-py
