#!/usr/bin/env bash
# OWASP Top 10 coverage-map gate (#706, epic #705).
#
# WHAT IT PROTECTS. This repo claims OWASP coverage in two places —
# audit-security.md's frontmatter ("OWASP patterns") and code-reviewer's
# SUBREVIEWERS.security bullet ("OWASP Top 10 vulnerabilities") — and until
# owasp-coverage.yml existed, neither claim mapped a single scanner category to
# an A0x id. An unfalsifiable claim cannot regress visibly: a detector could be
# renamed, or a whole category quietly dropped, and every gate in the suite would
# stay green while the advertised coverage silently shrank.
#
# THE FOUR RULES (the issue's ACs, in order):
#
#   1. Every A01-A10 id present EXACTLY once — missing or duplicated fails.
#   2. Every `owner: prescan` id is a category the scanners ACTUALLY emit, and
#      every emitted category is mapped. BOTH DIRECTIONS, deliberately: the
#      forward half catches a claim with no detector; the reverse half is what
#      makes a RENAMED detector fail loudly instead of drifting into an
#      unmapped-but-shipping category.
#   3. Every `llm-pass2` / `reviewer` id is backed by real text in the
#      corresponding checklist — a claim with no backing text fails.
#   4. Every `gap` carries a non-empty `reason`.
#
# NOT A TAUTOLOGY, BY CONSTRUCTION. The issue flags the trap directly: the
# artifact that ARMS rule 2 must not be the artifact that SATISFIES it. So the
# emitted-category set is derived from the SCANNER SOURCE (patterns.py +
# patterns.sh) and asserted against the YML — two independent files. A fixture
# corpus would have been the other option and is the worse one here: it can only
# cover the categories the fixtures happen to trigger, and the fixture would then
# be both the input and the evidence.
#
# WHY REGEX EXTRACTION AND NOT AN ARG-POSITION PARSE. patterns.py's emit() calls
# come in two shapes — single-line, and wrapped across five lines with the
# category literal alone on its own line. A parser keyed to `emit(path, idx,
# "<cat>"` matches only the first shape and silently misses six of the wrapped
# ones, under-reporting the emitted set (which fails OPEN on the forward half:
# fewer emitted categories means fewer things rule 2 can object to). The
# quoted-kebab-slug extraction below is the same idiom
# validate-scanner-category-parity.sh already uses for exactly this reason, and
# it is shape-independent.
#
# NEVER `printf … | grep -q` UNDER `set -o pipefail` (found live, #709). Both
# membership tests below use a here-string instead, and the reason is a false
# FAIL this gate actually produced: `grep -q` exits at its FIRST match, which
# SIGPIPEs the still-writing `printf` (141), and `pipefail` reports the pipeline
# as failed — so a category that IS emitted gets reported as missing. The tell is
# an evidence line that contradicts its own message ("no scanner emits
# 'command-injection'" directly above an emitted list containing it).
#
# It is INTERMITTENT by construction: with a short list the write fits the pipe
# buffer and completes before grep exits, so it passes. Measured — 1 failure in
# ~30 runs here, and 400/400 once the write is large enough not to fit. That
# rarity is the danger: a maintainer sees a one-off red, re-runs it green, and
# files it as noise. A here-string has no second process and no pipe status.
#
# PURE BASH + coreutils. No sed for the YAML — the parser is modelled on
# read_yaml_list in ship-issue/pre-review-gates.sh, for the reason recorded
# there: BSD sed (macOS default) rejects multi-command brace blocks and reads \s
# as a literal, and because such a call is usually written with 2>/dev/null the
# failure is INVISIBLE — every key parses to empty and the gate reports a clean
# map it never actually read. bash-3.2 clean, POSIX bracket classes only
# (CLAUDE.md § runtime policy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# Overridable so the self-tests below can drive the WHOLE gate path over a
# fixture rather than only exercising the helper functions. A self-test that
# calls helpers directly proves the helpers work; it cannot prove they are
# wired into the assertions, which is the failure that leaves a gate inert.
SKILL_DIR="${OWASP_SKILL_DIR:-$REPO_ROOT/plugins/review-audit/skills/check-security}"
COVERAGE_YML="${OWASP_COVERAGE_YML:-$SKILL_DIR/owasp-coverage.yml}"
PATTERNS_PY="${OWASP_PATTERNS_PY:-$SKILL_DIR/patterns.py}"
PATTERNS_SH="${OWASP_PATTERNS_SH:-$SKILL_DIR/patterns.sh}"
# The Pass-2 checklist moved out of agents/audit-security.md into a companion
# beside this map (#709) — the agent had grown past its 400-line budget, and the
# checklist is the half that pairs with owasp-coverage.yml rather than with the
# agent's dispatch mechanics. Rule 3 reads THIS file for llm-pass2 backing text.
PASS2_DOC="${OWASP_PASS2_DOC:-$SKILL_DIR/pass2-checklist.md}"
REVIEWER_JS="${OWASP_REVIEWER_JS:-$REPO_ROOT/plugins/dev-core/agents/code-reviewer/workflow.js}"

# The ten 2021 ids. Hardcoded ON PURPOSE: this is the external standard the map
# is measured against, so deriving it from the map under test would make rule 1
# vacuous (the map would define its own completeness).
OWASP_IDS="A01 A02 A03 A04 A05 A06 A07 A08 A09 A10"

# Category slug shape — the same expression validate-scanner-category-parity.sh
# uses, so the two gates cannot disagree about what a category literal looks like.
_SLUG_RX='"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"'

# Sentinel id emitted for a category entry whose `- id:` carries no value.
# Deliberately un-spellable as a real slug, so it can never collide with a
# genuine id and be mistaken for one.
MALFORMED_ID="<MALFORMED-EMPTY-ID>"

# --- YAML reading (pure bash, no sed) ---------------------------------------

# top_level_ids FILE — every top-level key, in file order, one per line.
# A key is a line starting in column 0 with a letter, ending in `:`.
top_level_ids() {
    local file="$1" line
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            [A-Za-z]*:) command printf '%s\n' "${line%%:*}" ;;
        esac
    done <"$file"
}

# entries_of FILE — one `owner|id|reason_present` record per category entry,
# across the whole file. Emitted as a flat stream rather than per-A0x because
# every rule below is a property of an ENTRY, not of the block containing it.
#
# The parse tracks a partial record and flushes it when the next `- id:` starts
# or the file ends. `reason_present` is `1` only for a reason with a non-empty
# value after quote-stripping — `reason: ""` must read as absent, which is the
# whole point of rule 4 and is exactly what a naive `grep -q reason:` gets wrong.
entries_of() {
    local file="$1" line stripped id owner reason_present
    [ -f "$file" ] || return 0
    id=""
    owner=""
    reason_present=0
    saw_id=0

    # A blank `- id:` must FAIL LOUDLY, not vanish (#706 review cycle 2). The
    # earlier `[ -n "$id" ] || return 0` dropped such an entry from the stream
    # entirely, so every rule below iterated past it and the gate went green on
    # a malformed map — the exact silent-drop failure this file exists to
    # prevent for scanner categories, reproduced in the map's own parser.
    # Measured: blanking one id passed the whole gate.
    #
    # `saw_id` distinguishes "no entry started yet" (the legitimate initial
    # flush, and any pre-entry prose) from "an entry started with no id", which
    # is the malformed case. Emitting a sentinel rather than calling _fail keeps
    # this a pure parser — the assertion lives with the other rules.
    _flush() {
        if [ -n "$id" ]; then
            command printf '%s|%s|%s\n' "$owner" "$id" "$reason_present"
        elif [ "$saw_id" = "1" ]; then
            command printf '%s|%s|%s\n' "$owner" "$MALFORMED_ID" "$reason_present"
        fi
    }

    while IFS= read -r line || [ -n "$line" ]; do
        # Strip leading whitespace once; every key below is nested.
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in
            '#'*) continue ;;
            '- id:'*)
                _flush
                id="$(_yaml_value "${stripped#- id:}")"
                saw_id=1
                owner=""
                reason_present=0
                ;;
            'owner:'*) owner="$(_yaml_value "${stripped#owner:}")" ;;
            'reason:'*)
                if [ -n "$(_yaml_value "${stripped#reason:}")" ]; then
                    reason_present=1
                fi
                ;;
        esac
    done <"$file"
    _flush
}

# evidence_for FILE ID — the `evidence:` value for entry ID, empty when absent.
# Separate pass rather than a fifth field on the record above: an evidence string
# is free prose that can contain the `|` this record format delimits on.
evidence_for() {
    local file="$1" want="$2" line stripped id ev
    [ -f "$file" ] || return 0
    id=""
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in
            '- id:'*) id="$(_yaml_value "${stripped#- id:}")" ;;
            'evidence:'*)
                ev="$(_yaml_value "${stripped#evidence:}")"
                if [ "$id" = "$want" ]; then
                    command printf '%s\n' "$ev"
                    return 0
                fi
                ;;
        esac
    done <"$file"
}

# _yaml_value RAW — trim surrounding whitespace, then ONE layer of surrounding
# quotes. Leading and trailing quotes are stripped independently, matching
# read_yaml_list's two-expression behaviour.
_yaml_value() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        \"*) v="${v#\"}" ;;
        \'*) v="${v#\'}" ;;
    esac
    case "$v" in
        *\") v="${v%\"}" ;;
        *\') v="${v%\'}" ;;
    esac
    command printf '%s' "$v"
}

# --- Emitted-category derivation (from scanner SOURCE) ----------------------

# emitted_categories — the sorted union of category slugs both scanner impls
# declare. Union, not intersection: parity between the two impls is
# validate-scanner-category-parity.sh's job, and duplicating it here would mean
# two gates that must agree about the same fact.
# `|| true` on each arm is load-bearing under `set -euo pipefail` (#706 review
# cycle 3). A `{ ...; }` group returns the status of its LAST command, so when
# patterns.sh has zero slug matches (grep exits 1) the group exits 1, and with
# `pipefail` the whole pipeline does too — even though patterns.py matched fine.
# Today every call site sits inside a `run_test` body, which the harness invokes
# as `if "$test_func"`, and that suspends `set -e`: the abort becomes a reported
# FAIL rather than a silent exit, which is why this was never observable (probed
# both ways — the construct DOES abort in a bare `set -e` script, and does not
# here). That makes this hardening, not a live bug fix: it stops the function's
# correctness from depending on where it happens to be called from, so a future
# call outside a test body cannot turn "one scanner has no matches yet" into a
# gate that exits with no report. An empty set is rule 0's job to report.
emitted_categories() {
    {
        [ -f "$PATTERNS_PY" ] && { command grep -oE "$_SLUG_RX" "$PATTERNS_PY" 2>/dev/null || true; }
        [ -f "$PATTERNS_SH" ] && { command grep -oE "$_SLUG_RX" "$PATTERNS_SH" 2>/dev/null || true; }
    } | command tr -d '"' | command sort -u
}

# --- Backing-text lookup ----------------------------------------------------

# backing_text ID FILE — the literal an entry claims, defaulting to the id.
backing_for() {
    local id="$1" ev
    ev="$(evidence_for "$COVERAGE_YML" "$id")"
    if [ -n "$ev" ]; then command printf '%s' "$ev"; else command printf '%s' "$id"; fi
}

# has_backing TEXT FILE — fixed-string, never a regex. Evidence strings are
# author-supplied prose containing `(`, `)` and `,`; building a pattern out of
# one means escaping it, and a backslash-escaped `( ) |` means OPPOSITE things
# in BRE and ERE (GNU-only operators vs literals on BSD). grep -F has no pattern
# to escape, so the whole dialect class is sidestepped.
has_backing() {
    command grep -qF "$1" "$2" 2>/dev/null
}

test_suite "OWASP Top 10 coverage map (#706)"

# --- Rule 0: anti-vacuity ---------------------------------------------------
# Every rule below iterates a parsed set. A misparse yields EMPTY sets, over
# which every "for each entry, assert X" loop passes trivially — the specific way
# a gate rots into reporting green while checking nothing.

test_map_exists_and_parses() {
    assert_file_exists "$COVERAGE_YML" "owasp-coverage.yml exists"
    # Both backing-text targets, asserted BY NAME (#709). Rule 3 would already
    # fail if either vanished — has_backing greps with 2>/dev/null, so a missing
    # file makes every claim report unbacked — but it would blame each claim
    # rather than the moved file, sending the reader to fix N checklist entries
    # that were never wrong. This turns one relocation into one message.
    assert_file_exists "$PASS2_DOC" "the Pass-2 checklist companion resolves"
    assert_file_exists "$REVIEWER_JS" "the reviewer harness resolves"
    [ -f "$COVERAGE_YML" ] || return 0

    local ids entries emitted
    ids="$(top_level_ids "$COVERAGE_YML")"
    entries="$(entries_of "$COVERAGE_YML")"
    emitted="$(emitted_categories)"

    assert_not_empty "$ids" "the map parses to a non-empty set of A0x ids"
    assert_not_empty "$entries" "the map parses to a non-empty set of category entries"
    assert_not_empty "$emitted" \
        "the scanner source yields a non-empty emitted-category set (rule 2 is armed)"
}
run_test test_map_exists_and_parses "map and scanner source both parse non-empty"

# --- Rule 1: all ten ids, exactly once --------------------------------------

test_all_ten_ids_present_once() {
    local ids id count
    ids="$(top_level_ids "$COVERAGE_YML")"
    for id in $OWASP_IDS; do
        count="$(command printf '%s\n' "$ids" | command grep -cx "$id" || true)"
        assert_equals "1" "$count" "$id present exactly once in the coverage map"
    done
}
run_test test_all_ten_ids_present_once "rule 1: every A01-A10 id present exactly once"

# --- Rule 2: prescan ids <-> categories the scanners actually emit ----------

test_prescan_ids_are_emitted() {
    local emitted owner id
    emitted="$(emitted_categories)"
    while IFS='|' read -r owner id _; do
        [ "$owner" = "prescan" ] || continue
        if command grep -qx "$id" <<<"$emitted"; then
            :
        else
            _fail "prescan category '$id' is claimed but no scanner emits it" \
                "emitted: $(command printf '%s' "$emitted" | command tr '\n' ' ')"
        fi
    done <<EOF
$(entries_of "$COVERAGE_YML")
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "every prescan id is emitted by the scanners"
}
run_test test_prescan_ids_are_emitted "rule 2a: every prescan id is a category the scanners emit"

# The reverse direction, and the half that carries the real teeth. Without it a
# RENAMED detector passes: the old slug simply stops being claimed by anything,
# and nothing notices that a shipping category is unmapped.
test_emitted_categories_are_mapped() {
    local emitted claimed cat
    emitted="$(emitted_categories)"
    # A POSITIVE ALLOWLIST, not the negation of `gap` (#706 review cycle 2): a
    # blank or unknown owner is `!= "gap"` and would therefore have counted as
    # "mapped" here, quietly disagreeing with the owner-vocabulary rule that
    # rejects it. Listing the three real owners keeps the two rules from drifting
    # apart if either is ever reordered or skipped.
    #
    # Owner-scoped ON PURPOSE (#706 review): a `gap` entry is deliberately named
    # after the slug its future detector will use, so counting gap ids as
    # "mapped" would let a shipping detector be absorbed by the very entry
    # claiming it does not exist — the map would keep asserting a gap, with a
    # stale "see #707" reason, and no rule would object. Excluding gap ids means
    # the moment slice B emits `ssrf`, this rule fires until the owner is flipped
    # to `prescan`. Measured: with an unscoped set the simulated detector passed
    # the whole gate silently.
    claimed="$(entries_of "$COVERAGE_YML" |
        command awk -F'|' '$1 == "prescan" || $1 == "llm-pass2" || $1 == "reviewer" { print $2 }' | command sort -u)"
    while IFS= read -r cat; do
        [ -n "$cat" ] || continue
        if command grep -qx "$cat" <<<"$claimed"; then
            :
        else
            _fail "scanner emits category '$cat' but the coverage map does not mention it" \
                "a new or renamed detector must be added to owasp-coverage.yml"
        fi
    done <<EOF
$emitted
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "every emitted category appears in the map"
}
run_test test_emitted_categories_are_mapped "rule 2b: every emitted category is mapped (catches a rename)"

# --- Rule 3: llm-pass2 / reviewer claims are backed by real text -------------

test_claims_have_backing_text() {
    local owner id text file
    while IFS='|' read -r owner id _; do
        case "$owner" in
            llm-pass2) file="$PASS2_DOC" ;;
            reviewer) file="$REVIEWER_JS" ;;
            *) continue ;;
        esac
        text="$(backing_for "$id")"
        if has_backing "$text" "$file"; then
            :
        else
            _fail "$owner category '$id' claims coverage with no backing text" \
                "looked for the literal: $text" \
                "in: ${file#"$REPO_ROOT"/}"
        fi
    done <<EOF
$(entries_of "$COVERAGE_YML")
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "every llm-pass2/reviewer claim is backed"
}
run_test test_claims_have_backing_text "rule 3: llm-pass2 / reviewer claims appear in their checklist"

# --- Rule 4: every gap carries a reason -------------------------------------

test_gaps_have_reasons() {
    local owner id reason_present
    while IFS='|' read -r owner id reason_present; do
        [ "$owner" = "gap" ] || continue
        if [ "$reason_present" = "1" ]; then
            :
        else
            _fail "gap category '$id' has no non-empty reason" \
                "an acknowledged gap must say why, and name its follow-up issue"
        fi
    done <<EOF
$(entries_of "$COVERAGE_YML")
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "every gap entry carries a reason"
}
run_test test_gaps_have_reasons "rule 4: every gap carries a non-empty reason"

# --- Owner vocabulary -------------------------------------------------------
# A typo'd owner (`prescn`) would otherwise match no rule's filter and sail
# through every check above unexamined — a silent exemption from the whole gate.

test_owners_are_known() {
    local owner id
    while IFS='|' read -r owner id _; do
        case "$owner" in
            prescan | llm-pass2 | reviewer | gap) ;;
            *) _fail "category '$id' has unknown owner '$owner'" \
                "valid owners: prescan, llm-pass2, reviewer, gap" ;;
        esac
    done <<EOF
$(entries_of "$COVERAGE_YML")
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "every entry has a known owner"
}
run_test test_owners_are_known "every entry's owner is one of the four known values"

# The parser-level counterpart to the rules above: an entry whose id blanked out
# must be reported, not silently skipped.
test_no_malformed_entries() {
    local owner id
    while IFS='|' read -r owner id _; do
        [ "$id" = "$MALFORMED_ID" ] || continue
        _fail "a category entry has an empty '- id:' value" \
            "it would otherwise vanish from every rule in this gate"
    done <<EOF
$(entries_of "$COVERAGE_YML")
EOF
    [ "$TEST_STATUS" = "failed" ] || assert_true "true" "no category entry has a blank id"
}
run_test test_no_malformed_entries "every category entry has a non-empty id"

# --- Self-tests: the negative fixtures MUST fire -----------------------------
#
# Everything above is green over the real tree, which by itself proves nothing:
# a gate whose predicates never fire is green too, and indistinguishable. These
# drive the WHOLE gate — a recursive invocation with the OWASP_* roots pointed at
# a fixture — rather than calling the helpers directly, because a helper-level
# self-test cannot show the helper is actually WIRED INTO an assertion.
#
# Each fixture differs from `valid/` by exactly ONE defect, so a fixture that
# fires proves the rule it targets rather than "something was wrong somewhere".
# `valid/` is the positive control: without it, a gate that failed unconditionally
# would pass every negative self-test below.

FIXROOT="$SCRIPT_DIR/fixtures/owasp-coverage"
SHARED="$FIXROOT/_shared"

# run_over_fixture DIR — run this gate recursively against a fixture map, with
# the scanner and checklist roots pointed at the stubs. Prints the output; the
# exit status is the fixture's verdict.
#
# OWASP_SELFTEST guards against infinite recursion: the child sets it, and the
# self-tests are skipped when it is set.
# A fixture may ship its OWN scanner stubs (gap-absorbs does, to simulate a
# future detector landing); otherwise it uses the shared pair. Per-fixture
# override rather than a second shared stub set: the defect under test is a
# relationship between one map and one scanner, so they belong together.
run_over_fixture() {
    local py="$SHARED/patterns.py" sh="$SHARED/patterns.sh"
    [ -f "$FIXROOT/$1/patterns.py" ] && py="$FIXROOT/$1/patterns.py"
    [ -f "$FIXROOT/$1/patterns.sh" ] && sh="$FIXROOT/$1/patterns.sh"
    OWASP_SELFTEST=1 \
        OWASP_COVERAGE_YML="$FIXROOT/$1/owasp-coverage.yml" \
        OWASP_PATTERNS_PY="$py" \
        OWASP_PATTERNS_SH="$sh" \
        OWASP_PASS2_DOC="$SHARED/pass2.md" \
        OWASP_REVIEWER_JS="$SHARED/reviewer.js" \
        bash "$SCRIPT_DIR/validate-owasp-coverage.sh" 2>&1
}

if [ -n "${OWASP_SELFTEST:-}" ]; then
    generate_report
    exit
fi

test_selftest_valid_fixture_passes() {
    local out
    if out="$(run_over_fixture valid)"; then
        assert_true "true" "the well-formed fixture passes clean (gate is not fail-always)"
    else
        _fail "the valid fixture FAILED — the gate rejects a well-formed map" \
            "$(command printf '%s' "$out" | command tail -n 20)"
    fi
}
run_test test_selftest_valid_fixture_passes "self-test: the valid fixture passes clean"

# assert_fixture_fires DIR EXPECTED_TEXT MESSAGE — the fixture must FAIL, and
# must fail for the stated reason. The text check is what stops a fixture from
# passing this self-test by tripping some unrelated rule.
assert_fixture_fires() {
    local dir="$1" expected="$2" msg="$3" out
    if out="$(run_over_fixture "$dir")"; then
        _fail "$msg — but the fixture PASSED (the rule has no teeth)"
        return 0
    fi
    assert_contains "$out" "$expected" "$msg"
}

test_selftest_missing_id_fires() {
    assert_fixture_fires missing-a0x "A07 present exactly once" \
        "rule 1 must fire on a map with a deleted A0x block"
}
run_test test_selftest_missing_id_fires "self-test: a deleted A0x block fails rule 1"

test_selftest_renamed_category_fires() {
    assert_fixture_fires renamed-category "injection-risk-renamed" \
        "rule 2a must fire on a prescan id no scanner emits"
}
run_test test_selftest_renamed_category_fires "self-test: an unemitted prescan id fails rule 2a"

test_selftest_unmapped_emitted_fires() {
    assert_fixture_fires unmapped-emitted "scanner emits category 'injection-risk'" \
        "rule 2b must fire on an emitted category the map omits"
}
run_test test_selftest_unmapped_emitted_fires "self-test: an unmapped emitted category fails rule 2b"

test_selftest_unbacked_claim_fires() {
    assert_fixture_fires unbacked-claim "not-in-the-checklist" \
        "rule 3 must fire on a claim with no backing checklist text"
}
run_test test_selftest_unbacked_claim_fires "self-test: an unbacked llm-pass2 claim fails rule 3"

test_selftest_empty_reason_fires() {
    assert_fixture_fires empty-reason "has no non-empty reason" \
        "rule 4 must fire on a gap whose reason is the empty string"
}
run_test test_selftest_empty_reason_fires "self-test: an empty gap reason fails rule 4"

test_selftest_duplicate_id_fires() {
    assert_fixture_fires duplicate-a0x "A03 present exactly once" \
        "rule 1 must fire on a DUPLICATED A0x id, not only a missing one"
}
run_test test_selftest_duplicate_id_fires "self-test: a duplicated A0x block fails rule 1"

# Rule 3 has two branches keyed by owner, reading two different files. The
# unbacked-claim fixture exercises only the llm-pass2 one; a regression that
# miswired the reviewer branch's file or evidence lookup would be invisible.
test_selftest_unbacked_reviewer_fires() {
    assert_fixture_fires unbacked-reviewer "no backing text" \
        "rule 3 must fire on an unbacked REVIEWER claim, not only an llm-pass2 one"
}
run_test test_selftest_unbacked_reviewer_fires "self-test: an unbacked reviewer claim fails rule 3"

test_selftest_bad_owner_fires() {
    assert_fixture_fires bad-owner "unknown owner 'prescn'" \
        "the owner-vocabulary rule must fire on a typo'd owner"
}
run_test test_selftest_bad_owner_fires "self-test: a typo'd owner value is rejected"

# The F1 regression directly: a fixture whose scanner stub emits a slug the map
# still tags `owner: gap`. Without the owner-scoping above this passes, which is
# precisely the silent drift the map exists to prevent.
test_selftest_gap_cannot_absorb_detector() {
    assert_fixture_fires gap-absorbs "scanner emits category 'command-injection'" \
        "a gap-owned id must NOT count as mapped once a detector emits it"
}
run_test test_selftest_gap_cannot_absorb_detector "self-test: a gap cannot absorb a shipping detector"

test_selftest_blank_id_fires() {
    assert_fixture_fires blank-id "empty '- id:' value" \
        "a blanked id must fail loudly rather than vanish from every rule"
}
run_test test_selftest_blank_id_fires "self-test: a blank category id fails loudly"

# The owner-vocabulary rule has two shapes: a typo'd value (bad-owner) and an
# omitted key. They reach the failure through different code paths.
test_selftest_missing_owner_fires() {
    assert_fixture_fires missing-owner "unknown owner ''" \
        "an entry with no owner: key at all must be rejected"
}
run_test test_selftest_missing_owner_fires "self-test: an omitted owner key is rejected"

generate_report
