#!/usr/bin/env bash
# Shared-scanner drift gate (issues #89, #132, #133, #609, #695).
#
# Pre-scan scripts living in SEPARATE, independently-installed plugins share
# regions of logic by DELIBERATE duplication. Four such PAIRS are pinned here:
#
#   check-code-health/patterns.sh   <-> ship-issue/pre-review-gates.sh
#   loop-make-it-tested/patterns.sh <-> ship-issue/pre-review-gates.sh   (#609)
#   check-decomposition/patterns.sh <-> ship-issue/sizing.sh             (#695)
#   check-decomposition/patterns.py <-> ship-issue/sizing.py             (#730)
#
# The third pair shares the production-LOC ENGINE — the per-language
# comment/test/blank exclusion rules that decide what "production LOC" means —
# between the audit lens and the per-PR review lens. Its regions carry AWK source
# rather than bash, which works unchanged because nothing in extract_shared or
# normalize is language-aware; the tamper fixtures below keep that from being an
# untested assumption.
#
# The FOURTH pair is the same engine's PYTHON primaries — the halves that
# actually execute whenever a python3>=3.11 is present, i.e. nearly always. Until
# #730 only the awk fallbacks were pinned, so the two Python copies could drift
# freely and every gate stayed green: validate-python-ports.sh compares each
# patterns.py to ITS OWN patterns.sh sibling and never one plugin's Python to
# another's. Same-output parity WITHIN a pair cannot see a divergence ACROSS
# pairs.
#
# ---------------------------------------------------------------------------
# PYTHON REGIONS: MODULE-TOP-LEVEL DEFINITIONS ONLY.
#
# `normalize` below strips leading whitespace. In awk and bash that is free —
# indentation is not semantic, and the copies genuinely nest at different depths.
# In PYTHON INDENTATION IS SEMANTIC, so the strip can hide a real divergence:
#
#     def f():          def f():
#         if x:         if x:
#             return 1  return 1
#
# Those two bodies normalize to identical text. The first is valid and the second
# is a SyntaxError — and a subtler pair (a `return` inside vs. outside a loop)
# would be two different working behaviors comparing equal.
#
# The rule that closes this: a `# >>> shared:*-py` region contains only
# COLUMN-ZERO definitions — `def`s, classes, module-level table literals — never
# an indented fragment of a function body. Every line's canonical indent is then
# already 0 relative to the region, so the strip removes nothing meaningful, and
# an indentation change INSIDE a shared def still alters the line sequence. Both
# copies are also parsed by Python itself on every run, so a region that violated
# the rule would fail loudly rather than silently compare equal.
# ---------------------------------------------------------------------------
#
# They cannot share a sourced library: CLAUDE_PLUGIN_ROOT is plugin-scoped, the
# plugins declare no dependency on each other, and a user may install `workflow`
# without `review-audit` or `dev-core`. So the shared logic must physically exist
# in both halves of each pair.
#
# Each shared region is bracketed by matching sentinel comments, e.g.:
#
#   # >>> shared:<region> ...
#   <shared code>
#   # <<< shared:<region>
#
# This gate is PARAMETERIZED over a list of (canonical, duplicate, regions)
# triples (SHARED_PAIRS below). For each region of each pair it extracts both
# copies, normalizes each to its ordered sequence of non-blank, trimmed lines,
# and asserts the sequences are identical. Trimming leading whitespace is
# deliberate: the copies nest the regions at different indent depths (inside a
# `while`/`if` in one file, at top level or inside a function in the other), so
# the bodies are byte-identical only after indentation is stripped — the
# regexes, evidence strings, AND their order are the invariant. The comparison
# is an ordered multiset (NOT `sort -u`): deduplicating or sorting would let a
# duplicated or reordered line slip through undetected.
#
# A region's sentinels bracket CODE, not the doc comment above it: a copy's
# leading prose legitimately differs per plugin (the py-public-symbols pair is
# the live example). Comments INSIDE a region are compared like any other line.
#
# Synthetic tamper checks prove the detector fires (mirrors the negative-fixture
# discipline of tests/validate-template-sync.sh, the exemplar for this gate).
#
# Pure bash + coreutils; no node/jq. Full /usr/bin/* paths per project shell
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The file pairs pinned by this gate, one per line:
#
#   <canonical>|<duplicate>|<space-separated region names>
#
# Each of the first two fields is a MEMBER: a `+`-joined list of paths whose
# regions reassemble in list order (#772). A single path is the one-element
# list, which is why most entries below read as plain paths. See the
# MULTI-FILE PAIR MEMBERS block above for why the order is explicit.
#
# Paths are repo-relative (joined to $REPO_ROOT at use) so the entries stay
# readable and failure messages can print the short form. Pipe-delimited fields
# in an indexed array rather than an associative one: bash 3.2 (stock macOS) has
# no `declare -A`, and a pair needs three fields anyway.
#
# Add a region name to a pair's third field when a new `# >>> shared:<name>`
# block is introduced in both of that pair's files; add a whole line when a new
# duplicated-logic pair appears; append `+<path>` to a member when that side's
# regions grow into a new sibling module.
SHARED_PAIRS=(
    "plugins/review-audit/skills/check-code-health/patterns.sh|plugins/workflow/skills/ship-issue/pre-review-gates.sh|debug-print-scan debugger-scan is-test-file yaml-list-parser"
    "plugins/dev-core/skills/loop-make-it-tested/patterns.sh|plugins/workflow/skills/ship-issue/pre-review-gates.sh|py-public-symbols"
    "plugins/review-audit/skills/check-decomposition/patterns.sh|plugins/workflow/skills/ship-issue/sizing.sh|loc-helpers-awk loc-measure-awk bloat-config bloat-spec split-shape-awk unit-segmenters-awk bundle-seam-awk"
    "plugins/workflow/skills/ship-issue/sizing.sh|plugins/workflow/skills/ship-issue/split-verify.sh|unit-segmenters-awk"
    "plugins/review-audit/skills/check-decomposition/loc_engine.py+plugins/review-audit/skills/check-decomposition/prose_spec.py|plugins/workflow/skills/ship-issue/loc_engine.py+plugins/workflow/skills/ship-issue/prose_spec.py|loc-tables-py loc-helpers-py loc-unit-py loc-measure-py bloat-spec-py split-shape-py bundle-seam-py"
)

# The Python pair's regions, in the order they appear above. Used by the
# per-region tamper fixture so adding a region to SHARED_PAIRS without a tamper
# case is caught rather than silently unproven (#730).
#
# NOT every shared symbol is listed: UNIT_NOUN, TOKEN_RE and _glob stay
# audit-lens-only on purpose. Copying them into sizing.py to make the files look
# more alike would add lookups nothing there reads — deliberate duplication is
# only worth its cost for logic BOTH lenses execute.
PY_REGIONS="loc-tables-py loc-helpers-py loc-unit-py loc-measure-py bloat-spec-py split-shape-py bundle-seam-py"

# Pair-specific paths used by the targeted tests below (the language-arm shape
# check and the two tamper fixtures). Kept as consts so a path edit above is a
# one-line change here too.
HEALTH_PATTERNS="$REPO_ROOT/plugins/review-audit/skills/check-code-health/patterns.sh"
TESTED_PATTERNS="$REPO_ROOT/plugins/dev-core/skills/loop-make-it-tested/patterns.sh"
PRE_REVIEW_GATES="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"
DECOMP_PATTERNS="$REPO_ROOT/plugins/review-audit/skills/check-decomposition/patterns.sh"
SIZING="$REPO_ROOT/plugins/workflow/skills/ship-issue/sizing.sh"
SPLIT_VERIFY="$REPO_ROOT/plugins/workflow/skills/ship-issue/split-verify.sh"
# The Python pair's two MEMBERS (#772) — `+`-joined file lists, not single
# paths. Since the split, no single file holds every shared Python region: the
# LOC engine and the prose spec live in sibling modules of each entry scanner.
# Every consumer below therefore goes through extract_shared_multi; a bare
# extract_shared against one of these would find the region in one file and
# nothing in the other, which is the silent-empty failure this issue exists to
# prevent.
DECOMP_PATTERNS_PY="$REPO_ROOT/plugins/review-audit/skills/check-decomposition/loc_engine.py+$REPO_ROOT/plugins/review-audit/skills/check-decomposition/prose_spec.py"
SIZING_PY="$REPO_ROOT/plugins/workflow/skills/ship-issue/loc_engine.py+$REPO_ROOT/plugins/workflow/skills/ship-issue/prose_spec.py"

test_suite "shared scanner sync (#89/#132/#133/#609)"

# extract_shared FILE REGION — the lines strictly between the sentinel comments
# for REGION. The sentinel lines themselves are excluded: their text names the
# *other* file, so it differs between copies and must not be compared.
#
# EVERY sentinel line is dropped, not just this region's. Regions may NEST — a
# subset of one region can itself be shared with a different file, which is the
# case for `unit-segmenters-awk` sitting inside `loc-helpers-awk` (#695). An
# inner sentinel is a comment naming a third file, so it is present in one copy
# of the outer region and absent from the other; comparing it would report drift
# on two copies that are in fact identical code.
extract_shared() {
    command awk -v region="$2" '
        index($0, "# >>> shared:" region) { in_region = 1; next }
        index($0, "# <<< shared:" region) { in_region = 0 }
        in_region && index($0, "# >>> shared:") { next }
        in_region && index($0, "# <<< shared:") { next }
        in_region { print }
    ' "$1"
}

# ---------------------------------------------------------------------------
# MULTI-FILE PAIR MEMBERS (#772).
#
# A pair member is a `+`-joined LIST of paths, not a single path. A region's
# lines may then live in several files of one member, reassembled by
# concatenating each file's extract IN LIST ORDER.
#
#   plugins/.../sizing.py+plugins/.../loc_engine.py+plugins/.../prose_spec.py
#
# A single-path member is the degenerate one-element list, so every entry
# written before this change keeps working verbatim.
#
# WHY A LIST AND NOT A DIRECTORY. The reassembly order is part of the contract —
# two members whose regions concatenate in different orders are NOT the same
# region, and a comparison that sorted or globbed the files would silently
# accept a reordering. A directory glob would also pick up a newly-added file
# nobody registered. The list is explicit, ordered, and reviewable in the diff.
#
# `+` is safe as the delimiter: `|` already separates the three pair fields,
# spaces already separate region names, and no path in this repo contains `+`.
# ---------------------------------------------------------------------------

# split_member MEMBER — the member's paths, one per line, in list order.
# Pure parameter expansion (bash 3.2: no `mapfile`, no `readarray`).
split_member() {
    local rest="$1" part
    while [ -n "$rest" ]; do
        case "$rest" in
            *+*)
                part="${rest%%+*}"
                rest="${rest#*+}"
                ;;
            *)
                part="$rest"
                rest=""
                ;;
        esac
        [ -n "$part" ] && printf '%s\n' "$part"
    done
}

# member_abs MEMBER — MEMBER with every repo-relative path joined to $REPO_ROOT,
# re-joined with `+`. Keeps SHARED_PAIRS readable in the short form.
member_abs() {
    local path out=""
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -z "$out" ]; then
            out="$REPO_ROOT/$path"
        else
            out="${out}+${REPO_ROOT}/${path}"
        fi
    done <<<"$(split_member "$1")"
    printf '%s' "$out"
}

# missing_member_files MEMBER [ROOT] — the paths of MEMBER that do not exist,
# one per line; empty when every file is present. ROOT defaults to $REPO_ROOT
# and is a parameter only so a fixture can drive this over a temp dir.
#
# A HELPER rather than an inline loop so the rule is directly testable. As an
# inline `assert_file_exists` loop the check could only ever be exercised by the
# real SHARED_PAIRS, whose files all exist — so mutating it to inspect just the
# first path of each member left the suite green. A rule with no reachable
# negative case is a rule nothing proves.
#
# EVERY path is checked, not just the first: a missing constituent does not
# error, it silently yields a SHORTER reassembled region (awk prints to stderr
# and moves on), which surfaces as a confusing drift report against a member
# that is in fact correct.
missing_member_files() {
    local member="$1" root="${2:-$REPO_ROOT}" path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            /*) [ -f "$path" ] || printf '%s\n' "$path" ;;
            *) [ -f "$root/$path" ] || printf '%s\n' "$path" ;;
        esac
    done <<<"$(split_member "$member")"
}

# extract_shared_multi MEMBER REGION — REGION's lines across every file of
# MEMBER, concatenated in list order. `extract_shared` itself is unchanged, so
# the nested-region sentinel handling above still applies per file.
extract_shared_multi() {
    local member="$1" region="$2" path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        extract_shared "$path" "$region"
    done <<<"$(split_member "$member")"
}

# Normalize to the ordered sequence of non-blank, trimmed lines. Trimming
# collapses the indentation difference between the two nesting depths. Order and
# duplicates are preserved (no sort, no -u), so the comparison is a true
# ordered-multiset equality: a reordered, duplicated, or dropped line all
# surface as drift, not just a changed evidence string.
normalize() {
    command awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 != "" { print }
    '
}

# sentinel_count NEEDLE FILE — occurrences of the fixed string NEEDLE in FILE.
sentinel_count() {
    command grep -cF "$1" "$2" || true
}

# sentinel_count_multi NEEDLE MEMBER — occurrences of NEEDLE summed across every
# file of MEMBER.
#
# A SUM, not a per-file check, on purpose: the caller asserts the total is
# exactly 1, which is the property that actually matters for a multi-file
# member. A region accidentally pasted into two files of the same member would
# reassemble as a doubled region — the ordered-multiset comparison would then
# report drift against the other member without saying why. Summing here fails
# on the duplication itself, with the region named (#772).
sentinel_count_multi() {
    local needle="$1" member="$2" path total=0 n
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        n="$(sentinel_count "$needle" "$path")"
        total=$((total + n))
    done <<<"$(split_member "$member")"
    printf '%s' "$total"
}

# label_for PATH — the plugin-qualified short name used in assertion messages.
# Both pairs' canonical file is *named* `patterns.sh`, so a bare basename would
# make the second pair's failures read as the first pair's. Keep the last two
# path segments (`<skill>/patterns.sh`), which are unique across the pairs.
label_for() {
    local path="$1" tail
    tail="${path%/*}"
    printf '%s/%s' "${tail##*/}" "${path##*/}"
}

# label_for_multi MEMBER — the label used in assertion messages for a
# possibly-multi-file member: the first file's short name, plus `(+N more)` when
# the member carries more. A bare first-file label would make a failure in the
# third file of a member read as one in the first (#772).
label_for_multi() {
    local member="$1" path first="" count=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -z "$first" ] && first="$path"
        count=$((count + 1))
    done <<<"$(split_member "$member")"

    if [ "$count" -le 1 ]; then
        label_for "$first"
    else
        printf '%s (+%d more)' "$(label_for "$first")" "$((count - 1))"
    fi
}

# assert_region_synced CANONICAL_MEMBER DUPLICATE_MEMBER REGION — both copies of
# REGION are present (one open + one close sentinel across each MEMBER) and
# byte-identical after normalization. Members are passed explicitly rather than
# read from globals so the same assertion serves every pair in SHARED_PAIRS.
#
# Each member is a `+`-joined file list (a single path being the one-element
# case), so a region may span several files on either side — reassembled in list
# order by extract_shared_multi (#772).
assert_region_synced() {
    local canonical_file="$1" duplicate_file="$2" region="$3"
    local open="# >>> shared:${region}" close="# <<< shared:${region}"
    local can_label dup_label
    can_label="$(label_for_multi "$canonical_file")"
    dup_label="$(label_for_multi "$duplicate_file")"

    assert_equals "1" "$(sentinel_count_multi "$open" "$canonical_file")" "${can_label}: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count_multi "$close" "$canonical_file")" "${can_label}: one closing sentinel for ${region}"
    assert_equals "1" "$(sentinel_count_multi "$open" "$duplicate_file")" "${dup_label}: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count_multi "$close" "$duplicate_file")" "${dup_label}: one closing sentinel for ${region}"

    local canonical duplicate
    canonical="$(extract_shared_multi "$canonical_file" "$region" | normalize)"
    duplicate="$(extract_shared_multi "$duplicate_file" "$region" | normalize)"

    assert_not_empty "$canonical" "${can_label} ${region} region is non-empty (sentinels intact)"
    assert_not_empty "$duplicate" "${dup_label} ${region} region is non-empty (sentinels intact)"

    if [ "$canonical" != "$duplicate" ]; then
        local diff_out
        diff_out="$(command diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$duplicate") || true)"
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$diff_out"
        _fail "shared:${region} drifted between ${can_label} and ${dup_label}" \
            "Lines prefixed '<' are ${can_label}-only; '>' are ${dup_label}-only. Re-sync the two copies." \
            "${detail[@]}"
    fi
}

# Every shared region of every pinned pair is in sync. This is the live drift
# guard.
test_all_regions_match() {
    local entry canonical_rel duplicate_rel regions region path
    local canonical_member duplicate_member

    for entry in "${SHARED_PAIRS[@]}"; do
        # Field-split on the delimiter. Region names are space-separated inside
        # the third field and are re-split by the unquoted `for` below. Each of
        # the first two fields is itself a `+`-joined file list (#772).
        IFS='|' read -r canonical_rel duplicate_rel regions <<<"$entry"

        assert_not_empty "$canonical_rel" "pair entry declares a canonical file"
        assert_not_empty "$duplicate_rel" "pair entry declares a duplicate file"
        assert_not_empty "$regions" "pair ${canonical_rel} declares at least one region"

        # EVERY file of EVERY member must exist — not just the first. A typo in
        # the third path of a member would otherwise surface as an empty extract
        # and a confusing drift report rather than a missing-file failure.
        for path in $(missing_member_files "$canonical_rel"); do
            _fail "member file does not exist: ${path}" \
                "Every path of a '+'-joined member must exist; check the SHARED_PAIRS entry."
        done
        for path in $(missing_member_files "$duplicate_rel"); do
            _fail "member file does not exist: ${path}" \
                "Every path of a '+'-joined member must exist; check the SHARED_PAIRS entry."
        done
        assert_equals "" "$(missing_member_files "$canonical_rel")" \
            "every file of the canonical member exists (${canonical_rel})"
        assert_equals "" "$(missing_member_files "$duplicate_rel")" \
            "every file of the duplicate member exists (${duplicate_rel})"

        canonical_member="$(member_abs "$canonical_rel")"
        duplicate_member="$(member_abs "$duplicate_rel")"

        # shellcheck disable=SC2086  # deliberate word-split: regions is a list
        for region in $regions; do
            assert_region_synced "$canonical_member" "$duplicate_member" "$region"
        done
    done
}

# Each debug region must carry an arm for every language it claims to cover.
# Guards against a copy silently losing a language arm (which the multiset
# equality would still catch as drift, but this pins the shape independently and
# makes the tamper fixture below meaningful for non-JS arms — see #133).
#
# The arm sets differ by family (#680) and that asymmetry is the point: only
# languages with a stdout-writing idiom appear in the print region (go/java
# have no breakpoint arm), and only languages with a breakpoint idiom appear in
# the debugger region (ruby has no print arm here).
# The arms are spelled as POSIX bracket classes since #754, and this test is
# deliberately keyed to that spelling rather than loosened to match either form.
# The bracket class is what makes the bash dispatch agree with patterns.py's
# `.lower()`; asserting on `*.py)` again would pass on a tree that had silently
# reverted to a case-SENSITIVE `case`, which is the exact defect #754 fixed. So
# the arm list doubles as the case-insensitivity pin at this dispatch site.
test_debug_region_has_all_language_arms() {
    local body arm
    body="$(extract_shared "$HEALTH_PATTERNS" debug-print-scan)"
    for arm in '*.[Pp][Yy])' '*.[Jj][Ss]' '*.[Gg][Oo])' '*.[Jj][Aa][Vv][Aa]'; do
        assert_contains "$body" "$arm" "debug-print region covers the ${arm} arm"
    done

    body="$(extract_shared "$HEALTH_PATTERNS" debugger-scan)"
    for arm in '*.[Pp][Yy])' '*.[Jj][Ss]' '*.[Rr][Bb])'; do
        assert_contains "$body" "$arm" "debugger region covers the ${arm} arm"
    done
}

# The families must stay SEPARATED, which is the invariant #680 depends on:
# pre-review-gates.sh exempts the print region for a declared `stdout_is_output`
# file and always runs the debugger region. If a breakpoint pattern migrated
# into the print region, that exemption would start silencing breakpoints — a
# real false negative, and one the byte-identical drift check alone would NOT
# catch (it only compares the two copies to each other, so the same mistake
# made in both files passes).
#
# Asserted on BOTH copies: the pair could be internally consistent and still
# wrong.
test_debug_families_stay_separated() {
    local file label print_body debugger_body pattern
    for file in "$HEALTH_PATTERNS" "$PRE_REVIEW_GATES"; do
        label="$(label_for "$file")"
        print_body="$(extract_shared "$file" debug-print-scan)"
        debugger_body="$(extract_shared "$file" debugger-scan)"

        # No breakpoint idiom may appear in the exemptible print region.
        for pattern in 'breakpoint' 'pdb' 'binding\.pry' 'byebug' 'debugger'; do
            assert_not_contains "$print_body" "$pattern" \
                "${label}: print region is free of the '${pattern}' idiom (stays exempt-safe)"
        done

        # ...and no stdout idiom may appear in the never-exempt debugger region,
        # which would make it unreachable for a declared CLI file.
        for pattern in 'print\(' 'console\.' 'fmt\.Print' 'System\.'; do
            assert_not_contains "$debugger_body" "$pattern" \
                "${label}: debugger region is free of the '${pattern}' idiom"
        done
    done
}

# The detector FIRES on drift in EACH region. A tamper on a non-JS line proves
# the extract/normalize path works beyond the first arm (#133). Comparison is in
# plain bash — NOT assert_true, which eval's its argument, and the regions hold
# shell metacharacters ($(...), quotes, |) that eval would execute.
test_detector_fires_on_drift() {
    # Region 1: debug-print-scan — tamper a Python (non-JS) evidence string.
    local dbg dbg_tampered
    dbg="$(extract_shared "$HEALTH_PATTERNS" debug-print-scan | normalize)"
    dbg_tampered="$(extract_shared "$HEALTH_PATTERNS" debug-print-scan |
        command sed 's/Debug print statement/Debug print/' | normalize)"
    assert_not_empty "$dbg_tampered" "tampered debug-print extract is non-empty (extract still works)"
    local dbg_changed="no" dbg_drift="none"
    [ "$dbg" != "$dbg_tampered" ] && dbg_changed="yes"
    [ "$dbg" != "$dbg_tampered" ] && dbg_drift="detected"
    assert_equals "yes" "$dbg_changed" "the debug-print tamper actually changed the region (non-JS 'Debug print statement' present)"
    assert_equals "detected" "$dbg_drift" "a one-line edit to the debug-print region is detected as drift"

    # Region 2: debugger-scan — tamper the Ruby arm, the one language that
    # exists ONLY in this region. A tamper on a py/js line would not prove the
    # split regions are extracted independently.
    local brk brk_tampered
    brk="$(extract_shared "$HEALTH_PATTERNS" debugger-scan | normalize)"
    brk_tampered="$(extract_shared "$HEALTH_PATTERNS" debugger-scan |
        command sed 's/Ruby debugger/Ruby dbg/' | normalize)"
    assert_not_empty "$brk_tampered" "tampered debugger extract is non-empty (extract still works)"
    local brk_changed="no" brk_drift="none"
    [ "$brk" != "$brk_tampered" ] && brk_changed="yes"
    [ "$brk" != "$brk_tampered" ] && brk_drift="detected"
    assert_equals "yes" "$brk_changed" "the debugger tamper actually changed the region ('Ruby debugger' present)"
    assert_equals "detected" "$brk_drift" "a one-line edit to the debugger region is detected as drift"

    # Region 3: is-test-file — tamper one glob arm.
    local itf itf_tampered
    itf="$(extract_shared "$HEALTH_PATTERNS" is-test-file | normalize)"
    itf_tampered="$(extract_shared "$HEALTH_PATTERNS" is-test-file |
        command sed 's/_spec\./_zzz./' | normalize)"
    assert_not_empty "$itf_tampered" "tampered is-test-file extract is non-empty"
    local itf_changed="no" itf_drift="none"
    [ "$itf" != "$itf_tampered" ] && itf_changed="yes"
    [ "$itf" != "$itf_tampered" ] && itf_drift="detected"
    assert_equals "yes" "$itf_changed" "the is-test-file tamper actually changed the region (_spec. arm present)"
    assert_equals "detected" "$itf_drift" "a one-line edit to the is-test-file region is detected as drift"

    # Region 4: yaml-list-parser (#686). Tampers the TRAILING-WHITESPACE strip,
    # not an arbitrary line — that expression is the #684 fix, and it is the one
    # place where a "harmless-looking" edit to either copy silently changes what
    # a project's declared patterns resolve to. Registering a region without a
    # tamper case would add it to SHARED_PAIRS and never prove the comparison
    # actually reaches it.
    local ylp ylp_tampered
    ylp="$(extract_shared "$HEALTH_PATTERNS" yaml-list-parser | normalize)"
    ylp_tampered="$(extract_shared "$HEALTH_PATTERNS" yaml-list-parser |
        command sed 's/item="${item%"${item##\*\[!\[:space:\]\]}"}"/item="$item"/' | normalize)"
    assert_not_empty "$ylp_tampered" "tampered yaml-list-parser extract is non-empty"
    local ylp_changed="no" ylp_drift="none"
    [ "$ylp" != "$ylp_tampered" ] && ylp_changed="yes"
    [ "$ylp" != "$ylp_tampered" ] && ylp_drift="detected"
    assert_equals "yes" "$ylp_changed" "the yaml-list-parser tamper actually changed the region (trailing-strip present)"
    assert_equals "detected" "$ylp_drift" "a one-line edit to the yaml-list-parser region is detected as drift (#686)"
}

# label_for actually DISAMBIGUATES the two pairs. Both pairs' canonical file is
# named `patterns.sh`, so this helper is the only thing keeping pair 2's failure
# messages from reading as pair 1's — and it renders exclusively on the failure
# path, which a green suite never exercises. Without this test, an edit to the
# tail-stripping expression that collapsed both labels back to `patterns.sh`
# would ship green.
test_label_for_disambiguates_the_pairs() {
    assert_equals "check-code-health/patterns.sh" "$(label_for "$HEALTH_PATTERNS")" \
        "label_for keeps the check-code-health copy distinguishable"
    assert_equals "loop-make-it-tested/patterns.sh" "$(label_for "$TESTED_PATTERNS")" \
        "label_for keeps the loop-make-it-tested copy distinguishable"
    assert_equals "ship-issue/pre-review-gates.sh" "$(label_for "$PRE_REVIEW_GATES")" \
        "label_for labels the shared duplicate by its skill dir"

    # The property that matters is DISTINCTNESS, not the strings alone: a bare
    # basename would satisfy neither assertion above nor this one.
    local a b
    a="$(label_for "$HEALTH_PATTERNS")"
    b="$(label_for "$TESTED_PATTERNS")"
    local distinct="no"
    [ "$a" != "$b" ] && distinct="yes"
    assert_equals "yes" "$distinct" "the two same-named patterns.sh copies get different labels"
}

# The detector FIRES on drift in the SECOND pair's region (#609). Deliberately
# shaped as a genuine CROSS-FILE comparison, unlike the single-file tampers
# above: the tampered text is extracted from the DUPLICATE
# (ship-issue/pre-review-gates.sh) and compared against the UNTAMPERED CANONICAL
# (loop-make-it-tested/patterns.sh). A fixture that tampered one file against
# itself would pass even if the two files were never actually paired — the
# pairing is the thing under test.
#
# The untampered-match assertion is what keeps this honest: it proves the two
# extracts are equal to begin with, so the inequality below can only come from
# the tamper. Without it, a broken extract returning empty for one side would
# make BOTH branches report "detected" and the fixture would pass vacuously.
#
# Comparison is plain bash, NOT assert_true — the region holds shell
# metacharacters ($(...), quotes, |) that assert_true's eval would execute.
test_detector_fires_on_py_region_drift() {
    local canonical duplicate tampered

    canonical="$(extract_shared "$TESTED_PATTERNS" py-public-symbols | normalize)"
    duplicate="$(extract_shared "$PRE_REVIEW_GATES" py-public-symbols | normalize)"

    assert_not_empty "$canonical" "loop-make-it-tested py-public-symbols extract is non-empty"
    assert_not_empty "$duplicate" "pre-review-gates py-public-symbols extract is non-empty"

    local baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "the untampered py-public-symbols pair matches (tamper is the only variable)"

    # Tamper a BEHAVIORAL line — py_symbol_is_public's `none` arm, which decides
    # whether a main()-guarded module exposes any public API at all. Prose would
    # prove less: this is the line a real one-sided bug fix would touch.
    tampered="$(extract_shared "$PRE_REVIEW_GATES" py-public-symbols |
        command sed 's/none) return 1 ;;/none) return 9 ;;/' | normalize)"
    assert_not_empty "$tampered" "tampered py-public-symbols extract is non-empty (extract still works)"

    local tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the 'none) return 1' arm is present)"

    local drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to pre-review-gates' copy is detected as drift against patterns.sh"
}

# The detector FIRES on drift in the THIRD pair's regions (#695) — the
# check-decomposition <-> ship-issue/sizing LOC engine. Shaped as a genuine
# CROSS-FILE comparison like the py-public-symbols fixture above: the tamper is
# applied to the DUPLICATE (sizing.sh) and compared against the UNTAMPERED
# CANONICAL (check-decomposition/patterns.sh), because a fixture that tampered
# one file against itself would pass even if the two files were never paired.
#
# This pair is the first whose shared regions carry AWK source rather than bash.
# Nothing in extract_shared/normalize is language-aware, so that works unchanged
# — but it is exactly the kind of assumption that deserves a live fixture rather
# than a comment, which is what these tampers are.
#
# BOTH regions are tampered, on BEHAVIORAL lines:
#   loc-helpers-awk — the `is_comment` py/sh arm, which decides what counts as a
#     comment line and therefore what production LOC IS. A prose tamper would
#     prove less; this is the line a real one-sided bug fix would touch.
#   loc-measure-awk — the production subtraction itself, the single expression
#     every sizing finding in both lenses is computed from.
#
# The untampered-match assertion keeps each honest: it proves the two extracts
# are equal to begin with, so the inequality below can only come from the tamper.
# Without it a broken extract returning empty for one side would make BOTH
# branches report "detected" and the fixture would pass vacuously.
#
# Comparison is plain bash, NOT assert_true — the regions hold shell
# metacharacters that assert_true's eval would execute.
test_detector_fires_on_loc_region_drift() {
    local canonical duplicate tampered baseline tamper_took drift

    # --- region 1: loc-helpers-awk ------------------------------------------
    canonical="$(extract_shared "$DECOMP_PATTERNS" loc-helpers-awk | normalize)"
    duplicate="$(extract_shared "$SIZING" loc-helpers-awk | normalize)"

    assert_not_empty "$canonical" "check-decomposition loc-helpers-awk extract is non-empty"
    assert_not_empty "$duplicate" "sizing loc-helpers-awk extract is non-empty"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "the untampered loc-helpers-awk pair matches (tamper is the only variable)"

    # The tamper targets the `is_comment` py/sh arm — the line that decides what
    # counts as a comment and therefore what production LOC IS. Matched on the
    # distinctive `return 0` terminator of that function rather than on the arm
    # itself: the arm contains a `||`, and a sed BRE `\|` is a GNU extension that
    # BSD sed reads as a LITERAL, so an alternation-bearing pattern would silently
    # match nothing on macOS and the tamper would be a no-op there (#679 — and
    # exactly the silent class that lint catches). `s/…/…/` on a plain fixed
    # string is dialect-neutral.
    tampered="$(extract_shared "$SIZING" loc-helpers-awk |
        command sed 's/if (lang == "js" || lang == "ts" || lang == "rs" || lang == "go" || lang == "swift") return line ~/if (0) return line ~/' | normalize)"
    assert_not_empty "$tampered" "tampered loc-helpers-awk extract is non-empty (extract still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the is_comment py/sh arm is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to sizing's loc-helpers copy is detected as drift"

    # --- region 2: loc-measure-awk ------------------------------------------
    canonical="$(extract_shared "$DECOMP_PATTERNS" loc-measure-awk | normalize)"
    duplicate="$(extract_shared "$SIZING" loc-measure-awk | normalize)"

    assert_not_empty "$canonical" "check-decomposition loc-measure-awk extract is non-empty"
    assert_not_empty "$duplicate" "sizing loc-measure-awk extract is non-empty"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "the untampered loc-measure-awk pair matches (tamper is the only variable)"

    tampered="$(extract_shared "$SIZING" loc-measure-awk |
        command sed 's/production = total - blank - comment - (tf ? 0 : test_excluded)/production = total/' | normalize)"
    assert_not_empty "$tampered" "tampered loc-measure-awk extract is non-empty (extract still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the production subtraction is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to sizing's loc-measure copy is detected as drift"
}

# The detector FIRES on drift in the PROSE-CLASSIFICATION pair (#724) — the bash
# half of what bloat-spec-py pins on the Python side.
#
# Two regions, tampered on the two things that can independently fork:
#
#   bloat-config — the NUMBERS. A drifted budget means the two lenses disagree
#                  about how big an agent definition may be.
#   bloat-spec   — the ARM ORDER. `*/skills/*/*.md` sitting above
#                  `*/skills/*/SKILL.md` swallows every SKILL.md into the looser
#                  companion budget, because `case` takes the FIRST match. That
#                  is a silent misciassification, not an error, which is exactly
#                  why it needs a fixture.
#
# Tampers are FIXED STRINGS: a BRE `\|` is a GNU extension BSD sed reads as a
# literal, so an alternation-bearing pattern would match nothing on macOS and the
# tamper would be a no-op there (#679).
test_detector_fires_on_bloat_region_drift() {
    local canonical duplicate tampered baseline tamper_took drift region sed_expr

    for region in bloat-config bloat-spec; do
        case "$region" in
            bloat-config)
                sed_expr='s/AGENT_HIGH="${AGENT_HIGH:-400}"/AGENT_HIGH="${AGENT_HIGH:-900}"/'
                ;;
            bloat-spec)
                sed_expr='s|        \*/skills/\*/SKILL.md)|        */skills/*/OTHER.md)|'
                ;;
        esac

        canonical="$(extract_shared "$DECOMP_PATTERNS" "$region" | normalize)"
        duplicate="$(extract_shared "$SIZING" "$region" | normalize)"

        assert_not_empty "$canonical" "check-decomposition ${region} extract is non-empty"
        assert_not_empty "$duplicate" "sizing ${region} extract is non-empty"

        baseline="differs"
        [ "$canonical" = "$duplicate" ] && baseline="matches"
        assert_equals "matches" "$baseline" \
            "the untampered ${region} pair matches (tamper is the only variable)"

        tampered="$(extract_shared "$SIZING" "$region" |
            command sed "$sed_expr" | normalize)"
        assert_not_empty "$tampered" "tampered ${region} extract is non-empty (extract still works)"

        tamper_took="no"
        [ "$duplicate" != "$tampered" ] && tamper_took="yes"
        assert_equals "yes" "$tamper_took" \
            "the ${region} tamper actually changed the region (the targeted line is present)"

        drift="none"
        [ "$canonical" != "$tampered" ] && drift="detected"
        assert_equals "detected" "$drift" \
            "a one-line edit to sizing's ${region} copy is detected as drift"
    done
}

# The detector FIRES on drift in the split-shape-awk region (#725) — the awk
# fallback half of the language split-shape table, whose Python primaries are
# covered by the split-shape-py case in the loop above.
#
# Cross-file like every other awk fixture here: the tamper is applied to the
# DUPLICATE (sizing.sh) and compared against the UNTAMPERED CANONICAL
# (check-decomposition/patterns.sh), because a fixture that tampered one file
# against itself would pass even if the two files were never paired.
#
# The tamper targets the `md` arm. Markdown is the largest and fastest-churning
# surface in this repo (#589) and the one arm whose guidance is structurally
# unlike the others — progressive disclosure rather than a module move — so a
# copy that "helpfully" rewrote it to match its siblings is the realistic drift.
#
# A fixed-string sed with no alternation: BSD sed reads BRE `\|` as a LITERAL, so
# an alternation-bearing pattern would match nothing on macOS and the tamper
# would be a silent no-op there (#679).
test_detector_fires_on_split_shape_region_drift() {
    local canonical duplicate tampered baseline tamper_took drift

    canonical="$(extract_shared "$DECOMP_PATTERNS" split-shape-awk | normalize)"
    duplicate="$(extract_shared "$SIZING" split-shape-awk | normalize)"

    assert_not_empty "$canonical" "check-decomposition split-shape-awk extract is non-empty"
    assert_not_empty "$duplicate" "sizing split-shape-awk extract is non-empty"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" \
        "the untampered split-shape-awk pair matches (tamper is the only variable)"

    tampered="$(extract_shared "$SIZING" split-shape-awk |
        command sed 's/return "progressive disclosure/return "zzz disclosure/' | normalize)"
    assert_not_empty "$tampered" "tampered split-shape-awk extract is non-empty (extract still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" \
        "the tamper actually changed the region (the md progressive-disclosure arm is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" \
        "a one-line edit to sizing.sh's split-shape copy is detected as drift (#725)"
}

# The shape table and the segmenters cover THE SAME LANGUAGE SET (#725 AC3).
#
# This is the invariant that makes the unified table worth having: advice and
# measurement must not disagree about what a file is. A language with a
# segmenter and no shape emits a generic fallback where a real shape was
# possible; a shape for a language nothing segments is dead advice that will
# never fire. Both are silent — no error, no empty output, just weaker findings
# — which is why they need a structural assertion rather than a behavioral one.
#
# Asserted on BOTH copies of the region and against BOTH runtimes' tables, NOT
# copy-vs-copy: a defect present in both passes an equality check by
# construction ([[parity-gate-hides-shared-defect]]). The awk half is checked by
# its `if (lang == "xx")` arms and the Python half by its dict keys, so the two
# spellings of the same table are each held to the segmenter set independently.
#
# The segmenter set is read from EXT_LANG's VALUES (the language keys), not its
# keys (the extensions): `ts`/`tsx`/`mjs` all map to `js`, and it is the mapped
# language the shape table is keyed by.
test_split_shape_covers_every_segmenter_language() {
    local file label langs lang body found

    # The language set, derived from the shared loc-tables-py region rather than
    # hardcoded — a list retyped here would be a third copy of the same fact and
    # would silently pass when #726/#727/#728 add a language.
    langs="$(extract_shared_multi "$DECOMP_PATTERNS_PY" loc-tables-py |
        command sed -n '/^EXT_LANG = {/,/^}/p' |
        command sed -n 's/^[[:space:]]*"[^"]*":[[:space:]]*"\([^"]*\)",.*$/\1/p' |
        command sort -u)"
    assert_not_empty "$langs" "the segmenter language set is derivable from EXT_LANG"

    # Sanity: the extraction found a plausible set, not one stray line. Six
    # languages today; the assertion is a FLOOR so adding a language does not
    # need an edit here, but a broken extract yielding one value fails.
    local count
    count="$(command printf '%s\n' "$langs" | command wc -l | command tr -d ' ')"
    local enough="no"
    [ "$count" -ge 6 ] && enough="yes"
    assert_equals "yes" "$enough" "EXT_LANG yields the full language set (>= 6, got ${count})"

    # --- Python halves: every segmenter language is a SPLIT_SHAPE key --------
    for file in "$DECOMP_PATTERNS_PY" "$SIZING_PY"; do
        label="$(label_for_multi "$file")"
        body="$(extract_shared_multi "$file" split-shape-py)"
        assert_not_empty "$body" "${label}: split-shape-py region is non-empty"

        for lang in $langs; do
            assert_contains "$body" "\"${lang}\":" \
                "${label}: SPLIT_SHAPE has a ${lang} arm (segmenter exists for it)"
        done
    done

    # --- awk halves: every segmenter language has an `if (lang == ...)` arm --
    for file in "$DECOMP_PATTERNS" "$SIZING"; do
        label="$(label_for_multi "$file")"
        body="$(extract_shared "$file" split-shape-awk)"
        assert_not_empty "$body" "${label}: split-shape-awk region is non-empty"

        for lang in $langs; do
            assert_contains "$body" "lang == \"${lang}\"" \
                "${label}: awk split_shape has a ${lang} arm (segmenter exists for it)"
        done
    done

    # --- the converse: no shape for a language nothing segments -------------
    # Dead advice, and the direction a hand-added arm drifts. Read the Python
    # table's keys back out and require each to be in the segmenter set.
    for file in "$DECOMP_PATTERNS_PY" "$SIZING_PY"; do
        label="$(label_for_multi "$file")"
        for lang in $(extract_shared_multi "$file" split-shape-py |
            command sed -n '/^SPLIT_SHAPE = {/,/^}/p' |
            command sed -n 's/^[[:space:]]*"\([^"]*\)":.*$/\1/p'); do
            found="no"
            for l2 in $langs; do
                [ "$lang" = "$l2" ] && found="yes"
            done
            assert_equals "yes" "$found" \
                "${label}: SPLIT_SHAPE key ${lang} is a language some segmenter produces"
        done
    done
}

# The detector FIRES on drift in the unit-segmenter pair — sizing.sh's proposal
# side vs split-verify.sh's verification side (#695). This pair is a NESTED
# region: `unit-segmenters-awk` sits inside `loc-helpers-awk`, which is itself
# shared with check-decomposition. That nesting is why extract_shared drops every
# sentinel line rather than only its own region's, and this fixture is what
# proves the inner region is still extracted independently rather than being
# swallowed by the outer one.
#
# It matters beyond bookkeeping: sizing.sh decides a file should be split and
# split-verify.sh decides whether the split lost anything. If their segmenters
# disagree about what a unit IS, the verifier can bless a split that dropped a
# function the sizer counted — silently, and only on the bash fallback path.
#
# Tampered on the `sh` arm of is_unit_header: split-verify's own suite is shell,
# so that arm is the one a careless edit is most likely to touch.
test_detector_fires_on_segmenter_region_drift() {
    local canonical duplicate tampered baseline tamper_took drift

    canonical="$(extract_shared "$SIZING" unit-segmenters-awk | normalize)"
    duplicate="$(extract_shared "$SPLIT_VERIFY" unit-segmenters-awk | normalize)"

    assert_not_empty "$canonical" "sizing unit-segmenters-awk extract is non-empty"
    assert_not_empty "$duplicate" "split-verify unit-segmenters-awk extract is non-empty"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "the untampered unit-segmenters-awk pair matches (tamper is the only variable)"

    tampered="$(extract_shared "$SPLIT_VERIFY" unit-segmenters-awk |
        command sed 's/if (lang == "sh") return line ~/if (0) return line ~/' | normalize)"
    assert_not_empty "$tampered" "tampered unit-segmenters-awk extract is non-empty (extract still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the sh arm is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to split-verify's segmenter copy is detected as drift"

    # THIRD holder (#727): check-decomposition/patterns.sh carries this region
    # too. Until #727 its copy was inside loc-helpers-awk but bore no inner
    # sentinels, so patterns.sh <-> split-verify.sh was pinned only TRANSITIVELY
    # through sizing.sh. That was enough while the segmenters were static; the
    # rs/go arms are now the most-edited lines in the file, and a three-way
    # region where one leg is unpinned is how two of three copies drift.
    #
    # Tampered on the `go` receiver arm — the rule #727 added, and the one a
    # careless edit is most likely to touch. Matched on the distinctive
    # `^func[ \t]*\(` opener via a fixed string: the arm contains `||`, and a
    # sed BRE `\|` is a GNU extension BSD sed reads as a LITERAL (#679), so an
    # alternation-bearing pattern would silently no-op on macOS.
    canonical="$(extract_shared "$DECOMP_PATTERNS" unit-segmenters-awk | normalize)"
    assert_not_empty "$canonical" "check-decomposition unit-segmenters-awk extract is non-empty"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "patterns.sh's segmenter copy matches split-verify's (three-way region)"

    tampered="$(extract_shared "$SPLIT_VERIFY" unit-segmenters-awk |
        command sed 's|if (lang == "go") return line ~ /\^func\[ .t\]\*|if (0) return line ~ /^func[ \\t]*|' | normalize)"
    assert_not_empty "$tampered" "tampered go-arm extract is non-empty (extract still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the go receiver arm is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to the go receiver arm is detected against patterns.sh"
}

# The detector FIRES on drift in EACH region of the FOURTH pair — the Python
# primaries (#730). Same cross-file shape as the awk fixtures above: the tamper
# is applied to the DUPLICATE (sizing.py) and compared against the UNTAMPERED
# CANONICAL (check-decomposition/patterns.py), because a fixture that tampered
# one file against itself would pass even if the two were never paired.
#
# Every tamper targets a BEHAVIORAL line, one per region, chosen as the line a
# real one-sided bug fix would touch:
#
#   loc-tables-py   — the `md` entry of NEST_UNIT. Markdown's indent unit is 2
#                     where almost everything else is 4, so a copy that "tidied"
#                     it to 4 would change max-nesting in every markdown metrics
#                     string while looking like a consistency cleanup.
#   loc-helpers-py  — _int_env's ValueError fallback. This is what makes a
#                     malformed threshold env var fall back to the default
#                     instead of crashing the scan; a copy that dropped it would
#                     fail only on malformed input, i.e. rarely and loudly.
#   loc-unit-py     — md_slug's slugging arm. THE #730 fork: sizing.py used to
#                     hardcode "section" here while patterns.py slugged the
#                     heading text.
#   loc-measure-py  — the production subtraction, the single expression every
#                     sizing finding in BOTH lenses is computed from.
#
# Each is a fixed-string sed with no alternation: BSD sed reads BRE `\|` as a
# LITERAL, so an alternation-bearing pattern would match nothing on macOS and the
# tamper would be a silent no-op there (#679).
#
# The untampered-match assertion per region is what keeps each honest — it proves
# the two extracts are equal to begin with, so the inequality can only come from
# the tamper. Without it a broken extract returning empty for one side would make
# BOTH branches report "detected" and the fixture would pass vacuously.
#
# Comparison is plain bash, NOT assert_true: the regions hold Python source with
# shell metacharacters (quotes, backslashes, parens) that assert_true's eval
# would execute.
test_detector_fires_on_python_primary_drift() {
    local region canonical duplicate tampered baseline tamper_took drift sed_expr

    for region in $PY_REGIONS; do
        case "$region" in
            loc-tables-py)
                # NEST_UNIT's `md` entry. Was `s/"md": 2}/"md": 4}/` back when
                # the dict fit on one line; adding `swift` (#728) pushed it to
                # one-key-per-line, so the closing brace is no longer on it.
                # Anchored on the trailing comma instead, which is still a fixed
                # string and still unique in the region (EXT_LANG's md entry is
                # `"md": "md",`, a different value).
                sed_expr='s/    "md": 2,/    "md": 4,/'
                ;;
            loc-helpers-py)
                sed_expr='s/        return default/        return 0/'
                ;;
            loc-unit-py)
                sed_expr='s/            out.append(ch)/            out.append("x")/'
                ;;
            loc-measure-py)
                # Retargeted by #851: the subtraction is now CONDITIONAL on
                # test_file, so the old literal no longer exists and the tamper
                # would silently stop taking — a drift check that is green and
                # vacuous, which is the failure this suite exists to prevent.
                sed_expr='s/    production = total - blank - comment - (0 if test_file else test_excluded)/    production = total/'
                ;;
            bloat-spec-py)
                # Targets the AGENT budget — the arm #724's headline fixture
                # lands on. A drifted copy here means the two lenses disagree
                # about how big an agent definition may be, which is the class
                # of fork this region exists to make impossible.
                sed_expr='s/            _int_env("AGENT_HIGH", 400),/            _int_env("AGENT_HIGH", 900),/'
                ;;
            split-shape-py)
                # Targets the `sh` ARM, not the fallback: shell is this repo's
                # own largest scanner surface, so a drifted shell shape is the
                # one that would misdirect a reader here first. A drift means
                # the audit backlog and the per-PR review propose DIFFERENT
                # destinations for the same file — advice that contradicts
                # itself across lenses, which is the whole fork #725 closes.
                sed_expr='s/    "sh": "sourced fragment/    "sh": "zzz fragment/'
                ;;
            bundle-seam-py)
                # Targets the CONCEPT row's anti-orphan clause (#729) — the one
                # sentence in this region whose loss is silent and permanent. A
                # drifted copy means one lens tells the reader to add the index
                # line and the other does not; following the lens that does not
                # produces #697 exactly: the lesson on disk, absent from the
                # index, never recalled, nothing erroring.
                sed_expr='s/                "line (an extracted concept with no index line is an orphan)"/                "line (optional)"/'
                ;;
            *)
                _fail "no tamper case for region ${region}" \
                    "Every region in PY_REGIONS needs a tamper, or its registration is unproven."
                continue
                ;;
        esac

        canonical="$(extract_shared_multi "$DECOMP_PATTERNS_PY" "$region" | normalize)"
        duplicate="$(extract_shared_multi "$SIZING_PY" "$region" | normalize)"

        assert_not_empty "$canonical" "patterns.py ${region} extract is non-empty"
        assert_not_empty "$duplicate" "sizing.py ${region} extract is non-empty"

        baseline="differs"
        [ "$canonical" = "$duplicate" ] && baseline="matches"
        assert_equals "matches" "$baseline" \
            "the untampered ${region} pair matches (tamper is the only variable)"

        tampered="$(extract_shared_multi "$SIZING_PY" "$region" |
            command sed "$sed_expr" | normalize)"
        assert_not_empty "$tampered" "tampered ${region} extract is non-empty (extract still works)"

        tamper_took="no"
        [ "$duplicate" != "$tampered" ] && tamper_took="yes"
        assert_equals "yes" "$tamper_took" \
            "the ${region} tamper actually changed the region (the targeted line is present)"

        drift="none"
        [ "$canonical" != "$tampered" ] && drift="detected"
        assert_equals "detected" "$drift" \
            "a one-line edit to sizing.py's ${region} copy is detected as drift"
    done
}

# Every region registered for the Python pair has a tamper case, and vice versa.
#
# Guarded by NAME SETS rather than counts: a count check passes when one region
# is added and another dropped in the same edit, which is exactly the bookkeeping
# error this catches. The failure mode it prevents is a region sitting in
# SHARED_PAIRS with no fixture ever proving the comparison reaches it — green,
# and unproven.
test_py_regions_and_tampers_agree() {
    local entry canonical_rel duplicate_rel regions declared r r2 found

    declared=""
    for entry in "${SHARED_PAIRS[@]}"; do
        IFS='|' read -r canonical_rel duplicate_rel regions <<<"$entry"
        case "$canonical_rel" in
            *.py) declared="$regions" ;;
        esac
    done

    assert_not_empty "$declared" "a .py pair is registered in SHARED_PAIRS"

    for r in $declared; do
        found="no"
        for r2 in $PY_REGIONS; do
            [ "$r" = "$r2" ] && found="yes"
        done
        assert_equals "yes" "$found" "region ${r} from SHARED_PAIRS has a tamper case"
    done
    for r in $PY_REGIONS; do
        found="no"
        for r2 in $declared; do
            [ "$r" = "$r2" ] && found="yes"
        done
        assert_equals "yes" "$found" "tampered region ${r} is actually registered in SHARED_PAIRS"
    done
}

# The detector FIRES when exactly ONE constituent file of a multi-file member
# drifts (#772 AC2).
#
# This is the property the multi-file support exists to preserve, and it is NOT
# implied by the per-region fixture above. That one tampers whichever file
# happens to hold the region; this one pins the harder direction — the tampered
# file is the SECOND of the member's list, and the first is left untouched. A
# reassembly bug that only ever read the first file would leave the region
# EMPTY, `assert_not_empty` would fail loudly, and the drift assertion would
# never be reached. A bug that read the files but dropped the second's lines
# would compare two truncated regions as equal and pass silently — which is the
# failure mode the issue names, and the one this fixture is aimed at.
#
# Shaped as a genuine CROSS-FILE comparison like every other fixture here: the
# tamper is applied to the DUPLICATE member (ship-issue) and compared against
# the UNTAMPERED CANONICAL (check-decomposition).
#
# The untampered-match assertion keeps it honest: it proves the two members
# reassemble equal to begin with, so the inequality below can only come from the
# tamper. Without it a broken extract returning empty for one side would make
# BOTH branches report "detected" and the fixture would pass vacuously.
test_detector_fires_on_multifile_member_drift() {
    local canonical duplicate tampered baseline tamper_took drift
    local first_file second_file untouched_before untouched_after

    # bundle-seam-py lives in prose_spec.py — the SECOND file of the member.
    first_file="$(split_member "$SIZING_PY" | command head -1)"
    second_file="$(split_member "$SIZING_PY" | command sed -n '2p')"
    assert_not_empty "$first_file" "the duplicate member has a first file"
    assert_not_empty "$second_file" "the duplicate member has a second file (it is genuinely multi-file)"

    canonical="$(extract_shared_multi "$DECOMP_PATTERNS_PY" bundle-seam-py | normalize)"
    duplicate="$(extract_shared_multi "$SIZING_PY" bundle-seam-py | normalize)"

    assert_not_empty "$canonical" "canonical member reassembles bundle-seam-py"
    assert_not_empty "$duplicate" "duplicate member reassembles bundle-seam-py"

    baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" \
        "the untampered multi-file member matches (tamper is the only variable)"

    # The region really does live in the SECOND file, not the first. Without
    # this the fixture could be tampering the first file and proving nothing
    # about reassembly reaching past it.
    untouched_before="$(extract_shared "$first_file" bundle-seam-py)"
    assert_equals "" "$untouched_before" \
        "bundle-seam-py is absent from the member's FIRST file (the tamper lands in the second)"

    # Tamper the CONCEPT row's anti-orphan clause, same behavioral line the
    # per-region fixture targets — a fixed string, since BSD sed reads a BRE
    # `\|` as a literal (#679).
    tampered="$(extract_shared_multi "$SIZING_PY" bundle-seam-py |
        command sed 's/                "line (an extracted concept with no index line is an orphan)"/                "line (optional)"/' | normalize)"
    assert_not_empty "$tampered" "tampered multi-file extract is non-empty (reassembly still works)"

    tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" \
        "the tamper actually changed the region (the anti-orphan clause is present)"

    drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" \
        "a one-line edit to ONE constituent file of a multi-file member is detected as drift (#772)"

    # The member's OTHER file is untouched by the tamper — this fixture mutates
    # exactly one constituent, which is what AC2 asks for.
    untouched_after="$(extract_shared "$first_file" loc-tables-py | normalize)"
    assert_not_empty "$untouched_after" \
        "the member's first file still yields its own region (only one constituent was tampered)"
}

# Reassembly is ORDER-PRESERVING (#772).
#
# The contract says a multi-file region concatenates in LIST order. Nothing
# above would notice if extract_shared_multi sorted the paths, globbed them, or
# read them backwards: every region currently lives whole inside ONE file of its
# member, so any order yields the same bytes per region. That makes the ordering
# rule true-by-accident today and silently breakable tomorrow — the moment a
# region does span two files, a sorted implementation would compare a correct
# member against a reordered one and report drift on two identical copies.
#
# So this asserts the property directly, on a purpose-built fixture: ONE region
# genuinely SPANNING two temp files, extracted by a SINGLE extract_shared_multi
# call per order. That single call is essential. An earlier version of this test
# made two calls and concatenated them at the call site — which put the ordering
# in the TEST's hands, not the function's, so mutating extract_shared_multi to
# `sort` its paths left it green. It was a tautology, and the mutation round is
# what surfaced it ([[anchored-regex-tautological-test]]).
#
# Temp files rather than the real modules for the same reason: no real region
# spans files today, so any pair of real regions would concatenate identically
# in either order and prove nothing.
test_multifile_reassembly_preserves_list_order() {
    local tmpdir file_a file_b forward reverse differs same_set

    tmpdir="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    file_a="$tmpdir/a.py"
    file_b="$tmpdir/b.py"

    # ONE region, two files. Each half is meaningless alone; the ordered
    # concatenation is the region.
    command cat >"$file_a" <<'FIXTURE'
# >>> shared:order-probe (sync: b.py)
ALPHA = 1
BRAVO = 2
# <<< shared:order-probe
FIXTURE
    command cat >"$file_b" <<'FIXTURE'
# >>> shared:order-probe (sync: a.py)
CHARLIE = 3
DELTA = 4
# <<< shared:order-probe
FIXTURE

    # A SINGLE call per order — the function does the concatenating, which is
    # the whole point.
    forward="$(extract_shared_multi "${file_a}+${file_b}" order-probe | normalize)"
    reverse="$(extract_shared_multi "${file_b}+${file_a}" order-probe | normalize)"

    command rm -rf "$tmpdir"

    assert_not_empty "$forward" "forward-order reassembly is non-empty"
    assert_not_empty "$reverse" "reverse-order reassembly is non-empty"

    # The region really does span both files — otherwise the order assertion
    # below could pass on a one-file extract for the wrong reason.
    assert_contains "$forward" "ALPHA = 1" "the reassembled region includes the FIRST file's lines"
    assert_contains "$forward" "CHARLIE = 3" "the reassembled region includes the SECOND file's lines"

    assert_equals "ALPHA = 1" "$(command printf '%s\n' "$forward" | command head -1)" \
        "list order decides which file's lines come first"
    assert_equals "CHARLIE = 3" "$(command printf '%s\n' "$reverse" | command head -1)" \
        "reversing the member reverses the reassembly (order is preserved, not sorted)"

    # Same LINES, different ORDER — which is exactly what an ordered-multiset
    # comparison must distinguish and a sorted one cannot. A `sort`-ing
    # implementation would make these two equal, which is the mutation.
    differs="no"
    [ "$forward" != "$reverse" ] && differs="yes"
    assert_equals "yes" "$differs" \
        "reassembling a member in reverse order yields different text (order is preserved, not sorted)"

    same_set="no"
    [ "$(command printf '%s\n' "$forward" | command sort)" = \
        "$(command printf '%s\n' "$reverse" | command sort)" ] && same_set="yes"
    assert_equals "yes" "$same_set" \
        "both orders carry the SAME lines (the difference is order alone, not content)"
}

# A member naming a file that does not exist FAILS, on every file of the list
# (#772).
#
# The mutation round found this untested: neutering the per-file
# assert_file_exists in test_all_regions_match to check only the first path left
# the suite green, because every registered member's files do exist. A rule with
# no negative fixture is a rule nothing proves.
#
# Asserted on the HELPER rather than by corrupting SHARED_PAIRS: the property is
# that a missing constituent is DETECTABLE, and extract_shared_multi returning
# empty for it is what makes the existence check load-bearing. A member whose
# second file is absent must not silently reassemble as if it were a one-file
# member.
test_missing_constituent_is_detectable() {
    local tmpdir file_a present absent

    tmpdir="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    file_a="$tmpdir/a.py"
    command cat >"$file_a" <<'FIXTURE'
# >>> shared:absent-probe (sync: ghost.py)
ALPHA = 1
# <<< shared:absent-probe
FIXTURE

    # Every path of the member must be seen by split_member, including one that
    # does not exist — that is what lets missing_member_files fire on it.
    absent="$(split_member "${file_a}+${tmpdir}/ghost.py" | command sed -n '2p')"
    assert_equals "${tmpdir}/ghost.py" "$absent" \
        "split_member yields the missing path too (so existence can be asserted on it)"

    local ghost_exists="yes"
    [ -f "${tmpdir}/ghost.py" ] || ghost_exists="no"
    assert_equals "no" "$ghost_exists" "the probe path is genuinely absent"

    # THE RULE ITSELF, driven over a member whose SECOND file is missing. This
    # is the assertion the mutation round demanded: checking only the first path
    # returns empty here and fails this line.
    assert_equals "${tmpdir}/ghost.py" \
        "$(missing_member_files "${file_a}+${tmpdir}/ghost.py")" \
        "missing_member_files names the absent SECOND file of a member"

    # ...and a fully-present member reports nothing, so the check cannot be
    # passing by always returning something.
    assert_equals "" "$(missing_member_files "${file_a}+${file_a}")" \
        "missing_member_files is silent when every file of the member exists"

    # A missing FIRST file is caught too — the converse direction, so the rule
    # is not merely 'inspect the tail'.
    assert_equals "${tmpdir}/ghost.py" \
        "$(missing_member_files "${tmpdir}/ghost.py+${file_a}")" \
        "missing_member_files names the absent FIRST file of a member"

    # THE RELATIVE ARM, driven with an explicit root. Every assertion above
    # passes ABSOLUTE paths, which take the `/*` branch — but SHARED_PAIRS
    # entries are repo-RELATIVE, so the `*)` branch is the one that actually
    # runs in production. The mutation round found it untested: neutering the
    # relative arm to a no-op left the suite green, because every real member's
    # files exist and no fixture reached that branch with an absent path.
    #
    # This is why missing_member_files takes a root parameter at all.
    assert_equals "ghost.py" \
        "$(missing_member_files "a.py+ghost.py" "$tmpdir")" \
        "missing_member_files names an absent RELATIVE path (the arm SHARED_PAIRS actually uses)"
    assert_equals "" \
        "$(missing_member_files "a.py" "$tmpdir")" \
        "a present RELATIVE path reports nothing (the relative arm is not always-failing)"

    # The present half still extracts, so a missing constituent degrades to a
    # SHORTER region rather than an error — which is precisely why the explicit
    # per-file existence assertion is required and cannot be inferred from a
    # non-empty extract.
    # stderr is silenced HERE ONLY, and only because the missing file is the
    # POINT of this fixture — awk's "cannot open" is the expected noise, and
    # letting it through would print a scary line in a passing report. It is
    # deliberately NOT silenced inside extract_shared_multi: everywhere else a
    # missing file is a real defect and must be loud.
    present="$(extract_shared_multi "${file_a}+${tmpdir}/ghost.py" absent-probe 2>/dev/null | normalize)"
    command rm -rf "$tmpdir"

    assert_equals "ALPHA = 1" "$present" \
        "a member with a missing file reassembles SILENTLY from the rest — the existence check is what catches it"
}

# A member's files are ALL required to exist, and split_member handles the
# one-element case unchanged (#772).
#
# The one-element assertion is what keeps every pre-#772 entry in SHARED_PAIRS
# honest: those members are still written as bare paths, and if split_member
# mangled a path with no `+` in it, four of the five pinned pairs would break at
# once.
test_split_member_handles_both_shapes() {
    local single multi count

    single="$(split_member "path/to/file.py")"
    assert_equals "path/to/file.py" "$single" \
        "a member with no '+' is returned unchanged (every pre-#772 entry keeps working)"

    multi="$(split_member "a.py+b.py+c.py")"
    count="$(command printf '%s\n' "$multi" | command wc -l | command tr -d ' ')"
    assert_equals "3" "$count" "a three-file member splits into three paths"
    assert_equals "a.py" "$(command printf '%s\n' "$multi" | command head -1)" \
        "split_member preserves the first path"
    assert_equals "c.py" "$(command printf '%s\n' "$multi" | command tail -1)" \
        "split_member preserves the last path"

    # label_for_multi must distinguish the shapes, or a failure in the third
    # file of a member reads as one in the first.
    assert_equals "to/file.py" "$(label_for_multi "path/to/file.py")" \
        "label_for_multi renders a single-file member as a plain label"
    assert_contains "$(label_for_multi "x/a.py+x/b.py+x/c.py")" "+2 more" \
        "label_for_multi marks a multi-file member with its extra count"
}

# The Python regions obey the column-zero rule stated in the header — the rule
# that makes `normalize`'s whitespace strip safe for a language where
# indentation is semantic.
#
# Asserted on BOTH copies: the pair could be internally consistent and still
# both wrong, which the byte-identical drift check alone cannot see
# ([[parity-gate-hides-shared-defect]]). Checked against the RAW extract, before
# normalize — normalize is precisely what would erase the evidence.
#
# The property: every non-blank, non-continuation line in a shared Python region
# starts at column 0 or is part of a def/class body, and the region never OPENS
# at an indented line. A region opening indented would mean a fragment of a
# function body had been shared, which is the shape the rule forbids.
test_py_regions_start_at_column_zero() {
    local file label region first col0
    for file in "$DECOMP_PATTERNS_PY" "$SIZING_PY"; do
        label="$(label_for_multi "$file")"
        for region in $PY_REGIONS; do
            # First non-blank line of the raw (un-normalized) extract.
            first="$(extract_shared_multi "$file" "$region" |
                command grep -v '^[[:space:]]*$' | command head -1)"
            assert_not_empty "$first" "${label}: ${region} has a non-blank first line"

            col0="no"
            case "$first" in
                [!\ ]*) col0="yes" ;;
            esac
            assert_equals "yes" "$col0" \
                "${label}: ${region} opens at column zero (no shared function-body fragment)"
        done
    done
}

run_test test_all_regions_match "All shared regions match across every pinned pair"
run_test test_label_for_disambiguates_the_pairs "label_for disambiguates the two same-named patterns.sh copies"
run_test test_debug_region_has_all_language_arms "Debug regions cover every advertised language arm"
run_test test_debug_families_stay_separated "Print and debugger families stay in separate regions (#680)"
run_test test_detector_fires_on_drift "Drift detector fires on a tampered region (print + debugger + is-test-file)"
run_test test_detector_fires_on_py_region_drift "Drift detector fires across the py-public-symbols pair (#609)"
run_test test_detector_fires_on_loc_region_drift "Drift detector fires across the LOC-engine pair (#695)"
run_test test_detector_fires_on_segmenter_region_drift "Drift detector fires across the unit-segmenter pair (#695)"
run_test test_detector_fires_on_split_shape_region_drift "Drift detector fires across the split-shape awk pair (#725)"
run_test test_split_shape_covers_every_segmenter_language "Split-shape keys and segmenter languages are the same set (#725)"
run_test test_detector_fires_on_bloat_region_drift "Drift detector fires across the prose-classification regions (#724)"
run_test test_detector_fires_on_python_primary_drift "Drift detector fires across every region of the Python-primary pair (#730)"
run_test test_py_regions_and_tampers_agree "Every registered Python region has a tamper case, and vice versa (#730)"
run_test test_split_member_handles_both_shapes "split_member handles single- and multi-file members (#772)"
run_test test_multifile_reassembly_preserves_list_order "Multi-file reassembly preserves list order (#772)"
run_test test_missing_constituent_is_detectable "A missing constituent file of a member is detectable (#772)"
run_test test_detector_fires_on_multifile_member_drift "Drift detector fires when one constituent file of a multi-file member drifts (#772)"
run_test test_py_regions_start_at_column_zero "Python regions open at column zero, so normalize's strip is safe (#730)"

generate_report
