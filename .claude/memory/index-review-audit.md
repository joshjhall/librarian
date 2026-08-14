# Index: review harness, cost & the audit scanners

<!-- Sub-index of MEMORY.md. Not a memory — no frontmatter, one line per entry. -->
<!-- rumdl-disable MD013 MD033 -->

## Review harness behavior & cost

- [Cap-stop is not convergence](cap-stop-is-not-convergence.md) — `stop`/`C1-cap` with a `capped_over` is a BUDGET artifact; re-run the predicate uncapped before merging
- [The review fix is the riskiest code](review-fix-is-the-riskiest-code.md) — 2 of 5 blocking defects on #673 were INTRODUCED by the prior cycle's fix
- [Ship review diff must be faithful](ship-review-diff-must-be-faithful.md) — the `diff` arg IS the bytes reviewers read; capture verbatim (#267)
- [Classify tool calls before optimizing](classify-tool-calls-before-optimizing.md) — tokens say WHICH agent, only the call log says WHY
- [Review cost BASELINE 2026-07-28](review-cost-baseline-2026-07-28.md) — frozen pre-change numbers; compare "after" against THIS
- [Review cost AFTER 2026-07-28](review-cost-after-2026-07-28.md) — per-cycle 173k/281k/207k → 34k/9k; recall UNPROVEN at n=2
- [Token-burn audit 2026-07-21](token-burn-audit-2026-07-21.md) — 4-axis audit → #487-#495; biggest lever = no --model dial
- [#553 review token ceiling](issue-553-review-token-ceiling.md) — budget gates are DEAD CODE without a runtime turn directive
- [#580 disposition rule list](issue-580-disposition-rule-list.md) — prose policy was unsatisfiable (1/67); split `nature` from `dispositionOf`
- [#256 cache-stability pass](issue-256-cache-stability.md) — stableStringify, instructions-first/volatile-last, helpers module-scope
- [#426 harness rm -rf](issue-426-harness-rm-rf.md) — CRITICAL: review subagents could rm -rf the LIVE tree; origin-lock + bash-guard
- [#494 checklist relocation](issue-494-checklist-relocation.md) — checklists .md→workflow.js; issue premise was WRONG; glob missed FLAT agents
- [#491 fable-tail merge](issue-491-fable-tail-merge.md) — rescore+classify → one fresh-judge pass; halves fable tail/cycle
- [#490 verify collapse](issue-490-verify-collapse.md) — per-domain fable verify O(domains)→O(1); missing tailAgent wrap
- [#492 re-review narrowing](issue-492-review-narrowing.md) — narrow to the fix delta, BUT prior-blocking dims re-confirm on the FULL diff
- [#495 prose split](issue-495-prose-split.md) — always-loaded → on-demand; the #409 guard greps for a literal `before <space>`
- [ship-issue rename rationale](ship-issue-rename-rationale.md) — named for the `nex` autocomplete collision; don't rename back
- [#390 ship CI-hang dead-end](issue-390-ship-ci-hang-deadend.md) — dead-ended at merge on the run-all.sh CI hang; resume after #442

## Scanners & pre-scan tools

- [#471/#472 agnix config trust](issue-471-472-agnix-config-trust.md) — never read the audited repo's config; `--config` is GLOBAL
- [#470 agnix dedup hardening](issue-470-agnix-dedup-hardening.md) — severity→certainty sent EVERY row down the HIGH fast path
- [#399 agnix SARIF CI gate](issue-399-agnix-sarif-ci.md) — separate workflow; validate `jq -e .runs` before upload
- [#402 precedence dedup](issue-402-precedence-dedup.md) — match PER UNDERLYING ISSUE, not line/category
- [#435 check-lifecycle scanner](issue-435-check-lifecycle.md) — how to add a check-* domain; MEDIUM-certainty pre-scan
- [check-docs-staleness colon parity](check-docs-staleness-ifs-colon-parity.md) — a shim cloned the bug into 7 ports, so parity was green on wrong output
- [check-ai-config bloat scan](check-ai-config-bloat-scan.md) — run the scanner locally (path-list arg); per-file-type thresholds
- [Codebase-audit prescan location](codebase-audit-prescan-location.md) — Step 2.5 prose in orchestration-protocol, checker owns execution
- [pre-review-gates needs filelist](pre-review-gates-needs-filelist.md) — takes changed files as positional args; bare call errors
- [pre-review-gates project root](pre-review-gates-project-root.md) — resolves via git rev-parse; tests need a GIT_*-scrubbed sandbox
- [Prescan bash↔python equivalence](prescan-bash-python-equivalence.md) — truncation is CHARACTER-based; a non-UTF-8 locale fakes a divergence
- [#503 large-file decompose](issue-503-large-file-decompose.md) — file-length is a Pass-2 LLM lens; workflow.js can't split (#90/#91)

## Coverage

- [Coverage: two surfaces](coverage-two-surfaces.md) — the Codecov number comes from coverage-python.sh's corpus, not behavioral gates
- [Bash line coverage is a category error](bash-coverage-category-error.md) — meaningless for grep pipelines; target python + mjs
- [mjs coverage c8 excludes tests](mjs-coverage-c8-excludes-tests.md) — covering tests/*.mjs needs an --exclude override (#186)
- [Source-detector gate (#348 A)](source-detector-gate.md) — corpus drove 3 ports to 100%; fixed a private-detection bug
- [Loop-detector gate (#348 B)](loop-detector-gate.md) — #384 drove 6 dev-core loop-*/drift ports to 100%

## Pipeline & autonomy

- [autonomy-resolver script](autonomy-resolver-script.md) — the single source of truth for L1-L4 gate disposition (#190)
- [Deprecated autonomy flags removed](deprecated-autonomy-flags-removed.md) — `--level N` is the sole dial; resolver EMITS plan_gated/perm_mode
- [Autonomy vs plan-gate flags](autonomy-vs-plangate-flags.md) — orthogonal; 3 unrelated `--auto` spellings never to rename
- [Read issue comments not just body](next-issue-read-issue-comments.md) — `--json body` omits comments; fetch --comments in Phase 2
- [#400 cross-repo coordination](issue-400-cross-repo-coordination.md) — real fix owned by containers#769; Closes-vs-unmet-AC catch
