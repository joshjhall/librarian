# OWASP coverage — end-to-end verification (#705)

Evidence for epic #705, "OWASP coverage is claimed but unmapped, under-detected,
and absent from the review path". Everything below marked **VERIFIED — live**
was executed in-session on 2026-09-09 and the output is transcribed as observed.

An epic is the one issue whose acceptance no single PR can demonstrate: its
criteria are satisfied by the *combination* of its slices, and each slice's own
tests only pin its own half. #705's four slices all merged green, and nothing in
the tree recorded that anyone had run the combined check. This file is that
check.

## What landed

| slice | issue | artifact                                                              |
| ----- | ----- | --------------------------------------------------------------------- |
| A     | #706  | `check-security/owasp-coverage.yml` + `tests/validate-owasp-coverage.sh` |
| B     | #707  | the missing detectors in `check-security/patterns.{py,sh}`             |
| C     | #708  | the security pre-scan arm in `ship-issue/pre-review-gates.sh`          |
| D     | #709  | `check-security/pass2-checklist.md` (moved out of `audit-security.md`) |

The epic opened with three gaps, one per layer: no taxonomy (A), a pre-scan
covering 4 narrow categories (B), and a review path whose `security` dimension
got zero deterministic rows (C). D closed the LLM-pass half of the taxonomy.

## The fixture

Three files' worth of defect in one, holding **exactly** the three examples the
epic's second acceptance bullet names — no more, so a pass cannot come from an
unrelated detector firing:

```python
import subprocess, yaml, os
AWS_KEY = "AKIA<16-CHARS-REDACTED>"
def run(user):
    subprocess.run(f"ls {user}", shell=True)
def load(s):
    return yaml.load(s)
```

Scanned via a one-line file list (`/tmp/owasp705/list.txt`), which is the
scanner's input contract (`$1` = a file of paths, one per line).

**One deliberate edit to the transcripts below.** The real fixture used the
canonical AWS example key (`AKIA` + `IOSFODNN7EXAMPLE`); every appearance in this
file — in the fixture above and in the captured output — is rewritten to
`AKIA<16-CHARS-REDACTED>`. This is the only alteration, and it is disclosed
rather than silent because the rest of the file's value depends on being
verbatim.

The reason is measured, not hypothetical. The AKIA detector is **lexical-
independent** by design — `patterns.sh` states that a leaked key "is interesting
wherever it appears, arguably MORE so inside a comment" — so a contiguous key
in this file is a true positive, not a scanner bug. Committed unredacted, this
document added **4 permanent HIGH `hardcoded-secret` rows** to the repo's own
scan (verified: `pre-review-gates.sh` over the staged diff emitted exactly those
four). An epic about making a security scan trustworthy must not be the change
that teaches readers its HIGH rows are noise.

The repo already has this idiom: `tests/validate-python-ports.sh` assembles its
fake tokens from fragments (`AWS_TOK="AKIA""0123456789ABCDEF"`) for the same
reason — the fixture on disk carries the contiguous token the scanner must
match, while the checked-in file does not. Redaction is the prose equivalent.
To reproduce, substitute any `AKIA` + 16 uppercase alphanumerics.

## AC#1 — every Top 10 entry has an explicit row

`plugins/review-audit/skills/check-security/owasp-coverage.yml` carries A01–A10,
each category `owner:` one of `prescan` / `llm-pass2` / `reviewer` / `gap`.

**VERIFIED — live.** The gate that enforces it, including its 14 negative
self-tests:

```console
$ bash tests/validate-owasp-coverage.sh; echo "exit=$?"
=== OWASP Top 10 coverage map (#706) ===
  map and scanner source both parse non-empty ... PASS
  rule 1: every A01-A10 id present exactly once ... PASS
  rule 2a: every prescan id is a category the scanners emit ... PASS
  rule 2b: every emitted category is mapped (catches a rename) ... PASS
  rule 3: llm-pass2 / reviewer claims appear in their checklist ... PASS
  rule 4: every gap carries a non-empty reason ... PASS
  every entry's owner is one of the four known values ... PASS
  every category entry has a non-empty id ... PASS
  self-test: the valid fixture passes clean ... PASS
  self-test: a deleted A0x block fails rule 1 ... PASS
  self-test: an unemitted prescan id fails rule 2a ... PASS
  self-test: an unmapped emitted category fails rule 2b ... PASS
  self-test: an unbacked llm-pass2 claim fails rule 3 ... PASS
  self-test: an empty gap reason fails rule 4 ... PASS
  self-test: a duplicated A0x block fails rule 1 ... PASS
  self-test: an unbacked reviewer claim fails rule 3 ... PASS
  self-test: a typo'd owner value is rejected ... PASS
  self-test: a gap cannot absorb a shipping detector ... PASS
  self-test: a blank category id fails loudly ... PASS
  self-test: an omitted owner key is rejected ... PASS
  self-test: a missing Pass-2 companion is named, not blamed on every claim ... PASS
  self-test: a missing reviewer harness is named, not blamed on every claim ... PASS

Summary
  Total:   22
  Passed:  22
  Failed:  0
  Skipped: 0
exit=0
```

Rule 2b is the one that makes the claim un-rottable in the direction that
matters: it fails on a category the scanners emit but the map does not list, so
a **new** detector cannot land unmapped. Rule 2a covers the other direction (a
renamed detector orphaning its row). Dispatched by `tests/shards/30-scanners.sh`
line 77, so it gates CI and pre-push.

## AC#2 — the three named examples produce deterministic rows

**VERIFIED — live**, at all three layers.

The scanner, both runtimes, and their parity:

```console
$ bash plugins/review-audit/skills/check-security/patterns.sh /tmp/owasp705/list.txt; echo "exit=$?"
/tmp/owasp705/bad.py	2	hardcoded-secret	AWS access key pattern: AWS_KEY = "AKIA<16-CHARS-REDACTED>"	HIGH
/tmp/owasp705/bad.py	4	command-injection	Subprocess with shell=True:     subprocess.run(f"ls {user}", shell=True)	HIGH
/tmp/owasp705/bad.py	6	insecure-deserialization	Unsafe deserialization of untrusted data:     return yaml.load(s)	HIGH
exit=0

$ python3 plugins/review-audit/skills/check-security/patterns.py /tmp/owasp705/list.txt; echo "exit=$?"
/tmp/owasp705/bad.py	2	hardcoded-secret	AWS access key pattern: AWS_KEY = "AKIA<16-CHARS-REDACTED>"	HIGH
/tmp/owasp705/bad.py	4	command-injection	Subprocess with shell=True:     subprocess.run(f"ls {user}", shell=True)	HIGH
/tmp/owasp705/bad.py	6	insecure-deserialization	Unsafe deserialization of untrusted data:     return yaml.load(s)	HIGH
exit=0

$ diff <(bash …/patterns.sh …) <(python3 …/patterns.py …) && echo identical
identical
```

Two of these three categories did not exist before slice B: `command-injection`
and `insecure-deserialization` are #707's. Only `hardcoded-secret` was among the
four the epic found.

The **review path** — the layer the epic's third gap was about. The same three
rows reach `ship-issue`'s pre-review handoff, which before #708 received nothing
deterministic for `security` at all:

```console
$ bash plugins/workflow/skills/ship-issue/pre-review-gates.sh /tmp/owasp705/list.txt
/tmp/owasp705/bad.py	2	hardcoded-secret	AWS access key pattern: AWS_KEY = "AKIA<16-CHARS-REDACTED>"	HIGH
/tmp/owasp705/bad.py	4	command-injection	Subprocess with shell=True:     subprocess.run(f"ls {user}", shell=True)	HIGH
/tmp/owasp705/bad.py	6	insecure-deserialization	Unsafe deserialization of untrusted data:     return yaml.load(s)	HIGH
```

### The refusal path is part of AC#2, not extra

A `prescan` row in the coverage map asserts "a scanner will catch this". On a
machine where `review-audit` is not installed — it installs independently of
`workflow` — that assertion would otherwise be satisfied by silence, since zero
rows from an absent scanner and zero rows from a clean diff are the same bytes.
That is the #538/#571 inert-gate shape reached through the plugin boundary, so
it is verified explicitly rather than assumed:

```console
$ SECURITY_SCANNER=/nonexistent/patterns.sh bash …/pre-review-gates.sh /tmp/owasp705/list.txt
exit=1

# stdout:
-	0	security-scan-unavailable	SECURITY PRE-SCAN DID NOT RUN (scanner not found) — this scan's silence is NOT a clean result	HIGH

# stderr:
Error: pre-review-gates.sh: the security pre-scan did not run: scanner not found
  Resolved to: /nonexistent/patterns.sh
  check-security/patterns.sh ships with the 'review-audit' plugin, which
  installs independently of 'workflow'. Install it with:
      claude plugin install review-audit@librarian
  or point SECURITY_SCANNER at the scanner explicitly.
  Refusing to exit 0: a security scan that finds nothing because it did not
  run is indistinguishable from a clean diff, which is the outcome this gate
  exists to prevent.
```

All three channels carry it — marker row, exit code, stderr — because a pipeline
drops the status (#854) and a `2>/dev/null` drops the message. Note the fixture
forces absence via `SECURITY_SCANNER` rather than skipping when the tool is
missing, so the refusal path is exercised on every run instead of only on a
machine that happens to lack the plugin.

## AC#3 — parity, portability, suite green

Pinned by gates that already run, so this file adds no assertion of its own:
`tests/validate-python-ports.sh` (bash↔python TSV parity),
`tests/lint-shell-portability.sh` (bash-3.2, no GNU-only regex/env/flags), and
`tests/validate-source-detectors.sh` (detector fixtures). The parity `diff`
above is the same contract checked against this specific fixture.

## The two `gap` rows, and why they satisfy AC#1

Quoting #705's acceptance bullet verbatim, so this does not rest on a
paraphrase — the third disposition is offered by the criterion itself, not read
into it:

> Every OWASP Top 10 (2021) entry has an explicit row in the coverage map:
> covered-by-prescan, covered-by-LLM-pass, or an acknowledged `gap:` with a
> reason.

The epic's *title* says "under-detected", and for A01/A10 at the deterministic
layer that remains literally true — which is exactly why both are `gap` rows
pointing at #898 rather than being quietly marked covered. The title states the
problem; the bullet above states the bar for closing it, and a disclosed,
measured gap clears that bar by construction. Anyone auditing this later should
read the two rows as "measured, declined at this tier, tracked", never as
"done".

AC#1 admits three dispositions: covered-by-prescan, covered-by-LLM-pass, **or**
an acknowledged `gap:` with a reason. Two rows take the third:

| row                            | entry | follow-up |
| ------------------------------ | ----- | --------- |
| `path-traversal-prescan`       | A01   | #898      |
| `ssrf`                         | A10   | #898      |

Both were **measured, not deferred**. #707 built the same-line
"argument derives from a request symbol" proxy and scored it on a 753-file
corpus: path-traversal returned **0 true positives in 7 hits** — every hit
`open(sys.argv[N])` in a test heredoc, with request-derived = 0 and argv = 7, so
the arm's entire yield came from its weakest token; SSRF returned **0 in 1**, a
health-check whose host is a literal. Per `contract.md`, a detector whose
measured hit rate cannot support its tier does not ship at that tier, and this
supports neither HIGH nor MEDIUM. Both need a multi-line taint model, which is
what #898 scopes.

Neither entry is uncovered, only un-*prescanned*: A01 carries `path-traversal`
(reviewer) and `path-traversal-pass2`, A10 carries `ssrf-reviewer` and
`ssrf-pass2`. The paired rows are deliberate — "an LLM might notice it" and "a
scanner will catch it" are different claims, and listing both is what keeps the
map from overstating either.

A gap reason is most useful when it records a measurement rather than an
intention: "no detector yet" ages into "nobody got to it", while "0 true
positives in 7 hits, request-derived = 0" tells the next person what to do
differently and what bar to clear.

## Verdict

All three acceptance bullets are satisfied by the four merged slices. #705 is
closed; #898 remains open on its own acceptance and is not a blocker — it is the
follow-up the epic's own `gap` rows name.
