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

run_test test_lost_unit_is_detected "Check 2: a dropped top-level unit is detected and named"
run_test test_sound_split_verifies "Check 2 counter: a sound split verifies clean"
run_test test_swift_sound_split_verifies "swift: a sound Type+Concern split verifies clean (#728)"
run_test test_swift_lost_unit_is_detected "swift: a dropped Swift declaration is detected and named (#728)"
run_test test_swift_reserved_name_and_attribute_paths "swift: reserved-name filter and attribute path in split-verify's own loop (#728)"
run_test test_rust_split_is_verified_by_unit_name "Check 2 (rust): impl moves as one unit, named by type (#727)"
run_test test_go_method_split_is_verified_by_receiver_name "Check 2 (go): a lost receiver method is named Receiver_Method (#727)"
run_test test_loc_drift_is_detected "Check 1: a large content drop is detected as LOC drift"
run_test test_boilerplate_does_not_trip_loc_check "Check 1 counter: re-export boilerplate is tolerated"
run_test test_dangling_reference_is_detected "Check 3: a dangling call site is detected and named"
run_test test_unreachable_moved_heading_is_detected "Check 4: prose moved with no link left behind is detected"
run_test test_dropped_heading_is_unreachable_despite_a_link "Check 4: a heading in NO result file is unreachable despite an unrelated link"
run_test test_second_destination_needs_its_own_link "Check 4: a link to one destination does not vouch for another (multi-file)"
run_test test_all_destinations_linked_verifies "Check 4 counter: every destination linked verifies (multi-file)"
run_test test_linked_moved_heading_passes "Check 4 counter: a one-line pointer makes the move sound"
run_test test_tsv_contract_is_five_columns "Output honors the 5-column TSV contract"
run_test test_usage_contract "Usage / missing-file contract"

generate_report
