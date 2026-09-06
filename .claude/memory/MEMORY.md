# Memory index

<!-- Root index: first-order memories inline; everything else behind a sub-index. -->
<!-- Sub-indexes are index-*.md — read one when its topic comes up. -->
<!-- rumdl-disable MD013 MD033 -->

## Sub-indexes (read on demand)

- [Runtime & tooling](index-runtime.md) — workflow.js sandbox, shell traps, lint gates, skill/agent packaging
- [Git, worktrees & releases](index-git-release.md) — cutting a release, merge/push verification, worktree isolation
- [Golem & orchestration](index-golem.md) — dispatch, gate watching, liveness signals, worktree guards
- [Review harness & scanners](index-review-audit.md) — review cost/behavior, audit scanners, coverage, autonomy
- [Test validity](index-test-validity.md) — **read before writing a regression test or trusting a green suite**: tautological fixtures, blind assertions, tests that never ran, mutation testing

## Operator directives

- [Workflow harness is pre-authorized](workflow-harness-standing-authorization.md) — a `/workflow:` invocation IS the opt-in; run it, don't re-ask each session
- [No --no-verify: fix the lint](no-noverify-fix-the-lint.md) — never skip rumdl/typos; don't `rumdl fmt` blind; only indexes are exempt
- [Librarian runs outside containers](librarian-runs-outside-containers.md) — Mac/bare-linux/container alike; never hard-depend on the submodule
- [Never time out a human gate](never-timeout-human-gate.md) — WAIT indefinitely for the answer; never lapse and decide alone
- [Ask before choosing the issue repo](ask-before-choosing-issue-repo.md) — a cross-repo follow-up is the user's call; don't default
- [Surface follow-ups before declaring done](surface-followups-before-declaring-done.md) — list every deferred finding + a recommendation and ASK; never wait to be asked
- [L3 broker plan-gate](l3-broker-plan-gate.md) — present each plan in-session, human decides HERE; never route to a TTY
- [Orchestrate broker-then-send](orchestrate-broker-then-send.md) — orchestrator SENDS the keystroke after approval; never hand back (#280)
- [Ship then merge and prune](ship-then-merge-and-prune.md) — non-autonomous ship carries through to merge+prune once green + clean
- [Umbrella Closes vs Contributes](umbrella-issue-closes-vs-contributes.md) — one slice → "Contributes to #N" + follow-up (#243)
- [Closes trailer in squash commit](closes-trailer-in-squash-commit.md) — the squash COMMIT auto-closes even if the PR body says Contributes (#411)
- [Closing keyword fires from prose](closing-keyword-fires-from-prose.md) — "auto-close #N" in a sentence EXPLAINING the trailer closed the issue; verify state AFTER merge (#936)

## How I get things wrong (applies to every task)

- [Comments assert intent, not code](comment-asserts-intent-not-code.md) — the comment claims what the code lacks, and HIDES the defect (#542/#498)
- [A comment can assert a SAFETY property](comment-asserts-a-safety-property.md) — "safe because the twin does Z" is a testable claim about the twin; measure it or it pre-marks the gap as safe
- [An issue's symbol inventory needs re-measuring](issue-symbol-inventory-needs-remeasuring.md) — the table counts NAMES and has drifted; grep declarations, diff bodies
- [Gate header claims an unimplemented check](gate-header-claims-an-unimplemented-check.md) — grep for the enforcing code; a rule written before it was testable stays prose
- [Detector needs a certainty tier](detector-needs-a-certainty-tier.md) — measure the idiom's hit rate before implementing; 723 FPs vs 2 TPs is "not at this tier"
- [An issue's stated cause can be false](issue-cause-may-be-falsified-by-measurement.md) — A/B the SUGGESTED fix; a no-op fix means the diagnosis is wrong (#766)
- [An issue's premise may undercount defects](issue-premise-may-undercount-defects.md) — run the issue's OWN repro; if removing the named cause still fails, there are two
- [Size the effect from the right quantity](size-the-effect-from-the-right-quantity.md) — bytes emitted vs the RECORD that accrues; flips "too small to see" into "a large effect is missing"
- [Measured cause may invert the remedy](measured-cause-may-invert-the-remedy.md) — a real total hides a billing split; check the premise's countable claims first (#787)
- [Deferred work may be doable now](deferred-work-may-be-doable-now.md) — "wait for Phase N" is an estimate; probe the blocker before accepting it
- [Strictness-first failures are in the checker](strictness-first-fails-in-the-checker.md) — a finer gate's first findings are its own parser bugs; never edit the subject to go green
- [Harden one knob, grep siblings](harden-one-knob-grep-every-sibling.md) — recurring class (#487/#489/#493): fix one site, sibling stays exposed
- [Required param beats optional default](required-param-beats-optional-default.md) — a smarter default preserves the footgun; require it, and test the omitted AND wrong-value paths
- [Third instance means fix the shape](third-instance-means-fix-the-shape.md) — 3 review cycles found 3 of 35; measure the class, re-key the structure, table-drive the test
- [Survey scoped to a glob misses a plugin](survey-scoped-to-a-glob-misses-a-plugin.md) — grep the defective LINE across plugins/; a `check-*` survey missed four `dev-core` twins
- [New routing label needs every consumer](new-routing-label-needs-every-consumer.md) — a row keyed on a label the classifier never emits routes NOTHING; the generated prompt is what runs
- [Structural gate where fixtures don't scale](structural-gate-where-fixtures-dont-scale.md) — per-arm × per-site defects need a source-reading gate; narrow the rule, key exemptions off the twin, mutate the vacuity guards
- [Sync script clobbers a nested region](sync-script-clobbers-nested-region.md) — a wholesale region copy deletes the INNER region's sentinels; sync only after resolving
- [Redirect order leaks the diagnostic](redirect-order-leaks-the-diagnostic.md) — `>>"$f" 2>/dev/null` still prints; absorbed failure, unabsorbed noise
- [grep -q under pipefail inverts a match](grep-q-under-pipefail-inverts-a-match.md) — SIGPIPE makes a SUCCESSFUL match report FAILURE, but only past the 64KB pipe buffer (#928)
- [A combined label call partially applies](combined-label-call-partially-applies.md) — gh applies the REMOVE then fails the add; "failed" leaves NO label, not the old one (#921)
- [Background exit code is the wrapper's](background-task-exit-code-is-the-wrappers.md) — a task-notification's "exit code 0" hid a red suite; read the log's own verdict (#921)
- [Execute the workflow step, don't grep it](execute-the-workflow-step-dont-grep-it.md) — a `run:` block's regressions are re-orderings every grep survives
- [Scope-drift check before first commit](scope-drift-check-before-first-commit.md) — `git status` before staging, not `git diff` after (#542/#498)
- [A fix reintroduces its own failure](fix-reintroduces-its-own-failure.md) — the snapshot/trap/rename a silent-loss fix adds is where the loss reappears
- [Tolerating a failure still needs the order right](tolerating-a-failure-still-needs-the-order-right.md) — a partial op already destroyed state before failing; mutate the message-only fix (#834)
- [Moving a check drops its freshness](moving-a-check-drops-its-freshness.md) — the old placement bought proximity to the mutation; check in BOTH places (#813)
- [A backticked token becomes a category](backticked-token-becomes-a-category.md) — contract.md scrapes EVERY `kebab-word` as a declared category; keep language names bare
- [End-marker indent over-grows the region](end-marker-indent-overgrows-the-region.md) — a moved START delimiter errors loud; a moved END one silently swallows what follows (#737)
- [Defeating a linter is not satisfying it](defeating-a-linter-is-not-satisfying-it.md) — use the gate's documented exemption marker; a regex-dodging spelling leaves no trace and breaks silently
- [Measure a suppression before keeping it](measure-suppression-before-keeping-it.md) — neuter the predicate and diff; a guard can buy 0 rows and cost a false negative (#604)
- [An exemption is a runtime claim — measure it](exemption-is-a-runtime-claim-measure-it.md) — ask which ACTOR runs it; a ratchet needs a floor too; 3 asserted boundaries wrong in one change
- [Diff the render before and after](render-diff-before-and-after-an-extraction.md) — a green suite pins only what someone asserted; capture whole output, every mode
- [split-verify proves the split](split-verify-proves-the-split.md) — tests can't show nothing was DROPPED; run it on every extraction, before the reviewer asks
- [Split entry point drops the reporter](split-entry-point-drops-the-reporter.md) — rebuilt from run_test lines, it loses generate_report: FAILs while exiting 0 (#899)
- [Reproduce outside the tool first](reproduce-outside-the-tool-first.md) — curl before instrumenting; A/B your own capture; a constant duration is a timeout, not congestion
- [Local pass + CI hang = unbounded wait](local-pass-remote-hang-is-a-timeout-gap.md) — a listen()ing squatter makes connect SUCCEED then block; bound every probe, check the BODY not the connect
- [Slow under load is not wedged](slow-under-load-is-not-wedged.md) — check for an advancing child + real memory pressure before calling a process stranded
- [Confirm PID ownership before killing](confirm-pid-ownership-before-killing.md) — never `pkill -f` a shared script name; a PID may be a peer golem's
- [A hanging push is the pre-push suite](push-hang-is-the-prepush-suite.md) — 461s of gates before any bytes move; fetches stay instant. Budget 10 min, never --no-verify
- [Pre-push already runs the suite](prepush-hook-already-runs-the-suite.md) — don't run `run-all.sh`/`just lint` by hand first; run the targeted gate and budget the push
- [Scratch file under memory fails the push](scratch-file-under-memory-fails-the-push.md) — rumdl lints `.claude/memory/` ignoring gitignore; keep scratch prose OUT, but not at a shared `/tmp` name a peer golem clobbers
- [Read the memory body, not just the index](read-the-memory-body-not-just-the-index.md) — the index line is a pointer; the trigger and the exception live in the body (#936)
- [Explicit path still honors gitignore](explicit-path-still-honors-gitignore.md) — a DIRECTORY arg re-applies .gitignore; only a FILE is exempt (#578)
- [Expand before you scope a path](path-guard-must-expand-before-scoping.md) — unexpanded `~` → nonexistent path → fail-open → silent bypass; same target must decide alike in every spelling (#662)
- [BSD wc pads its count](bsd-wc-pads-its-count.md) — an interpolated count corrupts a regex interval or evidence string; arithmetic is fine (#932)
- [Derived key hides the gate it guards](derived-key-hides-the-gate-it-guards.md) — `ext` is of the PATH, the gate is about the NAME; a dotted DIRECTORY diverges and parity is blind
- [Parity gate hides a shared defect](parity-gate-hides-shared-defect.md) — both impls wrong the same way passes green; same-output ≠ same-intent (#684)
- [Parity is blind to exit-code divergence](parity-blind-to-exit-code-divergence.md) — a refusal path emits nothing in BOTH impls; assert the exit code, not just stdout (#816)
- [A byte tool can't strip multi-byte](byte-tool-cannot-strip-multibyte.md) — `tr` passes U+202E that Python's isprintable() strips; enumerate literal UTF-8, never `\xNN` (#816)
- [A config value is not a pattern](config-value-is-not-a-pattern.md) — `notes[1].md` never matches itself via fnmatch/case; try literal equality FIRST (#669)
- [Whole-repo diff is bounded by repo content](whole-repo-diff-bounded-by-repo-content.md) — absent input shapes read as parity; grep the shape, 0 files = silent gate (#836)
- [The correct copy is the one under test](the-correct-copy-is-the-one-under-test.md) — N unpinned copies, and the fixture calls the RIGHT one; grep the test corpus by PATH (#836)
- [Pinned behavior may be a bug report](pinned-behavior-may-be-a-bug-report.md) — "recorded, not asserted-as-desirable" is a deferred defect; fix the row, comment, and every runtime together
- [blocking==[] is not "nothing to fix"](blocking-empty-is-not-nothing-to-fix.md) — the DEFERRABLE bucket held a real defect twice (#544, #549)
- [One row per line must name every hit](one-row-per-line-must-name-every-hit.md) — collapsing N findings re-creates the suppression bug; assert the SECOND hit in the evidence
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
