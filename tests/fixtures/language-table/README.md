# language-table fixtures

Negative fixtures for `tests/lint-language-table-sync.sh` (#622 Phase 0,
ADR 0002). Each directory is a **synthetic `plugins/` tree** the gate is pointed
at via `LANG_TABLE_ROOT`, arranged so exactly one assertion fires.

They are committed rather than generated at run time for the reason
`tests/fixtures/category-parity/` is: a detector that never fires passes the
real corpus silently, and this repo's most-recorded failure mode is an assertion
that is green with *and* without the change it claims to pin. A fixture on disk
proves the gate is alive on every future run, not only on the day it was written.

| Fixture | Arms | Expected finding |
| --- | --- | --- |
| `empty-normative/` | assertion 1 | `EXT_LANG` is present but empty, so the anti-vacuity check fails instead of every later check passing over nothing |
| `no-marker/` | assertion 2 | `contract.md` has a Language Support section but no `<!-- contract: -->` marker — the matrix does not resolve |
| `contradiction/` | assertion 3 | `sizing.sh` maps `.rs` to `go` while the normative table says `rs` |
| `one-runtime/` | assertion 4 | `.rs` is marked `M` and has a `patterns.py` arm but no `patterns.sh` arm — the exact shape of #836 |
| `per-category/` | assertion 4, per **cell** | `.rs` is `M` in two columns but only has an arm in one. The **only** multi-category matrix here (#847) |
| `sameline-arm/` | the bash arm splitter | **positive** — must PASS. A `case` arm whose `;;` is on the pattern line must not leak the next arm's coverage |
| `missing-roster/` | the four-scanner roster | no governed scanner exists at all, so all four must be reported undeclared |

Two of these are worth extra words.

`per-category/` is the one fixture with a **multi-column** matrix. Every other
tree here uses a single synthetic category column, which is precisely why the
per-cell gap survived Phase 0 — none of them could express it. It is verified to
**pass against the pre-#847 gate** and fail against the current one, so it pins
the narrowing rather than restating `one-runtime/`.

`sameline-arm/` inverts the usual shape: it must **pass**. The property is that a
bash `case` arm whose `;;` sits on the pattern line does not leak its successor's
coverage into its own region, and a leak surfaces as a *spurious finding against a
correct tree* — a false positive, which only a clean run can pin. It exists
because a mutation round found that branch **untested rather than unreachable**:
neutering it silently added `md`/`json`/`yaml` coverage to every real
`check-lifecycle` category and nothing failed, since those extensions appear in
neither the matrix nor `EXT_LANG`. The fixture puts the phantom extension
somewhere the assertions can see it.

`missing-roster/` needs `LANG_TABLE_EXPECT_ROSTER=1` alongside `LANG_TABLE_ROOT`.
The roster check skips under a fixture root by default — a fixture tree carries a
deliberate subset — but "skips under every fixture" would mean its **failing**
branch is executed by nothing, which is the self-skipping-hides-the-risky-branch
shape (#543): the arm that matters is the one no test reaches. The flag exists so
that arm is genuinely exercised.

Each tree is minimal: only the files the analyzer reads. The scanners here are
stubs, not runnable — the gate parses source, it never executes it.
