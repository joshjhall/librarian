# check-okf-conformance — Output Contract

Reference companion for `SKILL.md`. Defines the finding format for OKF
bundle-conformance pre-scan results.

## Contract Version

```yaml
version: "1.0"
compatible_with: "finding-schema.md >= 1.0"
```

## Categories

The structural categories are decidable from the document itself, so they emit
at certainty `HIGH` (method `deterministic`) rather than as candidates awaiting
LLM confirmation. `okf-version-drift` is `LOW`: it is a fact worth surfacing,
not a defect — see the exit-code note below.

The `memory-*` categories come from the whole-bundle health pass (#669) and are
decidable from the bundle rather than from one document. `Kind` below says which
pass a row came from, and what a consumer should conclude from it.

| Category                      | Kind        | Certainty | Method        | Confidence |
| ----------------------------- | ----------- | --------- | ------------- | ---------- |
| `okf-missing-type`            | conformance | HIGH      | deterministic | >= 0.9     |
| `okf-unparseable-frontmatter` | conformance | HIGH      | deterministic | >= 0.9     |
| `okf-reserved-file-structure` | conformance | MEDIUM    | deterministic | >= 0.9     |
| `okf-version-drift`           | conformance | LOW       | deterministic | >= 0.9     |
| `memory-orphan`               | health      | HIGH      | deterministic | >= 0.9     |
| `memory-dangling-index`       | health      | HIGH      | deterministic | >= 0.9     |
| `memory-multi-index`          | health      | HIGH      | deterministic | >= 0.9     |
| `memory-stale`                | health      | MEDIUM    | deterministic | >= 0.7     |
| `memory-missing-why`          | health      | MEDIUM    | deterministic | >= 0.7     |

### Kind — conformance failure vs health observation

This skill emits two different kinds of claim, and a consumer must be able to
tell them apart **without parsing the category name**:

- **conformance** — the bundle violates the OKF schema floor. An objective
  defect against a published spec.
- **health** — the bundle is conformant but structurally weaker than it could
  be. An observation about usability, not a spec violation.

`Kind` is documentation; **`certainty` is the machine-readable carrier**, and the
two health tiers are the lever:

- A health category emitting `HIGH` (`memory-orphan`, `memory-dangling-index`,
  `memory-multi-index`) is a **pure graph fact** — the file is either named by an
  index or it is not, and no judgment is involved. Safe to act on directly.
- A health category emitting `MEDIUM` (`memory-stale`, `memory-missing-why`) is a
  **candidate for Pass 2**, the same grade `check-lifecycle` uses for its
  deterministic rows. Both depend on operator configuration, and both can be
  deliberate: a memory may be pinned to an old date on purpose, and a body
  convention may not apply to every file carrying a type. The scanner states the
  fact; the LLM pass judges whether it matters.

The checker collects both grades; certainty decides only whether a row takes the
auto-include fast path or is handed to Pass 2 as a candidate.

**Every category above is emitted at exit 0** — health categories included. A
non-conformant bundle is reported, never rejected (OKF §11/§12), and a health
observation is further still from a rejection: §11 explicitly forbids rejecting a
bundle for broken cross-links or missing `index.md` files. Non-zero exits are reserved for
tool-side failures — an unresolvable version pin, a usage error, or an
unreadable file list. See `SKILL.md` § "Permissive conformance".

## Finding Format

Each finding extends the standard finding-schema.md:

```json
{
  "id": "check-okf-conformance-001",
  "category": "okf-missing-type",
  "severity": "medium",
  "title": "Concept has no type field",
  "description": "OKF §4.1 makes `type` the sole always-required frontmatter key: consumers use it for routing, filtering, and presentation. A concept without one cannot be routed, though a concept carrying only `type` is fully conformant. Any short descriptive string is valid — values are not registered centrally and consumers must tolerate unfamiliar ones.",
  "file": "<bundle-root>/some-concept.md",
  "line_start": 1,
  "line_end": 1,
  "evidence": "Concept frontmatter has no type key",
  "suggestion": "Add a `type:` key to the frontmatter block with a short, self-explanatory value",
  "effort": "trivial",
  "tags": ["conformance", "memory-bundle"],
  "related_files": [],
  "certainty": {
    "level": "HIGH",
    "support": 1,
    "confidence": 0.9,
    "method": "deterministic"
  },
  "pre_scan": true,
  "skill": "check-okf-conformance"
}
```

The `file` path is shown as `<bundle-root>/...` rather than a concrete root.
The root is resolved from the environment with a configurable default (see
`SKILL.md` § Bundle discovery), so a concrete path in a portable tool's contract
would read as though it were fixed. Emitted findings carry the real path.

## Evidence

Evidence is a category label plus, where it aids diagnosis, a short fragment of
the offending line (a non-ISO date heading, a declared version). It is capped at
80 characters and **never carries a document's body** — a memory bundle holds
operator-specific working notes and, in a consumer repo, material this repo has
never seen.

## ID Format

`check-okf-conformance-<NNN>` (e.g., `check-okf-conformance-001`)
