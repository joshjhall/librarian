# BSD regex-dialect verification — issue #684

Records the live macOS/BSD evidence for
[#684](https://github.com/joshjhall/librarian/issues/684)
("finish the BSD-portability pass left open by #679"), item **1** (the `\b`
word-boundary audit) and item **3** (whether the `patterns.py` primaries diverge
from the corrected bash).

This file exists because the finding **cannot be reproduced in-session**: every
development host in this project runs GNU userland, where every `\b` row reads
`SUPPORTED` and proves nothing about BSD. The evidence below comes from the
`bsd-probe` job on `macos-latest` — the repo's only BSD userland, added by this
issue precisely to obtain it.

## Why the question needed measuring at all

Issue #679 swept `\s`/`\S`/`\w`/`\W`/BRE `\|`/`grep -P` out of the shell scanners
because BSD `grep`/`sed` read them as **literals**: the pattern silently stops
matching, the scanner emits zero rows, and the scan still exits 0 — macOS sees a
clean report of nothing.

`\b` was **excluded on purpose** from that sweep: modern BSD `grep -E` was
*believed* to support it, and 38 sites depend on it, so a rewrite was worth doing
only against an observed failure. #684 asked for that belief to be *confirmed
rather than assumed* — explicitly "on a real macOS host (BSD `grep -E` **and**
BSD `sed`, which may differ from each other) — not on a Linux box."

## The run

- **Job**: `BSD/macOS regex probe (informational)` — `.github/workflows/ci.yml`
- **PR**: [#689](https://github.com/joshjhall/librarian/pull/689),
  [run 31740702257](https://github.com/joshjhall/librarian/actions/runs/31740702257/job/94583133581)
- **Host**: `Darwin 25.5.0`, `arm64` (`RELEASE_ARM64_VMAPPLE`)
- **grep**: `grep (BSD grep, GNU compatible) 2.6.0-FreeBSD`
- **sed**: no `--version` (BSD-style) — the absence *is* the identification
- **Result**: job **passed**; POSIX baseline held

## VERIFIED — live

Transcribed verbatim from the job log:

```text
== POSIX baseline (must hold everywhere) ==
  [ ok ] [[:space:]] under grep -E                      SUPPORTED
  [ ok ] [[:space:]] under grep (BRE)                   SUPPORTED
  [ ok ] [[:alnum:]_] under grep -E                     SUPPORTED
  [ ok ] ERE alternation (a|b)                          SUPPORTED
  [ ok ] grep -w matches a whole word                   SUPPORTED
  [ ok ] grep -w rejects a partial word                 SUPPORTED
  [ ok ] [[:space:]] under sed -E                       SUPPORTED

== Word boundaries (the #684 question) ==
  [info] \b under grep -E   (32 sites)                  SUPPORTED
  [info] \b under grep (BRE)  (6 sites)                 SUPPORTED
  [info] \b -E rejects partial word                     UNSUPPORTED  (UNSUPPORTED here means correct)
  [info] \b under sed -E                                UNSUPPORTED
  [info] [[:<:]] / [[:>:]] under grep -E                SUPPORTED

== GNU-only constructs (#679 banned these; all should be UNSUPPORTED on BSD) ==
  [info] \s under grep -E                               SUPPORTED
  [info] \w under grep -E                               SUPPORTED
  [info] BRE \| alternation                             SUPPORTED  (SUPPORTED on GNU = alternation)
  [info] grep -P (PCRE)                                 ERROR

== Verdict ==
  POSIX baseline holds on this host.
```

## What it establishes

| Question | Answer | Consequence |
| --- | --- | --- |
| `\b` under `grep -E` (32 sites) | **SUPPORTED** | safe; no port needed |
| `\b` under plain `grep`/BRE (6 sites) | **SUPPORTED** | safe; the `grep -w` fallback is not needed |
| `\b` under `sed -E` | **UNSUPPORTED** | a real hazard — but **zero sites** use it |
| `[[:<:]]` / `[[:>:]]` | **SUPPORTED** on BSD (GNU: `ERROR`, exit 2) | confirms no single portable spelling exists |
| `grep -P` | **ERROR** | confirms #679's outright ban |

**Item 1 resolves to AC#3**: all 38 sites are genuinely safe, so `\b` gets a
**documented exemption** in `tests/lint-shell-portability.sh` rather than a
port. `tests/lint-shell-portability.sh`'s `test_word_boundary_exemption_is_pinned`
pins it so a future tightening of `GNURE_BAD_RE` cannot flag 38 working sites on
reasoning that a GNU host cannot check.

### The one genuine discovery: BSD `sed` differs from BSD `grep`

The issue anticipated this ("BSD `grep -E` **and** BSD `sed`, which may differ
from each other") and it was right. On the same host, the same construct is
supported by `grep` in both dialects and **unsupported by `sed`**.

No site uses `\b` in a `sed` expression today, so nothing needed porting — which
makes this a **documented known gap, not a regression**. The ban is scoped to the
constructs #679 swept and does **not** catch `\b`, so a future
`sed -E 's/\bfoo\b/bar/'` would silently stop substituting on macOS and no gate
would notice. The exemption comment and the pinning test both record this
explicitly.

### Also confirmed: the probe can tell the platforms apart

The GNU-only rows are the control. `grep -P` returns **ERROR** on BSD where it
returns SUPPORTED on GNU, and `[[:<:]]` inverts (SUPPORTED on BSD, ERROR on GNU),
so the probe demonstrably distinguishes the two userlands rather than reporting
`SUPPORTED` for everything.

> Note the `\s`/`\w`/BRE `\|` rows read **SUPPORTED** here. That is not a
> contradiction of #679: this host's grep self-identifies as *"BSD grep, GNU
> compatible"* and accepts those extensions. #679's failures were observed via
> **BSD `sed`**, and `\b under sed -E → UNSUPPORTED` on this very host is the
> direct confirmation that the sed side is where the dialect gap actually bites.
> A GitHub `macos-latest` image is one data point, not every macOS host — a
> stock or older BSD `grep` may still differ, which is why the `grep -w` fallback
> is documented and probe-verified on both platforms rather than discarded.

## Item 3 — the parity gate's blind spot

The probe does not settle item 3 by itself; the finding that does is recorded in
`tests/validate-python-ports.sh`'s header and was found while auditing for it.

`validate-python-ports.sh` pins bash↔python byte-identical TSV output, and it
stayed **green** across a live defect: the Go no-assertions pattern carried the
same wrong trailing `\b` in `patterns.sh` **and** `patterns.py`, rejecting
`t.Errorf`/`t.Fatalf`/`t.Logf`. Parity compares the two impls to each other, never
to intended behaviour, so an identical bug is invisible **by construction** —
same-output, not same-intent. Only a fixture asserting the *intended* match
catches that class, which is why the regression cases live in the per-detector
suites.

For the BSD half of item 3: `validate-python-ports.sh` now also runs in the
`bsd-probe` job, so a divergence that appears only under BSD semantics surfaces
there rather than being unreachable. It passed on this run.

## Follow-up

None required for item 1 — the disposition is settled and pinned. The `sed` gap
is documented rather than gated; if a `\b`-in-sed site is ever introduced, extend
`GNURE_BAD_RE` to cover `sed` specifically (not `grep`, which this evidence
exempts).
