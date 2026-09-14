# `splitlines()` call-site survey — issue #980

Acceptance criterion 3: *"The survey covers all 16 `splitlines()` call sites;
each is either changed or explicitly recorded as not applicable."*

The issue counted 16 sites via `fh.read().splitlines()`. A full sweep
(`grep -rn 'splitlines()' plugins/ --include=*.py`) found **26 sites across 21
files** — the extra ten are `read_text().splitlines()` on JSONL transcripts, a
`str.splitlines()` on an in-memory value, and second sites in files the issue
counted once. Every one is dispositioned below.

## The defect, restated

The bash fallbacks reach every line through `grep -n`, which splits on `\n`
**only**. `str.splitlines()` additionally splits on `\r`, `\x0b`, `\x0c`,
`\x1c`–`\x1e`, U+2028 and U+2029. On a file carrying any of those mid-line the
two runtimes disagree on how many lines the file has, diverging the `line` and
`evidence` fields together.

**The issue's proposed fix is insufficient**, and was measured so. Python's
universal-newline translation runs inside `read()`, *before* any split — a lone
`\r` is already rewritten to `\n` in the buffer:

```python
open(p).read()                          # 'x = 1\npassword = "s"\n'  CR already gone
open(p).read().split("\n")              # ['x = 1', 'password = "s"', '']   2 lines
open(p, newline="").read().split("\n")  # ['x = 1\rpassword = "s"', '']     1 line
```

`.split("\n")` alone fixes the form-feed case and **silently leaves the lone-CR
case broken** — the issue's headline example. The read must pass `newline=""`.

## The shape applied

```python
def read_lines(path: str) -> list[str]:
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines
```

A CRLF's `\r` **stays in the line** — grep keeps it too, and GNU grep's `^---$`
correctly does *not* match a `---\r` line. Stripping it per-line would silently
change every `$`-anchored regex in every scanner. It comes off at the evidence
cap instead, via `strip_eol_cr()`, mirroring what the bash `truncate_chars` has
done since #902. Without that second half, fixing the line number
**regresses #902**: measured, python emitted a trailing `^M` in the evidence
column.

## Verified equivalence (AC1, AC4)

`read_lines` vs `grep -n ''`, asserted per-port in
`tests/validate-python-ports.sh::test_py_read_lines_grep_equivalence`:

| input | grep | `read_lines` | old `splitlines()` |
| --- | --- | --- | --- |
| lone CR | 1 line | 1 ✓ | **2 ✗** |
| form feed `\x0c` | 1 | 1 ✓ | **2 ✗** |
| vertical tab `\x0b` | 1 | 1 ✓ | **2 ✗** |
| file separator `\x1c` | 1 | 1 ✓ | **2 ✗** |
| U+2028 | 1 | 1 ✓ | **2 ✗** |
| CRLF | `['---\r', …]` | same ✓ | `['---', …]` ✗ |
| empty file | 0 | 0 ✓ | 0 |
| bare `\n` | `['']` | `['']` ✓ | **`[]` ✗** |
| trailing `\n` | 2 | 2 ✓ | 2 |
| no trailing `\n` | 2 | 2 ✓ | 2 |

**AC4 (the trailing-newline edge case) is settled: no spurious final empty
line.** `split("\n")` does add one, and the `pop()` removes it; `grep -n` agrees
at both ends. The `pop()` is guarded on `== ""` rather than unconditional, which
is what keeps the no-trailing-newline file's last line and the bare-newline
file's single empty line.

The sweep also closed a case the issue did not name: on a bare-newline file
`splitlines()` returned `[]` where grep reports one empty line.

## Disposition — CHANGED (22 sites, 17 files)

### Governed scanners — 15 files, 16 sites

Each gained `read_lines()` and `strip_eol_cr()` at its evidence cap. These are
the `patterns.py` files whose `patterns.sh` sibling `validate-python-ports.sh`
compares byte-for-byte.

| File | Sites |
| --- | --- |
| `review-audit/skills/check-security/patterns.py` | 1 |
| `review-audit/skills/check-code-health/patterns.py` | 2 (scan + `_read_yaml_list`) |
| `review-audit/skills/check-decomposition/patterns.py` | 1 |
| `review-audit/skills/check-lifecycle/patterns.py` | 1 |
| `review-audit/skills/check-ai-config/patterns.py` | 1 |
| `review-audit/skills/check-okf-conformance/patterns.py` | 2 (scan + `read_pinned_version`) |
| `review-audit/skills/check-docs-deadlinks/patterns.py` | 1 |
| `review-audit/skills/check-docs-examples/patterns.py` | 1 |
| `review-audit/skills/check-docs-staleness/patterns.py` | 1 |
| `review-audit/skills/check-docs-missing-api/patterns.py` | 1 |
| `dev-core/skills/loop-make-it-work/patterns.py` | 1 |
| `dev-core/skills/loop-make-it-right/patterns.py` | 1 |
| `dev-core/skills/loop-make-it-secure/patterns.py` | 1 |
| `dev-core/skills/loop-make-it-tested/patterns.py` | 1 |
| `dev-core/skills/loop-make-it-documented/patterns.py` | 1 |

`check-decomposition` took `read_lines()` but no `strip_eol_cr()`: it has no
evidence slice at all, emitting metrics rather than source lines.

`loop-make-it-tested` **was** initially in that list, and the claim was wrong —
caught by the adversarial pre-PR review. Its `untested-public-api` arm slices
the raw matched line at a **literal `60`** (`ev = content[:60]`, matching
`truncate_chars 60` in the bash twin) rather than at `EVIDENCE_CAP`, so a survey
keyed on the constant name missed it. Reproduced before fixing: on a CRLF-
terminated `def` line python emitted `def public_thing():^M` where bash emitted
no `^M`. Both sites now strip. The lesson generalizes — **the evidence cap is a
behavior, not a constant name** — so the audit was redone behaviorally: every
port was run against a CRLF fixture shaped to trip many detectors, and all 15
now emit byte-identical TSV.

### Config and graph readers — 3 files, 5 sites (now 3 named helpers)

No `line` field of their own, but their **values** feed parity-compared output,
so a separator byte in a config file would diverge the two runtimes' findings.

- `review-audit/skills/okf-migrate/transforms.py` — `read_lines()`, the shared
  okf-migrate content reader (1 site)
- `review-audit/skills/okf-migrate/migrate.py` — `read_config_list` /
  `read_config_scalar` (2 sites)
- `review-audit/skills/check-okf-conformance/bundle_graph.py` — the health-block
  reader and the bundle `read()` closure (2 sites); imported by
  `check-okf-conformance/patterns.py`, so it is inside the parity contract

The four sites in `migrate.py` and `bundle_graph.py` were initially fixed
**inline**, duplicating the reader once per call site. The pre-PR review's second
finding — that these files are invisible to the gate's `PORT_BASENAMES` glob and
so shipped unasserted — was fixed by collapsing each file's inline readers into a
single named `read_lines()` and driving it from the test's `EXTRA_READERS` list.
The duplication removal was a side effect of making the code testable, which is
the usual shape.

### Already `split("\n")`, missing only `newline=""` — 2 files

Both read real source content. They had the pop-the-trailing-empty half right
and the translation half wrong, so they were subject to the lone-CR case alone.

- `workflow/skills/ship-issue/split-verify.py` — `read_lines()`
- `workflow/skills/ship-issue/sizing.py` — inline read, refactored to a
  `read_lines()` helper so the direct grep-equivalence test can reach it

## Disposition — NOT APPLICABLE (4 sites, 4 files)

Recorded rather than changed, each for a structural reason.

| Site | Why not applicable |
| --- | --- |
| `workflow/scripts/delegation-adoption.py:198` | Reads JSONL transcripts. **Python-only by design** — its `.sh` is a fail-loud shim with no bash body (it exits 77 when python3 is absent), so there is no grep to agree with. A JSON document cannot contain a raw control byte outside a string, and `json.loads` rejects one inside. |
| `workflow/scripts/measure-spawn-prefix.py:146` | Same: JSONL, python-only shim. |
| `workflow/scripts/token_attribute_engine.py:178` | Same, and it has no `.sh` sibling at all. |
| `review-audit/skills/okf-migrate/migrate.py:413` | `edit.new.splitlines()` splits an **in-memory generated string** built by this program, not file content. No second runtime reads it and no line number is reported against a file. |

Two further ports carry no `read_lines()` **and need none**, asserted through an
explicit `NO_CONTENT_READ` set in the test rather than a `try/except` (so a
content-reading port that loses its reader fails instead of being quietly
excused — the #538/#571 silence-reads-as-a-pass shape):

- `dev-core/skills/drift-detect/patterns.py` — compares two **path lists**; a
  path cannot contain a separator byte, so no line model is observable.
- `review-audit/skills/check-docs-organization/patterns.py` — reads only the
  file list.
- `workflow/skills/ship-issue/plan-lens.py` — reads a numstat TSV (counts keyed
  by path), never source.

## Evidence (AC2)

Fixtures added to `tests/validate-python-ports.sh`: `lonecr.py`, `formfeed.py`,
`verttab.py` (three separators, so a fix keyed to the two bytes named in the
issue still fails), and `barenewline.py`.

**Confirmed red before the fix** — the corpus diff reported exactly the
divergence the issue describes:

```text
/fix/lonecr.py    1  hardcoded-secret  ...: x = 1^Mpassword = "realsecret123"   (bash)
/fix/lonecr.py    2  hardcoded-secret  ...: password = "realsecret123"          (python)
/fix/formfeed.py  1  ...: a = 1^Lpassword = "realsecret123"   vs  2  ...
/fix/verttab.py   1  ...: b = 1^Kpassword = "realsecret123"   vs  2  ...
```

Suite exit 1, 18 assertions failing. After the fix: **65 passed, 0 failed**.

`crlfcontent.py` (#902's regression guard) stays green, and is what caught the
evidence-CR half: with `newline=""` but no `strip_eol_cr`, python emitted
`password = "realsecret123"^M` where bash emitted no `^M`.

**Coverage for the four readers the port glob cannot see** (`transforms.py`,
`migrate.py`, `bundle_graph.py`, `split-verify.py`) is the test's
`EXTRA_READERS` list, driven through the same ten shapes and the same `grep`
oracle. Verified non-vacuous by mutation: reverting `transforms.py` to
`splitlines()` turns the suite red on five of the ten shapes, naming the file.
`list_python_ports()` is keyed off `PORT_BASENAMES`, so a reader in a
differently-named module was invisible to every assertion in this gate —
the #836 trap reached by a new route: not a missing fixture but a missing
*file*.

## Review cycles

Three defects were found after the work looked finished. All three were mine,
and none was reachable from the full suite being green.

**Cycle 1, correctness/HIGH — a #902 regression.** `loop-make-it-tested` slices
evidence at a **literal `60`** (matching `truncate_chars 60` in its bash twin),
not at `EVIDENCE_CAP`, so a sweep keyed on the constant *name* missed it. It took
`read_lines()` (which keeps the CR) without the matching strip. The lesson:
**the evidence cap is a behavior, not a constant name** — so the audit was redone
behaviorally, running every port over a CRLF fixture rather than grepping for a
symbol.

**Cycle 1, tests/MEDIUM — four readers shipping unasserted.**
`list_python_ports()` keys off `PORT_BASENAMES`, so `transforms.py`,
`migrate.py`, `bundle_graph.py` and `split-verify.py` were invisible to this
gate, and no other suite carried a separator-byte fixture. The #836 trap by a new
route: not a missing fixture but a missing *file*.

**Found while verifying the cycle-1 fix — a shadowing bug worse than the finding.**
Collapsing `migrate.py`'s inline readers into a named `read_lines()` **shadowed
the `transforms.read_lines` imported at the top**, which `apply_edits` relies on
to swallow `OSError`. An unreadable file went from "yields no edits" to crashing
the migration engine — in a tool whose design note says one odd file must not
kill a run across N repos. The local reader is now `_read_config_lines`, and the
name is load-bearing rather than cosmetic.

This is the standard hazard of fixing under review pressure, and the reason the
cycle loop exists: the fix for a MEDIUM finding introduced a worse defect than
the finding.

**Cycle 2 returned `clean` with zero blocking findings.** Its two substantive
deferrables were closed rather than deferred, because both named the same real
gap — a fix asserted by *prose* instead of by a test:

- `test_py_evidence_carries_no_cr` drives every port over a CRLF file and asserts
  no emitted row carries a CR anywhere. Deliberately cap-width agnostic, so
  another port using its own literal slice cannot defeat it — the generalization
  of the cycle-1 defect. Guarded by `test_crlf_evidence_is_nonvacuous`, since a
  test over zero rows passes trivially.
- `test_migrate_config_readers_survive_unreadable` pins the three distinct
  `OSError` fallbacks **and** that `migrate.read_lines` still resolves to
  `transforms.py`. No end-to-end fixture can see that: both spellings behave
  identically on every *readable* file.

Both were mutation-verified. Reverting `strip_eol_cr` turns the first red;
renaming `_read_config_lines` back to `read_lines` turns the second red.

## Deferred

Plan-lens flagged three files already over their production-LOC budgets. Judged
swamping; the swamp gate was raised and resolved as **follow-up issues**, keeping
this PR narrow — its diff is wide and shallow, and a module split alongside it
would bury the one thing a reviewer must check: that all ports now share one line
model.

The figures below were measured with `pre-review-gates.sh` near the end of the
work — not the planning-time estimates. The first version of this section quoted
the plan-lens numbers taken *before* implementation, which the work then
invalidated; cycle 3 caught them understating the overage by about a quarter. A
deferral note that goes stale is worse than none, because it reads as current.

They are marked approximate deliberately. A figure for a file the same PR is
still editing is stale the moment a later commit touches it — chasing it to the
byte just reintroduces the staleness in a smaller font. What has to be accurate
is the **claim**: this file is several hundred lines over budget, this PR is
responsible for most of that growth, and #1038 tracks the split. Run
`pre-review-gates.sh` for the exact current number.

| File | Budget | Final | This PR added | Tracked by |
| ---- | ------ | ----- | ------------- | ---------- |
| `tests/validate-python-ports.sh` | 700 | **~995** | ~394 | [#1038](https://github.com/joshjhall/librarian/issues/1038) |
| `check-security/patterns.py` | 500 | **666** | 40 | [#1037](https://github.com/joshjhall/librarian/issues/1037) |
| `okf-migrate/migrate.py` | 500 | **519** | 26 | left to the existing backlog |

`validate-python-ports.sh` is the one this PR genuinely grew — most of the added
lines are the new fixtures and the direct probes the review cycles asked for.
That growth is the deliverable (AC2 is "the corpus carries fixtures that fail
without the fix"). At the PR base it measured **819** production LOC against the
`sh` warning budget of **700**, so it was already ~119 lines over before this
change: the split is a pre-existing debt this PR adds to rather than creates.
Filed as #1038 with the split shape the scanner itself recommends (sourced
fragment + an explicit ordered list, the convention six other suites already
follow).

`migrate.py`'s ~19-line overage is small and genuinely pre-existing — it was 608
lines on `main` before this branch, added by #1036 — so it is left to the
ordinary backlog rather than given an issue of its own.
