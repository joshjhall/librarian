# review-route-lang fixtures

Fixtures for `tests/lint-review-route-lang.sh` (#913, ADR 0002). Each directory
is a **synthetic `plugins/` tree** the gate is pointed at via
`REVIEW_ROUTE_LANG_ROOT`, arranged so exactly one assertion fires.

They are committed rather than generated at run time for the reason
`tests/fixtures/language-table/` is: a detector that never fires passes the real
corpus silently, and this repo's most-recorded failure mode is an assertion that
is green with *and* without the change it claims to pin. A fixture on disk proves
the gate is alive on every future run, not only on the day it was written.

Each tree holds two stubs — a `loc_engine.py` carrying the normative `EXT_LANG`,
and a `review-route.sh` carrying `classify()`. Nothing is executed; the gate
parses both.

| Fixture | Arms | Expected finding |
| --- | --- | --- |
| `empty-normative/` | assertion 1 | `EXT_LANG` is present but empty, so the anti-vacuity check fails instead of every later check passing over nothing |
| `no-classify/` | assertion 2 | `classify()` is renamed, so the region does not resolve — without this, assertions 3-5 compare against empty sets and pass |
| `contradiction-doc/` | assertion 3 | `.rs` is in the `doc` arm. **The fail-open direction**, and the one #913's AC1 names verbatim |
| `contradiction-config/` | assertion 3 | `.py` is in the `config` arm — the same fail-open direction by the other cheap-adjacent class |
| `contradiction-inverse/` | assertion 3 | `.md` is in the `source` arm. The **safe** direction, which ADR 0002 forbids just the same |
| `contradiction-md-config/` | assertion 3 | `.md` is in the `config` arm — the one cell of the direction matrix the three above do not reach |
| `source-not-normative/` | assertion 4 | `.rb` is in the `source` arm but absent from `EXT_LANG`, so the header's subset claim is false |
| `undeclared-doc/` | assertion 5 | `.rb` is in the `doc` arm. Contradicts nothing — `EXT_LANG` has no opinion — yet routes Ruby source cheap |
| `clean/` | the whole gate | **positive** — must PASS, and must reach the no-contradiction assertion |

Three of these are worth extra words.

`contradiction-inverse/` is not a restatement of `contradiction-doc/`. Both fail
the same assertion, so what separates them is the **direction label** each
asserts: a gate that reported every row as fail-open would satisfy the first and
fail this one. The two directions are genuinely unequal — a source language
routed `doc` reaches `clean: true`, while markdown routed `source` only costs
review budget — and a reader triaging the row needs to know which they have.

`contradiction-md-config/` closes the last cell of the contradiction matrix. The
three fixtures above it all drive `want == "source"`, so the branch computing the
*other* direction label was reachable by nothing — and it caught a real bug on its
first run: the label was hardcoded `doc routed as source` and mislabelled exactly
this case. Its assertion pins the **full** string rather than the `over-review`
prefix, since a prefix match cannot see a wrong class pair.

`undeclared-doc/` is what justifies assertion 5 existing at all. `.rb` is absent
from `EXT_LANG`, so the contradiction check is **silent** on it by construction;
the fixture asserts that assertion 3 **passes** while assertion 5 fails, which
pins the residual gap rather than letting a future reader assume the
contradiction check covers everything. `contradiction-doc/` asserts the mirror
image — assertion 5 **passes** there, because `.rs` is governed and so belongs to
assertion 3. One defect must produce one row, and it must be the row that names
the direction.

**Every** negative fixture asserts its siblings stay `PASS`, not just the one
that arms each check. That is what makes "arms exactly one assertion" a pinned
property rather than an intention: without it, a gate that flagged everything
would satisfy all seven negatives at once, which is the same
green-with-and-without failure the fixtures exist to prevent. Verified by
mutation — widening assertion 5 back to its pre-narrowing predicate, or making
assertion 4 fire unconditionally, reddens these rows and nothing else does. `source-not-normative/` carries the mirror
of that narrowness assertion for the same reason: it confirms the gate does not
report an ungoverned extension as a *contradiction*, which would be the gate
punishing `unknown` — the direction `review-route.sh`'s header explicitly
forbids, because it pressures an author toward classifying a doubtful extension
`doc`.

`clean/` inverts the usual shape: it must **pass**. Without it every negative
fixture above is satisfied just as well by a gate that fails unconditionally, and
the asserted `... PASS` line is what makes it more than "did not crash".

The `.sh` stubs are walked by `tests/lint-shellcheck.sh` and
`tests/lint-shell-portability.sh` (both `find` over `tests/`), so they are
written shellcheck-clean and bash-3.2/BSD-clean **without suppressions** — a
suppressed warning in a fixture is one more thing that can rot.
