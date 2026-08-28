#!/usr/bin/env bash
# Definition-shaped assertion gate (issue #830).
#
# `assert_file_contains` is a raw grep over the whole file, so it matches
# COMMENTS as readily as code. When the assertion's job is "this setting is
# defined", the prose explaining that setting satisfies it on its own: delete the
# definition, keep the comment, and the test stays green. This repo's convention
# is to explain every non-obvious setting directly above it, so a
# definition-shaped assertion and its explanatory prose reliably co-occur — which
# is what makes the hole systematic rather than incidental (#737 saw it first,
# #825 fixed one instance, #830 swept the class).
#
# Two live instances were measured before this gate existed:
#
#   validate-lint-gates.sh   commenting out `SKIP_EXIT_CODE=77` in lint-python.sh
#                            left the raw-text case GREEN while four behavioural
#                            cases went red — masked by its siblings.
#   validate-prose-budget.sh widening PLUGINS_DIR to $REPO_ROOT (the exact
#                            regression its own comment says it guards) kept the
#                            suite 26/26 green — NOT masked. A live hole.
#
# #830 swept both to `assert_file_defines`. This gate is what stops the next
# unanchored one being written — the same answer this repo gives the whole
# "convention nothing enforces" class: lint-command-refs.sh, lint-action-pins.sh,
# lint-harness-refs.sh.
#
# THE RULE. An `assert_file_contains` / `assert_file_not_contains` whose PATTERN
# is definition-shaped must use `assert_file_defines` instead. Definition-shaped
# means the pattern begins with a NAME followed by `=` — `SKIP_EXIT_CODE=77`,
# `PLUGINS_DIR="..."`, `ruff_version="$(...)"`. A pattern that merely CONTAINS an
# `=` further in (`--version $GC_INSTALL_VERSION`, `install --force "ruff==$V"`)
# is not a definition and is left alone.
#
# WHY THE NAME MUST LEAD. The narrowness is the whole design. Flagging every
# pattern containing `=` would sweep in ~40 phrase assertions and one sandbox
# artifact check, none of which has the defect, and a gate that cries wolf on
# two-thirds of its corpus gets exempted into uselessness. The ~60 assertions
# over runtime artifacts ($WORKDIR/*.err, feed.jsonl, $sb/claude.json) are
# likewise not at risk: those files are generated per-run and contain no
# committed prose to collide with.
#
# THE EXEMPTION. `# lint-allow-unanchored: <reason>` on the assertion line, or
# anywhere in the contiguous comment block directly above it, matching the
# existing `# lint-allow-path` / `# lint-allow-gnu-regex` convention. The block
# (rather than a one-line lookback) is deliberate: a reason worth writing often
# runs to two or three lines. The known legitimate case is an assignment
# that is not line-initial and therefore cannot be line-anchored at all — the
# justfile's `RUFF="uvx ruff@$RUFF_PIN"` sits mid-line in a backslash-joined
# POSIX-sh recipe. A reason is REQUIRED: a bare marker does not exempt, because
# the reason is the only thing that distinguishes a considered exception from a
# silenced failure.
#
# CORPUS: tests/**/*.sh, minus two specimen-bearing files (see the exclusion
# note beside HARNESS_LIB below). Both exclusions are by explicit path, and
# test_exclusions_are_deliberate pins them so neither can silently widen into
# "skip anything under lib/" or "skip every lint-*.sh".
#
# Detection is awk, not grep: BSD and GNU grep disagree on `\s`/`\w`/`\|` and
# BSD has no `grep -P`, so a GNU-only pattern would silently match NOTHING on
# macOS and report a clean scan of zero rows — the failure mode CLAUDE.md
# singles out, and a particularly embarrassing one for this gate to have. awk's
# regex engine behaves the same on both. POSIX classes only.
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

TESTS_DIR="$SCRIPT_DIR"

# Two files are excluded, both because their "violations" are DELIBERATE
# specimens rather than assertions the suite relies on:
#
#   lib/harness.sh   defines both helpers and documents the bad pattern.
#   this gate        its fixtures are heredoc'd violating lines, which is how
#                    test_detection_fires_and_is_narrow proves the scanner has
#                    teeth. Excluding by path beats teaching the scanner to skip
#                    heredocs: that parse is fragile, and getting it subtly wrong
#                    would make the scanner skip real code silently — the exact
#                    false-green this gate exists to prevent.
#
# Both exclusions are by EXPLICIT PATH and pinned by
# test_exclusions_are_deliberate, so neither can widen unnoticed.
HARNESS_LIB="$SCRIPT_DIR/lib/harness.sh"
SELF_PATH="$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")"

# Cap on violation detail lines so a large regression stays readable.
MAX_DETAIL=40

test_suite "Definition-shaped assertions (#830)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
# A silent skip is indistinguishable from a pass, which is how a gate sits inert
# unnoticed (#538, #571) — so this must never be a bare exit 0.
SKIP_EXIT_CODE=77

if ! command -v awk >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — awk not available (install awk to check definition assertions)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Detection ---------------------------------------------------------------

# The awk program, held as a constant so the tests drive the SAME text the real
# scan does. Emits one `<line>:<text>` row per offending assertion.
#
# An exemption marker may sit on the assertion line or in the CONTIGUOUS COMMENT
# BLOCK immediately above it — the assertion lines here are long and routinely
# wrap, so demanding a same-line marker would push authors to squeeze the reason
# out. A one-line lookback is not enough for the same reason: a reason worth
# writing often runs to two or three lines, and the marker then falls out of the
# window while the comment it introduces is still directly above the assertion.
# (Observed while writing this gate — a two-line rationale silently stopped
# exempting.) The block ends at the first non-comment line, so a marker cannot
# reach across code into an unrelated assertion.
#
# The pattern argument is isolated as the text between the SECOND quote pair:
# `assert_file_contains "$FILE" 'PATTERN'`. Both quote styles appear in the
# corpus, so the match runs twice rather than assuming one.
SCAN_AWK='
function is_exempt(s) {
    return s ~ /#[[:space:]]*lint-allow-unanchored:[[:space:]]*[^[:space:]]/
}
function is_comment_line(s) {
    sub(/^[[:space:]]+/, "", s)
    return substr(s, 1, 1) == "#"
}
# A pattern is definition-shaped when a NAME leads and is immediately followed
# by "=". NAME is the usual identifier set plus "." (dotted config keys).
function is_definition(p) {
    return p ~ /^[A-Za-z_][A-Za-z0-9_.]*=/
}
# Isolate the PATTERN argument: the second quoted run of
# `assert_file_contains "$FILE" <pattern>`. Both quote styles appear in the
# corpus, so try each rather than assuming one.
function pattern_of(line,   rest) {
    rest = line
    sub(/^.*assert_file_(not_)?contains[[:space:]]+/, "", rest)
    if (!match(rest, /^"[^"]*"[[:space:]]+/)) return ""
    rest = substr(rest, RSTART + RLENGTH)
    if (match(rest, /^"[^"]*"/)) return substr(rest, RSTART + 1, RLENGTH - 2)
    if (match(rest, /^'"'"'[^'"'"']*'"'"'/)) return substr(rest, RSTART + 1, RLENGTH - 2)
    return ""
}
{
    # JOIN CONTINUATION LINES FIRST. These assertions routinely wrap with a
    # trailing backslash — tests/validate-free-port.sh:376 puts the call and
    # "$gate" on one line and the PATTERN on the next — and a per-line scan sees
    # neither half: the call line has no closing quote for the pattern, and the
    # pattern line does not contain the function name. The gate would then be
    # blind to exactly the wrapped style this repo writes most, which is the same
    # silent false-negative #830 exists to prevent, reached by a different route.
    #
    # Accumulate into `buf` until a line does not end in `\`, then judge the
    # joined text. `first_nr` keeps the report pointing at the line the call
    # STARTS on, which is where a reader has to go to fix it.
    raw = $0
    if (buf == "") first_nr = NR
    stripped = raw
    cont = (stripped ~ /\\[[:space:]]*$/)
    sub(/[[:space:]]*\\[[:space:]]*$/, "", stripped)
    buf = (buf == "") ? stripped : buf " " stripped
    if (cont) next

    line = buf
    buf = ""

    pat = (line ~ /assert_file_(not_)?contains/) ? pattern_of(line) : ""

    if (pat != "" && is_definition(pat)) {
        # Exempt when the marker is on this line, or anywhere in the contiguous
        # comment block directly above it.
        if (!is_exempt(line) && !block_exempt) printf "%d:%s\n", first_nr, pat
    }

    # Maintain the comment-block state AFTER judging this line, so a marker on
    # the assertion line itself never leaks onto the next assertion.
    if (is_comment_line(line)) {
        if (is_exempt(line)) block_exempt = 1
    } else {
        block_exempt = 0
    }
}
END {
    # A file whose last line ends in a backslash leaves buf unjudged. Rare, but
    # dropping it silently is the failure mode this whole gate is about.
    if (buf != "") {
        pat = (buf ~ /assert_file_(not_)?contains/) ? pattern_of(buf) : ""
        if (pat != "" && is_definition(pat) && !is_exempt(buf) && !block_exempt)
            printf "%d:%s\n", first_nr, pat
    }
}
'

# scan_file <path> — sets CUR_VIOLATIONS to zero or more "rel:line: pattern" rows.
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local row lineno pat rel
    rel="${file#"$REPO_ROOT"/}"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        lineno="${row%%:*}"
        pat="${row#*:}"
        CUR_VIOLATIONS+="${rel}:${lineno}: ${pat}"$'\n'
    done < <(command awk "$SCAN_AWK" "$file" 2>/dev/null || true)
}

# --- Corpus -------------------------------------------------------------------

# Every shell test under tests/, minus the two specimen-bearing files above.
collect_corpus() {
    command find "$TESTS_DIR" -type f -name '*.sh' \
        ! -path "$HARNESS_LIB" ! -path "$SELF_PATH" | command sort
}

CORPUS="$(collect_corpus)"

corpus_count() {
    command printf '%s\n' "$CORPUS" | command grep -c . || true
}

# --- Tests ---------------------------------------------------------------------

# build_detail <violations> — cap reported lines at MAX_DETAIL, then summarize.
DETAIL_LINES=()
DETAIL_TOTAL=0
build_detail() {
    local violations="$1" line shown=0
    DETAIL_LINES=()
    DETAIL_TOTAL=0
    [ -n "$violations" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        DETAIL_TOTAL=$((DETAIL_TOTAL + 1))
        if [ "$shown" -lt "$MAX_DETAIL" ]; then
            DETAIL_LINES+=("$line")
            shown=$((shown + 1))
        fi
    done <<EOF
$violations
EOF
    if [ "$DETAIL_TOTAL" -gt "$MAX_DETAIL" ]; then
        DETAIL_LINES+=("… and $((DETAIL_TOTAL - MAX_DETAIL)) more")
    fi
}

# A gate whose corpus is empty reports nothing and exits 0 — indistinguishable
# from a pass. Pins that the real corpus is non-empty, so this is not a no-op.
test_corpus_non_empty() {
    local n
    n="$(corpus_count)"
    assert_true "[ ${n:-0} -gt 20 ]" \
        "Corpus discovery found ${n:-0} shell tests (expected many)"
}

# The harness library exclusion is by EXPLICIT PATH, not a lib/ glob. Pinning
# the narrowness stops it widening into "skip anything under lib/", which would
# silently drop tests/lib/*-sandbox.sh from the corpus.
test_exclusions_are_deliberate() {
    assert_not_contains "$CORPUS" "lib/harness.sh" \
        "harness.sh (which defines both helpers) is out of corpus"
    assert_not_contains "$CORPUS" "lint-definition-assertions.sh" \
        "this gate's own fixture specimens are out of corpus"
    assert_contains "$CORPUS" "lib/" \
        "the exclusion is one file, not the whole lib/ directory"
    assert_contains "$CORPUS" "lint-harness-refs.sh" \
        "the exclusion is one gate, not every lint-*.sh"
}

# The real corpus must be clean — this is what fails the tree on a regression.
test_real_corpus_is_clean() {
    local file all=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        scan_file "$file"
        all+="$CUR_VIOLATIONS"
    done <<EOF
$CORPUS
EOF
    build_detail "$all"
    if [ "$DETAIL_TOTAL" -eq 0 ]; then
        assert_true "true" "No unanchored definition-shaped assertions"
        return 0
    fi
    _fail "Unanchored definition-shaped assertions — use assert_file_defines (#830)" \
        "${DETAIL_LINES[@]}"
}

# The teeth. Each fixture is the DIVERGENT case: definition-shaped patterns must
# fire, and the near-miss shapes must not. A gate that fires on everything (or
# nothing) passes a naive test either way — which is the very defect #830 is
# about, so this gate of all gates must not have it.
test_detection_fires_and_is_narrow() {
    local d
    d="$(command mktemp -d)"
    command cat >"$d/f.sh" <<'FIXTURE'
assert_file_contains "$F" "SKIP_EXIT_CODE=77" "double-quoted definition"
assert_file_contains "$F" 'PLUGINS_DIR="${X:-y}"' "single-quoted definition"
assert_file_not_contains "$F" "DEBUG=1" "not_contains is covered too"
assert_file_contains "$F" "install --force \"ruff==$V\"" "= not leading: fine"
assert_file_contains "$F" "did NOT run" "phrase: fine"
assert_file_contains "$F" "80-workflow-tools" "corpus name: fine"
assert_file_defines "$F" "ALREADY_FIXED=1" "already converted: fine"
FIXTURE
    scan_file "$d/f.sh"
    assert_contains "$CUR_VIOLATIONS" "SKIP_EXIT_CODE=77" \
        "flags a double-quoted definition pattern"
    assert_contains "$CUR_VIOLATIONS" "PLUGINS_DIR=" \
        "flags a single-quoted definition pattern"
    assert_contains "$CUR_VIOLATIONS" "DEBUG=1" \
        "flags assert_file_not_contains too"
    assert_not_contains "$CUR_VIOLATIONS" "ruff==" \
        "does NOT flag a pattern whose = is not leading"
    assert_not_contains "$CUR_VIOLATIONS" "did NOT run" \
        "does NOT flag a phrase assertion"
    assert_not_contains "$CUR_VIOLATIONS" "80-workflow-tools" \
        "does NOT flag a corpus-name assertion"
    assert_not_contains "$CUR_VIOLATIONS" "ALREADY_FIXED" \
        "does NOT flag an already-converted assert_file_defines"
    command rm -rf "$d"
}

# These assertions routinely WRAP with a trailing backslash — the call and the
# file argument on one line, the pattern on the next (tests/validate-free-port.sh
# writes 5 calls in exactly this shape). A per-line scan sees neither half and
# the gate is silently blind to the style this repo writes most. Measured: the
# joined scan sees 98 patterns in the real corpus where the per-line scan saw 82.
test_wrapped_call_is_detected() {
    local d
    d="$(command mktemp -d)"
    command cat >"$d/w.sh" <<'FIXTURE'
    assert_file_contains "$gate" \
        "WRAPPED_DEFN=77" \
        "a definition-shaped pattern on a continuation line"
    assert_file_contains "$gate" \
        'with_free_port "$PORT_ATTEMPTS" start_listener' \
        "a wrapped PHRASE assertion stays unflagged"
FIXTURE
    scan_file "$d/w.sh"
    assert_contains "$CUR_VIOLATIONS" "WRAPPED_DEFN=77" \
        "a wrapped definition-shaped assertion is detected"
    assert_contains "$CUR_VIOLATIONS" ":1:" \
        "the violation is reported at the line the CALL starts on"
    assert_not_contains "$CUR_VIOLATIONS" "with_free_port" \
        "a wrapped phrase assertion is still spared"
    command rm -rf "$d"
}

# The exemption works from either line, and a BARE marker does not exempt —
# the reason is what separates a considered exception from a silenced failure.
test_exemption_requires_a_reason() {
    local d
    d="$(command mktemp -d)"
    command cat >"$d/e.sh" <<'FIXTURE'
# lint-allow-unanchored: mid-line assignment in a joined recipe
assert_file_contains "$F" "ABOVE_OK=1" "marker on the line above"
assert_file_contains "$F" "SAME_OK=1" "marker on the same line" # lint-allow-unanchored: because
assert_file_contains "$F" "BARE_MARKER=1" "no reason given" # lint-allow-unanchored:
assert_file_contains "$F" "NOT_EXEMPT=1" "no marker at all"
FIXTURE
    scan_file "$d/e.sh"
    assert_not_contains "$CUR_VIOLATIONS" "ABOVE_OK" \
        "a reasoned marker on the line ABOVE exempts"
    assert_not_contains "$CUR_VIOLATIONS" "SAME_OK" \
        "a reasoned marker on the SAME line exempts"
    assert_contains "$CUR_VIOLATIONS" "BARE_MARKER=1" \
        "a marker with NO reason does not exempt"
    assert_contains "$CUR_VIOLATIONS" "NOT_EXEMPT=1" \
        "an unmarked definition assertion is still flagged"
    command rm -rf "$d"
}

# The header justifies scanning the whole contiguous comment BLOCK rather than
# one line back, on the grounds that a reason often runs to two or three lines —
# a claim the single-line fixture above cannot support. Both halves are pinned:
# the marker still reaches across further comment lines, and it does NOT reach
# across code (or a blank line, which ends the block).
test_exemption_spans_a_multi_line_comment_block() {
    local d
    d="$(command mktemp -d)"
    command cat >"$d/m.sh" <<'FIXTURE'
# lint-allow-unanchored: the assignment is mid-line in a joined recipe
# so no line-anchored helper can match it, and there is no comment
# occurrence in the target to collide with.
assert_file_contains "$F" "MULTILINE_OK=1" "marker three lines up, same block"
FIXTURE
    scan_file "$d/m.sh"
    assert_not_contains "$CUR_VIOLATIONS" "MULTILINE_OK" \
        "a marker earlier in the same comment block still exempts"

    command cat >"$d/g.sh" <<'FIXTURE'
# lint-allow-unanchored: a reason that belongs to the assertion below it
some_unrelated_command "here"
assert_file_contains "$F" "ACROSS_CODE=1" "marker separated by code"
FIXTURE
    scan_file "$d/g.sh"
    assert_contains "$CUR_VIOLATIONS" "ACROSS_CODE=1" \
        "a marker does NOT reach across an intervening code line"

    command cat >"$d/b.sh" <<'FIXTURE'
# lint-allow-unanchored: a reason orphaned by a blank line

assert_file_contains "$F" "ACROSS_BLANK=1" "marker separated by a blank line"
FIXTURE
    scan_file "$d/b.sh"
    assert_contains "$CUR_VIOLATIONS" "ACROSS_BLANK=1" \
        "a blank line ends the comment block, so the marker does not carry"
    command rm -rf "$d"
}

# is_definition's char class allows a dot so dotted config keys count. That is a
# SECOND implementation of the concept assert_file_defines implements, so it can
# regress independently — pin it on the scanner side too.
test_dotted_name_is_definition_shaped() {
    local d
    d="$(command mktemp -d)"
    command cat >"$d/d.sh" <<'FIXTURE'
assert_file_contains "$F" "tool.ruff=1" "a dotted config key is a definition"
assert_file_contains "$F" "a.b.c=2" "so is a multi-dotted one"
FIXTURE
    scan_file "$d/d.sh"
    assert_contains "$CUR_VIOLATIONS" "tool.ruff=1" \
        "a dotted config key is treated as definition-shaped"
    assert_contains "$CUR_VIOLATIONS" "a.b.c=2" \
        "so is a multi-segment dotted key"
    command rm -rf "$d"
}

# MAX_DETAIL caps the reported lines so a large regression stays readable. An
# off-by-one in the cap or the remainder would misreport how much was hidden.
test_detail_truncation() {
    local violations="" i
    i=1
    while [ "$i" -le 45 ]; do
        violations+="tests/f.sh:${i}: SETTING${i}=1"$'\n'
        i=$((i + 1))
    done
    build_detail "$violations"
    assert_equals "45" "$DETAIL_TOTAL" "every violation is counted, not just the shown ones"
    assert_equals "$((MAX_DETAIL + 1))" "${#DETAIL_LINES[@]}" \
        "MAX_DETAIL lines are shown, plus one summary line"
    assert_contains "${DETAIL_LINES[$MAX_DETAIL]}" "and 5 more" \
        "the summary reports the exact remainder"
    # Under the cap there is no summary line at all.
    build_detail "tests/f.sh:1: ONE=1"$'\n'
    assert_equals "1" "$DETAIL_TOTAL" "a single violation counts as one"
    assert_equals "1" "${#DETAIL_LINES[@]}" "and adds no '… and N more' line"
}

# The gate's own regexes must be BSD-clean. A GNU-only construct here would
# match nothing on macOS and report a clean scan of zero rows — silent, and
# exactly the class CLAUDE.md flags as dangerous.
test_scanner_regexes_are_portable() {
    assert_not_contains "$SCAN_AWK" '\s' "no GNU-only \\s in the scanner"
    assert_not_contains "$SCAN_AWK" '\w' "no GNU-only \\w in the scanner"
    assert_contains "$SCAN_AWK" '[[:space:]]' "uses POSIX classes instead"
}

# With awk absent the gate must exit 77, never 0 — a silent skip reads as a pass
# (#538, #571). Driven BEHAVIOURALLY, not by reading the source: run this very
# file with a PATH that has no awk and assert the real exit status. A text check
# would be satisfied by the sentinel's own definition and prove nothing about
# what the script actually does — which is the #830 defect wearing a different
# hat.
test_missing_awk_exits_77() {
    local d rc=0
    d="$(command mktemp -d)"
    # A PATH with the usual coreutils but deliberately no awk.
    command mkdir -p "$d/bin"
    local tool
    # `timeout` is linked in too when present — the bound below invokes it from
    # this restricted PATH, so omitting it makes the probe fail 127 instead of
    # exercising the skip branch.
    for tool in bash grep sed find sort basename dirname mktemp rm cat printf head chmod timeout; do
        if command -v "$tool" >/dev/null 2>&1; then
            command ln -sf "$(command -v "$tool")" "$d/bin/$tool" 2>/dev/null || true
        fi
    done
    # `env -i` is load-bearing, not tidiness. A plain `PATH=… bash script` does
    # NOT restrict the child: bash sources the user's profile, which rebuilds
    # PATH from scratch, and awk reappears at /usr/bin/awk. The probe then runs
    # the FULL gate and asserts 77 against a green 0 — a test that silently
    # exercises the present-tool arm it was written to avoid. Verified: the
    # child reported `YES at /usr/bin/awk` under the naive form.
    # `--noprofile --norc` is belt-and-braces for the same reason.
    #
    # LINT_DEFN_NO_RESPAWN stops the child re-running THIS case and forking a
    # grandchild — without it the probe recurses forever (observed: a 15s bound
    # hit 124 with no report). `timeout` is a second, independent bound so a
    # future regression surfaces as a failure rather than a wedged suite; it is
    # optional (macOS ships no coreutils `timeout`), hence the presence check.
    local runner=""
    if command -v timeout >/dev/null 2>&1; then runner="timeout 30"; fi
    env -i PATH="$d/bin" LINT_DEFN_NO_RESPAWN=1 HOME="$d" \
        $runner bash --noprofile --norc "$SELF_PATH" >"$d/out" 2>&1 || rc=$?
    assert_equals "77" "$rc" "with awk absent the gate exits the 77 skip sentinel, not 0"
    assert_contains "$(command cat "$d/out")" "GATE DID NOT RUN" \
        "the skip says the gate did not run, rather than reporting green"
    command rm -rf "$d"
}

run_test test_corpus_non_empty "Corpus discovery is non-empty (gate is not a no-op)"
run_test test_exclusions_are_deliberate "Exclusions are two explicit paths, not globs"
run_test test_real_corpus_is_clean "No unanchored definition-shaped assertions in tests/"
run_test test_detection_fires_and_is_narrow "Detection flags definitions and spares phrases"
run_test test_wrapped_call_is_detected "A backslash-wrapped call is detected, not skipped"
run_test test_exemption_requires_a_reason "lint-allow-unanchored exempts only with a reason"
run_test test_exemption_spans_a_multi_line_comment_block "A marker spans its comment block but not code or a blank"
run_test test_dotted_name_is_definition_shaped "A dotted config key is definition-shaped to the scanner"
run_test test_detail_truncation "Violation detail truncates at MAX_DETAIL with an accurate remainder"
run_test test_scanner_regexes_are_portable "The scanner's own regexes are BSD-clean"
if [ -z "${LINT_DEFN_NO_RESPAWN:-}" ]; then
    run_test test_missing_awk_exits_77 "With awk absent the gate exits 77, not 0"
fi

generate_report
