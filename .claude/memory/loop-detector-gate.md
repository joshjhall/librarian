---
name: loop-detector-gate
description: "#384 slice-B loop-*/drift behavioral gate + coverage lift for the 6 dev-core patterns.py ports to 100%; #348 umbrella now fully covered"
metadata: 
  node_type: memory
  type: project
  originSessionId: ed0667c2-ebf3-43c3-932e-eb5b462b45f5
  modified: 2026-07-18T19:30:22.928Z
---

Issue #384 (slice B of #348, the [[source-detector-gate]] follow-up) SHIPPED (PR #389,
squash eb8bf56, issue closed): the 6 dev-core `patterns.py` ports driven to 100%
line-rate, edge-cases-first, via the #204 two-surface convention. TOTAL python
coverage 89→**100%** — the whole #348 umbrella is now covered.

**New gate**: `tests/validate-loop-detectors.sh` (modeled on `validate-source-detectors.sh`;
content-only, no git-rooting). 13 `run_test` groups over BOTH impls covering
loop-make-it-work (stub/empty-body/no-assertions), -right (long-function/deep-nesting/
single-char), -secure (secret/interpolation-query/dangerous-fn/denylist), -tested
(missing-test-file/untested-public-api — **filesystem-probing**, sibling trees under
`fresh_dir`), -documented (undocumented function/class/export + js/go/shell), drift-detect
(planned-not-touched + MEDIUM/LOW unplanned, two-arg). Wired into `run-all.sh` as stage 9f.

**Gate driver tweak vs slice A**: `emit_rows`/`assert_fires`/`assert_silent` take env-KV
overrides then a `--` then the scanner argv, so a single helper drives both the single-list
loop ports AND drift's two-list form AND `LOOP_MAX_*` threshold env.

**Coverage lift** (measured, local py3.12+coverage): work 79→100, right 76→100, secure
79→100, tested 66→100, documented 66→100, drift 77→100. Corpus extension = a `LOOPDIR`
block + per-port driver cases in `tests/coverage-python.sh`.

**Gotchas hit while closing gaps**:

- loop-make-it-tested's `SKIP_GLOBS` matches `*test*` on the WHOLE PATH, so a fixture dir
  named `tested/` skips every file wholesale — name the tree `probe/` instead.
- The last stubborn lines were OSError arms: `_word_in_file`/`_word_in_any` need an
  UNREADABLE sibling test file (chmod 000, isfile passes + open raises); `_word_in_file`'s
  `return True` needs a go func actually REFERENCED in its `_test.go`.
- documented's colon-strip line (`_bash_read_content`) needs a JS/Go/shell def whose
  signature ends in a lone `:` (e.g. TS `export function parse():`) — Python uses awk, no strip.

**Two source cleanups** (both output-neutral, byte-parity preserved):

- Deleted dead `_next_nonblank` helper in loop-make-it-documented (defined, never called;
  scan_python inlines its own blank-skip).
- Pragma'd loop-make-it-right's `if not m: continue` (`PY_SINGLE_ASSIGN_RE` guarantees
  `PY_VARNAME_RE` matches → genuinely unreachable; code already said "defensive only").

**Fault-injection** (all 6 red→green, recorded in gate header): work no-assert guard forced
true; right SKIP_VARNAMES emptied; secure LOADER_EXCLUDE dropped; tested `if not has_test`
inverted; documented py-docstring guard forced true; drift side-effect/test LOW forced off.

**Pre-PR review caught regex-ALTERNATION gaps that 100% line-coverage hides** (the exact
class this issue exists to close): `child_process.exec`/`marshal.loads` alternatives share a
line with `subprocess.call`/`yaml.load`, and the ts/js + rust missing-test-file probe arms +
brace-language deep-nesting were only line-driven by the corpus with zero assertions. All 3
were low/deferrable but ON-TOPIC, so I fixed them IN-PR (3 new assert_fires groups) rather than
defer — a coverage-hardening PR shouldn't ship known assertion gaps in its own subject. Lesson:
when covering a detector, assert EACH regex alternative and EACH per-language arm separately,
not just one representative per line.

Note: `just lint` fails on pre-existing markdown debt in `.claude/memory/*.md` (committed but
untouched by this work) — NOT in the #384 diff; leave it (scope drift). Fixture secrets trip the
gitleaks pre-commit hook unless fragment-assembled (`"abcdefgh""ijklmnop1234"`) like the AKIA
token. PR = "Contributes to #348" per [[umbrella-issue-closes-vs-contributes]]; the issue does
NOT auto-close on merge, so close it manually. See [[coverage-two-surfaces]].
