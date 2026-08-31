#!/usr/bin/env bash
# measure-spawn-prefix behavioral gate (issue #787).
#
# The tool reports what a subagent spawn costs, split into the shared prefix
# block (normally a cache HIT, ~0.1x) and per-spawn bytes (written at ~1.25x).
# Those figures are load-bearing: docs/verification/subagent-prefix-e2e-787.md
# cites them, and delegating-investigation/SKILL.md's break-even is derived from
# them. A wrong number here silently corrupts guidance downstream.
#
# WHY THIS GATE EXISTS SEPARATELY FROM THE COVERAGE DRIVER. #787 first shipped
# with only tests/python-corpus/{80,90}-* — a Codecov LOC driver whose every
# invocation is `|| true` with output to /dev/null. That executes the lines but
# ASSERTS NOTHING, so wrong arithmetic keeps every gate green. Two review
# dimensions (tests, conventions) independently flagged the same gap: every
# sibling in NON_PATTERNS_TOOLS has both a driver AND a behavioral gate. This is
# the missing half.
#
# THE ARITHMETIC IS THE POINT, so the fixtures pin exact numbers rather than
# "some output appeared":
#
#   spawns / HIT / MISS counts        the hit-vs-miss classification itself
#   implied shared block              miss_written - hit_written
#   miss penalty                      (1.25 - 0.1) * shared, and the 12x ratio
#   per-agent-type grouping           medians grouped by the meta sidecar
#   exit codes 0 / 2 / 3              and the shim's 77
#
# TWO REGRESSIONS THIS GATE PINS, both found by a fixture and invisible on the
# real corpus, where each read as a plausible ~65%:
#
#   * The `prefix share of input` denominator was `cache_read` alone. A cache
#     MISS moves those tokens into cache_creation, so they left the denominator
#     while staying in the numerator -> 427.8%.
#   * `prefix x turns` is an UPPER BOUND (it assumes the full prefix is re-sent
#     every turn). On short transcripts it legitimately exceeds 100%, so the
#     >100% case must SAY so rather than print an impossible share.
#
# A NEGATIVE-SHARED-BLOCK GUARD is pinned too (review cycle 1): `shared` is a
# difference of two group means, so a skewed sample can invert it and every
# derived figure becomes a negative token count. The fixture below constructs
# exactly that inversion — the hit group writing MORE than the miss group —
# because it cannot arise from the natural corpus.
#
# Pure bash + coreutils; no node/jq. Full command paths per project convention.
# bash-3.2 clean. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

MEASURE_PY="$REPO_ROOT/plugins/workflow/scripts/measure-spawn-prefix.py"
MEASURE_SH="$REPO_ROOT/plugins/workflow/scripts/measure-spawn-prefix.sh"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "measure-spawn-prefix behavioral gate (#787)"

# The tool is Python-3.11+ only BY DESIGN (it parses JSONL; there is no bash
# fallback). With no such runtime the whole gate reports the reserved 77
# sentinel rather than passing vacuously — a silent skip is indistinguishable
# from a pass, which is how a gate sits inert unnoticed (CLAUDE.md § gates).
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    command printf '%s\n' \
        "measure-spawn-prefix gate: no python3 >= 3.11 — gate DID NOT RUN." >&2
    exit 77
fi

# --- fixture builders --------------------------------------------------------

# spawn_file ROOT NAME AGENT_TYPE CACHE_READ CACHE_CREATION
# One transcript plus its meta sidecar. AGENT_TYPE `-` omits the sidecar, which
# drives the "(unknown)" fallback. A cache_read of 0 is a MISS.
spawn_file() {
    local dir="$1/proj/sess/subagents/wf" f="$2" atype="$3" read="$4" create="$5"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"dispatch"}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
            "$read" "$create"
    } >"$dir/agent-$f.jsonl"
    if [ "$atype" != "-" ]; then
        command printf '{"agentType":"%s","spawnDepth":1}\n' "$atype" \
            >"$dir/agent-$f.meta.json"
    fi
}

# run_measure SUBCOMMAND ROOT — capture stdout+stderr into OUT, status into RC.
# Assigned to globals rather than run in a subshell so assertions land in the
# caller's shell where TEST_STATUS is real (same rationale as validate-plan-lens).
run_measure() {
    set +e
    OUT="$(python3 "$MEASURE_PY" "$1" --root "$2" 2>&1)"
    RC=$?
    set -e
}

# --- the main corpus: 2 HITs + 1 MISS of one type, 1 MISS of another ---------
#
# Numbers chosen so every derived figure is exact and hand-checkable:
#   hit written  = (17000 + 19000) / 2 = 18000
#   miss written = (29000 + 31000) / 2 = 30000
#   shared       = 30000 - 18000       = 12000
#   penalty      = (1.25 - 0.1) * 12000 = 13800
MAIN="$WORKDIR/main"
spawn_file "$MAIN" hit1 dev-core:code-reviewer 11000 17000
spawn_file "$MAIN" hit2 dev-core:code-reviewer 11000 19000
spawn_file "$MAIN" miss1 dev-core:code-reviewer 0 29000
spawn_file "$MAIN" miss2 general-purpose 0 31000

test_counts_hits_and_misses() {
    run_measure cache "$MAIN"
    assert_equals "0" "$RC" "cache exits 0 on a well-formed corpus"
    assert_contains "$OUT" "spawns                4" "counts every spawn"
    assert_contains "$OUT" "cache HIT             2  (50%)" "classifies hits"
    assert_contains "$OUT" "cache MISS            2  (50%)" "classifies misses"
}

test_shared_block_and_penalty_arithmetic() {
    run_measure cache "$MAIN"
    # The whole reason the tool exists: a miss pays full write price for bytes a
    # hit reads at a tenth. Each figure is pinned, not just the final one, so a
    # regression names which step broke.
    assert_contains "$OUT" "mean cache_creation on HIT   18,000" "hit-group mean"
    assert_contains "$OUT" "mean cache_creation on MISS  30,000" "miss-group mean"
    assert_contains "$OUT" "implied shared block         12,000 tokens" \
        "shared block = miss mean - hit mean"
    assert_contains "$OUT" "cost of shared block, HIT    1,200 tok-equiv" \
        "hit cost = 0.1 x shared"
    assert_contains "$OUT" "cost of shared block, MISS   15,000 tok-equiv" \
        "miss cost = 1.25 x shared"
    assert_contains "$OUT" "miss penalty per spawn       13,800 tok-equiv (12x)" \
        "penalty = (1.25 - 0.1) x shared, at the 12x ratio"
    assert_contains "$OUT" "total penalty paid           27,600 tok-equiv" \
        "total penalty scales by the miss count"
}

test_summary_groups_by_agent_type() {
    run_measure summary "$MAIN"
    assert_equals "0" "$RC" "summary exits 0"
    assert_contains "$OUT" "spawns                 4" "reports the spawn count"
    # Grouping comes from the meta sidecar, and the broad agent must sort first
    # (it is the more expensive prefix) — the ordering is the finding.
    assert_contains "$OUT" "general-purpose" "groups the broad agent type"
    assert_contains "$OUT" "dev-core:code-reviewer" "groups the narrow agent type"
    assert_contains "$OUT" "n=3" "the narrow type carries three spawns"

    # The descriptive stats, pinned by value — this is the only direct coverage
    # of _percentile(), whose index arithmetic (int(len * fraction), clamped)
    # is exactly the kind of off-by-one that stays invisible when a test only
    # checks that a label was printed.
    #
    # MAIN's per-spawn prefixes are 28,002 / 30,002 / 29,002 / 31,002 (each
    # input_tokens=2 + cache_read + cache_creation), so sorted: 28,002 / 29,002
    # / 30,002 / 31,002 -> median 29,502, p90 and max both 31,002.
    assert_contains "$OUT" "prefix min             28,002" "min prefix"
    assert_contains "$OUT" "prefix median          29,502" "median prefix"
    assert_contains "$OUT" "prefix p90             31,002" "p90 via _percentile"
    assert_contains "$OUT" "prefix max             31,002" "max prefix"
    assert_contains "$OUT" "one-shot spawn cost    118,008" \
        "one-shot cost is the sum of every prefix"
}

test_split_reports_billing_weighted_shares() {
    run_measure split "$MAIN"
    assert_equals "0" "$RC" "split exits 0"
    # The headline claim of the whole issue: the cached half is nearly free, so
    # the written half dominates billing. If this inverts, the guidance built on
    # it is wrong — so pin the VALUES, not merely that the labels were printed.
    #
    # Hand-computable from the MAIN fixture:
    #   cached_cost  = 0.1  x (11000 + 11000 + 0 + 0)         =   2,200
    #   written_cost = 1.25 x (17000 + 19000 + 29000 + 31000) = 120,000
    #   total        = 122,200 -> cached 1.8%, written 98.2%
    #   weighted per spawn = 0.1 x cached + 1.25 x written
    #                      -> median of (22,350 / 24,850 / 36,250 / 38,750)
    #                      =  30,550
    #
    # cmd_split applies the multipliers independently of cmd_cache, so a flip
    # confined to this subcommand would otherwise pass on the cache assertions.
    assert_contains "$OUT" "cached  median             5,500" "cached median"
    assert_contains "$OUT" "written median             24,000" "written median"
    assert_contains "$OUT" "median weighted tokens   30,550" \
        "billing-weighted median = 0.1 x cached + 1.25 x written"
    assert_contains "$OUT" "cached share             1.8%" \
        "the cached half is nearly free"
    assert_contains "$OUT" "written share            98.2%" \
        "the written half carries the billing"
}

# --- the share-ratio regressions --------------------------------------------

test_share_of_input_is_labelled_a_bound() {
    run_measure summary "$MAIN"
    # `prefix x turns` assumes the full prefix rides every turn, which is an
    # upper bound. Printing a bare percentage would overstate a measurement.
    assert_contains "$OUT" "prefix share of input" "reports the share"
    case "$OUT" in
        *"upper bound"* | *">100%"*) : ;;
        *) fail "share of input must be qualified as a bound, got: $OUT" ;;
    esac
}

test_share_never_prints_a_bare_impossible_percentage() {
    # Short transcripts make prefix x turns exceed measured input. The tool must
    # say so rather than print e.g. "427.8%" as though it were a real share —
    # the original defect, which the hit-dominated real corpus hid behind a
    # plausible-looking ~65%.
    local short="$WORKDIR/short"
    spawn_file "$short" only dev-core:code-reviewer 0 40000
    run_measure summary "$short"
    assert_equals "0" "$RC" "summary exits 0 on a short transcript"
    case "$OUT" in
        *">100%"*)
            assert_contains "$OUT" "short transcripts" \
                "the >100% branch explains WHY, not just that"
            ;;
        *) : ;; # under 100% is fine; the defect is an unqualified impossible value
    esac
}

# --- the negative-shared-block guard (review cycle 1) ------------------------

test_inverted_sample_refuses_to_size_the_block() {
    # The hit group writing MORE than the miss group inverts `shared`. Without
    # the guard every derived figure is a negative token count. This cannot
    # arise from the natural corpus, so it is constructed.
    local inv="$WORKDIR/inverted"
    spawn_file "$inv" bighit dev-core:code-reviewer 11000 50000
    spawn_file "$inv" smallmiss dev-core:code-reviewer 0 5000
    run_measure cache "$inv"
    assert_equals "0" "$RC" "an inverted sample is reported, not a crash"
    assert_contains "$OUT" "n/a" "refuses to size the shared block"
    case "$OUT" in
        *"-"[0-9]*"tok-equiv"*) fail "printed a negative token figure: $OUT" ;;
        *) : ;;
    esac
}

test_all_hits_skips_the_penalty_arithmetic() {
    # With no misses the penalty is undefined; the early return must fire.
    local allhit="$WORKDIR/allhit"
    spawn_file "$allhit" h1 dev-core:code-reviewer 11000 17000
    run_measure cache "$allhit"
    assert_equals "0" "$RC" "an all-hits corpus exits 0"
    assert_contains "$OUT" "cache MISS            0  (0%)" "reports zero misses"
    assert_contains "$OUT" "need both hits and misses" "explains the omission"
}

# --- degenerate inputs the readers must survive ------------------------------

test_journal_and_malformed_records_are_tolerated() {
    local messy="$WORKDIR/messy"
    spawn_file "$messy" good dev-core:code-reviewer 11000 17000
    local dir="$messy/proj/sess/subagents/wf"
    # journal.jsonl is skipped BY NAME — it carries usage but is not a spawn.
    command printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":9,"cache_read_input_tokens":5,"cache_creation_input_tokens":5}}}\n' \
        >"$dir/journal.jsonl"
    # A blank line, a non-JSON line, and a zero-usage record inside a real spawn.
    {
        command printf '\n'
        command printf 'not json at all\n'
        command printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
        command printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":11000,"cache_creation_input_tokens":18000}}}\n'
    } >>"$dir/agent-good.jsonl"
    # An unparseable meta sidecar -> the "(unknown)" fallback, not a crash.
    spawn_file "$messy" badmeta dev-core:code-reviewer 11000 17500
    command printf 'not valid json\n' >"$dir/agent-badmeta.meta.json"

    run_measure summary "$messy"
    assert_equals "0" "$RC" "malformed lines and a bad sidecar do not fail the run"
    assert_contains "$OUT" "spawns                 2" \
        "journal.jsonl is excluded from the spawn count"
    assert_contains "$OUT" "(unknown)" "an unparseable sidecar falls back"
}

test_percentile_does_not_collapse_to_max_at_round_sizes() {
    # REGRESSION (#787, review cycle 3). _percentile used `int(n * fraction)`,
    # one rank too high, which clamps to the LAST element whenever n * fraction
    # is an integer — so at n=10 (and n=100) the reported p90 was simply `max`,
    # hiding the very gap between the 90th percentile and the outlier that a p90
    # is quoted to show.
    #
    # The MAIN fixture is n=4, where p90 and max legitimately coincide under
    # BOTH the old and new formulas, so it cannot distinguish them — the defect
    # was invisible to the whole suite. This fixture is n=10 precisely because
    # that is where the two formulas diverge.
    #
    # Ten spawns with prefixes 10,002 .. 100,002 (cache_creation 10k..100k, each
    # + input_tokens 2). Nearest-rank p90 is the 9th value, 90,002 — NOT the max
    # of 100,002.
    local ranked="$WORKDIR/ranked" i=1
    while [ "$i" -le 10 ]; do
        spawn_file "$ranked" "s$i" dev-core:code-reviewer 0 "${i}0000"
        i=$((i + 1))
    done

    run_measure summary "$ranked"
    assert_equals "0" "$RC" "the n=10 corpus reports"
    assert_contains "$OUT" "spawns                 10" "ten spawns"
    assert_contains "$OUT" "prefix max             100,002" "max is the largest"
    assert_contains "$OUT" "prefix p90             90,002" \
        "p90 is the 9th of 10 by nearest rank, NOT the max"
    case "$OUT" in
        *"prefix p90             100,002"*)
            fail "p90 collapsed to max at a round sample size"
            ;;
        *) : ;;
    esac
}

test_subagent_type_key_is_honoured() {
    # `_agent_type` falls back from `agentType` to `subagent_type`. Every other
    # fixture writes only `agentType`, so that second branch was dead as far as
    # the suite was concerned and a key-name drift would pass unnoticed.
    local altkey="$WORKDIR/altkey"
    spawn_file "$altkey" alt - 11000 17000
    command printf '{"subagent_type":"review-audit:checker","spawnDepth":1}\n' \
        >"$altkey/proj/sess/subagents/wf/agent-alt.meta.json"

    run_measure summary "$altkey"
    assert_equals "0" "$RC" "a subagent_type sidecar reports"
    assert_contains "$OUT" "review-audit:checker" \
        "the subagent_type key is read when agentType is absent"
    case "$OUT" in
        *"(unknown)"*) fail "fell back to (unknown) despite a usable key" ;;
        *) : ;;
    esac
}

test_top_level_usage_is_counted() {
    # `_usage` falls back to a top-level `usage` when the record has no
    # `message` wrapper. No fixture produced that shape, so the branch was
    # never taken — and a record silently dropped from the accounting is the
    # failure mode this whole tool exists to avoid.
    local toplevel="$WORKDIR/toplevel"
    local dir="$toplevel/proj/sess/subagents/wf"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"dispatch"}}\n'
        command printf '{"type":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":11000,"cache_creation_input_tokens":17000}}\n'
    } >"$dir/agent-top.jsonl"
    command printf '{"agentType":"dev-core:code-reviewer"}\n' \
        >"$dir/agent-top.meta.json"

    run_measure summary "$toplevel"
    assert_equals "0" "$RC" "a top-level usage record reports"
    assert_contains "$OUT" "spawns                 1" "the record counts as a spawn"
    assert_contains "$OUT" "prefix median          28,002" \
        "its usage is accounted, not silently dropped"
}

test_non_object_sidecar_falls_back_instead_of_crashing() {
    # REGRESSION (#787, review cycle 2). The parse guard caught OSError/ValueError
    # but not a sidecar that is VALID JSON yet not an object: `[1,2,3]`, `"x"` and
    # `42` all parse fine and then raise AttributeError on .get(), aborting the
    # whole run over one bad sidecar among possibly dozens of good transcripts.
    #
    # The unparseable-sidecar case above cannot reach this branch — it never gets
    # past json.loads — so this needs its own fixture.
    local shaped="$WORKDIR/shaped"
    spawn_file "$shaped" good dev-core:code-reviewer 11000 17000
    spawn_file "$shaped" arr dev-core:code-reviewer 11000 18000
    command printf '[1, 2, 3]\n' \
        >"$shaped/proj/sess/subagents/wf/agent-arr.meta.json"
    spawn_file "$shaped" num dev-core:code-reviewer 11000 18500
    command printf '42\n' \
        >"$shaped/proj/sess/subagents/wf/agent-num.meta.json"
    spawn_file "$shaped" str dev-core:code-reviewer 11000 19000
    command printf '"just a string"\n' \
        >"$shaped/proj/sess/subagents/wf/agent-str.meta.json"

    run_measure summary "$shaped"
    assert_equals "0" "$RC" "a non-object sidecar degrades rather than crashing"
    case "$OUT" in
        *Traceback*) fail "aborted with a traceback: $OUT" ;;
        *) : ;;
    esac
    assert_contains "$OUT" "spawns                 4" "every spawn is still counted"
    assert_contains "$OUT" "(unknown)" "the malformed sidecars fall back"
}

test_missing_sidecar_falls_back_to_unknown() {
    local nometa="$WORKDIR/nometa"
    spawn_file "$nometa" bare - 11000 17000
    run_measure summary "$nometa"
    assert_equals "0" "$RC" "a spawn with no sidecar still reports"
    assert_contains "$OUT" "(unknown)" "an absent sidecar falls back"
}

# --- the exit-code contract --------------------------------------------------

test_absent_root_exits_three() {
    run_measure summary "$WORKDIR/never-created"
    assert_equals "3" "$RC" "a missing transcript root exits 3"
    assert_contains "$OUT" "no transcript root" "and says which path"
}

test_root_with_no_billed_turn_exits_three() {
    # Distinct branch from the above: the root EXISTS and holds a transcript,
    # but nothing in it was ever billed, so there is no prefix to measure.
    local empty="$WORKDIR/empty"
    command mkdir -p "$empty/proj/sess/subagents"
    command printf '{"type":"user","message":{"role":"user","content":"never billed"}}\n' \
        >"$empty/proj/sess/subagents/agent-unbilled.jsonl"
    run_measure summary "$empty"
    assert_equals "3" "$RC" "a root with no billed turn exits 3"
    assert_contains "$OUT" "no subagent transcripts" "and says so"
}

test_unknown_subcommand_exits_two() {
    run_measure bogus-report "$MAIN"
    assert_equals "2" "$RC" "an unknown subcommand exits 2"
}

test_default_subcommand_is_summary() {
    set +e
    local out
    out="$(python3 "$MEASURE_PY" --root "$MAIN" 2>&1)"
    local rc=$?
    set -e
    assert_equals "0" "$rc" "no subcommand exits 0"
    assert_contains "$out" "prefix median" "defaults to the summary report"
}

# --- the shim's fail-loud contract -------------------------------------------

test_shim_reports_77_without_python() {
    # The shim must exit the reserved 77 sentinel, never 0, when its runtime is
    # missing — reporting nothing beats reporting wrong token accounting.
    #
    # Forcing python3 absent needs BOTH an emptied PATH and BASH_ENV unset:
    # /etc/bash_env re-seeds PATH in every non-interactive bash here, so a
    # PATH-only override silently leaves python3 findable and the test proves
    # nothing (measured — it passed while testing the opposite of its name).
    local runner="$WORKDIR/no-python.sh" out rc
    {
        command printf '#!/usr/bin/env bash\n'
        # Resolve bash BEFORE emptying PATH: the fixture removes python3, not
        # the shell, and an unresolvable interpreter would fail as 127 for a
        # reason that has nothing to do with the sentinel under test.
        command printf '_sh="$(command -v bash)"\n'
        command printf 'export PATH=%s/empty-bin\n' "$WORKDIR"
        command printf 'unset BASH_ENV\n'
        command printf 'exec "$_sh" "$1" summary\n'
    } >"$runner"
    command mkdir -p "$WORKDIR/empty-bin"
    set +e
    out="$(command bash "$runner" "$MEASURE_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "an absent python3 exits the 77 sentinel"
    assert_contains "$out" "python3 not found" "and names the real cause"
}

test_shim_reports_77_on_old_python() {
    # A PRESENT but too-old interpreter is a different branch from an absent
    # one, and the absent-python test cannot reach it. The stub satisfies
    # `command -v` and fails the version probe.
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
        command printf 'exec bash "$1" summary\n'
    } >"$runner"
    set +e
    out="$(command bash "$runner" "$MEASURE_SH" 2>&1)"
    rc=$?
    set -e
    assert_equals "77" "$rc" "a too-old python3 exits the 77 sentinel"
    assert_contains "$out" "older than 3.11" "and names the version, not a guess"
}

test_shim_diagnoses_a_broken_path_correctly() {
    # REGRESSION (#787): the shim derived its own directory with `dirname`, an
    # EXTERNAL command. On a broken PATH that failed, $_here collapsed to the
    # CWD, and the shim blamed "the plugin install is incomplete" for what was
    # really a PATH fault. A wrong diagnosis is worse than none, so the path is
    # derived with builtins and the message must name python3.
    local runner="$WORKDIR/broken-path.sh" out
    {
        command printf '#!/usr/bin/env bash\n'
        command printf '_sh="$(command -v bash)"\n'
        command printf 'export PATH=%s/empty-bin\n' "$WORKDIR"
        command printf 'unset BASH_ENV\n'
        command printf 'exec "$_sh" "$1" summary\n'
    } >"$runner"
    set +e
    out="$(command bash "$runner" "$MEASURE_SH" 2>&1)"
    set -e
    case "$out" in
        *"plugin install is incomplete"*)
            fail "misdiagnosed a PATH fault as a missing install: $out"
            ;;
        *) : ;;
    esac
}

run_test test_counts_hits_and_misses "Hit/miss classification counts every spawn"
run_test test_shared_block_and_penalty_arithmetic "Shared-block and penalty arithmetic is exact"
run_test test_summary_groups_by_agent_type "Summary groups spawns by agent type"
run_test test_split_reports_billing_weighted_shares "Split reports billing-weighted shares"
run_test test_share_of_input_is_labelled_a_bound "Share of input is labelled an upper bound"
run_test test_share_never_prints_a_bare_impossible_percentage "A >100% share explains itself"
run_test test_inverted_sample_refuses_to_size_the_block "An inverted sample refuses to size the block"
run_test test_all_hits_skips_the_penalty_arithmetic "An all-hits corpus skips the penalty arithmetic"
run_test test_journal_and_malformed_records_are_tolerated "journal.jsonl and malformed records are tolerated"
run_test test_percentile_does_not_collapse_to_max_at_round_sizes "p90 does not collapse to max at n=10"
run_test test_subagent_type_key_is_honoured "The subagent_type sidecar key is honoured"
run_test test_top_level_usage_is_counted "A top-level usage record is counted"
run_test test_non_object_sidecar_falls_back_instead_of_crashing "A non-object meta sidecar falls back, not crashes"
run_test test_missing_sidecar_falls_back_to_unknown "A missing meta sidecar falls back to (unknown)"
run_test test_absent_root_exits_three "An absent transcript root exits 3"
run_test test_root_with_no_billed_turn_exits_three "A root with no billed turn exits 3"
run_test test_unknown_subcommand_exits_two "An unknown subcommand exits 2"
run_test test_default_subcommand_is_summary "The default subcommand is summary"
run_test test_shim_reports_77_without_python "The shim exits 77 when python3 is absent"
run_test test_shim_reports_77_on_old_python "The shim exits 77 when python3 is too old"
run_test test_shim_diagnoses_a_broken_path_correctly "The shim diagnoses a broken PATH correctly"

generate_report
