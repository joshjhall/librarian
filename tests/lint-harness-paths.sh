#!/usr/bin/env bash
# Harness-path reachability gate (issue #973).
#
# Every golem's adversarial pre-PR review silently stopped running. Two defects
# stacked, and neither was visible from inside a run:
#
#   1. The `Workflow` tool only accepts a `scriptPath` under the session's cwd.
#      The plugin installs outside it (/opt/librarian/…, or
#      ~/.claude/plugins/cache/<mkt>/<plugin>/<version>/…), and a golem's cwd is
#      its worktree — so the real, present harness was REFUSED.
#   2. Eleven prose sites named `~/.claude/skills/<name>/workflow.js`, which is
#      not the dev layout NOR the installed layout. It resolved on no tree.
#
# The documented degradation clause then skipped the review when the harness was
# "absent from disk" — permanently true — so a five-dimension review plus a judge
# was replaced, every run, by `Review status: skipped (harness not available)`.
# Silence-reads-as-a-pass (#538/#571) at the most expensive site in the repo.
#
# #973 replaced every one of those literals with `harness-stage.sh`, which
# resolves the harness and stages it under cwd. This gate is what stops the
# literals coming back — the same answer this repo gives the whole
# "prose that must stay true" class: lint-command-refs.sh, lint-harness-refs.sh
# (#681), lint-readonly-harness.sh, lint-action-pins.sh.
#
# THREE RULES.
#
#   R1  No `~/.claude/**/workflow.js` literal anywhere in the corpus. This is the
#       exact spelling that resolved nowhere. Flagged on sight — there is no
#       context in which it is correct.
#
#   R2  A markdown SECTION that invokes the `Workflow` tool on a harness must
#       name `harness-stage.sh` in that same section. Section scope, not
#       whole-file, for the reason #681 records: a file may name the stager once
#       in an overview and then describe an invocation three screens later, and
#       the reader is at the invocation. Satisfied by naming the script; NOT
#       satisfied by "stage the harness" in prose, because a pointer to a
#       concept is what drifts.
#
#   R3  RESOLVABILITY, which is what makes this gate more than a spell-checker.
#       Every id `harness-stage.sh list` prints must actually resolve on this
#       tree (`harness-stage.sh path <id>` exits 0 and names an existing file).
#       R1 and R2 together only prove the prose is CONSISTENT; R3 proves it is
#       TRUE. A rename of any harness file — or a new id added to the table with
#       a typo'd relative path — fails here rather than at 2am inside a golem,
#       which is the regression AC4 asks to prevent.
#
# WHY R2 IS TWO-LINE-WINDOWED, like #681: the invocation phrase wraps in the real
# corpus (`invoke the Workflow tool on\n  the path=…`). A single-line matcher
# would miss exactly the prose shape being enforced — green before the fix and
# green after, the definition of a tautological gate. test_wrapped_invocation
# plants that shape to catch a future collapse back to line-at-a-time.
#
# CORPUS: plugins/**/*.md plus the top-level README.md — mirroring
# lint-harness-refs.sh exactly, and for the same reasons. Two absences are out of
# scope BY CONSTRUCTION (outside the walked root), not by an active filter:
#   CHANGELOG.md         — git-cliff-generated release notes.
#   docs/verification/** — dated end-to-end transcripts. A VERIFIED-live block
#                          records what a command actually printed; rewriting it
#                          falsifies the evidence.
# test_exclusions_are_deliberate pins the NARROWNESS of the root itself, since
# widening it to $REPO_ROOT is the plausible regression that would sweep them in.
#
# NOT IN THE CORPUS: tests/. lint-command-refs.sh carries POSITIVE fixtures
# containing the dead path (asserting it is not mistaken for a slash-command
# ref), and this gate must not fight that one. The roots simply do not overlap.
#
# Detection is awk, not grep: R2 is stateful (accumulate a section, then judge
# it), and awk's regex engine behaves the same on BSD and GNU, which grep's does
# not. No `\s`, `\w`, or `grep -P` anywhere — POSIX classes only.
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"
STAGER="$PLUGINS_DIR/workflow/scripts/harness-stage.sh"

# Cap on violation detail lines per file so a large regression stays readable.
MAX_DETAIL=40

test_suite "Harness-path reachability (#973)"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
# run-all.sh renders it as [SKIP] instead of [ok]. A silent skip is
# indistinguishable from a pass, which is how a gate sits inert unnoticed
# (#538, #571) — so this must never be a bare exit 0.
SKIP_EXIT_CODE=77

if ! command -v awk >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — awk not available (install awk to check harness paths)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Detection ---------------------------------------------------------------

# Emits one `<line>:<rule>:<heading>` row per violation.
#   R1 rows are per-LINE (the literal is a point defect).
#   R2 rows are per-SECTION (the requirement is a section property).
#
# `two` is the current line joined to the next, implementing the wrapped-phrase
# window for R2. The last line of a section joins nothing, correctly — a phrase
# cannot wrap past the end of its own section.
#
# The R2 trigger requires the Workflow tool AND a PATH-SHAPED reference
# (`workflow.js` or `path=`) on the same window. Both halves are needed, and the
# narrowing is not incidental — an earlier, looser version also accepted the bare
# word "harness" and immediately produced a false positive on
# dev-core/skills/workflow-authoring/SKILL.md § "No Clock in the Sandbox", which
# says a caller "can invoke the harness as a background task". That is authoring
# GUIDANCE about the tool, not an invocation of it, and forcing it to name the
# stager would be enforcing a falsehood. The discriminator that holds: a genuine
# invocation site always names what to invoke.
#
# Consequence worth stating, because it bounds the rule: an invocation written
# with no path reference at all is invisible to R2. That is deliberate — R1 and
# R3 are what make the paths true, and R2 exists to keep an invocation that DOES
# carry a path from carrying a raw one. A gate that guessed at intent here would
# fire on prose, and a gate that fires on prose gets switched off.
SCAN_AWK='
function flush(   i, two, invoked, staged, invln) {
    if (nsec == 0) return
    invoked = 0; staged = 0; invln = 0
    for (i = 1; i <= nsec; i++) {
        two = sec[i] (i < nsec ? " " sec[i + 1] : "")
        if (two ~ /[Ii]nvoke[a-z]*[[:space:]]+(the[[:space:]]+)?`?Workflow`?[[:space:]]+tool/ &&
            two ~ /workflow\.js|path=/) {
            if (!invoked) { invoked = 1; invln = secln[i] }
        }
        if (sec[i] ~ /harness-stage\.sh/) staged = 1
    }
    if (invoked && !staged) printf "%d:R2:%s\n", invln, sechdr
    nsec = 0
}
# Fenced code must not be read for headings: a shell comment inside a ``` fence
# is not a markdown heading, and treating it as one splits a section at a line
# the reader sees as code.
/^[[:space:]]*(```|~~~)/ { fence = !fence }
!fence && /^#+[[:space:]]/ { flush(); sechdr = $0 }
# R1 is checked per line, inside or outside a fence — a dead path in an example
# block is exactly as wrong as one in prose, and more likely to be copied.
/~\/\.claude\/[^[:space:]]*workflow\.js/ { printf "%d:R1:%s\n", FNR, $0 }
{ nsec++; sec[nsec] = $0; secln[nsec] = FNR }
END { flush() }
'

CUR_FILE=""
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local row lineno rule rest rel
    rel="${file#"$REPO_ROOT"/}"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        lineno="${row%%:*}"
        rest="${row#*:}"
        rule="${rest%%:*}"
        rest="${rest#*:}"
        if [ "$rule" = "R1" ]; then
            CUR_VIOLATIONS+="${rel}:${lineno}: R1 unreachable ~/.claude harness path"$'\n'
        else
            [ -n "$rest" ] || rest="(file head, before the first heading)"
            CUR_VIOLATIONS+="${rel}:${lineno}: R2 invokes the harness without naming harness-stage.sh, under ${rest}"$'\n'
        fi
    done < <(command awk "$SCAN_AWK" "$file" 2>/dev/null || true)
}

# --- Corpus -------------------------------------------------------------------

# README.md is REQUIRED, not best-effort: silently skipping a missing one would
# narrow the corpus without saying so — the same false-green class as a
# discovery typo. Fail loudly instead.
collect_corpus() {
    command find "$PLUGINS_DIR" -type f -name '*.md' | command sort
    if [ ! -f "$REPO_ROOT/README.md" ]; then
        command printf 'lint-harness-paths: README.md not found at %s\n' \
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
test_file_harness_paths() {
    scan_file "$CUR_FILE"
    if [ -n "$CUR_VIOLATIONS" ]; then
        build_detail "$CUR_VIOLATIONS"
        _fail "Unreachable or unstaged harness path in $(command basename "$CUR_FILE") — invoke the Workflow tool on the \`path=\` from \`harness-stage.sh stage <id>\`, never a \`~/.claude/…/workflow.js\` literal (#973)" \
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
    assert_contains "$CORPUS" "/plugins/workflow/skills/ship-issue/pre-ship-validation.md" \
        "The corpus includes pre-ship-validation.md (the file #973 was filed against)"
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
    # needs pinning is the property they depend on: the root stays narrow.
    # Widening it to $REPO_ROOT would sweep them in — and would also sweep in
    # tests/lint-command-refs.sh's fixtures, which legitimately contain the dead
    # path.
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

# R3 — RESOLVABILITY. The rule that makes this gate assert truth rather than
# self-consistency. Every advertised id must resolve to a file that exists.
test_every_harness_id_resolves() {
    if [ ! -x "$STAGER" ]; then
        _fail "harness-stage.sh is missing or not executable at $STAGER — the staging recipe every skill now names would fail (#973)"
        return 0
    fi

    local ids id out path rc bad=""
    ids="$("$STAGER" list 2>/dev/null || true)"
    assert_not_empty "$ids" "harness-stage.sh list must advertise at least one harness id"

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        out="$("$STAGER" path "$id" 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -ne 0 ]; then
            bad="${bad}${id}: exit ${rc}"$'\n'
            continue
        fi
        # Parse the key=value contract rather than assuming line order.
        path="$(command printf '%s\n' "$out" | command sed -n 's/^path=//p')"
        if [ -z "$path" ]; then
            bad="${bad}${id}: no path= line in output"$'\n'
        elif [ ! -f "$path" ]; then
            bad="${bad}${id}: path= names a file that does not exist: ${path}"$'\n'
        fi
    done <<<"$ids"

    assert_equals "" "$bad" \
        "Every harness id advertised by harness-stage.sh must resolve to an existing file (#973 AC4)"
}

# Positive control. Every per-file test goes green on an EMPTY corpus, and would
# also go green if someone deleted the staging prose outright rather than fixing
# it. Assert the recipe is genuinely present in the real tree, at the site #973
# was filed against.
test_staging_recipe_present_in_real_corpus() {
    local files
    files="$(command grep -rl 'harness-stage\.sh' "$PLUGINS_DIR" \
        --include='*.md' 2>/dev/null || true)"
    assert_not_empty "$files" \
        "The staging recipe must appear in the corpus (named, not deleted)"

    # Step 3.5 check 6 — the site #973 was filed against — moved into its own
    # companion when pre-ship-validation.md passed its prose budget, so this
    # anchors on the file that now HOLDS the invocation, not the one that used
    # to. Anchoring on the old name would have this positive control pass on a
    # stale duplicate and fail on a correct split.
    local step="$PLUGINS_DIR/workflow/skills/ship-issue/adversarial-review-step.md"
    local hits
    hits="$(command grep -c 'harness-stage\.sh' "$step" 2>/dev/null || true)"
    local ge=0
    [ "${hits:-0}" -ge 1 ] && ge=1
    assert_equals "1" "$ge" \
        "adversarial-review-step.md must name harness-stage.sh (found ${hits:-0}); its Workflow invocation is the site #973 was filed against"
}

# The degradation clause must distinguish an UNREACHABLE harness from an ABSENT
# one (#973 AC5). Before the fix it did not, so the skip fired on every run.
test_degradation_is_narrowed() {
    local f hits
    for f in pre-ship-validation ci-review-protocol; do
        local path="$PLUGINS_DIR/workflow/skills/ship-issue/${f}.md"
        [ -f "$path" ] || {
            skip_test "${f}.md not found"
            continue
        }
        hits="$(command grep -c 'unavailable' "$path" 2>/dev/null || true)"
        local ge=0
        [ "${hits:-0}" -ge 1 ] && ge=1
        assert_equals "1" "$ge" \
            "${f}.md must carry the 'unavailable' disposition, distinct from 'skipped' (#973 AC5; found ${hits:-0})"
    done
}

# Negative case: the violation branches must fire on the offending shapes, and
# the satisfiers must NOT fire. Without this, a regression in the awk program
# would report PASS while enforcing nothing.
#
# Needles are section HEADINGS, not `:<line>: ` prefixes — a line number stops
# identifying a section the moment the fixture above it grows a line, which
# silently turns an assertion into one about the wrong section (the lesson
# lint-harness-refs.sh records from getting this wrong twice).
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }

    command cat >"$tmp/fixture.md" <<'EOF'
## Dead path in prose

Invoke the `Workflow` tool with `~/.claude/skills/ship-issue/workflow.js`.

## Dead path in a fence

```bash
node ~/.claude/agents/ci-fixer/workflow.js
```

## Invocation without the stager

**Invoke the `Workflow` tool** with `ship-issue/workflow.js`, passing args.

## Wrapped invocation without the stager

Now **invoke the Workflow tool**
with `orchestrate/workflow.js`, passing args.

## Properly staged

Run `harness-stage.sh stage ship-issue`, then **invoke the `Workflow` tool**
on the `path=` it printed.

## Merely discussing the harness

`workflow.js` runs in a sandbox with no shell, so a budget cannot be read there.

## Authoring guidance is not an invocation

A caller can invoke the harness as a background task and poll `TaskOutput`.
EOF

    scan_file "$tmp/fixture.md"
    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags violations (the branch fires at all)"

    assert_contains "$CUR_VIOLATIONS" "R1" \
        "R1 fires on a ~/.claude harness literal in prose"
    # The fenced section carries no invocation phrase, so R2 correctly stays
    # silent there and only R1 fires — which the r1count assertion below proves.
    # (An earlier draft asserted the section HEADING appeared, which conflated
    # "R1 fired inside a fence" with "R2 reported the section"; R1 rows are
    # per-line and carry no heading, so that assertion was testing the wrong
    # thing and failed for the right reason.)
    assert_contains "$CUR_VIOLATIONS" "Invocation without the stager" \
        "R2 fires on an invocation that never names harness-stage.sh"
    assert_contains "$CUR_VIOLATIONS" "Wrapped invocation without the stager" \
        "R2 fires on a WRAPPED invocation phrase (the two-line window is load-bearing)"

    assert_not_contains "$CUR_VIOLATIONS" "Properly staged" \
        "Naming harness-stage.sh in the section satisfies R2"
    assert_not_contains "$CUR_VIOLATIONS" "Merely discussing the harness" \
        "Prose that discusses workflow.js without invoking it is not a violation"
    # Regression fixture for a real false positive: the looser first draft of R2
    # flagged workflow-authoring/SKILL.md § "No Clock in the Sandbox" on exactly
    # this sentence. Kept as a fixture so re-loosening the trigger fails here
    # rather than in the corpus.
    assert_not_contains "$CUR_VIOLATIONS" "Authoring guidance is not an invocation" \
        "Guidance that says a caller 'can invoke the harness' names no path and is not an invocation site"

    # R1 must fire on BOTH literals — the prose one and the fenced one. Counting
    # is what proves the fence does not suppress it, which a `contains R1` cannot.
    local r1count
    r1count="$(command printf '%s\n' "$CUR_VIOLATIONS" | command grep -c 'R1' || true)"
    assert_equals "2" "$r1count" \
        "R1 fires on both literals, in prose and inside a fence (found ${r1count})"

    command rm -rf "$tmp"
}

# The real corpus must be clean of R1. Stated separately from the per-file tests
# so a regression names the rule rather than only the file.
test_no_dead_paths_remain() {
    local hits
    # SC2088: the `~` here is a LITERAL being searched for in markdown text, not
    # a path this script is expanding. Expanding it to $HOME is precisely wrong —
    # the whole point is to find the un-expanded `~/.claude/…` spelling that
    # resolves on no tree.
    # shellcheck disable=SC2088
    hits="$(command grep -rlE '~/\.claude/[^[:space:]]*workflow\.js' "$PLUGINS_DIR" \
        --include='*.md' 2>/dev/null || true)"
    assert_equals "" "$hits" \
        "No plugin markdown may name a ~/.claude/**/workflow.js path — it resolves on no tree (#973)"
}

# --- Dispatch ------------------------------------------------------------------

run_test test_corpus_non_empty "Corpus is discovered and non-trivial"
run_test test_exclusions_are_deliberate "Corpus exclusions are deliberate (root stays narrow)"
run_test test_every_harness_id_resolves "Every advertised harness id resolves (#973 AC4)"
run_test test_staging_recipe_present_in_real_corpus "Staging recipe present in the real corpus (positive control)"
run_test test_degradation_is_narrowed "Degradation clause distinguishes unavailable from skipped (#973 AC5)"
run_test test_negative_case_fires "Negative fixtures fire; satisfiers do not"
run_test test_no_dead_paths_remain "No ~/.claude harness literals remain (#973 AC2)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_harness_paths "harness paths: ${f#"$REPO_ROOT"/}"
done <<<"$CORPUS"

generate_report
