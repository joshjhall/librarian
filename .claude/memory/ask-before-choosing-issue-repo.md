---
name: ask-before-choosing-issue-repo
description: "When a follow-up issue could be filed in more than one repo (this repo vs an upstream/submodule repo), ask where before filing — don't default silently"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 2bb72d45-46df-4138-bb3b-9e8a5ad11257
---

When work surfaces a follow-up whose fix spans repos (e.g. a change that must
land in the pinned `containers` submodule, then a pin-bump here), the choice of
*which repo* to file the tracking issue in is the user's call. Ask up front
rather than defaulting to the current repo.

**Why:** On issue #97, I filed the scoped-sudoers follow-up as librarian#157
without asking; the user actually wanted it filed upstream in
joshjhall/containers (filed as containers#675, cross-linked to #157). The
cross-repo split (containers = code change, librarian = pin bump) is a real
decision, not a mechanical default.

**How to apply:** When a follow-up is cross-repo, use AskUserQuestion to offer
"file upstream / keep here / both cross-linked" BEFORE filing. Also: don't
narrate an AskUserQuestion 60s timeout as "user is away" — the user may be
present; just say the prompt timed out, or avoid front-loading a decision that
is clearly theirs. Related: [[verify-squash-merge-landed]].
