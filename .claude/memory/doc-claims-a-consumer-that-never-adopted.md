---
name: doc-claims-a-consumer-that-never-adopted
description: "A shared doc's header names its consumers; one of them never adopted it. The claim reads as evidence of integration, so nobody greps — measure adoption from the CONSUMER side, per call site"
metadata:
  node_type: memory
  type: feedback
---

`golem/background-work.md` opened with *"on-demand companion for `golem/`,
`next-issue/`, and `ship-issue/`"*. Two of the three had adopted it. `ship-issue`
referenced it **zero** times (#890) — and `ship-issue` was where **all five** of
the measured false-idle reports the protocol exists to prevent had happened.

The mechanism is [[comment-asserts-intent-not-code]] one level up: not a comment
asserting a property of its own function, but a **doc asserting who uses it**.
It is worse in one specific way — a comment sits beside the code that falsifies
it, while a consumer list points at files that are somewhere else entirely, so
falsifying it takes a deliberate grep nobody runs. The mechanism reads as
integration *evidence*, which is exactly what stops the check.

**Why:** a consumer list is an assertion about files that live somewhere else, so
it reads as integration evidence while being unverified by construction. That is
strictly worse than a wrong comment: a comment sits beside the code that falsifies
it, whereas falsifying a consumer list takes a deliberate grep in another
directory that nobody runs — least of all the person who just wrote the list.
`ship-issue` was named as a consumer and had zero references, and that is where
every one of the five measured failures happened.

**How to apply:** when a shared artifact (a protocol doc, a helper, a schema)
names its consumers, verify from the **consumer side**, per call site:

```bash
grep -rn "<artifact>" plugins/**/<claimed-consumer>/ | wc -l   # 0 is the finding
```

Then ask the sharper question: *where does this consumer actually do the thing?*
Enumerate the call sites, not the file. Two things fell out of doing that:

- The adoption gate's own trigger, once measured, **found a fourth call site**
  the manual sweep had missed — a backgrounded `ci-fixer` harness whose prose
  said "Invoke it as a background task" verbatim.
- The **mechanism landing is not the fix landing.** #890's classifier (#954) and
  registry (#949) both shipped and the issue still had a live gap. When an issue
  spans several PRs, re-derive the ACs against the tree before assuming the
  remainder is cleanup — see [[issue-symbol-inventory-needs-remeasuring]].

**Ship the prose with a gate.** A pointer added by hand drifts on the next edit,
so the fix is a lint gate over the same class (`lint-background-work-refs.sh`,
modeled on `lint-harness-refs.sh`). Two properties earn their keep: **section
scope** (a whole-file satisfier passes when a new site lands 3 screens from an
old mention) and a **two-line window** (the trigger phrase wraps in real prose;
a single-line matcher is green before the fix and green after).

And measure the trigger before shipping it — see
[[detector-needs-a-certainty-tier]]. The obvious wide trigger fired on 11
sections, 8 in `orchestrate/`, which **observes** this work rather than starting
it; demanding registration there would make the gate assert something false.
