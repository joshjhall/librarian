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

`check-decomposition` and `loop-make-it-tested` took `read_lines()` but no
`strip_eol_cr()`: neither has an `EVIDENCE_CAP` slice — the first emits metrics,
the second emits a computed message rather than a source line.

### Config and graph readers — 3 files, 5 sites

No `line` field of their own, but their **values** feed parity-compared output,
so a separator byte in a config file would diverge the two runtimes' findings.

- `review-audit/skills/okf-migrate/transforms.py` — `read_lines()`, the shared
  okf-migrate content reader (1 site)
- `review-audit/skills/okf-migrate/migrate.py` — `read_config_list` /
  `read_config_scalar` (2 sites)
- `review-audit/skills/check-okf-conformance/bundle_graph.py` — the health-block
  reader and the bundle `read()` closure (2 sites); imported by
  `check-okf-conformance/patterns.py`, so it is inside the parity contract

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

## Deferred

Plan-lens flagged three files already over their production-LOC budgets
(`check-security/patterns.py` 638 vs 500, `okf-migrate/migrate.py` 505 vs 500,
`tests/validate-python-ports.sh` 803 vs 700). Judged swamping; the swamp gate
was raised and resolved as **follow-up issues**, keeping this PR narrow — its
diff is wide and shallow, and a module split alongside it would bury the one
thing a reviewer must check: that all ports now share one line model.
