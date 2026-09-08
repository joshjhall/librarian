# Tests

| Check | Command |
|---|---|
| Everything | `bash tests/run-all.sh` |
| One shard | `bash tests/run-all.sh --shard 10-portability` |
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

## Shards (#960)

The stage list lives in `tests/shards/NN-<area>.sh`, not in `run-all.sh`. A bare
`bash tests/run-all.sh` still runs **every** stage in order, so `just test` and
the pre-push hook are unchanged; `--shard <name>` runs one, which is what CI's
`quality-gates` matrix passes.

| Shard | Area | Stage time |
|---|---|---|
| `10-portability` | shell portability (the indivisible floor), ruff, typos, regex probes | ~337s |
| `20-golem` | golem/worktree helpers, PreToolUse hooks, stop/route decisions | ~350s |
| `30-scanners` | `check-*` detector fixtures, contract/prose/doc gates, shellcheck, bash↔python parity | ~260s |

Those are one run's numbers (34187725583) and are **runner-dependent** — the same
stages swing ±30% between runs with no code change. Compare sums within a single
run, never across two.

Sharding cut the CI job from ~22 min to roughly the largest shard.
`10-portability` sets the floor: its Shell portability stage cannot be
subdivided and is essentially that whole leg (335s of 337s in run 34187725583 —
every other stage in that leg costs 0–1s), so no partition finishes sooner than
that one stage. The bound is **structural, not a number** — the stage's own
runtime varies ~8% run to run on identical code. Two cautions when re-deriving
it: pair a stage time only with a leg total from the **same** run (the pre-#964
samples came from a leg that still held four more gates), and ignore the 547s
older notes quote — that was the pre-sharding *serial* run, all ~96 stages on
one runner. The stage never got faster; the measurement context changed.

**#964 re-balanced these to the floor.** The original split was drawn
before #961 fixed an unbounded capture that made `golem/worktree helper scripts`
read as 1175s instead of 234s, leaving the legs at 522 / 376 / 175s. Four gates
moved out of `10-portability` (bash↔python differential, shellcheck, python-port
contract, `bounded_run` behavior) and one out of `20-golem` (coverage-driver
listener), all into `30-scanners` — cutting CI wall clock from 542s to **370s**
(measured, run 34187725583). The three legs are now within ~90s of each other
instead of ~347s, so `30-scanners` is no longer free headroom for a new heavy
gate: measure all three sums before adding one. Those five stages sit in
`30-scanners` for **balance, not theme**, and are tagged as such at their call
sites.

**Setup cost is not the lever** (#964 AC1). Summing every non-suite CI step per
leg gives 17 / 19 / 22s, not the ~120s the issue estimated — that figure came
from subtracting stage sums from the UI wall clock, which includes runner queue
time. Per-shard conditional setup was therefore rejected: it would save seconds
and risks a shard silently losing a linter its gate needs.

**Adding a stage:** put the `run_stage` line in exactly one shard — never in
`run-all.sh` — and nowhere else. `tests/validate-shards.sh` fails the suite if a
shard file is unlisted in `run-all.sh`'s `SHARDS` manifest, if a listed shard is
missing, if a stage is claimed by two shards, or if any `tests/*.sh` gate is
dispatched by no shard at all. That last direction is the important one: without
it a renamed gate could stop running while every shard still reported green.

**Re-balancing** is a manifest edit plus moving `run_stage` lines between shard
files. If a shard ever approaches its `timeout-minutes`, re-balance or add a
shard rather than raising the cap — the cap bounds a hang, and raising it is
what #834 and #932 each did before the split.

**One constraint on re-balancing: worktree-mutating stages stay together.**
`tests/lib/golem-sandbox.sh` creates and removes git worktrees in the repo under
test, so two suites using it against the *same checkout* contend on shared
worktree state. The symptom is a **stall**, not a failure, at an arbitrary point
— which looks exactly like the `timeout-minutes` cancellation that motivated
sharding in the first place.

On GitHub Actions each matrix leg gets its own runner and its own checkout, so
this hazard does not apply there — an assumption worth stating rather than
inheriting silently. It *is* live locally: two parallel `--shard N` invocations
share one checkout. Keeping those stages in one shard makes them sequential,
which is what makes them safe, and `tests/validate-shards.sh` enforces it.
See #961 for the unbounded capture that turns the contention into a hang.

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
