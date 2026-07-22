#!/usr/bin/env bash
# agnix→TSV normalizer gate (issue #397).
#
# agnix-normalize.{py,sh} is the boundary object of the agnix integration spine
# (ADR plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md): it
# maps `agnix --format json` findings to the repo's TSV finding contract
# (file<TAB>line<TAB>category<TAB>evidence<TAB>certainty), carrying the CC-* rule
# ID -> check-ai-config category map. This gate pins that behavior exhaustively:
#
#   1. Byte-correct TSV — a captured agnix JSON fixture (mix of CC-AG/CC-SK/CC-HK/
#      MCP/CC-PL/CC-MEM rows + a VER-001 project row + an unmapped AS-* row)
#      maps to exactly the expected rows: mapped category, `[RULE] message`
#      evidence truncated to 80 codepoints, passed-through certainty. Unmapped
#      rules and empty-`file` diagnostics are dropped. (Acceptance criterion 1.)
#   2. Absent-binary no-op — AGNIX_BIN=/nonexistent -> empty stdout, exit 0, a
#      clear skip line on stderr. (Acceptance criterion 2.)
#   3. Fail-loud — missing arg -> exit 1 + Usage; malformed/empty agnix output ->
#      exit 2 + actionable message; agnix present but jq absent (bash) -> exit 2.
#   4. Edge — empty file-list -> exit 0, no output (no agnix invocation).
#   5. bash<->python PARITY — the bash fallback (PATTERNS_FORCE_BASH=1) and, when
#      a python3>=3.11 is present, the python primary emit byte-identical output
#      for every row above. The language boundary is the output, not the impl.
#
# The stub AGNIX_BIN makes every assertion deterministic without the real Rust
# binary. The bash path is always exercised; the python path + parity are skipped
# (not failed) when python3>=3.11 is unavailable, mirroring validate-python-ports.sh.
# The whole jq-dependent bash body is skipped when jq is absent (the tool needs
# jq for its bash fallback). Pure bash + coreutils (+ jq, python3 when present).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/check-ai-config"
SH="$SKILL_DIR/agnix-normalize.sh"
PY="$SKILL_DIR/agnix-normalize.py"
REAL_BASH="$(command -v bash)"

# Is a usable python3 primary available? Parity is only asserted where it is.
HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

test_suite "agnix→TSV normalizer (#397)"

# The bash fallback parses JSON with jq. Without jq the bash body cannot run, so
# skip the whole suite (the python primary alone is not the fallback contract).
if ! command -v jq >/dev/null 2>&1; then
    skip_test "jq not available — bash fallback requires jq (python primary is covered where python3>=3.11 exists)"
    generate_report
    return 0 2>/dev/null || exit 0
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- stub agnix: echoes a captured JSON fixture regardless of args -----------
# The fixture mirrors the REAL agnix schema captured from the 0.40.0 binary, i.e.
# {version, files_checked, diagnostics:[{level,rule,file,line,column,message,
# suggestion,category,rule_severity,applies_to_tool}], summary}. It exercises
# every mapped prefix, plus a VER-001 project-level row (empty file) and an
# unmapped AS-* row — both of which MUST be dropped.
STUB="$WORKDIR/stub-agnix.sh"
command cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
command cat <<'JSON'
{
  "version": "0.40.0",
  "files_checked": 6,
  "diagnostics": [
    {"level":"error","rule":"CC-AG-001","file":"agents/a.md","line":1,"column":1,"message":"Agent frontmatter is missing required 'name' field","suggestion":"add name","category":"claude-agents","rule_severity":"HIGH","applies_to_tool":"claude-code"},
    {"level":"error","rule":"CC-SK-001","file":"skills/s/SKILL.md","line":3,"column":1,"message":"Invalid model value","suggestion":"use a valid model","category":"claude-skills","rule_severity":"HIGH"},
    {"level":"error","rule":"CC-HK-009","file":"hooks/h.sh","line":7,"column":1,"message":"Dangerous command pattern detected","suggestion":"guard it","category":"claude-hooks","rule_severity":"HIGH"},
    {"level":"warning","rule":"MCP-008","file":"mcp.json","line":2,"column":1,"message":"Protocol version mismatch","suggestion":"pin version","category":"mcp","rule_severity":"MEDIUM"},
    {"level":"error","rule":"CC-MCP-001","file":"cc-mcp.json","line":4,"column":1,"message":"CC MCP rule","suggestion":"fix","category":"claude-mcp","rule_severity":"HIGH"},
    {"level":"error","rule":"CC-PL-001","file":".claude-plugin/x.json","line":1,"column":1,"message":"Plugin manifest not in .claude-plugin/","suggestion":"move it","category":"claude-plugins","rule_severity":"HIGH"},
    {"level":"error","rule":"CC-MEM-001","file":"CLAUDE.md","line":5,"column":1,"message":"Invalid import path","suggestion":"fix path","category":"claude-memory","rule_severity":"HIGH"},
    {"level":"info","rule":"VER-001","file":"","line":1,"column":1,"message":"No tool or spec versions pinned","suggestion":"pin","category":"version-awareness","rule_severity":"LOW"},
    {"level":"warning","rule":"AS-042","file":"agents/a.md","line":9,"column":1,"message":"Generic spec rule not in overlap set","suggestion":"n/a","category":"agent-spec","rule_severity":"MEDIUM"}
  ],
  "summary": {"errors":5,"warnings":2,"info":1}
}
JSON
STUBEOF
command chmod +x "$STUB"

# A stub that emits a very long message so the 80-codepoint truncation shows.
STUB_LONG="$WORKDIR/stub-long.sh"
command cat >"$STUB_LONG" <<'STUBEOF'
#!/usr/bin/env bash
command cat <<'JSON'
{"version":"0.40.0","files_checked":1,"diagnostics":[
 {"rule":"CC-AG-001","file":"a.md","line":1,"message":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","rule_severity":"HIGH"}
],"summary":{}}
JSON
STUBEOF
command chmod +x "$STUB_LONG"

# A stub emitting non-JSON -> fail-loud parse path.
STUB_BAD="$WORKDIR/stub-bad.sh"
command printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "not json {{{"' >"$STUB_BAD"
command chmod +x "$STUB_BAD"

# A stub emitting nothing -> fail-loud empty-output path.
STUB_EMPTY="$WORKDIR/stub-empty.sh"
command printf '%s\n%s\n' '#!/usr/bin/env bash' 'printf ""' >"$STUB_EMPTY"
command chmod +x "$STUB_EMPTY"

# A stub emitting a top-level JSON ARRAY (not an object) -> malformed-shape
# fail-loud. Both impls must exit 2 with no output, not silently no-op (python)
# or emit (bash). Pins the parity the pre-PR review found diverging.
STUB_TOPARR="$WORKDIR/stub-toparr.sh"
command printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "[1,2,3]"' >"$STUB_TOPARR"
command chmod +x "$STUB_TOPARR"

# A stub whose top-level `diagnostics` value is JSON null (a plausible serde
# Option<Vec<..>> shape for zero findings) -> both impls treat it as a clean
# empty result (exit 0, no output), matching jq's `(.diagnostics // [])`. NOT a
# hard failure. Pins the top-level null-coalescing parity.
STUB_DIAGNULL="$WORKDIR/stub-diagnull.sh"
command printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "{\"diagnostics\": null}"' >"$STUB_DIAGNULL"
command chmod +x "$STUB_DIAGNULL"

# A stub whose diagnostics array holds a VALID dict followed by a NON-dict
# element -> both impls must fail loud (exit 2) with NO partial row on stdout
# (the valid dict must not leak before the error). Pins fail-loud-before-output.
STUB_NONDICT="$WORKDIR/stub-nondict.sh"
command cat >"$STUB_NONDICT" <<'STUBEOF'
#!/usr/bin/env bash
command printf '%s\n' '{"diagnostics":[{"rule":"CC-AG-001","file":"a.md","line":1,"message":"m","rule_severity":"HIGH"},42]}'
STUBEOF
command chmod +x "$STUB_NONDICT"

FILE_LIST="$WORKDIR/list.txt"
command printf '%s\n' "agents/a.md" >"$FILE_LIST"
EMPTY_LIST="$WORKDIR/empty.txt"
: >"$EMPTY_LIST"

# A stub that RECORDS the count of path arguments it received (everything after
# `validate`) into a side file, then emits a trivial valid JSON. Used to prove a
# manifest path containing a space is passed as ONE argv element (not word-split)
# in both impls — a divergence class the fixed-output STUB above cannot catch.
ARGC_FILE="$WORKDIR/argc.txt"
CONFIG_FILE="$WORKDIR/config-seen.txt"
STUB_ARGC="$WORKDIR/stub-argc.sh"
command cat >"$STUB_ARGC" <<STUBEOF
#!/usr/bin/env bash
# Skip the leading "--format json --target claude-code validate", record an
# optional "--config X" (value, and that it precedes the "--" marker), then the
# "--" end-of-options marker, then count the remaining path args. Everything
# after "--" is a positional path regardless of shape.
_seen_validate=0
_after_ddash=0
_paths=0
_config="__NONE__"
while [ \$# -gt 0 ]; do
    if [ "\$_after_ddash" = "1" ]; then
        _paths=\$((_paths + 1))
        shift
        continue
    fi
    if [ "\$_seen_validate" = "1" ]; then
        case "\$1" in
            --config)
                # Record the value; that we see it here (pre-"--") proves correct
                # ordering — a --config placed after "--" would be counted as a path.
                shift
                _config="\$1"
                ;;
            --) _after_ddash=1 ;;
            *) _paths=\$((_paths + 1)) ;;
        esac
    fi
    case "\$1" in validate) _seen_validate=1 ;; esac
    shift
done
printf '%s' "\$_paths" >"$ARGC_FILE"
printf '%s' "\$_config" >"$CONFIG_FILE"
printf '%s\n' '{"diagnostics":[]}'
STUBEOF
command chmod +x "$STUB_ARGC"
SPACE_LIST="$WORKDIR/space-list.txt"
command printf '%s\n' "some dir/with space/agent.md" >"$SPACE_LIST"

# A manifest with a real path, a blank line, and a WHITESPACE-ONLY line: both
# impls must drop the blank + whitespace-only lines (python's `ln.strip()`, bash's
# `*[![:space:]]*` guard) and pass exactly ONE path. A bash `case "" )`-only guard
# would leak the whitespace line as a spurious agnix arg (parity break).
WS_LIST="$WORKDIR/ws-list.txt"
command printf '%s\n' "agents/real.md" "" "   " >"$WS_LIST"

# A stub whose diagnostics carry JSON `null` fields: file=null (must be DROPPED,
# not emitted at file "None"), and line/message/rule_severity=null (must coalesce
# to "" — matching jq's `// ""`), plus a normal mapped row. Pins python↔bash
# parity on null values (a bare str(None) would emit the literal "None").
STUB_NULL="$WORKDIR/stub-null.sh"
command cat >"$STUB_NULL" <<'STUBEOF'
#!/usr/bin/env bash
command printf '%s\n' '{"diagnostics":[{"rule":"CC-AG-001","file":null,"line":1,"message":"dropped: null file","rule_severity":"HIGH"},{"rule":"CC-SK-001","file":"skills/s.md","line":null,"message":null,"rule_severity":null}]}'
STUBEOF
command chmod +x "$STUB_NULL"

# Expected byte-correct TSV for the full fixture (mapped rows only, insertion
# order). Tabs are literal via printf's \t. This is acceptance criterion 1.
EXPECTED_TSV="$(command printf '%s\n' \
    "agents/a.md	1	agent-frontmatter	[CC-AG-001] Agent frontmatter is missing required 'name' field	HIGH" \
    "skills/s/SKILL.md	3	skill-frontmatter	[CC-SK-001] Invalid model value	HIGH" \
    "hooks/h.sh	7	hook-safety	[CC-HK-009] Dangerous command pattern detected	HIGH" \
    "mcp.json	2	mcp-misconfiguration	[MCP-008] Protocol version mismatch	MEDIUM" \
    "cc-mcp.json	4	mcp-misconfiguration	[CC-MCP-001] CC MCP rule	HIGH" \
    ".claude-plugin/x.json	1	config-inconsistency	[CC-PL-001] Plugin manifest not in .claude-plugin/	HIGH" \
    "CLAUDE.md	5	claude-md-drift	[CC-MEM-001] Invalid import path	HIGH")"

# run_bash <env-assignments...> -- <args...> — run the bash fallback with the
# given AGNIX_BIN env, capturing stdout (only) into RUN_OUT, stderr into RUN_ERR,
# exit code into RUN_RC. The forced bash body is the fallback contract under test.
RUN_OUT=""
RUN_ERR=""
RUN_RC=0
run_bash() {
    _rb_bin="$1"
    shift
    RUN_ERR="$WORKDIR/stderr.$$"
    RUN_OUT="$(AGNIX_BIN="$_rb_bin" PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" "$@" 2>"$RUN_ERR")" &&
        RUN_RC=0 || RUN_RC=$?
    RUN_ERR="$(command cat "$RUN_ERR" 2>/dev/null || true)"
}

# run_py <bin> -- <args...> — same for the python primary; used only for parity.
run_py() {
    _rp_bin="$1"
    shift
    PY_OUT="$(AGNIX_BIN="$_rp_bin" python3 "$PY" "$@" 2>/dev/null)" && PY_RC=0 || PY_RC=$?
}

# --- 1. byte-correct TSV + parity --------------------------------------------

test_byte_correct_tsv() {
    run_bash "$STUB" "$FILE_LIST"
    assert_exit 0 "$RUN_RC" "bash: full fixture exits 0"
    assert_equals "$EXPECTED_TSV" "$RUN_OUT" "bash: fixture maps to exact expected TSV rows"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB" "$FILE_LIST"
        assert_exit 0 "$PY_RC" "python: full fixture exits 0"
        assert_equals "$EXPECTED_TSV" "$PY_OUT" "python: fixture maps to exact expected TSV rows"
        assert_equals "$RUN_OUT" "$PY_OUT" "parity: bash == python on the fixture"
    fi
}

test_unmapped_and_project_rows_dropped() {
    # VER-001 (empty file, unmapped) and AS-042 (unmapped prefix) must not appear.
    run_bash "$STUB" "$FILE_LIST"
    assert_not_contains "$RUN_OUT" "VER-001" "bash: VER-001 project row is dropped"
    assert_not_contains "$RUN_OUT" "AS-042" "bash: unmapped AS-* row is dropped"
    assert_not_contains "$RUN_OUT" "version-awareness" "bash: agnix category strings never leak into TSV"
}

test_evidence_truncated_to_80() {
    # The `[RULE] message` evidence column is capped at 80 codepoints (matches
    # patterns.py str[:80]); parity holds on the boundary.
    run_bash "$STUB_LONG" "$FILE_LIST"
    _ev="$(command printf '%s' "$RUN_OUT" | command awk -F'\t' 'NR==1{print length($4)}')"
    assert_equals "80" "$_ev" "bash: evidence truncated to 80 codepoints"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_LONG" "$FILE_LIST"
        assert_equals "$RUN_OUT" "$PY_OUT" "parity: truncation identical bash == python"
    fi
}

# --- 2. absent-binary no-op --------------------------------------------------

test_absent_binary_noop() {
    run_bash "/nonexistent/agnix-binary" "$FILE_LIST"
    assert_exit 0 "$RUN_RC" "bash: absent binary exits 0 (no-op, not an error)"
    assert_output_empty "$RUN_OUT" "bash: absent binary emits nothing to stdout"
    assert_contains "$RUN_ERR" "[skip]" "bash: absent binary logs a clear skip line"
    assert_contains "$RUN_ERR" "agnix binary not found" "bash: skip line names the cause"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "/nonexistent/agnix-binary" "$FILE_LIST"
        assert_exit 0 "$PY_RC" "python: absent binary exits 0"
        assert_output_empty "$PY_OUT" "python: absent binary emits nothing"
    fi
}

# --- 3. fail-loud ------------------------------------------------------------

test_missing_arg_usage() {
    RUN_ERR="$WORKDIR/stderr.$$"
    RUN_OUT="$(PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" 2>"$RUN_ERR")" && RUN_RC=0 || RUN_RC=$?
    RUN_ERR="$(command cat "$RUN_ERR")"
    assert_exit 1 "$RUN_RC" "bash: missing arg exits 1"
    assert_contains "$RUN_ERR" "Usage:" "bash: missing arg prints Usage"
    if [ "$HAVE_PY" = "1" ]; then
        _mp_err="$(python3 "$PY" 2>&1 >/dev/null)" && _mp_rc=0 || _mp_rc=$?
        assert_exit 1 "$_mp_rc" "python: missing arg exits 1"
        assert_contains "$_mp_err" "Usage" "python: missing arg prints Usage"
    fi
}

test_missing_filelist() {
    run_bash "$STUB" "$WORKDIR/does-not-exist.txt"
    assert_exit 1 "$RUN_RC" "bash: absent file list exits 1"
    assert_contains "$RUN_ERR" "file list not found" "bash: absent file list is reported"
}

test_malformed_json_fails_loud() {
    run_bash "$STUB_BAD" "$FILE_LIST"
    assert_exit 2 "$RUN_RC" "bash: unparsable agnix output exits 2"
    assert_contains "$RUN_ERR" "agnix-normalize:" "bash: parse failure is actionable"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_BAD" "$FILE_LIST"
        assert_exit 2 "$PY_RC" "python: unparsable agnix output exits 2"
    fi
}

test_empty_output_fails_loud() {
    run_bash "$STUB_EMPTY" "$FILE_LIST"
    assert_exit 2 "$RUN_RC" "bash: empty agnix output exits 2"
    assert_contains "$RUN_ERR" "no JSON output" "bash: empty output is reported"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_EMPTY" "$FILE_LIST"
        assert_exit 2 "$PY_RC" "python: empty agnix output exits 2"
    fi
}

test_top_level_array_fails_loud() {
    # A non-object top level is malformed — both impls fail loud (exit 2), never
    # a silent no-op. (Pre-PR review: python previously exited 0 here.)
    run_bash "$STUB_TOPARR" "$FILE_LIST"
    assert_exit 2 "$RUN_RC" "bash: top-level JSON array exits 2"
    assert_output_empty "$RUN_OUT" "bash: top-level array emits nothing"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_TOPARR" "$FILE_LIST"
        assert_exit 2 "$PY_RC" "python: top-level JSON array exits 2 (no silent no-op)"
        assert_output_empty "$PY_OUT" "python: top-level array emits nothing"
    fi
}

test_diagnostics_null_is_empty() {
    # A top-level `"diagnostics": null` is a clean empty result in BOTH impls
    # (jq `// []`), not a hard failure — python previously exited 2 here.
    run_bash "$STUB_DIAGNULL" "$FILE_LIST"
    assert_exit 0 "$RUN_RC" "bash: diagnostics:null exits 0 (empty result)"
    assert_output_empty "$RUN_OUT" "bash: diagnostics:null emits nothing"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_DIAGNULL" "$FILE_LIST"
        assert_exit 0 "$PY_RC" "python: diagnostics:null exits 0 (no hard failure)"
        assert_output_empty "$PY_OUT" "python: diagnostics:null emits nothing"
    fi
}

test_nondict_diagnostic_fails_loud() {
    # A non-dict element in the diagnostics array is malformed — both impls fail
    # loud (exit 2) with NO partial row emitted (the valid dict before it must
    # not leak). (Pre-PR review: python previously crashed with a traceback after
    # streaming the first row.)
    run_bash "$STUB_NONDICT" "$FILE_LIST"
    assert_exit 2 "$RUN_RC" "bash: non-object diagnostic exits 2"
    assert_output_empty "$RUN_OUT" "bash: non-object diagnostic emits no partial row"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_NONDICT" "$FILE_LIST"
        assert_exit 2 "$PY_RC" "python: non-object diagnostic exits 2 (no traceback)"
        assert_output_empty "$PY_OUT" "python: non-object diagnostic emits no partial row"
    fi
}

test_agnix_present_jq_absent_fails_loud() {
    # Build a minimal PATH containing the stub agnix + the coreutils the script
    # needs, but NO jq. The bash fallback must fail loud (exit 2), never silently
    # emit nothing (that would be a coverage hole masquerading as a clean scan).
    _bindir="$WORKDIR/nojq-bin"
    command mkdir -p "$_bindir"
    for _t in bash sed grep printf cat tr awk head mktemp rm chmod dirname mkdir; do
        _p="$(command -v "$_t" 2>/dev/null || true)"
        [ -n "$_p" ] && command ln -sf "$_p" "$_bindir/$_t"
    done
    command ln -sf "$STUB" "$_bindir/agnix"
    # PATTERNS_FORCE_BASH=1 keeps it on the bash body; python3 is absent from the
    # trimmed PATH so the shim cannot exec the primary anyway. `env -u BASH_ENV`
    # is REQUIRED: on this devcontainer a non-interactive bash sources
    # /etc/bash_env, which resets $PATH to the full system PATH and leaks jq (and
    # the real agnix) back in — defeating the trimmed PATH. Stripping BASH_ENV
    # keeps the jq-less PATH authoritative for the child.
    _jq_err="$WORKDIR/nojq.err"
    AGNIX_BIN="agnix" PATTERNS_FORCE_BASH=1 /usr/bin/env -u BASH_ENV PATH="$_bindir" \
        "$REAL_BASH" "$SH" "$FILE_LIST" >/dev/null 2>"$_jq_err" && _jq_rc=0 || _jq_rc=$?
    assert_exit 2 "$_jq_rc" "bash: agnix present but jq absent exits 2 (fail loud)"
    assert_contains "$(command cat "$_jq_err")" "jq is required" "bash: jq-absent message is actionable"
}

# --- 4. empty file-list edge -------------------------------------------------

test_empty_filelist_noop() {
    # An empty manifest is no-work: exit 0, no output, agnix not invoked (a stub
    # that would fail loud on invocation proves it is never called).
    run_bash "$STUB_EMPTY" "$EMPTY_LIST"
    assert_exit 0 "$RUN_RC" "bash: empty file list exits 0 (agnix not invoked)"
    assert_output_empty "$RUN_OUT" "bash: empty file list emits nothing"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_EMPTY" "$EMPTY_LIST"
        assert_exit 0 "$PY_RC" "python: empty file list exits 0"
        assert_output_empty "$PY_OUT" "python: empty file list emits nothing"
    fi
}

test_space_path_is_one_arg() {
    # A manifest path with a space must reach agnix as a SINGLE argv element in
    # both impls (Python passes a list; the bash fallback uses an indexed array,
    # NOT a whitespace-joined string). The recording stub writes the path count.
    : >"$ARGC_FILE"
    run_bash "$STUB_ARGC" "$SPACE_LIST"
    assert_exit 0 "$RUN_RC" "bash: space-path manifest exits 0"
    assert_equals "1" "$(command cat "$ARGC_FILE")" "bash: space path passed as one argv element"
    if [ "$HAVE_PY" = "1" ]; then
        : >"$ARGC_FILE"
        run_py "$STUB_ARGC" "$SPACE_LIST"
        assert_equals "1" "$(command cat "$ARGC_FILE")" "python: space path passed as one argv element"
    fi
}

test_whitespace_only_line_dropped() {
    # A blank line and a whitespace-only line in the manifest must BOTH be
    # dropped in both impls, so exactly one real path reaches agnix.
    : >"$ARGC_FILE"
    run_bash "$STUB_ARGC" "$WS_LIST"
    assert_exit 0 "$RUN_RC" "bash: whitespace-line manifest exits 0"
    assert_equals "1" "$(command cat "$ARGC_FILE")" "bash: blank + whitespace-only lines dropped (one path)"
    if [ "$HAVE_PY" = "1" ]; then
        : >"$ARGC_FILE"
        run_py "$STUB_ARGC" "$WS_LIST"
        assert_equals "1" "$(command cat "$ARGC_FILE")" "python: blank + whitespace-only lines dropped (one path)"
    fi
}

test_agnix_config_placement() {
    # AGNIX_CONFIG (ADR §5 trust knob) must be forwarded as `--config <value>`
    # BEFORE the `--` marker (so it is parsed as a flag, not a path), with the
    # value one argv element (even with a space) and the path count unaffected.
    # The recording stub captures the value; seeing it pre-`--` proves ordering.
    _cfg="a config/with space.toml"
    : >"$ARGC_FILE"
    : >"$CONFIG_FILE"
    RUN_ERR="$WORKDIR/stderr.$$"
    RUN_OUT="$(AGNIX_BIN="$STUB_ARGC" AGNIX_CONFIG="$_cfg" PATTERNS_FORCE_BASH=1 \
        "$REAL_BASH" "$SH" "$SPACE_LIST" 2>"$RUN_ERR")" && RUN_RC=0 || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "bash: AGNIX_CONFIG run exits 0"
    assert_equals "$_cfg" "$(command cat "$CONFIG_FILE")" "bash: --config value forwarded intact (pre-'--', one arg)"
    assert_equals "1" "$(command cat "$ARGC_FILE")" "bash: --config does not perturb the path count"
    if [ "$HAVE_PY" = "1" ]; then
        : >"$ARGC_FILE"
        : >"$CONFIG_FILE"
        AGNIX_BIN="$STUB_ARGC" AGNIX_CONFIG="$_cfg" python3 "$PY" "$SPACE_LIST" >/dev/null 2>&1 || true
        assert_equals "$_cfg" "$(command cat "$CONFIG_FILE")" "python: --config value forwarded intact (pre-'--', one arg)"
        assert_equals "1" "$(command cat "$ARGC_FILE")" "python: --config does not perturb the path count"
    fi
}

test_null_fields_parity() {
    # JSON `null` fields: file=null must be DROPPED (not emitted at "None"), and
    # line/message/rule_severity=null must coalesce to "" — byte-identical to the
    # bash fallback's jq `// ""`. A bare str(None) would leak the literal "None".
    run_bash "$STUB_NULL" "$FILE_LIST"
    assert_exit 0 "$RUN_RC" "bash: null-field fixture exits 0"
    assert_not_contains "$RUN_OUT" "None" "bash: no literal 'None' leaks from a JSON null"
    assert_not_contains "$RUN_OUT" "dropped: null file" "bash: the null-file advisory row is dropped"
    if [ "$HAVE_PY" = "1" ]; then
        run_py "$STUB_NULL" "$FILE_LIST"
        assert_not_contains "$PY_OUT" "None" "python: no literal 'None' leaks from a JSON null"
        assert_not_contains "$PY_OUT" "dropped: null file" "python: the null-file advisory row is dropped"
        assert_equals "$RUN_OUT" "$PY_OUT" "parity: bash == python on JSON null fields"
    fi
}

run_test test_byte_correct_tsv "byte-correct TSV rows (acceptance 1) + parity"
run_test test_space_path_is_one_arg "space-containing manifest path is one argv element"
run_test test_whitespace_only_line_dropped "blank + whitespace-only manifest lines dropped + parity"
run_test test_agnix_config_placement "AGNIX_CONFIG forwarded as --config before -- + parity"
run_test test_null_fields_parity "JSON null fields dropped/coalesced + parity"
run_test test_unmapped_and_project_rows_dropped "unmapped + project rows dropped"
run_test test_evidence_truncated_to_80 "evidence truncated to 80 codepoints + parity"
run_test test_absent_binary_noop "absent-binary no-op (acceptance 2) + parity"
run_test test_missing_arg_usage "missing arg -> exit 1 + Usage + parity"
run_test test_missing_filelist "absent file list -> exit 1"
run_test test_malformed_json_fails_loud "malformed agnix output -> exit 2 + parity"
run_test test_empty_output_fails_loud "empty agnix output -> exit 2 + parity"
run_test test_top_level_array_fails_loud "top-level JSON array -> exit 2 (no silent no-op) + parity"
run_test test_diagnostics_null_is_empty "diagnostics:null -> exit 0, empty (coalesced) + parity"
run_test test_nondict_diagnostic_fails_loud "non-object diagnostic -> exit 2, no partial row + parity"
run_test test_agnix_present_jq_absent_fails_loud "agnix present, jq absent -> exit 2 (fail loud)"
run_test test_empty_filelist_noop "empty file-list -> exit 0, no output + parity"

generate_report
