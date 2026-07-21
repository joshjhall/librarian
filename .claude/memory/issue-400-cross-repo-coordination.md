---
name: issue-400-cross-repo-coordination
description: "#400 agnix-pin SHIPPED as librarian-side coordination only (PR #463); cross-repo work → companion issue + re-scope AC so Closes trailer matches what the diff delivers"
metadata: 
  node_type: memory
  type: project
  originSessionId: ac81c95b-349b-455a-9682-d0eb902975db
  modified: 2026-07-21T04:43:30.140Z
---

SHIPPED PR #463 (2026-07-20, L3): #400 "pin agnix off @latest" — ADR-0001 spine
item 6, **cross-repo**. The actual `npm install -g agnix@latest` → `agnix@0.40.0`
lives in `containers/lib/features/lib/dev-tools/install-binary-tools.sh`, in the
pinned (`update = none`) containers submodule — a separate repo librarian must
NEVER edit (see [[librarian-runs-outside-containers]]). Per that operator
directive the submodule fix is owned by `severity/high` companion issue
**joshjhall/containers#769** (operator lands next release); #400 is the
**librarian-side coordination tracker**.

librarian-side deliverable was tiny: cross-link ADR-0001 §5 + Follow-ups spine
item + `.agnix.toml` header to containers#769. librarian's own consumers
(`.agnix.toml`, CI `code-scanning.yml`) were ALREADY at `0.40.0` (landed #398/#460)
— no re-sync. Left the ADR line-90 `agnix@latest` QUOTE intact — it's an accurate
snapshot of the current containers script until #769 ships; editing it early makes
the quote wrong.

**Adversarial pre-PR review earned its keep (HIGH blocking, cycle 1):**
scope-drift caught that my `Closes #400` trailer would auto-close the issue while

# 400's WRITTEN Acceptance ("Container install pins…", "dependabot config…") is

containers-side work NOT delivered by the librarian diff — the
[[closes-trailer-in-squash-commit]] premature-closure class. Fix was NOT to the
diff (code was clean on all other dims) but to the **issue tracker**: re-scoped

## 400's AC into "Librarian-side (what closing #400 records)" vs "Containers-side

(owned by #769, NOT closed by #400)". Then `Closes #400` legitimately closes
exactly what the diff delivers. Cycle 2 clean.

LESSON for cross-repo spine items: when the real fix is in the pinned submodule,
(1) file/point at the containers companion issue, (2) scope the librarian golem to
coordination (cross-links + already-synced config), (3) **re-scope the librarian
issue's AC so the Closes trailer matches the coordination delivered** — don't let
a Closes trailer auto-close an issue whose AC still describes the other repo's
unshipped work.
