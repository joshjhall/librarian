#!/usr/bin/env bash
# delegation-adoption behavioral gate (issue #797).
#
# The tool answers whether the #785 investigation-delegation guidance actually
# fires. Its headline result on the real corpus is a ZERO — no delegated fan-out
# investigations — and that zero is written into
# docs/verification/delegation-recall-tally-785.md as evidence.
#
# WHY THE FIXTURES LEAN ON VACUITY. For most tools the dangerous regression is a
# wrong number. For this one it is a CORRECT-LOOKING ZERO: the boring explanation
# for "found no delegations" is that the counter looked in the wrong place, ran
# against an empty root, or classified every spawn into the wrong bucket. Each of
# those failures produces exactly the output the verdict is built on. So the
# fixtures below pin, in preference to anything else:
#
#   * a corpus with BOTH kinds present         — the split must be 1/1, never 2/0
#                                                or 0/2. A classifier stuck on
#                                                either constant reproduces the
#                                                real corpus's shape by accident.
#   * an empty corpus exits 3, never 0         — "did not run" must not read as a
#                                                measured zero (#538/#571). This
#                                                is the single most important
#                                                assertion in the file.
#   * `opportunities` survives zero spawns     — it is the DENOMINATOR that makes
#                                                the zero mean something, so an
#                                                exit 3 keyed on spawns would
#                                                suppress it in exactly the case
#                                                the tool was written for.
#   * the break-even is a PRODUCT               — tokens x turns_resident. A small
#                                                long-resident result must clear
#                                                while a larger short-lived one
#                                                does not; asserting only on size
#                                                would pass with the multiplier
#                                                dropped.
#   * `workflows` matches a PATH SEGMENT        — not a substring. A session dir
#                                                whose name merely contains the
#                                                letters would otherwise
#                                                reclassify direct spawns as
#                                                harness traffic and manufacture
#                                                the zero.
#
# Pure bash + coreutils; no node/jq. Full command paths per project convention.
# bash-3.2 clean. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

ADOPTION_PY="$REPO_ROOT/plugins/workflow/scripts/delegation-adoption.py"
ADOPTION_SH="$REPO_ROOT/plugins/workflow/scripts/delegation-adoption.sh"

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while realpath-based code resolves the same dir to
# /private/var/... Any prefix match between the two spellings fails (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "delegation-adoption behavioral gate (#797)"

# Python-3.11+ only BY DESIGN (it parses JSONL; there is no bash fallback). With
# no such runtime the whole gate reports the reserved 77 sentinel rather than
# passing vacuously — a silent skip is indistinguishable from a pass (CLAUDE.md).
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    command printf '%s\n' \
        "delegation-adoption gate: no python3 >= 3.11 — gate DID NOT RUN." >&2
    exit 77
fi

# --- fixture builders --------------------------------------------------------

# harness_spawn ROOT NAME AGENT_TYPE — a spawn under a `workflows/` segment,
# i.e. one fanned out by a workflow.js harness rather than delegated by a human.
harness_spawn() {
    local dir="$1/proj/sess/subagents/workflows/wf_abc"
    command mkdir -p "$dir"
    command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"harness finding"}]}}\n' \
        >"$dir/agent-$2.jsonl"
    command printf '{"agentType":"%s","spawnDepth":1}\n' "$3" \
        >"$dir/agent-$2.meta.json"
}

# direct_spawn ROOT NAME AGENT_TYPE RETURN_TEXT — a spawn NOT under `workflows/`,
# i.e. a session calling the Agent tool itself. RETURN_TEXT becomes the last
# assistant text, which is what `ac5` scores.
direct_spawn() {
    local dir="$1/proj/sess/subagents"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"investigate"}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$4"
    } >"$dir/agent-$2.jsonl"
    command printf '{"agentType":"%s","spawnDepth":1}\n' "$3" \
        >"$dir/agent-$2.meta.json"
}

# session_result ROOT NAME RESULT_CHARS TRAILING_TURNS — a main-session
# transcript holding one tool_result of the given size, followed by N further
# records so the tool can measure residency.
session_result() {
    local dir="$1/proj" f="$1/proj/$2.jsonl" i pad
    command mkdir -p "$dir"
    pad="$(command head -c "$3" /dev/zero | command tr '\0' 'x')"
    command printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"%s"}]}}\n' \
        "$pad" >"$f"
    i=0
    while [ "$i" -lt "$4" ]; do
        command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"t"}]}}\n' >>"$f"
        i=$((i + 1))
    done
}

# run_adoption SUBCOMMAND ROOT — capture stdout+stderr into OUT, status into RC.
# Assigned to globals rather than run in a subshell so assertions land in the
# caller's shell where TEST_STATUS is real (same rationale as the sibling gates).
run_adoption() {
    set +e
    OUT="$(python3 "$ADOPTION_PY" "$1" --root "$2" 2>&1)"
    RC=$?
    set -e
}

# --- the main corpus: one harness spawn and one direct spawn ------------------
#
# Deliberately 1/1. A classifier that answered a constant — everything harness,
# or everything direct — would reproduce the real corpus's lopsided shape and
# pass a test built on it; against 1/1 it cannot.
MAIN="$WORKDIR/main"
harness_spawn "$MAIN" h1 dev-core:code-reviewer
direct_spawn "$MAIN" d1 general-purpose "Found it at plugins/workflow/scripts/config.sh:41 — the default is unset."

test_splits_harness_from_direct() {
    run_adoption adoption "$MAIN"
    assert_equals "0" "$RC" "adoption exits 0 on a well-formed corpus"
    assert_contains "$OUT" "spawns total           2" "counts every spawn"
    # The classification the whole verdict rests on. Both halves are pinned:
    # asserting only the direct count would pass with everything misfiled as
    # direct, and vice versa.
    assert_contains "$OUT" "harness (workflow.js) 1" "counts the harness spawn"
    assert_contains "$OUT" "direct  (Agent tool)  1" "counts the direct spawn"
    assert_contains "$OUT" "delegated investigations (direct spawns): 1" \
        "the headline figure is the direct count, not the total"
}

test_groups_by_agent_type_within_each_kind() {
    run_adoption adoption "$MAIN"
    # Grouping comes from the meta sidecar. Each type must show its own
    # harness/direct split, so a reader can see WHICH agents were delegated.
    assert_contains "$OUT" "dev-core:code-reviewer" "groups the harness agent type"
    assert_contains "$OUT" "general-purpose" "groups the direct agent type"
}

test_workflows_must_be_a_path_segment_not_a_substring() {
    # REGRESSION GUARD: keying on a substring would classify a direct spawn as
    # harness traffic whenever any ancestor directory merely contains the
    # letters "workflows" — a worktree named for the workflow plugin, say. That
    # failure manufactures precisely the zero this tool reports, so it must be
    # impossible rather than merely unlikely.
    local root="$WORKDIR/substring"
    command mkdir -p "$root/my-workflows-notes/sess/subagents"
    {
        command printf '{"type":"user","message":{"role":"user","content":"go"}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer at a/b.py:12"}]}}\n'
    } >"$root/my-workflows-notes/sess/subagents/agent-x.jsonl"
    command printf '{"agentType":"general-purpose"}\n' \
        >"$root/my-workflows-notes/sess/subagents/agent-x.meta.json"
    run_adoption adoption "$root"
    assert_equals "0" "$RC" "a workflows-substring directory still scans"
    assert_contains "$OUT" "direct  (Agent tool)  1" \
        "a 'workflows' substring in a dir name does not make a spawn harness traffic"
}

test_empty_corpus_exits_three_not_a_measured_zero() {
    # THE MOST IMPORTANT ASSERTION IN THIS FILE. An absent measurement and a
    # measured zero are different claims, and only the second is evidence about
    # the guidance. If this ever exits 0 with "0 delegations", the tally's
    # headline finding becomes unfalsifiable.
    local root="$WORKDIR/empty"
    command mkdir -p "$root"
    run_adoption adoption "$root"
    assert_equals "3" "$RC" "an empty corpus exits 3, never 0"
    assert_contains "$OUT" "ABSENT measurement, not a measured zero" \
        "and says so in words, so a reader cannot mistake it for a finding"
}

test_zero_delegations_is_stated_explicitly() {
    # A corpus with harness spawns but no direct ones is the real-world shape.
    # The tool must SAY "NONE" rather than printing a table that happens to
    # contain no direct rows — a silent absence is what gets misread.
    local root="$WORKDIR/harness-only"
    harness_spawn "$root" h1 dev-core:code-reviewer
    harness_spawn "$root" h2 dev-core:code-reviewer
    run_adoption adoption "$root"
    assert_equals "0" "$RC" "a harness-only corpus is a valid measurement"
    assert_contains "$OUT" "delegated investigations (direct spawns): 0" \
        "reports the zero"
    assert_contains "$OUT" "NONE" "states the negative explicitly"
}

# --- the break-even is a product, not a size ---------------------------------
#
# BIG is 40,000 chars (~10,000 tok) resident 1 turn   -> product ~10,000  (under)
# SMALL is 12,000 chars (~3,000 tok) resident 20 turns -> product ~63,000 (over)
#
# The small one clears and the big one does not, which is only true if the
# multiplier is applied. Asserting on size alone would pass with it dropped.
PROD="$WORKDIR/product"
session_result "$PROD" big 40000 0
session_result "$PROD" small 12000 20

test_break_even_multiplies_by_residency() {
    run_adoption opportunities "$PROD"
    assert_equals "0" "$RC" "opportunities exits 0"
    assert_contains "$OUT" "results >= 2,000 tok     2" "sizes both results"
    assert_contains "$OUT" "clearing break-even  1" \
        "only the long-resident result clears — the break-even is tok x turns"
}

test_small_results_are_below_the_floor() {
    # The floor keeps hundreds of status lines out of the denominator. Without
    # it the opportunity count is noise and the ratio beside it meaningless.
    local root="$WORKDIR/floor"
    session_result "$root" tiny 400 50
    run_adoption opportunities "$root"
    assert_equals "0" "$RC" "a sub-floor corpus still exits 0"
    assert_contains "$OUT" "no inline tool results" \
        "a result below the floor is not counted as an opportunity"
}

test_opportunities_does_not_require_any_spawn() {
    # The denominator must survive a corpus with ZERO subagent transcripts —
    # which is exactly the corpus this tool was written to characterize. An
    # exit 3 keyed on spawns here would suppress the evidence that makes the
    # zero a finding rather than a shrug.
    local root="$WORKDIR/nospawn"
    session_result "$root" only 12000 20
    assert_equals "0" \
        "$(command find "$root" -name '*.meta.json' 2>/dev/null | command wc -l | command tr -d ' ')" \
        "fixture genuinely has no spawns"
    run_adoption opportunities "$root"
    assert_equals "0" "$RC" "opportunities works with no spawns present"
    assert_contains "$OUT" "clearing break-even  1" "and still reports the denominator"
}

test_opportunities_ignores_subagent_transcripts() {
    # Reading done INSIDE a subagent is the volume a delegation keeps out of the
    # parent. Counting it as an inline opportunity would credit the guidance's
    # own successes to the column measuring its failures.
    local root="$WORKDIR/subonly"
    command mkdir -p "$root/proj/sess/subagents"
    local pad
    pad="$(command head -c 12000 /dev/zero | command tr '\0' 'x')"
    command printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"%s"}]}}\n' \
        "$pad" >"$root/proj/sess/subagents/agent-a.jsonl"
    run_adoption opportunities "$root"
    assert_equals "3" "$RC" "a subagent-only corpus has no main sessions"
}

# --- AC5: conclusion vs transcript -------------------------------------------

test_ac5_classifies_an_anchored_conclusion() {
    run_adoption ac5 "$MAIN"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose" "reports the direct spawn"
    assert_contains "$OUT" "yes" "a path:line citation counts as an anchor"
    assert_contains "$OUT" "n=1" "names the sample size beside the result"
}

test_ac5_classifies_an_unanchored_dump() {
    local root="$WORKDIR/dump"
    direct_spawn "$root" d1 general-purpose "I read many files and here is everything I saw with no citations"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0 on an unanchored return"
    assert_contains "$OUT" "general-purpose                          16       no" \
        "an unanchored return is not a conclusion"
}

test_ac5_rejects_a_source_url_as_an_anchor() {
    # REGRESSION (review cycle 1): a token shaped `head:digits` where the head
    # contains "/" or "." reads as a `path:line` citation — so a return value
    # that merely QUOTES A LINK scored as "cited its sources", manufacturing
    # evidence for the very behavior AC5 measures.
    #
    # The fixture is a URL whose path ends in a REAL source extension
    # (`.../src/app.py:42`). That is deliberate and is the only shape that
    # isolates the `://` guard: a plain `https://example.com:8080/x` is already
    # rejected by the extension check (its extension is `com`), so a test built
    # on one passes with the guard deleted and proves nothing — measured, this
    # test survived its own mutation until the fixture was changed to this.
    local root="$WORKDIR/urlport"
    direct_spawn "$root" d1 general-purpose "I found it at https://github.com/org/repo/blob/main/src/app.py:42 upstream"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    # Assert the ROW, not a bare "no": the trailing explanation contains the
    # letters "no" inside "unanchored"/"not", so a substring check passes with
    # the guard deleted — measured, this assertion survived its own mutation
    # until it was anchored to the column.
    assert_contains "$OUT" "general-purpose                          18       no" \
        "a URL is not a path:line anchor even when it ends in a source extension"
}

test_ac5_rejects_a_numeric_extension() {
    # Isolates the ALPHABETIC-extension requirement, and the fixture has to work
    # harder than it looks. The obvious `v2.0.31:8080` stopped discriminating the
    # moment cycle 2 added the path-separator guard — with no "/" it is rejected
    # one condition earlier, so the test passed with `isalpha()` reverted to
    # `isalnum()` and proved nothing (measured).
    #
    # `build/app.v2:8080` carries a path separator AND a numeric extension, so it
    # reaches the extension check and is rejected only by `isalpha()`.
    local root="$WORKDIR/numext"
    direct_spawn "$root" d1 general-purpose "The artifact is deployed at build/app.v2:8080 now"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          12       no" \
        "a numeric extension is not a source extension"
}

test_ac5_rejects_a_scheme_less_host_port() {
    # REGRESSION (review cycle 2 — a defect the cycle-1 FIX introduced). That fix
    # dropped the original `"/" in head` requirement, so `database.io:5432` and
    # `api.dev:8443` scored as citations: no scheme, so the `://` guard never
    # sees them, and a TLD is indistinguishable from a short file extension.
    # Bare host:port mentions are common in exactly the ops-flavored transcripts
    # this tool classifies, so this manufactured the same false "cited its
    # sources" verdict the cycle-1 fix was written to remove.
    local root="$WORKDIR/hostport"
    direct_spawn "$root" d1 general-purpose "The service listens on database.io:5432 in prod"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          11       no" \
        "a scheme-less host:port is not a path:line anchor"
}

test_ac5_keeps_scanning_past_a_rejected_token() {
    # The three guards `continue`; they must not `return False`/`break`. Every
    # other rejection fixture holds exactly ONE anchor-shaped token, so a
    # `continue` and an early `return False` produce identical output on them —
    # the tests would not tell the two implementations apart.
    #
    # This fixture is the input where they DIFFER: a rejected URL token FIRST,
    # then a genuine `path:line` anchor later in the same message. Only
    # continue-and-keep-scanning reaches the real citation.
    local root="$WORKDIR/mixed"
    direct_spawn "$root" d1 general-purpose "See https://example.com/docs, the fix is in src/app.py:42 upstream"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          16      yes" \
        "a rejected token does not abort the scan for a later real anchor"
}

test_ac5_accepts_a_trailing_colon_citation() {
    # REGRESSION (review cycle 3 — a FALSE NEGATIVE the cycle-2 hardening
    # introduced). `src/app.py:42:` is the pytest/mypy/compiler error format: the
    # citation is followed immediately by a colon and more prose. Splitting on
    # the LAST colon gave an empty tail, so the token was rejected before any
    # other check — the single most common real citation shape scored `no`.
    #
    # Both error directions corrupt the verdict. A false positive invents
    # evidence; a false negative under-reports the behavior the guidance exists
    # to produce.
    local root="$WORKDIR/trailcolon"
    direct_spawn "$root" d1 general-purpose "Found it in src/app.py:42: the assertion fails"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          11      yes" \
        "a trailing-colon citation is still an anchor"
}

test_ac5_accepts_a_line_col_citation() {
    # The sibling false negative: `pkg/mod.py:42:5` (ripgrep --vimgrep, many
    # linters). Splitting on the last colon put `:42` inside the extension, which
    # then failed the alphabetic test. Both shapes are why the checks became one
    # regex instead of a chain of string operations.
    local root="$WORKDIR/linecol"
    direct_spawn "$root" d1 general-purpose "Traced to pkg/mod.py:42:5 in the vimgrep output"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          11      yes" \
        "a file:line:col citation is still an anchor"
}

test_ac5_keeps_scanning_past_a_rejected_host_port() {
    # The separator sibling of test_ac5_keeps_scanning_past_a_rejected_token.
    # That one puts a URL first, so it only proves the `://` arm keeps scanning.
    # This one leads with a scheme-less host:port — rejected by the PATTERN
    # rather than the scheme guard — and follows it with a real citation, which
    # is the input where "keep scanning" and "give up on first rejection"
    # disagree for that arm.
    local root="$WORKDIR/hostthenok"
    direct_spawn "$root" d1 general-purpose "It calls database.io:5432 and the bug is in src/app.py:42"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0"
    assert_contains "$OUT" "general-purpose                          14      yes" \
        "a rejected host:port does not abort the scan for a later real anchor"
}

test_string_shaped_content_is_not_dropped() {
    # REGRESSION (review cycle 1): a message's `content` may be a bare STRING
    # rather than a block list. Returning [] for that shape silently dropped a
    # spawn's final answer and skipped string-shaped tool_results — shrinking
    # both what ac5 scores and the opportunity denominator, quietly.
    local root="$WORKDIR/strcontent" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"investigate"}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","content":"The answer is at plugins/workflow/scripts/config.sh:41"}}\n'
    } >"$dir/agent-s1.jsonl"
    command printf '{"agentType":"general-purpose"}\n' >"$dir/agent-s1.meta.json"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0 on string-shaped content"
    # Pin the ROW. A bare "yes" would be a weaker claim than it looks, and the
    # size column is what proves the string was actually READ rather than the
    # anchor merely defaulting true.
    assert_contains "$OUT" "general-purpose                          13      yes" \
        "a bare-string assistant turn is read, not silently dropped"
}

test_wrong_shaped_content_yields_no_blocks() {
    # _blocks' third branch: content present but neither list nor string (a dict,
    # a number). It must return [] rather than raise or mis-normalize — the
    # string-normalization added in cycle 1 must not have widened into "accept
    # anything". Distinct from the no-answer case below, which omits the record.
    local root="$WORKDIR/badshape" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"investigate"}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","content":42}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","content":{}}}\n'
    } >"$dir/agent-w1.jsonl"
    command printf '{"agentType":"general-purpose"}\n' >"$dir/agent-w1.meta.json"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "a wrong-shaped content does not crash the run"
    assert_contains "$OUT" "general-purpose                         n/a      n/a" \
        "neither a number nor an object is read as an answer"
}

test_ac5_reports_na_for_a_spawn_with_no_answer() {
    # A direct spawn that errored or was killed before answering has no
    # assistant text. That is a THIRD state — distinct from "returned a dump" —
    # and the row must say so rather than scoring an absent answer as 0 tokens.
    local root="$WORKDIR/noanswer" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    command printf '{"type":"user","message":{"role":"user","content":"investigate"}}\n' \
        >"$dir/agent-n1.jsonl"
    command printf '{"agentType":"general-purpose"}\n' >"$dir/agent-n1.meta.json"
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0 when a spawn never answered"
    # Both columns, not a bare "n/a": the row must show n/a for SIZE as well as
    # for anchors, or an absent answer could still be scored as 0 tokens.
    assert_contains "$OUT" "general-purpose                         n/a      n/a" \
        "an unanswered spawn reports n/a in both columns, not a score"
}

test_subagent_type_sidecar_key_is_honoured() {
    # _agent_type falls back to `subagent_type` when `agentType` is absent.
    # Every other fixture writes agentType, so without this the fallback is
    # dead code that could be deleted with the suite still green.
    local root="$WORKDIR/subtypekey" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"x"}]}}\n' \
        >"$dir/agent-k1.jsonl"
    command printf '{"subagent_type":"Explore"}\n' >"$dir/agent-k1.meta.json"
    run_adoption adoption "$root"
    assert_equals "0" "$RC" "adoption exits 0"
    assert_contains "$OUT" "Explore" "the subagent_type sidecar key is honoured"
}

test_ac5_says_untested_when_nothing_was_delegated() {
    # The third state. "Returned a dump" and "there was nothing to score" are
    # different findings, and collapsing them is the exact error the tally's
    # verdict is written to avoid.
    local root="$WORKDIR/ac5-empty"
    harness_spawn "$root" h1 dev-core:code-reviewer
    run_adoption ac5 "$root"
    assert_equals "0" "$RC" "ac5 exits 0 when only harness spawns exist"
    assert_contains "$OUT" "UNTESTED" "names the state rather than implying a failure"
}

# --- tolerance and CLI surface -----------------------------------------------

test_malformed_records_and_journal_are_tolerated() {
    local root="$WORKDIR/malformed" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    command printf 'not json at all\n{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok at a/b.py:1"}]}}\n' \
        >"$dir/agent-m.jsonl"
    command printf '{"agentType":"general-purpose"}\n' >"$dir/agent-m.meta.json"
    command printf '{"journal":true}\n' >"$dir/journal.jsonl"
    run_adoption adoption "$root"
    assert_equals "0" "$RC" "a malformed line does not abort the run"
    assert_contains "$OUT" "direct  (Agent tool)  1" \
        "journal.jsonl is excluded and the good spawn still counts"
}

test_non_object_sidecar_falls_back_instead_of_crashing() {
    # `[1,2,3]` is valid JSON that sails past the parse guard and then raises
    # AttributeError on .get() — aborting a whole run over one bad sidecar.
    local root="$WORKDIR/badmeta" dir
    dir="$root/proj/sess/subagents"
    command mkdir -p "$dir"
    command printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"x"}]}}\n' \
        >"$dir/agent-b.jsonl"
    command printf '[1,2,3]\n' >"$dir/agent-b.meta.json"
    run_adoption adoption "$root"
    assert_equals "0" "$RC" "a non-object sidecar does not crash the run"
    assert_contains "$OUT" "(unknown)" "it falls back to the advertised label"
}

test_absent_root_exits_three() {
    run_adoption adoption "$WORKDIR/definitely-not-here"
    assert_equals "3" "$RC" "an absent transcript root exits 3"
}

test_unknown_subcommand_exits_two() {
    set +e
    OUT="$(python3 "$ADOPTION_PY" bogus --root "$MAIN" 2>&1)"
    RC=$?
    set -e
    assert_equals "2" "$RC" "an unknown subcommand exits 2"
}

test_default_subcommand_is_adoption() {
    set +e
    OUT="$(python3 "$ADOPTION_PY" --root "$MAIN" 2>&1)"
    RC=$?
    set -e
    assert_equals "0" "$RC" "the bare invocation runs"
    assert_contains "$OUT" "spawns total" "and defaults to the adoption report"
}

# --- the shim ----------------------------------------------------------------

test_shim_reports_77_without_python() {
    # Forcing python3 absent needs BOTH an emptied PATH and BASH_ENV unset:
    # /etc/bash_env re-seeds PATH in every non-interactive bash here, so a
    # PATH-only override silently leaves python3 findable and the test proves
    # nothing (measured on the sibling gate — it passed while testing the
    # opposite of its name).
    local runner="$WORKDIR/no-python.sh" out rc
    {
        command printf '#!/usr/bin/env bash\n'
        # Resolve bash BEFORE emptying PATH: the fixture removes python3, not
        # the shell, and an unresolvable interpreter would fail as 127 for a
        # reason unrelated to the sentinel under test.
        command printf '_sh="$(command -v bash)"\n'
        command printf 'export PATH=%s/empty-bin\n' "$WORKDIR"
        command printf 'unset BASH_ENV\n'
        command printf 'exec "$_sh" "$1" adoption\n'
    } >"$runner"
    command mkdir -p "$WORKDIR/empty-bin"
    set +e
    out="$(command bash "$runner" "$ADOPTION_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "an absent python3 exits the 77 sentinel"
    assert_contains "$out" "python3 not found" "and names the real cause"
}

test_shim_reports_77_on_old_python() {
    # A PRESENT but too-old interpreter is a different branch from an absent
    # one, and the absent-python test cannot reach it.
    local stub_dir="$WORKDIR/oldpy" runner="$WORKDIR/old-python.sh" out rc
    command mkdir -p "$stub_dir"
    {
        command printf '#!/usr/bin/env sh\n'
        command printf 'exit 1\n'
    } >"$stub_dir/python3"
    command chmod +x "$stub_dir/python3"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'export PATH=%s:/usr/bin:/bin\n' "$stub_dir"
        command printf 'unset BASH_ENV\n'
        command printf 'exec bash "$1" adoption\n'
    } >"$runner"
    set +e
    out="$(command bash "$runner" "$ADOPTION_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "a too-old python3 exits the 77 sentinel"
    assert_contains "$out" "older than 3.11" "and names the version, not a guess"
}

test_shim_diagnoses_a_broken_path_correctly() {
    # The shim derives its own directory with BUILTINS. `dirname` is external, so
    # on a broken PATH it fails, $_here collapses to the CWD, and the shim blames
    # "the plugin install is incomplete" for what is really a PATH fault (#787's
    # measured regression). A wrong diagnosis is worse than none.
    local runner="$WORKDIR/broken-path.sh" out
    {
        command printf '#!/usr/bin/env bash\n'
        command printf '_sh="$(command -v bash)"\n'
        command printf 'export PATH=%s/empty-bin\n' "$WORKDIR"
        command printf 'unset BASH_ENV\n'
        command printf 'exec "$_sh" "$1" adoption\n'
    } >"$runner"
    command mkdir -p "$WORKDIR/empty-bin"
    set +e
    out="$(command bash "$runner" "$ADOPTION_SH" 2>&1)"
    set -e
    case "$out" in
        *"plugin install is incomplete"*)
            fail "misdiagnosed a PATH fault as a missing install: $out"
            ;;
        *) : ;;
    esac
}

run_test test_splits_harness_from_direct "Harness and direct spawns are told apart"
run_test test_groups_by_agent_type_within_each_kind "Spawns group by agent type within each kind"
run_test test_workflows_must_be_a_path_segment_not_a_substring "A 'workflows' substring does not reclassify a spawn"
run_test test_empty_corpus_exits_three_not_a_measured_zero "An empty corpus exits 3, not a measured zero"
run_test test_zero_delegations_is_stated_explicitly "Zero delegations is stated explicitly"
run_test test_break_even_multiplies_by_residency "The break-even multiplies size by residency"
run_test test_small_results_are_below_the_floor "Sub-floor results are not opportunities"
run_test test_opportunities_does_not_require_any_spawn "Opportunities works with no spawns present"
run_test test_opportunities_ignores_subagent_transcripts "Opportunities ignores subagent transcripts"
run_test test_ac5_classifies_an_anchored_conclusion "AC5 classifies an anchored conclusion"
run_test test_ac5_classifies_an_unanchored_dump "AC5 classifies an unanchored dump"
run_test test_ac5_rejects_a_source_url_as_an_anchor "AC5 rejects a source URL as an anchor"
run_test test_ac5_rejects_a_numeric_extension "AC5 rejects a numeric extension"
run_test test_ac5_rejects_a_scheme_less_host_port "AC5 rejects a scheme-less host:port"
run_test test_ac5_keeps_scanning_past_a_rejected_token "AC5 keeps scanning past a rejected token"
run_test test_ac5_accepts_a_trailing_colon_citation "AC5 accepts a trailing-colon citation"
run_test test_ac5_accepts_a_line_col_citation "AC5 accepts a file:line:col citation"
run_test test_ac5_keeps_scanning_past_a_rejected_host_port "AC5 keeps scanning past a rejected host:port"
run_test test_string_shaped_content_is_not_dropped "String-shaped message content is not dropped"
run_test test_wrong_shaped_content_yields_no_blocks "Wrong-shaped message content yields no blocks"
run_test test_ac5_reports_na_for_a_spawn_with_no_answer "AC5 reports n/a for a spawn that never answered"
run_test test_subagent_type_sidecar_key_is_honoured "The subagent_type sidecar key is honoured"
run_test test_ac5_says_untested_when_nothing_was_delegated "AC5 says UNTESTED when nothing was delegated"
run_test test_malformed_records_and_journal_are_tolerated "Malformed records and journal.jsonl are tolerated"
run_test test_non_object_sidecar_falls_back_instead_of_crashing "A non-object meta sidecar falls back, not crashes"
run_test test_absent_root_exits_three "An absent transcript root exits 3"
run_test test_unknown_subcommand_exits_two "An unknown subcommand exits 2"
run_test test_default_subcommand_is_adoption "The default subcommand is adoption"
run_test test_shim_reports_77_without_python "The shim exits 77 when python3 is absent"
run_test test_shim_reports_77_on_old_python "The shim exits 77 when python3 is too old"
run_test test_shim_diagnoses_a_broken_path_correctly "The shim diagnoses a broken PATH correctly"

generate_report
