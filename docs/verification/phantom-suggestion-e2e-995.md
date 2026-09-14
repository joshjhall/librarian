# Phantom suggestion: Enter and clearing — issue #995

Records the live evidence for
[#995](https://github.com/joshjhall/librarian/issues/995) ("phantom suggestion:
can `Enter` submit one, and can the line be cleared without reaping?"), the
follow-up to [#977](https://github.com/joshjhall/librarian/issues/977).

Issue #977 settled *what* the phantom `❯` line is — Claude Code's autocomplete
suggestion, rendered in SGR 2 (dim) — but could not answer two questions,
because a suggestion **would not reproduce on demand** in a disposable session.
This file answers both, plus the induction recipe the issue named as the real
first task.

## Method

Two disposable tmux sessions, created and torn down for this measurement. No
keystroke was ever sent to a live `golem-*` session.

- `phantom-probe-995` in `/tmp/phantom-probe-995`, launched with
  `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1`
- `phantom-ctl-995` in `/tmp/phantom-probe-ctl`, launched with **no** such
  variable (the control — see "the env var is not the lever" below)

Claude Code **v2.1.270**, tmux **3.5a**, Linux 7.0.12-linuxkit, 2026-09-13.

The composer was classified with the **real** shipped classifier rather than by
eye, so the measurement exercises the same parse the fleet readers use:

```bash
. plugins/workflow/scripts/golem-gate-watch.sh
pane_prompt_line_class phantom-probe-995
```

Submission was confirmed against the session **transcript**
(`~/.claude/projects/<project>/*.jsonl`), not the pane — a pane shows text, only
the transcript shows what was actually submitted as a user turn.

## VERIFIED — live: the induction recipe (AC 4)

A suggestion appears after an **ordinary completed turn** when the session then
sits idle at an empty composer. That is all it takes:

```text
$ tmux send-keys -t phantom-probe-995 -l -- "Read README.md and tell me in one sentence what it says."
$ tmux send-keys -t phantom-probe-995 Enter
  ... turn completes ...
$ pane_prompt_line_class phantom-probe-995
suggestion
$ tmux capture-pane -p -t phantom-probe-995 | grep '❯' | tail -1
❯ now ask me that caching question again, in plain text
```

The raw bytes are the #977 shape exactly — dim run, glyph + NBSP prefix:

```text
^[[39mM-bM-^]M-/M-BM- ^[[2mnow ask me that caching question again, in plain text^[[0m
```

**Reproducibility: 3/3.** Three consecutive fresh turns, each followed by a
single classifier read ~14s later:

```text
trial 1 -> suggestion
trial 2 -> suggestion
trial 3 -> suggestion
```

**Why #977 could not do this.** Its probe session was driven to *idle* without
first completing an ordinary turn — and one shape that reliably does **not**
produce a suggestion is a turn that ends in a **selection menu**. The first
induction attempt here ended in `AskUserQuestion`'s menu and classified
`unknown` for 12 consecutive polls (2 minutes):

```text
t=10s class=empty
t=20s class=unknown
...
t=120s class=unknown
```

Escaping that menu to reach a real idle prompt, then running one plain turn,
produced a suggestion on the **next** poll.

### The env var is NOT the lever — a corrected hypothesis

The probe session was launched with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1` on
the theory that a growthbook flag gates the feature. **The control disproves
that.** `phantom-ctl-995`, with the variable entirely absent, showed a
suggestion on its second poll after one ordinary turn:

```text
CONTROL SHOWED SUGGESTION at poll 2 (env var is NOT the lever)

$ tmux capture-pane -p -e -t phantom-ctl-995 | grep '❯' | tail -1
^[[39mM-bM-^]M-/M-BM- ^[[2mwhat else is in this directory?^[[0m
$ pane_prompt_line_class phantom-ctl-995
suggestion
$ tr '\0' '\n' < /proc/<claude-pid>/environ | grep -c PROMPT_SUGGESTION
0
```

Recorded because it matters for anyone reproducing this: the recipe is the
completed-turn-then-idle state, and it needs no special launch flag. A golem
does this constantly, which is why phantoms show up on real golems.

## VERIFIED — live: `Enter` does NOT submit a suggestion (AC 1)

**This is the question the whole hazard framing rested on, and the answer is
no.**

A bare `Enter` against a displayed suggestion leaves it displayed and starts no
turn:

```text
before:  suggestion
         ❯ now ask me that caching question again, in plain text
$ tmux send-keys -t phantom-probe-995 Enter
after:   suggestion
         ❯ now ask me that caching question again, in plain text
```

Repeated — four `Enter` presses in total across two trials — with the transcript
unchanged throughout. The submitted user turns after all four:

```text
'I want to add a caching layer to this project. Ask me one clarifying question...'
''
''
'[Request interrupted by user for tool use]'
'Read README.md and tell me in one sentence what it says.'
```

No phantom text among them.

**Replicated on the control session**, independently and without the env var:

```text
baseline: suggestion | ❯ what else is in this directory?
$ tmux send-keys -t phantom-ctl-995 Enter   (x2)
after:    suggestion | ❯ what else is in this directory?

control transcript user turns:
  'Read README.md and tell me in one sentence what it says.'
  ''
```

### The broker's actual payload submits the DIGIT, not the suggestion

The plan-gate broker does not send a bare `Enter` — it sends `1 Enter`. Measured
against a displayed suggestion:

```text
$ tmux send-keys -t phantom-probe-995 1 Enter
class after: empty
pane:
  ❯ 1
  * Levitating…

transcript user turns now end with:
  'Read README.md and tell me in one sentence what it says.'
  '1'
```

The `1` was submitted; the suggestion text was **discarded**, never entering the
transcript. Typing a printable character replaces the ghost text rather than
appending to it — so the broker's digit both dismisses the suggestion and
submits the intended answer, which is precisely the desired behavior.

**Consequence: the hazard is theoretical, and AC 2 does not fire.** No broker
guard is needed, and this issue's severity is not raised. A stray `Enter` cannot
submit `merge it once CI is green`; a brokered `1 Enter` submits `1`.

## VERIFIED — live: nothing clears the line short of reaping (AC 3)

Every candidate, each against a freshly displayed suggestion. The honest answer
the issue asked for is **none does**:

| Keystroke | Result |
| --- | --- |
| `Esc` | still `suggestion`, text unchanged |
| `Esc Esc` | still `suggestion`, text unchanged |
| `C-u` (the known control) | still `suggestion`, text unchanged |
| `C-c` | still `suggestion`, text unchanged |
| `x` then `BSpace` | suggestion returns |
| `x` then `C-u` | `input` while typed, then suggestion returns |
| `Right` then `C-u` | `input` while accepted, then suggestion returns |
| submit a real turn | replaced by a **new** suggestion |

Two of these are informative beyond the verdict:

**Typing hides it; clearing brings it back.** The suggestion is display state
that survives composer edits:

```text
after 'x' typed: input
❯ x
after C-u:       suggestion
❯ yes, in-memory LRU with TTL
```

**`Right` accepts it into the real draft** (the accept binding — the class flips
from `suggestion` to `input` with the same visible text), but clearing that real
text re-displays the suggestion:

```text
after Right:  input
❯ yes, in-memory LRU with TTL
after C-u:    suggestion
❯ yes, in-memory LRU with TTL
```

It does not time out either — polled for 10s after a clear, it was back
immediately and stayed:

```text
t+1s: suggestion | ❯ yes, in-memory LRU with TTL
t+3s: suggestion | ❯ yes, in-memory LRU with TTL
t+6s: suggestion | ❯ yes, in-memory LRU with TTL
t+10s: suggestion | ❯ yes, in-memory LRU with TTL
```

Submitting a real turn does not dispose of it — it just earns a fresh one:

```text
$ tmux send-keys -t phantom-probe-995 -l -- "say ok" ; tmux send-keys ... Enter
after turn: suggestion
❯ in-memory cache, go ahead and plan it
```

So reaping the session remains the only known disposal — but since the line is
now measured **inert**, disposal is cosmetic rather than a safety need.

## AC status

| AC | Status |
| --- | --- |
| Determine whether `Enter` submits a suggestion — disposable session only | **VERIFIED — it does not.** Four bare `Enter`s across two sessions (one without the env var); transcript unchanged. The broker's `1 Enter` submits the digit `1` and discards the suggestion |
| If it does: add a broker guard and raise severity | **N/A — does not fire.** `Enter` cannot submit one, so no guard is needed and severity is unchanged |
| Determine whether any keystroke clears the line without reaping | **VERIFIED — none does.** `Esc`, `Esc Esc`, `C-u`, `C-c`, type+`BSpace`, type+`C-u`, `Right`+`C-u` all leave or restore it; a real turn replaces it with a new one |
| Find a reliable way to induce a suggestion | **VERIFIED — 3/3.** One ordinary completed turn, then idle at an empty composer. Needs no env var; a turn ending in a selection menu does **not** work, which is why #977 could not reproduce it |
| Update `.claude/memory/phantom-prompt-buffer-text.md` | **DONE** — the "Still unverified" section is replaced with these results |

## Caveat, carried forward from #977

All of this is measured against **one** host's Claude Code build (v2.1.270). The
accept binding, the ghost-text rendering, and the empty-draft submit guard are
implementation details that can change. If the TUI changes how suggestions are
rendered or accepted, the failure mode is **silent** — the annotation stops
appearing, and the inertness measured here would need re-checking. Worth
re-running this recipe after a client upgrade; it now takes about a minute.
