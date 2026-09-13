# Brokered text directive submit verification — issue #974

Records the live evidence for
[#974](https://github.com/joshjhall/librarian/issues/974) ("brokered text
directive lands unsubmitted: `send-keys` with a long payload needs a second
Enter, and no verify step covers the text path").

This file exists because AC #1 asks for the trigger to be **measured rather than
assumed** — the issue explicitly says "the fix differs per cause" and lists four
candidate causes (message length, embedded newlines, bracketed-paste mode,
composer state). The measurement below rules out three of them and identifies
the fourth, and the fix follows from it. None of this is visible from the source:
it is a property of how the composer reads its input stream.

## Method

A raw-mode reader was placed behind a real tmux pane, logging the length of each
`read()` and whether it ended in `\r`. tmux **3.5a** on Linux 7.0.12-linuxkit.
A pane cannot show this — by the time text is painted, the chunking that decides
submit-vs-newline has already happened.

## VERIFIED — live: the trigger

Payload and CR arrive in the **same** `read()` when sent as one `send-keys`:

```text
# tmux send-keys -t probe "<200 chars>" Enter
0.9827 len=201 endswith_CR=True        <- ONE read, payload + CR together
```

Split into two calls, the CR is its own read:

```text
# tmux send-keys -t probe -l -- "<200 chars>" ; tmux send-keys -t probe Enter
len=199 first8=b'OPERATOR' last4=b'xxxx'
len=1   first8=b'\r'       last4=b'\r'   <- CR alone
```

So the composer's paste heuristic treats a CR arriving **inside** an input chunk
as a newline *within* the message rather than a submit. The text stays in the
composer, tmux reports success, and the golem idles until a second `Enter`.

## VERIFIED — live: three candidate causes ruled out

**Not length-dependent.** Reproduced at 200 characters. tmux does split its own
writes at 4095 bytes, but that boundary is unrelated and does not change the
outcome:

```text
N=100   len=101  ... last4=b'xxx\r'     <- one read
N=4090  len=4091 ... last4=b'xxx\r'     <- one read
N=4096  len=4095 ... last4=b'xxxx'      <- tmux's own 4095-byte split
        len=2    ... last4=b'x\r'
N=8000  len=4095 / len=3906 (ends \r)
```

The bug reproduces at 200 chars, well below any split — so length is not it.

**Not bracketed-paste.** No `ESC[200~` wrapper appears in the byte stream at any
size; `tmux send-keys` does not emit one.

**Not embedded newlines.** The measured payloads contained none.

## VERIFIED — live: the existing guard false-confirms

Against a composer simulator reproducing the measured behavior (a CR in its own
read submits; a CR inside a chunk does not), the pre-existing `verify-send`
reports success on exactly this failure:

```text
$ golem-mode-check.sh verify-send 777 "OPERATOR DIRECTIVE: unmet ACs move to new issues." Enter
golem-777 — send confirmed (pane changed)
verify-send rc=0
composer now:
❯ OPERATOR DIRECTIVE: unmet ACs move to new issues.
```

The directive is **still sitting in the composer** while the guard reports
confirmed. Its `_expect_changed` predicate asks only whether the pane differs
from before, and typed-but-unsubmitted text satisfies that — the characters do
appear. This is why the fix is a new subcommand with a different predicate
rather than a tweak to this one: `verify-send` is the #659 modal guard, and
redefining its predicate would change what that guard asserts.

## VERIFIED — live: the fix

```text
$ golem-mode-check.sh verify-text 777 "OPERATOR DIRECTIVE: unmet ACs move to new issues. Use trailer Closes #793."
golem-777 — directive submitted (composer empty)
rc=0
composer now:
❯
reads seen by the app:
read len=74 solo_cr=False
read len=1  solo_cr=True
```

Payload and CR arrive as separate reads; the composer empties; exit 0.

**Dash-leading payload** (what `-l --` buys — operator directives realistically
start with a dash, and a word like "Enter" inside the prose must not be resolved
as a key name):

```text
$ golem-mode-check.sh verify-text 777 "--force: press Enter twice, then -t the target"
golem-777 — directive submitted (composer empty)
rc=0
```

**A composer that never empties** fails loud after the bound rather than
spinning or confirming:

```text
$ golem-mode-check.sh verify-text 778 "a directive"
golem-778 — DIRECTIVE NOT SUBMITTED: the composer did not empty after
  3 submit attempt(s). The text is most likely sitting UNSENT in the
  golem's prompt — it will idle until submitted. Do NOT re-send the payload
  (that would double it). Attach and press Enter: golem-attach.sh 778
rc=1
real 0m4.109s
```

**An occupied composer is refused, non-destructively.** Typing appends, so
relaying onto leftover text would submit one *merged* directive — a decision the
operator never wrote, delivered confidently. That is worse than the bug being
fixed, where the text at least sat visible and unsent:

```text
$ tmux send-keys -t golem-779 -l -- "half-typed operator text"
$ golem-mode-check.sh verify-text 779 "SECOND DIRECTIVE"
golem-779 — NOT SENT: the composer already holds text.
  Typing appends, so relaying now would submit ONE merged directive the
  operator never wrote. Nothing was sent. Attach and clear the prompt,
  then retry: golem-attach.sh 779
rc=1
composer unchanged (nothing appended, nothing submitted):
❯ half-typed operator text
```

The two refusals call for **opposite** operator moves, which is why they are
worded distinctly: `NOT SUBMITTED` means the text is typed and needs an Enter
(re-sending the payload would double it); `NOT SENT` means nothing was typed and
the prompt needs clearing first.

## AC status

| AC | Status |
| --- | --- |
| Determine the actual trigger, measured | **VERIFIED** — same-`read()` CR; length, bracketed-paste, and embedded newlines ruled out |
| Delivered reliably, or payload and submit split | **VERIFIED** — `verify-text` splits them; live run above |
| Delivery verified (composer empty, turn advanced) — not merely that the pane changed | **VERIFIED** — predicate is composer-empty; the `verify-send` false-confirm is pinned as a control test |
| The verify step appears wherever a text directive is sent | **VERIFIED** — `monitor-protocol.md` § Path B (the only free-text recipe) and a pointer in `mode-protocol.md`'s "do not assume a send-keys was delivered" block |
| A test pins the second-keypress case | **VERIFIED** — `test_mode_verify_text_retries_second_enter`, plus six siblings, in `tests/golem-scripts/100-mode-check.sh` |

## Note on the test double

The suite's stub tmux models the measured behavior (a `-l` send types into the
composer; the Nth `Enter` clears it) rather than re-deriving it. The pane
fixtures carry **real** glyph and NBSP bytes — the borrowed classifier anchors on
the prompt-glyph + NBSP *pair*, so a fixture writing either as an escape sequence
would classify `unknown` and the test would pass with **or without** the fix.
Same escaped-fixture-cannot-self-match trap the fragment header already warns
about for the mode footers, one level deeper.
