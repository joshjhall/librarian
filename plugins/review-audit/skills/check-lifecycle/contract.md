# check-lifecycle — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for
resource-lifecycle pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

The deterministic categories emit at certainty `MEDIUM` (method
`deterministic`): the pre-scan flags a *candidate* the LLM pass confirms, not an
auto-fixable definite defect. `unjoined-worker` and `unbounded-growth` are
LLM-only (no pre-scan rows).

| Category                 | Certainty   | Method                | Confidence |
| ------------------------ | ----------- | --------------------- | ---------- |
| `unreaped-subprocess`    | MEDIUM      | deterministic + llm   | >= 0.7     |
| `terminate-without-kill` | MEDIUM      | deterministic + llm   | >= 0.7     |
| `unclosed-handle`        | MEDIUM      | deterministic         | >= 0.7     |
| `unpaired-listener`      | MEDIUM      | deterministic + llm   | >= 0.7     |
| `unjoined-worker`        | MEDIUM      | llm                   | >= 0.5     |
| `unbounded-growth`       | MEDIUM/LOW  | llm                   | >= 0.5     |

## Language Support

Governed by [ADR 0002](../../docs/adr/0002-scanner-language-support.md).
`M` = modeled (per-language detectors run). `L` = lexical-only (no per-language
detector; the language-agnostic detectors run under its comment model).
`—` = unsupported (not scanned).

Only the four deterministic categories appear here. `unjoined-worker` and
`unbounded-growth` are LLM-only and emit no pre-scan rows, so they have no
per-language dispatch to declare.

<!-- contract: check-lifecycle-language-support -->

| Language   | ext(s)          | unreaped-subprocess | terminate-without-kill | unclosed-handle | unpaired-listener |
| ---------- | --------------- | ------------------- | ---------------------- | --------------- | ----------------- |
| Swift      | swift           | M                   | M                      | M               | M                 |
| Python     | py              | M                   | M                      | M               | M                 |
| JavaScript | js, jsx, mjs, cjs | M                 | M                      | M               | M                 |
| TypeScript | ts, tsx         | M                   | M                      | M               | M                 |
| Go         | go              | M                   | M                      | M               | —                 |
| Rust       | rs              | M                   | M                      | M               | M                 |
| Bash       | sh, bash        | M                   | M                      | —               | —                 |
| every other | —               | —                   | —                      | —               | —                 |

<!-- contract: end-check-lifecycle-language-support -->

**Swift was audited against this matrix in Phase 2 (#839) and needed no code
change.** It is the one scanner that modeled Swift before the epic began — the
asymmetry that motivated #622 in the first place — and all four categories were
confirmed to fire: `Process(` (unreaped-subprocess), `.terminate()`
(terminate-without-kill), `FileHandle(` (unclosed-handle), and
`.addObserver(`/`scheduledTimer` (unpaired-listener). Recorded here so a later
phase does not read the absent diff as an absent audit.

Every detector in this scanner is **language-specific** (ADR 0002 § 3): all of
them sit inside an extension arm and there is no trailing fallthrough arm, so an unmodeled
file yields zero rows and no error. This scanner therefore carries **no
false-positive risk** on an unmodeled language — only missing coverage. It is the
clean end of the spectrum described in ADR 0002 § Context.

One gap remains visible above: **Go** has no `unpaired-listener` arm, though the
language has registration idioms worth detecting. **Python's was filled in Phase
4 (#841)** — see below.

**Python was audited against this matrix in Phase 4 (#841).** The three
subprocess/terminate/handle arms were confirmed firing in both runtimes and
needed no change; the `unpaired-listener` cell was a real `—` and is now `M`. Its
arm keys on four registration idioms, chosen by measured rate over the Python
3.12 stdlib (1096 non-test files): `signal.signal` (17 hits), `atexit.register`
(11), `add_signal_handler` (4), and `add_reader`/`add_writer` (2). Each names a
registration that outlives its statement and wants a matching teardown —
`signal.SIG_DFL`, `atexit.unregister`, `.cancel()`,
`remove_signal_handler`/`remove_reader`.

`threading.Timer` is matched despite **0** stdlib hits: it is the canonical
Python timer idiom, and the stdlib declining to use its own convenience wrapper
says nothing about application code. A **bare `Timer(`** is deliberately not
matched — measured 6 hits, and far too generic to carry this category's
confidence. That sparse, registration-shaped profile is the *opposite* of the one
that got `let _ =` rejected from `check-code-health` in Phase 1 (723 candidates
against 2 true positives), which is the comparison that justified shipping this
arm at MEDIUM rather than deferring it.

Both runtimes spell the arm as **one** pattern rather than two, and that is
load-bearing for parity rather than cosmetic: `emit_rows` greps the whole file
per call, so a second call would emit all its rows *after* the first pattern's,
while the Python twin walks line by line. A file registering an `add_reader`
above a `signal.signal` would then differ in **row order** — which
`tests/validate-python-ports.sh` compares byte-for-byte. A single alternation
also keeps a line matching both halves at one row, matching the twin's single
`re.search`.

The leading boundary is a negated class over identifier characters only — it
**admits `.` on purpose**, and the reason is a correction worth keeping. The
first draft excluded `.` too, on the stated theory that `mysignal.signal(` would
otherwise match on its attribute-access tail. Mutating the `.` away produced no
test failure, which is what exposed the theory as false: the plain class already
rejects that line on the preceding `y`. What the exclusion actually bought was a
false **negative**, silencing the qualified registrations that are true
positives — a dotted `mod.threading.Timer` or `self.loop.add_reader` call. The
trailing boundary is carried by the **required** `[[:space:]]*\(`, a genuine
terminator unlike Phase 2's `[^{}]*`, which admitted identifier characters and
let `catches { }` through on the bash runtime alone. Both edges, and the
qualified form, are fixture-pinned in both runtimes.

**The leading boundary is POSIX `grep -w`, and the road there is worth keeping.**
Pre-PR review raised the two boundary spellings as a suspected py/sh divergence
on non-ASCII input. The first response measured it and "refuted" it — **that
measurement was wrong**: it set `LC_ALL=C` over an environment whose `LANG` was
already `C.UTF-8`, so the C-locale path was never exercised. Re-run under
`env -i`, bash fired where Python stayed silent.

Two bracket-class fixes were then tried, and **both failed**:

| Spelling | Result |
| --- | --- |
| `[^[:alnum:]_]` | portable, but bytewise under `C` — a multibyte letter's trailing byte satisfies it, so the arm fires where Python does not |
| `[^[:alnum:]_\200-\377]` | correct on GNU grep; **BSD grep rejects the pattern outright** (exit >1 — the raw byte range is invalid under its collation) |

The second failure is the instructive one: it passed every local check because
this repo's dev boxes carry GNU grep, and only `tests/probe-bsd-regex.sh` — the
lone gate on the `macos-latest` shard — caught it. That probe existed because an
earlier review cycle asked for exactly this coverage.

The arm now uses **`grep -w`**, a POSIX *flag* rather than a regex construct, so
it sidesteps the dialect question entirely — the same reasoning `probe-bsd-regex.sh`
already records for the `\b` sites. Because `-w` requires the match to *end* on a
word character (and `(` is not one), the "must be a call" test is re-imposed
separately inside `emit_rows_word` rather than folded into the `-w` pattern.

**Known limitation, stated rather than papered over.** The boundary is correct
under a **UTF-8** locale, not under a strict `C` one. Under `LC_ALL=C`, `-w`
decides word-ness bytewise, so a call prefixed by a non-ASCII **identifier**
character emits a false positive in bash while the Python twin stays silent. The
concrete case is real code, not prose: PEP 3131 permits non-ASCII identifiers, so
`caféadd_reader(...)` compiles, and that line fires in bash under `C` only. Under
any UTF-8 locale — including `C.UTF-8`, the default on the containers and CI
runners this scanner targets — the two runtimes agree exactly, on that shape and
on multibyte **punctuation** alike. Both the agreement and the gap are
fixture-pinned, so a locale change surfaces in the suite instead of silently
widening the divergence.

Rust (#838) is `M` for all four, but two of its arms are spelled differently from
every other language's and the reason is worth recording:

- **`terminate-without-kill` keys on `SIGTERM`, not on `.kill()`.** This category
  asks whether a *graceful* stop escalates to SIGKILL. `std::process` has no
  graceful stop — `Child::kill()` **is** SIGKILL — so keying on `.kill()` would
  invert the question, flagging the escalation as though it were the thing
  missing one. The graceful send site in Rust is an explicit `SIGTERM` through
  `libc`/`nix`, so that is what the arm matches.
- **`unpaired-listener` keys on bound sockets and signal handlers.** Rust has no
  DOM-style `addEventListener`; the registrations that genuinely outlive their
  statement and want a teardown are `TcpListener::bind` / `UnixListener::bind`
  and an installed `signal::unix::signal` handler.

`Command::new` will also match `clap::Command::new`, common in Rust CLIs. That is
within this scanner's declared tolerance — every row is `MEDIUM`, a candidate the
LLM pass-2 confirms or dismisses — but it is worth knowing before reading a
report.

Bash (#842, Phase 5) is `M` for two categories and `—` for two, and the two
declines are measurements rather than unwritten arms.

- **`unreaped-subprocess`** keys on a trailing `&`. Its correctness is almost
  entirely its **exclusions**, each measured necessary against this repo's own
  shell corpus (299 tracked `.sh` files, 119,139 lines — the corpus #842 names,
  and the language most of this repo's tooling is written in): `&&` is a control
  operator, `>&` is an fd-dup, and an **assignment-shaped line** is not a command.
  That last exclusion removed the corpus's only false positive,
  `plugins/workflow/hooks/bash-guard.sh:701`, whose `&` sits inside a **trailing**
  comment. `is_comment()` is line-**start** only, so the lexical model cannot
  suppress a trailing comment — the exclusion, not the comment model, is what
  makes this arm clean. Measured after exclusions: **6 rows over the non-test
  corpus, all genuine background jobs, 0 false positives.**
- **`terminate-without-kill`** matches all three SIGTERM spellings —
  `kill -TERM`, `kill -15`, `kill -s TERM` — reading the category the way the
  Rust arm above does: flag the graceful send, let pass-2 confirm the escalation.
  Measured **4 rows**, all real; the two `bounded-run.sh` sites that *do*
  escalate to `-KILL` still emit, correctly, as MEDIUM candidates.
- **`unclosed-handle` is `—`.** The bash analogue would be `exec 3>file` without
  a closing `exec 3>&-`, and that idiom measures **zero** occurrences across the
  whole corpus. An arm for it would be unfalsifiable by this repo's own evidence.
  The issue named a **second** idiom for this cell — a temp file created without
  a `trap … EXIT` to clean it up — and it is refused on the opposite ground, so
  it is recorded separately rather than folded into the sentence above. It is not
  absent but **too common to be a signal**: 123 corpus files call `mktemp`, and
  **48 of them declare no `trap` at all**. Nearly every one of those 48 is
  structurally fine — most are `.`-sourced test **fragments** whose parent entry
  point owns the trap (`tests/golem-scripts/10-launch.sh`,
  `tests/pre-review-gates/98-security.sh` and their siblings), and the rest clean
  up inline or hand the directory to a caller. A single-line regex cannot see any
  of that: the `trap` it is looking for is in a **different file**. At a ~39%
  raw-hit rate whose true positives are indistinguishable without whole-program
  reasoning, this is a `—` by measurement, like the two above it.
- **`unpaired-listener` is `—`.** Bash has no in-process registration outliving
  its statement. `trap` is the nearest shape, but a trap is scoped to the shell's
  own lifetime and needs no paired removal, so flagging it would report the
  correct idiom as the defect.

Both `—` cells are pinned by **silence fixtures**. An empty column is otherwise
unfalsifiable — deleting the cell and adding an arm would both pass — the same
reasoning that pins Swift's empty `debugger` column in `check-code-health`.

**The exclusion is spelled differently in the two runtimes, and that asymmetry is
the phase's parity lesson.** Python applies its regex per line; bash filters the
output of `grep -n`, which carries a `NNN:` prefix, so a `^`-anchored exclusion
written for the source line binds to the **line number** instead and silently
stops excluding. Measured: the first draft let the one corpus false positive
through on the **bash runtime only**. The bash spelling therefore anchors
`^[0-9]+:[[:space:]]*…`, and the helper it rides (`emit_rows_unless`, the inverse
of Phase 4's `emit_rows_word`) records the requirement at its definition. The
`grep -v` stage is deliberately not `-q`: a `-q` exits on first match and
SIGPIPEs the upstream writer, which under this file's `pipefail` reports 141 and
inverts the result.

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-lifecycle-001",
  "category": "unreaped-subprocess",
  "severity": "medium",
  "title": "Subprocess spawned without a visible reap",
  "description": "A subprocess is spawned here with no wait/reap on the same scope. If the paired reap does not run on the error/timeout path, the child can survive as a zombie or orphan — especially when detached onto a persistent side-channel (a socket or named session) that language-level reaping never touches.",
  "file": "src/capture.swift",
  "line_start": 42,
  "line_end": 42,
  "evidence": "let task = Process()",
  "suggestion": "Ensure the process is reaped on every path (waitUntilExit()/.wait()), including error and timeout branches, and torn down explicitly if detached",
  "effort": "small",
  "tags": ["reliability"],
  "related_files": [],
  "certainty": {
    "level": "MEDIUM",
    "support": 1,
    "confidence": 0.7,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-lifecycle"
}
```

## ID Format

`check-lifecycle-<NNN>` (e.g., `check-lifecycle-001`)
