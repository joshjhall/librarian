---
description: Mechanized Open Knowledge Format (OKF) bundle migration — check/plan/apply with deterministic, idempotent transforms. Renders the full change set as a reviewable diff before writing anything. Use when adopting OKF in a repo whose memory bundle is not yet conformant.
---

# okf-migrate

The **adoption path** for the OKF toolset. Slices A–C report; this one changes
things.

| Mode | Writes? | Purpose |
| --- | --- | --- |
| `check` | never | Report what would need migrating. **The default.** |
| `plan` | never | Render the full change set as a reviewable diff. |
| `apply` | yes | Execute the plan. Explicit subcommand **and** `--confirm`. |

```bash
migrate.sh                      # check — what needs migrating?
migrate.sh plan                 # the diff, before anything is touched
migrate.sh apply --confirm      # execute it
```

**Companion files**: `contract.md` for output shapes, the edit record, and exit
codes. `thresholds.yml` for the transform split, type-inference rules, and link
form — every one a documented default rather than a contract.

## Why this exists

A checker that only *reports* pushes the whole adoption cost onto every
consuming repo, one hand-edit at a time — the failure #663 names, where
detection without a mechanized recommendation gets ignored.

This repo is its own evidence: **238 of 255** memory files still carry the
non-conformant `[[wikilink]]` form, because nobody hand-converts 238 files. That
is what `plan` and `apply` are for.

## `plan` is the important mode

It renders the full change set *before* anything is touched, so a repo owner
reviews a **diff** rather than trusting a bulk rewrite. It is the default output
of any migration request, and it is also the **write allowlist** — `apply`
writes only paths the plan listed.

That last part is what makes the split real rather than ceremonial. A "dry run"
that merely rehearses can still diverge from the run that matters; a plan that
*constrains* the apply cannot. A transform discovering a new file between the
two is a bug, not a permitted widening, so the mismatch is a hard error.

## The transforms

| Transform | What it does | `apply` |
| --- | --- | --- |
| `adopt-bundle` | Create the bundle-root `index.md` carrying `okf_version` | ✓ |
| `backfill-type` | Add the sole always-required key (§4.1) | ✓ |
| `wikilink-convert` | `[[x]]` → `[x](/x.md)` (§6.1) | ✓ |
| `split-index` | Split an oversized index | refused |
| `confirmed-merge` | Execute a confirmed near-duplicate merge | refused |

**The split is structural, not a preference**, which is why it lives in
`thresholds.yml` where it can be inspected. The top three are mechanical: given
the bundle, the edit is determined. The bottom two each execute a judgment made
somewhere else — `split-index` needs a seam chosen from `check-decomposition`'s
topic-cluster *recommendations*, `confirmed-merge` needs slice C's (#670) human
confirmation. Both render in `plan`; `apply` refuses each with a pointer to the
decision it lacks.

Moving a name from `plan_only` to `applicable` is a real decision, not config
tidying: it grants the engine permission to write a judgment it did not make.

### `backfill-type` never guesses

`type` is OKF's sole always-required key, and §4.1 requires consumers to
**tolerate unknown values** — which means a wrong one is rejected nowhere and
propagates silently through everything that routes on it. A missing `type` is
one loud finding; a wrong one is a lie the ecosystem believes.

So where inference is ambiguous the tool emits the candidates and **exits 3
without writing anything** — not for that file, not for any file. Partial
application is not offered: a half-migrated bundle is harder to reason about
than an unmigrated one.

The commonest real case is not an inference at all. A bundle whose `type` is
nested under `metadata:` has the answer already written down — the validator
reports it missing because §4.1 reads `type` at the **top level** only — so the
default rules lift it rather than guessing. That is this repo's own history:
issue #991 migrated ~246 files of exactly that shape.

### `wikilink-convert` is lossless

An unresolvable target becomes a link to the path it *would* occupy. §6.1 says a
broken link may simply represent knowledge not yet written, so converting it
preserves the fact that someone meant to link there; dropping it would not.

Wikilinks inside fenced code blocks are **skipped** — a memory documenting the
old syntax must not have its examples rewritten out from under it, which would
turn documentation of a format into a claim about a different one.

## The safety model

`apply` requires **both** an explicit subcommand and `--confirm`, so neither a
bare invocation nor a typo can write. On top of that:

- **It refuses a dirty working tree** (`--allow-dirty` escapes), so every applied
  change is reviewable as its own diff. A directory not under version control is
  **not** dirty — this tool migrates any repo's bundle, and refusing there would
  make the safety gate a portability bug.
- **It writes only what the plan listed** (above).

## Two kinds of failure, kept strictly apart

The same split `check-okf-conformance` draws, and the epic (#664) says
conflating them is how a tool like this lands wrong:

- **The bundle is never rejected.** A non-conformant bundle is exactly what this
  tool exists to fix, so every migration finding is reported at **exit 0**.
- **The tool fails loud.** A usage error, an unresolvable version pin, a refusal,
  or an ambiguity exits **non-zero** with an actionable message.

Exit 2 (refused) and exit 3 (needs a human choice) are distinct on purpose: 2
means *you* have something to do, 3 means the engine needs an answer it will not
invent. A caller can branch on them without parsing prose.

## Guarantees

- **Idempotent** — applying twice equals applying once, byte-compared.
- **Reversible in the checker's sense** — after `apply`, `check-okf-conformance`
  emits zero rows for that transform's category.

Both are fixture-pinned in `tests/validate-okf-migrate.sh`, and the reversibility
fixtures drive the **real** validator rather than a stand-in.

## Portability

No librarian convention is hardcoded — a repo with entirely different values gets
correct results with **zero code changes**, which is an acceptance criterion of
the epic rather than a nicety.

| Setting | Default | Where |
| --- | --- | --- |
| bundle root | `.claude/memory` | `$OKF_BUNDLE_ROOT` → `$MEMORY_BUNDLE_ROOT` |
| OKF version pin | `0.2` | `check-okf-conformance/thresholds.yml` |
| type-inference rules | librarian's four types | `thresholds.yml` |
| link form | `bundle_relative` | `thresholds.yml` |
| which transforms may write | the three mechanical ones | `thresholds.yml` |

The version pin is **read, never copied**. `adopt-bundle` stamps it into the
`index.md` it creates, so a second copy here would let this engine write a bundle
its own validator then reports as drifted — the two halves of one toolset
disagreeing about a constant. Same rule `ruff.toml`'s `required-version` follows.

The link form mirrors `okf-author/thresholds.yml`'s `link_form` and must agree
with it: that skill teaches an **author** the form, this engine converts
**existing** files to it, and a disagreement would have every new memory written
one way while the migration rewrote the rest the other.

## Runtime

Python 3.11+ primary (`migrate.py` + `transforms.py`), with a bash-3.2 fallback
(`migrate.sh` + `transforms.sh`) selected by the standard shim;
`PATTERNS_FORCE_BASH=1` forces bash. The two must agree on output — that is the
language boundary, and `tests/okf-migrate/60-parity.sh` pins it per case for all
three modes, including a byte-compare of the applied tree.

## Not a pre-scan

Deliberately not named `check-*`, and its tool deliberately not `patterns.sh`.
Those names are auto-discovered by the checker agent, by
`bin/check-patterns-coverage.sh` (which would demand a `contract.md` Categories
table this tool has no business having), and by `tests/validate-prescans.sh`
(which imposes a file-list CLI incompatible with a mode-shaped one). A migration
engine is not a scanner: it emits transforms, not findings.

For the same reason its bash↔python parity is pinned by its own suite rather
than `tests/validate-python-ports.sh`, whose contract is file-list shaped and
whose scope rule says so explicitly — the same call `split-verify.{py,sh}` made.

## When to use

- Adopting OKF in a repo whose memory bundle is not yet conformant
- Converting a bundle's non-conformant wikilinks to portable markdown links
- Lifting nested `metadata.type` keys to the top level

## When NOT to use

- Judging a bundle's quality — that is `check-okf-conformance` and `audit-memory`
- Deciding *which* of two near-duplicate memories survives — slice C recommends,
  a human confirms, and only then does `confirmed-merge` have an input
- Authoring a new memory — that is `dev-core`'s `okf-author`
