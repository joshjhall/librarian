#!/usr/bin/env bash
# Suite-verdict reporting gate (issue #899).
#
# WHAT THIS EXISTS TO STOP. A suite that sources tests/lib/harness.sh, registers
# run_test cases, and never calls `generate_report` prints `... FAIL` lines and
# still EXITS 0. `generate_report` is the only thing that turns TESTS_FAILED into
# a non-zero status (harness.sh's `[ "$TESTS_FAILED" -eq 0 ]` tail), and
# run-all.sh's run_stage keys purely on the exit code — so such a suite renders
# `[ok]` in CI while its assertions are failing.
#
# It is the #538/#571 "a gate that sits inert reads as a pass" shape by a third
# route: not an absent tool (sentinel 77), and not an unregistered test (#596),
# but a registered, EXECUTING, FAILING test whose verdict is never collected.
#
# HOW IT GOT HERE. Introduced accidentally while splitting
# tests/validate-source-detectors.sh into fragments (#859, in #707): the entry
# point was rebuilt from its `run_test` dispatch lines, and what follows those
# lines — the trailing `generate_report` — went with the tail. The suite then
# reported `18 passed` on a tree where a deliberately mutated scanner made two
# assertions fail. It surfaced only because a mutation round keyed on exit code
# showed EVERY rule "surviving", which was implausible enough to investigate.
#
# That rebuild-the-entry-point operation happens on every suite split (six so
# far, #564), which is exactly when it is easiest to drop. The omission is
# invisible in review: the file looks complete, the tests ARE registered, and the
# suite DOES run them. Only the reporting is missing, and its absence is silent.
#
# WHY A LINT AND NOT A HARNESS-SIDE EXIT TRAP. #899 offered both shapes. The trap
# is structurally defeated in this corpus: 39 of the 94 harness-sourcing suites
# already arm their own `trap ... EXIT` for sandbox cleanup
# (`trap 'command rm -rf "$WORKDIR"' EXIT` and friends). Bash keeps ONE EXIT trap
# per shell, so a later `trap` silently OVERWRITES whatever test_suite installed
# — the guard would be disarmed across 40% of the corpus without a word,
# reproducing the very failure mode it was added to close. A static rule has no
# such hole and no runtime risk.
#
# THE RULE, in two parts. For every file carrying a real `source .../harness.sh`
# statement:
#
#   1. a COLUMN-0 `generate_report` must be present, and
#   2. it must be the LAST executable statement in the file.
#
# Column-0 is load-bearing, and is what closes the caveat #899 itself raised
# against the lint shape ("misses a suite that calls it on only one branch").
# Eight suites legitimately call `generate_report` INDENTED inside an early-exit
# branch (`skip_test; generate_report; exit "$SKIP_EXIT_CODE"` — lint-markdown.sh,
# validate-okf-bundle.sh, validate-prelude-sync.sh and friends). Those calls are
# correct and must stay allowed, but they are not the unconditional tail call, and
# a suite carrying ONLY them still exits 0 on the path where its tests actually
# run. Anchoring at column 0 accepts the branch calls while still demanding the
# tail one.
#
# Part 2 closes the sibling hole: `generate_report` followed by `exit 0` discards
# the verdict just as thoroughly as omitting the call. The exit status of the
# script is the status of its LAST command, so anything executable after the
# report overwrites it.
#
# The rule is UNCONDITIONAL — deliberately not "only if the file calls run_test".
# Every file in the corpus registers tests, and `generate_report` on a zero-test
# file is harmless (Total: 0, exit 0), so the unconditional form is both simpler
# and strictly stronger: it cannot be dodged by a rebuild that drops the run_test
# lines too.
#
# CORPUS SELECTION is keyed on a real SOURCE STATEMENT, not a bare grep for the
# string "harness.sh". tests/lib/fragments.sh and tests/lib/source-detectors-sandbox.sh
# only MENTION the harness in comments — they are sourced helpers with no entry
# point of their own, and sweeping them in would demand a report from a file that
# must not produce one.
#
# Pure bash + coreutils + grep/sed. bash-3.2 clean and BSD-regex clean, per
# CLAUDE.md § Runtime policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Suite verdict reporting (#899)"

# A real source statement for the harness: `source <path>/lib/harness.sh` or the
# `.` spelling, at the start of a line (leading whitespace allowed). A comment
# mentioning the harness cannot match, because `#` precedes the keyword.
# The boundary after the path is load-bearing in BOTH directions, and getting
# only one of them right re-creates this gate's own bug somewhere else.
#
# Unanchored, `lib/harness.sh` matches as a SUBSTRING, so a future
# `lib/harness.sh.bak` or `lib/harness.shim.sh` is swept in and required to carry
# a report it has no business owning — a false positive.
#
# But anchoring hard at end-of-line ($) is worse, and worse in the direction this
# file exists to prevent: a suite spelled `source ".../harness.sh" || exit 1` or
# `. ".../harness.sh"; set -x` stops matching, silently leaves the corpus, and is
# never checked for its tail call at ALL. That is the #538/#571
# silence-reads-as-a-pass shape relocated from the tail-call check into corpus
# SELECTION, where it is even harder to notice — the suite does not fail, it
# simply stops being audited.
#
# So the rule is a BOUNDARY, not an anchor: the path may be followed by the
# closing quote and then end-of-line, a shell operator (`;`, `|`, `&`, `)`), or
# whitespace. What it may NOT be followed by is another path character, which is
# exactly what distinguishes `harness.sh"` from `harness.sh.bak"`.
#
# The operator class is exactly `[;|]`, and it is deliberately no larger. Every
# candidate was tested by MUTATION — drop the character, rerun the fixtures, see
# whether anything fails — because an alternative no test can distinguish reads
# as coverage while buying nothing:
#   `;` and `|`  KEPT: reachable, and the only branch that matches. A no-space
#                `harness.sh";` has no whitespace to fall back on, so removing
#                either one drops a real spelling (verified: match 1 -> 0).
#   `#`          DROPPED: a shell comment needs whitespace before its `#`, and
#                that whitespace already matches the third branch. A trailing
#                comment is still accepted — just not via this class.
#   `&`          DROPPED: same reason as `#` — `... harness.sh" &` has the space.
#   `)`          DROPPED, and it never matched anyway: a command substitution
#                spells the line `x=$(source ...)`, which fails the `^\s*source`
#                anchor before the boundary is ever consulted.
# test_corpus_selector_is_narrow pins both directions.
#
# KNOWN LIMIT, stated so it is a decision rather than an oversight: a suite whose
# source line does not CONTAIN the path — `source "$HARNESS_PATH"` — is invisible
# here. No text detector can see a path that is not in the line, and no suite in
# this repo spells it that way; if one ever does, it silently leaves the corpus,
# and `sources_harness` is the single place to fix it.
#
# Precisely: the test is on the LINE, not on the resolved target. So a variable
# source that happens to carry the literal elsewhere on the line — say a trailing
# `# see lib/harness.sh` — DOES match and is swept in. That is the right outcome
# (the file sources the harness, so it owes a report) but it is not what
# "invisible" would suggest, which is why the limit is worded as containment
# rather than as a guarantee about variables. test_corpus_selector_is_narrow
# pins both halves.
HARNESS_SOURCE_RE='^[[:space:]]*(source|\.)[[:space:]]+.*lib/harness\.sh["'"'"']?([[:space:]]*$|[[:space:]]*[;|]|[[:space:]])'

# The required unconditional tail call, at column 0. A trailing `;` and/or an
# inline `# comment` are accepted: they change nothing about WHEN the call runs,
# and rejecting them would report "never calls generate_report" about a file that
# plainly does — a misleading diagnostic that sends the reader hunting for an
# absent call rather than fixing the real defect.
REPORT_RE='^generate_report[[:space:]]*;?[[:space:]]*(#.*)?$'
# The same call, indented — i.e. inside a branch. Used only to tell the two
# no-column-0-call cases apart, because their fixes differ.
INDENTED_REPORT_RE='^[[:space:]]+generate_report[[:space:]]*;?[[:space:]]*(#.*)?$'

# --- Detector ---------------------------------------------------------------

# sources_harness <file> — true when <file> carries a real harness source
# statement.
sources_harness() {
    command grep -Eq "$HARNESS_SOURCE_RE" "$1"
}

# harness_suites <root> — print, one relative path per line, every *.sh under
# <root> that sources the harness. Sorted for a stable, diffable corpus.
harness_suites() {
    local root="$1" f
    command find "$root" -name '*.sh' -type f 2>/dev/null | command sort | while IFS= read -r f; do
        sources_harness "$f" || continue
        command printf '%s\n' "${f#"$root"/}"
    done
}

# reporting_defect <file> — print a one-line defect description, or nothing when
# the file satisfies both parts of the rule. This is THE detector; every
# assertion below and every fixture goes through it.
#
# `grep -n` into a variable (not `grep -q` into a pipeline) on purpose: under
# `pipefail`, a `-q` that exits on its first match SIGPIPEs the upstream writer
# and the pipeline reports 141, inverting a successful match into a failure
# (#928). Here grep reads a FILE directly, but the captured form also gives us
# the line number we need for part 2.
reporting_defect() {
    local file="$1" last_report trailing

    last_report="$(command grep -nE "$REPORT_RE" "$file" | command tail -n 1 | command cut -d: -f1)"

    if [ -z "$last_report" ]; then
        # Distinguish the two ways to have no column-0 call, because the fix
        # differs: an indented-only suite needs the call HOISTED, an absent one
        # needs it ADDED.
        if command grep -Eq "$INDENTED_REPORT_RE" "$file"; then
            command printf 'calls generate_report only INDENTED (inside a branch) — no unconditional tail call\n'
        else
            command printf 'never calls generate_report — its tests can FAIL while the suite exits 0\n'
        fi
        return 0
    fi

    # Part 2: nothing executable may follow. Blank lines and comments are fine.
    trailing="$(
        command sed -n "$((last_report + 1)),\$p" "$file" |
            command grep -vE '^[[:space:]]*(#.*)?$' |
            command head -n 1
    )"
    if [ -n "$trailing" ]; then
        command printf 'has executable code AFTER generate_report (%s) — the script exit status is the LAST command, so the verdict is discarded\n' \
            "$trailing"
    fi
}

# --- Corpus -----------------------------------------------------------------

SUITES="$(harness_suites "$REPO_ROOT/tests")"

# --- Real-corpus assertions -------------------------------------------------

CUR_REL=""
test_suite_reports_its_verdict() {
    local defect
    defect="$(reporting_defect "$REPO_ROOT/tests/$CUR_REL")"
    assert_equals "" "$defect" \
        "tests/$CUR_REL $defect. Every harness-sourcing suite must end in an unconditional column-0 \`generate_report\` — it is the only call that turns TESTS_FAILED into a non-zero exit status (#899)."
}

# Non-vacuity floor: a broken find/grep would empty the corpus and let every
# assertion above pass by inspecting nothing. Same posture as
# fragments.sh's assert_not_empty and lint-shell-portability.sh's
# test_corpus_non_empty.
test_corpus_non_empty() {
    assert_not_empty "$SUITES" \
        "At least one harness-sourcing suite must be discovered under tests/ (a gate that inspects zero files reports green while enforcing nothing)"
}

# The corpus selector must EXCLUDE a file that merely mentions the harness in a
# comment. tests/lib/fragments.sh is the live control: it is a sourced helper
# with no entry point, it names harness.sh in its usage comment, and it must
# never be required to produce a report.
test_comment_mention_is_not_a_suite() {
    assert_not_contains "$SUITES" "lib/fragments.sh" \
        "A file that only MENTIONS harness.sh in a comment is not a suite (fragments.sh has no entry point and must not be required to report)"
    assert_file_exists "$REPO_ROOT/tests/lib/fragments.sh" \
        "The live control still exists — if fragments.sh was renamed, re-point this assertion rather than deleting it"
    assert_true "command grep -q 'harness\\.sh' '$REPO_ROOT/tests/lib/fragments.sh'" \
        "The live control still mentions harness.sh (otherwise the exclusion above passes for the wrong reason)"
}

# --- Fixture assertions (the detector must have teeth) ----------------------

# Each fixture is a minimal suite written to a sandbox, run through the SAME
# reporting_defect the real corpus uses. Without these, a detector that always
# returned empty would pass this gate on a clean tree — which is precisely the
# silence-reads-as-a-pass bug #899 is about.
#
# FIXTURES ARE BUILT WITH printf, NOT WITH A HEREDOC, and that is a correctness
# requirement rather than a style choice. This gate is itself part of the corpus
# it audits, and reporting_defect is a pure text detector with no notion of
# heredocs or quoting: a heredoc'd fixture containing a literal column-0
# `generate_report` is indistinguishable, to the detector, from this file's real
# tail call. With heredocs this file carried SIX such lines and self-checked
# correctly only because all five fixtures happened to sit ABOVE the real call,
# so `tail -n 1` still landed on it. That is a coincidence of ordering, not a
# property — appending one more fixture below the tail call (the natural place)
# would silently point the self-check at fixture text. Emitting the token as
# 'generate' '_report' keeps this file at exactly one column-0 match, the same
# invariant it enforces on everyone else. test_this_file_has_one_tail_call pins it.
REPORT_CALL="generate""_report"

# write_suite <path> <line>... — write a fixture suite, one argument per line.
write_suite() {
    local path="$1"
    shift
    local line
    : >"$path"
    for line in "$@"; do
        command printf '%s\n' "$line" >>"$path"
    done
}

test_detector_fires_in_every_direction() {
    local sandbox
    sandbox="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sandbox now, at trap-registration time
    trap "command rm -rf '$sandbox'" RETURN

    # (a) Correct: unconditional column-0 call, nothing after it.
    write_suite "$sandbox/good.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL"
    assert_equals "" "$(reporting_defect "$sandbox/good.sh")" \
        "A suite ending in an unconditional generate_report reports no defect"

    # (b) The #899 defect itself: the tail call was dropped on a split.
    write_suite "$sandbox/missing.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"'
    assert_contains "$(reporting_defect "$sandbox/missing.sh")" "never calls generate_report" \
        "A suite with no generate_report at all is detected"

    # (c) Indented-only: the call exists, but only on the skip branch. The path
    # where the tests actually run still exits 0.
    write_suite "$sandbox/indented.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'if ! command -v thing >/dev/null 2>&1; then' \
        '    skip_test "thing not on PATH"' \
        "    $REPORT_CALL" \
        '    exit 77' \
        'fi' \
        'run_test test_a "a"'
    assert_contains "$(reporting_defect "$sandbox/indented.sh")" "only INDENTED" \
        "A suite whose only generate_report is inside a branch is detected"

    # (d) Trailing code: the report ran, then `exit 0` overwrote its status.
    write_suite "$sandbox/trailing.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL" \
        'exit 0'
    assert_contains "$(reporting_defect "$sandbox/trailing.sh")" "AFTER generate_report" \
        "A suite with executable code after generate_report is detected"

    # (e) Comments and blank lines after the call are NOT trailing code — the
    # narrowness of (d), without which the rule would fire on a trailing comment.
    write_suite "$sandbox/comment-tail.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL" \
        '' \
        '# A closing note about the suite.'
    assert_equals "" "$(reporting_defect "$sandbox/comment-tail.sh")" \
        "Comments and blank lines after generate_report are not executable code"

    # (f) An inline comment or a trailing `;` on the tail call changes nothing
    # about when it runs. Reporting "never calls generate_report" about a file
    # that plainly does would send the reader hunting for an absent call.
    write_suite "$sandbox/inline-comment.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL  # print the final verdict"
    assert_equals "" "$(reporting_defect "$sandbox/inline-comment.sh")" \
        "A tail call carrying an inline comment is accepted, not misreported as absent"

    write_suite "$sandbox/semicolon.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL;"
    assert_equals "" "$(reporting_defect "$sandbox/semicolon.sh")" \
        "A tail call with a trailing semicolon is accepted"

    write_suite "$sandbox/semicolon-comment.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        '' \
        "$REPORT_CALL; # print the final verdict"
    assert_equals "" "$(reporting_defect "$sandbox/semicolon-comment.sh")" \
        "The COMBINED semicolon-plus-comment spelling is accepted (each half is tested above; a regex edit could break only the combination)"

    # (g) Two column-0 calls: the detector takes the LAST, so a duplicated call
    # above the real tail is tolerated. Pinning it makes that deliberate rather
    # than incidental — the rule is about the FINAL statement, and an earlier
    # extra call cannot make a suite exit 0 with failures.
    write_suite "$sandbox/duplicate.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        'run_test test_a "a"' \
        "$REPORT_CALL" \
        'run_test test_b "b"' \
        '' \
        "$REPORT_CALL"
    assert_equals "" "$(reporting_defect "$sandbox/duplicate.sh")" \
        "The LAST column-0 call is the one checked (an earlier duplicate is tolerated)"

    # (h) ...and the last-match rule must not become a way to HIDE trailing code:
    # a correct call followed by a second one with code after it still fires.
    write_suite "$sandbox/duplicate-trailing.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        "$REPORT_CALL" \
        'run_test test_a "a"' \
        "$REPORT_CALL" \
        'exit 0'
    assert_contains "$(reporting_defect "$sandbox/duplicate-trailing.sh")" "AFTER generate_report" \
        "A duplicate earlier call cannot mask trailing code after the last one"
}

# This file audits itself, so the coincidence described above must not creep
# back. Assert directly what the printf fixtures buy: exactly ONE column-0
# match, which is therefore necessarily the real tail call. A future edit that
# reintroduces a heredoc'd fixture fails HERE, naming the reason, rather than
# silently re-pointing the self-check at fixture text.
test_this_file_has_one_tail_call() {
    local n
    n="$(command grep -cE "$REPORT_RE" "$SCRIPT_DIR/lint-suite-reporting.sh")"
    assert_equals "1" "$n" \
        "This gate must contain exactly ONE column-0 generate_report (its own tail call). It is part of the corpus it audits, and the detector cannot tell a heredoc'd fixture from a real call — build fixtures with write_suite/\$REPORT_CALL, never a heredoc (#899)."
}

# The corpus SELECTOR must have teeth in both directions too: a real source
# statement is picked up, a comment mention is not.
test_corpus_selector_is_narrow() {
    local sandbox picked
    sandbox="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sandbox now, at trap-registration time
    trap "command rm -rf '$sandbox'" RETURN

    command mkdir -p "$sandbox/tests"
    write_suite "$sandbox/tests/real-source.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"' \
        "$REPORT_CALL"
    write_suite "$sandbox/tests/dot-source.sh" \
        '. "$SCRIPT_DIR/lib/harness.sh"' \
        "$REPORT_CALL"
    # The single-quote member of the optional-quote class, which no other fixture
    # reaches (they are all double-quoted). Mutation-checked: dropping ' from the
    # class makes this the assertion that fails.
    write_suite "$sandbox/tests/single-quoted.sh" \
        "source '\$SCRIPT_DIR/lib/harness.sh'" \
        "$REPORT_CALL"
    write_suite "$sandbox/tests/mention-only.sh" \
        '# Sourced by a suite AFTER tests/lib/harness.sh. Has no entry point.' \
        'helper() { :; }'
    # A DIFFERENT file whose path merely starts with the harness's name. Without
    # the boundary in HARNESS_SOURCE_RE this is swept into the corpus by
    # substring match and required to carry a report it does not own.
    write_suite "$sandbox/tests/near-miss.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh.bak"' \
        'helper() { :; }'
    # The opposite direction, and the more dangerous one: a REAL suite that
    # sources the harness with trailing code on the same line. An end-of-line
    # anchor would drop these from the corpus silently — they would never be
    # checked for a tail call at all, which is this gate's own failure mode
    # turned on itself.
    write_suite "$sandbox/tests/compound-or.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh" || exit 1' \
        "$REPORT_CALL"
    write_suite "$sandbox/tests/compound-semi.sh" \
        '. "$SCRIPT_DIR/lib/harness.sh"; set -x' \
        "$REPORT_CALL"
    # NOTE: no space before the `||`. compound-or.sh above has one, which means it
    # matches via the WHITESPACE branch and leaves `|` unproven — mutation showed
    # exactly that. The operator class is only reachable when the operator abuts
    # the closing quote, so that is what this fixture spells.
    write_suite "$sandbox/tests/compound-pipe.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh"|| exit 1' \
        "$REPORT_CALL"
    # The optional-quote branch, asserted rather than left to incidence: an
    # UNQUOTED path at true end-of-line.
    write_suite "$sandbox/tests/unquoted.sh" \
        'source $SCRIPT_DIR/lib/harness.sh' \
        "$REPORT_CALL"
    # The bare-whitespace branch of the boundary alternation, which is the most
    # permissive of the three and the one a future tightening is likeliest to
    # drop: a path followed by a space and ordinary trailing content. Both
    # regressions this regex already had (over-anchoring in cycle 1,
    # under-anchoring in cycle 2) lived exactly here, so the branch is pinned
    # directly instead of only via cases that also satisfy another alternative.
    write_suite "$sandbox/tests/trailing-arg.sh" \
        'source "$SCRIPT_DIR/lib/harness.sh" extra_arg' \
        "$REPORT_CALL"
    # ...and the same widening must NOT re-admit a near-miss path unquoted.
    write_suite "$sandbox/tests/unquoted-near-miss.sh" \
        'source $SCRIPT_DIR/lib/harness.sh.bak' \
        'helper() { :; }'
    # The KNOWN LIMIT above, pinned in both directions. A variable source with no
    # literal path is invisible (the detector reads the line, not the resolved
    # target); the same line carrying the literal in a comment IS swept in.
    write_suite "$sandbox/tests/var-source.sh" \
        'source "$HARNESS_PATH"' \
        'helper() { :; }'
    # NOTE the trailing words after the path. Without them the literal would end
    # the line and match the end-of-line branch instead, so the fixture would
    # pass while testing nothing about an incidental mid-line token — which is
    # how it was first written, and what mutating the boundary class revealed.
    write_suite "$sandbox/tests/var-source-comment.sh" \
        'source "$HARNESS_PATH" # see lib/harness.sh for the helpers' \
        "$REPORT_CALL"

    picked="$(harness_suites "$sandbox/tests")"
    assert_contains "$picked" "real-source.sh" "A source statement puts the file in the corpus"
    assert_contains "$picked" "dot-source.sh" "The dot spelling is recognised too"
    assert_contains "$picked" "single-quoted.sh" \
        "A SINGLE-quoted harness path is recognised (the ' member of the quote class; every other fixture is double-quoted)"
    assert_not_contains "$picked" "mention-only.sh" "A comment mention does not put a file in the corpus"
    assert_not_contains "$picked" "near-miss.sh" \
        "A path that merely STARTS with lib/harness.sh (e.g. lib/harness.sh.bak) is a different file and stays out of the corpus"
    assert_contains "$picked" "compound-or.sh" \
        "A suite sourcing the harness with a trailing || clause IS in the corpus (dropping it would leave a real suite unaudited — this gate's own bug, relocated)"
    assert_contains "$picked" "compound-semi.sh" \
        "A suite sourcing the harness with a trailing ; clause IS in the corpus"
    assert_contains "$picked" "compound-pipe.sh" \
        "A trailing || that ABUTS the closing quote IS in the corpus (the | member of the operator class; with a space it would match the whitespace branch instead)"
    assert_contains "$picked" "unquoted.sh" \
        "An UNQUOTED harness source path IS in the corpus (the optional-quote branch, asserted not assumed)"
    assert_contains "$picked" "trailing-arg.sh" \
        "A harness source line with trailing content after a space IS in the corpus (pins the bare-whitespace branch of the boundary)"
    assert_not_contains "$picked" "unquoted-near-miss.sh" \
        "Widening for unquoted paths must not re-admit a near-miss path (lib/harness.sh.bak, unquoted) — both boundary directions hold at once"
    assert_not_contains "$picked" "var-source.sh" \
        "A source line with no literal path (source \"\$HARNESS_PATH\") is invisible — the documented limit, pinned so the comment cannot drift from the code"
    assert_contains "$picked" "var-source-comment.sh" \
        "...but the same line carrying the literal in a comment IS swept in: the test is on the LINE, not the resolved target (the file does source the harness, so it owes a report)"
}

run_test test_corpus_non_empty "Corpus is non-empty (gate is not a no-op)"
run_test test_comment_mention_is_not_a_suite "A comment-only mention of harness.sh is not a suite"
run_test test_detector_fires_in_every_direction "Detector fires on absent / indented-only / trailing-code, and passes a correct suite"
run_test test_this_file_has_one_tail_call "This gate carries exactly one column-0 generate_report (self-audit is not a coincidence)"
run_test test_corpus_selector_is_narrow "Corpus selector picks real source statements only"

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    CUR_REL="$rel"
    run_test test_suite_reports_its_verdict "tests/$rel ends in an unconditional generate_report"
done <<EOF
$SUITES
EOF

generate_report
