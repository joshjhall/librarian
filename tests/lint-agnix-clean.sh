#!/usr/bin/env bash
# agnix error-free gate (issue #734).
#
# Asserts the repo's own AI-config artifacts produce ZERO agnix errors, over the
# same target set and config CI scans (.github/workflows/code-scanning.yml):
#
#   agnix --format sarif --target claude-code --config .agnix.toml \
#     validate CLAUDE.md AGENTS.md plugins
#
# This gate drops `--format sarif` and reads the default TEXT output instead —
# same rules, same corpus, same findings, but parsable with grep/sed alone. CI
# needs SARIF because it uploads to code scanning; a local gate that required it
# would drag in a `jq` dependency to answer a yes/no question. Verified rather
# than assumed: on this tree both formats report 0 errors / 78 warnings / 1 note,
# so the SARIF that CI uploads and the text this gate parses agree.
#
# VERSION FLOOR 0.48.1 (#734). agnix <= 0.47.0 ships stale frontmatter/tools
# parsers that emit dozens of phantom errors on a tree that is genuinely clean:
#   0.40.0 -> 57 errors   0.43.0 -> 57   0.47.0 -> 50   0.48.1 -> 10   0.49.0 -> 10
# (counts at the pre-#734 config; the [[overrides]] then take the last two to 0.)
# Those are TOTALS: 10 of each row is real, so the phantom count is the row
# minus 10 and varies across the pre-floor range. Read it off the table rather
# than restating a single figure that can drift from the data beside it.
# Those phantoms are parser bugs, not findings — AS-002 demanding a `name` key
# that this repo's skills omit by design, CC-AG-009 splitting `Bash(git diff:*)`
# on the comma inside its own parens — and .agnix.toml cannot and must not try to
# suppress them. Below the floor this gate therefore SKIPS (77) rather than
# failing: a phantom red here would be the very erosion #734 was filed to end.
# The floor is kept identical to code-scanning.yml's pin; the two move together.
#
# WHY THIS GATE EXISTS. #734 cleared 10 long-standing agnix errors that reddened
# the code-scanning annotation on every PR — including PRs touching none of the
# affected files. That check is informational by design (code-scanning.yml keeps
# it out of the merge-gate aggregation), so nothing was ever blocked. The cost
# was erosion: a permanently-red annotation trains reviewers to ignore the
# surface, at which point a genuinely NEW agnix error lands unnoticed. Having
# paid to clear it, this gate keeps it clear — offline, and before CI.
#
# It covers TWO regressions that look identical from the outside, both silent:
#
#   1. A NEW agnix error in a skill/agent/CLAUDE.md.
#   2. A .agnix.toml `[[overrides]]` path that suppresses NOTHING. Override
#      `paths` match only as `**/`-prefixed SUFFIX globs; a repo-relative path,
#      a `plugins/**/x.md` prefix glob, a `*/x.md`, or an absolute path each
#      matches nothing while agnix still exits 0. A mis-shaped suppression
#      therefore looks correct, reports success, and changes nothing. That is
#      precisely the inert-and-silent failure this repo's 77-sentinel convention
#      exists to prevent, so it gets a real assertion rather than a comment.
#
# SCOPE. Errors only. agnix also emits ~78 warnings (negative-instruction
# phrasing, critical-keyword placement, AGENTS.md character limits) which are
# deliberately NOT gated: only errors drive the red annotation, and #734 put the
# warnings explicitly out of scope. Gating them would convert a large advisory
# backlog into a hard blocker, which is a separate decision to make deliberately.
#
# ABSENT BINARY => exit 77, never 0. agnix is an optional enrichment (ADR
# plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md §2/§4), so
# a host without it must SKIP. run-all.sh renders 77 as `[SKIP] … did not run`
# rather than `[ok]` — a silent skip is indistinguishable from a pass, which is
# how a gate sits inert unnoticed (#538/#571). A PRESENT binary emitting output
# this gate cannot parse is the opposite case: a broken environment, not absent
# tooling, so it FAILS LOUDLY instead of degrading to a skip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

AGNIX_CONFIG_FILE="$REPO_ROOT/.agnix.toml"

# The validate targets, mirroring code-scanning.yml. A space-separated string
# (deliberately word-split at the call site) so the same value serves both the
# invocation and the message a failure prints — one source of truth for "what
# was actually scanned".
AGNIX_TARGETS="CLAUDE.md AGENTS.md plugins"

# The floor this gate refuses to run below (see VERSION FLOOR above). Declared
# HERE, above the absent-binary skip, because the pin cross-check below compares
# it against the workflow pins and must run on a host with no agnix at all.
AGNIX_MIN_VERSION="0.48.1"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

test_suite "agnix error-free (#734)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
SKIP_EXIT_CODE=77

# $1 < $2 ? Compares major.minor.patch numerically, field by field. Defined here
# rather than beside the floor check because the pin cross-check below needs it
# and runs first — on a host with no agnix at all.
#
# Numeric fields, not a string compare: "0.9.0" sorts AFTER "0.48.1" lexically,
# and `sort -V` is a GNU-only flag this repo bans (BSD sort on macOS lacks it).
# Callers must pass a three-field numeric version; both call sites below extract
# theirs with a regex requiring exactly three numeric groups, so a malformed
# value cannot reach here.
agnix_ver_lt() {
    local a_major a_minor a_patch b_major b_minor b_patch
    a_major="${1%%.*}"
    a_patch="${1##*.}"
    a_minor="${1#*.}"
    a_minor="${a_minor%%.*}"
    b_major="${2%%.*}"
    b_patch="${2##*.}"
    b_minor="${2#*.}"
    b_minor="${b_minor%%.*}"
    [ "$a_major" -ne "$b_major" ] && { [ "$a_major" -lt "$b_major" ] && return 0 || return 1; }
    [ "$a_minor" -ne "$b_minor" ] && { [ "$a_minor" -lt "$b_minor" ] && return 0 || return 1; }
    [ "$a_patch" -lt "$b_patch" ]
}

# --- Pin agreement: the three version literals must not drift ----------------
# The agnix version lives as three independent literals that must move together:
# the `npm install -g agnix@X` pin in ci.yml, the same pin in code-scanning.yml,
# and AGNIX_MIN_VERSION here. Every one of those three files CLAIMS in a comment
# that they "move together" — and until this check, nothing enforced it. A
# comment asserting a property the code does not have is worse than no comment:
# it tells the next reader the drift is already handled.
#
# Two drifts this catches, both silent today:
#   * ci.yml and code-scanning.yml diverging — the same tree then gets scanned by
#     two different agnix versions, so a green local gate can sit beside a red PR
#     annotation (or the reverse), which is exactly the erosion #734 set out to
#     end.
#   * Both CI pins bumped while MIN_VERSION is left behind — `min <= actual`
#     stays true, so the gate keeps passing and the stale floor is never noticed.
#
# Deliberately placed ABOVE the absent-binary skip and asserted through the
# harness (not an early `exit`): it is a pure text comparison over files in the
# repo, needs no agnix binary, and would otherwise vanish behind sentinel 77 on
# precisely the hosts where nobody is watching. Extracting via grep+sed keeps it
# offline and jq-free, matching this gate's other parsing.
agnix_pin_in() {
    # Echo the version from the first `agnix@<ver>` npm install pin in $1, or
    # nothing when the file carries none.
    #
    # `|| true` on the grep is load-bearing under `set -euo pipefail`: a grep
    # that matches nothing exits 1, which fails the whole pipeline and aborts
    # the script mid-substitution. The gate would then die with a bare exit
    # status instead of running test_pins_found — non-zero, but reporting
    # nothing about WHY. Absorbing it here lets an empty result reach the
    # assertion, which names the actual problem.
    command grep -oE 'agnix@[0-9]+\.[0-9]+\.[0-9]+' "$1" 2>/dev/null |
        command head -n 1 | command sed -n 's/^agnix@//p' || true
}

CI_PIN="$(agnix_pin_in "$WORKFLOW_DIR/ci.yml")"
SCAN_PIN="$(agnix_pin_in "$WORKFLOW_DIR/code-scanning.yml")"

test_pins_found() {
    # Fail loud rather than pass vacuously: if the pins stop being greppable
    # (step rewritten, file renamed), the two assertions below would compare
    # "" against "" and report agreement between two things that do not exist.
    assert_not_empty "$CI_PIN" \
        "ci.yml must carry a greppable 'agnix@X.Y.Z' install pin (found none — did the install step change shape?)"
    assert_not_empty "$SCAN_PIN" \
        "code-scanning.yml must carry a greppable 'agnix@X.Y.Z' install pin (found none — did the install step change shape?)"
}

test_pins_agree() {
    assert_equals "$CI_PIN" "$SCAN_PIN" \
        "ci.yml and code-scanning.yml must pin the SAME agnix version, or the local gate and the PR annotation scan the same tree with different parsers"
}

test_floor_not_stale() {
    # The floor must not exceed the pinned version, which would make CI install
    # an agnix this gate then refuses to run against — a permanent silent SKIP.
    local ok=1
    if [ -n "$CI_PIN" ] && agnix_ver_lt "$CI_PIN" "$AGNIX_MIN_VERSION"; then
        ok=0
    fi
    assert_equals "1" "$ok" \
        "CI pins agnix $CI_PIN but this gate's floor is $AGNIX_MIN_VERSION — the gate would SKIP in CI forever. Raise the pin or lower the floor."
}

run_test test_pins_found "agnix install pins are discoverable in both workflows"
run_test test_pins_agree "ci.yml and code-scanning.yml pin the same agnix version"
run_test test_floor_not_stale "Gate floor is not above the CI pin"

# agnix is an OPTIONAL enrichment — absent binary skips the REST of the gate
# rather than failing it or, worse, passing quietly. The pin checks above have
# already run and are already recorded, so a drift still fails here even on a
# host with no agnix.
if ! command -v agnix >/dev/null 2>&1; then
    skip_test "agnix not on PATH — optional enrichment (ADR §2/§4); install to run this gate"
    # A pin-drift failure must NOT be masked by the skip sentinel: report first,
    # and only exit 77 when the checks above actually passed.
    if generate_report; then
        exit "$SKIP_EXIT_CODE"
    fi
    exit 1
fi

# Below the floor, agnix's own parser is wrong about this tree (see the VERSION
# FLOOR note above), so the 0-error contract cannot hold and a failure here would
# report a defect that does not exist. Skip instead — same sentinel, same
# `[SKIP] … did not run` rendering, so it is never mistaken for a pass.
#
# Unparsable output is NOT treated as too-old — it falls through to the
# fail-loud path below, where a broken binary belongs. AGNIX_MIN_VERSION and the
# numeric comparator agnix_ver_lt are both declared above, next to the pin
# cross-check that shares them.
#
# The prefix is `^[^0-9]*` (zero or more), NOT a bare `[^0-9]` requiring exactly
# one character before the digits. agnix 0.49.0 prints `agnix 0.49.0`, so the
# stricter form happens to work today — but many npm CLIs print a BARE semver
# (`0.49.0`) with nothing before it, which the one-char form cannot match at the
# start of a line. That failure is silent in the worst way: AGNIX_VERSION comes
# back empty, the `-n` guard below short-circuits, the below-floor SKIP never
# fires, and a pre-floor agnix gets scanned anyway — reporting its phantom
# errors as real test_zero_errors failures instead of "upgrade to run this gate".
AGNIX_VERSION="$(agnix --version 2>/dev/null | command sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | command head -n 1)"

if [ -n "$AGNIX_VERSION" ] && agnix_ver_lt "$AGNIX_VERSION" "$AGNIX_MIN_VERSION"; then
    skip_test "agnix $AGNIX_VERSION < $AGNIX_MIN_VERSION — pre-floor parsers emit phantom errors (#734); upgrade to run this gate"
    # As at the absent-binary skip above: report first so a pin-drift failure
    # already recorded cannot be masked by the 77 sentinel.
    if generate_report; then
        exit "$SKIP_EXIT_CODE"
    fi
    exit 1
fi

# The config is NOT optional once agnix is present: running without it would let
# agnix fall back to its own discovery and report a different error set than CI.
# A missing config is a repo defect, so it fails loudly rather than skipping.
if [ ! -f "$AGNIX_CONFIG_FILE" ]; then
    test_missing_config() {
        assert_file_exists "$AGNIX_CONFIG_FILE" \
            ".agnix.toml must exist — it is the operator-controlled config CI runs with"
    }
    run_test test_missing_config "Config present"
    generate_report
    exit $?
fi

# Run once, up front; every test below asserts against this captured output.
# `|| true` because agnix exits non-zero when it FINDS issues — that is the
# condition under test, not a harness failure.
AGNIX_OUT=""
AGNIX_RC=0
# shellcheck disable=SC2086  # AGNIX_TARGETS is a deliberate multi-arg word split
AGNIX_OUT="$(cd "$REPO_ROOT" && agnix --target claude-code \
    --config "$AGNIX_CONFIG_FILE" validate $AGNIX_TARGETS 2>&1)" || AGNIX_RC=$?

# The summary line agnix prints last: "Found N errors, M warnings".
SUMMARY_LINE="$(printf '%s\n' "$AGNIX_OUT" | command grep -E '^Found [0-9]+ error' | command tail -n 1 || true)"

# Extract N from that line. Empty when the line is absent/unparsable, which the
# fail-loud test below turns into a hard failure.
ERROR_COUNT="$(printf '%s\n' "$SUMMARY_LINE" | command sed -n 's/^Found \([0-9][0-9]*\) error.*/\1/p')"

# --- Fail loud on unparsable output -----------------------------------------
# A present binary whose output this gate cannot read is a BROKEN ENVIRONMENT
# (agnix changed its summary format, or crashed on a bad flag / unparsable
# config). Distinct from the absent-binary skip above: degrading this to a skip
# would let a real breakage read as "not run", and a gate that cannot parse its
# own input must never report success.
test_output_parsable() {
    assert_not_empty "$ERROR_COUNT" \
        "agnix output must carry a parsable 'Found N errors' summary (rc=$AGNIX_RC). Output tail: $(printf '%s\n' "$AGNIX_OUT" | command tail -n 3 | command tr '\n' ' ')"
}

# --- The gate itself ---------------------------------------------------------
test_zero_errors() {
    # Guard on the parse: without it, an unparsable summary would compare ""
    # against "0" and fail with a confusing message instead of the specific one
    # test_output_parsable already emits.
    if [ -z "$ERROR_COUNT" ]; then
        skip_test "summary unparsable — reported by the parsability test above"
        return 0
    fi

    local detail=""
    if [ "$ERROR_COUNT" != "0" ]; then
        # Surface the actual error lines, not just the count — a bare "expected 0
        # got 3" sends the reader back to re-run the tool by hand.
        #
        # ` error: ` is verified against real output, not inferred from the
        # summary-line pattern above (which is a different format and proves
        # nothing about this one). A per-finding line at 0.49.0 reads:
        #   /abs/path/agents/issue-filer.md:1:0 error: Referenced skill … not found
        # i.e. `<path>:<line>:<col> <level>: <msg>` — a space on each side of the
        # level. If a future agnix drops those spaces this silently yields an
        # EMPTY detail on a real failure; the count assertion still fails, but
        # the message loses its evidence, so re-check the format when bumping.
        detail="$(printf '%s\n' "$AGNIX_OUT" | command grep -E ' error: ' | command head -n 10 | command tr '\n' ' ')"
    fi

    assert_equals "0" "$ERROR_COUNT" \
        "agnix must report 0 errors over $AGNIX_TARGETS — a new error, or a .agnix.toml override whose glob silently matched nothing (see the GLOB SHAPE note in .agnix.toml). Errors: $detail"
}

# --- Corpus sanity: the gate is not passing on an empty scan ------------------
# A run that walked zero files would trivially report 0 errors. Without this, a
# broken path argument or an over-broad `exclude` would turn the gate inert while
# still printing green — the same tautology class the suppressions above guard.
test_corpus_non_empty() {
    local checked
    # Matches agnix's per-finding lines (`<file>:<line>:<col> <level>: <msg>`).
    # Not anchored to a leading `/`: agnix prints absolute paths today, but the
    # assertion is "diagnostics were produced", and anchoring it to a path shape
    # that is not part of any contract would turn a cosmetic output change into a
    # spurious failure.
    checked="$(printf '%s\n' "$AGNIX_OUT" | command grep -cE ':[0-9]+:[0-9]+ (warning|error|info):' || true)"

    # `if`, not `[ ... ] && x=1`: under `set -e` a whole AND-list that evaluates
    # false is a failing command, so the shorthand would abort this function
    # before its assertion ran — the check would vanish instead of failing.
    local has_findings=0
    if [ "${checked:-0}" -ge 1 ]; then
        has_findings=1
    fi

    assert_equals "1" "$has_findings" \
        "agnix must actually have walked the corpus (expected diagnostic lines; found $checked). Zero means the scan matched no files, making the 0-error result meaningless. NOTE: this leans on the ~78 known warnings still being present — if a future change legitimately clears them all, replace this proxy rather than deleting it."
}

run_test test_output_parsable "agnix output carries a parsable summary (fail-loud, not skip)"
run_test test_zero_errors "0 agnix errors over CLAUDE.md AGENTS.md plugins"
run_test test_corpus_non_empty "Scan is non-empty (gate is not a no-op)"

generate_report
