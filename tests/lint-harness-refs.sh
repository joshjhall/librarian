#!/usr/bin/env bash
# Adversarial-review harness-reference gate (issue #681).
#
# An agent running `/workflow:golem` reached for the `dev-core:code-reviewer`
# AGENT instead of the `ship-issue/workflow.js` Workflow HARNESS for the pre-PR
# review, and never opened `ship-issue` Step 3.5 at all. Nothing was violated:
# `golem/SKILL.md` said "adversarial pre-PR review" three times and never named
# the artifact, while `dev-core:code-reviewer`'s own description asserts "use
# before creating pull requests". When prose merely DESCRIBES and a tool
# description ASSERTS, the tool description wins.
#
# The wrong pick is a plausible-looking SUBSET of the right one — the harness
# fans that very agent out across five dimensions plus a fresh judge — so it
# fails silently, and expensively (5.4 min per harness cycle vs 9-61 min per
# serial subagent cycle, measured on PR #642). #681 swept the prose; this gate
# is what stops the drift recurring on the next skill edit. Same answer this
# repo gives the whole "prose that asks to be read more carefully" class:
# lint-command-refs.sh, lint-action-pins.sh, lint-readonly-harness.sh.
#
# THE RULE. Within a markdown SECTION (a heading and the lines under it up to
# the next heading), a line carrying the adversarial-review phrase must be
# joined by a line naming the harness. Section scope, not whole-file, is what
# makes the pointer land where a reader actually is: a file may legitimately
# name the harness once in an overview and then describe the review three
# screens later, which is exactly the shape that misled the agent.
#
# TWO-LINE WINDOW, not a single line. This is load-bearing, not a nicety. The
# phrase WRAPS in the real corpus — golem/SKILL.md ("… the same\nadversarial
# pre-PR review") and plugins/workflow/README.md both split it across a newline.
# A single-line matcher misses the exact prose that caused this bug, which is
# the definition of a tautological gate: green before the fix and green after.
# test_wrapped_phrase_is_detected plants that shape specifically to catch a
# future collapse back to line-at-a-time.
#
# SATISFIERS — any ONE of these in the section discharges the requirement:
#   workflow.js      the harness file itself (`ship-issue/workflow.js`)
#   Workflow tool    the invocation, with or without backticks around Workflow
# Deliberately NOT satisfiers: "harness", "Step 3.5", "pre-ship-validation.md".
# Each is a pointer to a place that names the artifact rather than the artifact,
# and pointer-instead-of-artifact is the entire defect #681 is about.
#
# THE ONE EXEMPTION. dev-core ships a SKILL literally called
# `adversarial-review` (an authoring checklist for skills and harnesses). A
# section about that skill is not talking about the ship harness and must not be
# forced to name it. It is recognized as the backticked name FOLLOWED BY the
# word "skill" — `` `adversarial-review` skill `` — on the same two-line window.
# Both halves matter: the backticks mark it as an artifact name rather than an
# adjective, and requiring "skill" keeps the exemption from swallowing a section
# that merely happens to mention the checklist while describing the ship review.
# Note the phrase regex requires whitespace between the two words, so the
# hyphenated `adversarial-review` never matches the phrase on its own — the
# exemption exists for sections where BOTH forms appear.
#
# CORPUS: plugins/**/*.md plus the top-level README.md — mirroring
# lint-command-refs.sh exactly, and for the same reasons. The two notable
# absences are out of scope BY CONSTRUCTION (outside the walked root), not by an
# active filter, so there is no `grep -v` that could regress; what
# test_exclusions_are_deliberate pins is the NARROWNESS of the root itself,
# since widening it to $REPO_ROOT is the plausible regression that would sweep
# them in:
#   CHANGELOG.md         — git-cliff-generated release notes.
#   docs/verification/** — dated end-to-end transcripts. A VERIFIED-live block
#                          records the exact text a command printed at the time;
#                          rewriting it falsifies the evidence.
#
# Detection is awk, not grep: the rule is stateful (accumulate a section, then
# judge it), and awk's regex engine behaves the same on BSD and GNU, which grep's
# does not. No `\s`, `\w`, or `grep -P` anywhere — POSIX classes only.
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file's own path. Both test_missing_readme_fails_loudly and
# test_missing_awk_exits_77 slice a real block out of it and drive that block
# standalone, so each slice tracks edits to the real code instead of drifting.
SELF_PATH="$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

# Cap on violation detail lines per file so a large regression stays readable.
MAX_DETAIL=40

test_suite "Adversarial-review harness refs (#681)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
# A silent skip is indistinguishable from a pass, which is how a gate sits inert
# unnoticed (#538, #571) — so this must never be a bare exit 0.
SKIP_EXIT_CODE=77

if ! command -v awk >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — awk not available (install awk to check harness refs)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Detection ---------------------------------------------------------------

# The awk program, held as a constant so the tests drive the SAME text the real
# scan does. Emits one `<line>:<heading>` row per offending section: the line
# number of the section's first phrase match, and the heading it sits under
# (empty for a pre-first-heading section such as YAML frontmatter).
#
# `two` is the current line joined to the NEXT one, which is what implements the
# wrapped-phrase window. The last line of a section joins nothing, correctly — a
# phrase cannot wrap past the end of its own section.
SCAN_AWK='
function flush(   i, two, hit, named, exempt, hitline) {
    if (nsec == 0) return
    hit = 0; named = 0; exempt = 0; hitline = 0
    for (i = 1; i <= nsec; i++) {
        two = sec[i] (i < nsec ? " " sec[i + 1] : "")
        if (two ~ /[Aa]dversarial[[:space:]]+([A-Za-z-]+[[:space:]]+)?review/) {
            if (!hit) {
                hit = 1
                # Report the line the word ADVERSARIAL is actually on, which on
                # a wrapped match is sec[i] and on a heading-plus-first-line
                # window is sec[i+1]. Reporting the window opener instead would
                # point an author at a heading that carries no prose.
                hitline = (sec[i] ~ /[Aa]dversarial/) ? secln[i] : secln[i + 1]
            }
        }
        if (sec[i] ~ /workflow\.js/) named = 1
        if (sec[i] ~ /`?Workflow`?[[:space:]]+tool/) named = 1
        if (two ~ /`adversarial-review`[[:space:]]+skill/) exempt = 1
    }
    if (hit && !named && !exempt) printf "%d:%s\n", hitline, sechdr
    nsec = 0
}
# Fenced code blocks must not be read for headings: a shell comment
# (`# In a Claude Code session…`) inside a ``` fence is not a markdown heading,
# and treating it as one splits a section at a line the reader sees as code.
# README.md contains exactly that shape.
/^[[:space:]]*(```|~~~)/ { fence = !fence }
!fence && /^#+[[:space:]]/ { flush(); sechdr = $0 }
{ nsec++; sec[nsec] = $0; secln[nsec] = FNR }
END { flush() }
'

# scan_file <path>
# Populates CUR_VIOLATIONS with one
# "<relpath>:<line>: section '<heading>' names the review but not the harness"
# entry per offending section (empty when the file is clean).
CUR_FILE=""
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local row lineno hdr rel
    rel="${file#"$REPO_ROOT"/}"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        lineno="${row%%:*}"
        hdr="${row#*:}"
        [ -n "$hdr" ] || hdr="(file head, before the first heading)"
        CUR_VIOLATIONS+="${rel}:${lineno}: under ${hdr}"$'\n'
    done < <(command awk "$SCAN_AWK" "$file" 2>/dev/null || true)
}

# --- Corpus -------------------------------------------------------------------

# Every markdown file under plugins/, plus the top-level README. README.md is
# REQUIRED, not best-effort: it carries two of the swept sections, so silently
# skipping a missing one would narrow the corpus without saying so — the same
# false-green class as a discovery typo. Fail loudly instead.
collect_corpus() {
    command find "$PLUGINS_DIR" -type f -name '*.md' | command sort
    if [ ! -f "$REPO_ROOT/README.md" ]; then
        command printf 'lint-harness-refs: README.md not found at %s\n' \
            "$REPO_ROOT/README.md" >&2
        return 1
    fi
    command printf '%s\n' "$REPO_ROOT/README.md"
}

CORPUS="$(collect_corpus)"

corpus_count() {
    command printf '%s\n' "$CORPUS" | command grep -c . || true
}

# --- Tests ---------------------------------------------------------------------

# build_detail <violations> — cap the reported lines at MAX_DETAIL and append a
# "… and N more" summary when truncating.
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
    done <<<"$violations"
    [ "$DETAIL_TOTAL" -gt "$shown" ] &&
        DETAIL_LINES+=("… and $((DETAIL_TOTAL - shown)) more")
    return 0
}

# Per-file body (reads CUR_FILE). One run_test per file keeps a failure
# attributable to the file that caused it.
test_file_harness_refs() {
    scan_file "$CUR_FILE"
    if [ -n "$CUR_VIOLATIONS" ]; then
        build_detail "$CUR_VIOLATIONS"
        _fail "Adversarial-review prose without the harness named in $(command basename "$CUR_FILE") — name the Workflow tool with \`ship-issue/workflow.js\` (ship-issue Step 3.5 item 6) in the same section" \
            "${DETAIL_LINES[@]}"
    fi
}

# The gate must actually inspect something. A bare non-empty check would pass if
# a path typo left exactly one file discovered, so assert a floor with the real
# number in the message.
test_corpus_non_empty() {
    local files ge_files=0
    files="$(corpus_count)"
    assert_not_empty "$CORPUS" "The corpus must contain at least one markdown file"
    [ "$files" -ge 50 ] && ge_files=1
    assert_equals "1" "$ge_files" \
        "At least 50 markdown files must be in the corpus (found $files)"
    assert_contains "$CORPUS" "/plugins/workflow/skills/golem/SKILL.md" \
        "The corpus includes golem/SKILL.md (the file #681 was filed against)"
    assert_contains "$CORPUS" "/README.md" \
        "The corpus includes the top-level README"
}

# The exclusions are a tested decision, not an accident of the find root.
test_exclusions_are_deliberate() {
    assert_not_contains "$CORPUS" "/docs/verification/" \
        "docs/verification/** is out of scope (dated e2e transcripts)"
    assert_not_contains "$CORPUS" "/CHANGELOG.md" \
        "CHANGELOG.md is out of scope (git-cliff-generated release notes)"

    # Both assertions above are true BY CONSTRUCTION — those paths sit outside
    # the walked root, so they would pass even with every filter deleted. What
    # actually needs pinning is the property they depend on: the root stays
    # narrow. Widening it to $REPO_ROOT would sweep them in and make the
    # assertions above start failing for real.
    local outside="" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$PLUGINS_DIR"/*) continue ;;
            "$REPO_ROOT/README.md") continue ;;
            *) outside="${outside}${f}"$'\n' ;;
        esac
    done <<<"$CORPUS"
    assert_equals "" "$outside" \
        "The corpus is exactly plugins/**/*.md + README.md (root has not widened)"
}

# Positive control. Every per-file test goes green on an EMPTY corpus, and would
# also go green if someone deleted the review prose outright rather than naming
# the harness beside it. Assert the harness name is genuinely present in the
# real tree — and specifically in golem/SKILL.md, whose ZERO hits
# (`grep -c 'workflow\.js|Workflow tool'` → 0) is the measurement #681 opens with.
test_harness_named_in_real_corpus() {
    local golem="$PLUGINS_DIR/workflow/skills/golem/SKILL.md"
    local hits
    hits="$(command grep -cE 'workflow\.js|`?Workflow`?[[:space:]]+tool' "$golem" || true)"
    local ge=0
    [ "$hits" -ge 1 ] && ge=1
    assert_equals "1" "$ge" \
        "golem/SKILL.md must name the harness at least once (found $hits; it was 0 in #681)"

    local files
    files="$(command grep -rlE 'ship-issue/workflow\.js' "$PLUGINS_DIR" \
        --include='*.md' 2>/dev/null || true)"
    assert_not_empty "$files" \
        "The harness path ship-issue/workflow.js must appear in the corpus (named, not deleted)"
}

# Negative case: the violation branch must fire on the offending shapes, and
# every satisfier and the exemption must NOT fire. Without this, a regression in
# the awk program would report PASS while enforcing nothing.
#
# Needles are section HEADINGS, not `:<line>: ` prefixes. The violation text is
# otherwise identical across sections, so a needle must be unique per section —
# and a line number stops being that the moment the fixture above it grows a
# line, which silently turns an assertion into one about the wrong section.
# (That happened twice while writing this file.) The one line-number assertion
# that remains is deliberate: it checks WHICH line gets reported, not which
# section, so it has to name a number.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/fixture.md" <<'EOF'
## Bare adjective
The adversarial pre-PR review runs before the push.

## Named by file
The adversarial pre-PR review runs via `ship-issue/workflow.js`.

## Named by tool
Invoke the Workflow tool for the adversarial review.

## Named by backticked tool
Invoke the `Workflow` tool for the adversarial review.

## The authoring skill
- **Adversarial review**: for a skill that drives a
  workflow, apply the `adversarial-review` skill (its Bug-Class Checklist).

## Plain phrasing with no artifact
Each cycle re-runs the adversarial review over the fix delta.

## Pointer is not the artifact
The adversarial review runs at Step 3.5 (see pre-ship-validation.md).
EOF

    scan_file "$tmp/fixture.md"
    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags bare prose (violation branch fires)"

    # Positive branch — the offending shapes.
    assert_contains "$CUR_VIOLATIONS" "Bare adjective" \
        "Prose naming only the adjective is flagged (and names its heading)"
    assert_contains "$CUR_VIOLATIONS" "Plain phrasing with no artifact" \
        "Plain 'adversarial review' with no artifact is flagged"
    assert_contains "$CUR_VIOLATIONS" "Pointer is not the artifact" \
        "A pointer to Step 3.5 / another file is NOT a satisfier (that is the #681 defect)"
    # The reported line must be the PROSE line, not the heading above it —
    # otherwise the message points an author at a line carrying no phrase.
    assert_contains "$CUR_VIOLATIONS" ":2: " \
        "The violation reports the prose line, not the heading line"

    # Negative branch — one per satisfier, plus the exemption.
    assert_not_contains "$CUR_VIOLATIONS" "Named by file" \
        "A section naming workflow.js is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "Named by tool" \
        "A section naming the Workflow tool is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "Named by backticked tool" \
        "A section naming the backticked \`Workflow\` tool is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "The authoring skill" \
        "A section about the \`adversarial-review\` SKILL is exempt"

    # The exemption assertion above is only meaningful if that section ARMS the
    # gate in the first place — a section with no phrase match is unreportable
    # whether or not the exemption exists, which would make the assertion
    # vacuous. (It WAS vacuous in an earlier draft: the hyphenated
    # `adversarial-review` never matches the whitespace-separated phrase, so a
    # fixture carrying only the skill name never armed anything. Neutering the
    # exemption in a mutation round failed the REAL corpus and left this fixture
    # green — which is how the vacuity surfaced.) So prove the arming half
    # directly: the same text WITHOUT the backticked skill name must be flagged.
    command cat >"$tmp/arms.md" <<'EOF'
## The authoring skill
- **Adversarial review**: for a skill that drives a
  workflow, apply the checklist.
EOF
    scan_file "$tmp/arms.md"
    assert_contains "$CUR_VIOLATIONS" "The authoring skill" \
        "The exemption fixture genuinely arms the gate (exemption test is not vacuous)"
}

# Pins the two-line window. The phrase wraps across a newline in the real corpus
# (golem/SKILL.md and plugins/workflow/README.md both split it), so a matcher
# collapsed to one line at a time would MISS the exact prose that caused #681 —
# green before the fix and green after, the textbook tautological gate. This
# fixture is the shape that catches that collapse.
test_wrapped_phrase_is_detected() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # The wrap must split the PHRASE ITSELF, not merely put it at a line start.
    # This is the real shape from plugins/workflow/README.md, where line 2 ends
    # on "the adversarial" and line 3 opens with "pre-PR review" — so neither
    # line carries a complete phrase and only the joined window matches.
    command cat >"$tmp/wrapped.md" <<'EOF'
## Wrapped across a newline
worktree, the full `next-issue` → `ship-issue` pipeline, and the adversarial
pre-PR review — no orchestrator, `tmux`, or containers.
EOF

    # Guard the fixture: prove neither line matches alone, so the assertion
    # below can only pass because of the window.
    local single
    single="$(command grep -cE '[Aa]dversarial[[:space:]]+([A-Za-z-]+[[:space:]]+)?review' \
        "$tmp/wrapped.md" || true)"
    assert_equals "0" "$single" \
        "Fixture guard: no single line carries the phrase (found $single)"

    scan_file "$tmp/wrapped.md"
    assert_contains "$CUR_VIOLATIONS" ":2: " \
        "A phrase wrapped across two lines IS detected (window is load-bearing)"

    # And the window must not leak past a section boundary: a phrase whose two
    # halves straddle a heading is two different topics, not one wrapped phrase.
    command cat >"$tmp/straddle.md" <<'EOF'
## First section ends with the word
adversarial

## Second section opens with
review of the changes, run via `ship-issue/workflow.js`.
EOF
    scan_file "$tmp/straddle.md"
    assert_equals "" "$CUR_VIOLATIONS" \
        "The window does not join lines across a heading boundary"
}

# Drives build_detail's truncation branch, which no fixture reaches otherwise.
test_detail_truncation() {
    local many="" i=1
    while [ "$i" -le 45 ]; do
        many="${many}f.md:${i}: under ## H"$'\n'
        i=$((i + 1))
    done

    build_detail "$many"
    assert_equals "45" "$DETAIL_TOTAL" "All 45 violations are counted"
    assert_equals "$((MAX_DETAIL + 1))" "${#DETAIL_LINES[@]}" \
        "Detail is capped at MAX_DETAIL plus one summary line"
    assert_equals "… and $((45 - MAX_DETAIL)) more" "${DETAIL_LINES[$MAX_DETAIL]}" \
        "The summary line reports the correct remainder"
    assert_equals "f.md:1: under ## H" "${DETAIL_LINES[0]}" \
        "Truncation keeps the first violation"

    # Boundary: exactly MAX_DETAIL violations must NOT append a summary line.
    local exact="" j=1
    while [ "$j" -le "$MAX_DETAIL" ]; do
        exact="${exact}f.md:${j}: under ## H"$'\n'
        j=$((j + 1))
    done
    build_detail "$exact"
    assert_equals "$MAX_DETAIL" "${#DETAIL_LINES[@]}" \
        "Exactly MAX_DETAIL violations produce no summary line (off-by-one guard)"

    build_detail ""
    assert_equals "0" "${#DETAIL_LINES[@]}" "No violations produce no detail lines"
    assert_equals "0" "$DETAIL_TOTAL" "No violations produce a zero total"
}

# Pins collect_corpus's fail-loud README branch. The behavior under test is "the
# gate ABORTS", which run_test's `if "$test_func"` suspends `set -e` for and
# therefore cannot observe — so SLICE the real function out of this file and
# drive it at top level against a REPO_ROOT with no README.md. Slicing rather
# than restating is the point: a hand-copied body would keep passing after the
# real function regained a `|| true`.
test_missing_readme_fails_loudly() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command mkdir -p "$tmp/root/plugins"
    local sliced="$tmp/sliced.sh"
    {
        command printf 'set -euo pipefail\n'
        command printf 'REPO_ROOT=%s\n' "$tmp/root"
        command printf 'PLUGINS_DIR=%s\n' "$tmp/root/plugins"
        command sed -n '/^collect_corpus() {$/,/^}$/p' "$SELF_PATH"
        command printf 'CORPUS="$(collect_corpus)"\n'
        command printf 'command printf "REACHED_AFTER:[%%s]\\n" "$CORPUS"\n'
    } >"$sliced"

    # Guard the slice: a broken sed would make the probe fail for the wrong reason.
    assert_contains "$(command cat "$sliced")" "collect_corpus() {" \
        "The real collect_corpus was sliced out (probe is not vacuous)"

    local out rc=0
    out="$(command bash "$sliced" 2>"$tmp/err")" || rc=$?
    assert_equals "1" "$rc" "A missing README.md makes the gate exit non-zero"
    assert_contains "$(command cat "$tmp/err")" "README.md not found" \
        "The failure names the missing file (actionable, not silent)"
    assert_not_contains "$out" "REACHED_AFTER" \
        "Execution does NOT continue past the corpus build with a narrowed corpus"

    command printf '# root\n' >"$tmp/root/README.md"
    local out2 rc2=0
    out2="$(command bash "$sliced" 2>/dev/null)" || rc2=$?
    assert_equals "0" "$rc2" "With README.md present, collect_corpus succeeds"
    assert_contains "$out2" "README.md" "The README is part of the corpus it returns"
}

# Pins the SKIP sentinel. The skip branch runs only when awk is absent, so on
# every real host it is dead code — and a gate whose skip path silently exits 0
# is indistinguishable from a pass (#538, #571), which is exactly the failure
# class the sentinel exists to prevent. So force the absence rather than
# skip-if-absent, which would only ever cover the arm that already works.
#
# TECHNIQUE, and why the obvious one is wrong. Re-running THIS FILE under a
# stripped PATH is the natural first idea. It does not work, and it fails
# destructively: some environments re-initialize PATH from the shell profile, so
# the override is silently discarded, awk stays reachable, the child runs the
# full suite — including this test — and recurses until it is killed. That is
# not a hypothetical; it was observed here, as a hang, before this comment
# existed. A stripped-PATH probe must therefore never re-enter the whole gate.
#
# Instead, SLICE the real skip branch out of this file and drive it standalone,
# the same idiom test_missing_readme_fails_loudly uses. The slice has no test
# bodies in it, so it cannot recurse no matter what PATH does, and it asserts
# against the real text rather than a hand-copy that would drift.
test_missing_awk_exits_77() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    local sliced="$tmp/sliced.sh"
    {
        command printf 'set -euo pipefail\n'
        # Stubs for the two harness calls the branch makes, so the slice needs
        # no harness and its behavior is observable as plain text.
        command printf 'skip_test() { command printf "SKIP:%%s\\n" "$1"; }\n'
        command printf 'generate_report() { command printf "REPORT\\n"; }\n'
        # Force the probe to miss regardless of the ambient PATH: a function
        # named `command` would break everything else, so shadow the lookup
        # itself with a `command -v awk` that fails. This models "awk absent"
        # without touching PATH at all.
        command printf 'command() { if [ "$1" = "-v" ] && [ "$2" = "awk" ]; then return 1; fi; builtin command "$@"; }\n'
        # The real branch, sliced from the SKIP_EXIT_CODE assignment through the
        # `fi`. Starting at the constant (not at the `if`) means the slice
        # carries the sentinel VALUE too, so a future edit that changed 77 to
        # something else would be caught here rather than silently re-defined.
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

    # The sentinel must be the literal 77 in the source, not merely whatever
    # SKIP_EXIT_CODE happens to hold — 77 is the value run-all.sh keys on.
    assert_contains "$(command cat "$SELF_PATH")" "SKIP_EXIT_CODE=77" \
        "The skip sentinel is the reserved 77 that run-all.sh renders as [SKIP]"
}

run_test test_corpus_non_empty "Corpus discovery is non-empty (gate is not a no-op)"
run_test test_exclusions_are_deliberate "CHANGELOG.md and docs/verification are excluded on purpose"
run_test test_negative_case_fires "scan_file flags bare prose and honors every satisfier"
run_test test_wrapped_phrase_is_detected "A phrase wrapped across two lines is detected (not single-line)"
run_test test_harness_named_in_real_corpus "The harness is genuinely named in the real corpus"
run_test test_detail_truncation "Violation detail truncates at MAX_DETAIL with an accurate remainder"
run_test test_missing_readme_fails_loudly "A missing README.md aborts the gate instead of narrowing the corpus"
run_test test_missing_awk_exits_77 "With awk absent the gate exits 77, not 0"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_harness_refs "${f#"$REPO_ROOT"/}: adversarial-review prose names the harness"
done <<<"$CORPUS"

generate_report
