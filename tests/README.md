# Tests

| Check | Command |
|---|---|
| Everything | `bash tests/run-all.sh` |
| Manifest validation | `node tests/validate-manifests.mjs` |
| Skill/agent structural lint | `bash tests/lint-skills-agents.sh` |
| Skill contract validation | `bash tests/validate-contracts.sh` |
| golem-gate-watch feed snapshot | `bash tests/golem-gate-watch.sh` |

`run-all.sh` is the single entry point: it runs manifest validation followed by
the structural gates and one behavioral gate, runs every stage to completion
(no early exit), and exits non-zero if any stage fails.

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

## Behavioral gates

- **`golem-gate-watch.sh`** — runs the real
  `plugins/workflow/scripts/golem-gate-watch.sh --once` against a throwaway
  repo whose `.worktrees/.status/feed.jsonl` is seeded with crafted lines. It
  guards the issue #24 regression — a `feed.jsonl` line with a null/empty `.ts`
  must NOT abort the jq filter and silently drop every BLOCKED golem — and the
  symmetric TTL branch (a present-but-stale `.ts` still ages out). Skips
  cleanly when `jq` is absent (the helper no-ops without it).
