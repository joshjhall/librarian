# ADR 0002 — Scanner language support: modeled, lexical-only, unsupported

- **Status:** Accepted
- **Date:** 2026-08-28
- **Scope:** `review-audit` plugin — the `check-security`, `check-code-health`,
  `check-lifecycle` and `check-docs-missing-api` pre-scan skills
- **Issue:** [#622](https://github.com/joshjhall/librarian/issues/622) Phase 0

> **Convention:** ADRs for the `review-audit` plugin live in this directory
> (`plugins/review-audit/docs/adr/`), four-digit-prefixed and never renumbered.
> `docs/` is inert to the plugin loader (only `skills/` and `agents/` are
> auto-discovered), so a design doc here ships with the repo without becoming a
> loadable component.

## Context

Each of the four `check-*` pre-scan skills grew its own extension-dispatch chain
independently, so a language recognized by one is invisible to the others. No
language is covered by all four. #622 filed this as a Swift gap; the shape of
the problem turned out to be broader than the label.

### The defect is bidirectional

A missing language arm is not a no-op. Each scanner mixes per-language detectors
with unconditional "all files" detectors, and the unconditional ones carry a
**hardcoded C-family comment model** that misfires on anything else. Measured on
the tree as of this ADR, both runtimes agreeing byte-for-byte:

**False positive.** A `.lua` or `.sql` file whose only content is a `--` comment
mentioning `password = "…"` is emitted as `hardcoded-secret` at **HIGH**. The
denylist at `check-security/patterns.py:107` enumerates `#`, `//`, `/*`; `--` is
absent, so comment prose is scanned as code.

**False negative.** That same denylist is an **unanchored substring** test, so a
`#` anywhere on the line suppresses the finding — including inside the secret
value (`password = "Str0ng#Pass#Value"`) and in a trailing `# noqa`. Both emit
zero rows. This is a false-clean in a security scanner, and it was not known
when #622 was filed. Tracked as
[#837](https://github.com/joshjhall/librarian/issues/837).

**False negative.** A Swift `catch { }` emits nothing —
`check-code-health`'s `empty-handler` has arms for py/js/ts/java/kt/rb/go and
none for Swift or Rust.

So the current state is the worst of both: false positives from language-blind
detectors applied to unmodeled syntax, and false negatives from per-language
detectors nobody wrote.

**A note on the anchor.** Anchoring the comment test to line-start fixes both
directions of the false negative, and it is the obvious first move. It does
**not** fix the false positive: `--`, `"""` and every other non-C-family marker
remain unmodeled. This ADR exists partly so that the anchor-only change is not
applied and declared done — the fix must consult a language's comment model, and
§2 defines where that model comes from.

### Not every scanner carries the same risk

The four differ more than #622's framing suggests, and the contract below is
calibrated to the difference:

| Scanner | Unconditional detectors | Risk on an unmodeled file |
| --- | --- | --- |
| `check-security` | secrets, xss, sql-concat, insecure-crypto | **false positives** |
| `check-code-health` | `tech-debt-marker` | **false positives** |
| `check-lifecycle` | none | false negatives only (silent) |
| `check-docs-missing-api` | none | false negatives only (silent) |

The latter two are pure `if/elif` chains with no trailing `else`; an unrecognized
extension yields zero rows and no error. That is a coverage gap, not a
correctness bug — a real distinction, and the reason the states in §1 are three
rather than two.

### The dual-runtime asymmetry

Every scanner is a `patterns.py` (Python 3.11+ primary) plus a `patterns.sh`
(bash-3.2 fallback that exec's the Python when a suitable interpreter exists).
Their outputs are pinned byte-identical by `tests/validate-python-ports.sh`.

The two halves cannot share code the same way:

- The four scanners live in **one plugin** (`review-audit`) which installs as a
  unit, so a Python module *could* be imported across them. This differs from
  `check-decomposition/loc_engine.py`, which exists in two byte-identical copies
  precisely because its consumers (`review-audit` and `workflow`) install
  independently.
- The **bash halves can share nothing.** No scanner `patterns.sh` sources a
  sibling, and `plugins/` is copied as-is by `claude plugin install` with no
  build step. Bash sharing in this repo is only ever duplicated
  `# >>> shared:<name>` regions pinned by `tests/validate-shared-scanner-sync.sh`.

Any design that assumes one sharing mechanism for both runtimes is wrong on the
bash side.

### How many spellings of "which language is this file" already exist

- `loc_engine.EXT_LANG` — two byte-identical copies, pinned.
- `check-decomposition/patterns.sh:153` and `ship-issue/sizing.sh:238` — two
  byte-identical `case` blocks that are **outside any shared region** and pinned
  by nothing. They sit in the gap between `<<< shared:bloat-config` and
  `>>> shared:bloat-spec`.
- The four scanners' inline `ext ==` chains, ×2 runtimes — eight more, unpinned
  to each other.

That is roughly a dozen independent spellings of "`.mjs` is JavaScript". #663's
principle — *two tables over the same files that must agree is exactly the
duplication we are trying to eliminate* — applies directly. **This ADR must not
add a thirteenth.**

## Decision

Adopt **Option A (a shared language table), scoped to lexical facts only**.
Reject Option B. Keep detector dispatch as a flat per-scanner chain.

### 1. Three states, not two

The epic proposed the invariant *"a language is either modeled or explicitly
unsupported — never silently falls through"*. As a binary that is not
implementable without losing real coverage: `tech-debt-marker` is
`\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b`, which is correct on **any** language. A
strict binary would force `check-code-health` to skip a Lua file entirely,
dropping a true positive in order to fix a false positive that lives in a
different scanner.

So a language is in exactly one of three states **per scanner**:

| State | Notation | Per-language detectors | Unconditional detectors |
| --- | --- | --- | --- |
| **Modeled** | `M` | run | run, gated on this language's lexical model |
| **Lexical-only** | `L` | none are written | run, gated on this language's lexical model |
| **Unsupported** | `—` | do not run | **do not run** — the file is skipped |

The operative invariant, in its testable form:

> **No detector that depends on a lexical model may execute against a file whose
> lexical model this scanner does not know.** A file is scanned under its own
> comment and string rules, or it is not scanned at all. There is no path on
> which a detector applies one language's lexical model to another language's
> source.

This is strictly stronger than #622's wording where it matters — it forbids the
Lua/SQL false positive — while permitting the Lua `TODO` true positive that the
binary form would have discarded.

`L` is the state that makes the difference. It says: we know how this language
spells a comment, so the language-agnostic detectors can run safely, but nobody
has written idiom-specific detectors for it. That is an honest and common
position, and collapsing it into either neighbour loses information.

### 2. The lexical floor: one normative table, subset-checked copies

`EXT_LANG` and `COMMENT_RE` in
`plugins/review-audit/skills/check-decomposition/loc_engine.py` are hereby the
**normative** spelling of the lexical facts: which extension is which language,
and how that language opens a line comment.

They are deliberately **not moved** and **not imported** by the four scanners.
`loc_engine.py` is a pair member pinned byte-identical against
`ship-issue/loc_engine.py`; adding a third consumer would make that pinning
tripartite and force every future decomposition change to consider four
scanners. The cure would be worse than the disease.

Instead each scanner keeps the subset of lexical facts it needs, and
`tests/lint-language-table-sync.sh` asserts every copy is a **consistent
subset**:

> A scanner may cover **fewer** extensions than the normative table. It may
> never **contradict** it — an extension it dispatches on must map to the same
> language key, and a comment marker it uses for a language must match the
> normative one.

Subset-consistency rather than byte-identity is the load-bearing choice. It lets
`check-lifecycle` model four languages while `check-docs-missing-api` models
eight, and simultaneously makes it impossible for two scanners to disagree about
what `.mjs` is or how Lua spells a comment. Byte-identity would have forced every
scanner to carry every language; a free-for-all would have permitted exactly the
drift that produced this ADR.

### 3. The unconditional-detector rule

Every detector is classified into exactly one bin, and the classification is
recorded in its scanner's `contract.md`:

| Bin | Definition | Gating |
| --- | --- | --- |
| **lexical-dependent** | correctness depends on telling code from comment or from string-literal content | MUST consult the language's lexical model; MUST NOT run on `—` |
| **lexical-independent** | correct on any plain-text source regardless of syntax | MAY run on `M`/`L`/`—` alike, **with a stated reason** |
| **language-specific** | written against one language's idioms | runs only under its own `M` arm |

> An unconditional detector is permitted **only** when it is declared
> lexical-independent in its scanner's contract, with a reason. Every other
> detector is lexical-dependent by default and must be gated. Adding an
> unconditional detector without a declaration is a contract violation.

Default-deny is the correct polarity here: it was the *absence* of any
declaration that let the comment model spread unexamined across three detectors
in two scanners.

Classification of the detectors as they stand:

- `tech-debt-marker` — **lexical-independent**. A `TODO` is a TODO in any
  syntax. Stays unconditional.
- `hardcoded-secret`, the AWS / GitHub / Stripe / private-key literals —
  **lexical-independent**. `AKIA[0-9A-Z]{16}` is a leaked key wherever it
  appears; arguably a commented-out one is more interesting, not less.
- `hardcoded-secret`, the generic credential + denylist — **lexical-dependent**,
  currently misclassified as independent. This is #837.
- `injection-risk` string-concatenation — **lexical-dependent** (it reasons about
  string-literal form). To be gated.
- `xss-risk` — **lexical-independent**. `dangerouslySetInnerHTML`, `v-html` and
  the Blade token are framework markers, meaningful wherever they occur.
- `insecure-crypto` — **lexical-dependent**, already attempts to be, with a
  hardcoded model (`patterns.py:175`). To be gated properly.
- `debug-statement`, `empty-handler`, all of `check-lifecycle`, all of
  `check-docs-missing-api` — **language-specific**, already correctly per-arm.

### 4. Declaring support: the per-scanner matrix

Each scanner's `contract.md` carries a `## Language Support` section holding a
**category × language** matrix with `M` / `L` / `—` cells, behind a
`<!-- contract: … -->` marker so it is addressable by id rather than by heading
text.

The matrix is category × language, not a flat language list, because the
scanners are genuinely ragged at that granularity: in `check-code-health`,
`debug-statement` covers `.mjs`/`.cjs` while `empty-handler` does not.

This is the one fact that is irreducibly **per-scanner**, which is why it lives
in the contracts and not in a shared table. Which categories a scanner
implements for a language is not a lexical fact and cannot be centralized
without forcing four scanners to agree where they legitimately differ —
`check-lifecycle` models Swift and not Rust; `loc_engine` models both, correctly.

### 5. Visibility: unsupported is silent on stdout

An unsupported file emits **no TSV row**.

This is the tempting wrong answer, so it is recorded explicitly. The contract is
`file⇥line⇥category⇥evidence⇥certainty` and every consumer treats a row as a
*finding in the audited repository*. An `unsupported-language` row would need a
category slug in the Categories table, would be picked up by
`validate-contracts.sh`'s cross-check, and would flow through the checker's merge
into the issue-writer as a defect in someone else's code — when it is a
limitation of ours.

Visibility belongs in three places instead: the contract matrix (declared and
gate-checked), an explicit terminal arm in both runtimes rather than a
fallthrough (so a reader can tell "unsupported" from "nobody got to it yet"), and
— if wanted later — stderr, which the TSV contract does not constrain.

## Consequences

**Positive:**

- The bidirectional comment-model defect becomes structurally impossible rather
  than individually fixed: a detector either has a lexical model for the file or
  does not run.
- Adding a language becomes a bounded, checkable change — extend the subset,
  fill the matrix, add arms to both runtimes — instead of an open-ended audit.
- `tests/lint-language-table-sync.sh` converts each future phase's dual-runtime
  obligation from "remember to do both" into a gate. It would have caught
  [#836](https://github.com/joshjhall/librarian/issues/836) — which is the
  per-language shape it checks; see the granularity limit below.
- The gate's no-contradiction assertion also covers the unpinned
  `check-decomposition` ↔ `sizing.sh` bash tables, which nothing checked before.
- No thirteenth language table.

**Negative / costs:**

- The lexical facts are still duplicated — one normative copy plus per-scanner
  subsets — traded deliberately for the ability to install `workflow` without
  `review-audit`. The gate makes the duplication safe, not absent.
- `L` cells cannot be gate-checked until Phase 1: they assert both the absence of
  a detector and the presence of correct lexical gating, and the gating does not
  exist yet.
- **The gate checks the matrix per LANGUAGE, not per CELL.** It unions the
  extensions dispatched anywhere in a scanner's file and collapses a matrix row
  across its category columns, so it answers *"is this language dispatched in
  both runtimes, as the matrix claims"* — the #836 shape — and not *"is this
  category's cell accurate"*. A wrong cell in one column can pass while another
  column's arm for the same extension exists, which matters precisely because
  the matrices are per-category and genuinely ragged (`check-code-health`'s
  three dispatch chains disagree about `rb` and about `.mjs`/`.cjs`). Narrowing
  to per-category means locating each detector family's source region — Phase 1
  work, when those arms are being rewritten anyway. Until then, a matrix cell is
  reviewed by a human and only its language dimension is enforced. Tracked as
  [#847](https://github.com/joshjhall/librarian/issues/847).
- The matrices are hand-transcribed from source for their first version. The gate
  checks `M` and `—` structurally from Phase 0, but the initial transcription
  needs review by eye.

## Alternatives considered

- **Option B — per-language scanner modules** (`check-security/swift.py`, …).
  Rejected on three grounds. It multiplies 4 scanners × N languages × 2
  runtimes, and the bash half cannot modularize at all — so B buys Python-side
  readability while *guaranteeing* the py/sh divergence
  `validate-python-ports.sh` exists to prevent. It expands the coverage corpus
  contract (`tests/coverage-python.sh` keys on `patterns.py` plus explicit
  lists) by up to twenty files. And it makes detector **emission order** — a
  pinned TSV-parity invariant — an emergent property of module registration
  rather than of source order.

- **Option A as literally proposed in #622** — one shared table in which "each
  scanner declares which categories it implements per language". Rejected for
  the second half only: category-per-language is per-scanner data, and hoisting
  it into a global matrix would force four scanners to agree where they
  legitimately differ. The first half — shared lexical facts — is adopted.

- **Importing `loc_engine` from the four scanners.** Feasible (they share a
  plugin, and parent-sibling `sys.path` seeding resolves) but rejected: it makes
  a two-way byte-identical pinning into a four-consumer dependency, and it has
  no bash counterpart, so the bash halves would still need their own answer.

- **A `skills/_shared/` module directory.** Rejected on evidence:
  `tests/lint-skills-agents.sh` enumerates *every* directory at
  `plugins/*/skills/*` depth with no name filter and asserts each contains a
  `SKILL.md`. A `_shared/` peer fails that gate today. A shared Python module, if
  ever needed, belongs as a sibling *inside* a skill directory — the
  `loc_engine.py` layout.

- **Emitting an `unsupported-language` TSV row.** Rejected — see §5.

- **Fixing the denylist defect in this phase.** Rejected: it is a detector
  behavior change needing a mutation-tested fixture and both-runtime parity work,
  which would stop this phase from being reviewable as a design decision. More
  importantly the correct fix consults the model this ADR defines, so it should
  be written *against* the contract rather than before it. Filed as #837.

## Follow-ups

Phases land as separate PRs, each `Contributes to #622`; the umbrella closes when
Phase 5 lands. The spine is **1 → 2**, with **3**, **4** and **5** independent of
each other once 1 is in.

1. **Phase 1 — Rust** ([#838](https://github.com/joshjhall/librarian/issues/838)). Full arms across all four scanners. Carries the gating
   machinery itself (the first implementation of "consult the lexical model"), so
   it is materially larger than its successors.
2. **Phase 2 — Swift** ([#839](https://github.com/joshjhall/librarian/issues/839)). Full arms; retires the false positives that motivated
   #622 and the `catch {}` gap. Swift's lexical facts already exist in
   `loc_engine` from #728 — reuse that spelling rather than deriving a second.
3. **Phase 3 — TypeScript / JavaScript** ([#840](https://github.com/joshjhall/librarian/issues/840)). Audit the existing arms against this
   contract and fill the matrix. Consider whether TS should split from JS, as
   #726 found for the decomposition lenses.
4. **Phase 4 — Python** ([#841](https://github.com/joshjhall/librarian/issues/841)). Audit and fill, same shape as Phase 3.
5. **Phase 5 — Bash** ([#842](https://github.com/joshjhall/librarian/issues/842)). Full arms; currently `check-docs-missing-api` only.
   Closes #622.

Defects found while writing this ADR, filed separately because each needs its own
mutation-tested fixture:

- [#836](https://github.com/joshjhall/librarian/issues/836) — `check-lifecycle`'s
  bash `is_test_file` is path-crossing, so real source under any `test_*/`
  directory is silently skipped on the bash runtime only. A live py/sh parity
  break that every gate currently misses.
- [#837](https://github.com/joshjhall/librarian/issues/837) — the
  `hardcoded-secret` denylist is an unanchored substring match, so real secrets
  are silently missed. Should land in or just before Phase 1.
