#!/usr/bin/env bash
# Background-work registration gate (issue #890).
#
# THE BUG THIS EXISTS FOR. `golem-transcript-liveness.sh` classifies a golem from
# the last top-level assistant record's `stop_reason`: `tool_use` => working,
# `end_turn` => idle. That is right for a SYNCHRONOUS turn and wrong whenever
# work outlives the turn that started it — a `run_in_background` Bash task, a
# `Monitor`, or a `Workflow` harness. #890 measured FIVE golems reported
# `idle at prompt` in ONE orchestration session, every one doing real work.
#
# #954 fixed the CLASSIFIER (an unregistered background turn now degrades to
# indeterminate rather than idle) and #949/#957 built the REGISTRY
# (`scripts/golem-work.sh`) that upgrades indeterminate to a definite `working`.
# This gate covers the third thing, which is neither: whether the skills that
# actually START that work say so.
#
# WHY A GATE AND NOT JUST PROSE. `golem/background-work.md` declared itself an
# "on-demand companion for golem/, next-issue/, and ship-issue/" while
# `ship-issue/` referenced it ZERO times — and ship-issue is where all five
# measured false-idles happened (the review harness mid-fan-out x3, a suite run,
# a `git push` executing the pre-push hook). The companion's own header ASSERTED
# the adoption that did not exist, which is what made the gap invisible. Prose
# that merely describes drifts on the next skill edit; the same class and the
# same remedy as lint-harness-refs.sh (#681), lint-command-refs.sh, and
# lint-readonly-harness.sh.
#
# THE RULE. Within a markdown SECTION (a heading and the lines under it up to the
# next heading), a line that starts background work must be joined by a line
# naming the registry. Section scope, not whole-file, is load-bearing here: the
# swept files run 458-770 lines, so a whole-file satisfier would let a new
# background site land unregistered three screens from an existing mention and
# still pass.
#
# TWO-LINE WINDOW, not a single line, for the reason lint-harness-refs.sh
# documents at length: these phrases WRAP in the real corpus, and a matcher
# collapsed to one line at a time is green before the fix and green after — the
# textbook tautological gate. test_wrapped_trigger_is_detected plants that shape.
#
# TRIGGERS — an IMPERATIVE that starts background work, not a mention of it:
#   **Invoke the `Workflow` tool**    the harness fan-out (bolded imperative)
#   **Run** the `Workflow` tool       ditto, the other spelling
#   Invoke it as a background task    the ci-fixer harness site
#   run_in_background                 a backgrounded Bash task
#
# The bolding is deliberate and was MEASURED, not guessed. A looser trigger
# (any of invoke|run|start|dispatch near a tool name) fired on 11 sections, 8 of
# them in `orchestrate/` — which is the OBSERVER of golem background work, not a
# golem that starts any, so demanding registration there would be a false claim.
# It also fired on `ship-protocol.md` section "Workflow authority", which is
# ABOUT the permission question and invokes nothing. Narrowing to the bolded
# imperative left exactly the four real sites, and reverting the fix re-reddens
# them (see docs/verification/background-work-adoption-890.md).
#
# SATISFIERS — either names the registry concretely:
#   golem-work.sh         the script itself
#   background-work.md    the protocol companion
# Deliberately NOT satisfiers: "register", "background work", "#890". Each is a
# description rather than the artifact, and pointer-instead-of-artifact is the
# defect this gate is about — the same line lint-harness-refs.sh draws.
#
# THE ONE EXEMPTION: `golem/background-work.md` itself. It is the file that
# DEFINES the protocol, so every trigger phrase appears there as the subject
# under discussion rather than as an instruction to a golem. It is exempt by
# NAME, and test_exemption_is_narrow proves the exemption is one file rather
# than a directory (a `golem/*` exemption would silently un-gate golem/SKILL.md).
#
# CORPUS: the three skills that RUN the pipeline — ship-issue/, golem/,
# next-issue/. orchestrate/ is deliberately out of scope, per the measurement
# above: it watches golems, it does not start their background work. That is an
# ACTIVE decision, so test_corpus_scope_is_deliberate pins both halves.
#
# Detection is awk, not grep: the rule is stateful (accumulate a section, then
# judge it), and awk's regex engine behaves the same on BSD and GNU, which
# grep's does not. No GNU-only escapes anywhere — POSIX classes only.
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file's own path. test_missing_awk_exits_77 slices a real block out of it
# and drives that block standalone, so the slice tracks edits to the real code
# instead of drifting from a hand-copy.
SELF_PATH="$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILLS_DIR="$REPO_ROOT/plugins/workflow/skills"

# The protocol file itself — exempt by name (see THE ONE EXEMPTION above).
EXEMPT_FILE="$SKILLS_DIR/golem/background-work.md"

# Cap on violation detail lines per file so a large regression stays readable.
MAX_DETAIL=40

test_suite "Background-work registration refs (#890)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok] and does not fail the suite.
# A silent skip is indistinguishable from a pass, which is how a gate sits inert
# unnoticed (#538, #571) — so this must never be a bare exit 0.
SKIP_EXIT_CODE=77

if ! command -v awk >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — awk not available (install awk to check background-work refs)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Detection ---------------------------------------------------------------

# The awk program, held as a constant so the tests drive the SAME text the real
# scan does. Emits one `<line>:<heading>` row per offending section: the line
# number of the section's first trigger match, and the heading it sits under
# (empty for a pre-first-heading section such as YAML frontmatter).
#
# `two` is the current line joined to the NEXT one, which is what implements the
# wrapped-phrase window. The last line of a section joins nothing, correctly — a
# phrase cannot wrap past the end of its own section.
SCAN_AWK='
# trigger_on(t) — does t carry a COMPLETE background-work trigger? ONE predicate,
# used both to detect a match and to attribute it to a line, so the two can never
# disagree. A cycle-1 review found them disagreeing: attribution used a loose
# /[Ii]nvoke/ keyword, which claimed any window whose FIRST line merely contained
# "invoked"/"invoking"/"revoke" while the real, unwrapped trigger sat entirely on
# the second — reproduced, then fixed by factoring the regex out to here.
function trigger_on(t) {
    if (t ~ /\*\*[Ii]nvoke[[:space:]]+the[[:space:]]+`?Workflow`?[[:space:]]+tool\*\*/) return 1
    if (t ~ /\*\*[Rr]un\*\*[[:space:]]+the[[:space:]]+`?Workflow`?[[:space:]]+tool/) return 1
    if (t ~ /[Ii]nvoke it as a background task/) return 1
    if (t ~ /run_in_background/) return 1
    return 0
}
function flush(   i, two, hit, named, hitline) {
    if (nsec == 0) return
    hit = 0; named = 0; hitline = 0
    for (i = 1; i <= nsec; i++) {
        two = sec[i] (i < nsec ? " " sec[i + 1] : "")
        if (trigger_on(two)) {
            if (!hit) {
                hit = 1
                # WHICH line to report. Three cases, and the ORDER matters:
                #
                #  1. sec[i] alone carries a complete trigger -> secln[i].
                #  2. sec[i+1] alone carries one -> secln[i+1]. The join matched
                #     only because it CONTAINS that line; sec[i] is unrelated
                #     prose that happens to precede it. Reporting sec[i] here is
                #     the cycle-1 defect: "We already invoked the setup earlier"
                #     got blamed for a trigger entirely on the next line.
                #  3. neither alone, only the join -> a genuine WRAP, so the
                #     trigger opens on sec[i] -> secln[i].
                #
                # Case 2 must be tested BEFORE case 3, since a wrap and a
                # trailing-line match are indistinguishable from the join alone.
                if (trigger_on(sec[i])) hitline = secln[i]
                else if (i < nsec && trigger_on(sec[i + 1])) hitline = secln[i + 1]
                else hitline = secln[i]
            }
        }
        if (sec[i] ~ /golem-work\.sh/) named = 1
        if (sec[i] ~ /background-work\.md/) named = 1
    }
    if (hit && !named) printf "%d:%s\n", hitline, sechdr
    nsec = 0
}
# Fenced code blocks must not be read for headings: a shell comment inside a
# fence is not a markdown heading, and treating it as one splits a section at a
# line the reader sees as code.
/^[[:space:]]*(```|~~~)/ { fence = !fence }
!fence && /^#+[[:space:]]/ { flush(); sechdr = $0 }
{ nsec++; sec[nsec] = $0; secln[nsec] = FNR }
END { flush() }
'

# scan_file <path>
# Populates CUR_VIOLATIONS with one "<relpath>:<line>: under <heading>" entry
# per offending section (empty when the file is clean).
CUR_FILE=""
CUR_VIOLATIONS=""
# FAIL LOUD ON A SCAN THAT COULD NOT RUN, never quietly "clean" (review cycle 1).
# The earlier form ended `2>/dev/null || true`, which folded an awk RUNTIME error
# into the same empty output as a clean file — so a per-file failure (an
# unexpected byte sequence, a platform regex quirk) would read as "this file has
# no unregistered background work". That is the silence-reads-as-a-pass shape this
# repo keeps filing issues about (#538, #571), arriving per-file instead of
# per-gate: the 77 sentinel covers an ABSENT awk, and nothing covered a PRESENT
# awk that failed.
#
# Runs awk to a temp file first so the exit status is the AWK's, not a pipeline's
# last stage — a `while read` fed by a process substitution discards it entirely.
# CUR_SCAN_ERR is set (not printed) so the caller decides how loudly to surface it;
# scan_file's own contract is "either accurate rows or a flagged failure".
CUR_SCAN_ERR=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    CUR_SCAN_ERR=""
    local row lineno hdr rel out err rc=0
    rel="${file#"$REPO_ROOT"/}"
    out="$(command mktemp)" || {
        CUR_SCAN_ERR="mktemp failed"
        return 0
    }
    err="$(command mktemp)" || {
        command rm -f "$out"
        CUR_SCAN_ERR="mktemp failed"
        return 0
    }
    command awk "$SCAN_AWK" "$file" >"$out" 2>"$err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        CUR_SCAN_ERR="awk exited $rc on $rel: $(command tr '\n' ' ' <"$err" | command cut -c1-200)"
        command rm -f "$out" "$err"
        return 0
    fi
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        lineno="${row%%:*}"
        hdr="${row#*:}"
        [ -n "$hdr" ] || hdr="(file head, before the first heading)"
        CUR_VIOLATIONS+="${rel}:${lineno}: under ${hdr}"$'\n'
    done <"$out"
    command rm -f "$out" "$err"
}

# --- Corpus -------------------------------------------------------------------

# The three pipeline skills, minus the protocol file itself. Each directory is
# REQUIRED, not best-effort: a renamed skill directory would silently narrow the
# corpus to nothing and the gate would go green while enforcing nothing — the
# same false-green class as a discovery typo. Fail loudly instead.
collect_corpus() {
    local d
    for d in ship-issue golem next-issue; do
        if [ ! -d "$SKILLS_DIR/$d" ]; then
            command printf 'lint-background-work-refs: skill directory not found: %s\n' \
                "$SKILLS_DIR/$d" >&2
            return 1
        fi
    done
    command find "$SKILLS_DIR/ship-issue" "$SKILLS_DIR/golem" "$SKILLS_DIR/next-issue" \
        -type f -name '*.md' | command grep -v '/background-work\.md$' | command sort
}

CORPUS="$(collect_corpus)"

corpus_count() {
    command printf '%s\n' "$CORPUS" | command grep -c . || true
}

# --- Tests ---------------------------------------------------------------------

# build_detail <violations> — cap the reported lines at MAX_DETAIL and append a
# "and N more" summary when truncating.
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
test_file_background_work_refs() {
    scan_file "$CUR_FILE"
    # A scan that could not RUN learned nothing — never render it as a pass.
    if [ -n "$CUR_SCAN_ERR" ]; then
        _fail "SCAN DID NOT RUN for $(command basename "$CUR_FILE") — $CUR_SCAN_ERR"
        return 0
    fi
    if [ -n "$CUR_VIOLATIONS" ]; then
        build_detail "$CUR_VIOLATIONS"
        _fail "Background work started without the registry named in $(command basename "$CUR_FILE") — name \`golem-work.sh\` or \`golem/background-work.md\` in the same section (#890)" \
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
    [ "$files" -ge 10 ] && ge_files=1
    assert_equals "1" "$ge_files" \
        "At least 10 markdown files must be in the corpus (found $files)"
    assert_contains "$CORPUS" "/ship-issue/pre-ship-validation.md" \
        "The corpus includes pre-ship-validation.md (where the review harness is invoked)"
    assert_contains "$CORPUS" "/ship-issue/ci-review-protocol.md" \
        "The corpus includes ci-review-protocol.md (the multi-cycle loop + ci-fixer)"
}

# The corpus scope is a tested DECISION, not an accident of the find roots.
# orchestrate/ is the observer of golem background work — it reads the registry
# rather than writing it — so demanding registration in its sections would be a
# false claim. Pin both halves: what is in, and what is deliberately out.
test_corpus_scope_is_deliberate() {
    assert_not_contains "$CORPUS" "/skills/orchestrate/" \
        "orchestrate/ is out of scope — it OBSERVES background work, it does not start it"
    assert_not_contains "$CORPUS" "/docs/verification/" \
        "docs/verification/** is out of scope (dated e2e transcripts)"

    # Those assertions are true BY CONSTRUCTION (both sit outside the walked
    # roots), so they would pass with every filter deleted. What actually needs
    # pinning is the property they depend on: the roots stay narrow. Widening to
    # $SKILLS_DIR would sweep orchestrate/ in and make the assertion above start
    # failing for real.
    local outside="" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$SKILLS_DIR"/ship-issue/* | "$SKILLS_DIR"/golem/* | "$SKILLS_DIR"/next-issue/*) continue ;;
            *) outside="${outside}${f}"$'\n' ;;
        esac
    done <<<"$CORPUS"
    assert_equals "" "$outside" \
        "The corpus is exactly ship-issue/ + golem/ + next-issue/ (roots have not widened)"
}

# The exemption is ONE FILE, not a directory. A `golem/*` exemption would
# silently un-gate golem/SKILL.md — which DOES start background work and is one
# of the two files that already carried a registration pointer before this gate.
test_exemption_is_narrow() {
    assert_not_contains "$CORPUS" "/background-work.md" \
        "The protocol file itself is exempt (it DEFINES the triggers it mentions)"
    assert_contains "$CORPUS" "/golem/SKILL.md" \
        "The exemption is one FILE — golem/SKILL.md is still gated"

    # And the exempt file genuinely WOULD fire without the exemption, otherwise
    # the exemption is decoration and this test asserts nothing. (An exemption
    # over a file that never arms the gate is the vacuity shape #681's gate hit.)
    scan_file "$EXEMPT_FILE"
    assert_not_empty "$CUR_VIOLATIONS" \
        "background-work.md genuinely arms the gate (its exemption is not vacuous)"
}

# Positive control. Every per-file test goes green on an EMPTY corpus, and would
# also go green if someone deleted the background-work prose outright rather than
# naming the registry beside it. Assert the registry is genuinely named in the
# real tree — and specifically in ship-issue/, whose ZERO hits are the
# measurement #890's remaining gap was found by.
test_registry_named_in_real_corpus() {
    local hits ge=0
    hits="$(command grep -rlE 'golem-work\.sh|background-work\.md' \
        "$SKILLS_DIR/ship-issue" --include='*.md' 2>/dev/null | command grep -c . || true)"
    [ "$hits" -ge 3 ] && ge=1
    assert_equals "1" "$ge" \
        "ship-issue/ must name the registry in at least 3 files (found $hits; it was 0 before #890)"

    local files
    files="$(command grep -rlE 'golem-work\.sh' "$SKILLS_DIR" --include='*.md' 2>/dev/null || true)"
    assert_not_empty "$files" \
        "The registry script golem-work.sh must appear in the corpus (named, not deleted)"
}

# Negative case: the violation branch must fire on the offending shapes, and
# every satisfier must NOT fire. Without this, a regression in the awk program
# would report PASS while enforcing nothing.
#
# Needles are section HEADINGS, not `:<line>: ` prefixes. The violation text is
# otherwise identical across sections, so a needle must be unique per section —
# and a line number stops being that the moment the fixture above it grows a
# line, which silently turns an assertion into one about the wrong section.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/fixture.md" <<'FIXTURE'
## Bare harness invocation
   b. **Invoke the `Workflow` tool** with the bundled script.

## Named by script
   b. **Invoke the `Workflow` tool** with the bundled script.
   Register it first: `golem-work.sh register workflow`.

## Named by companion
   b. **Invoke the `Workflow` tool** with the bundled script.
   Protocol: `golem/background-work.md`.

## Unbackticked bold invocation
   b. **Invoke the Workflow tool** with the bundled script.

## Backgrounded ci-fixer
Invoke it as a background task and poll for the verdict.

## Backgrounded bash
Start the suite with run_in_background and poll it.

## Run spelling
**Run** the `Workflow` tool over the committed diff.

## Merely discussing the harness
The Workflow tool is already opted in for this skill, see #637.

## A pointer is not the artifact
   b. **Invoke the `Workflow` tool** with the bundled script.
   Remember to register the background work first.
FIXTURE

    scan_file "$tmp/fixture.md"
    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags an unregistered site (violation branch fires)"

    # Positive branch — the offending shapes.
    assert_contains "$CUR_VIOLATIONS" "Bare harness invocation" \
        "A bolded Workflow invocation with no registry named is flagged"
    assert_contains "$CUR_VIOLATIONS" "Unbackticked bold invocation" \
        "The unbackticked Workflow tool spelling is flagged too"
    assert_contains "$CUR_VIOLATIONS" "Backgrounded ci-fixer" \
        "'Invoke it as a background task' is flagged (the ci-fixer site)"
    assert_contains "$CUR_VIOLATIONS" "Backgrounded bash" \
        "run_in_background is flagged"
    assert_contains "$CUR_VIOLATIONS" "Run spelling" \
        "The **Run** the Workflow tool spelling is flagged"
    # The prose-not-artifact line, which is the whole defect class: saying
    # "register the background work" without naming golem-work.sh sends the
    # reader nowhere. Same line lint-harness-refs.sh draws for #681.
    assert_contains "$CUR_VIOLATIONS" "A pointer is not the artifact" \
        "Describing registration without naming the artifact is NOT a satisfier"

    # Negative branch — one per satisfier, plus the non-imperative mention.
    assert_not_contains "$CUR_VIOLATIONS" "Named by script" \
        "A section naming golem-work.sh is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "Named by companion" \
        "A section naming background-work.md is NOT flagged"
    # The narrowness half. Without it the gate could pass by flagging every
    # mention of the word Workflow, which would fire across orchestrate/ and get
    # the gate turned off — the failure mode a too-eager lens always reaches.
    assert_not_contains "$CUR_VIOLATIONS" "Merely discussing the harness" \
        "A section that DISCUSSES the harness without invoking it is NOT flagged"
}

# Pins the two-line window. The trigger wraps across a newline in real prose, so
# a matcher collapsed to one line at a time would MISS it — green before the fix
# and green after, the textbook tautological gate.
test_wrapped_trigger_is_detected() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # The wrap splits the TRIGGER ITSELF: line 2 ends on "**Invoke the" and
    # line 3 opens with "`Workflow` tool**", so neither line carries a complete
    # trigger and only the joined window matches.
    command cat >"$tmp/wrapped.md" <<'FIXTURE'
## Wrapped across a newline
   b. **Invoke the
   `Workflow` tool** with the script bundled alongside this skill.
FIXTURE

    # Guard the fixture: prove neither line matches alone, so the assertion
    # below can only pass because of the window.
    local single
    single="$(command grep -cE '\*\*[Ii]nvoke[[:space:]]+the[[:space:]]+`?Workflow`?[[:space:]]+tool\*\*' \
        "$tmp/wrapped.md" || true)"
    assert_equals "0" "$single" \
        "Fixture guard: no single line carries the trigger (found $single)"

    scan_file "$tmp/wrapped.md"
    assert_contains "$CUR_VIOLATIONS" ":2: " \
        "A trigger wrapped across two lines IS detected (window is load-bearing)"

    # And the window must not leak past a section boundary: a trigger whose two
    # halves straddle a heading is two different topics, not one wrapped phrase.
    command cat >"$tmp/straddle.md" <<'FIXTURE'
## First section ends mid-trigger
   b. **Invoke the

## Second section opens with
   `Workflow` tool** — registered via `golem-work.sh`.
FIXTURE
    scan_file "$tmp/straddle.md"
    assert_equals "" "$CUR_VIOLATIONS" \
        "The window does not join lines across a heading boundary"
}

# Pins the FAIL-LOUD scan path (review cycle 1). A scan that could not run
# learned nothing, so it must never render as "clean" — the per-file arm of the
# #538/#571 silence-reads-as-a-pass rule. Forces a real awk failure by handing the
# scanner a syntactically invalid program, which is the only way to exercise the
# branch without waiting for a platform quirk.
test_scan_failure_is_loud_not_clean() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/subject.md" <<'FIXTURE'
## An unregistered site
   b. **Invoke the `Workflow` tool** with the bundled script.
FIXTURE

    # Control: with the real program the file is flagged, so the fixture is
    # genuinely scannable and the mutation below is what changes the outcome.
    scan_file "$tmp/subject.md"
    assert_not_empty "$CUR_VIOLATIONS" "Control: the fixture is flagged by the real program"
    assert_equals "" "$CUR_SCAN_ERR" "Control: a healthy scan reports no error"

    # Now break the program itself and re-scan the SAME file.
    local saved="$SCAN_AWK"
    SCAN_AWK='function { syntax error'
    scan_file "$tmp/subject.md"
    local broke_err="$CUR_SCAN_ERR" broke_rows="$CUR_VIOLATIONS"
    SCAN_AWK="$saved"

    assert_not_empty "$broke_err" \
        "A failing awk sets CUR_SCAN_ERR instead of yielding a silent clean file"
    assert_equals "" "$broke_rows" \
        "A failed scan reports NO rows (it cannot know them) rather than partial ones"
    assert_contains "$broke_err" "awk exited" \
        "The error names the failure and its file (actionable, not silent)"

    # And the per-file test body must FAIL on that state rather than pass.
    CUR_FILE="$tmp/subject.md"
    SCAN_AWK='function { syntax error'
    local out rc=0
    out="$(test_file_background_work_refs 2>&1)" || rc=$?
    SCAN_AWK="$saved"
    assert_contains "$out" "SCAN DID NOT RUN" \
        "The per-file test surfaces a scan failure as a failure, not a pass"
}

# Pins LINE ATTRIBUTION against the cycle-1 review defect. The window joins two
# lines, so when a match appears only in the join there are three possible sites,
# and an earlier draft keyed the choice off a loose /[Ii]nvoke/ keyword — which
# blamed any line merely containing "invoked"/"invoking"/"revoke" for a trigger
# that sat entirely on the NEXT line. A wrong line number sends the author to
# unrelated prose, and the gate looks broken rather than right.
test_line_attribution_picks_the_trigger_line() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # Case 2: the preceding line contains "invoked" but NO complete trigger; the
    # real trigger is wholly on the line after it. This is the reproduced defect.
    command cat >"$tmp/herring.md" <<'FIXTURE'
## Red herring above the trigger
We already invoked the setup earlier for context.
   b. **Invoke the `Workflow` tool** with the bundled script.
FIXTURE
    scan_file "$tmp/herring.md"
    assert_contains "$CUR_VIOLATIONS" ":3: " \
        "The trigger line is reported, not the line that merely says 'invoked'"
    assert_not_contains "$CUR_VIOLATIONS" ":2: " \
        "The unrelated preceding line is NOT blamed (cycle-1 defect)"

    # Case 1: a complete trigger on one line, with prose after it, still reports
    # its own line — the narrowness check for the fix above.
    command cat >"$tmp/plain.md" <<'FIXTURE'
## Plain single-line trigger
   b. **Invoke the `Workflow` tool** with the bundled script.
and some trailing prose that mentions invoking things.
FIXTURE
    scan_file "$tmp/plain.md"
    assert_contains "$CUR_VIOLATIONS" ":2: " \
        "A complete single-line trigger reports its own line"

    # Case 3: a genuine WRAP still reports the OPENING line, which is the
    # property test_wrapped_trigger_is_detected depends on. Pinned here too so a
    # future edit to the three-case branch cannot satisfy one case by breaking
    # another — the three are one decision and must be asserted together.
    command cat >"$tmp/wrap.md" <<'FIXTURE'
## Genuine wrap
   b. **Invoke the
   `Workflow` tool** with the bundled script.
FIXTURE
    scan_file "$tmp/wrap.md"
    assert_contains "$CUR_VIOLATIONS" ":2: " \
        "A wrapped trigger reports the line it opens on"
}

# Pins the fence toggle. A `#`-prefixed line inside a fenced block is a shell
# comment, not a markdown heading. Without the toggle that line splits the
# section, and the violation gets attributed to a "heading" the reader sees as
# code — and worse, it can separate a trigger from the satisfier that answers it.
test_fence_suppresses_fake_heading() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/fenced.md" <<'FIXTURE'
## Real heading

```bash
# Not a heading — a shell comment inside a fence
golem-status.sh --once
```

   b. **Invoke the `Workflow` tool** with the bundled script.
FIXTURE

    scan_file "$tmp/fenced.md"
    assert_contains "$CUR_VIOLATIONS" "Real heading" \
        "The violation is attributed to the real heading, not the fenced comment"
    assert_not_contains "$CUR_VIOLATIONS" "Not a heading" \
        "A #-prefixed line inside a fence never becomes a section heading"

    # The toggle must also CLOSE. If `fence` latched on at the first fence and
    # never flipped back, every later heading would be swallowed and the whole
    # remainder would collapse into one section — at which point a satisfier
    # anywhere below would silently discharge every trigger above it. Two
    # sections, two separate violations, is the observable difference.
    command cat >"$tmp/reopen.md" <<'FIXTURE'
## First real heading

```bash
# fenced comment
```

   b. **Invoke the `Workflow` tool** with the bundled script.

## Second real heading

   b. **Invoke the `Workflow` tool** again, still unregistered.
FIXTURE

    scan_file "$tmp/reopen.md"
    assert_contains "$CUR_VIOLATIONS" "First real heading" \
        "The section before the fence is reported"
    assert_contains "$CUR_VIOLATIONS" "Second real heading" \
        "A heading AFTER a closed fence still starts its own section (toggle closed)"
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

# Pins collect_corpus's fail-loud branch. The behavior under test is "the gate
# ABORTS", which run_test's `if "$test_func"` suspends `set -e` for and therefore
# cannot observe — so SLICE the real function out of this file and drive it at
# top level against a SKILLS_DIR missing a skill. Slicing rather than restating
# is the point: a hand-copied body would keep passing after the real function
# regained a `|| true`.
test_missing_skill_dir_fails_loudly() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # ship-issue and golem exist; next-issue is missing.
    command mkdir -p "$tmp/skills/ship-issue" "$tmp/skills/golem"
    command printf '# s\n' >"$tmp/skills/ship-issue/SKILL.md"

    local sliced="$tmp/sliced.sh"
    {
        command printf 'set -euo pipefail\n'
        command printf 'SKILLS_DIR=%s\n' "$tmp/skills"
        command sed -n '/^collect_corpus() {$/,/^}$/p' "$SELF_PATH"
        command printf 'CORPUS="$(collect_corpus)"\n'
        command printf 'command printf "REACHED_AFTER:[%%s]\\n" "$CORPUS"\n'
    } >"$sliced"

    # Guard the slice: a broken sed would make the probe fail for the wrong reason.
    assert_contains "$(command cat "$sliced")" "collect_corpus() {" \
        "The real collect_corpus was sliced out (probe is not vacuous)"

    local out rc=0
    out="$(command bash "$sliced" 2>"$tmp/err")" || rc=$?
    assert_equals "1" "$rc" "A missing skill directory makes the gate exit non-zero"
    assert_contains "$(command cat "$tmp/err")" "skill directory not found" \
        "The failure names the missing directory (actionable, not silent)"
    assert_not_contains "$out" "REACHED_AFTER" \
        "Execution does NOT continue past the corpus build with a narrowed corpus"

    command mkdir -p "$tmp/skills/next-issue"
    command printf '# n\n' >"$tmp/skills/next-issue/SKILL.md"
    local out2 rc2=0
    out2="$(command bash "$sliced" 2>/dev/null)" || rc2=$?
    assert_equals "0" "$rc2" "With all three directories present, collect_corpus succeeds"
    assert_contains "$out2" "ship-issue/SKILL.md" "The corpus it returns includes a real file"
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
# full gate — including this test — and recurses until it is killed. Instead,
# SLICE the real skip branch out and drive it standalone. The slice has no test
# bodies in it, so it cannot recurse no matter what PATH does.
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
run_test test_corpus_scope_is_deliberate "orchestrate/ is out of scope on purpose (observer, not writer)"
run_test test_exemption_is_narrow "The exemption is one FILE, and it genuinely arms the gate"
run_test test_negative_case_fires "scan_file flags unregistered sites and honors every satisfier"
run_test test_wrapped_trigger_is_detected "A trigger wrapped across two lines is detected (not single-line)"
run_test test_scan_failure_is_loud_not_clean "A scan that could not run fails loud, never reads as clean (cycle-1 review)"
run_test test_line_attribution_picks_the_trigger_line "The reported line is the trigger line, not a neighbour (cycle-1 review)"
run_test test_fence_suppresses_fake_heading "A #-line inside a code fence is not treated as a heading"
run_test test_registry_named_in_real_corpus "The registry is genuinely named in the real corpus"
run_test test_detail_truncation "Violation detail truncates at MAX_DETAIL with an accurate remainder"
run_test test_missing_skill_dir_fails_loudly "A missing skill directory aborts the gate instead of narrowing the corpus"
run_test test_missing_awk_exits_77 "With awk absent the gate exits 77, not 0"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_background_work_refs "${f#"$REPO_ROOT"/}: background work names the registry"
done <<<"$CORPUS"

generate_report
