# agnix pre-scan — the optional second source for `check-ai-config`

Companion to `plugins/review-audit/agents/checker.md` § *Step 3a*. Load this when
the skill being pre-scanned is `check-ai-config` — it is the only skill shipping
`agnix-normalize.*`, so every other skill's pre-scan ends at the `patterns.sh`
step and never needs this file.

Extracted from `checker.md` in #503: the block is call-specific (one skill of
many) but `checker.md` is loaded as the system prompt on *every* dispatch, so
carrying it there charged every invocation for prose almost none of them use —
the same load-frequency argument #494 applied to `code-reviewer.md`.

## Contract markers

The `<!-- contract: ... -->` markers below are load-bearing: they are how
`tests/validate-agnix-checker-wiring.sh` and `tests/validate-audit-trust-gate.sh`
address these guarantees. Anchoring on an id rather than on a heading pair is
what let this prose move out of `checker.md` without touching an assertion —
and what lets it be reworded or re-headed freely. Deleting or renaming a marker
breaks the gate loudly (never vacuously); see `extract_contract` in
`tests/lib/harness.sh` for the full rationale.

## Step 3a — agnix as an optional second pre-scan source

<!-- contract: agnix-prescan-framing -->
`check-ai-config` ships a **second** deterministic pre-scan source alongside its
`patterns.sh`: `agnix-normalize.sh`, which runs the external
[agnix](https://github.com/agent-sh/agnix) linter and maps its `--format json`
`CC-*` findings into the **same TSV contract**
(`<file>\t<line>\t<category>\t<evidence>\t<certainty>`). It is the boundary
object of the agnix integration spine (ADR
`plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md`, § 2 & 4;
issues #397 → #401). agnix is an **optional enrichment over an always-present
floor** — `patterns.sh` is that floor and always runs; agnix only *adds* rows
when its binary is present. This sub-step applies **only** to the
`check-ai-config` skill (the only skill shipping `agnix-normalize.*`); every
other skill's pre-scan ends at the `patterns.sh` step above.

When `check-ai-config` survived the Step 2 integrity gate, after its
`patterns.sh` run:

<!-- contract: agnix-prescan-invocation -->
1. **Log on discovery** (same convention as `patterns.sh`):
   `[prescan] agnix enrichment <resolved-path> (source: <source>)`.
1. **Run the normalizer over the same manifest tempfile**, invoking the runtime
   shim (it exec's the Python primary when `python3>=3.11` is present, else the
   bash fallback — no branching needed here):
   `bash <check-ai-config-dir>/agnix-normalize.sh <tempfile>`
<!-- contract: agnix-trust-posture -->
1. **Trust posture — the audited repo's `.agnix.toml` is untrusted input, and
   it is an *enforced* gate, not advice** (ADR § 5). agnix reads *the
   repo-under-audit's* `.agnix.toml` (`disabled_rules`, `[[overrides]]`,
   `severity`), which a hostile repo can ship to silence findings (e.g. disable
   `CC-HK-009` to hide a malicious hook). Critically, when `AGNIX_CONFIG` is
   **unset** the normalizer passes **no** `--config` flag, so agnix falls through
   to its own default discovery — and that discovery **walks up from each scanned
   file's own directory**, not from the repo root. A hostile repo can therefore
   plant an `.agnix.toml` in **any** directory near the files it wants to hide;
   agnix honors it silently, and a check of the repo-root file alone would never
   see it. (Verified against agnix 0.40.0 and 0.41.0: a nested `.agnix.toml`
   disabling a rule suppressed that rule's findings, while an `.agnix.toml` in a
   *parent* of the repo was not consulted.)

   **The enforced precondition is therefore that agnix ALWAYS runs with an
   explicit `--config` naming a file the *operator or the checker* owns** — never
   on its own discovery, and **never on a config the audited repo authored**. An
   explicit `--config` suppresses the upward walk entirely (verified on both
   versions), which is the only reliable defense: enumerating every ancestor
   `.agnix.toml` would have to model agnix's search order exactly and would still
   race a file created after the check. Branch as follows, mirroring the
   skip-branch of the other three surfaces (Step 2 skill discovery, Step 2
   `audit-*` dispatch, Step 3 `patterns.sh` execution):
   - **`AGNIX_CONFIG` is already set in the environment** (an operator-controlled
     config): invoke the normalizer with it inherited — agnix uses `--config
     "$AGNIX_CONFIG"`, never the audited tree's own file.
   - **`AGNIX_CONFIG` is unset AND `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS` is not
     `1`** (exact value `1`; treat any other value, including `true`/`yes`/empty,
     as unset): **do NOT invoke the normalizer for this run** — agnix would
     otherwise silently read the untrusted repo's `.agnix.toml`. Log
     `[prescan] agnix skipped (no operator-controlled AGNIX_CONFIG; untrusted project source)`
     and fall through to the `patterns.sh`-only result exactly like the
     graceful-degrade path below (the floor stands alone; no agnix contribution
     this run).
   - **`AGNIX_CONFIG` is unset but `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1`** (the
     operator explicitly trusts this repo): invoke the normalizer, but **still
     never let agnix read a config the repo authored**. Write a
     **checker-controlled config carrying agnix's defaults** — a minimal file
     whose only required key is `tools = ["claude-code"]` — to a temporary path
     you own, **never inside the audited tree**; point `AGNIX_CONFIG` at that
     file for the invocation. Log
     `[prescan] agnix pinned to default config (untrusted project source)`.
     **Do NOT read, validate, or point agnix at the repo's own `.agnix.toml`**,
     tracked or not.

     **Why not honor a tracked `.agnix.toml`?** Because git-tracked-ness cannot
     vouch for what a config resolves to. A tracked entry may be a **symlink**
     (index mode `120000`) redirecting to any path in or out of the tree, and a
     tracked regular file may use agnix's **`extend` key** to chain to another
     config — including an untracked sibling, an absolute path, or one reached by
     `../` traversal. Both are `git ls-files --error-unmatch`-clean and both
     silently suppress findings (reproduced against 0.40.0 and 0.41.0). Chasing
     them would mean resolving symlinks, walking the whole `extend` chain, and
     re-validating each hop — with a TOCTOU race still open between the check and
     the invocation. Not reading the repo's config at all removes the entire
     class: **there is no attacker-authored input on this path to validate.**

     Because `AGNIX_CONFIG` is set on **every** branch above, agnix's per-file
     upward walk never runs, and a planted `.agnix.toml` — at the root, at any
     nested depth, symlinked, or reached via `extend` — is inert.

     This differs from the `SKILL.md` / `patterns.sh` guards, which can simply
     **skip** an untrusted artifact: skipping is not enough here, because the
     danger is not the artifact the checker reads but the one **agnix** reads
     behind it. Neutralize the input rather than declining to run.

     **Trade-off, deliberate:** a repo's own legitimate committed `.agnix.toml`
     (its intentional rule tuning) does **not** apply during an audit. An
     operator who wants a specific config honored sets `AGNIX_CONFIG` explicitly
     — the first branch above — which is the operator-controlled path by
     definition.

   This is the **same** untrusted-project-input boundary and opt-in that gate the
   project `patterns.sh` execution (Step 3), project skill discovery, and project
   `audit-*` dispatch (Step 2) — one trust decision, now a fourth surface —
   except the enforced action here is "skip agnix / use the operator config",
   never "let agnix discover the repo's own config".
<!-- contract: agnix-observe-only -->
1. **Observe-only — never autofix.** Invoke agnix in `validate` mode only. Never
   run agnix `--fix`, `--fix-safe`, or `--fix-unsafe` on this path; autofix is
   fenced off the checker path entirely (ADR § 4). The normalizer already invokes
   only `validate`; do not add any fix flag.
<!-- contract: agnix-owned-categories -->
1. **Parse the TSV rows exactly like `patterns.sh` output** and collect them as
   pre-scan findings, **tagged as agnix-sourced**. Their `category` is a mapped
   check-ai-config slug; the `CC-*` rule ID **and agnix's `rule_severity`** ride
   inside `evidence` as `[<RULE-ID>|<SEVERITY>] <message>`, while `certainty` is a
   **fixed `MEDIUM`** — every agnix row takes the Pass-2 confirmation path, never
   the `HIGH` auto-include fast path (#470). Carry the tag to Step 6, where
   it drives precedence dedup — **but only for the categories the ADR § 3
   ownership table assigns to agnix**: `agent-frontmatter` (`CC-AG-*`),
   `skill-frontmatter` (`CC-SK-*`), `hook-safety` (`CC-HK-*`), and
   `mcp-misconfiguration` (`CC-MCP-*`/`MCP-*`). The normalizer's rule→category map
   can also emit `config-inconsistency` (`CC-PL-*`) and `claude-md-drift`
   (`CC-MEM-*`), but ADR § 1/§ 3 make those **check-ai-config-exclusive** (they
   need repo/ecosystem context agnix has no model of), so a `config-inconsistency`
   or `claude-md-drift` agnix row must **not** supersede check-ai-config at Step 6
   (the dedup there matches **per underlying issue** on same-`file` +
   same owned-category, not `file:line`, so a whole-file-anchored floor finding is
   superseded without collapsing its siblings — but only for the four owned
   categories) — collect it, but it never wins the dedup.

<!-- contract: agnix-graceful-degrade -->
**Graceful degrade — absent agnix ⇒ skip its contribution.** The normalizer
**no-ops** when the agnix binary is absent (emits nothing, logs one `[skip]`
line to stderr, exits 0) and **fails loud** (exit 2) only when agnix *is* present
but ran unusably. Treat its result exactly like the `patterns.sh` failure path
above: on empty output **or** a non-zero exit, log the outcome and **continue
without agnix pre-scan results for check-ai-config** — do NOT drop the skill, and
do NOT let a missing/misbehaving agnix fail the run. **When agnix does not run,
the checker's output is identical to today's** (`patterns.sh`-only) result.
