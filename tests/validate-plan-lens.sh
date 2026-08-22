#!/usr/bin/env bash
# next-issue plan-lens sizing scanner behavioral gate (issue #756).
#
# THE THIRD LENS. File-size discipline had two lenses and both were reactive:
# the audit lens sweeps a repo and yields a backlog nobody works through; the
# review lens fires per-PR, once the work exists and acting on it means
# unpicking a finished implementation. Neither ran during PLANNING, the one
# moment a decomposition is cheap.
#
# THE CENTRAL PROPERTY is the row NEITHER other lens can produce. Both return
# early for a file UNDER its threshold, so a file at 640 lines against a 700
# budget is silent everywhere else — and it is exactly the file about to gain
# 200 lines. The plan lens projects `current + planner-estimate` against the
# budget and reports that file. Its disposition table:
#
#   under budget, projection crosses     -> size-headroom, MEDIUM/HIGH
#   already over budget, with estimate   -> its size category, MEDIUM/HIGH
#   already over, sidecar names no growth-> LOW, informational
#   no sidecar at all                    -> LOW, and NO headroom rows
#   under budget, projection stays under -> nothing
#
# AC3 is the deliberate DIVERGENCE from the review lens: there, a trivial touch
# to a pre-existing oversized file is explicitly not the author's debt (#695
# AC4). Here the planner is about to open the file anyway, which is the cheapest
# moment its split will ever have — so it is raised regardless of estimate.
#
# Every case is asserted against BOTH the Python primary (plan-lens.py) and the
# bash fallback (PLAN_LENS_FORCE_BASH=1 plan-lens.sh) — free parity
# reinforcement on top of validate-python-ports.sh's whole-corpus diff.
#
# MUTATION-VERIFIED. Ten mutations over the RULES (not merely the tests), each
# reverted after:
#   headroom arm   — the size-headroom emit removed          -> red
#   floor          — min_estimate forced to 0                -> red
#   already-over   — the estimate>0 distinction disabled     -> red
#   zero-vs-absent — the have_estimate arm collapsed         -> red
#   classification — the b_warn>0 prose branch disabled      -> red
#   rename         — sidecar_path() short-circuited          -> red
#   fail loud (sh) — the no-engine exit 2 downgraded to 0    -> red
#   measure seam   — measure mode made to ALSO emit findings -> red
#   projection(sh) — `if (projected <= warn) exit 0` deleted -> SURVIVED, see below
#   projection(py) — the same guard in the python twin       -> red
#
# THAT ROUND PAID FOR ITSELF. The bash projection guard initially SURVIVED, and
# it was a REAL GAP rather than a no-op: with the guard gone the scanner claims
# a 40-production-LOC file is "over the 500 warning budget" while python stays
# silent — genuine cross-runtime drift. The cause was two guards producing
# indistinguishable silences: the small-estimate case exits at the FLOOR check
# and never reaches the PROJECTION check, so no fixture exercised the latter.
# Diagnosed per [[surviving-mutation-may-be-a-real-no-op]] by driving the mutant
# directly before writing anything; the fix is
# test_plan_lens_ample_headroom_stays_silent, whose estimate deliberately CLEARS
# the floor so the projection is the only thing keeping it quiet.
#
# Pure bash + coreutils; no node/jq. Full /usr/bin/* paths per project shell
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SIZING_SH="$REPO_ROOT/plugins/workflow/skills/ship-issue/sizing.sh"
SIZING_PY="$REPO_ROOT/plugins/workflow/skills/ship-issue/sizing.py"
PLAN_SH="$REPO_ROOT/plugins/workflow/skills/ship-issue/plan-lens.sh"
PLAN_PY="$REPO_ROOT/plugins/workflow/skills/ship-issue/plan-lens.py"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "next-issue plan-lens sizing scanner (#756)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

# make_py_file PATH NDEFS — a Python file with NDEFS trivial top-level defs.
# Each def contributes 2 production lines, so production LOC ~= 2 * NDEFS.
make_py_file() {
    local path="$1" ndefs="$2" i
    : >"$path"
    i=0
    while [ "$i" -lt "$ndefs" ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$path"
        i=$((i + 1))
    done
}

# make_md_file PATH NLINES — a prose file of NLINES lines.
make_md_file() {
    local path="$1" nlines="$2" i
    : >"$path"
    i=0
    while [ "$i" -lt "$nlines" ]; do
        command printf 'Prose line %d of the document.\n' "$i" >>"$path"
        i=$((i + 1))
    done
}

# make_numstat PATH FILE ADDED — a one-row `git diff --numstat` sidecar, for the
# review-lens regression case (AC6) that rides along in this suite.
make_numstat() {
    command printf '%s\t0\t%s\n' "$3" "$2" >"$1"
}

# run_scan / assert_parity — the REVIEW lens, needed only by the AC6 case below.
# Same subshell rationale as run_plan: assigning to a global keeps assertions in
# the caller's shell, where TEST_STATUS is real.
run_scan() {
    local list="$1" numstat="${2:-}" py_out
    SCAN_PARITY="ok"
    SCAN_OUT="$(SIZING_FORCE_BASH=1 command bash "$SIZING_SH" "$list" $numstat 2>&1 || true)"
    if [ "$HAVE_PY" = "1" ]; then
        py_out="$(command python3 "$SIZING_PY" "$list" $numstat 2>&1 || true)"
        [ "$SCAN_OUT" = "$py_out" ] || SCAN_PARITY="drift"
        SCAN_PY_OUT="$py_out"
    fi
}

assert_parity() {
    [ "$HAVE_PY" = "1" ] || return 0
    if [ "$SCAN_PARITY" != "ok" ]; then
        _fail "bash and python impls disagree (parity drift)" \
            "The TSV contract is the language boundary — a port is a drop-in only while the output matches." \
            "bash: $SCAN_OUT" "python: $SCAN_PY_OUT"
    fi
}

# A file that is comfortably over the 500-LOC default warning threshold.
setup_over_threshold() {
    OVER_FILE="$WORKDIR/big.py"
    make_py_file "$OVER_FILE" 320 # ~640 production LOC
    LIST="$WORKDIR/files.txt"
    command printf '%s\n' "$OVER_FILE" >"$LIST"
}

# --- plan lens (#756) --------------------------------------------------------
# make_estimate PATH FILE ADDED — a one-row plan-lens estimate sidecar. Two
# columns (`added<TAB>path`), the planner shape; the 3-column numstat shape is
# exercised separately by test_plan_lens_accepts_numstat_shape.
make_estimate() {
    command printf '%s\t%s\n' "$3" "$2" >"$1"
}

# run_plan FILE_LIST [ESTIMATES] — run BOTH plan-lens impls, leaving output in
# the GLOBAL `PLAN_OUT` with parity in `PLAN_PARITY`. Same subshell rationale as
# run_scan above: a command substitution would run the parity assertion in a
# child whose TEST_STATUS the parent never sees, making the check silently inert.
run_plan() {
    local list="$1" est="${2:-}" py_out
    PLAN_PARITY="ok"
    PLAN_OUT="$(PLAN_LENS_FORCE_BASH=1 command bash "$PLAN_SH" "$list" $est 2>&1 || true)"
    if [ "$HAVE_PY" = "1" ]; then
        py_out="$(command python3 "$PLAN_PY" "$list" $est 2>&1 || true)"
        [ "$PLAN_OUT" = "$py_out" ] || PLAN_PARITY="drift"
        PLAN_PY_OUT="$py_out"
    fi
}

assert_plan_parity() {
    [ "$HAVE_PY" = "1" ] || return 0
    if [ "$PLAN_PARITY" != "ok" ]; then
        _fail "plan-lens bash and python impls disagree (parity drift)" \
            "The TSV contract is the language boundary — a port is a drop-in only while the output matches." \
            "bash: $PLAN_OUT" "python: $PLAN_PY_OUT"
    fi
}

# A file comfortably UNDER the 500-LOC warning but with little headroom left.
# 230 defs ~= 460 production LOC, so 40 LOC of headroom against the 500 warning.
setup_near_budget() {
    NEAR_FILE="$WORKDIR/near.py"
    make_py_file "$NEAR_FILE" 230
    PLAN_LIST="$WORKDIR/plan-files.txt"
    command printf '%s\n' "$NEAR_FILE" >"$PLAN_LIST"
}

# --- AC2: the headroom row, which NEITHER other lens can produce -------------
# THE central plan-lens property. A file UNDER its budget is silent in both the
# audit and review lenses (both return early on the threshold check), so this is
# the one row that justifies a third lens existing at all.
#
# ASSERTED AS A PAIR, deliberately: the SAME fixture with a LARGE estimate must
# emit and with a SMALL estimate must not. A one-sided assertion here would be
# satisfied by a scanner that emits headroom rows unconditionally — which is the
# [[gate-and-evidence-converge-tautology]] shape, where one fixture both arms and
# satisfies the gate. Two estimates over one fixture is what makes the estimate,
# rather than the file, the variable under test.
test_plan_lens_headroom_fires_on_projection() {
    setup_near_budget
    local est="$WORKDIR/est-big.tsv"
    make_estimate "$est" "$NEAR_FILE" 200

    run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "size-headroom" \
        "an under-budget file whose projection crosses emits size-headroom"
    assert_contains "$PLAN_OUT" "projecting 660" \
        "the evidence names the PROJECTED total (460 + 200), not just today's size"
    assert_contains "$PLAN_OUT" "MEDIUM" \
        "a projection over the warning threshold is MEDIUM"
}

test_plan_lens_small_estimate_stays_silent() {
    setup_near_budget
    local est="$WORKDIR/est-small.tsv"
    make_estimate "$est" "$NEAR_FILE" 5

    run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_equals "" "$PLAN_OUT" \
        "the SAME under-budget file with a small estimate emits nothing (the estimate is the variable)"
}

# A file with AMPLE headroom is silent even when the estimate CLEARS the floor.
#
# WHY THIS IS NOT test_plan_lens_small_estimate_stays_silent. That case uses an
# estimate BELOW the floor, so it exits at the floor check and never reaches the
# projection comparison — the two silences look identical from outside but come
# from different guards. Found by mutation: deleting the bash projection guard
# (`if (projected <= warn) exit 0`) left the whole suite green, because no
# fixture reached it. Unmutated, the mutant claims a 40-LOC file is "over the
# 500 warning budget" while python stays silent — a real gap, not a no-op, so it
# gets a real test rather than a recorded exemption.
test_plan_lens_ample_headroom_stays_silent() {
    local small="$WORKDIR/ample.py" list="$WORKDIR/ample-list.txt"
    make_py_file "$small" 20 # ~40 production LOC
    command printf '%s\n' "$small" >"$list"
    local est="$WORKDIR/est-ample.tsv"
    # 30 clears the default floor of 25, so the ONLY thing keeping this quiet is
    # the projection (40 + 30 = 70) landing far under the 500 warning.
    make_estimate "$est" "$small" 30

    run_plan "$list" "$est"
    assert_plan_parity
    assert_equals "" "$PLAN_OUT" \
        "an estimate above the floor whose projection stays under budget emits nothing"
}

# The floor is a real boundary, not decoration. Mirrors
# test_materiality_floor_is_honored on the review lens: asserted from BOTH sides
# of the same threshold so a scanner ignoring the knob fails one arm.
test_plan_lens_headroom_floor_is_honored() {
    setup_near_budget
    local est="$WORKDIR/est-floor.tsv"
    # 60 LOC of growth crosses the 500 warning from 460 either way, so the ONLY
    # variable is whether the estimate clears the floor.
    make_estimate "$est" "$NEAR_FILE" 60

    PLAN_HEADROOM_MIN_ESTIMATE=50 run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "size-headroom" \
        "an estimate at or above the floor is projected"

    PLAN_HEADROOM_MIN_ESTIMATE=100 run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_equals "" "$PLAN_OUT" \
        "the same estimate below a raised floor is silent (PLAN_HEADROOM_MIN_ESTIMATE is consulted)"
}

# --- AC3: an already-over file is raised REGARDLESS of estimate --------------
# The deliberate DIVERGENCE from the review lens, and the reason this cannot be
# a shared disposition. There, a trivial touch to a pre-existing oversized file
# is explicitly not the author's debt (AC4 of #695). Here the planner is about to
# open the file anyway, which is the cheapest moment its split will ever have.
test_plan_lens_already_over_is_raised_regardless() {
    setup_over_threshold
    local est="$WORKDIR/est-tiny.tsv"
    make_estimate "$est" "$OVER_FILE" 1

    run_plan "$LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "file-length" \
        "an already-over file is raised even on a 1-line estimate"
    assert_contains "$PLAN_OUT" "already over" \
        "the evidence distinguishes already-over from a projected crossing"
    assert_not_contains "$PLAN_OUT" "size-headroom" \
        "an already-over file takes its size category, NOT size-headroom"
}

# --- AC4: no estimate sidecar -> informational, and NO headroom rows ---------
# Mirrors the review lens's no-numstat behavior. The two halves are separate
# claims: already-over files must still SPEAK (silence is indistinguishable from
# "not examined"), while headroom must go quiet (there is nothing to project).
test_plan_lens_without_estimates_is_informational() {
    setup_over_threshold
    run_plan "$LIST"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "LOW" \
        "with no sidecar an already-over file is LOW/informational"
    assert_contains "$PLAN_OUT" "no plan estimate supplied" \
        "the evidence says WHY it is informational"

    setup_near_budget
    run_plan "$PLAN_LIST"
    assert_plan_parity
    assert_equals "" "$PLAN_OUT" \
        "with no sidecar there is nothing to project, so no headroom row"
}

# A sidecar that EXISTS but names no growth for this file is a THIRD state, and
# must not borrow the no-sidecar wording — saying "no estimate supplied" there
# would be false and would hide that the planner did size the file.
test_plan_lens_distinguishes_zero_from_absent() {
    setup_over_threshold
    local other="$WORKDIR/other.py" est="$WORKDIR/est-other.tsv"
    make_py_file "$other" 5
    make_estimate "$est" "$other" 200

    run_plan "$LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "does not add to it" \
        "a sidecar naming no growth for this file reads differently from no sidecar"
    assert_not_contains "$PLAN_OUT" "no plan estimate supplied" \
        "the no-sidecar wording is NOT reused when a sidecar exists"
}

# --- prose classification reaches the plan lens ------------------------------
# The plan lens must size an agent definition by its OWN 250/400 budget, not the
# generic md pair — the #724 defect, which would otherwise recur here because
# this is a new consumer of the same classification.
test_plan_lens_classifies_prose_by_type() {
    local agents="$WORKDIR/agents" list="$WORKDIR/prose-list.txt"
    command mkdir -p "$agents"
    make_md_file "$agents/rev.md" 450
    command printf '%s\n' "$agents/rev.md" >"$list"
    local est="$WORKDIR/est-prose.tsv"
    make_estimate "$est" "$agents/rev.md" 30

    run_plan "$list" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "ai-file-bloat" \
        "an agent definition is classified, not sized as a generic doc"
    assert_contains "$PLAN_OUT" "agent definition" \
        "the evidence names the file TYPE from the shared bloat spec"
}

# The sidecar accepts a real `git diff --numstat` file unchanged (3 columns) and
# is rename-aware. Without the rename handling a renamed file's estimate silently
# reads 0 and it can never be raised — the case the lens most wants to see.
test_plan_lens_accepts_numstat_shape() {
    setup_near_budget
    local est="$WORKDIR/est-numstat.tsv"
    command printf '200\t7\told.py => %s\n' "$NEAR_FILE" >"$est"

    run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "size-headroom" \
        "a 3-column numstat row with a rename still resolves to its post-rename path"
}

# --- fail loud, never a silent "no findings" ---------------------------------
# The #538/#571 sentinel discipline. A scanner that cannot reach its LOC engine
# must exit non-zero: a clean exit 0 with no rows is indistinguishable from a
# clean repo, which is how a gate sits inert unnoticed. (The PLANNER's tolerance
# is separate and lives in plan-sizing.md — it catches this and proceeds.)
test_plan_lens_fails_loud_without_engine() {
    local iso="$WORKDIR/isolated" rc=0
    command mkdir -p "$iso"
    setup_near_budget

    # BOTH RUNTIMES, and the pairing is the point. Copying only plan-lens.sh
    # leaves the shim with no sibling .py to exec, so it silently falls through
    # to the bash body and the PYTHON fail-loud arm — the one that actually runs
    # in production, since the shim prefers python3>=3.11 — is never exercised.
    # That is the [[self-skipping-test-hides-the-risky-branch]] shape: the test
    # passes while covering only the arm that does not run.
    command cp "$PLAN_SH" "$iso/"
    rc=0
    PLAN_LENS_FORCE_BASH=1 command bash "$iso/plan-lens.sh" "$PLAN_LIST" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" \
        "bash fallback: with no sibling sizing engine the scanner exits 2, NOT 0-with-no-findings"

    if [ "$HAVE_PY" = "1" ]; then
        command cp "$PLAN_PY" "$iso/"
        rc=0
        command python3 "$iso/plan-lens.py" "$PLAN_LIST" >/dev/null 2>&1 || rc=$?
        assert_equals "2" "$rc" \
            "python primary: with no sibling sizing engine the scanner exits 2, NOT 0-with-no-findings"

        # And through the SHIM, which is how a caller actually reaches it: with
        # both files present the shim exec's python, so this pins the real path.
        rc=0
        command bash "$iso/plan-lens.sh" "$PLAN_LIST" >/dev/null 2>&1 || rc=$?
        assert_equals "2" "$rc" \
            "via the shim (python primary selected): the scanner still exits 2"
    fi
}

test_plan_lens_usage_contract() {
    local rc=0 empty="$WORKDIR/empty-plan.txt" out
    : >"$empty"

    # BOTH RUNTIMES. A bare `bash "$PLAN_SH"` is exec'd straight to the python
    # primary by the shim whenever a python3>=3.11 is present, so without the
    # FORCE_BASH arm the bash body's own usage handling is never reached — the
    # same asymmetry the fail-loud case had. The CLI contract is what
    # validate-python-ports.sh keys the whole corpus on, so it must hold in each
    # impl independently, not merely in whichever one the shim happened to pick.
    rc=0
    PLAN_LENS_FORCE_BASH=1 command bash "$PLAN_SH" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "plan-lens (bash): no argument exits 1"

    rc=0
    PLAN_LENS_FORCE_BASH=1 command bash "$PLAN_SH" "$WORKDIR/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "plan-lens (bash): a missing file list exits 1"

    rc=0
    out="$(PLAN_LENS_FORCE_BASH=1 command bash "$PLAN_SH" "$empty" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "plan-lens (bash): an empty file list exits 0"
    assert_equals "" "$out" "plan-lens (bash): an empty file list emits nothing"

    if [ "$HAVE_PY" = "1" ]; then
        rc=0
        command python3 "$PLAN_PY" >/dev/null 2>&1 || rc=$?
        assert_equals "1" "$rc" "plan-lens (python): no argument exits 1"

        rc=0
        command python3 "$PLAN_PY" "$WORKDIR/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
        assert_equals "1" "$rc" "plan-lens (python): a missing file list exits 1"

        rc=0
        out="$(command python3 "$PLAN_PY" "$empty" 2>&1)" || rc=$?
        assert_equals "0" "$rc" "plan-lens (python): an empty file list exits 0"
        assert_equals "" "$out" "plan-lens (python): an empty file list emits nothing"
    fi
}

# A hand-written sidecar WILL eventually carry a malformed row — the planner
# writes it, not git. The contract is that a bad row is SKIPPED, not fatal and
# not silently treated as growth: an unparseable count must leave the file with
# no estimate rather than crash the scan or invent a number. Pinned in both
# impls because they parse independently (python int()/ValueError, awk's
# /^[0-9]+$/ guard) and could disagree about what "malformed" means.
test_plan_lens_tolerates_malformed_estimate_rows() {
    setup_over_threshold
    local est="$WORKDIR/est-bad.tsv"
    {
        command printf 'notanumber\t%s\n' "$OVER_FILE"
        command printf '\n'
        command printf 'onlyonefield\n'
    } >"$est"

    run_plan "$LIST" "$est"
    assert_plan_parity
    # The file is over budget, so it must still be REPORTED — a malformed
    # sidecar must not silence the scan (that would be the fail-loud inversion).
    assert_contains "$PLAN_OUT" "file-length" \
        "a malformed sidecar does not silence an already-over file"
    assert_contains "$PLAN_OUT" "no plan estimate supplied" \
        "an unparseable count reads as NO estimate, never as growth"
    assert_not_contains "$PLAN_OUT" "size-headroom" \
        "a malformed row cannot manufacture a projection"
}

# --- AC6: the REVIEW lens is byte-identical after the measure-mode seam -------
# The regression tripwire. `sizing --measure` was added so the plan lens could
# reuse the LOC engine; the risk is that the seam perturbs the review lens's own
# output. Asserted as an explicit property rather than by inspection.
test_measure_mode_does_not_disturb_review_output() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-ac6.txt"
    make_numstat "$numstat" "$OVER_FILE" 120

    run_scan "$LIST" "$numstat"
    assert_parity
    assert_contains "$SCAN_OUT" "file-length" \
        "the review lens still emits its rows with measure mode present"
    assert_not_contains "$SCAN_OUT" "size-headroom" \
        "the review lens NEVER emits the plan lens's category"

    # Measure mode itself must be inert unless explicitly asked for.
    local m_out
    m_out="$(SIZING_FORCE_BASH=1 command bash "$SIZING_SH" --measure "$LIST" 2>&1 || true)"
    assert_not_contains "$m_out" "file-length" \
        "measure mode emits metrics, not findings"
    assert_contains "$m_out" "$OVER_FILE" \
        "measure mode emits a record for the scanned file"
}
# The measure record's `generated` and `comment_pct` fields carry NO assertion
# from the plan lens, which consumes neither (they feed the review lens's
# decline-reason arms). That makes them the record's soft spot: a drift between
# the two runtimes there changes no plan-lens output, so every existing test
# stays green while the shared contract silently forks — and the review lens,
# which DOES read them, would then disagree with itself across runtimes.
#
# Pinned here because this suite owns the --measure seam. Positional too, not
# just valued: the whole point of a 13-field record is that field N means the
# same thing to every consumer.
test_measure_record_fields_agree_across_runtimes() {
    local gen="$WORKDIR/gen.py" com="$WORKDIR/com.py" list="$WORKDIR/measure-list.txt"
    local i=0

    command printf '# @generated\n# DO NOT EDIT\ndef a():\n    return 1\n' >"$gen"

    # Majority-comment file: 60 comment lines against 20 production lines.
    : >"$com"
    while [ "$i" -lt 60 ]; do
        command printf '# comment %d\n' "$i" >>"$com"
        i=$((i + 1))
    done
    make_py_file "$WORKDIR/tmp-defs.py" 10
    command cat "$WORKDIR/tmp-defs.py" >>"$com"

    command printf '%s\n%s\n' "$gen" "$com" >"$list"

    local sh_out py_out
    sh_out="$(SIZING_FORCE_BASH=1 command bash "$SIZING_SH" --measure "$list" 2>&1 || true)"
    assert_not_empty "$sh_out" "measure mode emits a record (the gate is not a no-op)"

    # generated=1 on the marked file, 0 on the other — asserted by VALUE, so a
    # detector that always answered the same way fails here.
    assert_contains "$sh_out" "$(command printf '%s\t4\t' "$gen")" \
        "the generated fixture's record starts with its path and total"
    local gen_flag com_flag gen_pct com_pct
    gen_flag="$(command printf '%s\n' "$sh_out" | command awk -F'\t' -v f="$gen" '$1 == f { print $6 }')"
    com_flag="$(command printf '%s\n' "$sh_out" | command awk -F'\t' -v f="$com" '$1 == f { print $6 }')"
    assert_equals "1" "$gen_flag" "a @generated file reports generated=1"
    assert_equals "0" "$com_flag" "an ordinary file reports generated=0 (the flag discriminates)"

    com_pct="$(command printf '%s\n' "$sh_out" | command awk -F'\t' -v f="$com" '$1 == f { print $5 }')"
    gen_pct="$(command printf '%s\n' "$sh_out" | command awk -F'\t' -v f="$gen" '$1 == f { print $5 }')"
    assert_equals "75" "$com_pct" "a 60-comment/20-code file reports comment_pct=75"
    assert_equals "50" "$gen_pct" "the generated fixture reports comment_pct=50"

    if [ "$HAVE_PY" = "1" ]; then
        py_out="$(command python3 "$SIZING_PY" --measure "$list" 2>&1 || true)"
        assert_equals "$sh_out" "$py_out" \
            "the FULL 13-field measure record is byte-identical across runtimes (incl. fields plan-lens ignores)"
    fi
}

# --- the HIGH band, in BOTH arms -------------------------------------------
# Every other fixture in this suite lands in the WARNING band (setup_near_budget
# projects to at most 660, setup_over_threshold sits at ~640 — both under the
# 800 default high for .py). So the `current > high` / `projected > high`
# comparison that chooses HIGH-vs-MEDIUM was never exercised: a mutation pinning
# certainty to MEDIUM, or flipping that `>` to `<`, passed the whole suite in
# both runtimes.
#
# Asserted on the CERTAINTY and the band WORDING together, because they are
# computed from the same comparison and a test reading only one would miss a
# half-applied change.
test_plan_lens_high_band_on_projection() {
    local big="$WORKDIR/high-proj.py" list="$WORKDIR/high-list.txt" est="$WORKDIR/high-est.tsv"
    make_py_file "$big" 240 # ~480 production LOC, under the 500 warning
    command printf '%s\n' "$big" >"$list"
    # 480 + 400 = 880, over the 800 high — not merely over the warning.
    make_estimate "$est" "$big" 400

    run_plan "$list" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "size-headroom" "the headroom row is emitted"
    assert_contains "$PLAN_OUT" "HIGH" \
        "a projection over the HIGH threshold is HIGH, not MEDIUM"
    assert_contains "$PLAN_OUT" "high budget" \
        "the evidence names the high band (certainty and wording agree)"
}

test_plan_lens_high_band_on_already_over() {
    local big="$WORKDIR/high-over.py" list="$WORKDIR/high-over-list.txt" est="$WORKDIR/high-over-est.tsv"
    make_py_file "$big" 420 # ~840 production LOC, already past the 800 high
    command printf '%s\n' "$big" >"$list"
    make_estimate "$est" "$big" 30

    run_plan "$list" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "HIGH" \
        "an already-over file past the HIGH threshold is HIGH, not MEDIUM"
    assert_contains "$PLAN_OUT" "already over its high budget" \
        "the already-over arm names the high band too"
}

# The sidecar's SECOND rename shape. git prints a rename either as
# `old.py => new.py` (whole path) or `a/{x => y}/f.py` (one segment), and the
# brace branch is a separate code path in both impls — python slices around
# index("{")/index("}"), awk does the same by hand. Only the whole-path form was
# fixtured, so a broken brace branch silently read the estimate as 0 and the file
# could never be raised, which is the case the lens most wants to see.
# validate-sizing-scanner.sh fixtures this shape for the review lens; the plan
# lens needs its own.
test_plan_lens_brace_rename_shape() {
    setup_near_budget
    local est="$WORKDIR/est-brace.tsv" dir base
    dir="$(command dirname "$NEAR_FILE")"
    base="$(command basename "$NEAR_FILE")"
    # `a/{oldsub => }/f.py` — the dropped-segment spelling, which also exercises
    # the `//` collapse both impls perform after splicing.
    command printf '200\t0\t%s/{oldsub => }/%s\n' "$dir" "$base" >"$est"

    run_plan "$PLAN_LIST" "$est"
    assert_plan_parity
    assert_contains "$PLAN_OUT" "size-headroom" \
        "a {old => new} segment rename resolves to its post-rename path and keeps its estimate"
}

run_test test_plan_lens_headroom_fires_on_projection "#756 AC2: an under-budget file whose projection crosses emits size-headroom"
run_test test_plan_lens_small_estimate_stays_silent "#756 AC2: the same file with a small estimate stays silent (estimate is the variable)"
run_test test_plan_lens_ample_headroom_stays_silent "#756: a projection that stays under budget is silent (distinct guard from the floor)"
run_test test_plan_lens_headroom_floor_is_honored "#756: PLAN_HEADROOM_MIN_ESTIMATE is a real boundary"
run_test test_plan_lens_already_over_is_raised_regardless "#756 AC3: an already-over file is raised regardless of estimate"
run_test test_plan_lens_without_estimates_is_informational "#756 AC4: no sidecar -> informational, and no headroom rows"
run_test test_plan_lens_distinguishes_zero_from_absent "#756: a sidecar naming no growth reads differently from no sidecar"
run_test test_plan_lens_classifies_prose_by_type "#756: prose classification reaches the plan lens (#724 does not regress)"
run_test test_plan_lens_high_band_on_projection "#756: a projection over the HIGH threshold is HIGH, not MEDIUM"
run_test test_plan_lens_high_band_on_already_over "#756: an already-over file past HIGH is HIGH (both arms)"
run_test test_plan_lens_brace_rename_shape "#756: the {old => new} segment rename shape resolves (2nd git rename form)"
run_test test_plan_lens_accepts_numstat_shape "#756 AC1: the sidecar accepts a real numstat file and is rename-aware"
run_test test_plan_lens_fails_loud_without_engine "#756: no LOC engine exits 2, never 0-with-no-findings"
run_test test_plan_lens_tolerates_malformed_estimate_rows "#756: a malformed estimate row is skipped, not fatal and not growth"
run_test test_plan_lens_usage_contract "#756: plan-lens usage / missing-file / empty-list contract"
run_test test_measure_record_fields_agree_across_runtimes "#756: the measure record's unconsumed fields are pinned across runtimes"
run_test test_measure_mode_does_not_disturb_review_output "#756 AC6: the review lens is unchanged by the measure-mode seam"
generate_report
