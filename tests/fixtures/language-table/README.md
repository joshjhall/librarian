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

Each tree is minimal: only the files the analyzer reads. The scanners here are
stubs, not runnable — the gate parses source, it never executes it.
