# Tests

| Check | Command |
|---|---|
| Everything | `bash tests/run-all.sh` |
| Manifest validation | `node tests/validate-manifests.mjs` |
| Harness self-test | `bash tests/validate-harness.sh` |
| Skill/agent structural lint | `bash tests/lint-skills-agents.sh` |
| Skill contract validation | `bash tests/validate-contracts.sh` |
| golem-gate-watch feed snapshot | `bash tests/golem-gate-watch.sh` |

**Capture, do not pipe** (#854): `bash tests/run-all.sh | tail` exits 0 on a
red suite, because a pipeline reports its last command's status. Run
`bash tests/run-all.sh > /tmp/run.log 2>&1; echo $?` instead. The failure
verdict is also mirrored to stderr so a piped run is still loud, but only the
captured form preserves the exit code.

`run-all.sh` is the single entry point: it runs manifest validation followed by
the structural gates and one behavioral gate, runs every stage to completion
(no early exit), and exits non-zero if any stage fails. It is invoked by both
CI (`.github/workflows/ci.yml`) and the lefthook `pre-push` hook, so the local
and CI suites cannot drift.

**Design & roadmap:** see [`ARCHITECTURE.md`](ARCHITECTURE.md) for the test
layers (unit / integration / behavioral), how each maps to the gate that
implements it, the priority-ordered gaps, and the LLM-in-the-loop decision.

`validate-manifests.mjs` parses `.claude-plugin/marketplace.json` and every
`plugins/*/.claude-plugin/plugin.json`, and asserts they agree on name +
semver version and that each `source` points at a real plugin directory. It
has no external dependencies so it runs identically on host and in CI.

## Skill/agent quality gates

The skill/agent quality gates were relocated from the `containers` repo
([joshjhall/librarian#5](https://github.com/joshjhall/librarian/issues/5)) so
migrated artifacts are validated where they live. They scan all three plugins
at `plugins/*/skills/` and `plugins/*/agents/` (retargeted from the original
single `lib/features/templates/claude/{skills,agents}` tree). Empty plugins
pass — discovery simply finds no artifacts to check.

- **`lint-skills-agents.sh`** — structural lint: every agent has a
  `<name>.md` with valid `name`/`description`/`tools`/`model` frontmatter
  (and the name matches its directory); every skill has `SKILL.md` with a
  description; `check-*`/`loop-*`/`context-*` skills carry their required
  companion files; `patterns.sh` files are executable; every `workflow.js`
  `export const meta` is a pure literal and passes `node --check`. A committed
  negative fixture (`fixtures/claude/workflow_meta_bad.js`) proves the
  meta-literal detector fires.
- **`validate-contracts.sh`** — contract validation: `check-*`/`loop-*`
  `contract.md` JSON examples are valid and carry every required
  finding-schema / loop-report field; enum values (severity, effort,
  certainty) are in range; a `version:` field exists; and each `check-*`
  skill's `patterns.sh` output categories are declared in its contract.
  Schema-shape checks use `jq` and skip gracefully when it is absent.

Both gates use a small self-contained harness at `tests/lib/harness.sh`
(assertions + reporting) instead of the `containers` Docker-coupled test
framework, so they run with just bash + coreutils (plus `node`/`jq` where
noted). Run on every PR by `.github/workflows/ci.yml`.

- **`validate-harness.sh`** — self-test for `tests/lib/harness.sh`. Every gate
  trusts the harness, so the harness gets its own coverage: `assert_true`'s
  argument-parsing heuristic (last arg is the message when it has whitespace or
  starts uppercase, else part of the command), the value assertions
  (`assert_equals` / `assert_not_empty` / `assert_contains` /
  `assert_not_contains`) on both passing and failing inputs,
  `assert_valid_json` on valid, malformed, and jq-absent inputs (including a
  single-quote value that proves the no-eval footgun is closed and the `false`/
  `null` scalars that pin the `jq empty` vs `jq -e .` contract), and
  `skip_test`'s counter bookkeeping. Each deliberately-failing probe runs in an isolated
  subshell so it cannot corrupt the live suite's counters.

## Behavioral gates

- **`golem-gate-watch.sh`** — runs the real
  `plugins/workflow/scripts/golem-gate-watch.sh --once` against a throwaway
  repo whose `.worktrees/.status/feed.jsonl` is seeded with crafted lines. It
  guards the issue #24 regression — a `feed.jsonl` line with a null/empty `.ts`
  must NOT abort the jq filter and silently drop every BLOCKED golem — and the
  symmetric TTL branch (a present-but-stale `.ts` still ages out). Skips
  cleanly when `jq` is absent (the helper no-ops without it).
