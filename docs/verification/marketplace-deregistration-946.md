# Marketplace deregistration — issue #946

Records the evidence for
[#946](https://github.com/joshjhall/librarian/issues/946)
("librarian marketplace silently deregisters mid-session"), acceptance criterion
**1** — *the mechanism that removes the registration is identified, or explicitly
recorded as not-yet-reproduced with the evidence*.

**Verdict: NOT REPRODUCED.** The removal mechanism remains unidentified. This
file records what was observed, what was ruled out, and what a future
investigation should collect — so the gap stays visible instead of being closed
by silence.

The other half of the issue — a launch-time preflight that fails loud — *was*
implemented and is measured at the bottom.

## What was observed (2026-09-06, from the issue)

During a long four-lane `/workflow:orchestrate` session, the `librarian`
registration vanished from `~/.claude/plugins/known_marketplaces.json`
mid-session, taking `dev-core`, `review-audit`, and `workflow` with it. Every
newly-launched golem then failed at its first prompt:

```text
● Unknown command: /workflow:next-issue
● Args from unknown skill: 894 --level 3
```

State at the time of discovery:

| Check | Result |
| --- | --- |
| `claude plugin marketplace list` | only `claude-plugins-official`, `agentsys` — no `librarian` |
| `claude plugin list \| grep librarian` | nothing installed |
| `grep -c '"librarian"' known_marketplaces.json` | 0 |
| `~/.claude/plugins/marketplaces/` | `agentsys`, `claude-plugins-official` only |
| `grep -c librarian installed_plugins.json` | 0 |
| `/opt/librarian/.claude-plugin/marketplace.json` | **present** — the baked source was intact |
| repo `plugins/{dev-core,review-audit,workflow}` | **present** |

Neither the image nor the repo lost anything: only the **host-side registration**
disappeared. `known_marketplaces.json` had an mtime minutes before discovery;
`installed_plugins.json` was ~1 h older — so whatever removed the marketplace did
**not** rewrite the installed-plugins file at the same time. The two were left
inconsistent, which is itself a clue: it points at a writer that touches one file
and not the other, rather than a wholesale `~/.claude` reset.

## Why it was invisible

Two properties compound:

1. **Already-running golems were unaffected** — they had loaded their skills at
   startup, so they kept working. Only a *new* session sees the loss.
2. **A dead lane looks like a quiet lane.** `golem-gate-watch.sh` classifies a
   pane whose last line is `Unknown command` as `idle` (its #229 arm). The
   orchestrator's feed showed a lane doing nothing, which is
   indistinguishable from a lane between steps.

So a four-lane run silently became a three-lane run, and stayed that way.

## Candidates, and what can be said about each

Not reproduced, so none is confirmed. Recorded for whoever next sees it:

| Candidate | Status |
| --- | --- |
| A `claude plugin` operation elsewhere in the session rewriting the file | **Not eliminated.** The mtime split (marketplaces file recent, installed file an hour older) is consistent with a partial writer. |
| Concurrent writes from multiple golem sessions to one `known_marketplaces.json` | **Not eliminated, and the best fit for the observed conditions** — the failure appeared during a four-lane run, i.e. the highest-concurrency state that session reached. No write-serialization is known to exist on that file. |
| A `~/.claude` volume or permission event | **Not eliminated,** but weakly supported: a volume event would be expected to disturb `installed_plugins.json` too, and it was untouched for an hour. |

## What a future investigation should capture

The condition is rare and was gone by the time anyone looked, so the useful
artifacts are the ones that must be collected *before* discovery:

- `stat` on both `known_marketplaces.json` and `installed_plugins.json` at each
  dispatch (the mtime split is the sharpest signal available).
- A copy of `known_marketplaces.json` retained per dispatch, so the diff at the
  moment of loss is recoverable rather than inferred.
- Whether the loss ever occurs in a **single-lane** run. If it does not, the
  concurrency candidate is promoted from "best fit" to "likely".

## The preflight (AC2) — measured

The half that *was* implemented: `golem-launch.sh` now probes plugin capability
before dispatching, and refuses rather than launching into the broken state.

Measured in this worktree, 2026-09-06, against the real `claude` CLI and stubs:

| Probe state | `launch` | Observed |
| --- | --- | --- |
| real CLI, plugin healthy | proceeds | no warning; launch line emitted |
| `Plugin "…" not found.` + exit 1 | **exit 3** | refusal naming `claude plugin marketplace add` |
| exit 0 but `Skills (0)` | **exit 3** | `resolvable but reports 0 skills` |
| exit 0, count line **unreadable** | proceeds | `UNVERIFIED` warning (see fail-open below) |
| no temp **file** creatable | proceeds | `UNVERIFIED` — names the file failure |
| no temp **directory** creatable | proceeds | `UNVERIFIED` — names the mkdir failure separately |
| probe hangs 60 s, bound 3 s | **exit 3** | refused after **4 s** |
| probe absent from `PATH` | proceeds | silent skip (undeterminable) |
| `GOLEM_SKIP_PLUGIN_CHECK=1` | proceeds | warning only |

Three of those rows are the point of the design:

**Zero skills must refuse.** The container-side guard this replaces greps
`known_marketplaces.json` and reports success on the strength of the grep, so a
file that still names the marketplace while the plugins are gone reads as
healthy. Checking only the probe's **exit code** reproduces that same false pass
one level up — the plugin resolves, discovers nothing, and the golem still dies.
Asserting a non-zero skill count is what makes this a capability probe.
`CLAUDE.md` already prescribes exactly this check, because manifest validation
does not exercise component discovery.

That claim was **mutation-tested** rather than asserted. Weakening the guard to
accept any resolvable plugin — `[ -n "$count" ] && return 0`, dropping the
`-gt 0` — fails **exactly 1 of 317** tests, and it is the zero-skills case:

```text
golem-launch: exit 0 with zero skills still refuses (#946)  [10-launch.sh] ... FAIL
  Passed:  316
  Failed:  1
```

A clean, targeted kill in both directions: the assertion detects the weakening,
and nothing else in the suite fails spuriously alongside it — so the test is
pinning the count, not a coincidence of the surrounding setup.

**An unreadable count must NOT refuse.** `plugin details` has no structured
output mode — probed directly: `--json` is rejected as an unknown option, and
`--help` lists no other flag — so the count is scraped from human-readable text.
That scraper will eventually stop matching: a rewording, an added ANSI sequence,
a localized string. The question is which way it fails when that happens.

Treating unreadable output as *absent* would refuse **every dispatch on every
host** the moment the CLI's phrasing changed — a total outage, in the exact
opposite direction from the false pass this guard was built to catch. So the
probe reports **three** outcomes rather than two (gone / a real count /
`unparsed`), and only the two it can actually read cause a refusal. A scraper
that no longer understands its input has learned nothing about the plugin, so it
warns loudly and proceeds. Both directions are pinned by tests, including one
asserting that an explicit `Skills (0)` and an unreadable line stay **distinct** —
collapsing them would look like a cleanup and would silently arm the outage.

This came out of the pre-PR review, which flagged the original single-branch
version as fail-closed. It was a real defect: worth recording that the guard's
first draft got the failure direction wrong in exactly the way this repo keeps
filing issues about, just inverted.

Re-reading the fix then turned up **the same defect one layer down**, by a
different route: `plugin_skill_count` needs a scratch file (a command
substitution cannot bound — see the timeout note below), and its `mktemp`
failure path returned early with an empty count, which the caller reads as
*absent*. An unwritable `TMPDIR` would therefore have refused every dispatch on
the host, for a reason having nothing to do with the plugin. Same class, same
correction: announce `UNVERIFIED` and proceed. The two unverified causes report
**separately** — a scratch-file failure described as "the CLI format changed"
would send an operator off to update a scraper that works fine.

Review cycle 2 then found a **third** instance in the same function, and it is
the least visible: `bounded_run` creates its own marker *directory* and returns
2 when that fails (`bounded-run.sh:63`) — a return this code cannot tell apart
from a probe exiting non-zero, so it lands back in the "absent" bucket. A plain
file check does not cover it, because file creation and `mkdir` are distinct
permissions: a directory-entry quota, some FUSE/overlay mounts, or a
write-but-not-mkdir ACL permits one and refuses the other. Guarded by probing
`mktemp -d` explicitly before the bounded call.

That third one is where this change got something **wrong, and had it caught**.
An earlier draft shipped the guard with no test and a comment declaring the
branch untestable: a PATH stub had been tried and was never invoked, and an
unwritable `TMPDIR` fails the plain-file `mktemp` first, so the directory branch
never runs. Both observations were real; the conclusion drawn from them was not.

Review cycle 3 refuted it with the mechanism: `BASH_ENV=/etc/bash_env` re-sources
a profile that **restores `PATH`**, silently discarding the stub before the
script ever ran. `-uBASH_ENV` fixes it — and this repo's own harness
already carried that exact idiom, for that exact reason, in `run_launch_auth`.
The test exists now, and a mutation check confirms it is not decorative:

| version | behavior under a stub that fails only `mktemp -d` |
| --- | --- |
| guard removed | `WARNING … is not resolvable` — the false refusal |
| guard present | `WARNING … UNVERIFIED (check TMPDIR)` |

Worth recording as a process point, not just a bug: "I could not find a way to
test this" is a statement about the search, and it was stated in the source as a
property of the code. The reviewer disproved it by *running* the stub the draft
had only reasoned about.

The three unverified causes report **separately**, which is the point of having
found three: a `mktemp -d` failure where the plain file succeeded is a
directory-entry quota, a FUSE/overlay mount, or a write-but-not-mkdir ACL —
telling that operator to "check TMPDIR" for a temp *file* points at the one
thing already known to work.

The lesson worth carrying: after fixing a fail-closed branch, grep the function
for **every** other early return that yields the same sentinel. Three instances
turned up in one function — one from each reviewer pass and one from re-reading —
and each was reachable the whole time.

**A hang must refuse, not skip.** An unresponsive CLI is not evidence of a
healthy plugin. The bound needed a correction found during implementation:
capturing the probe through a command substitution (`out="$(bounded_run …)"`)
blocks for the child's *full* lifetime, because an orphaned grandchild keeps the
substitution's pipe write end open even after the bound fires. Measured directly:

```console
substitution: rc=124 elapsed=60      # bound of 3s over a 60s hang
direct:       rc=124 elapsed=3
```

The exit code was right in both cases, so a test asserting only the code would
have passed a bound that did not bound anything. The guard captures to a temp
file instead, and the regression test asserts **elapsed time**, not just the code.

## AC3 — deferred, cross-repo

*"The container's re-registration guard verifies capability rather than grepping
a file"* is not implementable here. That guard lives at
`containers/lib/features/lib/claude/claude-setup:952-963`, in the `containers`
repo, which this repo carries as a **pinned submodule** (`update = none`) and
must not edit.

No new issue was filed, because one already covers it:
[containers#777](https://github.com/joshjhall/containers/issues/777) proposes an
on-demand repair script sharing one implementation with `claude-setup`'s boot
block, and its acceptance criteria already include *"post-install verification
asserts component discovery"* rather than an install exit code — the same
correction AC3 asks for. Filing a second issue would have split the work.

Notable: #777 records the **same failure on 2026-08-04**, a month earlier, with a
different suspected trigger (a Claude Code self-update mid-container-life). This
occurrence involved no update at all. Two independent occurrences with different
proximate triggers and an identical signature — only the **directory-sourced**
marketplace dropped, GitHub-sourced ones untouched — suggests the vulnerability
is in how that marketplace kind is persisted, not in any one trigger.

This issue's evidence was added to #777 as a comment, flagging the `claude-setup` grep
so it is not left as the one unconverted caller when the repair script lands. The
grep-based guard remains in place until then.
