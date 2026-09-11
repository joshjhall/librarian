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
  [#836](https://github.com/joshjhall/librarian/issues/836).
- **The gate checks the matrix per CELL**, as of
  [#847](https://github.com/joshjhall/librarian/issues/847). Phase 0 shipped it
  per-*language* — it unioned the extensions dispatched anywhere in a scanner's
  file and OR-ed each matrix row across its columns, so a wrong cell in one
  column passed whenever another column had an arm for the same extension. That
  mattered precisely because the matrices are per-category and genuinely ragged
  (`check-code-health`'s three dispatch chains disagree about `rb` and about
  `.mjs`/`.cjs`). The narrowing is an explicit **column → source-region binding
  map** in the gate, with three kinds — by emitted category tag, by enclosing
  function (for the two debug columns, which share one tag), and whole-file (for
  a scanner with a single modeled column). Two knock-on effects: a cell's
  parenthetical narrowing (`M (js/jsx only)`) is now enforced rather than prose,
  and an `M` cell in a column with no binding is reported rather than skipped, so
  a new modeled column cannot go quietly unchecked.

  This did **not** need to wait for Phase 1: the binding map locates each
  detector family's region without restructuring the arms, which is why #847
  landed early. Phase 1 may simplify the map, but does not gate it.
- The gate's no-contradiction assertion also covers the unpinned
  `check-decomposition` ↔ `sizing.sh` bash tables, which nothing checked before.
- No thirteenth language table.

**Negative / costs:**

- The lexical facts are still duplicated — one normative copy plus per-scanner
  subsets — traded deliberately for the ability to install `workflow` without
  `review-audit`. The gate makes the duplication safe, not absent.
- `L` cells cannot be gate-checked until Phase 1: they assert both the absence of
  a detector and the presence of correct lexical gating, and the gating does not
  exist yet. This is the one remaining granularity gap — `M` and `—` cells are
  checked per-cell as of #847.

  **Partly closed by Phase 1** ([#838](https://github.com/joshjhall/librarian/issues/838)).
  The gating now exists, and with it the second half of §2 became checkable: a
  scanner's comment-model subset is asserted against the normative `COMMENT_RE`
  (`COMMENT_CONTRADICTION` in `tests/lint-language-table-sync.sh`), which the
  gate's own header had claimed from Phase 0 while nothing implemented it —
  there was no subset to check until one existed. What remains open is the
  *other* half of an `L` cell: that no per-language detector exists for that
  language. That is an absence claim over the arms, not over the lexical tables,
  and it is still unenforced.
- The matrices are hand-transcribed from source for their first version. The gate
  checks `M` and `—` structurally from Phase 0 (per-cell since #847), but the
  initial transcription needs review by eye.

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
2. **Phase 2 — Swift** ([#839](https://github.com/joshjhall/librarian/issues/839)) — **landed**. The `catch {}` gap is fixed and the false
   positives are retired. Swift's lexical facts were consumed from `loc_engine`'s
   #728 spelling rather than re-derived, as planned.

   Two findings from the phase are worth recording here, because both narrow what
   a later phase should expect:

   - **Only two of the four scanners needed a code change.** `check-security`
     already resolved Swift in its lexical model, so its gating was correct on
     arrival — measured, not assumed: a real credential fires while `///`, `//`
     and `/*` suppress. `check-lifecycle` already modeled Swift `M` across all
     four categories. Both were audited and their contracts annotated; neither
     diff touches a detector. A phase's size is set by what is already modeled,
     not by the number of governed scanners.
   - **`check-code-health`'s Swift `empty-handler` could not reuse the js/java
     arm**, and this is the mechanical reason #622's headline bug survived so
     long. Swift's `catch` takes no parenthesized parameter, while that arm's
     pattern requires one — so no amount of extension-list widening would ever
     have matched a Swift `catch { }`. A language whose syntax differs in SHAPE
     rather than in keyword needs its own arm, and the matrix cannot show that
     distinction: `M` looks the same either way.

   Swift's `debugger` cell is `—` and that is a real absence rather than an
   unwritten arm: a Swift breakpoint is an lldb/Xcode action, not a source token,
   so there is nothing analogous to `dbg!` or `pdb.set_trace` to key on. It is
   pinned by a fixture asserting `breakpoint()` in a `.swift` file stays silent —
   an empty column is otherwise unfalsifiable.

   **A word-boundary lesson for every future phase, found by review rather than
   by the mutation round.** The Python arms may write `\b`; the bash arms may
   not, because `\b` is a GNU extension BSD grep reads as a literal. So each
   boundary must be spelled long-hand — and *both* sides matter. Phase 2's first
   draft guarded only the leading side and asserted in a comment that the
   trailing side was "carried by `[[:space:]]*[^{}]*\{`". That was false:
   `[^{}]*` excludes only the two brace characters and matches identifier
   characters freely, so `catches { }`, `catcher { }` and `catchAllErrors { }`
   were false positives on the bash runtime alone. The fixture written for the
   leading side (`mycatch { }`) passed throughout, which is why the round missed
   it — an identifier-*ends*-with fixture cannot fail on an
   identifier-*starts*-with bug.

   The correction has a second edge worth carrying forward: ERE has no
   lookahead, so a trailing `[^[:alnum:]_]` **consumes** the character it tests.
   For the brace-adjacent `catch{ }` the only thing following `catch` is the
   brace itself, so consuming it left nothing for `\{` and that line went silent
   in bash while Python still fired — a second divergence introduced by the fix
   for the first. Spell the trailing boundary as an alternation of the ways the
   construct can legally continue (`catch([[:space:]][^{}]*)?\{`), not as a
   negated class. Both directions are now fixture-pinned in both runtimes.
3. **Phase 3 — TypeScript / JavaScript** ([#840](https://github.com/joshjhall/librarian/issues/840)) — **landed**. The issue named two
   gaps; the audit measured **four**, and the extra two are the interesting part.

   **`.mjs`/`.cjs` were missing from four detector arms, in both runtimes:**
   `check-code-health`'s `empty-handler`, `check-security`'s `injection-risk`,
   all four of `check-lifecycle`'s categories, and
   `check-docs-missing-api`'s sole arm. Only `check-code-health`'s two
   `debug-statement` families had them.

   **The shared-region boundary predicted exactly which arms were stale, and
   that is the reusable finding for Phases 4 and 5.** The two arms that carried
   `.mjs`/`.cjs` are the two inside `# >>> shared:` sync regions; every arm
   outside one was left behind. #568 widened the extension list where
   `validate-shared-scanner-sync.sh` was watching, and nowhere else — so a
   future extension widening should be assumed to have reached the synced arms
   only, and every unsynced arm re-checked by hand. The symptom was an
   intra-scanner contradiction: a `console.log` in `foo.mjs` was caught while an
   empty `catch {}` in the same file was not.

   **Why no gate caught this.** Every one of the four gaps was **symmetric**
   across the two runtimes — py and sh were short in identical ways — so
   `validate-python-ports.sh` compared two silences and passed. That is the
   failure its own header warns about ("both impls break the same way"), and it
   means dual-runtime parity is structurally incapable of finding a missing
   extension. The per-cell matrix check (#847) could not see it either: the
   matrices were *accurate*, honestly recording the narrowing as
   `M (js/jsx only)`. A correct description of a defect still describes a
   defect.

   **The TS-vs-JS split question (the phase's open design question): answered
   NO, deliberately — keep the distinct lexical keys, do not split the arms.**
   #726's reasoning does not transfer. It split TS from JS in the decomposition
   lens because `UNIT_RE` is a **segmenter**: it must recognize
   `interface`/`type`/`enum`/`namespace` to find unit boundaries, so aliasing TS
   to JS made every type-level declaration invisible. The four scanners here are
   **line scanners** with no unit model. The only place a language key is
   consumed is `COMMENT_RE`, where `js` and `ts` are byte-identical
   (`^[ \t]*(?://|/\*|\*)`) and correctly so — TS and JS spell comments the same
   way.

   One caveat, measured rather than assumed: `check-docs-missing-api`'s shared
   arm matches `type|interface|enum`, and it **does** fire on
   `export interface Foo {}` in a `.js` file — a line scanner matches the text
   whether or not the syntax is legal JavaScript. That is a tolerable
   over-match, not a harmless impossibility: such a line is either TypeScript in
   a misnamed file or a genuine syntax error, and reporting it undocumented is
   defensible in both cases. It is recorded here because the tempting version of
   this argument — "those forms cannot appear in JS, so the superset is inert" —
   is false, and a future phase should not lean on it.

   The keys stay **distinct** (not merged) for two reasons: § 2's subset rule
   forbids contradicting the normative table, which has them distinct; and a
   future TS-only detector needs somewhere to attach. But splitting the arms
   today would add four branches with byte-identical bodies and no behavior
   change. **A shared key is not the same defect as a shared arm** — the
   question to ask of a future language pair is whether any detector *branches*
   on the distinction, not whether the languages differ.

   **Measured effect.** On this repo's own 26 tracked `.mjs`/`.cjs` files the
   widening produces **+26 rows**, all `undocumented-public-api` — real by that
   detector's declared contract (its JS doc marker is `/**`; `bin/*.mjs` and
   `tests/**/*.mjs` document their exports with `//` instead). The
   `check-code-health` rows on those files were already firing before the
   change, via the debug arms that already covered the extensions.
4. **Phase 4 — Python** ([#841](https://github.com/joshjhall/librarian/issues/841)) — **landed**. The inverse of Phase 3: the
   issue named three items and the audit confirmed **all three as stated**, with
   no fourth. Python's four matrix rows were already accurate, and
   `check-security`'s Python arms already consulted the lexical model — verified
   by probing both directions in both runtimes rather than by reading the source.
   **An audit that finds the matrices correct is a result, not a wasted phase**;
   Phase 3's four-gaps outcome is not the expected one.

   **The one real gap was `check-lifecycle`'s `unpaired-listener`**, absent for
   Python in both runtimes. Filled, keyed on registration idioms chosen by
   measured rate over the 3.12 stdlib — the *opposite*, sparse profile to the
   `let _ =` Phase 1 refused, which is what justified shipping at MEDIUM rather
   than deferring. The rates, the `threading.Timer`-in / bare-`Timer(`-out call,
   and the single-alternation parity constraint are in
   `check-lifecycle/contract.md`.

   **The docstring question, answered: NO — line-prefix is sufficient**, for
   these scanners and for `loc_engine.COMMENT_RE` alike. The short reason: a
   `"""…"""` block is a string literal, not a comment, and
   `check-docs-missing-api` keys on `"""` as Python's **doc marker** — so a model
   that hid docstrings would make that arm report every documented symbol as
   undocumented. The full decision, its three grounds and its measured cost live
   in `check-code-health/contract.md` § *Python docstrings are NOT modeled as
   comments*; read that before proposing a block-comment dimension.

   One methodological note belongs here rather than there: **measure a docstring
   claim with `ast`, not with a regex.** The first pass used a quote-pairing
   regex and reported six in-docstring rows; all six were artifacts of
   mispairing quotes inside the one file that *defines* a docstring regex.
   Widening the corrected check to any multi-line string then surfaced a real
   neighbour — 3 `tech-debt-marker` rows inside multi-line **regex literals**.
   Hence the phase's headline is "zero **docstring** rows", never "zero string
   rows": two different claims, only the narrower one true.

   **Two lessons from the mutation round, both about the fixtures rather than the
   arm.** They are the reusable part of this phase:

   - **A boundary comment asserted a property the code did not have.** The arm's
     leading class was first written `[^\w.]`, excluding `.` on the stated
     theory that `mysignal.signal(` would otherwise match on its attribute-access
     tail. Mutating the `.` away produced *no* test failure, which is what
     exposed the claim: the plain `[^\w]` already rejects that line. What the
     exclusion actually did was silence the **qualified** forms, which are true
     positives. A false rationale had been protecting a false negative, and only
     the mutation could tell the difference — #542/#498's shape reached through a
     regex. Detail: `check-lifecycle/contract.md`.
   - **The fixture written to pin that true positive was itself vacuous at
     first.** It put both qualified forms in ONE file; the two idioms sit in
     different halves of the alternation and share one evidence label, so
     re-applying the mutation left one silent while the other still emitted the
     label — `assert_fires` passed and the fixture proved nothing. Split per
     half, the same mutation goes red. The composite-fixture trap the function's
     own header warns about, hit anyway while writing the fixture *for* a
     mutation: **a fixture is not load-bearing until a mutation has actually
     turned it red.**
5. **Phase 5 — Bash** ([#842](https://github.com/joshjhall/librarian/issues/842)) — **landed**. Closes #622. The issue asked for arms in
   three scanners; the corpus granted **one**, and the declines are the phase's
   substance rather than its shortfall.

   **This phase could measure before implementing, and every other phase should
   want to.** The corpus is this repository — 299 tracked `.sh` files, 119,139
   lines — so a proposed detector's false-positive rate was a `grep` away rather
   than an estimate. Results, against each scanner's declared tier:

   | Proposed idiom | Scanner (tier) | Hits | Verdict |
   | --- | --- | --- | --- |
   | `\|\| true` | code-health (HIGH) | 1009 | refused |
   | `set -x` / bare `echo` | code-health (HIGH) | 0 / 238 | refused |
   | unquoted `$` into `eval` | security (CRITICAL) | 1 | refused |
   | SQL string + expansion | security (CRITICAL) | 32, ~all FP | refused |
   | `exec N>` unclosed | lifecycle (MEDIUM) | 0 | `—`, real absence |
   | temp file, no `trap` | lifecycle (MEDIUM) | 48 of 123, ~all FP | `—`, unreachable |
   | trailing `&`, no `wait` | lifecycle (MEDIUM) | 6, 0 FP | **shipped** |
   | `kill -TERM` | lifecycle (MEDIUM) | 4 | **shipped** |

   **`|| true` is Phase 1's `let _ =` reached from another language.** Both are
   real signals at a *lower* tier and unshippable at HIGH; both scanners lack a
   per-detector certainty, so the honest verdicts were "wrong tier" or "not yet".
   Two phases hitting the same wall from two directions is what makes it
   structural rather than incidental, and it is now filed as
   [#1003](https://github.com/joshjhall/librarian/issues/1003) —
   recording *why* a decline is a tier problem is what lets someone revisit it,
   whereas "not implemented" reads as "not worth it" forever.

   **The single `eval` hit is a test fixture inside a markdown heredoc.** Worth
   stating because a raw count of 1 looks shippable until the hit is inspected;
   the safe quoted form matches 52 times in the same corpus.

   **Two of the refusals are refusals for opposite reasons, and the table above
   would read as one verdict if it did not say so.** `exec N>` is declined
   because the idiom is **absent** (0 hits — nothing to detect). The trap-less
   temp file is declined because it is **everywhere and unreachable**: 48 of the
   123 `mktemp` callers declare no `trap`, and nearly all are correct anyway —
   most are `.`-sourced test fragments whose **parent** owns the trap. A
   single-line regex is looking for a statement in a different file. *A zero and
   a flood are both `—`, and recording only the verdict loses which one it was.*

   **`check-security` needed no code change — the third consecutive phase to find
   its subject already modeled.** Bash resolves there by four independent paths
   (extension, hash-family, shell dotfiles, and the shebang resolver). Phase 2's
   lesson generalizes: **a phase's size is set by what is already modeled, not by
   the number of governed scanners.** An audit that finds a matrix correct is a
   result; the phase's cost then goes into fixtures that make the correctness
   re-checkable, not into a diff.

   **The lexical model cannot see a TRAILING comment, and one arm's correctness
   depended on that.** `is_comment()` matches line-**start** only, so the corpus's
   sole false positive — an `&` inside a trailing comment on an assignment line —
   was unreachable by the comment model and had to be excluded structurally
   instead. A future arm should not assume the lexical gate covers a mid-line
   comment; it covers a comment *line*.

   **The parity gate failed to catch this phase's defects three times, in three
   different ways — and the third is the one worth carrying forward.**

   *Vacuously.* The first draft's exclusion was spelled differently per runtime
   (bash filters `grep -n` output, whose `NNN:` prefix an `^`-anchored pattern
   binds to instead of the source line), so it excluded nothing on the bash side
   only — exactly the asymmetric divergence the gate exists to catch. It did not,
   because the corpus fixture written to exercise it *lacked a trailing `&`* and
   reached no arm at all. **Add the corpus line, then prove it reddens; a fixture
   believed to be non-vacuous is not.**

   *By construction.* The eventual fix made that exclusion **unanchored**, which
   cannot acquire the bug. Where the rule permits it, prefer the spelling that
   makes the trap unreachable over the one that documents it.

   *Blindly.* Both defects that survived to review were **shared**: the match
   class excluded the quote characters (so `curl "$url" &` — most real background
   jobs — never matched), and the exclusion keyed on assignment shape, a proxy
   that covered the one corpus false positive while silencing every env-prefixed
   and compound one-liner. Both were byte-identical in the two runtimes, so
   parity was *perfect* and *wrong*. **A parity gate answers "do these agree",
   never "are these right"** — it is structurally incapable of seeing a shared
   defect, so it must never be the only thing asked. What found these was reading
   the pattern against shapes no fixture contained; what prevents the next one is
   that the corpus fixture now carries all six.

Defects found while writing this ADR, filed separately because each needs its own
mutation-tested fixture:

- [#836](https://github.com/joshjhall/librarian/issues/836) — `check-lifecycle`'s
  bash `is_test_file` is path-crossing, so real source under any `test_*/`
  directory is silently skipped on the bash runtime only. A live py/sh parity
  break that every gate currently misses.
- [#837](https://github.com/joshjhall/librarian/issues/837) — the
  `hardcoded-secret` denylist is an unanchored substring match, so real secrets
  are silently missed. Should land in or just before Phase 1.
