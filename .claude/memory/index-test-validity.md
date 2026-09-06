# Index: test validity — tautologies, blind assertions & mutation testing

<!-- Sub-index of MEMORY.md. Not a memory — no frontmatter, one line per entry. -->
<!-- rumdl-disable MD013 MD033 -->

Everything here answers one question: **does this test actually fail when the
code is wrong?** A green suite proves nothing until that is established, and
every entry below is a way a test looked green while proving nothing.

Read this before writing a regression test, before trusting a passing suite as
evidence a fix works, and before reporting a mutation round's verdict.

## The fixture doesn't exercise the change

- [Anchored regex → tautological test](anchored-regex-tautological-test.md) — a fixture the anchor never matched passes with AND without the fix (#599)
- [A prefix match is not an exact pin](prefix-match-is-not-an-exact-pin.md) — `index()==1` accepts every superset; test the EXTENDING value, not a disjoint one
- [Fixture must express the divergent case](fixture-must-express-the-divergent-case.md) — solve for the input where old and new differ; 5 green tautologies in one session
- [Gate + evidence converge → tautology](gate-and-evidence-converge-tautology.md) — one fixture both ARMS and SATISFIES the gate (#600)
- [Escaped fixture cannot self-match](escaped-fixture-cannot-self-match.md) — `console\.` on disk never matches a `console\.` pattern; passes either way (#604)
- [Config prose satisfies its own assertion](config-prose-satisfies-its-own-assertion.md) — delete the setting, the comment explaining it keeps the raw-text check green (#737)
- [A prefix arm can't detect a suffix strip](prefix-arm-cannot-detect-a-suffix-strip.md) — build the fixture on the arm that DISAGREES when the normalization is removed
- [Two lenses, two thresholds](two-lenses-two-thresholds.md) — a fixture sized for the audit lens leaves the review lens silent; both mutations survive green
- [A preserved fixture can heal](preserved-fixture-can-heal.md) — the kept repro self-healed and proved nothing; verify against what's broken NOW (#768)

## The assertion is blind to what it claims to check

- [Line scanner is blind to wrapped calls](line-scanner-blind-to-wrapped-calls.md) — a `\`-split call matches neither half; join first, then COUNT what the scanner sees
- [Phrase assertion is blind to wrapped prose](phrase-assertion-blind-to-wrapped-prose.md) — a phrase broken by a newline stops matching; normalize whitespace first
- [Absence assertion needs a leak fixture](absence-assertion-needs-a-leak-fixture.md) — `ok(!includes(X))` is green when the predicate breaks; pin teeth AND narrowness
- [Concat boundary defeats a phrase matcher](concat-boundary-defeats-phrase-matcher.md) — a phrase straddling `' + '` stops matching; a comment-anchored slice widens to the whole file
- [Prose contract anchored to prose](prose-contract-anchored-to-prose.md) — heading/sentence anchors block the extraction they should survive; use contract ids
- [Side effect invisible to the assertion](side-effect-invisible-to-the-assertion.md) — a test corrupted the live golem feed while every stdout check passed; isolate, then probe for delta 0 (#782)
- [Stale artifact makes the stub pass](stale-artifact-makes-the-stub-pass.md) — a leftover output file satisfied the check a no-output stub should have failed
- [Collect-all assertions must not throw](collect-all-test-assertions-must-not-throw.md) — bare `.field` on a missing entry masks later assertions; use `?.`

## The test never ran at all

- [Test defined but never registered](test-defined-but-never-registered.md) — no `run_test` line = never runs; guard by NAME SETS, not counts (#596)
- [Self-skipping test hides the risky branch](self-skipping-test-hides-the-risky-branch.md) — skip-if-tool-absent covers only the present arm; force absence instead (#543)
- [Shimmed PATH didn't hide the tool](false-negative-from-env-restoring-path.md) — BASH_ENV restores it; assert the absence BEFORE testing what depends on it
- [Tool-absence fixture needs a symlink farm](tool-absence-fixture-needs-a-symlink-farm.md) — a hand-listed stub PATH dies 127 at a new tool, and the no-op assertion stays green
- [Upstream guard hides the branch under test](upstream-guard-hides-the-branch-under-test.md) — arm the condition mid-run, or an earlier guard answers and the test proves nothing (#813)
- [A counter in a subshell is discarded](counter-in-subshell-is-discarded.md) — a double called via `$(...)` loses its count and repeats forever; blame the fixture before the code
- [Synthetic SCRIPT_DIR needs the new sibling](synthetic-script-dir-needs-the-new-sibling.md) — a new sourced fragment breaks shadow-dir fixtures; fix the fixture, never the assertion

## Mutation testing — proving the tests have teeth

- [Mutate after every security fixture](mutate-after-every-security-fixture.md) — 2 injection fixtures passed without the fix too (#596)
- [Mutate every RULE, not every test](mutation-round-finds-the-untested-rule.md) — the rule with 0 failures is the one the round exists to find
- [Mutation harness keyed on exit code](mutation-harness-keyed-on-exit-code.md) — ALL rules "survived" means the harness is blind; key on FAIL count, verify one by hand
- [Mutation restore is never git checkout](mutation-restore-must-not-be-git-checkout.md) — reverts to HEAD and DELETES the uncommitted fix; snapshot-copy instead
- [Untracked file survives a checkout restore](untracked-file-survives-git-checkout-restore.md) — `git checkout` leaves an untracked mutation in place; remove it explicitly
- [Crashed mutation reads as a survivor](crashed-mutation-reads-as-survivor.md) — an un-applied mutation passes green; assert the edit landed before trusting the verdict
- [Mutation anchor check fails both ways](mutation-anchor-check-fails-both-ways.md) — re-grepping the anchor lies in BOTH directions; `cmp` against the pristine copy (#936)
- [Asymmetric mutation reads as untested](asymmetric-mutation-reads-as-untested.md) — a partially-neutered predicate survives; mutate all arms, then each alone
- [A surviving mutation may be a real no-op](surviving-mutation-may-be-a-real-no-op.md) — prove unreachable-vs-untested before writing a test that cannot fail (#589) (#663)
- [A GNU host can't mutate a GNU-ism](gnu-host-cannot-mutate-a-gnu-ism.md) — reverting to the GNU spelling is a NO-OP; mutate to the other platform's outcome (#679)
