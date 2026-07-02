# Test framework architecture — agent & skill definitions

Design and roadmap for testing the `librarian` plugin artifacts. `README.md` is
the **how-to-run** reference; this document is the **why / what-tier / what's-missing**
companion. It satisfies the "Expected Output" of
[#16](https://github.com/joshjhall/librarian/issues/16) — an architecture that
names the test layers, maps each to the gate that implements it, and records the
priority-ordered gaps (filed as follow-up issues) plus the LLM-in-the-loop
decision.

## Purpose & scope

Agent and skill definitions are **effectively code**: they have structural
requirements (frontmatter schemas), behavioral contracts (`contract.md` ↔
`patterns.sh` output), and cross-file dependencies (`agentType` →
`agents/<name>.md`). They regress silently — a bad frontmatter field, a
`workflow.js` that names a deleted agent, a `patterns.sh` that crashes on empty
input — with no compiler to catch it. This framework treats them as a tested
tier.

The artifacts under test (counts as of this writing):

| Artifact | Location | Count |
| --- | --- | --- |
| Agents | `plugins/*/agents/<name>.md` (flat) | 17 |
| Skills | `plugins/*/skills/<name>/SKILL.md` | 38 |
| Workflow harnesses | `plugins/*/{agents,skills}/<name>/workflow.js` | 5 |
| Deterministic pre-scans | `patterns.sh` / `pre-review-gates.sh` | 15 |
| Skill metadata | `metadata.yml` | 38 |
| Output schemas | `*.schema.json` | 6 |

> **Layout note.** Issue #16 was written against the pre-extraction `containers`
> tree (`lib/features/templates/claude/{agents,skills}/`). Those artifacts now
> live under `plugins/<plugin>/{agents,skills}/` after the
> containers→librarian extraction
> ([#5](https://github.com/joshjhall/librarian/issues/5)). Every gate below was
> retargeted to the new layout; this document uses the real paths.

## Test layers

The unit / integration / behavioral taxonomy from #16, each mapped to the
concrete gate that implements it today. **The framework is not greenfield** —
the extraction shipped most of it.

| Layer | Research question (#16) | Implemented by | File |
| --- | --- | --- | --- |
| Unit — harness | Do the shared assertions behave as the gates assume? | harness self-test | `validate-harness.sh` |
| Unit — manifests | Manifest name/version agreement | manifest validation | `validate-manifests.mjs` |
| Unit — structure | Frontmatter schema; companion files; `workflow.js` well-formedness | structural lint | `lint-skills-agents.sh` |
| Integration — contracts | Output contract conformance; `patterns.sh` categories match `contract.md` | contract validation | `validate-contracts.sh` |
| Integration — schemas | Declared JSON schema matches output shape | JSON Schema files | `plugins/*/skills/*/**/*.schema.json` |
| Behavioral (no LLM) | Test runtime behavior without LLM calls | real-script regression gate | `golem-gate-watch.sh` |
| Behavioral (LLM-in-loop) | Is snapshot/LLM testing worth the cost? | **deferred** (see decision) | — |

All gates run through one entry point, `run-all.sh`, run-to-completion (no early
exit), and degrade gracefully — skipping rather than failing when an optional
tool (`node`, `jq`) is absent. The shared assertion/reporting helpers live in
`lib/harness.sh` (zero-dependency bash, no Docker), so the suite runs
identically on a host Mac, a bare Linux box, and inside the devcontainer.

## What exists today

| Gate | Validates |
| --- | --- |
| `validate-harness.sh` | Self-test for `lib/harness.sh` — `assert_true`'s message-vs-command heuristic, the value assertions (`assert_equals`/`assert_not_empty`/`assert_contains`/`assert_not_contains`) on passing+failing inputs, and `skip_test`'s counter bookkeeping. Failing probes run in isolated subshells. Pure bash. |
| `validate-manifests.mjs` | `marketplace.json` + every `plugin.json` agree on name + semver; each `source` points at a real plugin dir. Zero deps (node only). |
| `lint-skills-agents.sh` | Every agent is a flat `<name>.md` whose `name` matches its filename, with valid `name`/`description`/`tools`/`model` frontmatter; every skill has a `SKILL.md`; `check-*`/`loop-*`/`context-*` skills carry their required companion files; `patterns.sh` are executable; every `workflow.js` `export const meta` is a pure literal and passes `node --check`. |
| `validate-contracts.sh` | `check-*`/`loop-*` `contract.md` JSON examples are valid, carry every required finding-schema/loop-report field, hold in-range enums (severity, effort, certainty) and a `version:`, and the `patterns.sh` output categories are declared in the contract. Schema-shape checks use `jq`, skip when absent. |
| `golem-gate-watch.sh` | Runs the **real** `golem-gate-watch.sh --once` against throwaway repos with crafted `feed.jsonl` lines — guards the #24 regression (null/empty `.ts` must not drop BLOCKED golems) and the TTL-aging branch. No LLM. |
| `run-all.sh` | Single entry point: runs every stage above to completion, exits non-zero if any fails. |

Output schemas: `finding-schema.schema.json`, `loop-report.schema.json`
(review-audit/codebase-audit), `next-issue-state.schema.json`,
`next-issue-queue.schema.json`, and the three orchestrate
`*-status.schema.json` files.

## Integration — where the gates run

The single entry point is wired into **both** automation surfaces, and both call
`run-all.sh` rather than re-listing stages, so adding or renaming a stage updates
every surface at once (no drift).

| Surface | Trigger | What runs |
| --- | --- | --- |
| Local — `just test` | manual | `bash tests/run-all.sh` |
| Local — lefthook `pre-push` | push touching `plugins/**` or `tests/**` | `bash tests/run-all.sh` (skips without `node`) |
| Local — lefthook `pre-commit` | staged `*.json` manifest | `validate-manifests.mjs` (fast subset) |
| CI — `.github/workflows/ci.yml` | push / PR to `main` | `validate-manifests` job, then a `quality-gates` job running `run-all.sh` |
| Release — `.github/workflows/release.yml` | `v*` tag | same gates against the tagged tree + `VERSION`↔tag check |

> **Single-source-of-truth rule.** CI's `quality-gates` job and lefthook's
> `pre-push` both invoke `tests/run-all.sh`. Do **not** re-enumerate individual
> gate scripts in `ci.yml` or `lefthook.yml`; add the stage to `run-all.sh` and
> both surfaces pick it up. The `pre-commit` manifest check is the one
> deliberate exception — a deps-free fast subset kept inline for commit-time
> speed.

## Gaps & priority

Comparing what exists against #16's research questions, the genuine remaining
gaps. This list **is** the "priority-ordered list of tests to implement (filed
as subsequent issues)" that #16's Expected Output asks for — each row links the
follow-up issue that tracks it, so #16 itself is closed as a design deliverable
once this document and those issues exist (the implementation of each gap lands
under its own issue, not here).

| # | Gap | Tracked by | Priority | Effort | Approach |
| --- | --- | --- | --- | --- | --- |
| 1 | `workflow.js` validation is partial — meta-purity + `node --check` only | [#40](https://github.com/joshjhall/librarian/issues/40) | **P1** | small | In `lint-skills-agents.sh`, assert each `phase()` title declared in the script is in `meta.phases` (and vice-versa), and each `agentType=` resolves to a real agent. |
| 2 | Cross-reference integrity unvalidated — `agentType` / `subagent_type` in `workflow.js` and `SKILL.md` | [#41](https://github.com/joshjhall/librarian/issues/41) | **P2** | small | Resolve every referenced agent name against `plugins/*/agents/<name>.md` across all plugins; fail on dangling references. |
| 3 | `metadata.yml` `required_tools` not checked against frontmatter `tools` | [#42](https://github.com/joshjhall/librarian/issues/42) | **P2** | medium | Cross-check the declared `required_tools` against the agent/skill's actual `tools`; flag drift. |
| 4 | `patterns.sh` empty/missing-input robustness untested | [#43](https://github.com/joshjhall/librarian/issues/43) | **P3** | small | Feed each pre-scan empty + missing-arg input; assert clean exit (no crash, no spurious findings). |
| 5 | LLM-in-the-loop behavioral tier | — | — | — | **Deferred** — see decision below. |

The three `workflow.js` checks #16's "Workflow scripts as a tested artifact
tier" section enumerates (structural `phase()`↔`meta.phases`, `agentType`
cross-reference, no-spawn graph lint) are split across **#40** (the P1
quick-win) and **#41**; the current lint already covers their meta-purity +
`node --check` prerequisite. They are intentionally **not** implemented in this
design PR — #16 is closed by the architecture + the filed backlog, and the gates
themselves ship under #40/#41.

## LLM-in-the-loop decision

**Decision: deferred.** Behavioral tests that invoke a live model (snapshot
testing agent responses, feeding focused cases and grading output) are
**out of scope** for the framework's first iteration.

Rationale: they are non-deterministic (snapshot drift on every model update),
have real per-run cost, and would couple CI to model availability and API
credentials — at odds with the suite's no-Docker, deps-optional,
runs-anywhere design. The behavioral signal we need today is reachable
deterministically: `golem-gate-watch.sh` exercises **real script behavior**
against crafted fixtures with zero LLM calls, and is the model to copy for
future behavioral gates (e.g. running a `patterns.sh` against a known-bad
fixture and asserting the exact findings). Revisit LLM-in-the-loop only if a
class of regression appears that no deterministic gate can catch.

## Conventions for new validators

- **Location.** New gates live in `tests/` as `*.sh` (or `*.mjs` for node-only,
  deps-free logic). Add them as a stage in `run-all.sh` — never as a new inline
  step in `ci.yml`/`lefthook.yml`.
- **Harness.** Use `lib/harness.sh` (`test_suite` / `run_test` / `assert_*` /
  `skip_test`) for assertions and reporting; it matches the `containers`
  framework semantics so relocated tests run unmodified.
- **Graceful degradation.** Skip (don't fail) when an optional tool is absent —
  `skip_test` with a reason, gated on `command -v <tool>`. The suite must stay
  green on a bare host.
- **Negative fixtures.** Prove a detector fires with a committed bad fixture
  (e.g. `fixtures/claude/workflow_meta_bad.js`); keep it intentionally broken.
- **No early exit.** Stages report all failures together; `run-all.sh` collects
  and exits non-zero if any stage failed.
