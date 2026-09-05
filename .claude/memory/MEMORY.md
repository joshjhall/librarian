# Memory index

<!-- Root index: first-order memories inline; everything else behind a sub-index. -->
<!-- Sub-indexes are index-*.md — read one when its topic comes up. -->
<!-- rumdl-disable MD013 MD033 -->

## Sub-indexes (read on demand)

- [Runtime & tooling](index-runtime.md) — workflow.js sandbox, shell traps, lint gates, skill/agent packaging
- [Git, worktrees & releases](index-git-release.md) — cutting a release, merge/push verification, worktree isolation
- [Golem & orchestration](index-golem.md) — dispatch, gate watching, liveness signals, worktree guards
- [Review harness & scanners](index-review-audit.md) — review cost/behavior, audit scanners, coverage, autonomy

## Operator directives

- [Workflow harness is pre-authorized](workflow-harness-standing-authorization.md) — a `/workflow:` invocation IS the opt-in; run it, don't re-ask each session
- [No --no-verify: fix the lint](no-noverify-fix-the-lint.md) — never skip rumdl/typos; don't `rumdl fmt` blind; only indexes are exempt
- [Librarian runs outside containers](librarian-runs-outside-containers.md) — Mac/bare-linux/container alike; never hard-depend on the submodule
- [Never time out a human gate](never-timeout-human-gate.md) — WAIT indefinitely for the answer; never lapse and decide alone
- [Ask before choosing the issue repo](ask-before-choosing-issue-repo.md) — a cross-repo follow-up is the user's call; don't default
- [Read issue comments before planning](read-issue-comments-before-planning.md) — the approach may be DECIDED in a comment that overrides the body's framing
- [Surface follow-ups before declaring done](surface-followups-before-declaring-done.md) — list every deferred finding + a recommendation and ASK; never wait to be asked
- [L3 broker plan-gate](l3-broker-plan-gate.md) — present each plan in-session, human decides HERE; never route to a TTY
- [Orchestrate broker-then-send](orchestrate-broker-then-send.md) — orchestrator SENDS the keystroke after approval; never hand back (#280)
- [Ship then merge and prune](ship-then-merge-and-prune.md) — non-autonomous ship carries through to merge+prune once green + clean
- [Umbrella Closes vs Contributes](umbrella-issue-closes-vs-contributes.md) — one slice → "Contributes to #N" + follow-up (#243)
- [Closes trailer in squash commit](closes-trailer-in-squash-commit.md) — the squash COMMIT auto-closes even if the PR body says Contributes (#411)

## How I get things wrong (applies to every task)

- [Comments assert intent, not code](comment-asserts-intent-not-code.md) — the comment claims what the code lacks, and HIDES the defect (#542/#498)
- [An issue's symbol inventory needs re-measuring](issue-symbol-inventory-needs-remeasuring.md) — the table counts NAMES and has drifted; grep declarations, diff bodies
- [Gate header claims an unimplemented check](gate-header-claims-an-unimplemented-check.md) — grep for the enforcing code; a rule written before it was testable stays prose
- [Detector needs a certainty tier](detector-needs-a-certainty-tier.md) — measure the idiom's hit rate before implementing; 723 FPs vs 2 TPs is "not at this tier"
- [Corpus filter silently disables detectors](corpus-filter-silently-disables-detectors.md) — a `**/*.md` filter makes .json/.sh detectors report clean BY CONSTRUCTION; grep their gating, measure both corpora
- [An issue's stated cause can be false](issue-cause-may-be-falsified-by-measurement.md) — A/B the SUGGESTED fix; a no-op fix means the diagnosis is wrong (#766)
- [Size the effect from the right quantity](size-the-effect-from-the-right-quantity.md) — bytes emitted vs the RECORD that accrues; flips "too small to see" into "a large effect is missing"
- [Measured cause may invert the remedy](measured-cause-may-invert-the-remedy.md) — a real total hides a billing split; check the premise's countable claims first (#787)
- [Deferred work may be doable now](deferred-work-may-be-doable-now.md) — "wait for Phase N" is an estimate; probe the blocker before accepting it
- [Strictness-first failures are in the checker](strictness-first-fails-in-the-checker.md) — a finer gate's first findings are its own parser bugs; never edit the subject to go green
- [Harden one knob, grep siblings](harden-one-knob-grep-every-sibling.md) — recurring class (#487/#489/#493): fix one site, sibling stays exposed
- [Required param beats optional default](required-param-beats-optional-default.md) — a smarter default preserves the footgun; require it, and test the omitted AND wrong-value paths
- [Third instance means fix the shape](third-instance-means-fix-the-shape.md) — 3 review cycles found 3 of 35; measure the class, re-key the structure, table-drive the test
- [Survey scoped to a glob misses a plugin](survey-scoped-to-a-glob-misses-a-plugin.md) — grep the defective LINE across plugins/; a `check-*` survey missed four `dev-core` twins
- [Structural gate where fixtures don't scale](structural-gate-where-fixtures-dont-scale.md) — per-arm × per-site defects need a source-reading gate; narrow the rule, key exemptions off the twin, mutate the vacuity guards
- [Sync script clobbers a nested region](sync-script-clobbers-nested-region.md) — a wholesale region copy deletes the INNER region's sentinels; sync only after resolving
- [Redirect order leaks the diagnostic](redirect-order-leaks-the-diagnostic.md) — `>>"$f" 2>/dev/null` still prints; absorbed failure, unabsorbed noise
- [Execute the workflow step, don't grep it](execute-the-workflow-step-dont-grep-it.md) — a `run:` block's regressions are re-orderings every grep survives
- [Scope-drift check before first commit](scope-drift-check-before-first-commit.md) — `git status` before staging, not `git diff` after (#542/#498)
- [Anchored regex → tautological test](anchored-regex-tautological-test.md) — a fixture the anchor never matched passes with AND without the fix (#599)
- [A prefix match is not an exact pin](prefix-match-is-not-an-exact-pin.md) — `index()==1` accepts every superset; test the EXTENDING value, not a disjoint one
- [Line scanner is blind to wrapped calls](line-scanner-blind-to-wrapped-calls.md) — a `\`-split call matches neither half; join first, then COUNT what the scanner sees
- [Absence assertion needs a leak fixture](absence-assertion-needs-a-leak-fixture.md) — `ok(!includes(X))` is green when the predicate breaks; pin teeth AND narrowness
- [Concat boundary defeats a phrase matcher](concat-boundary-defeats-phrase-matcher.md) — a phrase straddling `' + '` stops matching; and a comment-anchored slice silently widens to the whole file
- [Fixture must express the divergent case](fixture-must-express-the-divergent-case.md) — solve for the input where old and new differ; 5 green tautologies in one session
- [Gate + evidence converge → tautology](gate-and-evidence-converge-tautology.md) — one fixture both ARMS and SATISFIES the gate (#600)
- [A fix reintroduces its own failure](fix-reintroduces-its-own-failure.md) — the snapshot/trap/rename a silent-loss fix adds is where the loss reappears
- [Tolerating a failure still needs the order right](tolerating-a-failure-still-needs-the-order-right.md) — a partial op already destroyed state before failing; mutate the message-only fix (#834)
- [Moving a check drops its freshness](moving-a-check-drops-its-freshness.md) — the old placement bought proximity to the mutation; check in BOTH places (#813)
- [Upstream guard hides the branch under test](upstream-guard-hides-the-branch-under-test.md) — arm the condition mid-run, or an earlier guard answers and the test proves nothing (#813)
- [Prose contract anchored to prose](prose-contract-anchored-to-prose.md) — heading/sentence anchors block the extraction they should survive; use contract ids
- [Escaped fixture cannot self-match](escaped-fixture-cannot-self-match.md) — `console\.` on disk never matches a `console\.` pattern; passes either way (#604)
- [Config prose satisfies its own assertion](config-prose-satisfies-its-own-assertion.md) — delete the setting, the comment explaining it keeps the raw-text check green (#737)
- [A backticked token becomes a category](backticked-token-becomes-a-category.md) — contract.md scrapes EVERY `kebab-word` as a declared category; keep language names bare
- [End-marker indent over-grows the region](end-marker-indent-overgrows-the-region.md) — a moved START delimiter errors loud; a moved END one silently swallows what follows (#737)
- [Measure a suppression before keeping it](measure-suppression-before-keeping-it.md) — neuter the predicate and diff; a guard can buy 0 rows and cost a false negative (#604)
- [An exemption is a runtime claim — measure it](exemption-is-a-runtime-claim-measure-it.md) — ask which ACTOR runs it; a ratchet needs a floor too; 3 asserted boundaries wrong in one change
- [Stale artifact makes the stub pass](stale-artifact-makes-the-stub-pass.md) — a leftover output file satisfied the check a no-output stub should have failed; delete it and re-run
- [Side effect invisible to the assertion](side-effect-invisible-to-the-assertion.md) — a test corrupted the live golem feed while every stdout check passed; isolate, then probe for delta 0 (#782)
- [Diff the render before and after](render-diff-before-and-after-an-extraction.md) — a green suite pins only what someone asserted; capture whole output, every mode
- [split-verify proves the split](split-verify-proves-the-split.md) — tests can't show nothing was DROPPED; run it on every extraction, before the reviewer asks
- [Split entry point drops the reporter](split-entry-point-drops-the-reporter.md) — rebuilt from run_test lines, it loses generate_report: FAILs while exiting 0 (#899)
- [Synthetic SCRIPT_DIR needs the new sibling](synthetic-script-dir-needs-the-new-sibling.md) — a new sourced fragment breaks shadow-dir fixtures; fix the fixture, never the assertion
- [Reproduce outside the tool first](reproduce-outside-the-tool-first.md) — curl before instrumenting; A/B your own capture; a constant duration is a timeout, not congestion
- [Local pass + CI hang = unbounded wait](local-pass-remote-hang-is-a-timeout-gap.md) — a listen()ing squatter makes connect SUCCEED then block; bound every probe, check the BODY not the connect
- [A counter in a subshell is discarded](counter-in-subshell-is-discarded.md) — a double called via `$(...)` loses its count and repeats forever; blame the fixture before the code
- [A preserved fixture can heal](preserved-fixture-can-heal.md) — the kept repro self-healed and proved nothing; capture evidence now, verify against what's broken NOW (#768)
- [A hanging push is the pre-push suite](push-hang-is-the-prepush-suite.md) — 461s of gates before any bytes move; fetches stay instant. Budget 10 min, never --no-verify
- [Pre-push already runs the suite](prepush-hook-already-runs-the-suite.md) — don't run `run-all.sh`/`just lint` by hand first; run the targeted gate and budget the push
- [Scratch file under memory fails the push](scratch-file-under-memory-fails-the-push.md) — rumdl lints `.claude/memory/` ignoring gitignore; keep scratch prose in `/tmp/`
- [Self-skipping test hides the risky branch](self-skipping-test-hides-the-risky-branch.md) — skip-if-tool-absent covers only the present arm; force absence instead (#543)
- [Shimmed PATH didn't hide the tool](false-negative-from-env-restoring-path.md) — BASH_ENV restores it; assert the absence BEFORE testing what depends on it
- [Tool-absence fixture needs a symlink farm](tool-absence-fixture-needs-a-symlink-farm.md) — a hand-listed stub PATH dies 127 at a new tool each time, and the no-op assertion stays green
- [A prefix arm can't detect a suffix strip](prefix-arm-cannot-detect-a-suffix-strip.md) — build the fixture on the arm that DISAGREES when the normalization is removed
- [Explicit path still honors gitignore](explicit-path-still-honors-gitignore.md) — a DIRECTORY arg re-applies .gitignore; only a FILE is exempt (#578)
- [Expand before you scope a path](path-guard-must-expand-before-scoping.md) — unexpanded `~` → nonexistent path → fail-open → silent bypass; same target must decide alike in every spelling (#662)
- [Mutate after every security fixture](mutate-after-every-security-fixture.md) — 2 injection fixtures passed without the fix too (#596)
- [Mutate every RULE, not every test](mutation-round-finds-the-untested-rule.md) — the rule with 0 failures is the one the round exists to find
- [Mutation harness keyed on exit code](mutation-harness-keyed-on-exit-code.md) — ALL rules "survived" means the harness is blind; key on FAIL count, verify one by hand
- [Mutation restore is never git checkout](mutation-restore-must-not-be-git-checkout.md) — reverts to HEAD and DELETES the uncommitted fix; snapshot-copy instead
- [Asymmetric mutation reads as untested](asymmetric-mutation-reads-as-untested.md) — a partially-neutered predicate survives; mutate all arms, then each alone
- [Two lenses, two thresholds](two-lenses-two-thresholds.md) — a fixture sized for the audit lens leaves the review lens silent; both mutations survive green
- [A surviving mutation may be a real no-op](surviving-mutation-may-be-a-real-no-op.md) — prove unreachable-vs-untested before writing a test that cannot fail (#589) (#663)
- [A GNU host can't mutate a GNU-ism](gnu-host-cannot-mutate-a-gnu-ism.md) — reverting to the GNU spelling is a NO-OP; mutate to the other platform's outcome (#679)
- [Parity gate hides a shared defect](parity-gate-hides-shared-defect.md) — both impls wrong the same way passes green; same-output ≠ same-intent (#684)
- [Whole-repo diff is bounded by repo content](whole-repo-diff-bounded-by-repo-content.md) — absent input shapes read as parity; grep the shape, 0 files = silent gate (#836)
- [The correct copy is the one under test](the-correct-copy-is-the-one-under-test.md) — N unpinned copies, and the fixture calls the RIGHT one; grep the test corpus by PATH (#836)
- [Pinned behavior may be a bug report](pinned-behavior-may-be-a-bug-report.md) — "recorded, not asserted-as-desirable" is a deferred defect; fix the row, comment, and every runtime together
- [Test defined but never registered](test-defined-but-never-registered.md) — no `run_test` line = never runs; guard by NAME SETS, not counts (#596)
- [Collect-all assertions must not throw](collect-all-test-assertions-must-not-throw.md) — bare `.field` on a missing entry masks later assertions; use `?.`
- [blocking==[] is not "nothing to fix"](blocking-empty-is-not-nothing-to-fix.md) — the DEFERRABLE bucket held a real defect twice (#544, #549)
- [Verify-then-refetch is not verified](verify-then-refetch-is-not-verified.md) — re-resolving by name installs unaudited bytes; install the verified path
- [stop/C6-duplicate can hold a live defect](c6-duplicate-stop-can-hold-a-live-defect.md) — a stop verdict on a cycle that ALSO blocked leaves the fix unreviewed (#613)

## This repo's conventions

- [Conform scope enum](conform-scope-enum.md) — `fix(review):` is rejected; generic skill scopes ≠ this repo's enum
- [Release process](release-process.md) — how to cut a repo-level vX.Y.Z release; what containers#608's LIBRARIAN_REF pins to
- [Two-runtime model](two-runtime-model.md) — workflow.js is sandboxed (no shell/fs); only Bash-tool subagents reach host tools
- [Harness format is neither module nor script](harness-format-is-neither-module-nor-script.md) — workflow.js can never import; no bundler emits its format (#712)
- [Auto-mode blocks self-merge](auto-mode-blocks-self-merge.md) — `gh pr merge` denied as self-authored; a human go-ahead does NOT clear it — retry once, then hand over
- [Verify before reporting an action blocked](verify-blocked-action-before-reporting-it-blocked.md) — the denial may be on the VERIFY step; the merge had already landed (#865)
- [Read access is not write access](read-access-is-not-write-access.md) — a 200 on `gh api repos/...` does not mean `gh issue create` works; probe the real verb
- [Edits landed in main not worktree](edits-landed-in-main-not-worktree.md) — main-checkout abs paths from a worktree land in MAIN

## Conventions for this directory

One memory per file, named after the **lesson** — never after an issue number. If
the name needs an issue number to make sense, it is a session note, not a durable
memory: put the reusable sentence in a lesson-named file and let git history hold
the rest. When an issue closes, its memory either graduates to a lesson or goes.

Each entry appears in exactly one index. A sub-index that outgrows a screen splits
by topic; this root file stays selective — it is loaded every session, so an entry
earns its place here only by applying across tasks.

A memory whose content **time can falsify** — a version pin, a "latest" claim, an
open-issue status, a measured baseline — carries three optional `metadata:` keys
(borrowed from OKF, see #631):

```yaml
status: stable          # draft | stable | deprecated
stale_after: 2026-10-31 # stale once today >= this date
stale_check: "what specifically rots, and how to re-derive it"
```

`stale_check` matters more than the date: it names the sentence to re-verify, so
a stale memory gets that one line refreshed instead of being distrusted whole. A
durable lesson needs none of this — being old is not being wrong. Prefer writing
the fact so it cannot rot at all (say how to look the version up, don't paste it).
