# Pinned test corpora — verification for issue #1075

**Status: COMPLETE.** A finished end-to-end report, not a running tally. It
records what was measured before each corpus was pinned, which of #1067's
candidates did not survive that check, and the live end-to-end run of
`bin/fetch-corpora.sh`.

Session date: 2026-09-16. Platform: Linux container (Debian, git 2.x), plus the
GitHub REST API for repository metadata.

## Why this document exists

[#1075](https://github.com/joshjhall/librarian/issues/1075) says to populate the
manifest from #1067's candidate list **"verifying each before pinning"** —
current state, actual license, and that the SHA is fetchable by the documented
recipe. #1067 itself flags that its list came from an assistant with a knowledge
cutoff and must be checked.

That check was not a formality. **Three of the seven candidates did not survive
it**, one of them fatally.

## Candidate verification

Metadata read from `gh api repos/<owner>/<name>` — license from the repo's own
SPDX field, not inferred.

| Candidate | License | Size | Verdict |
| --- | --- | --- | --- |
| `jsx-eslint/eslint-plugin-jsx-a11y` | MIT | 2.2 MB | **PINNED** — labeled ground truth |
| `dequelabs/axe-core` | MPL-2.0 | 23 MB | **PINNED**, but re-pinned to a tag (below) |
| `radix-ui/primitives` | MIT | 24 MB | **PINNED** — near-clean negative control |
| `excalidraw/excalidraw` | MIT | 105 MB | **PINNED** — i18n corpus, replacing Mastodon |
| `Ranchero-Software/NetNewsWire` | MIT | 66 MB | **PINNED** — Apple arm for #1074 |
| `w3c/wai-bad-demo` | **none** | ~0 | **REJECTED** — empty and unlicensed |
| `mastodon/mastodon` | AGPL-3.0 | 405 MB | **REJECTED** — replaced by excalidraw |
| `element-hq/element-web` | AGPL-3.0 | 598 MB | **REJECTED** — same reason |
| `shadcn-ui/ui` | MIT | 71 MB | **DEFERRED** to #1069 — role already filled |

### The three that changed the plan

**`w3c/wai-bad-demo` — rejected, twice over.** #1067 called the W3C "Before and
After Demonstration" the *"cleanest possible A/B"* because it pairs an
inaccessible and an accessible version of one site. The repository at that URL
contains **three files** — `README.md`, `CODE_OF_CONDUCT.md`, `w3c.json` — and
**no fixtures at all**. It also carries **no license**.

Either finding alone disqualifies it. The paired-corpus *idea* remains good and
is worth re-sourcing from the WAI website repository, but the slice that wants it
should find it rather than inherit a dead pin. Recorded in the manifest header so
the next reader does not re-derive this.

**`mastodon/mastodon` — replaced as the i18n corpus.** AGPL-3.0 and 405 MB.
Nothing here is redistributed, so the license is not disqualifying on its own —
but #1075 says to pick a different corpus rather than proceed when terms make
even local automated analysis doubtful, and a permissive alternative existed.
`excalidraw/excalidraw` is MIT, an eighth the size, and confirmed to carry **59
locale files** under `packages/excalidraw/locales` — so it fills the "i18n'd
project" role with none of the question. `element-hq/element-web` was checked as
the other named alternative: AGPL-3.0 and 598 MB, so it does not help.

**`dequelabs/axe-core` — re-pinned from `develop` to a release tag.** The
`develop` tip moved **the same day** it was checked (`c026364f`, committed
2026-09-16T20:18:42Z). That is the drift this whole slice exists to stop,
observed live. Pinned instead at release tag **v4.13.0** →
`1cc54b900413660610180d631feb73c9e74f4dc9`. A tag is the better pin: it is what
upstream itself treats as stable, and it gives the manifest's `fallback` field
something real to name.

**Net result: every pinned corpus is permissively licensed** (MIT or MPL-2.0).
The license gate resolved cleanly rather than being deferred.

## Fetch mechanics — measured, not assumed

### Arbitrary (non-tip) SHA fetch works against GitHub

```bash
git init && git remote add origin https://github.com/dequelabs/axe-core.git
git fetch --depth 1 --filter=blob:none origin 1cc54b900413660610180d631feb73c9e74f4dc9
git checkout FETCH_HEAD
```

Exit 0. `git rev-parse HEAD` returned
`1cc54b900413660610180d631feb73c9e74f4dc9` — **exactly** the pin, not a branch
tip. Materialized size **22 MB**, against a GitHub-reported repository size of
23 MB.

A caveat on the cost figure, because it is easy to overstate: #1075's
"20 MB shallow+blobless vs 115 MB full" was measured on **librarian itself**, and
this session did **not** measure a full clone of axe-core to compare against. So
the honest claim is the total, not the ratio — the five pinned corpora are
~220 MB of GitHub-reported size and land around 100 MB materialized, which is
what makes a named volume the right home rather than something to re-fetch per
run. The per-repo saving depends on history depth and is not established here.

<!-- corpus: axe-core 1cc54b900413660610180d631feb73c9e74f4dc9 -->

### The unreachable-pin signature

Fetching a well-formed but absent SHA from a live remote:

```text
fatal: remote error: upload-pack: not our ref deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
```

`bin/fetch-corpora.sh` matches that string explicitly rather than reporting a
generic clone failure, so the error can name *which* pin died and print that
entry's `fallback` field. Without the distinction, a dead pin and a flaky network
produce the same message and send the reader to the wrong layer.

### Live end-to-end run

```text
$ CORPORA_DIR=/tmp/c1075-a bin/fetch-corpora.sh axe-core
fetch-corpora: materializing into /tmp/c1075-a
  axe-core       fetch    https://github.com/dequelabs/axe-core.git
  axe-core       verified 1cc54b900413660610180d631feb73c9e74f4dc9
fetch-corpora: done

$ CORPORA_DIR=/tmp/c1075-a bin/fetch-corpora.sh axe-core     # re-run
fetch-corpora: materializing into /tmp/c1075-a
  axe-core       ok       1cc54b9 (already at pin)
fetch-corpora: done
```

Idempotent, and the idempotence is decided by comparing `HEAD` to the manifest
SHA rather than by testing whether the directory exists — a tree left at the
wrong commit by an interrupted fetch must be repaired, not reported as present.

`/cache` was confirmed writable as `vscode` (`drwxr-xr-x vscode vscode`), so the
`/cache/corpora` primary path is real in the devcontainer; `/tmp/corpora` covers
hosts with no container.

## Gate verification

Both gates are **offline and corpus-independent** — they read committed files, so
they run in CI and pre-push with no network (#1075 AC8) and do not go inert when
no corpus is materialized.

### Mutation testing

A green suite proves nothing until the assertions are shown to fire. Each
scanner was mutated and the suite re-run:

| Mutation | Expected | Result |
| --- | --- | --- |
| `scan_citations` always returns clean | citation gate goes red | **3 fixtures FAIL**, exit 1 |
| citation SHA comparison always flags | control case goes red | **1 fixture FAIL**, exit 1 |
| `verify_head` always returns true (trust the fetch) | fetch suite goes red | **2 cases FAIL**, exit 1 |

The second row is the one that is easy to omit. Without a clean-sandbox control,
a scanner that flagged *everything* would satisfy all three negative fixtures —
just as broken as one that flagged nothing, and invisible to a suite that only
tests the firing direction.

The third row is #1075 AC4 stated as an experiment: with the verification
neutered, the script still exits 0 and still leaves a populated directory. Only
the two SHA-keyed cases notice, which is precisely why the criterion says *verify
the checkout, never trust the fetch*.

### Three defects the fixtures did not find

Mutation testing proves the assertions fire; it cannot find a case nobody wrote.
These three came from probing the scanners against shapes **no fixture
contained** — the discipline that matters most on a gate, because a gate's own
blind spots are invisible to a green suite. Each is now pinned by a fixture that
fails against the pre-fix code.

1. **A marker with no space after `corpus:` was skipped, not flagged.**
   `<!--corpus:alpha …-->` reads as a citation to any person, but the pattern
   required `[[:space:]]+` and simply did not match — so a mis-spaced citation
   was invisible to the gate while still reading as evidence in the document.
   Skipping is the dangerous direction. Fixed to `[[:space:]]*`.

2. **Two markers on ONE line: only the first was checked.** `grep -n` emits one
   row per *line*, not per match, and the parser read a single citation from each
   row. So a bogus citation passed whenever a valid one shared its line — the
   collapse-N-findings-into-one suppression shape. The parser now iterates every
   marker on the line. Note the existing "reads every hit" fixture used two
   markers on two *lines* and passed throughout, which is why the same-line
   sibling was needed.

3. **A corpus name was not validated at the boundary.** The name becomes a path
   component (`$root/$name`), so `../escape` would write outside the corpora
   directory. Nothing exploitable was reachable — the unquoted word-split made a
   metacharacter an inert token, and the manifest lookup then failed — but that
   is a property of downstream expansions staying correct, not a boundary. Names
   are now validated as `[a-z0-9-]` on entry.

The first two are the same family as the drift this slice exists to stop: a check
that reports clean while not having looked. Finding them in the gate rather than
in a consumer's published figure is the point of writing the gate first.

### What the adversarial review found on top of that

The pre-PR review harness (five dimensions + a fresh judge) returned **two
blocking findings and three deferrable**, all of which were fixed. The two that
mattered most were ones the author's own mutation testing structurally could not
reach, because they were about paths no fixture entered.

**1. Predictable `/tmp/corpora` enabled a symlink pre-plant (CWE-377, blocking).**
`resolve_corpora_dir` decided *writable* and treated that as *safe*. On a shared
host an attacker can create `/tmp/corpora` first — as a directory they own, or a
symlink to one — and both `mkdir -p` and the write probe then succeed. The script
would run `git init` / `fetch` / `checkout` inside that tree, and **git executes
`.git/hooks/*` automatically on checkout**, which turns an ordinary temp-dir
weakness into local code execution as the invoking user. Fixed with
`dir_is_trustworthy`: an existing path must be a non-symlink owned by the current
uid, checked *before* `mkdir -p` (afterwards, "we made it" and "it was already
there" are indistinguishable), and the fallback is created `mkdir -m 0700`.

**2. A test named for behavior it did not assert (blocking).**
`test_tmp_fallback_when_cache_unwritable` set `CORPORA_DIR` explicitly and
asserted the *error* path — the opposite of the fallback its name promised. That
is worse than no test: a reader scanning the list concludes the fallback is
covered and stops looking. Renamed to
`test_explicit_unwritable_corpora_dir_fails_loudly`, with the genuine gap stated
in the docstring rather than implied away.

**3. `corpora_present` could kill its caller (deferrable, fixed anyway).**
Found independently while triaging the review. `die` called `exit`
unconditionally, and in a **sourced** context `exit` terminates the *consumer's*
shell — so a consuming gate sourcing this file with a missing manifest would die
at load, never reaching the 77 sentinel it exists to report. The gate would die
with no verdict exactly where it should have printed `[SKIP] … did not run`.
`die` now returns when sourced and exits when executed; both directions are
asserted.

Two deferrable findings were also fixed rather than filed: the documented
https-only URL policy is now **enforced** (`valid_corpus_url`, plus an https
assertion over the committed manifest — a stated rule with no code behind it is
the doc-claims-what-the-code-lacks shape), and the untested default
fetch-everything path and `--help`/unknown-option branches now have cases.

### The fixture that was testing nothing

Worth recording on its own, because it nearly shipped green.
`test_trust_check_refuses_when_stat_is_unusable` shadows `stat` with a failing
stub to prove the guard **refuses** when ownership is indeterminate. The first
version passed — against a guard that fails open.

The cause: this environment sets `BASH_ENV=/etc/bash_env`, which bash sources on
every non-interactive start and which **rebuilds `PATH`**. The stub directory was
discarded before the script ran, `stat` resolved to the real binary, and the case
exercised the ordinary path while claiming to exercise the hostile one. Fixed
with `env -uBASH_ENV … bash --noprofile --norc`, and confirmed by mutating the
guard to fail open — which the fixture now catches.

The same class explains a related hardening: GNU and BSD `stat` disagree about
what `-f` means (BSD gives the uid; GNU reads `%u` as a *filename* and prints a
filesystem dump). The fallback chain therefore validates stat's **output** as
all-digits rather than trusting its exit status, so a wrong-platform answer is
unusable instead of merely unlikely.

### The trust check needed to be one level lower

Found by re-reading the fix rather than by a reviewer. `resolve_corpora_dir`
vets the corpora **root**, but `fetch_one` then creates `$root/$name` — and
*that* is the directory git inits, fetches and checks out in, so that is where
`.git/hooks/*` would run.

Vetting only the parent is sufficient when the parent is `0700` and ours, which
is true of the `/tmp` fallback by construction. It is **not** sufficient on the
`/cache/corpora` volume, whose mode this script does not control (measured here:
`755`, so on a host where it were group- or world-writable a hostile per-corpus
child could be planted under a perfectly trustworthy root). The check now runs at
both levels, which removes the dependence on the parent's mode entirely.

`test_symlinked_per_corpus_dir_is_refused` pins it, and deleting the check makes
that fixture fail — so it is load-bearing rather than decorative.

### Cycle 2: the fix for the CWE-377 finding did not work

The second review cycle returned **two blocking findings, both defects in the
cycle-1 fix itself**. This is the part worth reading: a fix that looks right,
carries a comment stating what it achieves, and ships with a passing fixture can
still achieve nothing.

**The per-corpus trust check never ran on the common path.** It was placed
*after* the `corpora_present` idempotence fast path. That predicate asks only
"is there a `.git` here whose `HEAD` equals the pin" — and the manifest's
URL+SHA pairs are **public**, so an attacker clones the real commit into a tree
they own and symlinks `$root/$name` at it. The SHA matches, the fast path returns
0, and the guard is skipped entirely.

Reproduced before the fix, against the real axe-core pin:

```text
$ CORPORA_DIR=/tmp/attack/root bin/fetch-corpora.sh axe-core
  axe-core       ok       1cc54b9 (already at pin)
fetch-corpora: done                                     # exit 0, no refusal
```

and after moving the check above the early return:

```text
fetch-corpora: axe-core: refusing to use /tmp/attack/root/axe-core
  — it is a symlink or is not owned by uid 501          # exit 1
```

The ordering is the entire fix. Note why the existing fixture missed it:
`test_symlinked_per_corpus_dir_is_refused` plants an **empty** symlinked
directory, which fails `corpora_present` and therefore reaches the check by the
slow path no matter where the check sits. Only a symlink that is genuinely **at
the pin** distinguishes "checked before the fast path" from "checked after it" —
which is what `test_symlinked_per_corpus_dir_refused_even_when_at_the_pin` now
constructs, and it is the *only* fixture that fails when the ordering is
reverted.

**A "control" that controlled nothing.** The URL-policy test's third block was
commented as the accepting-direction control and asserted
`assert_file_exists "$at_mf"` — it proved a `printf` succeeded and never invoked
the checker. A rejection-only set passes equally well against a checker that
refuses everything, so the accepting direction has to be *run*, not described. It
now probes `valid_corpus_url` directly across five URLs and asserts both
verdicts.

Two deferrable findings were also taken: the check-then-act window between the
existence test and `mkdir -p` is closed by re-checking after creation (`mkdir -p`
through a pre-planted symlink succeeds silently), and
`test_foreign_owned_per_corpus_dir_is_refused` brings the child call site to
parity with the root's two-branch coverage.

**What this says about the cycle-1 report above.** Its mutation table is
accurate — those five mutants really were caught — and it was still not enough,
because mutation testing only probes paths a fixture already enters. Both cycle-2
blockers lived on paths no fixture reached: one behind an early return, one
behind an assertion that never called the subject.

### The third instance, and the structural fix

Cycle 2 asked, in effect, *are there other paths that reach a git operation
without the guard?* Answering it properly — walking every call site rather than
the one the reviewer named — found a **third** instance, this time not on the
fetch path at all.

`corpora_present` had no trust check. That is the one function consuming gates
import, and `--list` calls it too, so a symlink pre-planted at the **public**
pinned SHA reported `present`:

```text
$ CORPORA_DIR=/tmp/attack/root bin/fetch-corpora.sh --list
  axe-core       present  1cc54b900413660610180d631feb73c9e74f4dc9
```

A consuming gate keying its 77 sentinel on that predicate would measure an
attacker's tree while believing it held the pin — the same
wrong-answer-reads-as-evidence failure, arriving through the predicate rather
than the fetch.

Three instances of one class is the signal to stop patching call sites. The
guard now lives **inside `corpora_present`**, so every caller inherits it:

| # | Call site | Found by |
| --- | --- | --- |
| 1 | `resolve_corpora_dir` (the corpora root) | cycle 1 review |
| 2 | `fetch_one` (the per-corpus dir) | author, re-reading the cycle-1 fix |
| 3 | `corpora_present` (the shared predicate) | author, exhaustive control-flow walk |

It returns **false** rather than dying: "I will not vouch for this tree" is a
legitimate answer from a predicate, and `fetch_one` still fails loud on the same
condition, where a refusal is actionable rather than a silent skip.

### On the cycle cap

`maxCycles: 3` was passed to the harness on an assumption; the documented default
is **5**, and `ship-protocol.md` records why 3 was measured as wrong in both
directions — across a 26-cycle batch, the single `blocking` security finding
arrived in **cycle 4**. Given that cycles 1 and 2 each returned real blocking
defects here, stopping at three because that number was typed would have been the
worst available reason. The stop decision belongs to
`scripts/review-convergence.sh`, which is what this run uses rather than an
eyeballed judgement.

### Result

```text
$ bash tests/lint-measurement-citations.sh   # 16 passed, 0 failed
$ bash tests/validate-fetch-corpora.sh       # 27 passed, 0 failed
$ bash tests/validate-shards.sh              # 15 passed — both gates claimed by exactly one shard
$ bash tests/lint-shell-portability.sh       # 2762 passed, 0 failed (bash-3.2 + BSD, AC9)
$ bash tests/lint-shellcheck.sh              # 346 passed, 0 failed
```

Both gates also carry a **non-vacuity** assertion, because every other row in
each would pass against an empty corpus for the wrong reason: the citation gate
asserts the manifest has entries *and* that the live scan finds at least one real
citation (an absent `docs/verification/` now fails rather than reading clean),
and the fetch suite asserts its fixture repo really has two distinct commits, so
the "non-tip pin" cases cannot silently degrade into tip cases.

## What #1075 deliberately does not do

**Neither gate exits 77 for absent corpora.** AC7's reserved sentinel belongs to
the corpus-*consuming* gates that #1069/#1071/#1072/#1074 will ship: those
genuinely cannot run without a corpus and must skip loudly rather than pass
green. These two need no corpus, so keying them on one would make them inert —
the #538/#571 shape where silence reads as a pass, introduced by the very change
meant to prevent it. `fetch-corpora.sh` exports `corpora_present` for the
consumers to key on, and `test_corpora_present_is_sha_keyed` pins that it answers
"present **at the pin**" rather than "directory exists".

## Limits

- The four corpora other than `axe-core` were verified by API metadata and pin
  resolution, not by a full materialization — the recipe is identical and the
  one live run exercised it end to end. A first consumer slice will fetch them
  all.
- `corpora_present` is shipped and pinned, but has **no consumer yet**; the first
  arrives with #1069. A helper whose only caller is its own test is worth
  re-checking when that lands.
- The citation marker is exact-match by construction, so it has no
  false-positive rate to measure — but equally, it cannot catch a measurement
  published with **no** marker at all. That gap closes when a consuming slice
  publishes its first figure and the reviewer looks for the citation.
