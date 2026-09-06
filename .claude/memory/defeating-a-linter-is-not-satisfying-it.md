---
name: defeating-a-linter-is-not-satisfying-it
description: Prefer a gate's documented exemption marker over a trick that hides the line from its regex
metadata:
  type: feedback
---

When a lint gate fires on a line that is legitimately fine, use the gate's
**documented exemption**, not a spelling that hides the line from its matcher.
Writing `_direct="/bin""/sh"` to dodge `lint-shell-portability.sh`'s
hardcoded-path regex works only because the interposed quote breaks the pattern —
`tests/lint-shell-portability.sh` already ships
`# lint-allow-path: <reason>` for exactly this case, and its own comment says the
marker "must carry a reason so the exemption is justified, not silent."

**Why:** both forms go green, but they leave opposite artifacts. The marker
states the exemption and its reason where the next reader will look; the quote
trick states nothing and requires decoding to even recognize as deliberate — and
it silently stops working (or keeps working for the wrong line) if the pattern
changes. An exemption nobody can see is indistinguishable from a violation
nobody caught.

**How to apply:** when a gate fires, first read the gate's own source for an
escape hatch — most in this repo have one and document its contract. Only if
there is none should you change the spelling, and then say why in a comment. Note
a copied sibling using the trick is not authority: it may predate the marker, and
copying it spreads the invisible form ([[harden-one-knob-grep-every-sibling]]).
