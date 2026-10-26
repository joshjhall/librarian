#!/usr/bin/env bash
# Conformance gate for the repo-baseline language slices (#1211).
#
# dev-core's repo-baseline skill defines a slice contract: every
# languages/<lang>.md must carry a fixed list of `##` headings, in order, so the
# audit and scaffold tooling can read any slice generically. The list lives in
# ONE place — between the `slice-contract:required-headings` markers in
# slice-contract.md — and this gate parses it from there rather than keeping a
# copy, so editing the contract changes the gate and there is nothing to drift.
#
# Fails closed on a vacuous corpus: zero parsed headings (markers moved or
# renamed) or zero slices on disk is a FAILURE, not a clean pass — a gate that
# checks nothing must not report that it found nothing wrong.
#
# Pure bash + coreutils (bash-3.2 clean, no sed/grep regex), so it runs the same
# on macOS and Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL_DIR="$REPO_ROOT/plugins/dev-core/skills/repo-baseline"
CONTRACT="$SKILL_DIR/slice-contract.md"
SLICES_DIR="$SKILL_DIR/languages"

test_suite "repo-baseline slice contract conformance"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

# required_headings <contract-file>
# Prints each required heading (e.g. `## CI job`), one per line, from the list
# items between the start and end markers. An item is a line whose first
# backticked span starts with `## `; anything else in the region is ignored.
# Prints NOTHING unless the region is closed by its end marker: an unterminated
# region would otherwise run to EOF and absorb every later list item as a
# requirement, so it fails closed into the zero-heading case instead.
required_headings() {
    local line in_region=0 closed=0 span found=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'<!-- slice-contract:required-headings -->'*)
                in_region=1
                continue
                ;;
            *'<!-- slice-contract:end-required-headings -->'*)
                [ "$in_region" -eq 1 ] && closed=1
                in_region=0
                continue
                ;;
        esac
        [ "$in_region" -eq 1 ] || continue
        case "$line" in
            *'`## '*'`'*)
                span="${line#*\`}"
                span="${span%%\`*}"
                found="$found$span
"
                ;;
        esac
    done <"$1"
    [ "$closed" -eq 1 ] || return 0
    command printf '%s' "$found"
}

# slice_headings <slice-file>
# Prints the slice's `## ` headings in document order, skipping fenced code
# blocks (a `## ` inside a fence is example content, not structure).
slice_headings() {
    local line in_fence=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '```'* | '~~~'*)
                in_fence=$((1 - in_fence))
                continue
                ;;
        esac
        [ "$in_fence" -eq 0 ] || continue
        case "$line" in
            '## '*) command printf '%s\n' "${line%"${line##*[![:space:]]}"}" ;;
        esac
    done <"$1"
}

# conformance_problems <contract-file> <slice-file>
# Prints one line per problem: a required heading that is absent, or present
# but out of the contract's order. Empty output means the slice conforms.
# Order is checked as a subsequence, so extra headings a slice adds AFTER (or
# between) the required ones are allowed, per the contract.
conformance_problems() {
    local contract="$1" slice="$2"
    local req_file="$WORKDIR/req.$$" have_file="$WORKDIR/have.$$"
    required_headings "$contract" >"$req_file"
    slice_headings "$slice" >"$have_file"

    local req have pos last_pos=0
    while IFS= read -r req; do
        pos=0
        local n=0
        while IFS= read -r have; do
            n=$((n + 1))
            if [ "$have" = "$req" ]; then
                pos=$n
                break
            fi
        done <"$have_file"
        if [ "$pos" -eq 0 ]; then
            command printf 'missing heading: %s\n' "$req"
        elif [ "$pos" -lt "$last_pos" ]; then
            command printf 'out of order: %s\n' "$req"
        else
            last_pos=$pos
        fi
    done <"$req_file"
    command rm -f "$req_file" "$have_file"
}

# A minimal fixture contract with three required headings.
FIXTURE_CONTRACT="$WORKDIR/contract.md"
command cat >"$FIXTURE_CONTRACT" <<'EOF'
# Contract

<!-- slice-contract:required-headings -->

1. `## Alpha`
1. `## Beta`
1. `## Gamma`

<!-- slice-contract:end-required-headings -->

1. `## Not required` (outside the markers)
EOF

# --- The real contract and slices -------------------------------------------

test_contract_parses() {
    local count
    count="$(required_headings "$CONTRACT" | command wc -l)"
    count=$((count + 0))
    assert_true "[ $count -gt 0 ]" \
        "slice-contract.md yields at least one required heading (got $count — markers moved?)"
    assert_contains "$(required_headings "$CONTRACT")" "## Open decisions" \
        "The parsed list carries the last contract heading (whole region read)"
}

test_slices_exist() {
    local count=0 f
    for f in "$SLICES_DIR"/*.md; do
        [ -f "$f" ] && count=$((count + 1))
    done
    assert_true "[ $count -gt 0 ]" \
        "At least one languages/*.md slice exists (got $count)"
}

test_every_slice_conforms() {
    local f problems
    for f in "$SLICES_DIR"/*.md; do
        [ -f "$f" ] || continue
        problems="$(conformance_problems "$CONTRACT" "$f")"
        assert_output_empty "$problems" \
            "Slice ${f#"$REPO_ROOT"/} conforms to slice-contract.md"
    done
}

# --- Negative fixtures: the checker must fire --------------------------------

test_fixture_conforming() {
    local slice="$WORKDIR/ok.md"
    command printf '# S\n\n## Alpha\n\n## Beta\n\n## Extra\n\n## Gamma\n' >"$slice"
    assert_output_empty "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "A slice with all headings in order (plus an extra) conforms"
    assert_equals "3" "$(required_headings "$FIXTURE_CONTRACT" | command wc -l | command tr -d ' ')" \
        "Only the items between the markers are required"
}

test_fixture_missing_heading() {
    local slice="$WORKDIR/missing.md"
    command printf '# S\n\n## Alpha\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "missing heading: ## Beta" \
        "A slice missing a required heading is reported, naming the heading"
}

test_fixture_out_of_order() {
    local slice="$WORKDIR/order.md"
    command printf '# S\n\n## Beta\n\n## Alpha\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "out of order: ## Beta" \
        "A slice with required headings out of order is reported"
}

test_fixture_heading_only_in_fence() {
    local slice="$WORKDIR/fence.md"
    command printf '# S\n\n## Alpha\n\n```md\n## Beta\n```\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "missing heading: ## Beta" \
        "A heading that appears only inside a code fence does not count"
}

test_fixture_vacuous_contract() {
    local contract="$WORKDIR/no-markers.md"
    command printf '# Contract\n\n1. `## Alpha`\n' >"$contract"
    assert_output_empty "$(required_headings "$contract")" \
        "A contract without markers parses to zero headings (which test_contract_parses rejects)"
}

test_fixture_unterminated_contract() {
    local contract="$WORKDIR/unterminated.md"
    command printf '# C\n\n<!-- slice-contract:required-headings -->\n\n1. `## Alpha`\n\n1. `## Later`\n' >"$contract"
    assert_output_empty "$(required_headings "$contract")" \
        "A contract whose end marker is missing parses to zero headings, not to everything after the start"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_contract_parses "slice-contract.md's required-heading list parses non-empty"
run_test test_slices_exist "At least one language slice exists"
run_test test_every_slice_conforms "Every language slice carries the required headings in order"
run_test test_fixture_conforming "Fixture: a conforming slice passes"
run_test test_fixture_missing_heading "Fixture: a missing heading is reported"
run_test test_fixture_out_of_order "Fixture: an out-of-order heading is reported"
run_test test_fixture_heading_only_in_fence "Fixture: a fenced-only heading is reported missing"
run_test test_fixture_vacuous_contract "Fixture: a marker-less contract parses empty"
run_test test_fixture_unterminated_contract "Fixture: an unterminated contract region parses empty"

generate_report
