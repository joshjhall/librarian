---
description: How much of a file to pull into context per read — ask for the narrowest range that could answer the question, widen on a miss, and never let a clamp cut silently. Use when reading a file with sed/cat/head, when a read comes back large, or when adding a ceiling to any tool output.
---

# Reading Granularity

A tool result does not cost once. It is re-sent with every subsequent request
for the rest of the session, so an oversized read is a **recurring** charge on
every turn that follows it.

Measured over 24h (#786): tool results are **48% of transcript volume** and
carry **76% of all re-read debt** (Bash alone, 138.9M tokens). The two
instruments are the shell reads:

| command | calls | result chars | average |
| --- | ---: | ---: | ---: |
| `sed` | 300 | 737,444 | **2,458** |
| `cat` | 85 | 153,823 | **1,809** |
| `grep` | 598 | 194,424 | 325 |
| `git` | 420 | 215,331 | 512 |

Largest single result observed: **21,562 chars** — one `sed -n '560,965p'` to
answer one question about one function. At ~5.4k tokens, re-sent across an
800-turn session, that single read costs several million tokens.

`grep` is on that list too and is *fine*: 598 calls for 325 chars each. The
problem is not reading. It is reading **wide** when narrow would have answered.

## The rule: name the narrowest range that could hold the answer

**Decide the range before you run the command, and size it to the question —
not to the file.**

```text
read the narrowest range that could contain the answer.
widen only after the narrow read has actually come back insufficient.
```

That is the whole test. It is decidable at the moment you need it, because it
asks only what you already know — what you are looking for — and nothing about
what the read will return.

In practice:

- You want one function → the line range you saw in a `grep -n`, not the
  400-line region around it. Prefer a numeric range over a
  pattern-to-blank-line range like `/^def foo/,/^$/p`: a docstring or a blank
  line inside the body ends it early, and a body with none runs it on into the
  next function — both silently.
- You want to know whether a symbol exists → `grep -n`, not `cat`.
- You want a file's shape → `grep -n '^## \|^def \|^function '`, not the file.
- You want the whole file → read the whole file. Small files exist, and
  `cat` on a 40-line script is the narrowest range that answers.

## Widening is normal, not a failure

**Say this to yourself explicitly, because the alternative is the actual
failure mode.** A narrow read that misses costs one more round-trip. A wide
read that hits costs every remaining turn in the session. The asymmetry is
large and it runs one way.

So a second, wider read is a **success of the method**, not evidence you should
have read wide first. An agent that treats re-reading as a mistake will read
defensively — 400 lines "to be safe" — which is precisely the behavior this
skill exists to remove.

## Prefer codegraph for "how does X work"

When the question is about symbols and their relationships rather than a
specific line range, the `codegraph_explore` MCP tool returns the relevant
symbols' verbatim source **plus** the call paths between them in one capped
call. That is strictly less volume than a range guess, and it does not require
knowing where to look first.

Use it for: "how does X work", "what calls this", tracing a flow across
symbols. Use a narrow `sed`/`grep` when you already know the file and lines —
a targeted read is cheaper than any tool call that has to search.

Codegraph answers from a **per-project** index, and availability is not the
same as the directory being present — measured in a git worktree whose
`.codegraph` is a symlink, the tool still reported the project unindexed. So
treat its own refusal as the check: if it says the project is not indexed, fall
back to the narrow reads above for that project and do not retry it in the same
session. Indexing is the user's call, not something to run unprompted.

## Truncation must be loud

**A cap that quietly drops the tail is worse than no cap**, because the reader
reasons confidently over a partial value and has no way to tell. A silently
trimmed list reads as a complete one; silently trimmed evidence reads as a line
that ended where the text stopped.

So any ceiling you add must mark the cut **in the value itself**, where whoever
reads it will see it. This repo's own examples:

| clamp | marker |
| --- | --- |
| `ship-issue/workflow.js` `PRESCAN_MAX` | *"N further candidate(s) were omitted for size — this list is NOT exhaustive."* |
| `ship-issue/workflow.js` `DIGEST_MAX_CHARS` | *"AND IT WAS TRUNCATED for size"* |
| `truncate_chars` (15 bash copies + 14 python peers) | a trailing `…`, appended only when the slice actually cut |

Two properties, both required. The marker must appear **when it cuts**, and it
must be **absent when it did not** — a clamp that always appends is as
uninformative as one that never does. `tests/lint-truncation-markers.sh` gates
both.

## The byte-faithful exemption — do not cap these

**Some outputs are exact by design, and a ceiling there corrupts the artifact.**

The review diff is the standing case (#267): the bytes handed to a reviewer
*are* what they review, so `ship-issue/workflow.js` ingests `args.diff`
unclamped and never slices it, even when it is large. The exemption is
deliberate and test-pinned (the `*-BYTE-FAITHFUL-*` sentinel in
`tests/workflow-helpers/ship-issue/04-tdz-and-diff.mjs`).

Before adding any ceiling, ask whether fidelity is the point of the value. If
it is — a diff, a hash, a signature, a file being written back — it is exempt,
and the exemption belongs in a test so a later "cap everything" sweep cannot
quietly fold it in.

## Relation to `delegating-investigation`

The two are sequential, not alternatives:

- **`delegating-investigation`** decides **who reads** — if you cannot yet name
  the file and line range, that is fan-out and it belongs in a subagent.
- **This skill** decides **how much comes back per read**, and applies to the
  reads you do yourself once the location is known.

A delegated investigation is also bound by the volume rule at its own boundary:
it must return the answer and `file:line` anchors, not a transcript of what it
read. Otherwise the parent absorbs the exploration anyway.

Do not read this skill as a reason to read wide inline rather than delegate.
The two rules point the same direction — less material in the parent context.

## When to Use

- Before any `sed`/`cat`/`head` read, when choosing the range
- When a result comes back much larger than the question warranted
- When adding or reviewing a ceiling on any tool output or generated value
- When deciding between a range read and `codegraph_explore`

## When NOT to Use

- Inside a review harness reviewer — its diff is byte-faithful by design, and
  `SCOPE_DISCIPLINE` already bounds its exploration
- When the value must be exact (see the exemption above)
- To justify skipping a read you actually need — the rule narrows reads, it
  does not skip them
