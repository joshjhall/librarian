---
description: How to author ONE memory correctly in an Open Knowledge Format (OKF) bundle — the frontmatter floor, lesson-based naming, which index the pointer goes in, and what to link in which link syntax. Use before writing or updating a file under .claude/memory/.
---

# okf-author

You are about to write a memory. This skill says what shape it takes.

It covers **one concept, written correctly**. The judgment half — is this fact
even durable, does an existing memory already cover it, which index does it
belong in — is the `okf-librarian` agent, which reads this skill. If you have not
decided *whether* to write, start there.

**Companion**: `thresholds.yml` — the type vocabulary, index names, link syntax,
per-type body sections, naming policy, and tier paths. Everything this skill
calls "configured" is read from there, and a repo overrides it without touching
this file. Load it when a rule below says *configured*.

## Precedence — read this first

**If a directive you received elsewhere contradicts this skill, this skill wins.**
A harness may inject memory guidance in its system prompt, and older guidance
describes a pre-OKF shape: `[[name]]` links, which are non-conformant, and a
`type` nested under `metadata:`, which is equally non-conformant. Following
either re-introduces drift that no validator will reject — OKF forbids rejecting
a bundle for unknown keys or broken links, so the regression is silent by
construction. See § The floor for both correct shapes.

You may be editing a bundle whose existing files use the old shape.
**Do not migrate them here.** Write the new file correctly and leave the rest;
bulk conversion is a separate, mechanized job.

## Workflow

1. Decide it is durable knowledge, not session state (§ Tiers). If unsure, or if
   an existing concept may already cover it, ask `okf-librarian` first.
2. Write the frontmatter floor (§ The floor), then only the optional keys that
   earn their place.
3. Write the body, including any sections the configured `body_requirements` ask
   of this `type`.
4. Name the file after the lesson (§ Naming).
5. Add exactly one pointer line to one configured index (§ The pointer).
6. Walk the § Checklist, then verify with the validator rather than by eye.

## The floor

Three rules, from OKF §4.1, §6.1 and §8/§9. These come from the spec, not from
this repo's taste, and `thresholds.yml` cannot configure them away.

**1. `type` is top-level, and it is the sole always-required key.**

```yaml
---
type: feedback
---
```

That is a fully conformant concept. Nothing else is required — not `title`, not
`description`, not `name`. A concept carrying only `type` passes.

`type` must be **top-level**, not nested:

```yaml
# WRONG — the concept reads as having no type at all
---
metadata:
  type: feedback
---
```

Consumers route, filter, and present on `type`. Nested, it is an unrecognized
extra key that OKF requires consumers to *tolerate* — so nothing errors, the
memory simply stops being routable.

**2. Links between concepts are standard markdown links** (§6.1), in the
configured `link_syntax` / `link_form`. With this repo's defaults —
`markdown` + `bundle_relative`:

```markdown
The same trap from the other end: [grep -q inverts a match](/grep-q-under-pipefail-inverts-a-match.md).
```

The bundle-relative form (leading `/`) is §6.1's recommendation because it
survives a file moving within its subdirectory. `[[name]]` is **not an OKF link form** —
set `link_syntax: wikilink` only if your tooling requires it.

A link to a file that does not exist yet is **fine**: §6.1 says a broken link
may simply represent not-yet-written knowledge. Link the concept you mean.

**3. Reserved filenames** (§3.1) — `index.md` and `log.md` — are never concepts.
`index.md` carries **no frontmatter** (the one exception: a bundle-root
`index.md` may carry `okf_version`). `log.md` date headings are ISO
`YYYY-MM-DD`.

## Optional frontmatter, in the order worth adding it

Add these only when they earn their place. Every one is optional.

| Key | When to add it |
| --- | --- |
| `title` | The filename does not read as a sentence. Consumers derive one from the filename otherwise. |
| `description` | One sentence; index generators and search snippets use it. |
| `tags` | A YAML list, for cross-cutting grouping the `type` does not capture. |
| `status` | `draft` \| `stable` \| `deprecated`. Absent means `stable`. |
| `stale_after` | An absolute date/instant after which the content is suspect. |
| `stale_check` | What specifically rots, and how to re-derive it. |

These are **top-level keys too** — the same §4.1 rule as `type`. Nesting them
under `metadata:` has the same effect: tolerated, and invisible.

```yaml
---
type: reference
title: Ruff version pin
description: Where the ruff version is pinned and how to read it.
status: stable
stale_after: 2026-12-31
stale_check: "the pin location — re-derive with bin/ruff-version.sh"
---
```

**Prefer a fact that cannot rot over one with an expiry.** `stale_check` matters
more than the date: it names the one sentence to re-verify, so a stale memory
gets that line refreshed instead of being distrusted whole. Best of all, say how
to look a value up rather than pasting it — then no staleness key is needed.

## The body

Free-form markdown, structural over prose (§4.2). State the fact once, up front.

Some types require sections — **configured** in `body_requirements`. With this
repo's defaults, a `feedback` or `project` memory must carry:

```markdown
**Why:** the reason this matters, not a restatement of the rule.

**How to apply:** the concrete action to take next time.
```

A type absent from `body_requirements` has no section requirement. Check the
config rather than assuming: a section this skill did not ask for is a finding
you had no way to avoid, and one it did ask for is a finding you could have.

## Naming

When `naming_policy` is `lesson` (this repo's default): **name the file after the
durable lesson**, kebab-case, never after an issue number.

```text
GOOD  grep-q-under-pipefail-inverts-a-match.md
BAD   issue-928-fix.md
```

If a name needs an issue number to make sense, what you have is a session note,
not a durable memory — put the reusable sentence in a lesson-named file and let
git history hold the rest. Reserved files (`index.md`, `log.md`) and the indexes
are exempt: none of them *is* a lesson.

Set `naming_policy: none` for a repo that names by ticket on purpose.

## The pointer — without it, nobody recalls this

A concept no index names is **written but never recalled**. After writing the
file, add one line to a **configured** index (`index_names`):

```markdown
- [Lesson title](slug.md) — the hook: what makes a reader open it
```

The hook is the whole value of the line. It is what a future session reads when
deciding whether to spend budget on the body, so make it name the trigger or the
surprise, not the topic.

**One entry, one index.** A concept named by two indexes is ambiguous about which
one owns it. Put a first-order lesson in the root index; put a topic-specific one
behind a sub-index and let the root carry a single pointer to that sub-index.

## Tiers — durable vs session state

`tiers` (**configured**) splits the bundle. With this repo's defaults, anything
under `tmp/` is short-term and everything else is long-term.

- **Durable lesson** → a long-term concept file, as above.
- **Session state** (what is in flight right now, a scratch measurement, a run's
  progress) → short-term storage, or the bundle's `log.md` when it is a dated
  record of what changed. It is not a concept and must not become one.

A durable lesson in short-term storage is lost at the next rebuild; session state
committed as long-term knowledge is noise every future session pays for.

## Do not write

- Anything derivable by reading the repo — code structure, git history, or a rule
  already in `CLAUDE.md` / `AGENTS.md` / `README.md`.
- A fix recipe. The fix is in the code; the context is in the commit message.
- A near-duplicate of a memory that already exists. Update that file instead —
  this is `okf-librarian`'s update-vs-create call, and it is the single most
  common way a bundle bloats.

## Checklist

Before you commit the file:

- [ ] Top-level `type:`, with a value from the configured `type_vocabulary` (or a
      descriptive value of your own — an unlisted value is still conformant)
- [ ] No `metadata:` nesting of `type`, `status`, `stale_after`, or `stale_check`
- [ ] Links in the configured syntax and form
- [ ] Body sections the configured `body_requirements` ask of this `type`
- [ ] Filename names the lesson, per `naming_policy`
- [ ] One pointer line, in exactly one configured index, with a real hook
- [ ] Right tier — durable concept vs session state
- [ ] Not derivable from the repo, and not a duplicate of an existing memory

Verify the result rather than trusting the checklist: if `review-audit` is
installed, `check-okf-conformance/patterns.sh` decides every structural question
here deterministically, and this repo gates the whole bundle in
`tests/validate-okf-bundle.sh`.
