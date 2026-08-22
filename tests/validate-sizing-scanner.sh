#!/usr/bin/env bash
# ship-issue review-lens sizing scanner behavioral gate (issue #695).
#
# The adversarial pre-PR review had no size lens: a PR could add 900 lines to an
# already-oversized file and pass clean. sizing.{py,sh} supplies those
# candidates. This gate pins the behavior that makes the lens survivable.
#
# THE CENTRAL PROPERTY (AC4) is GROWTH-AWARENESS, and it is the reason this is a
# new scanner rather than a call into check-decomposition. An audit lens asks "is
# this file too long?"; a per-PR lens must ask "did THIS diff make it worse?",
# because a one-line touch to a pre-existing 1,200-line file is not the author's
# debt. A reviewer that blocks on pre-existing size gets turned off within a week,
# and then catches nothing at all. So the disposition table is the contract:
#
#   crossed a threshold because of this diff -> MEDIUM/HIGH, blocking-eligible
#   already over, material growth (>= 50)    -> MEDIUM,      blocking-eligible
#   already over, trivial growth             -> LOW,         informational only
#   no numstat supplied at all               -> LOW,         informational only
#
# Every case is asserted against BOTH the Python primary (sizing.py) and the bash
# fallback (SIZING_FORCE_BASH=1 sizing.sh) — free parity reinforcement on top of
# validate-python-ports.sh's whole-corpus diff, and the only place the two impls
# are compared on the GROWTH branch specifically.
#
# MUTATION-VERIFIED (the #221/#663 precedent). Each rule below was proven to be
# genuinely tested by transiently breaking it and confirming this gate goes red,
# then reverting. Per the mutation-round-finds-the-untested-rule lesson the round
# targets every RULE, not merely every test — the rule with zero failures is the
# one the round exists to find. The mutations checked:
#   growth guard  — `crossed` forced True unconditionally  -> red (10 -> 9)
#   growth guard  — `material` forced True unconditionally -> red (10 -> 9)
#   per-language  — PER_LANG_THRESHOLDS lookup disabled    -> red (10 -> 9)
#   decline path  — decline reason arm swapped             -> red (10 -> 9)
#   split shape   — split_shape() collapsed to "split it"  -> red (10 -> 6)
#
# The #724 prose-classification round (five mutations, each reverted after):
#   classification — bloat_spec() forced to None            -> red (23 -> 20)
#   arm order      — companion glob hoisted above SKILL.md  -> red (23 -> 22)
#   disposition    — `crossed` forced True (flat grading)   -> red (23 -> 20)
#   one verdict    — the #701 early `return` removed        -> red (23 -> 22)
#   fall-through   — docs arm widened to every *.md         -> red (23 -> 21)
#   category       — emit() category hardcoded ai-file-bloat -> red (25 -> 24)
#   prose material — `material` forced False in scan_prose   -> red (25 -> 24)
#   bundle kind    — bundle_kind() forced ""                 -> red (25 -> 24)
#
# THAT ROUND PAID FOR ITSELF TOO. The one-verdict mutation initially SURVIVED,
# and the cause was a test that could not fail: the assertion rode the 500-line
# agent fixture, which is UNDER the generic 700 md warning, so the production-LOC
# path returned early on its own and the guard being removed changed nothing.
# Diagnosed as a real gap rather than a no-op by reproducing the double row on a
# larger file; see test_classified_prose_gets_exactly_one_verdict, which is sized
# at 900 lines so both paths genuinely compete.
#
# THE ROUND PAID FOR ITSELF. The decline-reason mutation initially SURVIVED, and
# the reason was a defect in this file rather than a missing case: `run_scan` was
# called in a command substitution, so the bash-vs-python assertion inside it ran
# in a SUBSHELL and could never flip the parent's TEST_STATUS. The parity check
# was inert — it could not fail, which reads identically to always passing. See
# the `run_scan`/`assert_parity` split below, which is what makes it real.
#
# The #756 plan-lens round (ten mutations, each reverted after):
#   headroom arm   — the size-headroom emit removed          -> red (36 -> 33)
#   floor          — min_estimate forced to 0                -> red (36 -> 35)
#   already-over   — the estimate>0 distinction disabled     -> red (36 -> 34)
#   zero-vs-absent — the have_estimate arm collapsed         -> red (36 -> 35)
#   classification — the b_warn>0 prose branch disabled      -> red (36 -> 35)
#   rename         — sidecar_path() short-circuited          -> red (36 -> 35)
#   fail loud (sh) — the no-engine exit 2 downgraded to 0    -> red (36 -> 35)
#   measure seam   — measure mode made to ALSO emit findings -> red (36 -> 32)
#   projection(sh) — `if (projected <= warn) exit 0` deleted -> SURVIVED, see below
#   projection(py) — the same guard in the python twin       -> red (37 -> 36)
#
# THAT ROUND PAID FOR ITSELF. The bash projection guard initially SURVIVED, and
# it was a REAL GAP rather than a no-op: with the guard gone the scanner claims a
# 40-production-LOC file is "over the 500 warning budget", while python stays
# silent — genuine cross-runtime drift. The cause was two guards producing
# indistinguishable silences: the existing small-estimate case exits at the FLOOR
# check and never reaches the PROJECTION check, so no fixture exercised the
# latter. Diagnosed per [[surviving-mutation-may-be-a-real-no-op]] by driving the
# mutant directly before writing anything; the fix is
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

test_suite "ship-issue review-lens sizing scanner (#695)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

# make_py_file PATH NDEFS — a Python file with NDEFS trivial top-level defs.
# Each def contributes 2 production lines, so production LOC ~= 2 * NDEFS. Sized
# by parameter rather than by a fixed fixture so a threshold change here is a
# one-number edit rather than a fixture rewrite.
make_py_file() {
    local path="$1" ndefs="$2" i
    : >"$path"
    i=0
    while [ "$i" -lt "$ndefs" ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$path"
        i=$((i + 1))
    done
}

# make_numstat PATH FILE ADDED — a one-row `git diff --numstat` sidecar.
make_numstat() {
    command printf '%s\t0\t%s\n' "$3" "$2" >"$1"
}

# run_scan FILE_LIST [NUMSTAT] — run BOTH impls and leave the output in the
# GLOBAL `SCAN_OUT`, with parity recorded in `SCAN_PARITY` ("ok" | "drift").
#
# WHY A GLOBAL AND NOT AN ECHO. The obvious shape — capturing the helper in a
# command substitution, with the parity assertion inside it — is BROKEN here:
# command substitution runs the helper in a SUBSHELL, so an assertion that flips
# TEST_STATUS flips it in a child process that then exits. The parent's counters
# never see it and the parity check is silently inert — it can never fail, which
# is indistinguishable from always passing. (Found by the mutation round: a
# tampered decline-reason produced genuine bash/python drift and this suite
# stayed green.) Assigning to a global keeps every assertion in the caller's
# shell, where TEST_STATUS is real.
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

# assert_parity — every case asserts bash==python for free. Called in the test
# body (NOT inside run_scan) so the failure lands in the caller's TEST_STATUS.
assert_parity() {
    [ "$HAVE_PY" = "1" ] || return 0
    if [ "$SCAN_PARITY" != "ok" ]; then
        _fail "bash and python impls disagree (parity drift)" \
            "The TSV contract is the language boundary — a port is a drop-in only while the output matches." \
            "bash: $SCAN_OUT" "python: $SCAN_PY_OUT"
    fi
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

# A file that is comfortably over the 500-LOC default warning threshold.
setup_over_threshold() {
    OVER_FILE="$WORKDIR/big.py"
    make_py_file "$OVER_FILE" 320 # ~640 production LOC
    LIST="$WORKDIR/files.txt"
    command printf '%s\n' "$OVER_FILE" >"$LIST"
}

# --- AC4: a one-line touch to a pre-existing oversized file does NOT block ----
# THE headline acceptance criterion. Asserted on the CERTAINTY, not merely on
# "some row was emitted": the scanner is SUPPOSED to speak here (silence would be
# indistinguishable from "not examined"), it just must not speak in a
# blocking-eligible voice. Checking only for the absence of a row would pass if
# the whole scanner were deleted.
test_trivial_touch_is_not_blocking() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-trivial.txt" out
    make_numstat "$numstat" "$OVER_FILE" 1
    run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "file-length" "a trivial touch still reports the file (not silence)"
    assert_contains "$out" "pre-existing size" "the evidence names the size as pre-existing"
    assert_contains "$out" "not this PR" "the evidence says whose debt it is not"

    # The load-bearing assertion: the file-length row is LOW, never MEDIUM/HIGH.
    local row
    row="$(command printf '%s\n' "$out" | command grep -F 'file-length' || true)"
    assert_not_empty "$row" "a file-length row exists to check the certainty of"
    case "$row" in
        *"	LOW") : ;;
        *) _fail "trivial touch produced a blocking-eligible file-length row" \
            "A one-line touch to a pre-existing oversized file must be LOW/informational (AC4)." \
            "$row" ;;
    esac
}

# --- AC4: a diff that PUSHES a file over the threshold IS actionable ----------
# The counter-case. Without it the previous test passes trivially by having the
# scanner rate everything LOW — the gate-and-evidence-converge tautology.
test_crossing_the_threshold_is_actionable() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-cross.txt" out row
    # 600 added lines: prior = 640 - 600 = 40, comfortably under the 500 warning,
    # so this diff is what pushed it over.
    make_numstat "$numstat" "$OVER_FILE" 600
    run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "pushed it over" "the evidence says the diff crossed the threshold"
    row="$(command printf '%s\n' "$out" | command grep -F 'file-length' || true)"
    assert_not_empty "$row" "a file-length row exists"
    case "$row" in
        *"	LOW") _fail "a threshold-crossing diff was rated LOW" \
            "A diff that pushes a file over the review threshold must be blocking-eligible (MEDIUM/HIGH)." \
            "$row" ;;
        *) : ;;
    esac
}

# --- AC4: material growth on an already-over file is actionable ---------------
test_material_growth_is_actionable() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-material.txt" out row
    # 120 added: over the 50-line materiality floor, but prior (640-120=520) was
    # already over the 500 warning — so this is the "already over" arm, NOT the
    # crossing arm. Asserting the distinct evidence string keeps the two arms
    # from silently collapsing into one.
    make_numstat "$numstat" "$OVER_FILE" 120
    run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "already over before this diff" "the evidence names the already-over arm"
    row="$(command printf '%s\n' "$out" | command grep -F 'file-length' || true)"
    case "$row" in
        *"	MEDIUM") : ;;
        *) _fail "material growth on an already-over file was not MEDIUM" \
            "Adding 120 lines to an oversized file is this PR's business (AC4)." "$row" ;;
    esac
}

# --- the materiality floor is a real boundary, not decoration ----------------
# Pins REVIEW_GROWTH_MIN_ADDED as the thing that separates the two dispositions.
# Without this, removing the floor entirely would still pass every test above.
test_materiality_floor_is_honored() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-floor.txt" out
    make_numstat "$numstat" "$OVER_FILE" 10
    REVIEW_GROWTH_MIN_ADDED=5 run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "already over before this diff" \
        "lowering the floor below the added count promotes the row to actionable"

    REVIEW_GROWTH_MIN_ADDED=500 run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "pre-existing size" \
        "raising the floor above the added count demotes the row to informational"
}

# --- AC5: declining is preserved end-to-end ----------------------------------
# A long-but-cohesive file yields a RECORDED REASON, not silence and not a nag.
test_decline_records_a_reason() {
    local f="$WORKDIR/cohesive.py" list="$WORKDIR/cohesive-list.txt" out
    # One class, many methods: over threshold, but a single cohesive top-level
    # unit — the case where "split it" is the wrong advice.
    {
        command printf 'class OneBigThing:\n'
        i=0
        while [ "$i" -lt 320 ]; do
            command printf '    def m_%d(self):\n        return %d\n' "$i" "$i"
            i=$((i + 1))
        done
    } >"$f"
    command printf '%s\n' "$f" >"$list"

    local numstat="$WORKDIR/ns-decline.txt"
    make_numstat "$numstat" "$f" 1
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "decomposition-seam" "a declined file still emits a seam row"
    assert_contains "$out" "declined:" "the decline is explicit"
    assert_contains "$out" "single cohesive unit" "the decline names WHY it declined"
}

# --- .d.ts declines in the REVIEW lens too (#726) ----------------------------
# This lens gates its shape row on diff GROWTH (`crossed || material`), not on
# `seams == 0` the way the audit lens does. So the `.d.ts` suppression had to be
# stated here separately — `(crossed || material) && !is_decl_file(path)` — and
# that conjunct has NO audit-lens analog, which means
# tests/validate-decomposition-detectors.sh structurally cannot cover it.
#
# Nor can the parity corpus: it asserts sizing.py == sizing.sh, so dropping the
# guard from BOTH impls in one commit keeps every existing gate green
# ([[parity-gate-hides-shared-defect]] — same-output is not same-intent). This
# is the behavioral assertion that actually pins the intent.
test_declaration_file_declines_in_review_lens() {
    local f="$WORKDIR/api.d.ts" list="$WORKDIR/dts-list.txt"
    local numstat="$WORKDIR/ns-dts.txt" out i

    # A clusterable Api* family, large enough to be well over threshold, and
    # handed MATERIAL growth so the shape branch is the one it would otherwise
    # take. Without the guard this emits "split shape for ts: types/ dir ...".
    : >"$f"
    i=0
    while [ "$i" -lt 400 ]; do
        command printf 'export declare interface ApiThing%d {\n  id: string;\n}\n' "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 1200
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "declined: type declaration file — no runtime units to extract" \
        "review lens: a .d.ts declines with the declaration-file reason (#726)"
    assert_not_contains "$out" "split shape for" \
        "review lens: a .d.ts emits NO shape row despite material growth (#726)"

    # Case-insensitivity of the DECLINE PREDICATE, which both impls document as
    # load-bearing ("the same target must decide alike in every spelling") and
    # which nothing pinned behaviorally. Drop tolower()/.lower() from either
    # is_decl_file and this goes red.
    #
    # Asserted per-impl rather than through assert_parity, deliberately. A
    # mixed-case EXTENSION diverges between the two runtimes for an unrelated,
    # PRE-EXISTING reason: sizing.py's lang_of lowercases the extension before
    # the EXT_LANG lookup while the shell `case` matches literally, so `.D.TS`
    # segments as ts under python and as no-language under bash. That is not a
    # #726 defect — `.PY` vs `.py` diverges identically on the pre-#726 tree —
    # and it is filed separately. What IS #726's to hold is that the declaration
    # predicate itself decides alike in every spelling, and that holds in both
    # runtimes independently, which is what these two assertions check.
    local u="$WORKDIR/Weird.D.TS" ulist="$WORKDIR/uc-list.txt" uns="$WORKDIR/ns-uc.txt"
    command cp "$f" "$u"
    command printf '%s\n' "$u" >"$ulist"
    make_numstat "$uns" "$u" 1200
    run_scan "$ulist" "$uns"

    assert_contains "$SCAN_OUT" "declined: type declaration file — no runtime units to extract" \
        "review lens: .D.TS declines like .d.ts (case-insensitive, bash, #726)"
    if [ "$HAVE_PY" = "1" ]; then
        assert_contains "$SCAN_PY_OUT" "declined: type declaration file — no runtime units to extract" \
            "review lens: .D.TS declines like .d.ts (case-insensitive, python, #726)"
    fi

    # Counter-fixture, and it is what makes the assertions above non-vacuous: a
    # BYTE-IDENTICAL body under a plain .ts name takes the shape branch instead.
    # The path is the only variable — `declare` is kept here deliberately so the
    # contrast isolates the suffix predicate and nothing else. Without this pair,
    # a suppression firing on every ts file (or on nothing) would look the same.
    local g="$WORKDIR/plain.ts" glist="$WORKDIR/ts-list.txt" gns="$WORKDIR/ns-ts.txt"
    command cp "$f" "$g"
    command printf '%s\n' "$g" >"$glist"
    make_numstat "$gns" "$g" 1200
    run_scan "$glist" "$gns"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "split shape for ts: types/ dir split by domain" \
        "review lens: the same content as .ts DOES get the ts shape row (#726)"
    assert_not_contains "$out" "type declaration file" \
        "review lens: a plain .ts is not treated as a declaration file (#726)"

    # `.tsx` shares the ts language key, and that EXT_LANG/case arm was
    # otherwise asserted only by inspection — no scan drove a .tsx path.
    local x="$WORKDIR/widget.tsx" xlist="$WORKDIR/tsx-list.txt" xns="$WORKDIR/ns-tsx.txt"
    command cp "$f" "$x"
    command printf '%s\n' "$x" >"$xlist"
    make_numstat "$xns" "$x" 1200
    run_scan "$xlist" "$xns"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "split shape for ts: types/ dir split by domain" \
        "review lens: .tsx resolves to the ts language key like .ts (#726)"
}

# --- a whitespace-heavy diff cannot fake a threshold crossing ----------------
# `prior = production - added` compares two different units: numstat counts RAW
# insertions (blanks and comments included) while `production` excludes them. So
# the subtraction over-subtracts, `prior` errs LOW, and the error pushes toward
# the LOUDEST disposition — the opposite of what the code comment claimed.
#
# The fixture is a reformat bundled with a small real change: a file already far
# past the HIGH threshold receives ~900 blank lines and a handful of production
# lines. Before the clamp, `prior` went negative, `crossed` fired, and the
# scanner reported a HIGH "this diff pushed it over" against a file that was
# already 851 LOC — the exact case AC4 exists to keep quiet, reported in the
# loudest voice available.
#
# Asserts the EVIDENCE STRING, not merely the certainty: "already over before
# this diff" and "pushed it over" are the two arms in question, and a certainty
# check alone would pass if the row were demoted for some unrelated reason.
test_whitespace_heavy_diff_does_not_fake_a_crossing() {
    local f="$WORKDIR/reformat.py" list="$WORKDIR/reformat-list.txt" numstat="$WORKDIR/ns-reformat.txt"
    local out i
    : >"$f"
    i=0
    # ~856 production LOC — already well past the 800 py HIGH threshold.
    while [ "$i" -lt 428 ]; do
        command printf 'def u_%d(x):\n    return %d\n' "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    # ...plus 900 blank lines the reformat introduced.
    i=0
    while [ "$i" -lt 900 ]; do
        command printf '\n' >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 905

    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "already over before this diff" \
        "a whitespace-heavy diff on an already-oversized file takes the quiet arm"
    assert_not_contains "$out" "pushed it over" \
        "raw insertion count cannot manufacture a threshold crossing"
}

# --- an over-threshold file with no segmenter still gets a seam row ----------
# `.rb`/`.java`/`.c` are scanned (none are in SKIP_EXTS) but have no segmenter,
# so `lang` is empty. Gating the split-shape emit on a truthy `lang` dropped BOTH
# arms for such a file — the shape arm for want of a language, the decline arm
# for want of a quiet disposition — so an ACTIONABLE oversized file produced a
# file-length row and no decomposition-seam row at all, withholding from the
# review dimension the one thing it consumes.
test_unknown_language_still_emits_a_seam_row() {
    local f="$WORKDIR/big.rb" list="$WORKDIR/rb-list.txt" numstat="$WORKDIR/ns-rb.txt" out i
    : >"$f"
    i=0
    while [ "$i" -lt 700 ]; do
        command printf 'def unit_%d\n  %d\nend\n' "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 1500

    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "file-length" "an unsegmented language is still sized"
    assert_contains "$out" "decomposition-seam" \
        "an actionable file always yields a seam row, segmenter or not"
    assert_contains "$out" "sibling module" "the generic fallback names a real destination"
}

# --- renamed files keep their growth signal ----------------------------------
# `git diff --numstat` does NOT print a plain path for a renamed file. It prints
# the rename, in one of two shapes:
#
#     old.py => new.py          (whole path changed)
#     a/{x => y}/f.py           (one path segment changed)
#
# while `git diff --name-only` — the caller's file list — carries the plain
# post-rename path. An exact string match between the two therefore MISSES every
# renamed file: its added-count silently reads 0, `crossed`/`material` can never
# fire, and it is reported at the quiet LOW disposition no matter how much the
# diff actually added. A rename plus a large addition is exactly the case the
# size lens exists for, and it was the one guaranteed to stay silent.
#
# Both shapes are asserted, because they are resolved by DIFFERENT code paths
# (brace-splice vs after-the-arrow); a fixture for one proves nothing about the
# other. The assertion is on "pushed it over" rather than merely on some row
# being emitted — a row appears either way, and only the growth-graded evidence
# distinguishes a resolved rename from an unresolved one.
test_renamed_file_keeps_its_growth_signal() {
    setup_over_threshold
    local numstat="$WORKDIR/ns-rename.txt" out

    # Shape 1: whole path changed.
    command printf '600\t0\told-name.py => %s\n' "$OVER_FILE" >"$numstat"
    run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "pushed it over" \
        "a plain-arrow rename resolves to its post-rename path (growth preserved)"
    assert_not_contains "$out" "pre-existing size" \
        "a renamed file is not misread as untouched"

    # Shape 2: one path segment changed. Built from the fixture's own directory
    # so the spliced result is genuinely the file on disk, not a lookalike.
    local dir base
    dir="${OVER_FILE%/*}"
    base="${OVER_FILE##*/}"
    command printf '600\t0\t%s/{oldsub => }%s\n' "$dir" "$base" >"$numstat"
    run_scan "$LIST" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "pushed it over" \
        "a brace-form rename resolves to its post-rename path (growth preserved)"
}

# --- AC5: the OTHER decline reasons ------------------------------------------
# decline_reason() has four branches and only "single cohesive unit" was covered
# above. The remaining three are NOT protected by any other gate: unlike the
# loc-helpers/loc-measure regions, decline_reason is independently authored in
# sizing.py and sizing.sh (and again in check-decomposition), so a regression in
# one branch is invisible to the sentinel sync gate, and the ports-gate corpus
# contains no generated, majority-comment, or multi-unit-long fixture to catch it.
#
# Each case is engineered so exactly ONE branch can win, and each asserts the
# reason TEXT — the branches are ordered, so asserting merely "a decline was
# emitted" would pass with the arms permuted.
test_generated_file_decline_reason() {
    local f="$WORKDIR/gen.py" list="$WORKDIR/gen-list.txt" numstat="$WORKDIR/ns-gen.txt" out i
    {
        command printf '# Code generated by protoc. DO NOT EDIT.\n'
        i=0
        while [ "$i" -lt 320 ]; do
            command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i"
            i=$((i + 1))
        done
    } >"$f"
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 1
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "generated file" "a generated marker wins over every later branch"
    assert_not_contains "$out" "single cohesive unit" "the generated branch is not confused with the cohesive one"
}

test_majority_comment_decline_reason() {
    local f="$WORKDIR/prose.py" list="$WORKDIR/prose-list.txt" numstat="$WORKDIR/ns-prose.txt" out i
    # >2 units (so the cohesive branch cannot win) and >=50% comment lines.
    : >"$f"
    i=0
    while [ "$i" -lt 320 ]; do
        command printf '# explanatory line %d\n# second explanatory line %d\ndef unit_%d(x):\n    return x + %d\n' \
            "$i" "$i" "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 1
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "majority prose/comment" "a half-comment file declines as documentation, not logic"
}

test_mutually_referential_decline_reason() {
    local f="$WORKDIR/mutual.py" list="$WORKDIR/mutual-list.txt" numstat="$WORKDIR/ns-mutual.txt" out i
    # Many units, few comments, no generated marker — the fallback branch.
    : >"$f"
    i=0
    while [ "$i" -lt 320 ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 1
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "no low-coupling seam found" "a long multi-unit file falls through to the seam-less reason"
    assert_not_contains "$out" "majority prose/comment" "a code-heavy file is not called documentation"
}

# --- the markdown arm --------------------------------------------------------
# The language the surrounding prose calls the case that "matters most" had ZERO
# coverage here: md thresholds (700/1000), heading-based segmentation and the
# progressive-disclosure shape were all unexercised. Prose is this repo's largest
# and fastest-churning surface (#589), so an unsized markdown arm is the most
# consequential silent gap the scanner could have.
test_markdown_arm_is_sized_and_shaped() {
    local f="$WORKDIR/big.md" list="$WORKDIR/md-list.txt" numstat="$WORKDIR/ns-md.txt" out i
    : >"$f"
    i=0
    while [ "$i" -lt 400 ]; do
        command printf '## Section %d\n\nBody line for section %d.\n' "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 900
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "big.md" "markdown is sized, not skipped as a data file"
    assert_contains "$out" "split shape for md" "the seam row names the markdown arm"
    assert_contains "$out" "progressive disclosure" "markdown guidance is progressive disclosure (#589)"
    assert_contains "$out" "one-line pointer" "the guidance says to leave a pointer behind"
}

# --- AC7: split guidance is language-shaped ----------------------------------
# The advice must match how the segmenters already work, or it is generic noise.
test_split_shape_is_language_shaped() {
    local f="$WORKDIR/grow.sh" list="$WORKDIR/sh-list.txt" numstat="$WORKDIR/ns-sh.txt" out
    : >"$f"
    i=0
    while [ "$i" -lt 400 ]; do
        command printf 'fn_%d() {\n    echo %d\n}\n' "$i" "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "$f" >"$list"
    make_numstat "$numstat" "$f" 900
    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "split shape for sh" "the seam row names the language"
    assert_contains "$out" "sourced fragment" "shell guidance is the repo's split-suite convention (#564)"
    assert_not_contains "$out" "barrel index.ts" "shell guidance is not the JS shape"
}

# --- every SPLIT_SHAPE arm is reachable and distinct --------------------------
# The table has six arms and only `sh` and `md` are asserted above. An arm is
# cheap to get wrong (a copy-paste leaving two languages sharing one string) and
# nothing else would notice. Asserting each language gets ITS OWN string also
# pins distinctness, which a per-arm "contains something" check would not.
test_every_split_shape_arm_is_language_specific() {
    local ext lang expect f list numstat out i
    # ext:lang:expected-substring — one entry per SPLIT_SHAPE arm.
    for entry in \
        "py:py:__init__.py" \
        "js:js:barrel index.ts" \
        "ts:ts:types/ dir split by domain" \
        "rs:rs:mod.rs" \
        "go:go:same package"; do
        ext="${entry%%:*}"
        lang="${entry#*:}"
        lang="${lang%%:*}"
        expect="${entry##*:}"

        f="$WORKDIR/shape.$ext"
        list="$WORKDIR/shape-list.txt"
        numstat="$WORKDIR/ns-shape.txt"
        : >"$f"
        i=0
        # 500 units x 2-3 lines clears even the strictest per-language pair.
        while [ "$i" -lt 500 ]; do
            case "$ext" in
                py) command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$f" ;;
                js) command printf 'function unit_%d(x) {\n  return x + %d;\n}\n' "$i" "$i" >>"$f" ;;
                # TYPE-level units (#726), so the ts arm is reached through the
                # forms only its own segmenter matches — a function fixture here
                # would be caught by the js arm too and prove nothing about ts.
                ts) command printf 'export interface Unit%d {\n  a: string;\n}\n' "$i" >>"$f" ;;
                rs) command printf 'fn unit_%d() {\n    let _ = %d;\n}\n' "$i" "$i" >>"$f" ;;
                go) command printf 'func unit_%d() int {\n    return %d\n}\n' "$i" "$i" >>"$f" ;;
            esac
            i=$((i + 1))
        done
        command printf '%s\n' "$f" >"$list"
        make_numstat "$numstat" "$f" 1200
        run_scan "$list" "$numstat"
        assert_parity
        out="$SCAN_OUT"
        assert_contains "$out" "split shape for ${lang}" "the ${lang} arm names its language"
        assert_contains "$out" "$expect" "the ${lang} arm gives ${lang}-shaped guidance"
    done
}

# --- per-language thresholds actually differ ---------------------------------
# A 500-line Rust file and a 500-line shell script are not the same claim. This
# pins that the per-language table is CONSULTED, not merely present: the same
# production LOC must be over the Rust threshold and under the shell one.
test_per_language_thresholds_differ() {
    local rs="$WORKDIR/mid.rs" sh="$WORKDIR/mid.sh"
    local list="$WORKDIR/lang-list.txt" out
    # 600 production LOC each (200 units x 3 lines): over the Rust 400 warning,
    # under the shell 700 warning. The size is chosen to sit BETWEEN the two
    # per-language pairs — that gap is the whole property under test, so a
    # fixture over both (or under both) would pass with the table gutted.
    : >"$rs"
    : >"$sh"
    i=0
    while [ "$i" -lt 200 ]; do
        command printf 'fn unit_%d() {\n    let _ = %d;\n}\n' "$i" "$i" >>"$rs"
        command printf 'fn_%d() {\n    echo %d\n}\n' "$i" "$i" >>"$sh"
        i=$((i + 1))
    done
    command printf '%s\n%s\n' "$rs" "$sh" >"$list"
    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "mid.rs" "the Rust file is over its (stricter) 400 threshold"
    assert_not_contains "$out" "mid.sh" "the same size shell file is under its 700 threshold"
}

# --- a file UNDER threshold stays silent -------------------------------------
# The counter-fixture. Without it every assertion above could pass by emitting a
# row for literally every file.
test_small_file_stays_silent() {
    local f="$WORKDIR/small.py" list="$WORKDIR/small-list.txt" out
    make_py_file "$f" 10
    command printf '%s\n' "$f" >"$list"
    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"
    assert_equals "" "$out" "a small file produces no rows at all"
}

# --- #724: classified prose is sized by file TYPE, not as a generic doc -------
# make_md_file PATH NLINES — a markdown file of NLINES prose lines.
make_md_file() {
    local path="$1" nlines="$2" i
    : >"$path"
    i=0
    while [ "$i" -lt "$nlines" ]; do
        command printf 'Prose line %d of the document.\n' "$i" >>"$path"
        i=$((i + 1))
    done
}

# THE HEADLINE FIXTURE (#724). Before this issue an agent definition was sized by
# the generic md pair (700/1000), so a ~500-line agents/*.md — well over its own
# 250/400 budget, and flagged HIGH by the audit lens — passed the review lens in
# total silence. The measured miss was plugins/review-audit/agents/checker.md at
# 580 lines: `ai-file-bloat ... HIGH` on the audit lens, no output at all here.
#
# Asserted on the FILE-TYPE LABEL, not merely on "some row appeared": the whole
# defect was a classification fork, so a row that fires under the wrong label
# (or under the generic file-length category) has not fixed it.
test_agent_md_is_classified_by_type() {
    local agent_dir="$WORKDIR/prose/agents" out
    command mkdir -p "$agent_dir"
    local agent_md="$agent_dir/checker.md"
    make_md_file "$agent_md" 500
    local list="$WORKDIR/prose-agent.txt"
    command printf '%s\n' "$agent_md" >"$list"

    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "ai-file-bloat" "an agent definition emits ai-file-bloat, not a generic size row"
    assert_contains "$out" "agent definition" "the row names the FILE TYPE the audit lens would name"
    assert_contains "$out" "(>400)" "the agent HIGH budget (400) is the one applied, not the md 1000"
}

# --- #724/#701: exactly ONE size verdict per classified file ------------------
# SIZED AT 900 LINES ON PURPOSE, and that is the whole point of this fixture.
#
# The obvious version of this assertion — checking `file-length` is absent from
# the 500-line agent fixture above — is a TEST THAT CANNOT FAIL. At 500 lines the
# file is under the generic md warning of 700, so the production-LOC path returns
# early of its own accord: removing the one-verdict guard entirely changes
# nothing, and the assertion passes with AND without the code it claims to pin.
# (Found by the mutation round — dropping the guard left every #724 test green.)
#
# At 900 lines the file is over BOTH its own 250/400 agent budget and the generic
# 700 md warning, so the two paths genuinely compete and the guard is the only
# thing suppressing the second row.
test_classified_prose_gets_exactly_one_verdict() {
    local agent_dir="$WORKDIR/one-verdict/agents" out
    command mkdir -p "$agent_dir"
    local agent_md="$agent_dir/huge.md"
    make_md_file "$agent_md" 900
    local list="$WORKDIR/one-verdict.txt"
    command printf '%s\n' "$agent_md" >"$list"

    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    # Both thresholds are genuinely exceeded — without this the test could pass
    # by the file being under one of them, which is the trap described above.
    assert_contains "$out" "ai-file-bloat" "the file is over its per-type budget"
    assert_true "[ 900 -gt 700 ]" "the fixture also exceeds the generic md warning (both paths compete)"

    assert_not_contains "$out" "file-length" \
        "a classified prose file gets its bloat row INSTEAD of file-length, never both (#701)"
}

# --- #724: arm ORDER is load-bearing -----------------------------------------
# The arms are sequential and `*/skills/*/*.md` MUST stay below
# `*/skills/*/SKILL.md`. Hoisting it swallows every SKILL.md into the looser
# companion budget — silently, since both still emit a plausible-looking row.
#
# Both files are the SAME LENGTH on purpose: the only variable is the path, so a
# difference in the reported budget can only come from classification. A fixture
# with two different lengths would pass even with the arms reversed.
test_skill_and_companion_arms_stay_ordered() {
    local skill_dir="$WORKDIR/prose/skills/x" out
    command mkdir -p "$skill_dir"
    make_md_file "$skill_dir/SKILL.md" 520
    make_md_file "$skill_dir/companion.md" 520
    local list="$WORKDIR/prose-skill.txt"
    command printf '%s\n%s\n' "$skill_dir/SKILL.md" "$skill_dir/companion.md" >"$list"

    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    local skill_row companion_row
    skill_row="$(command printf '%s\n' "$out" | command grep -F '/SKILL.md' || true)"
    companion_row="$(command printf '%s\n' "$out" | command grep -F '/companion.md' || true)"

    assert_not_empty "$skill_row" "the SKILL.md is reported"
    assert_not_empty "$companion_row" "the companion is reported"
    assert_contains "$skill_row" "skill definition" "SKILL.md classifies as a skill definition"
    assert_contains "$skill_row" "(>500)" "SKILL.md gets the 300/500 SKILL budget"
    assert_contains "$companion_row" "skill companion" "a sibling .md classifies as a companion"
    assert_contains "$companion_row" "(>400)" "the companion gets the looser 400/650 budget"
}

# --- #724: prose keeps the review lens's GROWTH disposition (AC4) -------------
# The counter-case to the headline fixture. Without it, that test passes just as
# well from a change that made every classified prose file blocking — importing
# the audit lens's flat HIGH/MEDIUM grading wholesale, which on a per-PR gate
# would block a one-line touch to a pre-existing 580-line agent file. That is the
# outcome AC4 exists to prevent, on the file type most likely to be brushed
# against, and it is how the lens gets turned off.
#
# Asserted on CERTAINTY, not on silence: the scanner is supposed to speak here.
test_prose_trivial_touch_is_not_blocking() {
    local agent_dir="$WORKDIR/prose-growth/agents" out row
    command mkdir -p "$agent_dir"
    local agent_md="$agent_dir/big.md"
    make_md_file "$agent_md" 500
    local list="$WORKDIR/prose-growth.txt" numstat="$WORKDIR/ns-prose-trivial.txt"
    command printf '%s\n' "$agent_md" >"$list"
    make_numstat "$numstat" "$agent_md" 1

    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "pre-existing size" "the evidence names the size as pre-existing"
    row="$(command printf '%s\n' "$out" | command grep -F 'ai-file-bloat' || true)"
    assert_not_empty "$row" "a bloat row exists to check the certainty of"
    case "$row" in
        *"	LOW") : ;;
        *) _fail "a trivial touch to an over-budget prose file was blocking-eligible" \
            "Classification is shared with the audit lens; the growth DISPOSITION is not (#724/AC4)." \
            "$row" ;;
    esac

    # And the counter-direction: a diff that pushes it over IS actionable, so the
    # LOW above cannot be satisfied by rating everything LOW.
    local cross="$WORKDIR/ns-prose-cross.txt"
    make_numstat "$cross" "$agent_md" 400
    run_scan "$list" "$cross"
    assert_parity
    out="$SCAN_OUT"
    assert_contains "$out" "pushed it over" "a diff that crosses the budget says so"
    row="$(command printf '%s\n' "$out" | command grep -F 'ai-file-bloat' || true)"
    case "$row" in
        *"	LOW") _fail "a budget-crossing prose diff was rated LOW" \
            "Crossing a prose budget because of this diff must be blocking-eligible." \
            "$row" ;;
        *) : ;;
    esac
}

# --- #724: EVERY remaining bloat arm reaches this lens's own disposition ------
# The agent/SKILL/companion arms are covered above; this drives the other four —
# memory index, memory concept, CLAUDE.md, and docs.
#
# WHY THEY NEED THEIR OWN CASE HERE. They are tested against the AUDIT lens in
# validate-decomposition-detectors.sh, but `bundle_kind`/`_bundle_root` are brand
# new to sizing.{py,sh} in #724 — before it this lens had no classification at
# all. So an arm's thresholds could be right in patterns.py and still reach the
# review lens's growth-aware wrapper wrongly, and no gate would see it.
#
# The `documentation` arm carries the extra property: it is the ONE arm whose
# category is `doc-file-bloat` rather than `ai-file-bloat` (the #222 split). A
# wrapper that hardcoded the category would pass every other arm and silently
# reclassify docs pages.
test_every_bloat_arm_reaches_the_review_lens() {
    local root="$WORKDIR/arms" out
    command mkdir -p "$root/.claude/memory" "$root/sub" "$root/docs"
    make_md_file "$root/.claude/memory/MEMORY.md" 300 # >250 index high
    make_md_file "$root/.claude/memory/lesson.md" 400 # >350 concept high
    make_md_file "$root/sub/CLAUDE.md" 700            # >600 CLAUDE.md high
    make_md_file "$root/docs/guide.md" 900            # >800 doc high
    local list="$WORKDIR/arms.txt"
    command printf '%s\n%s\n%s\n%s\n' \
        "$root/.claude/memory/MEMORY.md" "$root/.claude/memory/lesson.md" \
        "$root/sub/CLAUDE.md" "$root/docs/guide.md" >"$list"

    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "memory index" "the memory-index arm reaches this lens"
    assert_contains "$out" "memory concept" "the memory-concept arm reaches this lens"
    assert_contains "$out" "CLAUDE.md exceeds" "the CLAUDE.md arm reaches this lens"
    assert_contains "$out" "documentation exceeds" "the docs arm reaches this lens"

    # The category split (#222): docs are doc-file-bloat, everything else is
    # ai-file-bloat. Asserted on the docs ROW, not on the whole output, which
    # would pass merely because some other row carried the category.
    local docs_row
    docs_row="$(command printf '%s\n' "$out" | command grep -F '/docs/guide.md' || true)"
    assert_not_empty "$docs_row" "the docs page is reported"
    assert_contains "$docs_row" "doc-file-bloat" "a docs page keeps doc-file-bloat, not ai-file-bloat"
    local mem_row
    mem_row="$(command printf '%s\n' "$out" | command grep -F '/MEMORY.md' || true)"
    assert_contains "$mem_row" "ai-file-bloat" "a memory index stays ai-file-bloat"
}

# --- #724: the `material` disposition on CLASSIFIED prose --------------------
# test_material_growth_is_actionable covers this branch on the production-LOC
# path only. scan_prose (and the awk `b_material` arm) carry their own copy of
# the logic, so the branch is genuinely separate code — an already-over prose
# file taking material growth without crossing from under-budget.
test_prose_material_growth_is_actionable() {
    local root="$WORKDIR/prose-material/agents" out row
    command mkdir -p "$root"
    local agent_md="$root/big.md"
    make_md_file "$agent_md" 700
    local list="$WORKDIR/prose-material.txt" numstat="$WORKDIR/ns-prose-material.txt"
    command printf '%s\n' "$agent_md" >"$list"
    # 60 added: over the 50 materiality floor, but prior (700-60=640) is still
    # far above the 250 warn, so this is `material`, NOT `crossed`.
    make_numstat "$numstat" "$agent_md" 60

    run_scan "$list" "$numstat"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "already over before this diff" "the evidence takes the material wording"
    assert_not_contains "$out" "pushed it over" "material growth is not reported as a crossing"
    row="$(command printf '%s\n' "$out" | command grep -F 'ai-file-bloat' || true)"
    assert_not_empty "$row" "a bloat row exists"
    case "$row" in
        *"	MEDIUM") : ;;
        *) _fail "material growth on an over-budget prose file was not MEDIUM" \
            "Material growth is blocking-eligible at MEDIUM, like the LOC path (#724/AC4)." \
            "$row" ;;
    esac
}

# --- #724: an UNCLASSIFIED markdown file still takes the generic path ---------
# The scoping counter-case. Classification must not swallow all markdown: a .md
# that matches no bloat arm (not an agent, skill, companion, CLAUDE.md, doc or
# memory file) still belongs to the production-LOC lens at the md thresholds.
# Without this, deleting the `spec is None` fall-through would go unnoticed.
test_unclassified_markdown_keeps_the_loc_path() {
    local plain="$WORKDIR/plain-notes.md" out
    make_md_file "$plain" 900
    local list="$WORKDIR/plain-md.txt"
    command printf '%s\n' "$plain" >"$list"

    run_scan "$list"
    assert_parity
    out="$SCAN_OUT"

    assert_contains "$out" "file-length" "an unclassified .md still gets the generic file-length row"
    assert_contains "$out" "production LOC" "and is measured in production LOC, not total lines"
    assert_not_contains "$out" "ai-file-bloat" "an unclassified .md is not forced into a bloat category"
}

# --- the TSV contract is exactly five tab-separated columns ------------------
# The language boundary every check-* skill and all three parity gates depend on.
test_tsv_contract_is_five_columns() {
    setup_over_threshold
    local out line cols
    run_scan "$LIST"
    assert_parity
    out="$SCAN_OUT"
    assert_not_empty "$out" "there is output to check the shape of"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cols="$(command printf '%s' "$line" | command awk -F'\t' '{print NF}')"
        assert_equals "5" "$cols" "row has exactly 5 tab-separated columns"
    done <<EOF
$out
EOF
}

# --- usage + missing-file contract -------------------------------------------
# Mirrors what validate-prescans.sh pins for every other scanner entry point.
test_usage_contract() {
    local rc=0
    command bash "$SIZING_SH" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "no argument exits 1"

    rc=0
    command bash "$SIZING_SH" "$WORKDIR/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing file list exits 1"

    local empty="$WORKDIR/empty.txt" out
    : >"$empty"
    rc=0
    out="$(command bash "$SIZING_SH" "$empty" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "an empty file list exits 0"
    assert_equals "" "$out" "an empty file list emits nothing"
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
    command cp "$PLAN_SH" "$iso/"
    setup_near_budget

    command bash "$iso/plan-lens.sh" "$PLAN_LIST" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" \
        "with no sibling sizing engine the scanner exits 2, NOT 0-with-no-findings"
}

test_plan_lens_usage_contract() {
    local rc=0
    command bash "$PLAN_SH" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "plan-lens: no argument exits 1"

    rc=0
    command bash "$PLAN_SH" "$WORKDIR/does-not-exist.txt" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "plan-lens: a missing file list exits 1"

    local empty="$WORKDIR/empty-plan.txt" out
    : >"$empty"
    rc=0
    out="$(command bash "$PLAN_SH" "$empty" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "plan-lens: an empty file list exits 0"
    assert_equals "" "$out" "plan-lens: an empty file list emits nothing"
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

run_test test_trivial_touch_is_not_blocking "AC4: a one-line touch to an oversized file is informational, never blocking"
run_test test_crossing_the_threshold_is_actionable "AC4: a diff that pushes a file over the threshold is actionable"
run_test test_material_growth_is_actionable "AC4: material growth on an already-over file is actionable"
run_test test_materiality_floor_is_honored "AC4: REVIEW_GROWTH_MIN_ADDED is a real boundary"
run_test test_decline_records_a_reason "AC5: a long-but-cohesive file yields a recorded decline reason"
run_test test_declaration_file_declines_in_review_lens "review lens: a .d.ts declines and gets no shape row, a plain .ts does (#726)"
run_test test_whitespace_heavy_diff_does_not_fake_a_crossing "A whitespace-heavy diff cannot fake a threshold crossing"
run_test test_unknown_language_still_emits_a_seam_row "An over-threshold file with no segmenter still gets a seam row"
run_test test_renamed_file_keeps_its_growth_signal "A renamed file keeps its growth signal (both numstat rename shapes)"
run_test test_generated_file_decline_reason "AC5: a generated file declines as generated"
run_test test_majority_comment_decline_reason "AC5: a majority-comment file declines as documentation"
run_test test_mutually_referential_decline_reason "AC5: a long multi-unit file declines as seam-less"
run_test test_markdown_arm_is_sized_and_shaped "The markdown arm is sized and gets progressive-disclosure guidance (#589)"
run_test test_split_shape_is_language_shaped "AC7: split guidance matches the file's language"
run_test test_every_split_shape_arm_is_language_specific "AC7: every SPLIT_SHAPE arm is reachable and language-specific"
run_test test_per_language_thresholds_differ "Per-language thresholds are consulted, not merely present"
run_test test_agent_md_is_classified_by_type "#724: an agent definition is sized by its own budget, not as a generic doc"
run_test test_classified_prose_gets_exactly_one_verdict "#724/#701: a classified prose file gets exactly one size verdict"
run_test test_skill_and_companion_arms_stay_ordered "#724: SKILL.md and its companion get different budgets (arm order)"
run_test test_prose_trivial_touch_is_not_blocking "#724: prose keeps the growth disposition (AC4 holds for classified files)"
run_test test_every_bloat_arm_reaches_the_review_lens "#724: every bloat arm (memory/CLAUDE.md/docs) reaches the review lens"
run_test test_prose_material_growth_is_actionable "#724: material growth on classified prose is MEDIUM/actionable"
run_test test_unclassified_markdown_keeps_the_loc_path "#724: an unclassified .md still takes the production-LOC path"
run_test test_small_file_stays_silent "A file under threshold produces no rows"
run_test test_tsv_contract_is_five_columns "Output honors the 5-column TSV contract"
run_test test_usage_contract "Usage / missing-file / empty-list contract"
run_test test_plan_lens_headroom_fires_on_projection "#756 AC2: an under-budget file whose projection crosses emits size-headroom"
run_test test_plan_lens_small_estimate_stays_silent "#756 AC2: the same file with a small estimate stays silent (estimate is the variable)"
run_test test_plan_lens_ample_headroom_stays_silent "#756: a projection that stays under budget is silent (distinct guard from the floor)"
run_test test_plan_lens_headroom_floor_is_honored "#756: PLAN_HEADROOM_MIN_ESTIMATE is a real boundary"
run_test test_plan_lens_already_over_is_raised_regardless "#756 AC3: an already-over file is raised regardless of estimate"
run_test test_plan_lens_without_estimates_is_informational "#756 AC4: no sidecar -> informational, and no headroom rows"
run_test test_plan_lens_distinguishes_zero_from_absent "#756: a sidecar naming no growth reads differently from no sidecar"
run_test test_plan_lens_classifies_prose_by_type "#756: prose classification reaches the plan lens (#724 does not regress)"
run_test test_plan_lens_accepts_numstat_shape "#756 AC1: the sidecar accepts a real numstat file and is rename-aware"
run_test test_plan_lens_fails_loud_without_engine "#756: no LOC engine exits 2, never 0-with-no-findings"
run_test test_plan_lens_usage_contract "#756: plan-lens usage / missing-file / empty-list contract"
run_test test_measure_mode_does_not_disturb_review_output "#756 AC6: the review lens is unchanged by the measure-mode seam"

generate_report
