# classifier-lang fixtures

Fixtures for `tests/lint-classifier-lang.sh` (#1073, ADR 0002). Each directory
is a **synthetic `plugins/` tree** the gate is pointed at via
`CLASSIFIER_LANG_ROOT`, arranged so exactly one assertion fires.

They are committed rather than generated at run time for the reason
`tests/fixtures/review-route-lang/` is: a detector that never fires passes the
real corpus silently, and this repo's most-recorded failure mode is an assertion
that is green with *and* without the change it claims to pin. A fixture on disk
proves the gate is alive on every future run, not only on the day it was written.

Each tree holds three stubs — a `loc_engine.py` carrying the normative
`EXT_LANG`, and the two prose classifier tables (`code-reviewer.md`,
`orchestration-protocol.md`). Nothing is executed; the gate parses all three.
`.build.sh` regenerates the set; it is **not** run by the suite.

| Fixture | Arms | Expected finding |
| --- | --- | --- |
| `empty-normative/` | assertion 1 | `EXT_LANG` is present but empty, so the anti-vacuity check fails instead of every later check passing over nothing |
| `no-table/` | assertion 2 | the `source` row is renamed `sources`, so the row does not resolve — without this, assertions 3-5 compare against empty sets and pass |
| `missing-swift/` | assertion 4 | **this issue's own defect.** `.swift` removed from the source row, everything else correct — the exact state of the tree before #1073 |
| `contradiction-doc/` | assertion 3 | `.go` is in the `docs` row. **The fail-open direction** — a source language that drops security/correctness/tests on a narrowed cycle |
| `contradiction-inverse/` | assertion 3 | `.md` is in the `source` row. The **safe** direction, which ADR 0002 forbids just the same |
| `undeclared-source/` | assertion 5 | `.lua` is in the source row, absent from `EXT_LANG`, and absent from `UNSEGMENTED_SOURCE` — nothing states whether it is a deliberate coarsening or drift |
| `second-subject/` | assertion 4 | `.swift` removed from **`orchestration-protocol.md` only**, with `code-reviewer.md` left correct |
| `clean/` | the whole gate | **positive** — must PASS, and must reach the no-contradiction assertion |

Three of these are worth extra words.

**`missing-swift/` is the regression fixture.** It reproduces the precise state
that issue #1073 was filed against. If it ever passes, the gate has stopped
detecting the bug it was written for — a stronger statement than "the gate is
green today", and the reason it is a committed tree rather than an inline
mutation.

**`second-subject/` exists because every other fixture tampers with
`code-reviewer.md`.** All five assertions would be satisfied by a gate that read
only `SUBJECTS[0]` and stopped — and `orchestration-protocol.md` was an ungated
copy of the same lexical fact until this issue, which is exactly the hole being
closed. A fixture that tampers only with the second file is what makes "both
subjects are really read" a tested claim rather than an intended one.

**`clean/` is the one positive, and its inversion is the point.** Every other
fixture proves an assertion *can* fail; this one proves a correct pair of tables
produces no finding. A gate that simply failed everything would satisfy all the
negatives at once and fail only here. The assertion that it *reaches* the
no-contradiction check is what makes it more than "did not crash".

## Why absence is a defect here and permitted in the sibling gates

`tests/lint-review-route-lang.sh` and `tests/lint-language-table-sync.sh` both
enforce subset-not-contradiction and deliberately allow a consumer to cover
*fewer* extensions. This gate's assertion 4 is stricter: every non-`md` language
in `EXT_LANG` must appear in each source row.

The difference is what sits downstream. An extension missing from one scanner
falls through to the next; an extension missing from the **classifier** has no
downstream at all — the file classifies as no type, matches nothing in
`DIMENSION_RELEVANT_TYPES`, and the cycle returns `clean` without having read it.
Absence is the defect, not a permitted narrowing.

The inverse direction is still permitted, because these tables answer a coarser
question than the LOC engine (`is this reviewable source` vs `can we segment
it`). Those entries live in `UNSEGMENTED_SOURCE` in the gate, so each coarsening
is a stated claim rather than silent retention — AC2 of #1073.
