---
name: check-what-already-shipped-before-scoping
description: "A multi-mode bug issue can be partly or wholly fixed by PRs that never referenced it — map each named mode to merged code before planning, or you re-implement shipped work"
type: feedback
metadata:
  node_type: memory
  originSessionId: 148628b2-70e3-48fa-af65-b354e70a89e4
  modified: 2026-11-09T19:00:11.926Z
---

An issue listing several failure modes ages while unrelated PRs fix some of
them, often without linking back. #446 (golem-status BLOCKED list) named four
modes; two were already shipped under other issues (#422, #323) when it was
picked up, and after PR #464 fixed the other two, the issue was closed with
**no PR at all**: the golem mapped every mode to its merged PR, verified those
functions were still intact despite five later PRs touching the same files, and
posted a closing summary instead of redoing the work.

**Why:** the issue text is a snapshot from when it was filed; the tree is the
current truth. Planning from the text alone produces duplicate implementations,
and churned files can silently lose an earlier fix — so "was fixed" and "is
still fixed" are separate checks.

**How to apply:** before scoping, list each mode/AC the issue names and grep
the current tree and `git log --grep` for its fix. For each, record either
*fixed by #N* or *still open*. If everything is code-complete and only live-verification ACs
remain, close it with that mapping (or narrow it via
[[umbrella-issue-closes-vs-contributes]]) rather than opening a PR. See also
[[deferred-work-may-be-doable-now]] — the same "the issue's stated state may be
wrong" check, from the other direction.
