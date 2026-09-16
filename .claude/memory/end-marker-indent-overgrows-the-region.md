---
name: end-marker-indent-overgrows-the-region
description: "A delimiter-terminated region fails ASYMMETRICALLY — a moved START marker errors loud, a moved END marker silently swallows the following text"
type: feedback
metadata:
  node_type: memory
  originSessionId: c5ce24e2-e77c-45fa-a057-bc727ea834d8
  modified: 2026-08-28T00:16:48.427Z
---

Any extraction bounded by a start and an end delimiter has two failure modes,
and only one of them is loud:

- **Start delimiter moves/breaks** → the extractor cannot find the region and
  fails loudly. Fine, if misleadingly worded.
- **End delimiter moves/breaks** → the region does not terminate. It
  **over-grows** into whatever follows, and every `contains`-style assertion
  still passes, because a bigger region still contains its tokens.

Measured on #737 against `extract_contract` (tests/lib/harness.sh), whose
terminator is `index($0, "<!-- contract:") == 1`: indenting an end marker by two
spaces left all six tests PASSING. A tamper check does not save you here —
`assert_contract_carries` proves the token is genuinely present, not that the
region ended where it should.

**Why it hides:** assertions on a region are almost always
existence assertions. Existence is monotonic in region size, so every check gets
*easier* to satisfy as the region grows. The failure enlarges the haystack rather
than removing the needle.

**How to apply:** pin the **end** delimiters too, not just the ids naming the
regions — same shape as the start check. Where the extractor requires
column-0 delimiters, assert that explicitly. And test it: indent the end marker
and confirm something fails. Region-bounding assertions (a length or exclusion
check — "the region must NOT contain the text after it") are the other half.

**A validity check is NOT a bound, and reaching for one instead is the trap.**
Confirmed again on #825, extracting a shell function by `sed -n '/^f() {/,/^}$/p'`:
adding **one trailing space** to the closing brace grew the capture from 3 lines
to 56 — the range ran on to the next bare brace — and the case still passed. A
`bash -n` guard was already in place and could not see it, because N concatenated
function definitions parse exactly as cleanly as one. Same for JSON, YAML, or any
grammar where the over-grown text is still well-formed. **Only a length bound
distinguishes over-growth**; pair it with the validity check rather than choosing
between them.

**A third arm: the end anchor's own definition can be unreliable, with nothing
having drifted at all.** Confirmed again on #786, mutation-testing
`tests/lint-truncation-markers.sh`'s detector for `truncate_chars`'s `…`
marker: `sed -n '/^def truncate_chars/,/^[a-zA-Z_@]/p' "$f" | grep -qE '…'`
stayed green even after the marker was reverted to a silent
`s[:EVIDENCE_CAP]`, because the range never terminated at the function's true
end and swept in an unrelated `…` sitting in a prose comment far below
(measured: `plugins/review-audit/skills/check-lifecycle/patterns.py:259`). No
delimiter moved — "next top-level def/decorator line" is simply not a reliable
function-boundary signature on its own: it can stop early (a blank line inside
a docstring satisfies nothing, so the range keeps going) or run long (no
matching line for hundreds of lines). **Where a single line inside the intended
region already distinguishes it, anchor on that line directly and drop the
range entirely** — `^ *return s\[: *[A-Za-z_]+ - 1\]` needs no end delimiter at
all and cannot inherit this failure mode.

Also make the end pattern tolerate how the delimiter really drifts — trailing
whitespace, an inline comment — since over-tightening it is itself a way to stop
matching. But tolerance needs its own divergence arm (an *indented* delimiter
must still be rejected), or blanket acceptance passes every positive case while
capturing to EOF. And put a **decoy** after the region in the fixture: against
EOF alone, a broken end pattern stops at the same line as a correct one and the
test proves nothing.

Related: [[prose-contract-anchored-to-prose]] for why ids beat headings in the
first place; [[gate-and-evidence-converge-tautology]] for the sibling shape where
a check gets easier to satisfy for a different reason;
[[green-suite-is-not-evidence-until-mutated]] for the general habit that surfaced
all three instances of this file.
