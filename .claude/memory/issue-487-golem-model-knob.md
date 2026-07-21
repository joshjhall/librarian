---
name: issue-487-golem-model-knob
description: "#487 SHIPPED PR #496 (L1): GOLEM_MODEL launch knob; review caught REAL HIGH shell-injection in the model-flag splice"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6d918ba8-345b-412b-97b7-b48ec4226971
  modified: 2026-07-21T21:01:18.228Z
---

Issue #487 (Tier-1 token-burn lever, [[token-burn-audit-2026-07-21]]) SHIPPED as
PR #496 at L1 (human-merge). Adds optional `GOLEM_MODEL` env knob: unset → no
`--model` (byte-identical launch line); set (e.g. `sonnet`) → whole golem
pipeline runs on that model. Shared `golem_model_flag()` helper in config.sh is
the single splice source for all 3 launch sites (golem-launch.sh
`launch_line`/print and the `launch` tmux string, plus worktree-new.sh hint),
covering both the next-issue and ship calls.

**REUSABLE BUG (adversarial review caught, HIGH, real):** the model fragment
lands inside a double-quoted word that tmux runs via `sh -c`. First cut spliced
`$GOLEM_MODEL` RAW → a value like `x"; touch pwned; echo "` breaks out and
executes at dispatch (verified PoC). Fix = backslash-escape the 4 chars special
in a POSIX double-quoted word, backslash FIRST, then double-quote, backtick,
dollar — NOT an allow-list (legit bracketed ids like `claude-opus-4-8[1m]` would
be rejected; brackets aren't double-quote-special so they pass untouched). Same
trusted-operator threat model as [[golem-notify-feed-cant-classify-forks]] (the
SSRF in #406), but injection into an EXECUTED command line is worse than a data
sink — I wrongly pre-dismissed it before the review returned; the review was
right.

**Test lesson:** the `print`-only tests I first wrote missed the REAL `launch`
dispatch argv (an independent 2nd splice site). Added a `run_launch_auth`-harness
test asserting `--model` reaches the tmux argv on both calls, plus an
injection-regression test (metachar value → escaped in argv, no `pwned` file).
`${v//old/new}` is bash-3.2 clean (NOT the banned `${v,,}`/`${v^^}`).

Deferred low/medium polish → #497 (worktree-hint test, quote-char print test,
README table, TRUST BOUNDARY note). Review MEDIUM "spliced unescaped" became moot
once the HIGH was fixed. See [[ship-review-diff-must-be-faithful]] — passed the
full byte-faithful diff to the pre-pr harness.
