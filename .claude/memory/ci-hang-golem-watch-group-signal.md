---
name: ci-hang-golem-watch-group-signal
description: "root cause of the multi-PR CI 15min-timeout: validate-golem-watch case-4 group-signal (kill -INT -<pgid>) escapes to run-all.sh on x86_64 CI (set -m job control unreliable headless); NOT reproducible on aarch64 dev host; fix = REMOVE case 4 (cases 2+3 cover it), #444/PR #445; diagnostic instrumentation #441/PR #442"
metadata: 
  node_type: memory
  type: project
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-07-20T05:32:22.197Z
---

<!-- rumdl-disable MD013 -->

**The CI hang that ate a session (2026-07-19/20).** PRs #433 (#397 agnix) and

# 440 (#390 Mode-3 token) both TIMED OUT the `Skill/agent quality gates` CI job at

the 15-minute ceiling — reproducibly, across runners — while main + every other
branch passed in ~2.5min. Looked #397-specific at first; operator's insight
("other PRs pass, so it's a dep specific to this branch" + "is CI a different
bash/arch?") reframed it: BOTH failing branches touch the **golem test files**,
and the common stage is `tests/validate-golem-watch.sh`.

**Root cause.** Case (4) of validate-golem-watch ("a delivered SIGINT reaches
cleanup_pane and reaps the pane worker") models a terminal Ctrl-C with a
**process-group** SIGINT: `set -m` to give the watcher its own pgid, then
`kill -INT -<pgid>`. On a **headless x86_64 ubuntu-latest** runner, `set -m` job
control is unreliable — the watcher can stay in the SUITE's process group, so
`kill -INT -<pgid>` lands on **run-all.sh itself** → the whole job wedges to the
15min kill (or, under a `timeout` wrapper, dies exit 130). NOT reproducible on the
**aarch64 linuxkit dev host** (different arch/kernel/job-control), which is why
local runs — even agnix-absent, even under the exact CI stage wrapper — always
passed in ~1m45s. The arch/env difference is the whole reason it hid.

**Why every fix squirmed (the dead-end the operator smelled).** Faithfully
delivering Ctrl-C REQUIRES a group signal, which REQUIRES process-group isolation,
which is exactly what's fragile headless. Tried `set -m` (original), `setsid`
(forks → `$!` != leader), `setsid`+leader-pidfile (kill -INT -pgid rc=1 / timing),
per-PID descendant walk (foreground `sleep` is a great-grandchild; recursion hit
the test shell). Each traded one signal-topology fragility for another.

**RESOLUTION — remove case 4 (#444 / PR #445).** golem-watch.sh binds ONE handler
to all three signals on one line: `trap cleanup_pane EXIT INT TERM`. Case (2)
already proves that handler REAPS the pane behaviourally (via the EXIT arm); case
(3) proves the spec LISTS INT+TERM (structural grep). No plausible bug fires the
shared one-line handler on EXIT but not INT, so case 4's marginal coverage is
near-zero while its cost is a test that can hang the suite it guards. Removed case
4 + its exclusive machinery (group_signal_unavailable / run_watch_int_signal /
make_stage_int / WATCH_WORKER_ALIVE). Now 5 deterministic cases, no skip, no group
signal. Structural case 3 is the authoritative INT/TERM guard. (The header comment
block itself had ALREADY documented — lines 34-40/64-69 pre-removal — that a
behavioural signal test CANNOT discriminate "dropped INT TERM" (case 3's job) and
that case 4's only distinct claim was "a delivered signal reaches cleanup at all"
— i.e. the near-zero delta was self-evident in the original prose.)

**Diagnostic tooling built (#441 / PR #442).** run-all.sh `run_stage` now prints
`[>>] <stage> :: entering at HH:MM:SS` + `[ok] <stage> (Ns)`. This is what pinned
the culprit: a timed-out-job log's LAST `[>>]` line named `golem-watch streaming
dispatcher`. GitHub PURGES timed-out/cancelled-job logs (can't read them
post-hoc) and does NOT expose a running job's step log via CLI/API — the markers
are the only way to see the last stage before a job-level kill. IMPORTANT: #442
must be MARKERS-ONLY — an earlier version wrapped each stage in `setsid timeout`
to fail-fast, but that perturbed the golem-watch group-signal topology and itself
caused exit-130; the markers alone name the culprit without touching signals. A
safe per-stage kill-budget is a deferred follow-up.

**How to apply.** (1) A run-all.sh CI timeout on a branch touching golem tests →
suspect a signal/process-group test, read the log's last `[>>]` marker. (2)
Local-passes-CI-hangs on shell signal/job-control code → check arch (aarch64 dev
vs x86_64 CI) + headless job-control BEFORE concluding "code is fine." (3) A test
that delivers a GROUP signal (`kill -INT -<pgid>`, `set -m`) is a CI-hang risk by
construction — prefer structural assertions; if behavioural, never depend on
process-group isolation working headless. See [[golem-gate-watch-host-leak]]
(sibling golem-watch/gate-watch test-isolation fix, #436) and
[[golem-watch-trap-signal-testing]] (the #359/#360 history of this exact case 4).
