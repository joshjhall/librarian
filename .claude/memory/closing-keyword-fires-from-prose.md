---
name: closing-keyword-fires-from-prose
description: "GitHub matches close/fix/resolve + #N ANYWHERE in a commit message — a sentence explaining why you did NOT use a closing trailer will itself close the issue"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8c18d381-5905-4b08-a734-d468be4e3b1b
  modified: 2026-09-06T22:16:11.512Z
---

A closing keyword is recognized **anywhere in the message**, not only in a
trailer position and not only at the start of a line. So prose *about* closing
keywords behaves exactly like a real one.

Measured on librarian #936. The squash commit deliberately said
`Contributes to #936` (one of eight ACs shipped elsewhere), and the PR's
`closingIssuesReferences` was verified **empty** before merging. The merge still
closed the issue. The culprit was the sentence justifying the trailer:

```text
a `Closes` trailer here would auto-close #936 on squash with that AC unshipped
```

GitHub matched the `close #936` inside **auto-close #936**. The hyphenated prefix
does not protect it.

**Why:** the parser scans for `(close|closes|closed|fix|fixes|fixed|resolve|
resolves|resolved) #N` as a token pair. It has no notion of trailer position,
backticks, negation, or the sentence saying you are not doing the thing.

**How to apply:** when writing a rationale for `Contributes to #N`, keep the
issue number out of any clause containing a close/fix/resolve word. Write "would
close that issue" or "would auto-close it" — never "auto-close #N". And verify
after merging, not before: `gh issue view N --json state`, because
`closingIssuesReferences` reads empty for this case
([[closes-trailer-in-squash-commit]] covers the trailer-in-commit-body half).
Recovery is `gh issue reopen N` plus a comment saying why.

Related: [[umbrella-issue-closes-vs-contributes]],
[[verify-blocked-action-before-reporting-it-blocked]].
