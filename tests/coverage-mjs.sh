#!/usr/bin/env bash
# JavaScript coverage for the .mjs validators (#186).
#
# Emits coverage/lcov.info for the two node validators
# (tests/validate-manifests.mjs + tests/validate-workflow-helpers.mjs) so CI can
# upload it to Codecov alongside the Python coverage.xml.
#
# Approach: run each validator with NODE_V8_COVERAGE pointed at a shared temp
# dir so V8 writes per-process coverage JSON, then `c8 report` merges both into a
# single lcov. This keeps each validator's own exit status observable (they run
# as plain `node ...`, not wrapped, so a validator failure still surfaces) while
# accumulating coverage across both. c8 is fetched on demand with `npx --yes` —
# the repo commits no package.json / node_modules, matching its zero-dep,
# on-demand tooling posture.
#
# Note on c8's default excludes: c8 excludes test/ and tests/ dirs by default,
# but our instrumented sources ARE the tests/*.mjs validators, so we override
# --exclude to just node_modules and --include the validators plus the modules
# they import.
#
# The --include list MUST track the module layout (#564). validate-workflow-
# helpers.mjs is now a thin entry point: the ~3,300 lines of assertions live in
# tests/workflow-helpers/*.mjs and the extraction machinery in tests/lib/*.mjs.
# An --include pinned to the entry point alone would report a green 2-file lcov
# while silently dropping every line that does the work — a coverage cliff that
# looks exactly like a passing report. Add new .mjs module dirs here when they
# appear.
#
# Each pattern is SINGLE-LEVEL: `tests/workflow-helpers/*.mjs` does NOT match
# `tests/workflow-helpers/ship-issue/*.mjs`. So a nested sub-split needs its own
# line — a sub-directory added without one hits the exact cliff above, and does
# it silently, since the parent glob still matches the thin dispatcher and the
# report stays green. ship-issue/ (#712) is the first such sub-split.
#
# Skips gracefully (exit 0, no report) when node or npx is unavailable — the
# same skip-if-absent posture as the sibling gates. NOT wired into
# tests/run-all.sh: additive reporting only, run by CI and `just coverage`.
#
# Pure bash-3.2 + coreutils + node/npx; c8 is fetched via npx at run time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Runtime gate: node + npx, else skip cleanly -----------------------------
if ! command -v node >/dev/null 2>&1; then
    printf '[skip] mjs-coverage — node not available\n'
    exit 0
fi
if ! command -v npx >/dev/null 2>&1; then
    printf '[skip] mjs-coverage — npx not available (needed to fetch c8)\n'
    exit 0
fi

# The two node validators under coverage. Add new .mjs validators here.
VALIDATORS="tests/validate-manifests.mjs tests/validate-workflow-helpers.mjs"

V8_DIR="$REPO_ROOT/coverage/.v8"
OUT_DIR="$REPO_ROOT/coverage"
rm -rf "$V8_DIR"
mkdir -p "$V8_DIR"

# --- Run each validator, letting V8 emit per-process coverage into V8_DIR -----
# Run from the repo root so the lcov SF: paths are repo-relative (tests/...),
# which is what Codecov expects. A validator that exits non-zero is a real
# failure — surface it rather than masking it, so this doubles as a smoke test.
cd "$REPO_ROOT"
rc=0
for v in $VALIDATORS; do
    if [ ! -f "$v" ]; then
        printf '[FAIL] mjs-coverage — validator not found: %s\n' "$v" >&2
        exit 1
    fi
    if ! NODE_V8_COVERAGE="$V8_DIR" node "$v" >/dev/null 2>&1; then
        printf '[warn] mjs-coverage — validator exited non-zero: %s\n' "$v" >&2
        rc=1
    fi
done

# --- Merge the per-process V8 data into a single lcov -------------------------
# --all=false so only files actually loaded appear; --exclude limited to
# node_modules so c8's default test/ exclusion does not drop our validators.
if ! npx --yes c8 report \
    --temp-directory="$V8_DIR" \
    --reporter=lcovonly \
    --reports-dir="$OUT_DIR" \
    --include='tests/validate-manifests.mjs' \
    --include='tests/validate-workflow-helpers.mjs' \
    --include='tests/workflow-helpers/*.mjs' \
    --include='tests/workflow-helpers/ship-issue/*.mjs' \
    --include='tests/lib/*.mjs' \
    --include='bin/*.mjs' \
    --exclude='node_modules/**' \
    --all=false >/dev/null 2>&1; then
    printf '[FAIL] mjs-coverage — c8 report failed\n' >&2
    exit 1
fi

LCOV="$OUT_DIR/lcov.info"
if [ ! -s "$LCOV" ]; then
    printf '[FAIL] mjs-coverage — lcov.info is empty\n' >&2
    exit 1
fi

sf_count="$(grep -c '^SF:' "$LCOV" 2>/dev/null || printf '0')"
rm -rf "$V8_DIR"

if [ "$rc" -ne 0 ]; then
    printf '[warn] mjs-coverage — lcov written (%s files) but a validator failed\n' "$sf_count" >&2
fi
printf '[ok] mjs-coverage — %s file(s) instrumented, coverage/lcov.info written\n' "$sf_count"
