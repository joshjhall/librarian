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

# Locate the next-issue-state schema file wherever the next-issue skill lives.
# Prints the absolute path, or nothing if absent.
find_next_issue_schema() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/next-issue/schemas/next-issue-state.schema.json' \
        2>/dev/null | command sort | command head -1
}

# Locate the next-issue dependency-queue schema file. Prints the absolute path,
# or nothing if absent.
find_next_issue_queue_schema() {
    command find "$PLUGINS_DIR" -type f -path '*/skills/next-issue/schemas/next-issue-queue.schema.json' \
        2>/dev/null | command sort | command head -1
}

# Validate a JSON instance against a (draft-07 subset of a) JSON schema using
# pure jq — ajv is not a dependency in this repo. Checks the parts the
# next-issue-state schema actually uses: required keys present, declared
# property types, string enums, the version const, and (when the schema sets
# additionalProperties:false) rejection of keys not named in `properties`.
# Args: <schema_file> <instance_file>. Returns 0 (valid) / 1 (invalid).
jq_validate_against_schema() {
    local schema="$1" instance="$2"
    jq -n --slurpfile s "$schema" --slurpfile d "$instance" '
        ($s[0]) as $schema | ($d[0]) as $doc |
        # Type-name of a JSON value, mapped to JSON Schema type vocabulary.
        def jstype:
            if type == "number" and (. == floor) then "integer"
            elif type == "number" then "number"
            else type end;
        # A value matches a schema "type" (integer also satisfies "number").
        def type_ok($want; $got): $got == $want or ($want == "number" and $got == "integer");
        ([
            # 1. required keys present
            ( ($schema.required // [])[] as $k | select(($doc | has($k)) | not)
              | "missing required key: \($k)" ),
            # 2. version const
            ( select($schema.properties.version.const != null
                     and $doc.version != null
                     and $doc.version != $schema.properties.version.const)
              | "version const mismatch: expected \($schema.properties.version.const)" ),
            # 3. declared property type + enum checks (top level only)
            ( $doc | to_entries[] as $kv
              | ($schema.properties[$kv.key]) as $prop
              | select($prop != null)
              | (
                  ( select($prop.type != null
                           and (type_ok($prop.type; ($kv.value | jstype)) | not))
                    | "type mismatch for \($kv.key): want \($prop.type), got \($kv.value | jstype)" ),
                  ( select($prop.enum != null and ($prop.enum | index($kv.value)) == null)
                    | "enum violation for \($kv.key): \($kv.value) not in \($prop.enum)" )
                ) ),
            # 4. additionalProperties:false → no unknown top-level keys
            ( select($schema.additionalProperties == false)
              | $doc | keys[] as $k | select(($schema.properties | has($k)) | not)
              | "unknown property (additionalProperties:false): \($k)" )
          ] | if length == 0 then empty else (.[] | "  - \(.)"), error("schema validation failed") end)
    ' >/dev/null 2>&1
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

# Extract category slugs from a skill's pre-scan implementation. A tool may ship
# a bash impl (patterns.sh), a Python primary (patterns.py, issue #17), or both
# behind the shared TSV contract; the emitted category is the same quoted slug in
# either language. Union the slugs across whichever files exist so the contract
# cross-check stays honest after a tool is ported to Python. `$1` is the
# patterns.sh path (may be absent); the sibling patterns.py is derived from it.
extract_patterns_categories() {
    local sh_file="$1"
    local py_file="${sh_file%patterns.sh}patterns.py"
    {
        [ -f "$sh_file" ] && command grep -oP '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$sh_file"
        [ -f "$py_file" ] && command grep -oP '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$py_file"
    } |
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

# --- next-issue-state Schema Tests ------------------------------------------

# next-issue-state.schema.json is valid JSON (when present + jq available).
test_next_issue_schema_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-state.schema.json"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no state schema to validate"
        return
    fi
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "next-issue-state.schema.json is not valid JSON"
    # additionalProperties:false is the load-bearing guard against silent
    # state-file typos — assert it is actually set at the top level.
    assert_true "jq -e '.additionalProperties == false' '$schema_file' >/dev/null 2>&1" \
        "next-issue-state.schema.json must set top-level additionalProperties:false"
}

# A representative state doc validates against the schema.
test_next_issue_schema_accepts_valid_doc() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-state sample doc"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no state schema to validate against"
        return
    fi
    local tmpdoc
    tmpdoc="$(/usr/bin/mktemp)"
    # Exercises autonomy_level, plan_comment_url, and a full checkpoint object —
    # the fields the autonomy-level work relies on (#215 dropped the autonomous /
    # plan_gated mirror fields; the schema now rejects them).
    cat >"$tmpdoc" <<'JSON'
{
  "version": 2,
  "issue": 101,
  "title": "Fix critical auth bypass in session handler",
  "phase": "plan",
  "branch": "fix/issue-101-auth-bypass",
  "plan": "Validate session token expiry before granting access",
  "started": "2026-02-27",
  "platform": "github",
  "autonomy_level": 4,
  "plan_comment_url": "https://github.com/o/r/issues/101#issuecomment-1",
  "contexts": ["security", "auth"],
  "active_loops": ["make-it-work", "make-it-secure"],
  "checkpoint": {
    "completed_phase": "plan",
    "key_decisions": ["Using env var for timeout, not config file"],
    "files_modified": [],
    "files_planned": ["src/auth/session.ts"],
    "warnings": ["Tests mock the timeout value"],
    "next_action": "Begin implementation loop: make-it-work"
  }
}
JSON
    assert_true "jq_validate_against_schema '$schema_file' '$tmpdoc'" \
        "valid next-issue-state doc rejected by schema validator"
    /usr/bin/rm -f "$tmpdoc"
}

# additionalProperties:false rejects a doc carrying an unknown top-level key —
# including the plan_gated / autonomous mirror fields dropped in #215.
test_next_issue_schema_rejects_unknown_property() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-state rejection"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no state schema to validate against"
        return
    fi
    local tmpdoc
    tmpdoc="$(/usr/bin/mktemp)"
    # Same minimal-valid doc plus the removed plan_gated mirror, which is now an
    # unknown top-level key that must be rejected (#215).
    cat >"$tmpdoc" <<'JSON'
{
  "version": 2,
  "issue": 101,
  "title": "Some issue",
  "phase": "select",
  "started": "2026-02-27",
  "platform": "github",
  "plan_gated": true
}
JSON
    # The validator must FAIL here (unknown key under additionalProperties:false).
    assert_true "! jq_validate_against_schema '$schema_file' '$tmpdoc'" \
        "schema validator accepted the removed plan_gated mirror field"
    /usr/bin/rm -f "$tmpdoc"
}

# next-issue-queue.schema.json is valid JSON + closed (when present + jq).
test_next_issue_queue_schema_valid() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-queue.schema.json"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_queue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no queue schema to validate"
        return
    fi
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "next-issue-queue.schema.json is not valid JSON"
    # additionalProperties:false guards against silent queue-file typos.
    assert_true "jq -e '.additionalProperties == false' '$schema_file' >/dev/null 2>&1" \
        "next-issue-queue.schema.json must set top-level additionalProperties:false"
}

# A representative queue doc validates against the queue schema.
test_next_issue_queue_schema_accepts_valid_doc() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-queue sample doc"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_queue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no queue schema to validate against"
        return
    fi
    local tmpdoc
    tmpdoc="$(/usr/bin/mktemp)"
    # A queue driving toward #5 with deps #4, #2 resolved deepest-first.
    cat >"$tmpdoc" <<'JSON'
{
  "version": 1,
  "target": 5,
  "ordered": [4, 2, 5],
  "remaining": [4, 2, 5],
  "active": 4,
  "created": "2026-07-02",
  "platform": "github"
}
JSON
    assert_true "jq_validate_against_schema '$schema_file' '$tmpdoc'" \
        "valid next-issue-queue doc rejected by schema validator"
    /usr/bin/rm -f "$tmpdoc"
}

# additionalProperties:false rejects a queue doc with an unknown top-level key.
test_next_issue_queue_schema_rejects_unknown_property() {
    if [ "$HAVE_JQ" -ne 1 ]; then
        skip_test "jq not available — cannot validate next-issue-queue rejection"
        return
    fi
    local schema_file
    schema_file="$(find_next_issue_queue_schema)"
    if [ -z "$schema_file" ]; then
        skip_test "next-issue skill not present — no queue schema to validate against"
        return
    fi
    local tmpdoc
    tmpdoc="$(/usr/bin/mktemp)"
    # Same minimal-valid doc plus a bogus top-level key that must be rejected.
    cat >"$tmpdoc" <<'JSON'
{
  "version": 1,
  "target": 5,
  "ordered": [4, 2, 5],
  "remaining": [4, 2, 5],
  "active": 4,
  "created": "2026-07-02",
  "platform": "github",
  "bogus_unknown_field": "should be rejected"
}
JSON
    # The validator must FAIL here (unknown key under additionalProperties:false).
    assert_true "! jq_validate_against_schema '$schema_file' '$tmpdoc'" \
        "queue schema validator accepted an unknown top-level property"
    /usr/bin/rm -f "$tmpdoc"
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
run_test test_next_issue_schema_valid "next-issue-state.schema.json is valid JSON + additionalProperties:false"
run_test test_next_issue_schema_accepts_valid_doc "next-issue-state schema accepts a valid doc"
run_test test_next_issue_schema_rejects_unknown_property "next-issue-state schema rejects unknown property"
run_test test_next_issue_queue_schema_valid "next-issue-queue.schema.json is valid JSON + additionalProperties:false"
run_test test_next_issue_queue_schema_accepts_valid_doc "next-issue-queue schema accepts a valid doc"
run_test test_next_issue_queue_schema_rejects_unknown_property "next-issue-queue schema rejects unknown property"
run_test test_check_contract_json_valid "check-* contract.md JSON examples are valid"
run_test test_check_contract_required_fields "check-* contract examples have all required fields"
run_test test_check_contract_enum_values "check-* contract enum values are valid"
run_test test_check_contract_version "check-* contracts have version field"
run_test test_loop_contract_json_valid "loop-* contract.md JSON examples are valid"
run_test test_loop_contract_required_fields "loop-* contract examples have all required fields"
run_test test_loop_contract_version "loop-* contracts have version field"
run_test test_category_cross_check "check-* contract categories match patterns.sh"

generate_report
