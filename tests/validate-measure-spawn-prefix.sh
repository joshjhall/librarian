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

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while git and realpath-based code resolve the
# same dir to /private/var/... Any prefix match between the two spellings
# fails, silently dropping rows or refusing valid paths (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
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

# --- `timing`: barrier reconstruction and miss attribution (#870) ------------
#
# #870 asked which of two hypotheses explains a 38% cache-miss rate: a 5-minute
# TTL expiring between review cycles, or barrier scheduling racing to populate
# the cache. They make DIFFERENT predictions, so the report must be able to tell
# them apart — which means the two axes it separates (rank within a barrier, and
# the gap before the barrier) each need a fixture that isolates one of them.
#
# The clustering is inferred, not read from a field: there is no barrier id in a
# transcript. So these fixtures pin the inference itself — that a gap past the
# threshold starts a new barrier, that a session change does too regardless of
# timing, and that a spawn which cannot be ordered is DROPPED rather than
# guessed into a barrier (a guess would fabricate the very signal being measured).

# timed_spawn ROOT SESSION NAME CACHE_READ CACHE_CREATION TIMESTAMP
# A transcript carrying the sessionId + timestamp that barrier clustering reads.
# Distinct from spawn_file above, which deliberately omits both (its callers pin
# the subcommands that ignore ordering, and that corpus must keep proving those
# still work without the fields).
timed_spawn() {
    local dir="$1/proj/$2/subagents/wf" sess="$2" f="$3" read="$4" create="$5" ts="$6"
    command mkdir -p "$dir"
    {
        command printf '{"type":"user","message":{"role":"user","content":"dispatch"}}\n'
        command printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
            "$sess" "$ts" "$read" "$create"
    } >"$dir/agent-$f.jsonl"
    command printf '{"agentType":"dev-core:code-reviewer","spawnDepth":1}\n' \
        >"$dir/agent-$f.meta.json"
}

# Two barriers in session A, 6 minutes apart (so the second leader is past the
# TTL), plus one barrier in session B that OVERLAPS barrier 1 in wall-clock time.
# The overlap is the point: if clustering keyed on time alone, B's spawn would be
# absorbed into A's barrier and the barrier count would be 2 instead of 3.
TIMED="$WORKDIR/timed"
timed_spawn "$TIMED" sessA b1lead 0 30000 "2026-09-01T10:00:00.000Z"
timed_spawn "$TIMED" sessA b1f1 11000 18000 "2026-09-01T10:00:04.000Z"
timed_spawn "$TIMED" sessA b1f2 11000 18000 "2026-09-01T10:00:08.000Z"
timed_spawn "$TIMED" sessA b2lead 0 30000 "2026-09-01T10:06:00.000Z"
timed_spawn "$TIMED" sessA b2f1 11000 18000 "2026-09-01T10:06:05.000Z"
timed_spawn "$TIMED" sessB b3lead 0 30000 "2026-09-01T10:00:02.000Z"

test_barriers_split_on_gap_and_session() {
    run_measure timing "$TIMED"
    assert_equals "0" "$RC" "timing exits 0 on a well-formed corpus"
    assert_contains "$OUT" "spawns placed in barriers   6 of 6" "places every ordered spawn"
    # 3 = A's two (split by the 6-minute gap) + B's one (split by session
    # despite overlapping A's first in wall-clock time).
    assert_contains "$OUT" "barriers                    3" "splits on gap AND on session"
}

test_leader_carries_the_misses() {
    run_measure timing "$TIMED"
    # Every leader misses and every follower hits, so the two rows are the
    # extremes: this pins that rank is computed per barrier rather than over the
    # whole corpus (which would put all six spawns at distinct ranks).
    assert_contains "$OUT" "0                            3/3" "all three leaders are rank 0"
    assert_contains "$OUT" "1                            0/2" "both rank-1 followers hit"
}

test_attribution_separates_ttl_from_barrier() {
    run_measure timing "$TIMED"
    # Barrier 2's leader sits 6 min after barrier 1 ENDED -> past the 300s TTL.
    # Barriers 1 and 3 are each their session's first -> cold start. So the
    # in-TTL category must be EMPTY here; a fixture where every leader landed in
    # one bucket could not show the categories are actually distinguished.
    assert_contains "$OUT" "leader, gap >= TTL               1" "the 6-min-gap leader is a TTL miss"
    assert_contains "$OUT" "leader, session cold start       2" "both first-in-session leaders are cold"
    assert_not_contains "$OUT" "leader, gap < TTL" "no in-TTL leader in this corpus"
}

test_cold_start_is_its_own_category() {
    run_measure timing "$TIMED"
    # A session's first barrier has no prior entry to reuse, so it is not
    # evidence about the TTL. Folding it into the largest gap bucket would
    # inflate that bucket's rate with misses the TTL cannot explain.
    #
    # Assert the COUNTS, not just the label: a row that merely exists still
    # passes when cold starts have been folded in elsewhere. Both leaders here
    # are cold, and exactly one leader is past the TTL — so a fold-in shows up
    # as 3 in the TTL row.
    assert_contains "$OUT" "cold (session's first)       2/2" "cold starts are counted separately"
    assert_contains "$OUT" "leader, gap >= TTL               1" "the TTL row does not absorb them"
}

# Barrier membership needs BOTH a session and a timestamp, so each missing field
# gets its own unplaceable spawn: one with neither (spawn_file's shape), and one
# carrying a timestamp but no sessionId. The second is the load-bearing case —
# it is orderable in time, so a clustering that checked only the timestamp would
# happily absorb it into a barrier it has no demonstrated membership in.
UNORDERED="$WORKDIR/unordered"
timed_spawn "$UNORDERED" sessA ok 0 30000 "2026-09-01T10:00:00.000Z"
spawn_file "$UNORDERED" nots dev-core:code-reviewer 11000 18000
# Hand-built rather than via timed_spawn: the point is the ABSENT sessionId.
command mkdir -p "$UNORDERED/proj/nosess/subagents/wf"
{
    command printf '{"type":"user","message":{"role":"user","content":"dispatch"}}\n'
    command printf '{"type":"assistant","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":11000,"cache_creation_input_tokens":18000}}}\n'
} >"$UNORDERED/proj/nosess/subagents/wf/agent-nosess.jsonl"

test_timing_ignores_unorderable_spawns() {
    run_measure timing "$UNORDERED"
    assert_equals "0" "$RC" "an unorderable spawn does not abort the report"
    assert_contains "$OUT" "spawns placed in barriers   1 of 3" "reports what it could not place"
    assert_contains "$OUT" "barriers                    1" "neither unplaceable spawn joins a barrier"
}

# A single spawn is one barrier with one member: no follower ranks, and no
# previous barrier to measure a gap against. Every rate denominator in the
# report must survive that.
SINGLE="$WORKDIR/single"
timed_spawn "$SINGLE" sessA only 0 30000 "2026-09-01T10:00:00.000Z"

test_timing_single_spawn_corpus() {
    run_measure timing "$SINGLE"
    assert_equals "0" "$RC" "a one-spawn corpus exits 0"
    assert_contains "$OUT" "barriers                    1" "counts the lone barrier"
    assert_not_contains "$OUT" "Traceback" "no division-by-zero on empty buckets"
}

# With no misses the shared block cannot be sized (cmd_cache makes the same
# refusal). The report must say there is nothing to attribute rather than print
# a 0-token penalty, which would read as "measured, and free".
ALLHIT="$WORKDIR/timed-allhit"
timed_spawn "$ALLHIT" sessA h1 11000 18000 "2026-09-01T10:00:00.000Z"
timed_spawn "$ALLHIT" sessA h2 11000 18000 "2026-09-01T10:00:04.000Z"

test_timing_all_hits_reports_no_misses() {
    run_measure timing "$ALLHIT"
    assert_equals "0" "$RC" "an all-hits corpus exits 0"
    assert_contains "$OUT" "no misses in this corpus" "says there is nothing to attribute"
}

# The TIMED corpus above has only a >TTL leader and two cold starts, so the
# in-TTL arm was proven ABSENT (assert_not_contains) and never proven correct
# when present. This corpus supplies a leader at a ~60s gap: far enough past the
# 20s barrier threshold to start a new barrier, well inside the 300s TTL.
INTTL="$WORKDIR/in-ttl"
timed_spawn "$INTTL" sessA b1lead 11000 18000 "2026-09-01T11:00:00.000Z"
timed_spawn "$INTTL" sessA b1f1 11000 18000 "2026-09-01T11:00:04.000Z"
timed_spawn "$INTTL" sessA b2lead 0 30000 "2026-09-01T11:01:04.000Z"

test_in_ttl_leader_is_bucketed_and_attributed() {
    run_measure timing "$INTTL"
    assert_equals "0" "$RC" "the in-TTL corpus exits 0"
    # 11:01:04 minus barrier 1's last START (11:00:04) = exactly 60s, which the
    # half-open buckets place in "60-120s" rather than "30-60s".
    assert_contains "$OUT" "60-120s                      1/1" "a 60s gap lands in the 60-120s bucket"
    assert_contains "$OUT" "leader, gap < TTL                1" "and is attributed as an in-TTL leader"
}

# The TTL boundary is the one value the bucket table and the attribution
# category could disagree about — and did, until both were made half-open. A gap
# of EXACTLY CACHE_TTL_SECONDS must read as past-TTL in both places.
BOUNDARY="$WORKDIR/ttl-boundary"
timed_spawn "$BOUNDARY" sessA b1lead 11000 18000 "2026-09-01T12:00:00.000Z"
timed_spawn "$BOUNDARY" sessA b2lead 0 30000 "2026-09-01T12:05:00.000Z"

test_ttl_boundary_agrees_between_both_tables() {
    run_measure timing "$BOUNDARY"
    # Exactly 300.0s. Half-open `low <= gap < high` puts it in 300-600s; the
    # attribution's `>=` must agree. A strict `>` there reported the SAME spawn
    # as in-TTL in one table and past-TTL in the other.
    assert_contains "$OUT" "300-600s                     1/1" "gap == TTL buckets as past-TTL"
    assert_contains "$OUT" "leader, gap >= TTL               1" "and attributes as past-TTL too"
    assert_not_contains "$OUT" "leader, gap < TTL" "never in-TTL in the same report"
}

# Ranks 5 and beyond are pooled into one "5+" row. Every other fixture tops out
# at 3 members, so the clamp was never exercised: a bug that dropped or
# mislabeled ranks 5-N would have passed the whole suite.
WIDE="$WORKDIR/wide-barrier"
timed_spawn "$WIDE" sessA w0 0 30000 "2026-09-01T13:00:00.000Z"
timed_spawn "$WIDE" sessA w1 11000 18000 "2026-09-01T13:00:02.000Z"
timed_spawn "$WIDE" sessA w2 11000 18000 "2026-09-01T13:00:04.000Z"
timed_spawn "$WIDE" sessA w3 11000 18000 "2026-09-01T13:00:06.000Z"
timed_spawn "$WIDE" sessA w4 11000 18000 "2026-09-01T13:00:08.000Z"
timed_spawn "$WIDE" sessA w5 11000 18000 "2026-09-01T13:00:10.000Z"
timed_spawn "$WIDE" sessA w6 0 30000 "2026-09-01T13:00:12.000Z"

test_rank_five_plus_is_pooled() {
    run_measure timing "$WIDE"
    assert_equals "0" "$RC" "a 7-member barrier exits 0"
    assert_contains "$OUT" "barriers                    1" "all seven spawns are one barrier"
    # Ranks 5 and 6 pool into one row: 2 spawns, of which w6 missed.
    assert_contains "$OUT" "5+                           1/2" "ranks 5 and 6 pool into a single row"
    # And nothing is dropped on the way: 7 placed, ranks 0-4 individually.
    assert_contains "$OUT" "spawns placed in barriers   7 of 7" "no spawn is lost to the clamp"
}

# iter_spawns takes session/timestamp from the first BILLED turn, and a comment
# justifies that choice against an earlier unbilled record. This fixture is the
# only place that claim is testable: an unbilled assistant record carrying a
# DIFFERENT session and an earlier timestamp precedes the billed one. Reading
# the first line instead would file the spawn under sessDECOY.
# The decoy carries the SAME session as the partner but a timestamp 10 minutes
# EARLIER. That combination is what makes the two readings distinguishable:
# reading the billed turn puts this spawn 4s before its partner -> ONE barrier;
# reading the first record puts it 10 min earlier -> TWO barriers, and the
# partner's leader then shows a >TTL gap. An earlier decoy in a DIFFERENT
# session would not work: it sorts away and still yields one barrier either way.
BILLED="$WORKDIR/billed-turn"
command mkdir -p "$BILLED/proj/x/subagents/wf"
{
    command printf '{"type":"user","message":{"role":"user","content":"dispatch"}}\n'
    command printf '{"type":"assistant","sessionId":"sessREAL","timestamp":"2026-09-01T13:50:00.000Z","message":{"role":"assistant","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    command printf '{"type":"assistant","sessionId":"sessREAL","timestamp":"2026-09-01T14:00:04.000Z","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":11000,"cache_creation_input_tokens":18000}}}\n'
} >"$BILLED/proj/x/subagents/wf/agent-billed.jsonl"
command printf '{"agentType":"dev-core:code-reviewer","spawnDepth":1}\n' \
    >"$BILLED/proj/x/subagents/wf/agent-billed.meta.json"
timed_spawn "$BILLED" sessREAL leader 0 30000 "2026-09-01T14:00:00.000Z"

test_identity_comes_from_the_billed_turn() {
    run_measure timing "$BILLED"
    assert_equals "0" "$RC" "the decoy-record corpus exits 0"
    assert_contains "$OUT" "spawns placed in barriers   2 of 2" "both spawns are placeable"
    # ONE barrier: the decoy-bearing spawn is placed at 14:00:04 (its billed
    # turn), 4s after the leader. Reading the unbilled 13:50 record instead
    # would split them into two barriers.
    assert_contains "$OUT" "barriers                    1" "identity comes from the billed turn"
    # And it lands as the FOLLOWER, not as a second leader.
    assert_contains "$OUT" "1                            0/1" "the billed timestamp makes it rank 1"
}

# cmd_timing re-derives cmd_cache's shared-block arithmetic, so it needs
# cmd_cache's refusal too: with no hits the block cannot be sized, and a
# fabricated 0-token cost would read as "measured, and free".
NOHITS="$WORKDIR/timing-nohits"
timed_spawn "$NOHITS" sessA m1 0 30000 "2026-09-01T15:00:00.000Z"
timed_spawn "$NOHITS" sessA m2 0 31000 "2026-09-01T15:00:04.000Z"

test_timing_refuses_to_price_an_unsizable_sample() {
    run_measure timing "$NOHITS"
    assert_equals "0" "$RC" "an all-miss corpus exits 0"
    assert_contains "$OUT" "cost per miss unavailable" "refuses to price what it cannot size"
    assert_not_contains "$OUT" "total penalty" "prints no fabricated total"
}

test_timing_is_an_accepted_subcommand() {
    run_measure timing "$TIMED"
    assert_equals "0" "$RC" "timing is a registered subcommand"
    # The argparse choices tuple and the dispatch dict are separate edits; a
    # subcommand added to one and not the other fails here rather than at use.
    run_measure tiiming "$TIMED"
    assert_equals "2" "$RC" "an unknown subcommand still exits 2"
}

run_test test_in_ttl_leader_is_bucketed_and_attributed "An in-TTL leader is bucketed and attributed, not just proven absent"
run_test test_ttl_boundary_agrees_between_both_tables "A gap of exactly the TTL reads the same in both tables"
run_test test_rank_five_plus_is_pooled "Ranks 5+ pool into one row without losing a spawn"
run_test test_identity_comes_from_the_billed_turn "Session identity comes from the billed turn, not the first line"
run_test test_timing_refuses_to_price_an_unsizable_sample "timing refuses to price a sample it cannot size"
run_test test_barriers_split_on_gap_and_session "Barriers split on the gap threshold and on a session change"
run_test test_leader_carries_the_misses "The leader/follower split is reported per rank"
run_test test_attribution_separates_ttl_from_barrier "Attribution separates a >TTL leader from an in-TTL one"
run_test test_cold_start_is_its_own_category "A session's first barrier is a cold start, not the largest gap bucket"
run_test test_timing_ignores_unorderable_spawns "A spawn with no timestamp is dropped, not guessed into a barrier"
run_test test_timing_single_spawn_corpus "A single-spawn corpus reports without dividing by zero"
run_test test_timing_all_hits_reports_no_misses "An all-hits corpus says so instead of pricing nothing"
run_test test_timing_is_an_accepted_subcommand "timing is accepted and an unknown subcommand still exits 2"
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
