#!/usr/bin/env bash
# Python coverage for the patterns.py pre-scan ports (#186).
#
# Emits a Cobertura coverage.xml for the plugins/**/patterns.py pre-scan ports
# (plus the non-port Python tools behind the same runtime policy — currently
# check-ai-config/agnix-normalize.py, #397) so CI can upload it to Codecov.
# Coverage is scoped to Python (and, separately, the
# .mjs validators via tests/coverage-mjs.sh) on purpose: the bash patterns.sh
# fallback is grep-pipeline code whose matching lives in `grep` subprocess regex
# alternations a line tracer cannot see, so a bash line-coverage number is
# instrument noise, not signal (see CLAUDE.md runtime policy; the bash path is
# guarded by tests/validate-python-ports.sh byte-parity instead).
#
# Each port is driven under `coverage run --parallel-mode` against a small
# synthetic corpus that exercises the detector categories (secrets, SQL, XSS,
# crypto, debug markers, empty bodies, ...), mirroring the fixture shape of
# tests/validate-python-ports.sh. drift-detect is the two-arg outlier (it diffs
# two path lists), handled below. The per-process .coverage.* data files are
# then combined into a single coverage.xml at the repo root.
#
# Skips gracefully (exit 0, no report) when python3>=3.11 or coverage.py is
# absent — the same skip-if-absent posture as the sibling gates. CI installs
# coverage so it actually runs there. This script is NOT wired into
# tests/run-all.sh: it is an additive reporting step, run by CI and `just
# coverage`, and must not perturb the no-python3 macOS test path.
#
# THIS FILE IS A THIN ENTRY POINT (issue #564). The synthetic corpora live in
# per-domain fragments under tests/python-corpus/; this file keeps the runtime
# gate, the WORKDIR lifecycle, the `coverage run` driver loop and the Cobertura
# emit. Adding a fixture means editing the ONE fragment for that detector family.
#
# Pure bash-3.2 + coreutils + python3; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

# --- Runtime gate: python3>=3.11 + coverage.py, else skip cleanly ------------
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    printf '[skip] python-coverage — python3>=3.11 not available\n'
    exit 0
fi
# Probe a real ATTRIBUTE, not mere importability. A bare `import coverage` is not
# evidence coverage.py is installed: this script runs from the repo root, where
# `./coverage/` is the OUTPUT directory tests/coverage-mjs.sh writes lcov.info
# into. Python treats any directory on sys.path as an implicit NAMESPACE PACKAGE
# (PEP 420), so `import coverage` binds that empty build-output dir and succeeds
# with coverage.py entirely absent. The gate was then bypassed and the script ran
# on to `coverage xml`, which hard-failed the run with a misleading
# "coverage xml failed" instead of skipping cleanly (found while baselining #564).
# A namespace package has no attributes, so touching `coverage.Coverage` is what
# actually distinguishes the real library from the directory.
if ! python3 -c 'import coverage; coverage.Coverage' 2>/dev/null; then
    printf '[skip] python-coverage — coverage.py not installed (pip install coverage)\n'
    exit 0
fi

OUT_XML="$REPO_ROOT/coverage.xml"

# --- Synthetic corpus lifecycle ---------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Corpus fragments -------------------------------------------------------
# Each fragment BUILDS fixtures under $WORKDIR and sets the path-list variables
# the driver section below feeds to the ports. They are sourced in a fixed order
# and must come after WORKDIR/FIXDIR exist. No wiring guard here: unlike the
# tests/ suites this script has no run_test counters, so an unwired fragment
# surfaces immediately as an unbound path-list variable under `set -u` rather
# than as a silently smaller pass count.
for _frag in 10-ai-config 20-source 30-lifecycle 40-loop-drift 50-docs 60-decomposition; do
    _frag_path="$SCRIPT_DIR/python-corpus/${_frag}.sh"
    if [ ! -f "$_frag_path" ]; then
        printf '[FAIL] python-coverage — corpus fragment missing: %s\n' "$_frag_path" >&2
        exit 1
    fi
    # shellcheck source=/dev/null  # path is composed at runtime from the list above
    . "$_frag_path"
done
unset _frag _frag_path

# --- Run every port under coverage (parallel-mode accumulates per process) ---
# COVERAGE_FILE lives in WORKDIR so combine sees only this run's data files and
# nothing pollutes the repo tree until the final xml is written.
export COVERAGE_FILE="$WORKDIR/.coverage"

run_count=0
while IFS= read -r py; do
    [ -n "$py" ] || continue
    case "$py" in
        */drift-detect/patterns.py)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" >/dev/null 2>&1 || true
            # Extended pair (#384): side-effect LOW + test-for-planned LOW + the
            # blank/whitespace trim-skip arms.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL2" "$DRIFT_PLANNED2" >/dev/null 2>&1 || true
            # Negative-path arms: no argument (usage), one argument (missing
            # planned, second usage arm), and both list-not-found arms.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_NOFILE" "$DRIFT_PLANNED" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" "$DRIFT_NOFILE" >/dev/null 2>&1 || true
            ;;
        */loop-make-it-work/patterns.py | */loop-make-it-secure/patterns.py | \
            */loop-make-it-tested/patterns.py | */loop-make-it-documented/patterns.py)
            # Drive each single-arg loop port over its dedicated fixture list
            # (#384). The per-port list carries a leading blank (empty-token skip),
            # a trailing ghost path (isfile==False skip), and the language/boundary
            # fixtures the gate asserts. The unreadable-file, file-list-not-found,
            # and usage arms follow.
            case "$py" in
                */loop-make-it-work/*) _loop_list="$LOOP_WORK_LIST" ;;
                */loop-make-it-secure/*) _loop_list="$LOOP_SEC_LIST" ;;
                */loop-make-it-tested/*) _loop_list="$LOOP_TEST_LIST" ;;
                *) _loop_list="$LOOP_DOC_LIST" ;;
            esac
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$_loop_list" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_UNREAD_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_NOFILE_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            ;;
        */loop-make-it-right/patterns.py)
            # loop-make-it-right needs its thresholds forced low so the long-
            # function and deep-nesting arms fire on the compact fixtures (#384).
            LOOP_MAX_FUNCTION_LINES=1 LOOP_MAX_NESTING_DEPTH=0 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_RIGHT_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_UNREAD_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_NOFILE_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            ;;
        */check-security/patterns.py | */check-code-health/patterns.py)
            # Drive the per-language / per-framework / boundary arms over the
            # source-shaped corpus (#348); the generic FILE_LIST keeps the
            # no-match early paths covered. The negative-path arms (usage error,
            # file-list-not-found) run below.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$SRC_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$SRC_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-decomposition/patterns.py)
            # Drive the six segmenters, the bloat arms migrated here from
            # check-ai-config, the god-module arm and all three decline reasons
            # over the decomposition corpus (#663). Thresholds are tuned down so
            # the compact fixtures reach the seam/size/bloat branches; the
            # generic FILE_LIST keeps the no-match early paths covered. The
            # negative-path arms (usage error, file-list-not-found) run below.
            DECOMP_LOC_WARN=5 DECOMP_SEAM_MIN_LINES=8 \
                CLAUDE_MD_WARN=2 CLAUDE_MD_HIGH=3 SKILL_WARN=2 SKILL_HIGH=3 \
                AGENT_WARN=2 AGENT_HIGH=3 DOC_WARN=2 DOC_HIGH=3 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_LIST" >/dev/null 2>&1 || true
            # Second pass on the WARNING-only side of each bloat branch
            # (WARN < lines < HIGH), which the pass above skips over.
            DECOMP_LOC_WARN=900 \
                CLAUDE_MD_WARN=3 CLAUDE_MD_HIGH=99 SKILL_WARN=3 SKILL_HIGH=99 \
                AGENT_WARN=3 AGENT_HIGH=99 DOC_WARN=3 DOC_HIGH=99 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-lifecycle/patterns.py)
            # Drive the per-language arms (swift/py/js/go spawn/terminate/handle/
            # listener) over the lifecycle-shaped corpus (#435); the generic
            # FILE_LIST keeps the no-match early paths covered. The negative-path
            # arms (usage error, file-list-not-found) run below.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LIFE_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LIFE_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-ai-config/patterns.py)
            # Drive this port over the config-shaped corpus (agent/skill/MCP/hook/
            # workflow.js) instead of the generic one, with bloat thresholds tuned
            # down so the tiny CLAUDE.md trips the HIGH arm and the SKILL.md trips
            # the WARNING-only arm (SKILL_WARN<lines<SKILL_HIGH), driving both
            # bloat branches under measurement (#348). Also run the generic list
            # so the no-match early-return globs stay covered.
            CLAUDE_MD_WARN=1 CLAUDE_MD_HIGH=2 DOC_WARN=1 DOC_HIGH=3 \
                SKILL_WARN=3 SKILL_HIGH=99 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$AICFG_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Negative-path arms (#348): usage error (no arg) and file-list-not-
            # found (OSError). The empty-path + unreadable-file skip arms are
            # driven by the shared negative-path loop below.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$WORKDIR/ai-nonexistent-list-XYZ.txt" >/dev/null 2>&1 || true
            # Relative `plugins/`-prefixed path -> _plugins_dir_for's relative arm
            # (run cd'd into $FIXDIR so the path stays relative). (#348)
            (cd "$FIXDIR" && python3 -m coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$AICFG_REL_LIST" >/dev/null 2>&1) || true
            ;;
        */check-docs-staleness/patterns.py)
            # STALENESS_MONTHS=-1 makes the current-month date in staleness.md
            # cross the threshold deterministically (year*12+month boundary).
            CHECK_STALENESS_MONTHS=-1 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-deadlinks/patterns.py | */check-docs-missing-api/patterns.py)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-examples/patterns.py)
            # Git-rooted: cd into the sandbox so `git rev-parse` resolves there.
            (cd "$DOCS_SB" && python3 -m coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-organization/patterns.py)
            # Git-rooted + min-files/depth boundaries driven via env.
            (cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 CHECK_ORG_README_DEPTH=2 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        *)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
    esac
    run_count=$((run_count + 1))
done <<EOF
$(find "$PLUGINS_DIR" -type f -name 'patterns.py' 2>/dev/null | sort)
EOF

if [ "$run_count" -eq 0 ]; then
    printf '[FAIL] python-coverage — no patterns.py found under %s\n' "$PLUGINS_DIR" >&2
    exit 1
fi

# --- Negative-path drivers for the check-docs-* ports (#243) -----------------
# Drive the usage-error, file-not-found, and per-path-skip arms of each docs
# port. These branches (issue priority 2) return non-zero / emit nothing, so the
# positive corpus above never reaches them; the behavioral contract is pinned by
# validate-python-ports.sh, this only makes the lines execute under measurement.
for docs_port in check-docs-staleness check-docs-deadlinks check-docs-examples \
    check-docs-missing-api check-docs-organization; do
    dp="$PLUGINS_DIR/review-audit/skills/$docs_port/patterns.py"
    [ -f "$dp" ] || continue
    # No argument -> usage-error arm (exit 1).
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" >/dev/null 2>&1 || true
    # A list PATH that does not exist -> file-not-found (OSError) arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_NOFILE_LIST" >/dev/null 2>&1 || true
    # A list of non-existent files -> per-path isfile()==False skip arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_GHOST_LIST" >/dev/null 2>&1 || true
    # An empty (0-line) list -> empty-list early-return arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_EMPTY_LIST" >/dev/null 2>&1 || true
    # An unreadable file that passes isfile() -> per-file OSError read arm.
    # missing-api reads .py (opens in scan_file); the others read .md content.
    case "$docs_port" in
        check-docs-missing-api)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_PY_LIST" >/dev/null 2>&1 || true
            ;;
        check-docs-examples | check-docs-organization) ;; # OSError arm handled below
        *)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_LIST" >/dev/null 2>&1 || true
            ;;
    esac
done

# The two git-rooted ports' _project_root() has an OSError fallback (git binary
# absent). Drive it with PATH emptied so `git` is not found -> subprocess raises
# FileNotFoundError (OSError) -> return ".". python3 is launched by ABSOLUTE path
# (an empty PATH cannot resolve `python3` itself); the emptied PATH only reaches
# the port's internal `git` subprocess lookup.
PYBIN="$(command -v python3)"
for docs_port in check-docs-examples check-docs-organization; do
    dp="$PLUGINS_DIR/review-audit/skills/$docs_port/patterns.py"
    [ -f "$dp" ] || continue
    (cd "$DOCS_SB" && PATH="" "$PYBIN" -m coverage run --parallel-mode \
        --source="$PLUGINS_DIR" "$dp" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
done

# check-docs-examples reads .md content in scan_file — an unreadable .md that
# passes isfile() drives its per-file OSError arm (run inside the sandbox).
(cd "$DOCS_SB" &&
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLUGINS_DIR/review-audit/skills/check-docs-examples/patterns.py" \
        "$DOCS_UNREAD_LIST" >/dev/null 2>&1) || true

# organization: root-level path skip, ghost-subdir skip, and listdir-OSError arm.
(cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 \
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
    "$PLUGINS_DIR/review-audit/skills/check-docs-organization/patterns.py" \
    "$DOCS_ORG_EDGE_LIST" >/dev/null 2>&1) || true

# --- agnix-normalize.py driver (#397) ----------------------------------------
# agnix-normalize.py is NOT a patterns.py port (it bridges agnix JSON -> the TSV
# contract), so the patterns.py glob above never reaches it. Drive it here with a
# stub AGNIX_BIN so its mapping / no-op / fail-loud arms execute under
# measurement, in lockstep with the behavioral gate tests/validate-agnix-normalize.sh
# (the #204 two-surface convention). The stub emits a fixture covering every
# mapped prefix plus a dropped VER-*/empty-file row and an unmapped AS-* row.
AGNIX_NORM_PY="$PLUGINS_DIR/review-audit/skills/check-ai-config/agnix-normalize.py"
if [ -f "$AGNIX_NORM_PY" ]; then
    AGX_STUB="$WORKDIR/agnix-stub.sh"
    cat >"$AGX_STUB" <<'AGXEOF'
#!/usr/bin/env bash
cat <<'JSON'
{"version":"0.40.0","files_checked":1,"diagnostics":[
 {"rule":"CC-AG-001","file":"agents/a.md","line":1,"message":"missing name","rule_severity":"HIGH"},
 {"rule":"CC-SK-001","file":"skills/s/SKILL.md","line":3,"message":"invalid model","rule_severity":"HIGH"},
 {"rule":"CC-HK-009","file":"hooks/h.sh","line":7,"message":"dangerous command","rule_severity":"HIGH"},
 {"rule":"MCP-008","file":"mcp.json","line":2,"message":"proto mismatch","rule_severity":"MEDIUM"},
 {"rule":"CC-MCP-001","file":"cc-mcp.json","line":4,"message":"cc mcp","rule_severity":"HIGH"},
 {"rule":"CC-PL-001","file":".claude-plugin/x.json","line":1,"message":"bad manifest","rule_severity":"HIGH"},
 {"rule":"CC-MEM-001","file":"CLAUDE.md","line":5,"message":"bad import","rule_severity":"HIGH"},
 {"rule":"CC-AG-002","file":"","line":1,"message":"mapped rule with empty file","rule_severity":"HIGH"},
 {"rule":"VER-001","file":"","line":1,"message":"unpinned","rule_severity":"LOW"},
 {"rule":"AS-042","file":"agents/a.md","line":9,"message":"generic","rule_severity":"MEDIUM"}
],"summary":{}}
JSON
AGXEOF
    chmod +x "$AGX_STUB"
    AGX_BAD="$WORKDIR/agnix-bad.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "not json {{{"' >"$AGX_BAD"
    chmod +x "$AGX_BAD"
    # Empty-output stub -> RuntimeError "no JSON output" -> die(2).
    AGX_EMPTYOUT="$WORKDIR/agnix-emptyout.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'printf ""' >"$AGX_EMPTYOUT"
    chmod +x "$AGX_EMPTYOUT"
    # Stub whose JSON has a non-list `diagnostics` -> the no-diagnostics-array arm.
    AGX_NOARRAY="$WORKDIR/agnix-noarray.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "{\"diagnostics\": \"notalist\"}"' >"$AGX_NOARRAY"
    chmod +x "$AGX_NOARRAY"
    # Stub whose `diagnostics` is JSON null -> the null-coalesce-to-[] arm.
    AGX_DIAGNULL="$WORKDIR/agnix-diagnull.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "{\"diagnostics\": null}"' >"$AGX_DIAGNULL"
    chmod +x "$AGX_DIAGNULL"
    # Top-level JSON array (not an object) -> the non-object fail-loud arm.
    AGX_TOPARR="$WORKDIR/agnix-toparr.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "[1,2,3]"' >"$AGX_TOPARR"
    chmod +x "$AGX_TOPARR"
    # diagnostics array holding a non-dict element -> the non-object-diagnostic arm.
    AGX_NONDICT="$WORKDIR/agnix-nondict.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "{\"diagnostics\":[{\"rule\":\"CC-AG-001\",\"file\":\"a.md\",\"line\":1,\"message\":\"m\",\"rule_severity\":\"HIGH\"},42]}"' >"$AGX_NONDICT"
    chmod +x "$AGX_NONDICT"
    # JSON null fields -> the _field() null-coalescing arm (file=null dropped;
    # line/message/rule_severity=null -> "").
    AGX_NULL="$WORKDIR/agnix-null.sh"
    printf '%s\n%s\n' '#!/usr/bin/env bash' 'echo "{\"diagnostics\":[{\"rule\":\"CC-AG-001\",\"file\":null,\"line\":1,\"message\":\"m\",\"rule_severity\":\"HIGH\"},{\"rule\":\"CC-SK-001\",\"file\":\"s.md\",\"line\":null,\"message\":null,\"rule_severity\":null}]}"' >"$AGX_NULL"
    chmod +x "$AGX_NULL"
    # A present-but-non-executable AGNIX_BIN passes the isfile() no-op guard, then
    # subprocess raises PermissionError (OSError) -> the run_agnix OSError arm.
    AGX_NOEXEC="$WORKDIR/agnix-noexec"
    printf 'not runnable\n' >"$AGX_NOEXEC"
    chmod 644 "$AGX_NOEXEC"
    AGX_LIST="$WORKDIR/agnix-list.txt"
    printf '%s\n' "agents/a.md" >"$AGX_LIST"
    AGX_EMPTY="$WORKDIR/agnix-empty.txt"
    : >"$AGX_EMPTY"
    # Full mapping (with AGNIX_CONFIG set to exercise the --config arm).
    AGNIX_BIN="$AGX_STUB" AGNIX_CONFIG="/dev/null" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Absent-binary no-op arm.
    AGNIX_BIN="/nonexistent/agnix" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Malformed-JSON fail-loud arm.
    AGNIX_BIN="$AGX_BAD" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Empty-output fail-loud arm (RuntimeError "no JSON output").
    AGNIX_BIN="$AGX_EMPTYOUT" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Non-list diagnostics fail-loud arm.
    AGNIX_BIN="$AGX_NOARRAY" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # diagnostics:null -> null-coalesce-to-[] arm (clean empty result).
    AGNIX_BIN="$AGX_DIAGNULL" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Top-level non-object fail-loud arm.
    AGNIX_BIN="$AGX_TOPARR" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Non-object diagnostic element fail-loud arm.
    AGNIX_BIN="$AGX_NONDICT" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # JSON null-field coalescing arm (_field null branch + null-file drop).
    AGNIX_BIN="$AGX_NULL" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Present-but-non-executable binary -> subprocess OSError arm.
    AGNIX_BIN="$AGX_NOEXEC" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Empty file-list arm (exit 0, no agnix invocation).
    AGNIX_BIN="$AGX_STUB" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_EMPTY" >/dev/null 2>&1 || true
    # Usage-error arm (no argument) + file-list-not-found arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" >/dev/null 2>&1 || true
    AGNIX_BIN="$AGX_STUB" \
        python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$WORKDIR/agnix-nonexistent-XYZ.txt" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# Restore perms so the trap `rm -rf` can clean WORKDIR without warnings.
chmod 644 "$DOCS_UNREADABLE" "$DOCS_UNREADABLE_PY" 2>/dev/null || true
chmod 755 "$DOCS_SB/locked" 2>/dev/null || true
chmod 644 "$SRC_UNREAD" 2>/dev/null || true
chmod 644 "$AI_UNREAD" 2>/dev/null || true
chmod 644 "$LOOP_UNREAD" "$TSTDIR/gomod_test.go" "$TSTDIR/test_pymod.py" 2>/dev/null || true

# --- Combine + emit Cobertura XML at the repo root ---------------------------
python3 -m coverage combine >/dev/null 2>&1 || true
python3 -m coverage xml -o "$OUT_XML" >/dev/null 2>&1 || {
    printf '[FAIL] python-coverage — coverage xml failed\n' >&2
    exit 1
}

if [ ! -s "$OUT_XML" ]; then
    printf '[FAIL] python-coverage — coverage.xml is empty\n' >&2
    exit 1
fi

pct="$(python3 -m coverage report 2>/dev/null | awk '/^TOTAL/ {print $NF}')"
printf '[ok] python-coverage — %s ports run, coverage.xml written (TOTAL %s)\n' \
    "$run_count" "${pct:-n/a}"
