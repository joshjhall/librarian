---
name: byte-tool-cannot-strip-multibyte
description: A byte-wise sanitizer (tr) silently passes multi-byte Unicode format chars that a codepoint-aware twin (Python isprintable) strips — the two runtimes diverge
metadata:
  type: feedback
---

`tr -d` operates on BYTES. It can strip ASCII C0 controls and DEL, and it cannot
express a Unicode format character at all: U+202E RIGHT-TO-LEFT OVERRIDE is the
three bytes `E2 80 AE`, none of which fall in any C0 range. A Python twin using
`str.isprintable()` rejects category **Cf** for free and strips it. Same intent,
two runtimes, different results — and no error from either.

**Measured (#816).** A guard sanitized the line it echoed back. bash used
`tr -d '\000-\010\013-\037\177'`; Python used an `isprintable()` filter. ASCII
controls agreed perfectly; RTLO survived in bash and was stripped in Python —
on precisely the fallback path the bash body exists to serve.

**The portable fix is an enumerated alternation, not a character class.**
`tr -d '[:cntrl:]'` is locale-dependent and C0-only in the C locale. Build the
byte sequences with `printf` as LITERAL UTF-8 and match them with `sed -E`:
`\xNN` escapes are a GNU extension that BSD sed reads as literal text, which
turns the strip into a silent no-op ([[gnu-host-cannot-mutate-a-gnu-ism]]).
Use an alternation rather than a bracket class — a bracket over multi-byte
sequences matches byte-wise and can split a character. The set worth covering:
zero-width U+200B-200F, bidi U+202A-202E and U+2066-2069, BOM U+FEFF.

**How to measure it — three probes that lie.** (1) Grepping COMBINED stdout+stderr:
the raw text often appears on stdout too and masks the stderr difference. Compare
**stderr only**. (2) `od` piped through `tr -s ' '`: the squeeze mangles the
offset columns and the byte grep misses. Use `cat -v`. (3) A fixture written with
`‮` or `\033` as backslash text: inert, cannot self-match, passes with and
without the fix ([[escaped-fixture-cannot-self-match]]). Generate the fixture
from code points.

**How to apply:** whenever a sanitizer exists in two runtimes, test the
multi-byte case explicitly — parity over ASCII proves nothing about Cf, and a
stdout-comparing parity gate cannot see a stderr difference at all
([[parity-blind-to-exit-code-divergence]]).
