#!/usr/bin/env bash
# ship-issue non-lossy split verification gate (issue #695, AC8).
#
# A reviewer that suggests a decomposition is cheap to ignore; a reviewer that
# suggests one AND can PROVE the split lost nothing is cheap to accept. That
# proof is split-verify.{py,sh}, and this gate pins its four checks:
#
#   1. LOC CONSERVATION       — content moved, not dropped
#   2. UNIT PRESERVATION      — every top-level unit survives
#   3. FAN-IN RESOLUTION      — no call site left dangling
#   4. MARKDOWN REACHABILITY  — a moved heading is still linked
#
# EVERY CHECK IS PAIRED WITH ITS COUNTER-FIXTURE. A verifier that always reports
# "verified" and one that always reports "lost" are equally useless, and a suite
# that only exercises one direction cannot tell them apart. So each property has
# a lossy fixture that MUST fire and a sound fixture that MUST stay silent, over
# the same shape of split — the fixture pair differs only in the defect.
#
# The markdown pair is the sharpest instance and the one the issue calls out as
# easiest to get wrong: the SAME content is moved out in both cases, and the only
# difference is whether a one-line pointer was left behind. A check that merely
# noticed "content moved" would pass both and prove nothing.
#
# Every case runs against BOTH the Python primary and the bash fallback
# (SPLIT_VERIFY_FORCE_BASH=1), with parity asserted per case.
#
# MUTATION-VERIFIED. Each check was proven tested by breaking it and confirming
# this gate goes red, then reverting:
#   unit preservation  — the `lost` set forced empty        -> unit case red
#   loc conservation   — tolerance raised past the drop     -> loc case red
#   md reachability    — link scan forced to "found"        -> md case red
#   md reachability    — moved-heading set forced empty     -> md case red
#
# Pure bash + coreutils; no node/jq. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

VERIFY_SH="$REPO_ROOT/plugins/workflow/skills/ship-issue/split-verify.sh"
VERIFY_PY="$REPO_ROOT/plugins/workflow/skills/ship-issue/split-verify.py"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "ship-issue non-lossy split verification (#695 AC8)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

# run_verify ORIGINAL POST_ORIGINAL [RESULTS...] — run BOTH impls, leaving output
# in the GLOBAL `VERIFY_OUT` and parity in `VERIFY_PARITY`.
#
# A GLOBAL, not an echo: command substitution would run this in a subshell, where
# a failed assertion flips a TEST_STATUS that dies with the child and never
# reaches the parent's counters — an inert check is indistinguishable from a
# passing one. (This is not hypothetical; the sibling sizing suite shipped that
# bug and the mutation round caught it.)
run_verify() {
    local py_out
    VERIFY_PARITY="ok"
    VERIFY_OUT="$(SPLIT_VERIFY_FORCE_BASH=1 command bash "$VERIFY_SH" "$@" 2>&1 || true)"
    if [ "$HAVE_PY" = "1" ]; then
        py_out="$(command python3 "$VERIFY_PY" "$@" 2>&1 || true)"
        [ "$VERIFY_OUT" = "$py_out" ] || VERIFY_PARITY="drift"
        VERIFY_PY_OUT="$py_out"
    fi
}

assert_parity() {
    [ "$HAVE_PY" = "1" ] || return 0
    if [ "$VERIFY_PARITY" != "ok" ]; then
        _fail "bash and python impls disagree (parity drift)" \
            "The TSV contract is the language boundary — a port is a drop-in only while the output matches." \
            "bash: $VERIFY_OUT" "python: $VERIFY_PY_OUT"
    fi
}

# --- fixtures ----------------------------------------------------------------
# One original, split three ways: soundly, with a unit dropped, and with a large
# chunk dropped. Built once so every case below splits the SAME original — the
# fixtures differ only in the defect under test.
setup_code_fixtures() {
    ORIG="$WORKDIR/orig.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$ORIG"

    # Sound: the parse_* family moved out, the original keeps render_all and
    # imports what it moved.
    KEPT="$WORKDIR/kept.py"
    {
        command printf 'from parse import parse_entry, parse_header, parse_body\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$KEPT"
    MOVED="$WORKDIR/parse.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n'
    } >"$MOVED"

    # Lossy: parse_body never made it into the destination file.
    LOSSY="$WORKDIR/parse-lossy.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n'
    } >"$LOSSY"
}

setup_md_fixtures() {
    MD_ORIG="$WORKDIR/doc.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf '## Configuration\n\nConfig details here.\n\n'
        command printf '## Troubleshooting\n\nTrouble details here.\n'
    } >"$MD_ORIG"

    # The destination both markdown cases move content INTO — identical in both,
    # so the only variable is the pointer left behind.
    MD_DETAIL="$WORKDIR/doc-detail.md"
    {
        command printf '# Details\n\n'
        command printf '## Configuration\n\nConfig details here.\n\n'
        command printf '## Troubleshooting\n\nTrouble details here.\n'
    } >"$MD_DETAIL"

    # BAD: content moved out, no link left behind — the content is lost, not
    # decomposed.
    MD_BAD="$WORKDIR/doc-bad.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n'
    } >"$MD_BAD"

    # GOOD: same move, plus the one-line pointer that makes it progressive
    # disclosure rather than deletion.
    MD_GOOD="$WORKDIR/doc-good.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf 'See [Details](doc-detail.md) for configuration and troubleshooting.\n'
    } >"$MD_GOOD"
}

# --- check 2: unit preservation ----------------------------------------------
test_lost_unit_is_detected() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$LOSSY"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" "a dropped top-level unit is reported"
    assert_contains "$VERIFY_OUT" "parse_body" "the report NAMES the unit that went missing"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a lossy split is not reported as verified"
}

test_sound_split_verifies() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" "a sound split is reported as non-lossy"
    assert_not_contains "$VERIFY_OUT" "split-unit-lost" "a sound split reports no lost units"
    assert_not_contains "$VERIFY_OUT" "split-fanin-dangling" "a sound split reports no dangling callers"
}

# --- Mixed-case extensions (#754) --------------------------------------------
# Every fixture above is lower-case, so this tool's `lang_of` was exercised in
# exactly one spelling. It matched the extension LITERALLY in a `case` while
# split-verify.py lowercased before the EXT_LANG lookup, so `Orig.PY` resolved
# to py under python and to NO LANGUAGE under bash.
#
# That is not a cosmetic label: `ORIG_LANG` feeds both `production_loc` and
# `unit_names`, so under bash a mixed-case original had ZERO extractable units —
# and a tool whose entire job is proving no unit was lost then had nothing to
# compare. It reported a lossy split as fine. Silent, exit 0.
#
# split-verify is deliberately OUT of validate-python-ports.sh's corpus (its argv
# is `<original> <post-split> [results...]`, not a file list), so its parity is
# asserted here per-case — which is exactly why the corpus fixture added in #754
# could not reach it, and why this case has to exist separately. Found by the
# mutation round, not by inspection: with only the corpus fixture, reverting this
# file's ts arm to a literal `case` left the whole suite green.
#
# BOTH arms are needed. The sound arm alone would pass on a broken tool that
# found no units at all (nothing lost because nothing seen), so the LOSSY arm is
# what gives the pair teeth, and the sound arm is what proves the tool is not
# simply reporting loss unconditionally.
setup_mixed_case_fixtures() {
    MC_ORIG="$WORKDIR/Orig.PY"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$MC_ORIG"

    MC_KEPT="$WORKDIR/Orig-kept.PY"
    {
        command printf 'from parse import parse_entry, parse_header, parse_body\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$MC_KEPT"

    MC_MOVED="$WORKDIR/Parse.PY"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n'
    } >"$MC_MOVED"

    # parse_body dropped on the way out.
    MC_LOSSY="$WORKDIR/Parse-lossy.PY"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n'
    } >"$MC_LOSSY"
}

test_mixed_case_lost_unit_is_detected() {
    setup_mixed_case_fixtures
    run_verify "$MC_ORIG" "$MC_KEPT" "$MC_LOSSY"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" \
        "mixed-case: a dropped unit in an .PY split is reported (#754)"
    assert_contains "$VERIFY_OUT" "parse_body" \
        "mixed-case: the report NAMES the unit that went missing (#754)"
}

test_mixed_case_sound_split_verifies() {
    setup_mixed_case_fixtures
    run_verify "$MC_ORIG" "$MC_KEPT" "$MC_MOVED"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" \
        "mixed-case: a sound .PY split is reported as non-lossy (#754)"
    assert_not_contains "$VERIFY_OUT" "split-unit-lost" \
        "mixed-case: a sound split reports no lost units (#754)"
}

# --- Swift (#728) ------------------------------------------------------------
# split-verify is the THIRD consumer of the shared segmenter table, and the one
# whose entire job is proving no unit was lost across a split. Its own scan loop
# — not the shared awk_lib helpers — gained real control flow in #728: the
# header-first `is_attr_test` ordering and the `is_reserved_name` filter are both
# called from `production_loc()`, OUTSIDE the `shared:unit-segmenters-awk`
# region. validate-shared-scanner-sync.sh proves those HELPERS are byte-identical
# to sizing.sh's copies; it says nothing about whether this loop CALLS them
# correctly. That gap is what these cases close: the sibling suites
# (validate-decomposition-detectors.sh, validate-sizing-scanner.sh) each got
# purpose-built Swift fixtures and this one had none.
setup_swift_fixtures() {
    # Four top-level declarations plus a swift-testing unit and a `///` doc
    # comment, so the fixtures exercise the exclusion paths and not merely the
    # unit list.
    SW_ORIG="$WORKDIR/Model.swift"
    {
        command printf '/// Model doc line.\n'
        command printf 'public struct UserProfile {\n    let id: String\n}\n'
        command printf 'public struct UserSettings {\n    let theme: String\n}\n'
        command printf 'extension UserProfile: Codable {\n    func encode() {}\n}\n'
        command printf 'public func loadUser() {\n    _ = UserProfile.self\n}\n'
        command printf '@Test\nfunc testLoadsUser() {\n    _ = loadUser()\n}\n'
    } >"$SW_ORIG"

    # The post-split original: the two Users stay, the extension and loader move.
    SW_KEPT="$WORKDIR/Model-kept.swift"
    {
        command printf '/// Model doc line.\n'
        command printf 'public struct UserProfile {\n    let id: String\n}\n'
        command printf 'public struct UserSettings {\n    let theme: String\n}\n'
        command printf '@Test\nfunc testLoadsUser() {\n    _ = loadUser()\n}\n'
    } >"$SW_KEPT"

    # The Type+Concern destination — the idiomatic Swift split shape this repo
    # now recommends, so the fixture matches the advice the scanners emit.
    SW_MOVED="$WORKDIR/UserProfile+Codable.swift"
    {
        command printf 'extension UserProfile: Codable {\n    func encode() {}\n}\n'
        command printf 'public func loadUser() {\n    _ = UserProfile.self\n}\n'
    } >"$SW_MOVED"

    # LOSSY: loadUser never lands anywhere, though it is still called.
    SW_LOSSY="$WORKDIR/UserProfile+Lossy.swift"
    command printf 'extension UserProfile: Codable {\n    func encode() {}\n}\n' >"$SW_LOSSY"
}

test_swift_sound_split_verifies() {
    setup_swift_fixtures
    run_verify "$SW_ORIG" "$SW_KEPT" "$SW_MOVED"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" "swift: a sound split is reported as non-lossy (#728)"
    assert_not_contains "$VERIFY_OUT" "split-unit-lost" "swift: a sound split reports no lost units (#728)"
}

test_swift_lost_unit_is_detected() {
    setup_swift_fixtures
    run_verify "$SW_ORIG" "$SW_KEPT" "$SW_LOSSY"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" "swift: a dropped Swift declaration is reported (#728)"
    assert_contains "$VERIFY_OUT" "loadUser" "swift: the report NAMES the lost declaration (#728)"
}

# The reserved-name filter and the attribute path both live in THIS tool's loop,
# so they need a case here even though the scanners cover them too. The malformed
# `open class override` header must not become a phantom unit, and — the #728
# review finding — the `@Test` before it must not leak its mark onto the genuine
# unit that follows.
test_swift_reserved_name_and_attribute_paths() {
    local orig="$WORKDIR/Leak.swift" kept="$WORKDIR/Leak-kept.swift"
    {
        command printf '@Test\nopen class override BogusOne {\n    let x: Int\n}\n'
        command printf 'public func realProductionUnit() {\n    work()\n}\n'
        command printf 'public func secondRealUnit() {\n    work()\n}\n'
    } >"$orig"
    # Same file, so a sound split verifies — the assertion is that neither the
    # phantom unit nor a leaked test mark makes this look lossy.
    command cp "$orig" "$kept"
    run_verify "$orig" "$kept"
    assert_parity
    assert_not_contains "$VERIFY_OUT" "override" \
        "swift: no phantom unit named for a captured keyword (#728)"
    assert_contains "$VERIFY_OUT" "split-verified" \
        "swift: an unchanged file with a reserved-name header still verifies (#728)"
}

# --- TypeScript (#755) -------------------------------------------------------
# #726 gave split-verify a `ts` arm — in is_unit_header/unit_name inside the
# shared:unit-segmenters-awk region on the bash side, and transitively via
# sizing.py -> loc_engine.py's UNIT_RE["ts"] on the python side — and this suite
# gained no .ts fixture at all. Neither neighbouring gate covers it:
#
#   - validate-shared-scanner-sync.sh proves the `ts` copy here is BYTE-IDENTICAL
#     to sizing.sh's. That is a textual property. Three copies wrong in the same
#     way still compare equal ([[parity-gate-hides-shared-defect]]).
#   - validate-python-ports.sh is scoped to sizing.{py,sh}'s own TSV output and
#     never invokes split-verify — its argv is `<original> <post-split>
#     [results...]`, not a file list. That is the same reason #754's corpus
#     fixture could not reach this tool, and why that issue needed its own case
#     here too.
#
# It matters more for ts than for most languages: #726 made the `types/` dir +
# re-exporting barrel the recommended TS remedy, so a types.ts broken into domain
# modules is now the split shape a decomposition-seam row is MOST likely to hand
# this tool — and it was the one shape never tested.
#
# THE SOUND ARM ASSERTS THE UNIT COUNT, NOT MERELY `split-verified`. Measured by
# reverting the ts arm on a scratch copy: the sound split still reports
# `split-verified`, because with no ts segmenter NOTHING is a unit and nothing
# can be missing — the only tell is the count falling from `all 4` to `all 0`.
# An arm asserting just `split-verified` would pass with AND without the fix
# ([[fixture-must-express-the-divergent-case]]). The lossy arm needs no such care:
# reverting turns a genuinely dropped `type Theme` into a clean `split-verified`.
#
# The declaration mix is deliberate. `interface`/`type`/`enum` are the type-level
# forms the ts arm added OVER the js arm; `function` is the one form js would also
# catch. A fixture of only functions would pass on a tool that classified .ts as
# js, and so could not tell the two arms apart.
setup_ts_fixtures() {
    # The pre-split original: three type-level declarations plus a function that
    # consumes one of them.
    TS_ORIG="$WORKDIR/types.ts"
    {
        command printf 'export interface UserProfile {\n  id: string;\n}\n\n'
        command printf 'export type Theme = "dark" | "light";\n\n'
        command printf 'export enum Role {\n  Admin,\n  Guest,\n}\n\n'
        command printf 'export function describeUser(u: UserProfile): string {\n  return u.id;\n}\n'
    } >"$TS_ORIG"

    # The post-split original: a re-exporting barrel plus the function that
    # stayed — the types/ + barrel shape #726 recommends. It names Theme, so a
    # Theme that lands nowhere leaves a live reference dangling.
    TS_KEPT="$WORKDIR/types-kept.ts"
    {
        command printf 'export type { UserProfile, Theme } from "./user";\n'
        command printf 'export { Role } from "./user";\n\n'
        command printf 'import type { UserProfile } from "./user";\n\n'
        command printf 'export function describeUser(u: UserProfile): string {\n  return u.id;\n}\n'
    } >"$TS_KEPT"

    # The domain module the three type-level declarations moved into.
    TS_MOVED="$WORKDIR/user.ts"
    {
        command printf 'export interface UserProfile {\n  id: string;\n}\n\n'
        command printf 'export type Theme = "dark" | "light";\n\n'
        command printf 'export enum Role {\n  Admin,\n  Guest,\n}\n'
    } >"$TS_MOVED"

    # LOSSY: `type Theme` never made it into the destination, while the barrel
    # still re-exports it.
    TS_LOSSY="$WORKDIR/user-lossy.ts"
    {
        command printf 'export interface UserProfile {\n  id: string;\n}\n\n'
        command printf 'export enum Role {\n  Admin,\n  Guest,\n}\n'
    } >"$TS_LOSSY"
}

test_ts_sound_split_verifies() {
    setup_ts_fixtures
    run_verify "$TS_ORIG" "$TS_KEPT" "$TS_MOVED"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" \
        "ts: a sound types/ + barrel split is reported as non-lossy (#755)"
    # THE assertion that gives this arm teeth — see the block comment above.
    # Without the ts segmenter this reads "all 0", and every other assertion
    # here still passes.
    assert_contains "$VERIFY_OUT" "all 4 top-level unit(s) preserved" \
        "ts: interface/type/enum/function are all seen as units (#755)"
    assert_not_contains "$VERIFY_OUT" "split-unit-lost" \
        "ts: a sound split reports no lost units (#755)"
    assert_not_contains "$VERIFY_OUT" "split-fanin-dangling" \
        "ts: a sound split reports no dangling callers (#755)"
}

test_ts_lost_unit_is_detected() {
    setup_ts_fixtures
    run_verify "$TS_ORIG" "$TS_KEPT" "$TS_LOSSY"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" \
        "ts: a dropped type alias is reported as a lost unit (#755)"
    assert_contains "$VERIFY_OUT" "Theme" \
        "ts: the report NAMES the type that went missing (#755)"
    # The barrel still re-exports Theme, so the loss ALSO dangles a live
    # reference — check 3 over ts, not just check 2.
    assert_contains "$VERIFY_OUT" "split-fanin-dangling" \
        "ts: the surviving re-export of a dropped type dangles (#755)"
    assert_not_contains "$VERIFY_OUT" "split-verified" \
        "ts: a lossy split is not reported as verified (#755)"
}

# --- checks 2/3 over the Rust and Go segmenters (#727) -----------------------
# Every case above drives .py fixtures, so split-verify's OWN use of unit_name
# was exercised for one language only. The rs/go arms are the most-edited lines
# in the shared unit-segmenters-awk region, and the sync gate that covers them
# is a DRIFT detector, not a behavior detector: three copies wrong in the same
# way still compare equal ([[parity-gate-hides-shared-defect]]). These two cases
# pin the behavior here, where the region is actually consumed.
test_rust_split_is_verified_by_unit_name() {
    local orig kept moved lossy
    orig="$WORKDIR/rs-orig.rs"
    {
        command printf 'pub fn render_all(x: u32) -> u32 {\n    parse_entry(x)\n}\n\n'
        command printf 'pub fn parse_entry(x: u32) -> u32 {\n    x + 1\n}\n\n'
        command printf 'impl Display for Doc {\n    fn fmt(&self) -> R {\n        w()\n    }\n}\n'
    } >"$orig"

    kept="$WORKDIR/rs-kept.rs"
    {
        command printf 'use parse::parse_entry;\n\n'
        command printf 'pub fn render_all(x: u32) -> u32 {\n    parse_entry(x)\n}\n'
    } >"$kept"

    # The impl block moves as ONE unit — the granularity decision #727 records.
    # Its unit name is the TYPE (`Doc`), not the trait, so a regression that
    # reverted to trait-capture would look for `Display` and report it lost.
    moved="$WORKDIR/rs-parse.rs"
    {
        command printf 'pub fn parse_entry(x: u32) -> u32 {\n    x + 1\n}\n\n'
        command printf 'impl Display for Doc {\n    fn fmt(&self) -> R {\n        w()\n    }\n}\n'
    } >"$moved"

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" \
        "rust: a sound impl/fn split verifies clean"

    # Lossy: the impl block never reached the destination.
    lossy="$WORKDIR/rs-lossy.rs"
    command printf 'pub fn parse_entry(x: u32) -> u32 {\n    x + 1\n}\n' >"$lossy"

    run_verify "$orig" "$kept" "$lossy"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" \
        "rust: a dropped impl block is detected as a lost unit"
    assert_contains "$VERIFY_OUT" "Doc" \
        "rust: the lost impl is NAMED by its type, not by its trait"
}

test_go_method_split_is_verified_by_receiver_name() {
    local orig kept moved lossy
    orig="$WORKDIR/go-orig.go"
    {
        command printf 'package app\n\n'
        command printf 'func MainEntry(s string) string {\n\treturn s\n}\n\n'
        command printf 'func (r *Repo) GetOne(id string) string {\n\treturn id\n}\n\n'
        command printf 'func (r *Repo) PutOne(id string) error {\n\treturn nil\n}\n'
    } >"$orig"

    kept="$WORKDIR/go-kept.go"
    {
        command printf 'package app\n\n'
        command printf 'func MainEntry(s string) string {\n\treturn s\n}\n'
    } >"$kept"

    moved="$WORKDIR/go-repo.go"
    {
        command printf 'package app\n\n'
        command printf 'func (r *Repo) GetOne(id string) string {\n\treturn id\n}\n\n'
        command printf 'func (r *Repo) PutOne(id string) error {\n\treturn nil\n}\n'
    } >"$moved"

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" \
        "go: a sound receiver-method split verifies clean"

    # Lossy: PutOne never reached the destination. Before #727 methods were
    # INVISIBLE to unit_name, so neither method was a unit and this loss was
    # undetectable — the split would have verified clean.
    lossy="$WORKDIR/go-lossy.go"
    {
        command printf 'package app\n\n'
        command printf 'func (r *Repo) GetOne(id string) string {\n\treturn id\n}\n'
    } >"$lossy"

    run_verify "$orig" "$kept" "$lossy"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" \
        "go: a dropped receiver method is detected as a lost unit"
    assert_contains "$VERIFY_OUT" "Repo_PutOne" \
        "go: the lost method is NAMED receiver-first, proving the receiver join"
}

# production_loc() is this tool's OWN measurement loop, outside the shared
# unit-segmenters-awk region — so the sync gate cannot see it, and #727's
# unit-bounded test-region sweep had to be applied here as a fourth sibling
# ([[harden-one-knob-grep-every-sibling]]). Unbounded, a mid-file
# `#[cfg(test)] mod tests` excluded every production unit after it: measured on
# this fixture, 3 -> 10 production LOC instead of 9 -> 10. A phantom seven-line
# GAIN, which is what would mask a real loss on the LOC-conservation check.
test_rust_midfile_test_region_in_production_loc() {
    local orig kept moved
    orig="$WORKDIR/rs-mid-orig.rs"
    {
        command printf 'pub fn alpha() -> u32 {\n    1\n}\n\n'
        command printf '#[cfg(test)]\nmod tests {\n    #[test]\n    fn t_one() {\n        assert!(true);\n    }\n}\n\n'
        command printf 'pub fn beta() -> u32 {\n    2\n}\n\n'
        command printf 'pub fn gamma() -> u32 {\n    3\n}\n'
    } >"$orig"

    kept="$WORKDIR/rs-mid-kept.rs"
    {
        command printf 'use beta::{beta, gamma};\n\n'
        command printf 'pub fn alpha() -> u32 {\n    1\n}\n\n'
        command printf '#[cfg(test)]\nmod tests {\n    #[test]\n    fn t_one() {\n        assert!(true);\n    }\n}\n'
    } >"$kept"

    moved="$WORKDIR/rs-mid-beta.rs"
    {
        command printf 'pub fn beta() -> u32 {\n    2\n}\n\n'
        command printf 'pub fn gamma() -> u32 {\n    3\n}\n'
    } >"$moved"

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    # The ORIGINAL side must measure 9, not 3 — the test module alone is
    # excluded, not everything after it. Asserting the rendered number rather
    # than merely "verified": both the fixed and unbounded impls report
    # verified here, and only the LOC figure tells them apart.
    assert_contains "$VERIFY_OUT" "9 -> 10 production LOC" \
        "rust: a mid-file test module excludes only itself in production_loc()"
    assert_contains "$VERIFY_OUT" "all 3 top-level unit(s) preserved" \
        "rust: units after a mid-file test module survive split verification"
}

# --- check 1: LOC conservation -----------------------------------------------
# Uses a LARGE drop so the loss clears the boilerplate tolerance — the tolerance
# exists precisely so a few import/mod/__init__ lines are not reported as drift.
test_loc_drift_is_detected() {
    local orig="$WORKDIR/big-orig.py" kept="$WORKDIR/big-kept.py" moved="$WORKDIR/big-moved.py" i
    : >"$orig"
    i=0
    while [ "$i" -lt 100 ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$orig"
        i=$((i + 1))
    done
    command printf 'from moved import unit_0\n' >"$kept"
    # Only the first 10 units survive: ~180 production LOC dropped, far past the
    # 40-line default tolerance.
    : >"$moved"
    i=0
    while [ "$i" -lt 10 ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$moved"
        i=$((i + 1))
    done

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-loc-drift" "a large content drop is reported as LOC drift"
    assert_contains "$VERIFY_OUT" "production LOC" "the evidence quantifies the loss"
}

# --- the tolerance is real: boilerplate does NOT trip the LOC check ----------
# Without this, the LOC check could be a bare equality test and the previous case
# would still pass — while every real split (which adds imports) reported drift.
test_boilerplate_does_not_trip_loc_check() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    assert_parity
    assert_not_contains "$VERIFY_OUT" "split-loc-drift" \
        "import/re-export boilerplate does not count as lost content"
}

# --- check 3: fan-in resolution ----------------------------------------------
# The positive fixture for the one check that would otherwise appear ONLY as a
# negative assertion inside the sound-split case. Per this suite's own rule,
# a check asserted only silent is indistinguishable from a check that never
# fires — so this engineers a genuinely dangling call site.
#
# The shape matters: `helper` must be DROPPED from the result set while a
# SURVIVING unit still calls it by name. A fixture that merely deleted an
# unreferenced unit would trip check 2 (unit preservation) instead and prove
# nothing about fan-in.
test_dangling_reference_is_detected() {
    local orig="$WORKDIR/fanin-orig.py" kept="$WORKDIR/fanin-kept.py" moved="$WORKDIR/fanin-moved.py"
    {
        command printf 'def helper(x):\n    return x * 2\n\n'
        command printf 'def compute(x):\n    return helper(x) + 1\n\n'
        command printf 'def report(x):\n    return compute(x)\n'
    } >"$orig"
    # The post-split original keeps report + compute — and compute STILL calls
    # helper by name...
    {
        command printf 'def compute(x):\n    return helper(x) + 1\n\n'
        command printf 'def report(x):\n    return compute(x)\n'
    } >"$kept"
    # ...but the destination file never received helper. The call now dangles.
    command printf 'def unrelated(x):\n    return x\n' >"$moved"

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-fanin-dangling" "a dangling call site is reported"
    assert_contains "$VERIFY_OUT" "helper" "the report NAMES the unit whose callers dangle"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a split with a dangling reference is not verified"
}

# --- check 4: markdown reachability ------------------------------------------
# THE pair the issue calls out. Same content moved in both; only the pointer
# differs. A check that merely noticed "content moved" would pass both.
test_unreachable_moved_heading_is_detected() {
    setup_md_fixtures
    run_verify "$MD_ORIG" "$MD_BAD" "$MD_DETAIL"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "prose moved out with no link left behind is reported"
    assert_contains "$VERIFY_OUT" "Configuration" "the report NAMES an unreachable heading"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a lossy prose split is not verified"
}

# A heading dropped from EVERY result file is unreachable no matter how many
# links the original carries. This is the bash/python divergence cycle 2 caught:
# the bash port checked only "does the original link to a moved-into file?" and
# never "did the heading survive anywhere?", so a genuinely LOST section passed
# as `split-verified` while python flagged it.
#
# The fixture is shaped to make link-presence and heading-survival DISAGREE — the
# original links to detail.md (real, and it did receive Configuration) while
# Troubleshooting exists nowhere. The MD_BAD/MD_GOOD pair above cannot catch this:
# both put every moved heading in MD_DETAIL, so survival is always true there and
# the two conditions never separate. That is precisely why this fixture is its own
# case rather than an assertion bolted onto an existing one.
test_dropped_heading_is_unreachable_despite_a_link() {
    local orig="$WORKDIR/drop-orig.md" post="$WORKDIR/drop-post.md" detail="$WORKDIR/drop-detail.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf '## Configuration\n\nConfig details here.\n\n'
        command printf '## Troubleshooting\n\nTrouble details here.\n'
    } >"$orig"
    # A real, resolvable link to the moved-into file...
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf 'See [Details](drop-detail.md) for configuration.\n'
    } >"$post"
    # ...which received Configuration but NOT Troubleshooting.
    {
        command printf '# Details\n\n'
        command printf '## Configuration\n\nConfig details here.\n'
    } >"$detail"

    run_verify "$orig" "$post" "$detail"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "a heading present in NO result file is unreachable even when the original links elsewhere"
    assert_contains "$VERIFY_OUT" "Troubleshooting" "the report names the genuinely lost heading"
    assert_not_contains "$VERIFY_OUT" "Configuration" \
        "the heading that DID survive and is linked is not falsely reported"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a split that lost a section is not verified"
}

# MULTI-DESTINATION reachability, the gap that let a shared defect ship.
#
# Every markdown fixture above passes exactly ONE moved-into file, so "is this
# heading's own destination linked?" and "is any destination linked?" are the
# same question and no fixture could tell them apart. With TWO destinations they
# diverge: a link to A wrongly vouched for content in B, and the tool reported
# `split-verified` while B was unreachable. BOTH impls had it, so the parity
# assertion was green throughout — the parity-gate-hides-a-shared-defect class,
# which only a fixture asserting the INTENDED behavior can catch.
#
# The pair differs solely in whether the second destination is linked.
setup_multi_dest_fixtures() {
    MULTI_ORIG="$WORKDIR/multi.md"
    {
        command printf '# Guide\n\nIntro.\n\n'
        command printf '## Alpha\n\nAlpha body.\n\n'
        command printf '## Beta\n\nBeta body.\n'
    } >"$MULTI_ORIG"
    MULTI_A="$WORKDIR/multi-a.md"
    command printf '# A\n\n## Alpha\n\nAlpha body.\n' >"$MULTI_A"
    MULTI_B="$WORKDIR/multi-b.md"
    command printf '# B\n\n## Beta\n\nBeta body.\n' >"$MULTI_B"
}

test_second_destination_needs_its_own_link() {
    setup_multi_dest_fixtures
    local post="$WORKDIR/multi-post-bad.md"
    # Links ONLY to multi-a.md; nothing points at multi-b.md.
    {
        command printf '# Guide\n\nIntro.\n\n'
        command printf 'See [Alpha](multi-a.md) for details.\n'
    } >"$post"

    run_verify "$MULTI_ORIG" "$post" "$MULTI_A" "$MULTI_B"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "a link to one destination does not vouch for a heading in another"
    assert_contains "$VERIFY_OUT" "Beta" "the report names the heading whose destination is unlinked"
    assert_not_contains "$VERIFY_OUT" "Alpha" "the properly-linked heading is not falsely reported"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a partially-linked split is not verified"
}

test_all_destinations_linked_verifies() {
    setup_multi_dest_fixtures
    local post="$WORKDIR/multi-post-good.md"
    {
        command printf '# Guide\n\nIntro.\n\n'
        command printf 'See [Alpha](multi-a.md) and [Beta](multi-b.md) for details.\n'
    } >"$post"

    run_verify "$MULTI_ORIG" "$post" "$MULTI_A" "$MULTI_B"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" \
        "linking every destination makes a multi-file split sound"
    assert_not_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "no heading is reported unreachable when each destination is linked"
}

test_linked_moved_heading_passes() {
    setup_md_fixtures
    run_verify "$MD_ORIG" "$MD_GOOD" "$MD_DETAIL"
    assert_parity
    assert_not_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "a one-line pointer makes the moved content reachable (progressive disclosure)"
    assert_contains "$VERIFY_OUT" "split-verified" "a sound prose split is reported as non-lossy"
}

# --- the TSV contract --------------------------------------------------------
test_tsv_contract_is_five_columns() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    local line cols
    assert_not_empty "$VERIFY_OUT" "there is output to check the shape of"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cols="$(command printf '%s' "$line" | command awk -F'\t' '{print NF}')"
        assert_equals "5" "$cols" "row has exactly 5 tab-separated columns"
    done <<EOF
$VERIFY_OUT
EOF
}

# --- usage contract ----------------------------------------------------------
test_usage_contract() {
    local rc=0
    command bash "$VERIFY_SH" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "no arguments exits 1"

    setup_code_fixtures
    rc=0
    command bash "$VERIFY_SH" "$ORIG" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a single argument (no results) exits 1"

    rc=0
    command bash "$VERIFY_SH" "$ORIG" "$WORKDIR/nope.py" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing result file exits 1"
}

# --- Check 5: the memory-bundle index line (#729) ---------------------------
# The scanner's concept-split row ends "AND add its index line (an extracted
# concept with no index line is an orphan)". That was advisory English inside an
# evidence string: nothing verified the second half was done. An agent following
# the first half only produces #697 — the lesson on disk, absent from the index,
# never recalled, nothing erroring.
#
# The fixture must be built so the ONLY difference between firing and not is the
# index line itself; if any other check also fired, the counter-case would go
# green for the wrong reason and prove nothing.
sv_bundle_fixture() {
    local root="$1"
    command mkdir -p "$root/.claude/memory"
    # Pre-split snapshot: two lessons in one file. Deliberately at a TEMP path
    # OUTSIDE the bundle, exactly as the argument contract describes
    # (`git show HEAD:path > /tmp/before.md`) — this is what makes the
    # classify-on-results[0] behavior load-bearing rather than incidental.
    command printf '# First lesson\n\nalpha text\n\n# Second lesson\n\nbeta text\n' \
        >"$root/before.md"
    # Post-split original keeps lesson 1 AND links to the extracted half, so
    # check 4 (markdown reachability) is satisfied and cannot be the thing that
    # fires.
    command printf '# First lesson\n\nalpha text\n\nSee [second](second-lesson.md).\n' \
        >"$root/.claude/memory/two-lessons.md"
    command printf '# Second lesson\n\nbeta text\n' \
        >"$root/.claude/memory/second-lesson.md"
}

test_extracted_concept_without_index_line_is_orphaned() {
    local root="$WORKDIR/orphan" out sv_prev
    sv_bundle_fixture "$root"
    # An index that does NOT name the extracted concept.
    command printf '# Memory index\n\n- [two-lessons](two-lessons.md) — hook\n' \
        >"$root/.claude/memory/MEMORY.md"

    # cd in THIS shell, not a subshell: run_verify sets VERIFY_OUT, which a
    # subshell would discard. Relative paths matter — the bundle root is
    # relative, so the tool must be run from the fixture root.
    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md .claude/memory/two-lessons.md .claude/memory/second-lesson.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_contains "$out" "split-memory-orphan" \
        "an extracted concept absent from the index is reported"
    assert_contains "$out" "second-lesson.md" \
        "the orphaned concept is NAMED, so the fix is actionable"
    assert_not_contains "$out" "split-verified" \
        "a split with an orphaned concept does not verify clean"
}

# THE COUNTER-CASE, and the reason this pair is not a tautology: the ONLY change
# is the index line. If the check were keyed off anything else — the link, the
# file existing, the heading — this case would stay red.
test_extracted_concept_with_index_line_verifies() {
    local root="$WORKDIR/indexed" out sv_prev
    sv_bundle_fixture "$root"
    command printf '# Memory index\n\n- [two-lessons](two-lessons.md) — hook\n- [second-lesson](second-lesson.md) — the second lesson\n' \
        >"$root/.claude/memory/MEMORY.md"

    # cd in THIS shell, not a subshell: run_verify sets VERIFY_OUT, which a
    # subshell would discard. Relative paths matter — the bundle root is
    # relative, so the tool must be run from the fixture root.
    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md .claude/memory/two-lessons.md .claude/memory/second-lesson.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_not_contains "$out" "split-memory-orphan" \
        "an extracted concept named by the index is not an orphan"
    assert_contains "$out" "split-verified" \
        "the same split verifies clean once the index line exists"
}

# A topic SUB-INDEX counts, not just the root MEMORY.md. This repo's own bundle
# routes most entries through `index-*.md` files, so a check that only read
# MEMORY.md would false-positive on the common correct layout here.
test_subindex_pointer_satisfies_the_invariant() {
    local root="$WORKDIR/subindex" out sv_prev
    sv_bundle_fixture "$root"
    command printf '# Memory index\n\n- [Runtime](index-runtime.md) — sub-index\n' \
        >"$root/.claude/memory/MEMORY.md"
    command printf '# Runtime\n\n- [second-lesson](second-lesson.md) — the second lesson\n' \
        >"$root/.claude/memory/index-runtime.md"

    # cd in THIS shell, not a subshell: run_verify sets VERIFY_OUT, which a
    # subshell would discard. Relative paths matter — the bundle root is
    # relative, so the tool must be run from the fixture root.
    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md .claude/memory/two-lessons.md .claude/memory/second-lesson.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_not_contains "$out" "split-memory-orphan" \
        "a pointer from a topic sub-index satisfies the invariant"
}

# SCOPE FENCE (#669 slice B stays out). The check is decomposition-side only:
# "the split you were just told to make must not orphan ITS OWN output". A
# pre-existing orphan the split never touched is NOT this tool's business —
# reporting it here would silently widen the contract and make every split of an
# imperfect bundle fail for reasons unrelated to the split.
test_preexisting_orphan_is_not_this_tools_business() {
    local root="$WORKDIR/preexisting" out sv_prev
    sv_bundle_fixture "$root"
    command printf '# Memory index\n\n- [two-lessons](two-lessons.md) — hook\n- [second-lesson](second-lesson.md) — the second lesson\n' \
        >"$root/.claude/memory/MEMORY.md"
    # An unrelated orphan that this split neither created nor was passed.
    command printf '# Unrelated\n\nnobody points at me\n' \
        >"$root/.claude/memory/stray-lesson.md"

    # cd in THIS shell, not a subshell: run_verify sets VERIFY_OUT, which a
    # subshell would discard. Relative paths matter — the bundle root is
    # relative, so the tool must be run from the fixture root.
    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md .claude/memory/two-lessons.md .claude/memory/second-lesson.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_not_contains "$out" "split-memory-orphan" \
        "a pre-existing orphan outside this split is not reported (#669 slice B)"
    assert_contains "$out" "split-verified" \
        "the split itself still verifies clean"
}

# A NON-BUNDLE split must be untouched by check 5. Without the bundle_kind guard
# the check would demand an index line for every markdown split in the repo.
test_non_bundle_split_is_unaffected() {
    local root="$WORKDIR/nonbundle" out sv_prev
    command mkdir -p "$root/docs"
    command printf '# First\n\nalpha\n\n# Second\n\nbeta\n' >"$root/before.md"
    command printf '# First\n\nalpha\n\nSee [second](second.md).\n' >"$root/docs/guide.md"
    command printf '# Second\n\nbeta\n' >"$root/docs/second.md"

    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md docs/guide.md docs/second.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_not_contains "$out" "split-memory-orphan" \
        "a split outside any memory bundle never asks for an index line"
}

# The '+N more' TRUNCATION arm (#729). Both impls cap the named orphans at 3 and
# append a `(+N more)` suffix. That is hand-rolled twice — a Python slice on one
# side, a bash counter on the other — so the two can disagree on the boundary
# (is the 4th name included?) or on the suffix text, and the TSV contract would
# break in a way no single-orphan fixture can see. `assert_parity` is doing real
# work here rather than being ceremony.
test_orphan_list_truncates_at_three_with_a_count() {
    local root="$WORKDIR/trunc" out sv_prev i
    command mkdir -p "$root/.claude/memory"
    command printf '# Lesson one\n\nalpha\n' >"$root/before.md"
    command printf '# Lesson one\n\nalpha\n' >"$root/.claude/memory/source.md"
    # An index naming NONE of the extracted concepts, so all four are orphans.
    command printf '# Memory index\n\n- [source](source.md) — hook\n' \
        >"$root/.claude/memory/MEMORY.md"
    i=1
    while [ "$i" -le 4 ]; do
        command printf '# Extracted %d\n\nbeta\n' "$i" \
            >"$root/.claude/memory/extracted-$i.md"
        i=$((i + 1))
    done

    sv_prev="$PWD"
    cd "$root" || return 1
    run_verify before.md .claude/memory/source.md \
        .claude/memory/extracted-1.md .claude/memory/extracted-2.md \
        .claude/memory/extracted-3.md .claude/memory/extracted-4.md
    cd "$sv_prev" || return 1
    out="$VERIFY_OUT"
    assert_parity

    assert_contains "$out" "split-memory-orphan" "four unindexed concepts are orphans"
    assert_contains "$out" "4 extracted concept(s)" "the COUNT reports all four, not just the listed three"
    assert_contains "$out" "(+1 more)" "the overflow suffix names how many were withheld"
    # The BOUNDARY: three names listed, the fourth withheld. Asserting the
    # absence of the 4th is what pins the cap — a `[:4]` slice would still
    # satisfy every other assertion here.
    assert_contains "$out" "extracted-3.md" "the third orphan is still named"
    assert_not_contains "$out" "extracted-4.md" "the fourth orphan is withheld behind the count"
}

run_test test_lost_unit_is_detected "Check 2: a dropped top-level unit is detected and named"
run_test test_sound_split_verifies "Check 2 counter: a sound split verifies clean"
run_test test_mixed_case_lost_unit_is_detected "mixed-case: a dropped unit in an .PY split is detected and named (#754)"
run_test test_mixed_case_sound_split_verifies "mixed-case counter: a sound .PY split verifies clean (#754)"
run_test test_swift_sound_split_verifies "swift: a sound Type+Concern split verifies clean (#728)"
run_test test_swift_lost_unit_is_detected "swift: a dropped Swift declaration is detected and named (#728)"
run_test test_swift_reserved_name_and_attribute_paths "swift: reserved-name filter and attribute path in split-verify's own loop (#728)"
run_test test_ts_sound_split_verifies "ts: a sound types/ + barrel split verifies clean (#755)"
run_test test_ts_lost_unit_is_detected "ts: a dropped type alias is detected, named, and dangles (#755)"
run_test test_rust_split_is_verified_by_unit_name "Check 2 (rust): impl moves as one unit, named by type (#727)"
run_test test_go_method_split_is_verified_by_receiver_name "Check 2 (go): a lost receiver method is named Receiver_Method (#727)"
run_test test_rust_midfile_test_region_in_production_loc "Check 1 (rust): a mid-file test module excludes only itself (#727)"
run_test test_loc_drift_is_detected "Check 1: a large content drop is detected as LOC drift"
run_test test_boilerplate_does_not_trip_loc_check "Check 1 counter: re-export boilerplate is tolerated"
run_test test_dangling_reference_is_detected "Check 3: a dangling call site is detected and named"
run_test test_unreachable_moved_heading_is_detected "Check 4: prose moved with no link left behind is detected"
run_test test_dropped_heading_is_unreachable_despite_a_link "Check 4: a heading in NO result file is unreachable despite an unrelated link"
run_test test_second_destination_needs_its_own_link "Check 4: a link to one destination does not vouch for another (multi-file)"
run_test test_all_destinations_linked_verifies "Check 4 counter: every destination linked verifies (multi-file)"
run_test test_linked_moved_heading_passes "Check 4 counter: a one-line pointer makes the move sound"
run_test test_extracted_concept_without_index_line_is_orphaned "Check 5: an extracted concept with no index line is an orphan (#729)"
run_test test_extracted_concept_with_index_line_verifies "Check 5 counter: the index line alone clears it (#729)"
run_test test_subindex_pointer_satisfies_the_invariant "Check 5: a topic sub-index pointer satisfies the invariant (#729)"
run_test test_preexisting_orphan_is_not_this_tools_business "Check 5 scope: a pre-existing orphan is #669 slice B, not this tool (#729)"
run_test test_non_bundle_split_is_unaffected "Check 5 guard: a non-bundle split never asks for an index line (#729)"
run_test test_orphan_list_truncates_at_three_with_a_count "Check 5: the orphan list truncates at 3 with a (+N more) count (#729)"
run_test test_tsv_contract_is_five_columns "Output honors the 5-column TSV contract"
run_test test_usage_contract "Usage / missing-file contract"

generate_report
