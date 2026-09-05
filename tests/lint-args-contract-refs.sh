#!/usr/bin/env bash
# Review-harness accepted-`args`-key gate (issue #886).
#
# `KNOWN_ARG_KEYS` in ship-issue/workflow.js decides which top-level `args` keys
# the review harness accepts. The same list is restated in prose six times, and
# until this gate only the array itself was enforced.
#
# WHY PROSE DRIFT HERE IS DANGEROUS, and why it needs a gate rather than care.
# The #597 runtime guard throws on an INVENTED key — a superset error — but is
# structurally blind to a MISSING one. A prose list that under-lists is silently
# wrong at dispatch: the caller simply never passes the key, the harness reads
# its empty default, and the cycle reviews less than the caller believes. That
# failure is invisible in the output (#567: a dropped `diff` produced
# `clean: true` from five reviewers scanning nothing), and `clean` is half the
# merge invariant. So the SUBSET direction is the half with no other backstop,
# and it is the direction a one-way check would miss.
#
# IT HAS ALREADY HAPPENED, TWICE OVER. #722 added two inline key lists, knowingly
# widening the surface, and split this gate out rather than pretend the docs edit
# closed it. Its own review caught both new lists omitting `tokenCeiling` on the
# FIRST cycle. Then #550 added `reviewRoute` to the array and to two of the
# fenced blocks — and missed three prose sites (SKILL.md, execute-protocol.md,
# and the narrowed pre-pr block). That drift shipped, and this gate is what
# found it. An LLM reading two files side by side is exactly the check that will
# not happen on the day nobody looks.
#
# THE RULE, in both directions, per site:
#   superset — every key NAMED at a site must be in KNOWN_ARG_KEYS
#              (catches an invented key, a rename, a typo)
#   subset   — every key in that site's EXPECTED set must appear
#              (catches the #722/#550 defect; the direction #597 cannot see)
#
# NOT a flat equality check against all 14. The sites legitimately differ:
# `prComments` is `pr-cycle`-only, the delta trio is omitted on cycle 1, and the
# two summary lists deliberately abbreviate. Demanding uniformity would force
# the docs to lie. The expected sets below encode those differences instead —
# which is also what makes the subset arm meaningful rather than vacuous.
#
# ANCHORING: `<!-- contract: … -->` markers, not headings or fence ordinals.
# The repo's own mechanism (tests/lib/harness.sh `extract_contract`), chosen
# after measuring the alternative: a paragraph-bounded region around the
# accepted-set sentence swallows the `argsFile` counter-example in the very next
# paragraph and reports it as an invented key, and the two `pre-pr` blocks in one
# file are distinguishable only by ordinal — an anchor that silently stops
# matching the day a block moves. Ids name the SITE, never its position.
#
# THE AUTHORITY IS THE JS, THE SUBJECT IS THE MARKDOWN. Never scrape both sides
# from one source: a fixture that does proves nothing (#886 says so explicitly,
# and this repo has hit that tautology on #599/#600).
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file's own path. test_missing_awk_exits_77 slices the real skip branch
# out of it and drives that block standalone, so the slice tracks edits to the
# real code instead of drifting into a paraphrase of it.
SELF_PATH="$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# Overridable so the negative fixtures can drive planted corpora instead of the
# real tree (the PROSE_BUDGET_* pattern in lint-prose-budget.sh). Asserting only
# against the real repo would make every case hostage to unrelated prose edits.
HARNESS_JS="${ARGS_CONTRACT_HARNESS:-$REPO_ROOT/plugins/workflow/skills/ship-issue/workflow.js}"
SHIP_DIR="${ARGS_CONTRACT_SHIP_DIR:-$REPO_ROOT/plugins/workflow/skills/ship-issue}"

test_suite "Review-harness accepted-args-key refs (#886)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
# A silent skip is indistinguishable from a pass, which is how a gate sits inert
# unnoticed (#538, #571) — so this must never be a bare exit 0.
SKIP_EXIT_CODE=77

if ! command -v awk >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — awk not available (install awk to check args-key refs)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Authority ---------------------------------------------------------------

# The awk program that lifts KNOWN_ARG_KEYS out of the harness, held as a
# constant so the tests drive the SAME text the real scan does.
#
# Bounded by the array literal itself, not by a line count: it starts at the
# `const KNOWN_ARG_KEYS = [` line and stops at the closing `]`, so keys are
# picked up wherever the array happens to sit in the file.
EXTRACT_KEYS_AWK='
index($0, "const KNOWN_ARG_KEYS") == 1 { grab = 1; next }
grab && /^\]/ { exit }
grab {
    if (match($0, /'"'"'[A-Za-z][A-Za-z0-9]*'"'"'/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
    }
}
'

# known_arg_keys — the accepted set, newline-separated, in declaration order.
known_arg_keys() {
    command awk "$EXTRACT_KEYS_AWK" "$HARNESS_JS"
}

# --- Sites -------------------------------------------------------------------
#
# One row per prose site: "<contract-id>|<file>|<expected keys>".
#
# `expected` is what that site MUST name. A site may name MORE than its expected
# set (the superset arm still constrains it to real members) — what the subset
# arm forbids is naming less. Written as explicit lists rather than derived from
# the authority, because deriving them would re-create the tautology this gate
# exists to prevent: the expected sets are a human claim about what each site
# promises, and the whole point is to check the prose against something that is
# not itself the prose.
#
# WHY EACH SITE DIFFERS (a reviewer should be able to check these by hand):
#   pre-pr-cycle1    — cycle 1: no `prComments` (pr-cycle only), no delta trio
#                      (#656: cycle 1 always omits them)
#   pre-pr-narrowed  — the same block on a narrowed cycle: adds the delta trio,
#                      still no `prComments`
#   accepted-set     — the normative sentence: ALL of them, by definition
#   pr-cycle         — the post-PR block: all of them
#   skill-summary    — SKILL.md's "so you never reconstruct them" digest; points
#                      at the full block for the delta trio and `prComments`
#   execute-summary  — execute-protocol.md's pr-cycle digest: names the trio
#                      inline, so it carries everything
#
# A bare `key1 key2` string is used rather than an associative array: this must
# stay bash-3.2 clean (no `declare -A`), per CLAUDE.md.
SITES='
args-keys-pre-pr-cycle1|pre-ship-validation.md|phase cycle maxCycles files diff issue tokenCeiling preScan conventionsDigest reviewRoute
args-keys-pre-pr-narrowed|pre-ship-validation.md|phase cycle maxCycles files diff issue tokenCeiling preScan conventionsDigest reviewRoute deltaFiles deltaDiff priorBlockingDimensions
args-keys-accepted-set|pre-ship-validation.md|phase cycle maxCycles files diff prComments issue tokenCeiling preScan conventionsDigest reviewRoute deltaDiff deltaFiles priorBlockingDimensions
args-keys-pr-cycle|ci-review-protocol.md|phase cycle maxCycles files diff prComments issue tokenCeiling preScan conventionsDigest reviewRoute deltaFiles deltaDiff priorBlockingDimensions
args-keys-skill-summary|SKILL.md|phase cycle maxCycles files diff issue preScan conventionsDigest reviewRoute tokenCeiling
args-keys-execute-summary|execute-protocol.md|phase cycle maxCycles files diff prComments issue preScan conventionsDigest reviewRoute tokenCeiling deltaFiles deltaDiff priorBlockingDimensions
'

# The keys a site NAMES. Two spellings must both be seen or a site silently
# reads as empty — which would make its subset arm fail loudly (good) but its
# superset arm pass vacuously (bad):
#   fenced blocks   ->  `  key: <…>,`      (line-initial, after indent)
#   prose lists     ->  `` `key` ``        (backticked, possibly `a`/`b`/`c`)
#
# `args` is dropped: it is the object's own name in `args: {`, not a member.
SITE_KEYS_AWK='
{
    line = $0
    if (match(line, /^[[:space:]]*[A-Za-z][A-Za-z0-9]*:/)) {
        k = substr(line, RSTART, RLENGTH - 1)
        gsub(/^[[:space:]]+/, "", k)
        if (k != "args") print k
    }
    while (match(line, /`[A-Za-z][A-Za-z0-9]*`/)) {
        k = substr(line, RSTART + 1, RLENGTH - 2)
        if (k != "args") print k
        line = substr(line, RSTART + RLENGTH)
    }
}
'

# site_keys <contract-id> <file> — the keys named at a site, sorted unique.
site_keys() {
    local id="$1" file="$2" region
    region="$(extract_contract "$id" "$SHIP_DIR/$file")" || return 1
    command printf '%s\n' "$region" | command awk "$SITE_KEYS_AWK" | command sort -u
}

# --- Checking ----------------------------------------------------------------

# check_site <contract-id> <file> <expected>
# Populates CUR_VIOLATIONS with one line per problem (empty when the site is
# clean). Both arms report the SITE and the KEY, so a failure is actionable
# without opening the file to work out which list is wrong.
CUR_VIOLATIONS=""
check_site() {
    local id="$1" file="$2" expected="$3"
    CUR_VIOLATIONS=""

    local authority named
    authority="$(known_arg_keys | command sort -u)"
    if ! named="$(site_keys "$id" "$file" 2>/dev/null)"; then
        CUR_VIOLATIONS="$file [$id]: contract could not be extracted (marker missing, renamed or duplicated)"
        return
    fi

    # A site that parses to nothing is a broken extractor, not a clean site —
    # and it would make the superset arm pass over an empty set. Fail loud.
    if [ -z "$named" ]; then
        CUR_VIOLATIONS="$file [$id]: named NO keys — the extractor stopped matching this site's spelling"
        return
    fi

    local k
    # superset: nothing invented
    for k in $named; do
        if ! command printf '%s\n' "$authority" | command grep -qxF "$k"; then
            CUR_VIOLATIONS="${CUR_VIOLATIONS}${CUR_VIOLATIONS:+
}$file [$id]: names \`$k\`, which is NOT in KNOWN_ARG_KEYS — the harness throws on it (#597)"
        fi
    done
    # subset: nothing missing
    for k in $expected; do
        if ! command printf '%s\n' "$named" | command grep -qxF "$k"; then
            CUR_VIOLATIONS="${CUR_VIOLATIONS}${CUR_VIOLATIONS:+
}$file [$id]: is missing \`$k\` — a caller reading this list never passes it, and the harness silently uses the empty default"
        fi
    done
}

# --- Tests -------------------------------------------------------------------

# The authority must parse. Everything else compares against it, so an empty or
# truncated extraction would make the whole gate vacuous — the single most
# likely way this file rots into reporting green while checking nothing.
test_authority_parses() {
    local keys count
    keys="$(known_arg_keys)"
    count="$(command printf '%s\n' "$keys" | command grep -c . || true)"
    assert_true "[ $count -ge 10 ]" \
        "KNOWN_ARG_KEYS extracted from workflow.js ($count keys) — not a vacuous empty set"
    assert_contains "$keys" "phase" "The extracted authority carries \`phase\`"
    assert_contains "$keys" "reviewRoute" \
        "The extracted authority carries \`reviewRoute\` (#550) — the key whose prose drift motivated this gate"
    assert_true "[ -f '$HARNESS_JS' ]" "The authority file exists at the path the gate reads"
}

# Per-site, dispatched from the SITES table below.
CUR_ID=""
CUR_FILE=""
CUR_EXPECTED=""
test_site() {
    check_site "$CUR_ID" "$CUR_FILE" "$CUR_EXPECTED"
    assert_equals "" "$CUR_VIOLATIONS" \
        "$CUR_FILE [$CUR_ID]: prose key list agrees with KNOWN_ARG_KEYS"
}

# --- Negative fixtures -------------------------------------------------------
#
# Driven against PLANTED corpora, never the real tree. A list gate over a clean
# tree is green whether or not its comparison exists — which is precisely how a
# gate ships inert (the lint-prose-budget.sh precedent).

# plant_site <dir> <file> <keys> — write a minimal marked-up fixture.
plant_site() {
    local dir="$1" file="$2" keys="$3" k
    command mkdir -p "$dir"
    {
        command printf '1. **A step** — prose above the region.\n\n'
        command printf '   <!-- contract: planted -->\n\n'
        for k in $keys; do command printf '   `%s`,\n' "$k"; done
        command printf '\n   <!-- contract: end-planted -->\n'
    } >"$dir/$file"
}

test_invented_key_is_caught() {
    local d
    d="$(command mktemp -d)"
    plant_site "$d" p.md "phase cycle argsFile"
    SHIP_DIR="$d" check_site planted p.md "phase cycle"
    assert_contains "$CUR_VIOLATIONS" "argsFile" \
        "superset arm: an invented key is reported, and NAMED"
    assert_contains "$CUR_VIOLATIONS" "planted" \
        "superset arm: the offending SITE is named (#886 AC#2)"
    command rm -rf "$d"
}

test_missing_key_is_caught() {
    local d
    d="$(command mktemp -d)"
    # The #550 shape exactly: a real list that simply lacks one member.
    plant_site "$d" p.md "phase cycle maxCycles"
    SHIP_DIR="$d" check_site planted p.md "phase cycle maxCycles reviewRoute"
    assert_contains "$CUR_VIOLATIONS" "reviewRoute" \
        "subset arm: an expected-but-missing key is reported (the direction #597 is blind to)"
    assert_contains "$CUR_VIOLATIONS" "planted" \
        "subset arm: the offending SITE is named (#886 AC#2)"
    command rm -rf "$d"
}

# The arms must be INDEPENDENT. A single check that happened to fire on both
# fixtures could still be one-directional — the #886 body calls out that a
# one-way check would have passed the #722 defect.
test_arms_are_independent() {
    local d
    d="$(command mktemp -d)"
    # Superset-only violation: nothing missing, one invented.
    plant_site "$d" p.md "phase cycle bogusKey"
    SHIP_DIR="$d" check_site planted p.md "phase cycle"
    assert_contains "$CUR_VIOLATIONS" "bogusKey" \
        "arms: an invented key alone fires (no missing key present)"
    assert_not_contains "$CUR_VIOLATIONS" "is missing" \
        "arms: the superset case does not also report a phantom missing key"
    # Subset-only violation: nothing invented, one missing.
    plant_site "$d" q.md "phase"
    SHIP_DIR="$d" check_site planted q.md "phase cycle"
    assert_contains "$CUR_VIOLATIONS" "is missing" \
        "arms: a missing key alone fires (no invented key present)"
    assert_not_contains "$CUR_VIOLATIONS" "NOT in KNOWN_ARG_KEYS" \
        "arms: the subset case does not also report a phantom invented key"
    command rm -rf "$d"
}

test_clean_site_is_silent() {
    local d
    d="$(command mktemp -d)"
    plant_site "$d" p.md "phase cycle maxCycles"
    SHIP_DIR="$d" check_site planted p.md "phase cycle"
    assert_equals "" "$CUR_VIOLATIONS" \
        "a site naming a superset of its expected set, all real, is clean"
    command rm -rf "$d"
}

# An unparseable site must FAIL, not read as clean. Without this the gate would
# quietly stop checking a site the day someone reformats it — the silent-inert
# mode that motivated the 77 sentinel elsewhere in this suite.
test_unparseable_site_fails_loud() {
    local d
    d="$(command mktemp -d)"
    command mkdir -p "$d"
    command printf '   <!-- contract: planted -->\n\n   no keys here at all\n\n   <!-- contract: end-planted -->\n' >"$d/p.md"
    SHIP_DIR="$d" check_site planted p.md "phase"
    assert_contains "$CUR_VIOLATIONS" "named NO keys" \
        "a site whose spelling stopped matching fails loudly rather than passing empty"
    command rm -rf "$d"
}

test_missing_marker_fails_loud() {
    local d
    d="$(command mktemp -d)"
    command mkdir -p "$d"
    command printf 'no markers in this file\n' >"$d/p.md"
    SHIP_DIR="$d" check_site planted p.md "phase"
    assert_contains "$CUR_VIOLATIONS" "could not be extracted" \
        "a deleted/renamed contract marker fails loudly rather than silently checking nothing"
    command rm -rf "$d"
}

# Both key spellings must be recognized. If the fenced-block arm regressed, the
# two protocol sites would read as empty; if the backticked arm regressed, the
# summary sites would. Either way the gate keeps reporting green on the other
# half, which is why this is pinned directly.
test_both_key_spellings_parse() {
    local d out
    d="$(command mktemp -d)"
    command mkdir -p "$d"
    {
        command printf '<!-- contract: planted -->\n\n'
        command printf '```text\nargs: {\n  phase: "pre-pr",\n  cycle: 1,\n}\n```\n\n'
        command printf 'and inline: `maxCycles`, `preScan`.\n\n'
        command printf '<!-- contract: end-planted -->\n'
    } >"$d/p.md"
    out="$(SHIP_DIR="$d" site_keys planted p.md)"
    assert_contains "$out" "phase" "fenced-block spelling (\`key: <…>\`) is parsed"
    assert_contains "$out" "maxCycles" "backticked prose spelling is parsed"
    assert_not_contains "$out" "args" \
        "the object's own name \`args\` is not mistaken for a member key"
    command rm -rf "$d"
}

# The #567 counter-example lives one paragraph past the accepted-set region.
# Contract markers are what keep it out; a paragraph- or heading-bounded anchor
# would swallow it and report `argsFile` as an invented key. Pin that the region
# boundary genuinely excludes it, or the anchoring choice silently rots.
test_region_excludes_the_counterexample() {
    local region
    region="$(extract_contract args-keys-accepted-set "$SHIP_DIR/pre-ship-validation.md")"
    assert_not_empty "$region" "the accepted-set region extracts"
    assert_not_contains "$region" "argsFile" \
        "the accepted-set region stops before the #567 \`argsFile\` counter-example"
    # ...and prove the counter-example is really there, or the assertion above
    # would pass against prose that simply never mentioned it.
    assert_file_contains "$SHIP_DIR/pre-ship-validation.md" "argsFile" \
        "the counter-example genuinely exists in the file (assertion is not vacuous)"
}

test_missing_awk_exits_77() {
    local sliced
    sliced="$(command mktemp)"
    {
        command printf 'set -euo pipefail\n'
        command printf 'source "%s/lib/harness.sh"\n' "$SCRIPT_DIR"
        command printf 'test_suite "sliced"\n'
        # Force the probe to miss regardless of the ambient PATH: shadow the
        # lookup itself with a `command -v awk` that fails. This models "awk
        # absent" without touching PATH at all (and without a stub farm, which
        # would die 127 at the next tool the harness happens to call).
        command printf 'command() { if [ "$1" = "-v" ] && [ "$2" = "awk" ]; then return 1; fi; builtin command "$@"; }\n'
        # The real branch, sliced from the SKIP_EXIT_CODE assignment through the
        # `fi`. Starting at the constant (not the `if`) means the slice carries
        # the sentinel VALUE, so changing 77 to something else is caught here
        # rather than silently redefined.
        command sed -n '/^SKIP_EXIT_CODE=77$/,/^fi$/p' "$SELF_PATH"
        command printf 'command printf "REACHED_AFTER\\n"\n'
    } >"$sliced"

    # Guard the slice: a broken sed would make the probe pass for the wrong reason.
    assert_contains "$(command cat "$sliced")" "SKIP_EXIT_CODE" \
        "The real awk-probe branch was sliced out (probe is not vacuous)"

    local out rc=0
    out="$(command bash "$sliced" 2>&1)" || rc=$?

    assert_equals "77" "$rc" \
        "With awk absent the gate exits the reserved SKIP sentinel 77, never 0"
    assert_contains "$out" "GATE DID NOT RUN" \
        "The skip is explicit about not having run (not a silent pass)"
    assert_not_contains "$out" "REACHED_AFTER" \
        "The branch EXITS rather than falling through to scan with no awk"
    # assert_file_defines, not assert_file_contains (#830): the comment above
    # the constant explains the sentinel, so a raw-text check stays green even
    # if the assignment itself were deleted.
    assert_file_defines "$SELF_PATH" "SKIP_EXIT_CODE" "77" \
        "The skip sentinel is the reserved 77 that run-all.sh renders as [SKIP]"

    command rm -f "$sliced"
}

run_test test_authority_parses "KNOWN_ARG_KEYS is extracted from workflow.js, non-vacuously"
run_test test_both_key_spellings_parse "Both fenced and backticked key spellings are parsed"
run_test test_invented_key_is_caught "An invented prose key is caught, with the site named"
run_test test_missing_key_is_caught "An expected-but-missing key is caught, with the site named"
run_test test_arms_are_independent "The superset and subset arms fire independently"
run_test test_clean_site_is_silent "A clean site produces no violations"
run_test test_unparseable_site_fails_loud "A site that stopped parsing fails loudly, not empty"
run_test test_missing_marker_fails_loud "A deleted/renamed contract marker fails loudly"
run_test test_region_excludes_the_counterexample "The accepted-set region excludes the argsFile counter-example"
run_test test_missing_awk_exits_77 "With awk absent the gate exits 77, not 0"

# The real corpus, one test per site. The site count is asserted below so a row
# silently lost from SITES cannot shrink the gate unnoticed.
SITE_COUNT=0
while IFS='|' read -r id file expected; do
    [ -n "$id" ] || continue
    CUR_ID="$id"
    CUR_FILE="$file"
    CUR_EXPECTED="$expected"
    SITE_COUNT=$((SITE_COUNT + 1))
    run_test test_site "$file [$id]: key list agrees with KNOWN_ARG_KEYS"
done <<EOF
$(command printf '%s\n' "$SITES" | command grep .)
EOF

# Guard by COUNT, not merely "the loop ran": a table row deleted in a refactor
# would otherwise remove a site's coverage while the suite still reported green
# (the test-defined-but-never-registered shape, one level up).
test_every_site_ran() {
    assert_equals "6" "$SITE_COUNT" \
        "All six prose sites were checked (#886 counts six copies of the list)"
}
run_test test_every_site_ran "Every one of the six prose sites was checked"

generate_report
