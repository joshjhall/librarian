---
name: typos-gate-blocks-push
description: "The `typos` pre-push hook fails the whole push on any misspelling in touched files, including pre-existing ones"
metadata:
  node_type: memory
  type: project
  originSessionId: ea04e8d4-f73c-4419-8d37-66d95037843f
---

`lefthook` runs a `typos` check on **pre-push** (config in `_typos.toml`). It
scans files in the push and fails the entire push on any misspelling — including
a **pre-existing** typo on a line adjacent to your edits, not just words you
added. Example hit: a singular/plural coreutils-name typo in a
`tests/validate-release.sh` comment I never touched, but in a file I was
committing. (This note itself can't quote the raw misspelled token — the gate
would flag it here too, which is exactly the point.)

**Why:** the gate is corpus-wide over changed files, so editing anywhere in a
file can surface a latent typo elsewhere in it.

**How to apply:** if a push dies at `typos ❯ ... error: \`X\` should be \`Y\``,
just fix the flagged word and fold it into the nearest same-file commit
(soft-reset later commits if needed to keep scopes clean), then re-push. It is
not a false positive to argue with. Commit-time hooks (conform, rumdl, gitleaks)
run per-commit; `typos` + the full `quality-gates` suite run at **push** time —
so a clean set of commits can still be rejected at push. Related:
[[conform-scope-enum]].
