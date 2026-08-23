#!/usr/bin/env bash
# Python coverage for the Python tools we ship (#186, #748).
#
# Emits a Cobertura coverage.xml for EVERY Python file under plugins/ — the
# patterns.py pre-scan ports plus the non-port tools behind the same runtime
# policy (check-ai-config/agnix-normalize.py, #397; ship-issue/sizing.py,
# ship-issue/plan-lens.py, ship-issue/split-verify.py, scripts/autonomy-resolve.py
# and scripts/golem-event-listener.py, #748) — so CI can upload it to Codecov.
#
# The corpus is keyed on "every Python file we ship", NOT on the patterns.py
# filename convention. That distinction IS #748: the driver loop below is still
# glob-driven for the ports, but the non-port tools are named in
# NON_PATTERNS_TOOLS and tests/validate-coverage-corpus.sh fails when the set of
# Python files on disk is not exactly {patterns.py ports} + {that list}. Before
# it, a shipped scanner that simply was not named patterns.py fell out of the
# corpus SILENTLY — no fixture, no driver, no measurement, no complaint.
#
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
# RUNNER RESOLUTION (#748): `coverage` on PATH -> `python3 -m coverage` -> skip.
# The PATH branch is FIRST and is load-bearing, not a convenience. CI installs
# coverage with `pipx`, which puts the tool in an ISOLATED venv and exposes only
# the `coverage` console script — `python3 -m coverage` does not resolve it, and
# neither does `import coverage`. This script probed and drove coverage.py by
# module only, so on every CI run it took the skip branch below, exited 0, and
# Codecov received nothing (`not_found_files: ["coverage.xml"]`). A green step, a
# green job, and Python coverage that had never once run. Same shape as
# lint-python.sh's ruff -> uvx resolution (#538/#544), for the same reason.
#
# Skips gracefully (exit 0, no report) when python3>=3.11 or coverage.py is
# absent — the same skip-if-absent posture as the sibling gates. But set
# COVERAGE_PYTHON_REQUIRED=1 (ci.yml does) and that skip becomes a HARD FAILURE:
# an environment that deliberately installed coverage and then skips is broken,
# not unequipped. That flag is the guard against a repeat, because the silent
# skip is precisely how a total absence of measurement read as a pass. Sibling
# reasoning: #538/#571, where a gate whose tool is absent must never look like a
# gate that ran.
#
# This script is NOT wired into tests/run-all.sh: it is an additive reporting
# step, run by CI and `just coverage`, and must not perturb the no-python3 macOS
# test path. The corpus-consistency gate that keeps this file honest,
# tests/validate-coverage-corpus.sh, IS wired in — it is a static check needing
# no coverage.py at all.
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

# --- Runtime gate: python3>=3.11 + a coverage.py RUNNER, else skip cleanly ---
#
# die_or_skip <reason> — skip (exit 0) normally; FAIL LOUD when the caller
# declared coverage must be available (COVERAGE_PYTHON_REQUIRED=1). CI sets it,
# so the never-ran-for-months state that motivated #748 cannot recur silently:
# the step that installs coverage now fails when coverage does not resolve.
die_or_skip() {
    if [ "${COVERAGE_PYTHON_REQUIRED:-}" = "1" ]; then
        printf '[FAIL] python-coverage — %s (COVERAGE_PYTHON_REQUIRED=1)\n' "$1" >&2
        exit 1
    fi
    printf '[skip] python-coverage — %s\n' "$1"
    exit 0
}

if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    die_or_skip "python3>=3.11 not available"
fi

# Resolve a coverage RUNNER: `coverage` on PATH, else `python3 -m coverage`.
#
# Both branches probe a real ATTRIBUTE / real subcommand, not mere importability.
# A bare `import coverage` is not evidence coverage.py is installed: this script
# runs from the repo root, where `./coverage/` is the OUTPUT directory
# tests/coverage-mjs.sh writes lcov.info into. Python treats any directory on
# sys.path as an implicit NAMESPACE PACKAGE (PEP 420), so `import coverage` binds
# that empty build-output dir and succeeds with coverage.py entirely absent. The
# gate was then bypassed and the script ran on to `coverage xml`, which
# hard-failed the run with a misleading "coverage xml failed" instead of skipping
# cleanly (found while baselining #564). A namespace package has no attributes,
# so touching `coverage.Coverage` is what actually distinguishes the real library
# from the directory. The PATH branch has the same hazard in reverse — a
# `coverage` NAME on PATH is not proof it works — so it is probed by running it.
COV_RUNNER=""
if command -v coverage >/dev/null 2>&1 && coverage --version >/dev/null 2>&1; then
    COV_RUNNER="path"
elif python3 -c 'import coverage; coverage.Coverage' 2>/dev/null; then
    COV_RUNNER="module"
fi

if [ -z "$COV_RUNNER" ]; then
    die_or_skip "coverage.py not installed (pip install coverage, or pipx install coverage)"
fi

# run_coverage <args...> — invoke coverage.py through the resolved runner.
# A function, not an unquoted "$COV_CMD" expansion: word-splitting a command
# string is the bug this shape exists to avoid (same idiom as lint-python.sh's
# run_ruff). EVERY coverage invocation in this file goes through it, including
# `combine` and `xml` — a stray `python3 -m coverage` would silently write to a
# different data file than the one the drivers populated.
run_coverage() {
    if [ "$COV_RUNNER" = "path" ]; then
        coverage "$@"
    else
        python3 -m coverage "$@"
    fi
}

# exec_coverage <args...> — same resolution, but REPLACES the current shell.
# Used only for the backgrounded golem-event-listener driver, where the pid that
# `$!` yields must be the coverage process itself and not a wrapper subshell (see
# that block for why an orphaned server loses the measurement it collected).
exec_coverage() {
    if [ "$COV_RUNNER" = "path" ]; then
        exec coverage "$@"
    else
        exec python3 -m coverage "$@"
    fi
}

# Announce the resolved runner. Without this the two branches are
# indistinguishable in the log, and "which coverage actually ran" is the first
# question when the report disagrees with what a local run produced.
printf 'Runner: %s\n' "$(if [ "$COV_RUNNER" = "path" ]; then
    printf 'coverage on PATH'
else
    printf 'python3 -m coverage'
fi)"

OUT_XML="$REPO_ROOT/coverage.xml"

# --- The non-patterns.py tools this script drives (#748) ---------------------
#
# THE DECLARED LIST. Repo-relative paths, one per line, of every shipped Python
# file that is NOT named patterns.py and therefore is not reached by the
# glob-driven loop below. Each has an explicit driver further down, following the
# agnix-normalize.py precedent (#397).
#
# This list is a CONTRACT, not a comment: tests/validate-coverage-corpus.sh
# parses it out of this file and fails when
#
#     { every plugins/**/*.py }  !=  { patterns.py ports }  ∪  { this list }
#
# in EITHER direction — a shipped Python file nobody drives, or a declared entry
# that no longer exists. That gate is the point of #748. The defect it closes is
# not "four files were missed"; it is that the corpus was keyed on a FILENAME
# CONVENTION, so a new scanner not named patterns.py fell out of measurement
# with nothing to notice. Keying the check on every Python file we ship is what
# makes falling out of the convention loud instead of silent.
#
# Adding a Python tool? Add it here AND give it a driver below. The gate will
# tell you if you do only one.
#
# shellcheck disable=SC2034  # read by tests/validate-coverage-corpus.sh, which
# parses this declaration out of this file rather than keeping a second copy.
NON_PATTERNS_TOOLS="\
plugins/review-audit/skills/check-ai-config/agnix-normalize.py
plugins/workflow/scripts/autonomy-resolve.py
plugins/workflow/scripts/golem-event-listener.py
plugins/workflow/skills/ship-issue/plan-lens.py
plugins/workflow/skills/ship-issue/sizing.py
plugins/workflow/skills/ship-issue/split-verify.py"

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
for _frag in 10-ai-config 20-source 30-lifecycle 40-loop-drift 50-docs 60-decomposition 70-okf 80-workflow-tools; do
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
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" >/dev/null 2>&1 || true
            # Extended pair (#384): side-effect LOW + test-for-planned LOW + the
            # blank/whitespace trim-skip arms.
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL2" "$DRIFT_PLANNED2" >/dev/null 2>&1 || true
            # Negative-path arms: no argument (usage), one argument (missing
            # planned, second usage arm), and both list-not-found arms.
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_NOFILE" "$DRIFT_PLANNED" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
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
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$_loop_list" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_UNREAD_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_NOFILE_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            ;;
        */loop-make-it-right/patterns.py)
            # loop-make-it-right needs its thresholds forced low so the long-
            # function and deep-nesting arms fire on the compact fixtures (#384).
            LOOP_MAX_FUNCTION_LINES=1 LOOP_MAX_NESTING_DEPTH=0 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_RIGHT_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_UNREAD_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LOOP_NOFILE_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            ;;
        */check-security/patterns.py | */check-code-health/patterns.py)
            # Drive the per-language / per-framework / boundary arms over the
            # source-shaped corpus (#348); the generic FILE_LIST keeps the
            # no-match early paths covered. The negative-path arms (usage error,
            # file-list-not-found) run below.
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$SRC_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
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
                MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3 \
                MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_LIST" >/dev/null 2>&1 || true
            # Second pass on the WARNING-only side of each bloat branch
            # (WARN < lines < HIGH), which the pass above skips over.
            DECOMP_LOC_WARN=900 \
                CLAUDE_MD_WARN=3 CLAUDE_MD_HIGH=99 SKILL_WARN=3 SKILL_HIGH=99 \
                AGENT_WARN=3 AGENT_HIGH=99 DOC_WARN=3 DOC_HIGH=99 \
                MEMORY_INDEX_WARN=3 MEMORY_INDEX_HIGH=99 \
                MEMORY_CONCEPT_WARN=3 MEMORY_CONCEPT_HIGH=99 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_LIST" >/dev/null 2>&1 || true
            # Third pass with NO bundle configured (#700) — drives the empty-root
            # early return in _bundle_root()/bundle_kind(), the "a consuming repo
            # opts out" path, which neither pass above reaches.
            MEMORY_BUNDLE_ROOT='' DECOMP_LOC_WARN=5 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DECOMP_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-okf-conformance/patterns.py)
            # Drive the OKF conformance arms over a BUNDLE-SHAPED corpus (#668).
            # The bundle root must be passed explicitly: the fixtures live under
            # $WORKDIR, so the default `.claude/memory` only matches because the
            # root is accepted when nested anywhere in the path. The generic
            # FILE_LIST keeps the outside-the-bundle early-continue covered.
            OKF_BUNDLE_ROOT="$OKF_ROOT_REL" \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_LIST" >/dev/null 2>&1 || true
            # Second pass with the pin overridden so the SAME fixtures flip from
            # drift to match, driving both sides of the version comparison.
            OKF_BUNDLE_ROOT="$OKF_ROOT_REL" OKF_PINNED_VERSION="9.9" \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_LIST" >/dev/null 2>&1 || true
            # Third pass with NO bundle configured — the empty-root early return
            # in bundle_root()/in_bundle(), the "consuming repo opts out" path.
            OKF_BUNDLE_ROOT='' \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_LIST" >/dev/null 2>&1 || true
            # MEMORY_BUNDLE_ROOT fallback arm (OKF_BUNDLE_ROOT unset).
            env -u OKF_BUNDLE_ROOT MEMORY_BUNDLE_ROOT="$OKF_ROOT_REL" \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Fail-loud arms: a malformed pin, and an UNRESOLVABLE pin (a copy of
            # the port beside a thresholds.yml carrying none) — the branch the
            # real skill directory can never reach.
            OKF_PINNED_VERSION="not-a-version" \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_LIST" >/dev/null 2>&1 || true
            env -u OKF_PINNED_VERSION \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$OKF_NOPIN_PY" "$OKF_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$OKF_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-lifecycle/patterns.py)
            # Drive the per-language arms (swift/py/js/go spawn/terminate/handle/
            # listener) over the lifecycle-shaped corpus (#435); the generic
            # FILE_LIST keeps the no-match early paths covered. The negative-path
            # arms (usage error, file-list-not-found) run below.
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$LIFE_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
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
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$AICFG_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Negative-path arms (#348): usage error (no arg) and file-list-not-
            # found (OSError). The empty-path + unreadable-file skip arms are
            # driven by the shared negative-path loop below.
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$WORKDIR/ai-nonexistent-list-XYZ.txt" >/dev/null 2>&1 || true
            # Relative `plugins/`-prefixed path -> _plugins_dir_for's relative arm
            # (run cd'd into $FIXDIR so the path stays relative). (#348)
            (cd "$FIXDIR" && run_coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$AICFG_REL_LIST" >/dev/null 2>&1) || true
            ;;
        */check-docs-staleness/patterns.py)
            # STALENESS_MONTHS=-1 makes the current-month date in staleness.md
            # cross the threshold deterministically (year*12+month boundary).
            CHECK_STALENESS_MONTHS=-1 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-deadlinks/patterns.py | */check-docs-missing-api/patterns.py)
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-examples/patterns.py)
            # Git-rooted: cd into the sandbox so `git rev-parse` resolves there.
            (cd "$DOCS_SB" && run_coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-organization/patterns.py)
            # Git-rooted + min-files/depth boundaries driven via env.
            (cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 CHECK_ORG_README_DEPTH=2 \
                run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        *)
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
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
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" >/dev/null 2>&1 || true
    # A list PATH that does not exist -> file-not-found (OSError) arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_NOFILE_LIST" >/dev/null 2>&1 || true
    # A list of non-existent files -> per-path isfile()==False skip arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_GHOST_LIST" >/dev/null 2>&1 || true
    # An empty (0-line) list -> empty-list early-return arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_EMPTY_LIST" >/dev/null 2>&1 || true
    # An unreadable file that passes isfile() -> per-file OSError read arm.
    # missing-api reads .py (opens in scan_file); the others read .md content.
    case "$docs_port" in
        check-docs-missing-api)
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_PY_LIST" >/dev/null 2>&1 || true
            ;;
        check-docs-examples | check-docs-organization) ;; # OSError arm handled below
        *)
            run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_LIST" >/dev/null 2>&1 || true
            ;;
    esac
done

# The two git-rooted ports' _project_root() has an OSError fallback (git binary
# absent). Drive it with PATH emptied so `git` is not found -> subprocess raises
# FileNotFoundError (OSError) -> return ".". The runner is launched by ABSOLUTE
# path (an empty PATH cannot resolve a command NAME at all); the emptied PATH
# only reaches the port's internal `git` subprocess lookup.
#
# This arm cannot go through run_coverage(): that helper invokes `coverage` /
# `python3` BY NAME, which an emptied PATH cannot resolve. So it resolves the
# absolute path of whichever runner won and builds the argv itself. Under the
# PATH runner that is the `coverage` console script, whose shebang names its venv
# interpreter absolutely and therefore still works with no PATH — the property
# that lets the pipx branch drive this arm at all (#748).
if [ "$COV_RUNNER" = "path" ]; then
    COVBIN="$(command -v coverage)"
    set -- "$COVBIN"
else
    PYBIN="$(command -v python3)"
    set -- "$PYBIN" -m coverage
fi
for docs_port in check-docs-examples check-docs-organization; do
    dp="$PLUGINS_DIR/review-audit/skills/$docs_port/patterns.py"
    [ -f "$dp" ] || continue
    (cd "$DOCS_SB" && PATH="" "$@" run --parallel-mode \
        --source="$PLUGINS_DIR" "$dp" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
done
set --

# check-docs-examples reads .md content in scan_file — an unreadable .md that
# passes isfile() drives its per-file OSError arm (run inside the sandbox).
(cd "$DOCS_SB" &&
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLUGINS_DIR/review-audit/skills/check-docs-examples/patterns.py" \
        "$DOCS_UNREAD_LIST" >/dev/null 2>&1) || true

# organization: root-level path skip, ghost-subdir skip, and listdir-OSError arm.
(cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 \
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
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
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Absent-binary no-op arm.
    AGNIX_BIN="/nonexistent/agnix" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Malformed-JSON fail-loud arm.
    AGNIX_BIN="$AGX_BAD" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Empty-output fail-loud arm (RuntimeError "no JSON output").
    AGNIX_BIN="$AGX_EMPTYOUT" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Non-list diagnostics fail-loud arm.
    AGNIX_BIN="$AGX_NOARRAY" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # diagnostics:null -> null-coalesce-to-[] arm (clean empty result).
    AGNIX_BIN="$AGX_DIAGNULL" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Top-level non-object fail-loud arm.
    AGNIX_BIN="$AGX_TOPARR" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Non-object diagnostic element fail-loud arm.
    AGNIX_BIN="$AGX_NONDICT" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # JSON null-field coalescing arm (_field null branch + null-file drop).
    AGNIX_BIN="$AGX_NULL" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Present-but-non-executable binary -> subprocess OSError arm.
    AGNIX_BIN="$AGX_NOEXEC" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_LIST" >/dev/null 2>&1 || true
    # Empty file-list arm (exit 0, no agnix invocation).
    AGNIX_BIN="$AGX_STUB" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$AGX_EMPTY" >/dev/null 2>&1 || true
    # Usage-error arm (no argument) + file-list-not-found arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" >/dev/null 2>&1 || true
    AGNIX_BIN="$AGX_STUB" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AGNIX_NORM_PY" "$WORKDIR/agnix-nonexistent-XYZ.txt" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- The non-patterns.py workflow tools (#748) -------------------------------
# Each is declared in NON_PATTERNS_TOOLS above and driven here. Neither of the
# first two is file-list shaped in the way the glob loop assumes, which is
# exactly why they fell out of that loop in the first place: split-verify.py
# takes <original> <post-split> [results...] and autonomy-resolve.py takes
# subcommands. Driving them means writing their real CLI, not extending a glob.

# --- ship-issue/sizing.py — the review-lens size scanner ---------------------
SIZING_PY="$PLUGINS_DIR/workflow/skills/ship-issue/sizing.py"
if [ -f "$SIZING_PY" ]; then
    # Thresholds tuned down so the compact fixtures reach the over-budget and
    # classified-prose arms; the corpus stays small while the branches still fire.
    #
    # They are INLINE assignments on each invocation rather than an
    # `env $VARS run_coverage` prefix: `env` execs a BINARY and cannot invoke a
    # shell function, so that shape would fail every call — silently, since each
    # is `|| true`, leaving the driver looking fine while measuring nothing.

    # No numstat at all -> every over-threshold file reported LOW/informational.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # BIG growth -> the crossed/blocking disposition.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_BIG" >/dev/null 2>&1 || true
    # TRIVIAL growth -> the pre-existing-debt arm (a one-line touch is not this
    # PR's debt), the disposition that distinguishes this lens from the audit one.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_TRIVIAL" >/dev/null 2>&1 || true
    # A numstat row matching nothing in the list -> the unmatched-row arm.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_ORPHAN" >/dev/null 2>&1 || true
    # Default (untuned) thresholds -> the under-budget early-return path.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # --measure mode: the 13-field metrics record plan-lens.py consumes.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" --measure "$SIZING_LIST" >/dev/null 2>&1 || true
    # Memory-bundle classification arms (index vs concept), and the opted-out
    # empty-root early return.
    MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    MEMORY_BUNDLE_ROOT='' \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # Negative-path arms: usage (no argument), list-not-found (OSError), empty
    # list (early return), unreadable file (per-file OSError read arm).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_NOFILE_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_EMPTY_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_UNREAD_LIST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- ship-issue/plan-lens.py — the plan-lens projection scanner (#756) -------
PLANLENS_PY="$PLUGINS_DIR/workflow/skills/ship-issue/plan-lens.py"
if [ -f "$PLANLENS_PY" ]; then
    # The load-bearing arm: near.py is UNDER budget today and OVER once the
    # estimate lands. Both other lenses return early for it, so this projection
    # is the row only this scanner produces — driving it without an estimate that
    # CROSSES a budget would measure the file while missing its reason to exist.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_CROSS" >/dev/null 2>&1 || true
    # An estimate that leaves everything under -> the no-row arm.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_SMALL" >/dev/null 2>&1 || true
    # Malformed estimate rows -> the parse-skip arms.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_BAD" >/dev/null 2>&1 || true
    # No estimate sidecar at all -> the already-over-budget-only path.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # Below the minimum-estimate floor -> the too-small-to-report arm.
    PLAN_HEADROOM_MIN_ESTIMATE=9999 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_CROSS" >/dev/null 2>&1 || true
    # Negative-path arms: usage, list-not-found, empty list.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_NOFILE_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_EMPTY_LIST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- ship-issue/split-verify.py — <original> <post-split> [results...] -------
SPLITV_PY="$PLUGINS_DIR/workflow/skills/ship-issue/split-verify.py"
if [ -f "$SPLITV_PY" ]; then
    # Sound split -> split-verified (all four properties hold).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_KEPT" "$SPLIT_MOVED" >/dev/null 2>&1 || true
    # A unit dropped -> split-unit-lost (+ the LOC-conservation arm).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_KEPT" "$SPLIT_LOSSY" >/dev/null 2>&1 || true
    # A call site left dangling -> split-fanin-dangling.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_DANGLE" >/dev/null 2>&1 || true
    # Markdown: heading moved out with NO link back -> split-heading-unreachable;
    # then the same split WITH the link -> the reachable arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MD_ORIG" "$SPLIT_MD_KEPT_NOLINK" "$SPLIT_MD_MOVED" \
        >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MD_ORIG" "$SPLIT_MD_KEPT_LINK" "$SPLIT_MD_MOVED" \
        >/dev/null 2>&1 || true
    # Memory bundle (#729): extracted concept with no index line ->
    # split-memory-orphan; then with MEMORY.md naming it -> the indexed arm.
    (cd "$SPLIT_MEM_ROOT" && MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MEM_ORIG" "$SPLIT_MEM_KEPT" "$SPLIT_MEM_MOVED" \
        >/dev/null 2>&1) || true
    (cd "$SPLIT_MEM_ROOT" && MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MEM_ORIG" "$SPLIT_MEM_KEPT" "$SPLIT_MEM_MOVED" \
        "$SPLIT_MEM_INDEX" >/dev/null 2>&1) || true
    # Negative-path arms: usage (none / one argument) and a named file that does
    # not exist, on both the original and the result side.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_GHOST" "$SPLIT_KEPT" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_GHOST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- scripts/autonomy-resolve.py — subcommand shaped, not file-list shaped ---
AUTONOMY_PY="$PLUGINS_DIR/workflow/scripts/autonomy-resolve.py"
if [ -f "$AUTONOMY_PY" ]; then
    # `level`: each input route (a --level flag inside --from-args, a
    # --chosen-level from an orchestrator or the operator's setup answer, and no
    # signal at all -> the L1 fallback).
    for _lvl in 1 2 3 4; do
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" level --from-args "123 --level $_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" level --chosen-level "$_lvl" >/dev/null 2>&1 || true
    done
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level >/dev/null 2>&1 || true
    # The severity/critical CAP (L4 -> L3, capped=true) in both label spellings,
    # and a non-critical severity that must NOT cap. This is the arm that decides
    # whether a plan gate is kept or auto-passed, so both sides are driven.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity critical >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity severity/critical >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity low >/dev/null 2>&1 || true
    # `gate`: routine vs escalation at every level, plus the --dead-end override
    # that defers to a human at L4 too.
    for _lvl in 1 2 3 4; do
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate routine --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate escalation --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate escalation --level "$_lvl" --dead-end >/dev/null 2>&1 || true
        # `sweep-interval` and `read` across the same level range.
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" sweep-interval --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" read --state-level "$_lvl" >/dev/null 2>&1 || true
    done
    # `read` with no state level -> the L1 default.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" read >/dev/null 2>&1 || true
    # Usage-error arms (exit 2): no subcommand, unknown subcommand, unknown gate
    # kind, out-of-range level, non-numeric level, missing required flag.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" bogus-subcommand >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate bogus-kind --level 2 >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine --level 9 >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine --level abc >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" sweep-interval >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 7 >/dev/null 2>&1 || true
    unset _lvl
    run_count=$((run_count + 1))
fi

# --- scripts/golem-event-listener.py — a BLOCKING HTTP server ----------------
#
# The one tool here that cannot simply be invoked and awaited: it binds a socket
# and calls serve_forever(). Three properties make driving it safe:
#
#   * EPHEMERAL PORT. The OS hands out a free port (bind :0, read it back, close)
#     rather than the 8787 default, so a developer already running a listener —
#     or a second copy of this script — cannot collide.
#   * BOUNDED READINESS WAIT. /healthz is polled up to ~5s, bailing out early if
#     the process already died. It never waits on a server that will not arrive.
#   * SIGTERM SHUTDOWN. The listener installs a SIGTERM handler that raises
#     KeyboardInterrupt, so serve_forever() unwinds through its `finally` and the
#     process exits 0. That ordinary exit is what lets coverage.py FLUSH its data
#     file — a SIGKILL would leave the measurement it just collected unwritten,
#     which is the whole reason the shutdown path matters here.
#
# If the server does not come up, this block prints one line and moves on. A
# reporting script must never hang or fail the run over an optional component.
LISTENER_PY="$PLUGINS_DIR/workflow/scripts/golem-event-listener.py"
if [ -f "$LISTENER_PY" ]; then
    # An ephemeral loopback port (same shape as free_port in
    # tests/validate-golem-event-listener.sh).
    LISTEN_PORT="$(
        python3 - <<'PY' 2>/dev/null || true
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    )"
    if [ -n "$LISTEN_PORT" ]; then
        # `exec` inside the backgrounded subshell is load-bearing: without it,
        # $! is the SUBSHELL's pid, the SIGTERM below reaps only that wrapper,
        # and the real coverage process is ORPHANED — it survives the script and,
        # never having exited cleanly, never flushes its data file. Measured:
        # the handler and serve_forever lines came back UNMEASURED while the
        # driver still reported success, and a stray listener was left running.
        # exec replaces the subshell, so $! addresses the process that must
        # receive the signal.
        (cd "$LISTENER_SB" && export GOLEM_EVENT_LISTEN_ADDR=127.0.0.1 \
            GOLEM_EVENT_LISTEN_PORT="$LISTEN_PORT" GOLEM_EVENT_MAX_BODY=512 &&
            exec_coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$LISTENER_PY" >/dev/null 2>&1) &
        LISTENER_PID=$!

        # Bounded readiness poll, bailing out early if the process already died.
        _tries=0
        _ready=""
        while [ "$_tries" -lt 50 ]; do
            if python3 - "$LISTEN_PORT" <<'PY' >/dev/null 2>&1; then
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=1).read()
PY
                _ready="yes"
                break
            fi
            kill -0 "$LISTENER_PID" 2>/dev/null || break
            sleep 0.1
            _tries=$((_tries + 1))
        done

        if [ -n "$_ready" ]; then
            # A valid event, an unknown event kind (defaults to "gate"), the
            # orphan sentinel (ACKed but never appended), a malformed body, an
            # oversized body (past GOLEM_EVENT_MAX_BODY), and a GET on /healthz.
            python3 - "$LISTEN_PORT" <<'PY' >/dev/null 2>&1 || true
import json, sys, urllib.error, urllib.request

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"


def post(body: bytes, path: str = "/") -> None:
    req = urllib.request.Request(base + path, data=body, method="POST")
    try:
        urllib.request.urlopen(req, timeout=2).read()
    except urllib.error.HTTPError:
        pass  # 4xx arms are the point of several of these
    except OSError:
        pass


post(json.dumps({"golem": "golem-5", "event": "gate",
                 "message": "Claude needs your permission to push"}).encode())
post(json.dumps({"golem": "golem-7", "event": "escalation",
                 "message": "architectural decision"}).encode())
post(json.dumps({"golem": "golem-9"}).encode())            # absent event -> "gate"
post(json.dumps({"golem": "golem-?", "event": "gate",
                 "message": "orphan"}).encode())           # sentinel: ACK, no append
post(json.dumps({"golem": "golem-1", "event": "gate",
                 "message": "x" * 4096}).encode())         # oversized -> rejected
post(b"not json at all {{{")                                # malformed -> rejected
post(b"")                                                   # empty body
post(json.dumps([1, 2, 3]).encode())                        # non-object JSON
post(json.dumps({"golem": "golem-2", "event": "gate",
                 "message": "m"}).encode(), "/nope")        # unknown path
try:
    urllib.request.urlopen(base + "/healthz", timeout=2).read()
except OSError:
    pass
PY
        else
            printf '[note] python-coverage — golem-event-listener did not start; skipping its driver\n'
        fi

        # SIGTERM (never SIGKILL): the handler raises KeyboardInterrupt so the
        # process exits cleanly and coverage.py flushes its data file.
        kill -TERM "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
        unset _tries _ready
        run_count=$((run_count + 1))
    else
        printf '[note] python-coverage — no free port; skipping golem-event-listener driver\n'
    fi

    # Fail-loud startup arms, driven WITHOUT binding anything: a non-integer port
    # and a non-integer max-body both exit 2 before the socket is created, and an
    # unbindable address exits 1. No cleanup needed — none of them starts a server.
    (cd "$LISTENER_SB" && GOLEM_EVENT_LISTEN_PORT="not-a-port" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
    (cd "$LISTENER_SB" && GOLEM_EVENT_MAX_BODY="not-a-number" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
    (cd "$LISTENER_SB" && GOLEM_EVENT_LISTEN_ADDR="256.256.256.256" \
        GOLEM_EVENT_LISTEN_PORT="8787" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
fi

# Restore perms so the trap `rm -rf` can clean WORKDIR without warnings.
chmod 644 "$SIZING_UNREAD" 2>/dev/null || true
chmod 644 "$DOCS_UNREADABLE" "$DOCS_UNREADABLE_PY" 2>/dev/null || true
chmod 755 "$DOCS_SB/locked" 2>/dev/null || true
chmod 644 "$SRC_UNREAD" 2>/dev/null || true
chmod 644 "$AI_UNREAD" 2>/dev/null || true
chmod 644 "$LOOP_UNREAD" "$TSTDIR/gomod_test.go" "$TSTDIR/test_pymod.py" 2>/dev/null || true

# --- Combine + emit Cobertura XML at the repo root ---------------------------
run_coverage combine >/dev/null 2>&1 || true
run_coverage xml -o "$OUT_XML" >/dev/null 2>&1 || {
    printf '[FAIL] python-coverage — coverage xml failed\n' >&2
    exit 1
}

if [ ! -s "$OUT_XML" ]; then
    printf '[FAIL] python-coverage — coverage.xml is empty\n' >&2
    exit 1
fi

pct="$(run_coverage report 2>/dev/null | awk '/^TOTAL/ {print $NF}')"
printf '[ok] python-coverage — %s ports run, coverage.xml written (TOTAL %s)\n' \
    "$run_count" "${pct:-n/a}"
