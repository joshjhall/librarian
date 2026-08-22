# ADR 0001 — agnix and check-ai-config: complementary layers, not either/or

- **Status:** Accepted
- **Date:** 2026-07-18
- **Scope:** `review-audit` plugin (`check-ai-config` skill, `checker` agent)
- **Issue:** [#238](https://github.com/joshjhall/librarian/issues/238)
  (refiled from joshjhall/containers#330; R11 in the AgentSys evaluation)

> **Convention:** ADRs for the `review-audit` plugin live in this directory
> (`plugins/review-audit/docs/adr/`), four-digit-prefixed and never renumbered.
> `docs/` is inert to the plugin loader (only `skills/` and `agents/` are
> auto-discovered), so a design doc here ships with the repo without becoming a
> loadable component.

## Context

[agnix](https://github.com/agent-sh/agnix) is a Rust linter and LSP for AI
coding-assistant configuration files (CLAUDE.md, AGENTS.md, SKILL.md, agents,
hooks, plugins, MCP, settings). As of v0.40.0 it ships **437 rules across ~40
categories**, of which **53 are Claude Code-specific** (the `CC-*` namespaces).
It is already installed — best-effort — in the `containers` dev image.

`check-ai-config` is this plugin's own linter for the same artifacts. It is a
**two-stage** skill: a deterministic pre-scan (`patterns.py` primary, `patterns.sh`
bash-3.2 fallback) emitting the repo's TSV finding contract, followed by an **LLM
heuristic pass**. It implements roughly 15 deterministic checks plus subjective
analysis the pre-scan cannot express.

The predecessor evaluation (`containers/docs/evaluations/agentsys-evaluation.md`,
recommendation R11) said to *evaluate adopting agnix rules* but never decided
**how the two tools coexist**. Left unarchitected, three failure modes follow:

- **Duplicate / conflicting findings** — both tools flag the same file; worse, a
  numeric rule (line-limit, token-count) fires on both sides with *different*
  thresholds, so dedup by location alone keeps both contradictory messages.
- **Unmaintainable fork** — porting agnix's rules into `patterns.{py,sh}` means
  re-implementing a 437-rule Rust linter in the least expressive runtime we own,
  chasing agnix's release cadence forever.
- **Silent coverage regression** — retiring our own mechanical checks in favour of
  agnix drops security-relevant coverage wherever agnix is not installed, with no
  error to signal it.

This ADR fixes the ownership boundary so none of those occur.

## Decision

Adopt **complementary layers: agnix as an optional enrichment over an
always-present floor.**

### 1. check-ai-config is the portable floor

Its deterministic pre-scan remains the baseline on **every** platform. Per the
repo runtime policy it is Python-3.11-primary with a bash-3.2-clean fallback,
fails loud, and runs on host / bare-linux / container / **base macOS**. It keeps
**all** current checks — nothing is deleted by this decision. In particular it
retains:

- the **HIGH-severity mechanical checks** agnix also covers — missing frontmatter
  fields, insecure `http://` MCP URLs, destructive-command and secret-leak hook
  safety;
- the checks agnix **structurally cannot do**, because they need repo or
  ecosystem context agnix has no model of — `claude-md-drift` (resolve a
  backticked path against the document's own directory in the repo tree),
  `config-inconsistency` (the librarian `` `<plugin>:<name>` `` agent/skill
  namespace topology), and `harness-logic` (`workflow.js` harnesses — a librarian
  construct for which agnix ships zero rules);
- the entire **LLM heuristic pass** — wrong-model-for-task-complexity, whether a
  bloated file is decomposable, and the `adversarial-review` bug-class checklist.
  agnix has no LLM layer at all.

### 2. agnix is an optional enrichment that supersedes on overlap

When the agnix binary is present, its `CC-*` findings are treated as
**authoritative on the overlap set**. At the finding-merge step, when an agnix
rule and a check-ai-config finding in an agnix-owned category describe the **same
underlying issue** on the same file, the check-ai-config finding is dropped and
agnix's is kept (richer message, rule ID, autofix hint). The match is **per
issue** — keyed on same-`file` + same-category, not `file:line` (the floor
anchors its whole-file frontmatter findings at line `1`, so a line key would miss
them) and not a whole-category sweep (the floor emits multiple distinct findings
per file+category, so only the specifically-superseded one is dropped and any
sibling agnix did not report is retained). When agnix is **absent**, the
check-ai-config finding stands. (Down-scoped to precedence-only dedup in
follow-up 4, issue #402 — never deletion of the floor's checks.)

> **Update (#470).** The drop described above is no longer unconditional — it is
> now gated by two guards in `checker.md` Step 6, and agnix rows are exempt from
> the within-skill line-range merge. (1) The drop applies **only** when agnix ran
> against an operator-controlled `AGNIX_CONFIG`; under the
> `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1` opt-in agnix reads the audited repo's
> own `.agnix.toml`, so the run falls back to **keep-both** rather than letting a
> repo delete floor coverage by shipping a config file. (2) Where the drop is
> allowed, agnix's `rule_severity` must be **≥** the check-ai-config finding's
> severity (case-folded, `critical > high > medium > low`; agnix has no
> `critical` tier, so a `critical` floor finding is never superseded). An agnix
> row is also **exempt from the within-skill overlapping-line merge** — a
> near-miss the precedence rule declined to drop must not be silently *blended*
> instead. Relatedly, the TSV `certainty` column is now a fixed `MEDIUM` and
> agnix's `rule_severity` rides in the `evidence` prefix; see
> `check-ai-config/contract.md` § Emitted columns.

The dedup is keyed on **actual agnix output present in this run** — never on
"agnix is the designated owner." So it is a strict **no-op when agnix did not
run**. Same displayed coverage on both paths; no double-report on the happy path;
no hole on the absent path.

This matters because **agnix is best-effort even in the container image**. The
install is guarded and swallows failure:

```sh
# containers/lib/features/lib/dev-tools/install-binary-tools.sh:446
if command -v npm &>/dev/null; then
    if npm install -g agnix@latest 2>/dev/null; then
        log_message "✓ agnix installed successfully"
    else
        log_warning "agnix installation failed, continuing without agnix"
    fi
fi
```

A registry hiccup, an npm-less base, or a network-restricted build yields a
container with **no agnix and no error**. "container ⇒ agnix present" is false.
Retiring our floor's mechanical checks on the theory that agnix owns them would
therefore leave a missing-`model` field, an `http://` MCP URL, or an `rm -rf` in a
hook **undetected and unreported** on those surfaces — a silent HIGH-severity
regression, precisely the failure class `adversarial-review` exists to catch.
Hence **keep-both-and-dedup, not retire-and-rely.**

### 3. One owner per overlapping rule

Deduping by location is not enough when two tools disagree on a *threshold* — two
line-limit findings at line 1 with different numbers are genuinely different
messages. So each overlapping rule gets a single owner, enforced through
`.agnix.toml`:

| Concern                    | agnix rule(s)            | check-ai-config   | Owner           |
| -------------------------- | ------------------------ | ----------------- | --------------- |
| Agent frontmatter schema   | `CC-AG-*`                | agent-frontmatter | **agnix**       |
| Skill frontmatter schema   | `CC-SK-*`                | skill-frontmatter | **agnix**       |
| Dangerous hook command     | `CC-HK-009`              | hook-safety       | **agnix**       |
| Insecure MCP transport     | `MCP-*` (http)           | mcp-misconfig     | **agnix**       |
| CLAUDE.md line / token cap  | `CC-MEM-014`,`CC-MEM-009`| ai-file-bloat     | **check-decomp**|
| File bloat thresholds      | —                        | ai/doc-file-bloat | **check-decomp**|
| CLAUDE.md path drift        | —                        | claude-md-drift   | **check-ai-cfg**|
| Plugin cross-reference      | —                        | config-inconsist. | **check-ai-cfg**|
| workflow.js harness logic  | —                        | harness-logic     | **check-ai-cfg**|
| Model-fit / decomposability| —                        | LLM pass          | **check-ai-cfg**|

agnix owns the richer *schema* rules (its `CC-AG-*`/`CC-SK-*` frontmatter
validation and `CC-HK-009` are more thorough than our regex checks). The **bloat
thresholds** stay ours — they are tuned to librarian's file taxonomy and
env-overridable (`CLAUDE_MD_WARN/HIGH`, `SKILL_*`, `AGENT_*`, `DOC_*`), which
agnix's fixed `CC-MEM-014`/`CC-MEM-009` are not — so those two agnix rules are
**disabled** to prevent contradictory line-limit findings.

**Amended by #663**: the two bloat rows moved from `check-ai-config` to
`check-decomposition`, which now owns all line counting (its per-file-type
thresholds are the same table under the same env var names). The reasoning is
unchanged and in fact reinforced — this section's own argument, that two tools
emitting a line-limit finding at line 1 with different numbers are two genuinely
different messages, applies just as much between two of *our* scanners as it does
between ours and agnix. The `CC-MEM-*` bloat rules stay disabled.

### 4. Surfaces and the integration boundary object

- **Author-time inner loop → agnix LSP.** This is a genuine gap: `check-*` is
  batch-only (run by the `checker` agent), so it offers no real-time editor
  feedback. The LSP is the strongest pro-agnix argument and we adopt it *there*,
  as an addition, not a replacement of the batch floor.
- **Audit / review → check-ai-config batch**, enriched by agnix when present.
- **CI gate → `agnix --format sarif`** for native GitHub code-scanning upload;
  `--format json` feeds the checker-path normalizer (stable to parse).
- **agnix `--fix` / `--fix-safe` / `--fix-unsafe` are fenced off the checker
  path.** The `checker` agent is contractually observe-only; autofix runs only at
  author-time (LSP / manual) or a dedicated recipe, never in audit/review.

agnix speaks `github | json | sarif`; it does **not** emit the repo's TSV contract
(`file⇥line⇥category⇥evidence⇥certainty`, parity pinned by
`tests/validate-python-ports.sh`). Integration therefore flows through a
**normalizer** (follow-up 1) mapping agnix JSON → TSV, including the `CC-*` rule
ID → check-ai-config category map. The normalizer is the load-bearing boundary
object, not an afterthought, and must itself honour the runtime policy and be a
no-op-with-clear-log when the binary is absent.

### 5. Trust and versioning

- **The audited repo's `.agnix.toml` is untrusted input.** Running agnix over a
  repo under audit means agnix reads *that repo's* `.agnix.toml` —
  `disabled_rules`, `[[overrides]]`, `severity` — which a hostile repo can ship to
  silence findings (e.g. disable `CC-HK-009` to hide a malicious hook). agnix on
  the audit path must run with an **operator-controlled** config, mirroring the
  `checker`'s existing `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS` posture for
  project-provided scripts.

  > **Update (#471).** "Must run with an operator-controlled config" is now
  > enforced as **agnix always runs with an explicit `--config`, naming a file
  > the operator or the checker owns — never one the audited repo authored.**
  > Two findings drove the strengthening, both reproduced against the pinned
  > 0.40.0 and against 0.41.0 —
  >
  > 1. **Discovery is per-file, not repo-root.** With no `--config`, agnix walks
  >    up from *each scanned file's own directory*, so a planted `.agnix.toml` at
  >    any nested depth is honored and a repo-root check never sees it. An
  >    explicit `--config` suppresses the walk entirely.
  > 1. **Git-tracked-ness cannot vouch for a config's content.** A tracked entry
  >    may be a **symlink** (index mode `120000`) to any path, and a tracked
  >    regular file may use agnix's **`extend`** key to chain to an untracked,
  >    absolute, or `../`-traversed config. Both are
  >    `git ls-files --error-unmatch`-clean and both silently suppress findings.
  >
  > So under the `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1` opt-in the checker
  > pins agnix to a **checker-controlled default config** written outside the
  > audited tree, and does not read the repo's `.agnix.toml` at all. Trading the
  > repo's own rule tuning for the removal of an entire attacker-input class is
  > deliberate; an operator who wants a specific config honored sets
  > `AGNIX_CONFIG`. Step 3a of `plugins/review-audit/agents/checker.md` carries
  > the operative rule.
  >
  > Separately, both normalizers emitted `--config` *after* the `validate`
  > subcommand. It is a **global** flag, so agnix rejects that ordering
  > (`unexpected argument '--config' found`, exit 2) — the `AGNIX_CONFIG` branch
  > had never actually worked. Fixed in `agnix-normalize.{py,sh}` and pinned by
  > `tests/validate-agnix-normalize.sh`.
- **agnix is pinned, not `@latest`.** A `@latest` bump can add rules that fail a
  previously-green tree with no code change — exactly the drift the repo's
  GitHub-Action SHA-pin + dependabot discipline prevents. Pin to a specific
  version (e.g. `agnix@0.49.0`) and route bumps through dependabot's npm ecosystem.
  The install edit lives in the **`containers` submodule** (a separate repo), so
  this is a cross-repo coordination item, not an in-repo change. librarian's own
  CI workflows carry that exact pin — `ci.yml` and `code-scanning.yml`, held in
  agreement by `tests/lint-agnix-clean.sh`'s pin cross-check, which runs
  unconditionally (pure text comparison, so it fires even on a host with no
  agnix installed). That same gate's *error-count* assertions are the part with
  a floor: they skip (sentinel 77) below agnix 0.48.1, where stale parsers emit
  phantom errors. `.agnix.toml` deliberately states no version of its own
  (#734), so those two workflow pins are the single place the number lives.
  The container install edit is tracked in the
  `severity/high` companion issue **joshjhall/containers#769**, coordinated from
  librarian tracking issue #400.

## Consequences

**Positive:**

- No coverage regression on any platform; the floor is unconditional.
- No duplicate or contradictory findings — precedence dedup plus single-owner
  thresholds.
- We gain agnix's ~38 mechanical schema rules and its author-time LSP without
  taking on maintenance of a 437-rule Rust linter.
- The runtime contract (runs on base macOS, fails loud) is preserved.

**Negative / costs:**

- A normalizer must be built and kept in sync with agnix's JSON schema and rule
  IDs across agnix releases.
- Two config surfaces to keep aligned: `thresholds.yml` and `.agnix.toml`.
- A cross-repo pin change in `containers`.

## Alternatives considered

- **Wholesale-adopt agnix, retire check-ai-config.** Rejected: deletes our only
  coverage for `claude-md-drift`, `config-inconsistency`, and `harness-logic`,
  removes the entire LLM heuristic pass, and violates the runtime contract (agnix
  is a Rust binary absent on stock macOS — the platform CLAUDE.md explicitly
  names).
- **Cherry-pick-port agnix rules into `patterns.{py,sh}`.** Rejected:
  re-implements slices of a 437-rule Rust linter in bash-3.2 + Python behind the
  TSV parity harness, chasing agnix's releases forever in the least expressive
  runtime we own. The runtime policy exists so we maintain *our* differentiated
  checks in two languages — not agnix's mechanical schema rules.
- **Retire only the overlapping mechanical checks (A/F/G), rely on agnix for
  them.** Rejected as the crux of this ADR: creates a silent HIGH-severity hole
  wherever agnix is absent (bare host, base macOS, best-effort container install).
  Superseded by keep-both-and-dedup.

## Follow-ups

The concrete code changes land as separate issues; this ADR is the decision.
Dependency spine **1 → 2 → 3 → 4**, with **5** hanging off **2** and **6**
free-floating. Item 4 (the down-scope to dedup) MUST NOT precede item 3 (the
wiring), so the floor never has a window where it is trimmed but agnix is not yet
integrated.

1. **agnix → TSV normalizer** (#397, blocks all) — map `agnix --format json` to the
   TSV contract including the `CC-*` → category map; runtime-policy compliant;
   no-op + clear log when the binary is absent.
2. **`.agnix.toml` finalization** (#398, dep 1) — flesh out `disabled_rules` /
   severity / pin from the rule→category map; the stub added with this ADR seeds it.
3. **checker wiring** (#401, dep 1) — agnix as an optional *second* pre-scan source
   in `checker.md` Step 3 (absent ⇒ skip its contribution) + precedence dedup at
   the merge step.
4. **Down-scope to precedence-only dedup** (#402, dep 3) — the dedup change,
   explicitly **not** deletion of the floor's checks.
5. **CI SARIF gate** (#399, dep 2, parallel to 3/4) — `agnix --format sarif` upload
   / annotations in `.github/workflows`.
6. **Pin agnix off `@latest`** (#400 coordination; the install edit is tracked in
   the `severity/high` companion issue joshjhall/containers#769, free-floating,
   cross-repo) — in the `containers` submodule; route bumps via dependabot's npm
   ecosystem. librarian-side is coordination only (this cross-link + config pin
   already at `0.40.0`); containers#769 lands the submodule change.
