# `long-function` BSD divergence — issue #932

Records the diagnosis and the live macOS evidence for
[#932](https://github.com/joshjhall/librarian/issues/932)
("`loop-make-it-right` long-function arm diverges bash-vs-python on BSD —
114 rows vs 0").

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

<!-- Fill from the `bsd-probe` job on the PR for this issue. Transcribe
     verbatim; do not summarize or tidy. -->

- **Job**: `BSD/macOS regex probe (informational)` — `.github/workflows/ci.yml`
- **PR**: *pending*
- **Host**: *pending*
- **Result**: *pending*

```text
(paste the `Python-port contract + bash parity` step output here)
```

**Status: OPEN pending the macOS run.** The diagnosis above is reproduced under
simulation on Linux and is complete, but AC1 ("root-cause the divergence on a
BSD host") and AC4 (`bsd-probe` green on `main`) are closed only by the real
run. Until this block is filled, treat the BSD result as *predicted*, not
*observed*.
