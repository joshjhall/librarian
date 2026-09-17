#!/usr/bin/env bash
# Every published measurement cites a corpus SHA the manifest backs (#1075 AC5).
#
# WHY THIS IS THE CRITERION THAT MAKES THE REST MATTER. tests/corpora.manifest
# pins the corpora and bin/fetch-corpora.sh verifies what it checked out — but
# neither makes a slice USE the pin. Without this gate, #1069/#1071/#1072/#1074
# can each report a precision figure taken from an unpinned skim of whatever was
# on disk, write it into docs/verification/, and it reads as evidence forever.
# That is the ground-truth-drift shape the whole slice exists to stop, arriving
# through the reporting path instead of the fetching one.
#
# So this gate fails closed when a published measurement cites:
#   - a corpus name absent from the manifest, or
#   - a SHA that disagrees with the manifest's pin for that corpus.
# And it fails closed on a manifest entry whose SHA is not a full 40-char hex
# string, because an abbreviation is not a stable identifier.
#
# SCOPE IS DELIBERATELY NARROW, AND THE NARROWNESS IS THE DESIGN.
# docs/verification/** is exempt from lint-command-refs.sh and the prose budget
# on purpose: those files are dated session transcripts, and a general rule over
# them would pressure someone to edit a session log to satisfy a linter. This
# gate reads ONLY lines carrying the citation marker below — it has no opinion
# about anything else in those documents, so it adds no such pressure.
#
# THE CITATION FORM (one line, anywhere in a docs/verification/*.md file):
#
#     <!-- corpus: <name> <40-char-sha> -->
#
# An HTML comment because it must not disturb the rendered document, and a fixed
# marker because a heuristic ("a line that looks like it mentions a corpus")
# would be exactly the kind of detector that needs a measured certainty tier
# before it ships. This one is exact-match by construction: it fires on the
# marker or not at all, so it has no false-positive rate to measure.
#
# OFFLINE AND CORPUS-INDEPENDENT. It compares two COMMITTED files — the manifest
# and the documents — so it runs in CI and in the pre-push hook with no network
# (#1075 AC8) and no materialized corpus.
#
# IT MUST NOT EXIT 77 FOR ABSENT CORPORA, and that is not an oversight. AC7's
# reserved sentinel belongs to the corpus-CONSUMING gates that slices B/D/E/F
# will ship: those genuinely cannot run without a corpus, and must skip loudly
# rather than pass green. This gate needs no corpus at all, so keying it on one
# would make it inert — the #538/#571 shape where silence reads as a pass, added
# by the very change that exists to prevent it. It exits 77 only when a required
# runtime is missing.
#
# Pure bash + coreutils + grep. bash-3.2 clean, BSD clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

MANIFEST="${CORPORA_MANIFEST:-$REPO_ROOT/tests/corpora.manifest}"
DOCS_DIR="${CITATION_DOCS_DIR:-$REPO_ROOT/docs/verification}"

test_suite "Measurement corpus citations (#1075)"

# --- shared helpers ---------------------------------------------------------
# Kept as functions rather than inlined into the tests because the negative
# fixtures below re-run them against a SANDBOX manifest and sandbox documents.
# A fixture that could only exercise a copy of the logic would prove nothing
# about the logic that actually runs.

# manifest_sha_for <name> <manifest> — the pinned SHA, empty when absent.
manifest_sha_for() {
    local want="$1" mf="$2"
    local name url sha rest
    while IFS=$'\t' read -r name url sha rest || [ -n "$name" ]; do
        case "$name" in
            '' | '#'*) continue ;;
        esac
        if [ "$name" = "$want" ]; then
            command printf '%s\n' "$sha"
            return 0
        fi
    done <"$mf"
    return 1
}

# manifest_short_shas <manifest> — every entry whose SHA is not 40 hex chars,
# as `name:sha`. Anchored at both ends: without the trailing anchor a 41-char
# string passes, without the leading one a 40-hex substring of a longer token
# does.
manifest_short_shas() {
    local mf="$1"
    local name url sha rest
    # `url` is read only to advance the field split to `sha`; shellcheck cannot
    # see that positional role, hence the directive rather than a rename.
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r name url sha rest || [ -n "$name" ]; do
        case "$name" in
            '' | '#'*) continue ;;
        esac
        case "$sha" in
            *[!0-9a-f]*)
                command printf '%s:%s\n' "$name" "$sha"
                continue
                ;;
        esac
        if [ "${#sha}" -ne 40 ]; then
            command printf '%s:%s\n' "$name" "$sha"
        fi
    done <"$mf"
}

# citation_lines <docs-dir> — `file:lineno:name:sha` per citation marker found.
#
# `|| true` on the grep: it exits 1 when no file carries a citation, which under
# `set -e` would abort the scan. That is a legitimate state today (no slice has
# published a measurement yet) and must read as "nothing to check", not as a
# crash.
#
# NOTE the grep is NOT `-q`. Under `pipefail` a `-q` exits on the first match,
# the upstream writer takes SIGPIPE, and the pipeline reports 141 — so a corpus
# that EXISTS reads as absent. That inversion is a documented BSD/pipefail trap
# in this repo (CLAUDE.md § Runtime policy); it is avoided here by construction.
#
# THE SPACING AFTER `corpus:` IS `*`, NOT `+`, and that is deliberate. A marker
# written `<!--corpus:alpha aaaa-->` is one any human reads as a citation, so a
# pattern that required the space would SKIP it — not flag it. Skipping is the
# dangerous direction: a mis-spaced citation would be invisible to the gate while
# reading as evidence to a person, which is the exact shape (#934) this gate
# exists to prevent, reached through the pattern instead of the corpus.
#
# Same reason the SHA is `[0-9a-f]+` rather than `{40}`: an abbreviated SHA must
# be CAUGHT (it cannot equal the manifest's 40-char pin, so it reports as a
# mismatch), never skipped as "not a citation".
citation_lines() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    command grep -rnE '<!--[[:space:]]*corpus:[[:space:]]*[a-z0-9-]+[[:space:]]+[0-9a-f]+[[:space:]]*-->' \
        "$dir" 2>/dev/null || true
}

# citation_location <grep-line> — the `file:lineno` prefix grep -n prepends.
#
# Pure-bash parameter expansion rather than sed: BSD and GNU sed disagree about
# constructs this would need, and that split is SILENT — the pattern stops
# matching, zero rows come back, and the gate reports a clean scan of nothing.
citation_location() {
    local line="$1" loc rest
    loc="${line%%:*}"
    rest="${line#*:}"
    command printf '%s:%s\n' "$loc" "${rest%%:*}"
}

# citation_pairs <grep-line> — EVERY marker on the line, one `name sha` per row.
#
# ITERATES rather than parsing once, and that is the whole point. `grep -n`
# emits one row per LINE, not per match, so a line carrying two markers arrives
# as a single row. A parser that read only the first would leave the second
# silently unchecked — one row per line collapsing N findings into one is a
# suppression bug this repo has filed before, and here it would mean a published
# measurement citing a bogus SHA passes the gate because a valid citation shares
# its line.
#
# Verified by test_fixture_two_citations_on_one_line below, which is the case
# that found this.
citation_pairs() {
    local rest="$1" body name sha
    # Drop the `file:lineno:` prefix so a path containing `<!--` cannot be
    # mistaken for a marker.
    rest="${rest#*:}"
    rest="${rest#*:}"

    while [ "${rest#*<!--}" != "$rest" ]; do
        rest="${rest#*<!--}"
        body="${rest%%-->*}"
        # Advance past this marker before any `continue`, or a non-citation
        # comment would spin forever.
        rest="${rest#*-->}"

        case "$body" in
            *corpus:*) ;;
            *) continue ;;
        esac

        body="${body#*corpus:}"
        # Collapse leading whitespace without a regex.
        while [ "${body# }" != "$body" ] || [ "${body#	}" != "$body" ]; do
            body="${body# }"
            body="${body#	}"
        done
        name="${body%%[ 	]*}"
        sha="${body#"$name"}"
        while [ "${sha# }" != "$sha" ] || [ "${sha#	}" != "$sha" ]; do
            sha="${sha# }"
            sha="${sha#	}"
        done
        sha="${sha%%[ 	]*}"

        [ -n "$name" ] && [ -n "$sha" ] || continue
        command printf '%s %s\n' "$name" "$sha"
    done
}

# scan_citations <docs-dir> <manifest> — the gate's whole verdict, as violation
# lines on stdout. Empty output == clean. Exit status is NOT the verdict: a
# caller reads the rows, so a helper that returned "fine" for the wrong reason
# cannot pass silently.
scan_citations() {
    local dir="$1" mf="$2"
    local line name sha want loc

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        loc="$(citation_location "$line")"

        # One iteration per MARKER, not per line — see citation_pairs.
        while IFS=' ' read -r name sha; do
            [ -n "$name" ] || continue

            if ! want="$(manifest_sha_for "$name" "$mf")"; then
                command printf '%s: UNKNOWN CORPUS %s — not in the manifest\n' "$loc" "$name"
                continue
            fi

            if [ "$sha" != "$want" ]; then
                command printf '%s: SHA MISMATCH for %s — cites %s, manifest pins %s\n' \
                    "$loc" "$name" "$sha" "$want"
            fi
        done <<PAIRS
$(citation_pairs "$line")
PAIRS
    done <<EOF
$(citation_lines "$dir")
EOF
}

# --- the live checks --------------------------------------------------------

test_manifest_exists() {
    assert_file_exists "$MANIFEST" "tests/corpora.manifest must exist"
}

test_manifest_has_entries() {
    # NON-VACUITY. Every assertion below would pass against an EMPTY manifest
    # for the wrong reason — zero entries means zero short SHAs and zero
    # mismatches. Asserting the corpus is non-empty BEFORE reporting clean is
    # what separates "checked and fine" from "never looked".
    local n
    n="$(
        manifest_short_shas "$MANIFEST" >/dev/null 2>&1
        command grep -cvE '^([[:space:]]*#|[[:space:]]*$)' "$MANIFEST" || true
    )"
    assert_true "[ \"$n\" -ge 1 ]" "Manifest must declare at least one corpus (else this gate is vacuous)"
}

test_manifest_shas_are_full_length() {
    local short
    short="$(manifest_short_shas "$MANIFEST")"
    assert_output_empty "$short" "Every manifest SHA must be a full 40-char hex SHA"
}

test_published_citations_match_manifest() {
    local violations
    violations="$(scan_citations "$DOCS_DIR" "$MANIFEST")"
    assert_output_empty "$violations" "Every published measurement must cite a corpus+SHA the manifest backs"
}

test_real_docs_are_actually_scanned() {
    # NON-VACUITY ON THE DOCS SIDE, the twin of test_manifest_has_entries.
    #
    # The assertion above passes against an EMPTY result, and an empty result has
    # two very different causes: no violations, or nothing scanned. A wrong
    # DOCS_DIR, a renamed directory, or a `grep` whose pattern stopped matching
    # (the silent BSD-regex split CLAUDE.md warns about) all yield "clean" —
    # which reads as evidence while the gate is looking at nothing (#934).
    #
    # This repo now ships at least one real citation, so the gate can assert it
    # sees it. If every citation is ever deliberately removed, this is the row
    # that must be revisited — deleting it to go green would be re-creating the
    # inert gate on purpose.
    assert_true "[ -d \"$DOCS_DIR\" ]" "The scanned docs directory must exist"
    local found
    found="$(citation_lines "$DOCS_DIR")"
    assert_not_empty "$found" \
        "The scan must find at least one real citation — an empty scan reads as clean but proves nothing"
}

# --- negative fixtures (AC6) ------------------------------------------------
# Each builds a real sandbox, breaks it in ONE specific way, and asserts the
# scanner reports THAT breakage by its specific message — never merely a
# non-zero exit. Asserting only the status would let a sibling defect in the
# fixture satisfy the assertion, which is how a gate ends up pinned to a
# property it does not actually have.
#
# Without these, every assertion above would pass on a scanner that always
# returned empty, and this gate would join the inert-gate class (#538/#571) on
# the day it shipped.

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && command rm -rf "$SANDBOX"; }
trap cleanup EXIT

SANDBOX="$(command mktemp -d)" || {
    command printf 'lint-measurement-citations: mktemp failed — not enforcing.\n' >&2
    exit 77
}

# A known-good sandbox manifest + docs dir the fixtures mutate one at a time.
FIX_MF="$SANDBOX/corpora.manifest"
FIX_DOCS="$SANDBOX/verification"
command mkdir -p "$FIX_DOCS"
command printf 'alpha\thttps://example.invalid/a.git\t%s\tMIT\ttag:v1\twhy\n' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"$FIX_MF"

test_fixture_clean_sandbox_is_silent() {
    # The CONTROL. Without it the three fixtures below could all pass against a
    # scanner that flags everything, which is just as broken as one that flags
    # nothing.
    command printf 'ok <!-- corpus: alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n' \
        >"$FIX_DOCS/good.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_output_empty "$out" "A citation matching the manifest must produce no violation"
    command rm -f "$FIX_DOCS/good.md"
}

test_fixture_unknown_corpus_fires() {
    command printf 'x <!-- corpus: ghostcorpus aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n' \
        >"$FIX_DOCS/unknown.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "UNKNOWN CORPUS ghostcorpus" \
        "A citation naming a corpus absent from the manifest must be reported as unknown"
    command rm -f "$FIX_DOCS/unknown.md"
}

test_fixture_sha_mismatch_fires() {
    command printf 'x <!-- corpus: alpha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->\n' \
        >"$FIX_DOCS/mismatch.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "SHA MISMATCH for alpha" \
        "A citation whose SHA disagrees with the manifest must be reported as a mismatch"
    # The message must carry BOTH shas — a reader who cannot see what was
    # expected has to go look it up, and the row stops being self-contained.
    assert_contains "$out" "manifest pins aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "The mismatch row must name the SHA the manifest actually pins"
    command rm -f "$FIX_DOCS/mismatch.md"
}

test_fixture_short_sha_in_manifest_fires() {
    local short_mf out
    short_mf="$SANDBOX/short.manifest"
    command printf 'alpha\thttps://example.invalid/a.git\taaaaaaa\tMIT\ttag:v1\twhy\n' >"$short_mf"
    out="$(manifest_short_shas "$short_mf")"
    assert_contains "$out" "alpha:aaaaaaa" \
        "A manifest entry with an abbreviated SHA must be reported"
}

test_fixture_non_hex_sha_in_manifest_fires() {
    # The sibling of the case above, and a distinct one: a 40-CHARACTER string
    # that is not hex passes a pure length check. Both arms of is-a-full-sha
    # need a fixture, or half the predicate is unpinned.
    local bad_mf out
    bad_mf="$SANDBOX/nonhex.manifest"
    command printf 'alpha\thttps://example.invalid/a.git\tzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\tMIT\ttag:v1\twhy\n' \
        >"$bad_mf"
    out="$(manifest_short_shas "$bad_mf")"
    assert_contains "$out" "alpha:zzzz" \
        "A 40-char non-hex SHA must be reported too, not just a short one"
}

test_fixture_tight_spacing_is_still_a_citation() {
    # A marker with no space after `corpus:` is one any reader treats as a
    # citation. The pattern must CHECK it, not skip it — a skipped citation is
    # invisible to the gate while still reading as evidence to a person, which is
    # the silent-hole direction. Found by probing the pattern against shapes no
    # fixture contained; pinned here so it cannot revert to `[[:space:]]+`.
    command printf 'x <!--corpus:ghosttight aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-->\n' \
        >"$FIX_DOCS/tight.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "UNKNOWN CORPUS ghosttight" \
        "A citation with no space after 'corpus:' must be checked, never skipped"
    command rm -f "$FIX_DOCS/tight.md"
}

test_fixture_abbreviated_citation_sha_is_caught() {
    # The citation-side twin of the manifest's short-SHA check. An abbreviated
    # SHA in a published measurement must be CAUGHT as a mismatch (it cannot
    # equal a 40-char pin), never skipped as "not a citation" by a pattern
    # demanding exactly 40 characters.
    command printf 'x <!-- corpus: alpha aaaaaaa -->\n' >"$FIX_DOCS/short.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "SHA MISMATCH for alpha" \
        "An abbreviated SHA in a citation must be reported, not skipped"
    command rm -f "$FIX_DOCS/short.md"
}

test_fixture_two_citations_on_one_line() {
    # `grep -n` emits one row per LINE, not per match, so two markers on one line
    # arrive as a single row. The scanner must report BOTH: a parser that read
    # only the first would let a bogus citation pass whenever a valid one shares
    # its line — the collapse-N-findings-into-one suppression shape.
    #
    # This is the sibling of test_fixture_scanner_reads_every_hit below, which
    # covers two markers on two lines; that one passed while this failed, which
    # is exactly why both are needed.
    command printf 'a <!-- corpus: ghostone aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --> then <!-- corpus: ghosttwo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->\n' \
        >"$FIX_DOCS/same-line.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "ghostone" "The first marker on the line must be reported"
    assert_contains "$out" "ghosttwo" "The SECOND marker on the SAME line must be reported too"
    command rm -f "$FIX_DOCS/same-line.md"
}

test_fixture_non_citation_comment_is_ignored() {
    # The control for the loop above: an ordinary HTML comment sharing a line
    # with a citation must neither be parsed as one nor stop the scan. A loop
    # that failed to advance past a non-citation comment would hang, which is a
    # worse failure than a wrong row.
    command printf 'x <!-- just a note --> y <!-- corpus: ghostthree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n' \
        >"$FIX_DOCS/mixed.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "ghostthree" "A citation following a plain comment must still be found"
    assert_not_contains "$out" "just a note" "A plain comment must not be parsed as a citation"
    command rm -f "$FIX_DOCS/mixed.md"
}

test_fixture_scanner_reads_every_hit() {
    # ONE ROW PER VIOLATION. A scanner that reported only the first bad citation
    # would re-create the suppression bug this gate exists to prevent: the second
    # defect in a document would be invisible until the first was fixed.
    command printf 'a <!-- corpus: ghostone aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\nb <!-- corpus: ghosttwo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->\n' \
        >"$FIX_DOCS/two.md"
    local out
    out="$(scan_citations "$FIX_DOCS" "$FIX_MF")"
    assert_contains "$out" "ghostone" "The first violation must be reported"
    assert_contains "$out" "ghosttwo" "The SECOND violation must be reported too"
    command rm -f "$FIX_DOCS/two.md"
}

run_test test_manifest_exists
run_test test_manifest_has_entries
run_test test_manifest_shas_are_full_length
run_test test_published_citations_match_manifest
run_test test_real_docs_are_actually_scanned
run_test test_fixture_clean_sandbox_is_silent
run_test test_fixture_unknown_corpus_fires
run_test test_fixture_sha_mismatch_fires
run_test test_fixture_short_sha_in_manifest_fires
run_test test_fixture_non_hex_sha_in_manifest_fires
run_test test_fixture_tight_spacing_is_still_a_citation
run_test test_fixture_abbreviated_citation_sha_is_caught
run_test test_fixture_two_citations_on_one_line
run_test test_fixture_non_citation_comment_is_ignored
run_test test_fixture_scanner_reads_every_hit

generate_report
