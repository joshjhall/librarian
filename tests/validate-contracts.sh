#!/usr/bin/env bash
# Contract validation for check-* and loop-* skill contracts in the librarian
# plugins. Relocated from containers tests/unit/claude/validate_contracts.sh and
# retargeted from templates/claude/skills to plugins/*/skills.
#
# Validates:
# - JSON examples in contract.md are valid JSON
# - check-* contract examples have all required finding-schema fields
# - loop-* contract examples have all required loop-report fields
# - Contract version field exists
# - check-* contract categories match patterns.sh output categories
# - The codebase-audit finding/loop schemas (wherever that skill lives) are JSON
#
# Uses jq for JSON parsing when available; skips JSON-shape tests gracefully
# otherwise. No Docker. Empty plugins PASS — the check-*/loop-* discovery globs
# find nothing and every loop no-ops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Skill Contract Validation"

# --- Discovery helpers ------------------------------------------------------

# List check-*/loop-* skill dirs across all plugins (absolute paths, sorted).
# Usage: list_prefixed_skill_dirs <prefix>
list_prefixed_skill_dirs() {
    local prefix="$1"
    command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' \
        -name "${prefix}*" 2>/dev/null | command sort
}

# Locate the codebase-audit skill directory (carries the shared schemas) wherever
# it lives among the plugins. Prints the first match, or nothing if absent.
find_schema_dir() {
    command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' \
        -name "codebase-audit" 2>/dev/null | command sort | command head -1
}

# Extract JSON from the last ```json fence in a file (later fences may hold
# sub-objects like certainty; the example finding is last).
extract_json_from_markdown() {
    local file="$1"
    /usr/bin/awk '
        /^```json$/ { in_fence=1; content=""; next }
        /^```$/ && in_fence { in_fence=0; last=content; next }
        in_fence { content = content (content ? "\n" : "") $0 }
        END { if (last) print last }
    ' "$file"
}

# Extract category slugs from a contract.md Categories table.
extract_contract_categories() {
    local file="$1"
    command grep -oP '`\K[a-z][a-z0-9-]+(?=`)' "$file" |
        command grep -v '^version$\|^deterministic$\|^heuristic$\|^llm$\|^finding-schema\|^compatible' |
        command sort -u
}

# Extract category slugs from a patterns.sh script.
extract_patterns_categories() {
    local file="$1"
    command grep -oP '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$file" |
        command sed 's/"//g' |
        command sort -u
}

# Required fields for a finding (from finding-schema.md).
FINDING_REQUIRED_FIELDS="id category severity title description file line_start line_end evidence suggestion effort tags related_files certainty"

# Required fields for a loop report.
LOOP_REQUIRED_FIELDS="loop status changes blockers_resolved blockers_remaining tests_passing commit"

# jq availability — many tests need it; check once.
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
fi

# --- Schema File Tests ------------------------------------------------------

# finding-schema.schema.json is valid JSON (when the codebase-audit skill and jq
# are both present).
test_finding_schema_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate finding-schema.schema.json"
        return
    fi
    local schema_dir
    schema_dir="$(find_schema_dir)"
    if [ -z "$schema_dir" ]; then
        skip_test "codebase-audit skill not present — no finding-schema to validate"
        return
    fi
    local schema_file="$schema_dir/finding-schema.schema.json"
    [ -f "$schema_file" ] || {
        skip_test "finding-schema.schema.json absent"
        return
    }
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "finding-schema.schema.json is not valid JSON"
}

# loop-report.schema.json is valid JSON (when present + jq available).
test_loop_report_schema_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate loop-report.schema.json"
        return
    fi
    local schema_dir
    schema_dir="$(find_schema_dir)"
    if [ -z "$schema_dir" ]; then
        skip_test "codebase-audit skill not present — no loop-report schema to validate"
        return
    fi
    local schema_file="$schema_dir/loop-report.schema.json"
    [ -f "$schema_file" ] || {
        skip_test "loop-report.schema.json absent"
        return
    }
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "loop-report.schema.json is not valid JSON"
}

# --- check-* Contract Tests -------------------------------------------------

# Every check-* contract.md has a valid JSON example.
test_check_contract_json_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate check-* contract JSON"
        return
    fi
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file json tmpfile
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        json="$(extract_json_from_markdown "$contract_file")"
        assert_not_empty "$json" "check-* skill $skill_name: no JSON found in contract.md"
        [ -z "$json" ] && continue

        tmpfile="$(/usr/bin/mktemp)"
        printf '%s' "$json" >"$tmpfile"
        assert_true "jq empty '$tmpfile' 2>/dev/null" \
            "check-* skill $skill_name: contract.md JSON is not valid"
        /usr/bin/rm -f "$tmpfile"
    done < <(list_prefixed_skill_dirs "check-")
}

# check-* contract JSON examples have all required finding fields.
test_check_contract_required_fields() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate check-* contract fields"
        return
    fi
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file json tmpfile field
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        tmpfile="$(/usr/bin/mktemp)"
        printf '%s' "$json" >"$tmpfile"
        for field in $FINDING_REQUIRED_FIELDS; do
            assert_true "jq -e 'has(\"$field\")' '$tmpfile' >/dev/null 2>&1" \
                "check-* skill $skill_name: contract example missing required field '$field'"
        done
        /usr/bin/rm -f "$tmpfile"
    done < <(list_prefixed_skill_dirs "check-")
}

# check-* contract enum values are valid (severity/effort/certainty.*).
test_check_contract_enum_values() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate check-* enum values"
        return
    fi
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file json tmpfile
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        tmpfile="$(/usr/bin/mktemp)"
        printf '%s' "$json" >"$tmpfile"

        local severity effort cert_level cert_method cert_conf
        severity="$(jq -r '.severity // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$severity" ]; then
            assert_true "printf '%s' '$severity' | command grep -qE '^(critical|high|medium|low)$'" \
                "check-* skill $skill_name: invalid severity '$severity'"
        fi
        effort="$(jq -r '.effort // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$effort" ]; then
            assert_true "printf '%s' '$effort' | command grep -qE '^(trivial|small|medium|large)$'" \
                "check-* skill $skill_name: invalid effort '$effort'"
        fi
        cert_level="$(jq -r '.certainty.level // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_level" ]; then
            assert_true "printf '%s' '$cert_level' | command grep -qE '^(CRITICAL|HIGH|MEDIUM|LOW)$'" \
                "check-* skill $skill_name: invalid certainty level '$cert_level'"
        fi
        cert_method="$(jq -r '.certainty.method // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_method" ]; then
            assert_true "printf '%s' '$cert_method' | command grep -qE '^(deterministic|heuristic|llm)$'" \
                "check-* skill $skill_name: invalid certainty method '$cert_method'"
        fi
        cert_conf="$(jq -r '.certainty.confidence // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_conf" ]; then
            assert_true "printf '%s' '$cert_conf' | command grep -qE '^[01]\\.?[0-9]*$'" \
                "check-* skill $skill_name: certainty confidence '$cert_conf' out of 0-1 range"
        fi
        /usr/bin/rm -f "$tmpfile"
    done < <(list_prefixed_skill_dirs "check-")
}

# check-* contract version exists.
test_check_contract_version() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        assert_true "command grep -q 'version:' '$contract_file'" \
            "check-* skill $skill_name: contract.md missing version field"
    done < <(list_prefixed_skill_dirs "check-")
}

# --- loop-* Contract Tests --------------------------------------------------

# Every loop-* contract.md has a valid JSON example.
test_loop_contract_json_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate loop-* contract JSON"
        return
    fi
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file json tmpfile
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        json="$(extract_json_from_markdown "$contract_file")"
        assert_not_empty "$json" "loop-* skill $skill_name: no JSON found in contract.md"
        [ -z "$json" ] && continue

        tmpfile="$(/usr/bin/mktemp)"
        printf '%s' "$json" >"$tmpfile"
        assert_true "jq empty '$tmpfile' 2>/dev/null" \
            "loop-* skill $skill_name: contract.md JSON is not valid"
        /usr/bin/rm -f "$tmpfile"
    done < <(list_prefixed_skill_dirs "loop-")
}

# loop-* contract JSON examples have all required loop-report fields.
test_loop_contract_required_fields() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate loop-* contract fields"
        return
    fi
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file json tmpfile field
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        tmpfile="$(/usr/bin/mktemp)"
        printf '%s' "$json" >"$tmpfile"
        for field in $LOOP_REQUIRED_FIELDS; do
            assert_true "jq -e 'has(\"$field\")' '$tmpfile' >/dev/null 2>&1" \
                "loop-* skill $skill_name: contract example missing required field '$field'"
        done
        /usr/bin/rm -f "$tmpfile"
    done < <(list_prefixed_skill_dirs "loop-")
}

# loop-* contract version exists.
test_loop_contract_version() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue
        assert_true "command grep -q 'version:' '$contract_file'" \
            "loop-* skill $skill_name: contract.md missing version field"
    done < <(list_prefixed_skill_dirs "loop-")
}

# --- Category Cross-Check ----------------------------------------------------

# check-* contract categories match patterns.sh output categories.
test_category_cross_check() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name contract_file patterns_file contract_cats patterns_cats cat
        skill_name="$(/usr/bin/basename "$skill_dir")"
        contract_file="$skill_dir/contract.md"
        patterns_file="$skill_dir/patterns.sh"
        [ -f "$contract_file" ] || continue
        [ -f "$patterns_file" ] || continue

        contract_cats="$(extract_contract_categories "$contract_file")"
        patterns_cats="$(extract_patterns_categories "$patterns_file")"
        [ -z "$contract_cats" ] && continue
        [ -z "$patterns_cats" ] && continue

        while IFS= read -r cat; do
            [ -z "$cat" ] && continue
            assert_true "printf '%s' '$contract_cats' | command grep -qF '$cat'" \
                "check-* skill $skill_name: patterns.sh outputs category '$cat' not declared in contract.md"
        done <<<"$patterns_cats"
    done < <(list_prefixed_skill_dirs "check-")
}

# --- Run All Tests ----------------------------------------------------------

run_test test_finding_schema_valid "finding-schema.schema.json is valid JSON"
run_test test_loop_report_schema_valid "loop-report.schema.json is valid JSON"
run_test test_check_contract_json_valid "check-* contract.md JSON examples are valid"
run_test test_check_contract_required_fields "check-* contract examples have all required fields"
run_test test_check_contract_enum_values "check-* contract enum values are valid"
run_test test_check_contract_version "check-* contracts have version field"
run_test test_loop_contract_json_valid "loop-* contract.md JSON examples are valid"
run_test test_loop_contract_required_fields "loop-* contract examples have all required fields"
run_test test_loop_contract_version "loop-* contracts have version field"
run_test test_category_cross_check "check-* contract categories match patterns.sh"

generate_report
