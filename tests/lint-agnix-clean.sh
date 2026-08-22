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
# than assumed: on this tree both formats report the same 0 errors alongside the
# same advisory warning/note counts, so the SARIF that CI uploads and the text
# this gate parses agree. Stated as agreement rather than as a warning FIGURE on
# purpose — the figure drifts with ordinary prose edits (it has already gone 78
# -> 80), and a comment carrying a number nobody defends rots into a false claim.
#
# The one place a count IS load-bearing is the corpus floor below, which reads
# `files_checked` from `--format json`. That is a different measurement in kind:
# how many files the scan REACHED, not how dirty they were. See AGNIX_MIN_FILES.
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
# SCOPE. Errors only. agnix also emits a standing backlog of warnings
# (negative-instruction phrasing, critical-keyword placement, AGENTS.md character
# limits) which are deliberately NOT gated: only errors drive the red annotation,
# and #734 put the warnings explicitly out of scope. Gating them would convert a
# large advisory backlog into a hard blocker, which is a separate decision to
# make deliberately.
#
# Nothing in this gate keys off the SIZE of that backlog, which is what #739
# fixed. The corpus-sanity check below used to assert "some diagnostic line was
# printed" — true today only because those warnings exist — so CLEARING them, an
# unambiguously good thing, would have reddened the gate on a better tree and
# invited deleting the guard rather than replacing it. It now floors
# `files_checked` instead, which measures scan REACH and holds at 0 warnings.
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

# Corpus floor for the vacuity guard (#739): the fewest files a scan of
# AGNIX_TARGETS may report having walked before the 0-error result stops meaning
# anything.
#
# CALIBRATION. Measured per target at time of writing: `plugins` 108,
# `CLAUDE.md` 1, `AGENTS.md` 1 (a symlink to CLAUDE.md, but counted as its own
# walked file rather than deduplicated) — 110 total. The regression this
# defends against is a TARGET THAT STOPS MATCHING (a rename, a mis-shaped
# `exclude`, a path argument dropped from the invocation), which takes the count
# to ~2 or 0 — not per-file churn, which moves it by ones. So the floor sits far
# below today's count on purpose: low enough that ordinary growth and pruning in
# either direction never trip it, high enough that losing `plugins` — the target
# carrying ~98% of the corpus — cannot pass.
#
# It is a FLOOR, not an equality: pinning the exact number would fail on every
# added or deleted plugin file, which is the churn-coupling #739 removed. Raise
# it only if the corpus grows so much that 60 stops being a meaningful fraction.
AGNIX_MIN_FILES=60

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

# Echo the `files_checked` count from agnix `--format json` output on STDIN, or
# nothing when the field is absent or malformed (#739).
#
# Reads stdin rather than taking the JSON as an argument: the payload is ~100 KB
# on this tree, and passing it through a positional would push it onto the
# command line for no benefit.
#
# A two-stage grep-then-sed rather than one `sed`, matching agnix_pin_in above:
# `grep -oE` isolates the whole field first, so the `sed` that pulls the digits
# out cannot match a `files_checked`-shaped substring elsewhere in a diagnostic
# MESSAGE. The pattern accepts optional whitespace on both sides of the colon —
# agnix pretty-prints today, but a compact `{"files_checked":110}` is the same
# JSON and must parse identically.
#
# Portability (this repo bans GNU-only regex — macOS ships BSD grep/sed): POSIX
# classes `[[:space:]]` and `[0-9]`, never `\s` or `\d`, and `-E` rather than
# `grep -P`, which BSD grep does not have at all. That failure would be silent —
# the pattern would stop matching, the count would come back empty — which is
# why the caller treats an empty result as a hard failure rather than a skip.
#
# `head -n 1` takes the FIRST match: `files_checked` is a top-level scalar and
# appears once, but a defensive first-wins costs nothing and keeps the contract
# single-valued (same choice, same reason, as agnix_pin_in).
#
# `|| true` is load-bearing under `set -euo pipefail`: a grep that matches
# nothing exits 1 and would abort the script mid-substitution, killing the gate
# with a bare status instead of letting the empty value reach the assertion that
# explains it.
agnix_files_checked() {
    command grep -oE '"files_checked"[[:space:]]*:[[:space:]]*[0-9]+' |
        command sed -n 's/.*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
        command head -n 1 || true
}

# Echo 1 when a scan that walked $1 files meets the floor $2, else 0 (#739).
#
# Extracted from test_corpus_reached rather than left inline so the unit suite
# can drive its boundary directly. The live gate cannot: it only ever sees the
# real corpus size, so it can never present the exactly-at-the-floor input that
# distinguishes `-ge` from `-gt`. Mutation-verified — `-le` and a swapped
# operand order both fail the live gate at once, but the `-gt` off-by-one
# survives it, and that is precisely the case a unit test makes trivial.
#
# The floor is INCLUSIVE: a scan that walked exactly AGNIX_MIN_FILES files has
# met it. Reading `AGNIX_MIN_FILES` as "the fewest files that still count" is
# what makes the constant's name true.
#
# Echoes a flag instead of signalling through the exit status, deliberately
# unlike its sibling agnix_ver_lt: the caller assigns the result under `set -e`,
# where a function returning 1 would abort the test body before its assertion
# ran. (agnix_ver_lt gets away with the exit-status idiom only because both of
# its call sites are `if`-guarded.)
agnix_corpus_reached() {
    if [ "$1" -ge "$2" ]; then
        command printf '1\n'
    else
        command printf '0\n'
    fi
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

# --- Signature verification: both install sites must actually check ----------
# (#740) The pin fixes WHICH version npm serves; it says nothing about whether
# the tarball for that version is the one its publisher signed. Both workflows
# run `npm audit signatures` before installing agnix. These checks assert the
# code is still there and still ordered correctly.
#
# Placed with the pin family, ABOVE the absent-binary skip, for the same reason:
# pure text comparison over files in the repo, needs no agnix, and would
# otherwise vanish behind sentinel 77 on exactly the hosts where nobody looks.

# Echo the line number of the first NON-COMMENT line of $1 matching $2, or
# nothing when there is none.
#
# Comment-stripping is the entire point, not defensive tidying. Both workflows
# carry a paragraph EXPLAINING the verification, and that prose contains the
# literal strings these tests search for. A plain `grep 'npm audit signatures'`
# would therefore be satisfied by the explanation of a check that had been
# deleted — delete the code, keep the comment, gate stays green. The filter is
# what makes these assertions about the workflow's behavior rather than about
# its documentation.
#
# The comment filter is ANCHORED at the `grep -n` line-number prefix
# (`^[0-9]*:[[:space:]]*#`), so it drops a line whose content begins with `#`
# while keeping a code line that merely has a trailing comment. Anchoring is not
# style: unanchored, the same pattern would also match a colon-then-`#` sequence
# occurring anywhere in a line's TEXT, silently discarding a real code line that
# happened to contain one.
#
# `-e` before the pattern is load-bearing: a search string starting with `-`
# (`--ignore-scripts`, one of this gate's two searches) is otherwise parsed as
# grep OPTIONS, not as a pattern. That failure is loud here only because the
# assertion is written to fail on an empty result.
#
# Portability (this repo bans GNU-only regex — macOS ships BSD grep): POSIX
# `[[:space:]]`, `-F` for the fixed strings, never `\s` or `grep -P`.
#
# `|| true` is load-bearing under `set -euo pipefail`: a grep matching nothing
# exits 1 and would abort the script mid-substitution, killing the gate with a
# bare status instead of letting the empty value reach the assertion that names
# the real problem.
agnix_code_line_no() {
    command grep -nF -e "$2" "$1" 2>/dev/null |
        command grep -v '^[0-9][0-9]*:[[:space:]]*#' |
        command sed -n 's/^\([0-9][0-9]*\):.*/\1/p' |
        command head -n 1 || true
}

test_signature_check_present() {
    local f
    for f in ci.yml code-scanning.yml; do
        assert_not_empty "$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'npm audit signatures')" \
            "$f must RUN 'npm audit signatures' before installing agnix (#740) — found no non-comment line invoking it. A pinned version is not a verified tarball."
    done
}

test_signature_check_is_scoped_to_the_scratch_tree() {
    # Presence is not enough: `npm audit signatures` audits whatever tree it is
    # invoked in. Run from the job's own working directory it would audit
    # something other than the agnix install — a check that runs, exits, and
    # means nothing about the package being installed. The `cd "$verify_dir"`
    # is what points it at the tree actually under test.
    local f
    for f in ci.yml code-scanning.yml; do
        assert_not_empty "$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'cd "$verify_dir" && npm audit signatures')" \
            "$f must run 'npm audit signatures' INSIDE \$verify_dir (#740) — an audit run anywhere else verifies a different tree than the one being installed, and reports success without checking agnix at all."
    done
}

test_global_install_uses_the_verified_tree() {
    # The strongest property in this change, and the one worth guarding hardest:
    # the bytes that were audited must be the bytes that get installed.
    #
    # `npm install -g "$pin"` would re-resolve the package from the registry — a
    # second, independent fetch that the audit never saw. Registry immutability
    # and cache reuse usually make the two identical, but nothing here enforces
    # that, and `-g` is where postinstall runs. Installing the verified
    # DIRECTORY removes the assumption entirely.
    #
    # Asserted as a positive match on the verified path rather than as an
    # absence of `"$pin"`: an absence check would also pass if the install line
    # were deleted outright.
    local f
    for f in ci.yml code-scanning.yml; do
        assert_not_empty "$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'npm install -g "$verify_dir/node_modules/agnix"')" \
            "$f's global install must read the VERIFIED tree (\$verify_dir/node_modules/agnix), not re-resolve \$pin from the registry (#740) — re-resolving audits one fetch and installs another, leaving the postinstall that actually runs unverified."
    done
}

test_scratch_dir_is_cleaned_up() {
    # A stray mktemp -d per run is minor on an ephemeral runner, but the pairing
    # is what keeps the step self-contained — and a future edit that drops the
    # cleanup while keeping the mktemp is exactly the kind of silent drift this
    # gate family exists to catch.
    #
    # Ordering is asserted too, and it is the load-bearing half now that the
    # global install READS $verify_dir: a cleanup hoisted above that install
    # would delete the verified tree before it is consumed. Presence alone would
    # stay green through that regression.
    local f cleanup_line install_line ok
    for f in ci.yml code-scanning.yml; do
        cleanup_line="$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'rm -rf "$verify_dir"')"
        assert_not_empty "$cleanup_line" \
            "$f creates a scratch \$verify_dir with mktemp -d and must remove it (#740) — found no non-comment 'rm -rf \"\$verify_dir\"'."

        install_line="$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'npm install -g "$verify_dir/node_modules/agnix"')"
        # Fail loud rather than pass vacuously when either line is missing —
        # comparing two empty strings would report correct ordering between two
        # things that do not exist.
        ok=0
        if [ -n "$cleanup_line" ] && [ -n "$install_line" ] && [ "$cleanup_line" -gt "$install_line" ]; then
            ok=1
        fi
        assert_equals "1" "$ok" \
            "$f must remove \$verify_dir (line ${cleanup_line:-none}) AFTER installing from it (line ${install_line:-none}) (#740) — cleaning up first deletes the verified tree before the install reads it."
    done
}

test_scratch_install_ignores_scripts() {
    # The pre-verification install must not run the package's own scripts. The
    # order is verify-THEN-install precisely so a tampered tarball's postinstall
    # never executes; without this flag the scratch install runs that code
    # first and audits afterward, which is the same as not auditing at all.
    # The check survives as a check only while this flag does.
    local f line
    for f in ci.yml code-scanning.yml; do
        line="$(agnix_code_line_no "$WORKFLOW_DIR/$f" '--ignore-scripts')"
        assert_not_empty "$line" \
            "$f's pre-verification agnix install must pass --ignore-scripts (#740) — without it a tampered tarball's postinstall runs BEFORE its signature is checked, leaving a check that looks right and protects nothing."
    done
}

test_signature_check_precedes_global_install() {
    # Ordering is the whole security property. An audit placed after the global
    # install verifies bytes that have already been unpacked and executed —
    # every assertion above would still pass while the check protected nothing.
    local f audit_line install_line ok
    for f in ci.yml code-scanning.yml; do
        audit_line="$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'npm audit signatures')"
        install_line="$(agnix_code_line_no "$WORKFLOW_DIR/$f" 'npm install -g')"
        # Fail loud rather than pass vacuously when either line is missing:
        # comparing two empty strings would report correct ordering between two
        # things that do not exist.
        ok=0
        if [ -n "$audit_line" ] && [ -n "$install_line" ] && [ "$audit_line" -lt "$install_line" ]; then
            ok=1
        fi
        assert_equals "1" "$ok" \
            "$f must run 'npm audit signatures' (line ${audit_line:-none}) BEFORE 'npm install -g' (line ${install_line:-none}) (#740) — verifying after the global install audits bytes already unpacked and executed."
    done
}

run_test test_signature_check_present "Both workflows verify agnix's registry signature"
run_test test_signature_check_is_scoped_to_the_scratch_tree "Signature check runs inside \$verify_dir"
run_test test_scratch_install_ignores_scripts "Pre-verification install passes --ignore-scripts"
run_test test_global_install_uses_the_verified_tree "Global install reads the verified tree, not the registry"
run_test test_signature_check_precedes_global_install "Signature check precedes the global install"
run_test test_scratch_dir_is_cleaned_up "Scratch verify_dir is removed"

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

# A SECOND invocation, in JSON, read only for `files_checked` (#739) — the
# corpus-reach measurement the text format does not carry at all.
#
# Additive rather than a rewrite of this gate to JSON. The text run above stays
# primary: it feeds test_zero_errors AND the human-readable ` error: ` detail
# lines that a failure message quotes, which a JSON port would have to
# reconstruct. Running agnix twice is the cheaper trade — measured at 78ms for
# the full JSON pass, against the header's standing argument for not making a
# yes/no gate depend on `jq`.
#
# `--config` precedes `validate`: it is a global (clap) flag, and agnix rejects
# `validate --config …` outright — the same ordering trap documented in
# check-ai-config/agnix-normalize.sh.
#
# VERIFIED AT THE FLOOR, not just at the version this was developed on. The
# concern is real in shape: this gate RUNS at AGNIX_MIN_VERSION (the skip is for
# versions strictly BELOW it), so a `--format json` introduced after 0.48.1 would
# make the corpus check report "broken agnix" on a supported host. Checked
# against a real 0.48.1 install rather than reasoned about: it carries
# `--format <FORMAT> (text, json, sarif, or github)` and emits the same
# `"files_checked": 110` as 0.49.0. So the floor needs no raise and this check
# needs no version gate of its own. Re-verify if the floor ever moves DOWN.
#
# stderr is dropped and a non-zero rc absorbed for the same reason as the text
# run: agnix exits non-zero when it FINDS things, which is not a harness
# failure. A genuinely broken run yields no parsable count, and the assertion
# below fails loudly on exactly that.
AGNIX_JSON=""
# shellcheck disable=SC2086  # AGNIX_TARGETS is a deliberate multi-arg word split
AGNIX_JSON="$(cd "$REPO_ROOT" && agnix --target claude-code \
    --config "$AGNIX_CONFIG_FILE" --format json validate $AGNIX_TARGETS 2>/dev/null)" || true

FILES_CHECKED="$(printf '%s\n' "$AGNIX_JSON" | agnix_files_checked)"

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
#
# Keyed on `files_checked` from the JSON run, NOT on diagnostics being present
# (#739). The original asserted that agnix printed at least one finding line,
# which — since this gate scopes itself to errors and the tree has none — really
# asserted the standing WARNING backlog still existed. That made a warning
# cleanup, a strict improvement, fail the guard on a better tree, where the
# expedient fix is to delete it. `files_checked` measures what the guard actually
# means ("the scan reached the corpus") and is unchanged by how clean the corpus
# is: it still reads 110 on a tree with zero findings of any level.
#
# It also detects something the old proxy structurally could not: a SHRINKING
# corpus. A target path that silently stops matching still emits warnings from
# the targets that do match, so the diagnostics-present check stayed green; the
# file count drops and this one fails.
test_corpus_reached() {
    # A present binary whose JSON carries no parsable count is a BROKEN
    # ENVIRONMENT, not absent tooling — fail loudly rather than skip, exactly as
    # test_output_parsable does for the text summary. Degrading this to a skip
    # would restore the inert-but-green state the whole gate exists to prevent.
    if [ -z "$FILES_CHECKED" ]; then
        assert_not_empty "$FILES_CHECKED" \
            "agnix --format json must carry a parsable top-level \"files_checked\" (found none). This is a broken agnix/config, not an absent one — the binary ran. JSON tail: $(printf '%s\n' "$AGNIX_JSON" | command tail -n 5 | command tr '\n' ' ')"
        return 0
    fi

    # The comparison itself lives in agnix_corpus_reached (above) rather than
    # inline, so the unit suite can drive its BOUNDARY. Mutation-verified that
    # this extraction earns its keep: flipping the operator to `-le` or swapping
    # the operands both fail the live gate immediately (110 is not <= 60), but
    # `-ge` -> `-gt` SURVIVES it — the live gate can only ever present the real
    # corpus size, so it cannot produce the exactly-at-the-floor input that
    # separates the two. That one case is untestable here by construction and
    # trivial in a unit test.
    local reached
    reached="$(agnix_corpus_reached "$FILES_CHECKED" "$AGNIX_MIN_FILES")"

    assert_equals "1" "$reached" \
        "agnix walked only $FILES_CHECKED files, below the floor of $AGNIX_MIN_FILES — the 0-error result above is meaningless. Either a target in '$AGNIX_TARGETS' stopped matching (renamed/moved path, or one dropped from the invocation), or an .agnix.toml \`exclude\` grew over-broad. Fix the scan rather than lowering the floor."
}

run_test test_output_parsable "agnix output carries a parsable summary (fail-loud, not skip)"
run_test test_zero_errors "0 agnix errors over CLAUDE.md AGENTS.md plugins"
run_test test_corpus_reached "Scan reached the corpus (gate is not a no-op)"

generate_report
