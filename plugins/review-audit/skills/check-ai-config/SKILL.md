---
description: Validates Claude Code configuration files (agents, skills, CLAUDE.md, MCP configs, hooks) for structural issues, bloat, and misconfigurations. Combines deterministic pre-scan with LLM heuristic analysis.
---

# check-ai-config

Validates Claude Code AI configuration artifacts for structural correctness,
bloat, misconfigurations, and quality issues. The deterministic pre-scan
(`patterns.sh`) handles structural checks; this skill handles nuanced analysis.

**How this relates to agnix**: the external
[agnix](https://github.com/agent-sh/agnix) linter is a complementary enrichment
layer, not a replacement — see
[`docs/adr/0001-agnix-check-ai-config-boundary.md`](../../docs/adr/0001-agnix-check-ai-config-boundary.md)
for the ownership boundary (this skill is the always-present floor; agnix
supersedes on overlap only when its binary is present). When agnix *is* present,
`agnix-normalize.{py,sh}` maps its `--format json` findings into this skill's TSV
contract (the `CC-*` rule → category map lives in [`contract.md`](contract.md)
§ agnix normalization); it no-ops silently when the binary is absent.

## Categories

### agent-frontmatter (deterministic + heuristic)

Pre-scan detects: missing frontmatter fields, invalid model values, wildcard
tools, naming convention violations. Valid model tokens are `fable`, `opus`,
`sonnet`, `haiku`, `inherit`, or a full model ID — do NOT flag a `fable` or
`inherit` agent as an invalid value.

LLM adds: wrong model selection for the task complexity. Judge against the
5-generation lineup — `haiku`=mechanical, `sonnet`=balanced default (Sonnet 5),
`opus`=implementation, most reasoning, and the judge/verify gates (Opus 5),
`fable`=only where opus has been measured as insufficient (Fable 5, ~2x opus per
token). `opus` is the ceiling for review-verification and orchestration gates:
what makes those accurate is a fresh, adversarial context, not the tier (#526).
Flag genuine mismatches (e.g. `fable` on a mechanical template-renderer, or
`haiku` on a security auditor) — but do NOT flag a balanced agent on `sonnet`,
nor the existing `audit-security`/`audit-architecture` on `fable` (grandfathered,
predating #526). Also flag tool lists that include write tools on read-only
agents, and descriptions that don't match the agent's actual behavior.

### skill-frontmatter (deterministic + heuristic)

Pre-scan detects: missing description, missing workflow section, missing
metadata.yml.

LLM adds: vague descriptions that don't help routing, scope overlap with
other skills, missing output format specification.

### ai-file-bloat (deterministic)

Pre-scan detects all AI-instruction files (CLAUDE.md/AGENTS.md, skill
definitions, agent definitions) via line counting against configurable
thresholds. LLM confirms whether large files contain decomposable sections.
Documentation files (`docs/*.md`) are counted under `doc-file-bloat` instead.

### doc-file-bloat (deterministic)

Pre-scan detects oversized documentation files (`docs/*.md`) via line counting
against the `doc_md` thresholds in `thresholds.yml` (warning 500 / high 800 by
default). Split out of `ai-file-bloat` so documentation bloat carries its own
canonical slug. LLM confirms whether the file is decomposable.

### claude-md-drift (deterministic pre-scan + heuristic)

Pre-scan detects: backtick-quoted relative file paths in `CLAUDE.md` /
`AGENTS.md` that do not resolve against the document's own directory. It is
conservative by design (emits MEDIUM): the char class excludes `${VAR}`
templates, globs, and URLs, and only file/dir paths with a source-file
extension are checked. LLM adds: separates literal drift from *illustrative*
paths (a doc may legitimately name a path that does not exist at that
location), and verifies referenced **commands** / directories the deterministic
pass does not check.

### config-inconsistency (deterministic pre-scan + heuristic)

Pre-scan detects: skill/agent markdown citing a `` `<plugin>:<name>` `` agent or
skill cross-reference where the plugin dir exists but neither
`agents/<name>.md` nor `skills/<name>/SKILL.md` resolves — a broken reference.
Non-plugin `foo:bar` tokens (e.g. `go:generate`) are ignored, so it emits
MEDIUM for the LLM to confirm.

LLM adds: CLAUDE.md claims that don't match the codebase, contradictions
between skill and agent instructions, and cross-references the deterministic
pass cannot resolve.

### mcp-misconfiguration (deterministic + heuristic)

Pre-scan detects: insecure HTTP URLs. LLM adds: missing env var documentation,
incorrect server arguments.

### hook-safety (deterministic + heuristic)

Pre-scan detects: destructive commands, secret leaks. LLM adds: context
assessment (e.g., a pre-commit hook running a formatter is acceptable).

### harness-logic (deterministic + heuristic)

Reviews `workflow.js` harnesses (and embedded shell in SKILL.md bash fences)
for the correctness/safety bug classes that frontmatter linting misses.

Pre-scan detects (mechanical signatures, conservatively): finding refs built as
a bare `file:line:category` template without an index segment (collision risk);
`${VAR}` interpolation inside a `--dangerously-skip-permissions` command
(injection surface); `npm install` / `pnpm install` / `composer update` without
a lockfile-only / `--ignore-scripts` flag (supply-chain).

LLM adds: applies the **`adversarial-review` skill's Bug-Class Checklist** as
the rubric — budget checked outside the barrier, silent drops of failed
sub-results, single-consent autonomy escape-hatches, prompts that assert false
facts on a fallback path, docs that contradict the real dispatch path. (Several
classes, including silent-drop, are deliberately left to this LLM pass because a
line-level grep false-positives on them.) The `adversarial-review` checklist is
the single source for this category's heuristics; do not duplicate it here.

## Workflow

1. Review pre-scan findings from `patterns.sh` — confirm, dismiss, or adjust
   severity based on context
1. For each file in the manifest, analyze against the heuristic aspects of
   each category listed above
1. Emit findings with certainty MEDIUM (heuristic) or LOW (subjective quality)
1. For pre-scan findings that are confirmed, keep certainty HIGH (deterministic)

## Output

Findings per finding-schema.md with `skill: "check-ai-config"`.
