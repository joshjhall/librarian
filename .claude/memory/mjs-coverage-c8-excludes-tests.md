---
name: mjs-coverage-c8-excludes-tests
description: "c8 excludes tests/ by default, so covering tests/*.mjs validators needs --exclude override; use NODE_V8_COVERAGE + c8 report to merge multiple entry points"
metadata:
  node_type: memory
  type: project
  originSessionId: 4072d4d5-dc23-48bf-9bf4-b614e642e3f9
---

Wiring Codecov for the `.mjs` validators (issue #186, PR pending). Two
non-obvious traps in `tests/coverage-mjs.sh`:

**1. c8 excludes `test/` and `tests/` by default.** Our instrumented sources
ARE `tests/validate-manifests.mjs` + `tests/validate-workflow-helpers.mjs`, so
the default exclude drops them and c8 reports `All files 0%` with an EMPTY
lcov — silently, no error. Fix: `--exclude='node_modules/**'` (override the
default set) + `--include=` the exact validator paths.

**Why:** c8's default `exclude` array bundles `test/`, `tests/`, `**/*.test.*`.
Passing any `--exclude` replaces the whole default array, not appends.

**2. Merging coverage across multiple entry points.** Running `npx c8 node X`
then `npx c8 node Y` clobbers, keeping only the last. Instead run each validator
plain with `NODE_V8_COVERAGE=<shared_dir> node X` so V8 drops per-process JSON,
then a single `npx c8 report --temp-directory=<shared_dir>` merges them. This
also keeps each validator's own exit status observable (they run unwrapped, so a
validator failure still surfaces — the script doubles as a smoke test).

**How to apply:** c8 fetched on demand via `npx --yes` (no package.json /
node_modules committed — matches repo posture). Python side is simpler:
`coverage run --parallel-mode` per port + `coverage combine` (see
[[bash-coverage-category-error]] for why bash is NOT measured). Artifacts
(`coverage.xml`, `coverage/`) are gitignored; `just coverage` runs both;
NOT wired into `run-all.sh` (additive, non-blocking — coverage job is absent
from `merge-gate` needs).
