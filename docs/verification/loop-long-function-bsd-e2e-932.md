# `long-function` BSD divergence — issue #932

Records the diagnosis and the live macOS evidence for
[#932](https://github.com/joshjhall/librarian/issues/932)
("`loop-make-it-right` long-function arm diverges bash-vs-python on BSD —
114 rows vs 0").

**Status: CLOSED** — confirmed on `macOS 26.6.2` / `BSD grep 2.6.0-FreeBSD`,
[run 34059645619](https://github.com/joshjhall/librarian/actions/runs/34059645619/job/101557777887):
the parity suite went **63/64 → 64/64**. See [VERIFIED — live](#verified--live).

This file exists for the same reason as
[`bsd-regex-probe-e2e-684.md`](bsd-regex-probe-e2e-684.md): every development
host in this project runs a **GNU userland**, and on GNU the two impls agree
(both emit **zero** `long-function` rows on the parity fixture). The defect is
reachable only under a second userland, so the closing evidence must come from
the `bsd-probe` job on `macos-latest`.

## Root cause — BSD `wc` PADDING, not the regex dialect

The issue named two suspects: the bounded-repeat BRE `^.\{0,N\}[^ ]` and the
`wc -c` indent width. **It is the second, and the mechanism is padding rather
than the byte count.**

`patterns.sh` computed the indent as:

```bash
indent=$(command printf '%s' "$content" | command sed 's/[^ ].*//' | command wc -c)
end_line=$(command sed -n "$((line_num + 1)),\$p" "$file" |
    command grep -n "^.\{0,${indent}\}[^ ]" | command head -1 | command cut -d: -f1)
```

BSD `wc` formats its count with `%7ju` — **right-aligned to width 7** — where GNU
emits the bare number. So on macOS `indent` is `"      0"`, not `0`, and the
interval interpolates to:

```text
^.\{0,      0\}[^ ]
```

That is a **malformed interval**. Whether the host's grep rejects it or reads it
as literal text, it matches **nothing** — so `end_line` comes back empty and
every `def` falls through to the `total - line_num` fallback, i.e. every function
is measured as running to **end of file**. On a 623-line fixture that puts all
but the last few defs over the 50-line threshold.

This is the classic silent shape #679 documented, with the polarity inverted:
not a clean report of nothing, but a **confident report of the wrong thing**.

### The count is the proof

The mechanism predicts the issue's number exactly. Of the 124 `def` lines in
`$FIXDIR/Upper.PY`, those with `total - line_num > 50` number:

```console
$ grep -nE '^[[:space:]]*def [[:alnum:]_]+' Upper.PY | cut -d: -f1 |
      awk -v t=623 '{ if (t-$1 > 50) n++ } END { print n }'
114
```

**114** — the exact bash row count the issue reports. A coincidence at that
precision is not plausible; the fallback branch is the source of every row.

### Reproduced on Linux with a BSD-`wc` simulation

Root-causing did not have to wait for macOS. A shim reproducing only BSD's
width-7 padding (nothing else about BSD) is enough to drive the whole defect on
a GNU host — which is what makes the diagnosis *falsifiable here* rather than
merely argued:

```console
$ # pre-fix patterns.sh, PATH-shimmed so `wc` pads to width 7
$ ... | cut -f3 | sort | uniq -c
    114 long-function
    121 single-char-name

$ # post-fix patterns.sh, same shim
$ ... | cut -f3 | sort | uniq -c
    121 single-char-name
```

Pre-fix reproduces **114/121** — the issue's row counts — and post-fix reproduces
python's output exactly. The `bsd-probe` run below is the confirmation that a
real BSD `wc` behaves as the shim models; the shim is what establishes that the
padding is *sufficient* to cause the reported numbers.

> Note on method: the shim must be asserted **active** before its result is
> trusted. This image sets `BASH_ENV=/etc/bash_env`, which rewrites `PATH` in
> every child shell and silently restored the real `wc` — the first three A/B
> runs read as "the shim changes nothing," which is indistinguishable from "the
> hypothesis is wrong." The runs above use `env -u BASH_ENV` plus an explicit
> `command -v wc` assertion that exits non-zero if the shim is not the one found.

## A SECOND defect, live on Linux the whole time

Root-causing turned up an independent bug the BSD split had masked. `patterns.py`
computed:

```python
indent = len(stripped) + 1  # wc -c counts the newline
```

The `+ 1` models a trailing newline that **GNU `sed` does not emit** for input
lacking one. So the two impls were off by one column, and the correct value is
the plain leading-space count (the column the first non-space sits at, which is
what the `^.{0,N}[^ ]` probe wants).

It went unseen because it is only observable for a body indented **exactly one
space past its `def`** — a shape no fixture had:

```console
$ printf '%s\n' 'class C:' '    def m(self):' '     a()' '     b()' '     c()' 'trailing = 1' > o.py
$ LOOP_MAX_FUNCTION_LINES=1 PATTERNS_FORCE_BASH=1 bash patterns.sh l | cut -f3,4
long-function	Function 4 lines (max 1):     def m(self):
$ LOOP_MAX_FUNCTION_LINES=1 python3 patterns.py l | cut -f3,4
(no output)
```

Both now use the space count, which is also the semantically correct width.

## The fix

- **`patterns.sh`** — indent is counted in **pure bash**
  (`_lead=${content%%[! ]*}; indent=${#_lead}`). Fork-free, bash-3.2 clean, and
  immune to *both* BSD behaviours (the padding and the `sed` trailing newline).
  It equals GNU's old value exactly, so Linux behaviour is unchanged.
- **`patterns.py`** — the `+ 1` off-by-one dropped.

## Sibling survey (AC5) — one more real hit

`grep -rn '\{0,' plugins/` finds the bounded repeat at **one** site only (the one
fixed). But the survey was widened from the *construct* to the *mechanism* —
any unstripped `wc` count — and that found a second live divergence:

`check-docs-organization/patterns.sh` interpolated a `wc -l` count **into the
evidence text**, so under BSD it emitted:

```text
Directory d/ has       6 files but no README     # bash on macOS
Directory d/ has 6 files but no README           # python, everywhere
```

A real bash↔python parity break in the emitted TSV, reached through string
interpolation instead of a regex interval. Fixed with `| tr -d '[:space:]'`.
The numeric comparison at that site tolerates padding on its own (`[ -ge ]` and
`$(( ))` both strip leading blanks) — only the evidence string does not, which is
why a survey keyed on "is the count used in arithmetic" would have missed it.

## Correctness fixtures, not parity

Per the issue's AC3, the new cases assert the **intended** answer, not that the
two impls match — the trap `validate-python-ports.sh`'s own header warns about,
and precisely what let #932 hide (on Linux both impls were silent, so "they
agree" held between two *empty* outputs).

- `tests/validate-loop-detectors.sh::test_right_long_function_extent_correctness`
  pins the **line count** of a def's extent. This is the load-bearing choice:
  #932's macOS failure was not that the arm stopped firing but that it fired
  **114 times with the wrong number**, so a test asking only "does it fire?" is
  green in both worlds. Only the count separates them.
- `tests/validate-docs-detectors.sh` pins the unpadded `has 3 files` evidence.

### Mutation round

Each fix was reverted in turn and the new assertions confirmed red:

| # | Mutation | Result |
| --- | --- | --- |
| M1 | `patterns.sh` back to `sed \| wc -c` | **PASS** — a no-op on GNU |
| M1b | `patterns.sh` indent padded to width 7 (the BSD *outcome*) | **FAIL** ✓ |
| M2 | `patterns.py` `+ 1` restored | **FAIL** ✓ |
| M3 | `check-docs-organization` count padded | **FAIL** ✓ |

M1 is the instructive row and is recorded rather than hidden: on a GNU host,
reverting to the GNU spelling **cannot** be detected, because the two spellings
agree here. A GNU host can only mutate a GNU-ism by mutating to *the other
platform's outcome*, which is M1b.

## VERIFIED — live

Transcribed verbatim from the job log.

- **Job**: `BSD/macOS regex probe (informational)` — `.github/workflows/ci.yml`
- **PR**: [#945](https://github.com/joshjhall/librarian/pull/945),
  [run 34059645619](https://github.com/joshjhall/librarian/actions/runs/34059645619/job/101557777887)
- **Host**: `macOS 26.6.2` (`BuildVersion: 25G83`), `Darwin 25.6.0`,
  `arm64` (`RELEASE_ARM64_VMAPPLE`)
- **grep**: `grep (BSD grep, GNU compatible) 2.6.0-FreeBSD`
- **sed**: no `--version` (`sed: illegal option -- -`) — the refusal *is* the
  identification
- **Result**: job **passed**; POSIX baseline held

The userland is confirmed BSD before any result below is read — that check is
what makes this run evidence rather than another GNU baseline.

### Operator's own macOS run — PASTE HERE

The block above is the **CI** `bsd-probe` job. This slot is for the operator's
**local** macOS run of the same suite, kept separate rather than merged into it
so the two remain independently attributable — a hosted runner and a real
workstation are different evidence, and if they ever disagree that fact must
stay visible rather than being averaged away.

Paste verbatim; do not summarize, tidy, or re-order. If the result differs from
the CI run above, **do not reconcile them** — record both and treat the
disagreement as the finding.

- **Host**: macOS 26.6.2 (build 25G83); `Darwin 25.6.0 ... RELEASE_ARM64_T6041 arm64`
- **bash**: `GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)` — the 3.2 floor itself
- **grep**: `sed --version`-style refusal not applicable; see note below — the
  interactive `grep` on this host is a **ugrep 7.8.4** shim, so BSD behaviour was
  re-confirmed against stock `/usr/bin/grep` directly. The detectors call
  `command grep`, which bypasses the shell function regardless.
- **sed**: `sed: illegal option -- -` (BSD; GNU would print a version)
- **python3**: 3.14.7
- **Command**: `bash tests/validate-python-ports.sh`
- **Result**: **64/64 PASS** — up from the 63/64 this issue reports.

```text
  dev-core/skills/loop-make-it-right/patterns.py: edge-case contract (no-arg exit 1, empty-list exit 0) ... PASS
  dev-core/skills/loop-make-it-right/patterns.py: bash<->python TSV parity ... PASS
  dev-core/skills/loop-make-it-right/patterns.py: input-guard exit-code parity (#816) ... PASS
  review-audit/skills/check-docs-organization/patterns.py: edge-case contract (no-arg exit 1, empty-list exit 0) ... PASS
  review-audit/skills/check-docs-organization/patterns.py: bash<->python TSV parity ... PASS
  review-audit/skills/check-docs-organization/patterns.py: input-guard exit-code parity (#816) ... PASS

Summary
  Total:   64
  Passed:  64
  Failed:  0
  Skipped: 0
```

#### Root cause, reproduced live on this host

Both halves of the mechanism were observed directly rather than inferred:

```text
$ printf 'ab' | wc -c | od -c        # BSD wc PADS to width 7
0000000                                2  \n

$ printf 'ab' | sed 's/b//' | od -c  # BSD sed appends NO trailing newline
0000000    a
```

The padding is the defect. Interpolated into the bounded-repeat probe it yields a
malformed interval, and stock `/usr/bin/grep` rejects it outright:

```text
$ sed -n '2,$p' probe.py | grep -n "^.\{0,       0\}[^ ]"
grep: invalid repetition count(s)
... pipeline exit=0          # <- the silent part: grep failed, the pipeline did not

$ sed -n '2,$p' probe.py | grep -n "^.\{0,0\}[^ ]"
2:def b():                   # <- unpadded: the probe works
```

That non-zero-grep-inside-a-zero-exit-pipeline is precisely the #679 shape: the
old code did not error, it silently failed to find any function end, so every
`def` fell through to the `total - line_num` fallback and produced the 114
phantom HIGH rows.

**Correction to one comment in the fix.** `patterns.sh` claims BSD `sed` appends
a trailing newline where GNU does not. Measured above, the opposite is true on
this host: BSD `sed` emits no trailing newline. This does not affect the fix —
the pipeline it describes was replaced wholesale by the fork-free
`${content%%[! ]*}` parameter expansion, so neither `wc` nor `sed` is on the path
any more — but the stated rationale (2) is wrong and is corrected here rather
than left to mislead a later reader.

### Second BSD finding: `env --unset=` — CONFIRMED on this host

Issue #932's comment thread recorded this as **documented-but-unverified**, with
two cautions and two one-liners that only a BSD host could answer. Both were run
verbatim on this machine; the transcript is exact.

```console
$ FOO=1 /usr/bin/env --unset=FOO sh -c 'echo "FOO=[${FOO-unset}]"'; echo "rc=$?"
env: unsetenv nset=FOO: Invalid argument
rc=1

$ FOO=1 /usr/bin/env -uFOO sh -c 'echo "FOO=[${FOO-unset}]"'; echo "rc=$?"
FOO=[unset]
rc=0
```

Both cautions from the thread are now closed, and one prediction is corrected:

- **Caution 1 — the BSD error string was "unconfirmed".** It is now confirmed
  **verbatim**: `env: unsetenv nset=FOO: Invalid argument`. That is the string
  attributed to BSD elsewhere in the tree, and it differs from GNU 9.7's
  `cannot unset 'nset=FOO'` exactly as the thread suspected.
- **Caution 2 — "modern macOS `env` may have gained long-option handling".** It
  has not. macOS 26.6.2 rejects the long form outright.
- **CORRECTION to the predicted failure shape.** Both comments predicted a
  *silent wrong-environment pass* — "tests would run with inherited `GIT_*`
  state rather than erroring". **That is not what happens.** `env` exits 1 and
  **never execs the child** (verified: a child whose only job is to `echo` prints
  nothing). The idiom is therefore **fail-closed**, not silently-wrong: no test
  has ever run against unscrubbed git state on macOS. The observable symptom is
  the sandbox variable never being assigned, so the suite dies later at
  `sb: unbound variable` — which is what was actually seen here, in
  `tests/validate-docs-detectors.sh`. This is better than feared: the bug
  destroyed the suite rather than quietly corrupting its results.

Blast radius matched the thread's survey exactly: **46 files** carrying
`--unset=` on `main` (`3ec84b8`), of which only **8** are findable by a literal
`env --unset=` grep — the other 38 reach `env` through the
`"${GIT_SCRUB[@]/#/--unset=}"` array expansion. All were converted to the
attached `-uVAR` form, which is the only spelling that survives that idiom.

### The full BSD sweep: nine further defects, all found by RUNNING the suite

Validating the fix meant running `tests/run-all.sh` on a real Mac for the first
time. It failed **20 stages**. None were caused by the #932 fix; each was a
latent defect that only a BSD/macOS host (or a differently-configured developer
machine) could expose. `tests/run-all.sh` runs **only on `ubuntu-latest`**, and
the lone `macos-latest` job runs just two scripts, so none of this had ever
executed on a second userland.

| # | Defect | Mechanism | Failure shape |
| --- | --- | --- | --- |
| 1 | `realpath -m` | GNU-only; `\|\| echo "$1"` fallback returns the path UNRESOLVED | **security hole** — see below |
| 2 | `env --unset=` | GNU long option; BSD reads it as `-u nset=VAR` | fail-closed, 46 files |
| 3 | `/var` vs `/private/var` | `mktemp -d` and `git rev-parse` disagree | every row silently dropped |
| 4 | BSD `wc` padding | `"       3"` vs `"3"` in a STRING compare | assertion mismatch |
| 5 | `mktemp --suffix=` | GNU-only, **and still exits 0** | empty var, confusing error |
| 6 | `[[:<:]]` fixture | BSD ACCEPTS it; the test assumed GNU rejection | wrong verdict class |
| 7 | tmux socket path | 109 bytes vs the 104-byte `sun_path` cap | spurious `WARNING:` |
| 8 | GNU `timeout` | absent on macOS; helper called it despite the caller's guard | rc=127 |
| 9 | `touch -d @epoch` | GNU-only; BSD prints usage and **exits 0** | mtime unchanged → "not stale" |

Two more were not macOS-specific at all — they break on **any** developer
machine so configured, and both had been invisible because CI runners are
configured the other way:

| # | Defect | Trigger | Failure shape |
| --- | --- | --- | --- |
| 10 | `init.defaultBranch=main` | collides with the fixture's own `git branch -f main` | fixture never builds |
| 11 | `commit.gpgsign=true` | signing agent refuses → HEAD never exists | fixture never builds |

Defects 10 and 11 deserve emphasis because they fail in the **dangerous**
direction. `golem-mode-check`'s drift arms reported **exit 0 with empty output**
— which reads as "no drift detected", a PASS-shaped result — when the truth was
that the fixture had never been constructed. A test that cannot build its own
fixture should fail loudly; this one reported the absence of a problem.

#### Defect 1 in detail: the symlink guard was defeated on every Mac

`seed-worktree-trust.sh` canonicalizes both sides before checking that the
worktree is under the repo root — the guard that stops a `.worktrees/issue-N`
**symlink** from redirecting a trust grant to an arbitrary host directory
(the issue-#21 attack surface). It did so with:

```bash
canon() { command realpath -m -- "$1" 2>/dev/null || command echo "$1"; }
```

`realpath -m` is GNU-only. Measured on this host:

```console
$ command realpath -m -- /tmp/does/not/exist
realpath: illegal option -- m
```

So on macOS the `||` branch always fired and `canon()` returned its argument
**unresolved** — the symlink intact. Demonstrated end-to-end:

```text
canon() gives : /var/.../repo/.worktrees/issue-7      <- the symlink itself
truth is      : /private/var/.../escape               <- where it points
```

The under-root check then compares a path that still contains the symlink, so it
passes, and the grant is written for a directory outside the repo. The
suite's own `test_symlink_escape_refused` was failing with `Expected exit: 3,
Actual exit: 0` — the security test correctly reporting a defeated guard, on a
platform where the suite had never been run.

The replacement resolves in pure shell (`cd -P` + `pwd -P`, both builtins — no
`realpath`, `readlink`, or `python`), walking to the deepest existing ancestor
and re-appending the non-existent tail to reproduce `-m` semantics. Verified
byte-identical to GNU `realpath -m` across symlink-escape, missing-tail, and
`..`-traversal inputs on **both** userlands.

#### Two more, found only by running the whole suite

| # | Defect | Mechanism | Failure shape |
| --- | --- | --- | --- |
| 12 | `grep -q` under `pipefail` | `-q` exits on match → `locale -a` gets SIGPIPE → pipeline rc=141 | **15 shipped detectors** |
| 13 | `sed -e '1{/^$/d}'` | BSD sed requires `;`/newline before `}` | wrong RELEASE NOTES |

**Defect 12 is the same trap this repo recorded in `7a7c0ac`** ("record that
grep -q under pipefail inverts a match"), reached independently:

```console
$ locale -a | grep -qixF C.UTF-8; echo $?
0
$ set -o pipefail; locale -a | grep -qixF C.UTF-8; echo $?
141
```

`0` means found; `141` is SIGPIPE — the same match, reported as a failure.

Every `patterns.sh` runs under `set -euo pipefail`, so the UTF-8 locale probe
reported "no UTF-8 locale" on a host that has one. `truncate_chars` then took its
byte-wise fallback and **split a multibyte character mid-sequence** — the bash
output ended in a bare `342` byte. That is the *same class of bash↔python
divergence #932 is about*, in a second detector family, and it was invisible on
Linux only because the fixtures there are ASCII. Fixed in all 15 by dropping `-q`
so grep drains its input.

**Defect 13 corrupts a user-visible artifact.** `bin/generate-release-notes.sh`
stripped blank lines with a GNU-only sed expression; BSD rejects it
(`extra characters at the end of d command`), the enclosing `$( )` swallowed the
error, `section` came back empty, and the script emitted the **generic fallback
release body instead of the real CHANGELOG section** — with exit 0. Any release
cut from a Mac would have shipped wrong notes. Replaced with a pure-bash
`strip_blank_edges`, per this repo's own "prefer a pure-bash parse over `sed`"
convention. Note the sibling expression in `bin/lib/release/changelog.sh` uses
the portable `-e '}'` split and was verified working on BSD — it is the
`1{/^$/d}` half that was broken.

#### Result

`tests/validate-golem-scripts.sh` went from **24 failures to 0** (289 tests).
Every fix above is a portability or hermeticity correction to test infrastructure
or, for defects 1 and 2, to shipped `plugins/` code; none changes what the
detectors under test actually assert.

### The arm this issue is about

```text
  dev-core/skills/loop-make-it-right/patterns.py: edge-case contract (no-arg exit 1, empty-list exit 0) ... PASS
  dev-core/skills/loop-make-it-right/patterns.py: bash<->python TSV parity ... PASS
  dev-core/skills/loop-make-it-right/patterns.py: input-guard exit-code parity (#816) ... PASS
```

### Whole-suite verdict

```text
  Total:   64
  Passed:  64
  Failed:  0
  Skipped: 0
```

**64/64, against the 63/64 that opened this issue.** The failing row
(`loop-make-it-right: python and bash impls emit identical findings`) is gone,
and no other row regressed. `check-docs-organization` — the AC5 sibling — also
reports `bash<->python TSV parity ... PASS` on the same run.

### AC status, closed

| AC | Evidence |
| --- | --- |
| 1. Root-cause on a BSD host | Diagnosis above; confirmed by this run going green |
| 2. Impls agree on macOS | `loop-make-it-right ... bash<->python TSV parity ... PASS` |
| 3. Correctness fixture | `validate-loop-detectors.sh`, mutation-verified (M1b/M2/M3) |
| 4. `bsd-probe` green | This run — green on the PR; on `main` at merge |
| 5. Sibling survey | One further hit found and fixed (`check-docs-organization`) |

**Status: CLOSED.** The prediction made under simulation on Linux — that
removing the `wc` dependency would take this suite from 63/64 to 64/64 on BSD —
is now an observation.

### Bonus: the probe's own dialect rows, from this run

Not this issue's subject, but this is a BSD run and the rows are cheap to
record for [#684](https://github.com/joshjhall/librarian/issues/684):

```text
  [info] \b under grep -E   (32 sites)                  SUPPORTED
  [info] \b under grep (BRE)  (6 sites)                 SUPPORTED
  [info] \b -E rejects partial word                     UNSUPPORTED  (UNSUPPORTED here means correct)
  [info] \b under sed -E                                UNSUPPORTED
  [info] [[:<:]] / [[:>:]] under grep -E                SUPPORTED
```

Note `\b under sed -E` reads **UNSUPPORTED** on BSD while `grep -E` supports it
— the two engines genuinely differ, exactly as `probe-bsd-regex.sh`'s header
warned they might. No scanner in this fix depends on it; recorded for #684.
