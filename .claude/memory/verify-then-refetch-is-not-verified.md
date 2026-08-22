---
name: verify-then-refetch-is-not-verified
description: "Verifying a package then re-resolving it by name installs unverified bytes; install the verified artifact by path"
metadata:
  type: feedback
---

A supply-chain check that verifies an artifact and then **re-fetches it by name**
verifies nothing that runs. `npm audit signatures` (or any equivalent) describes
the bytes the *first* fetch received; a second `npm install -g "$pkg@$ver"` is an
independent resolution whose bytes were never audited — and the global install is
where `postinstall` executes. Immutable registries and warm caches usually make
the two identical, which is exactly why the gap survives review: it is invisible
until it isn't.

Install the **verified artifact by path** (`npm install -g "$dir/node_modules/$pkg"`),
so the audited bytes and the installed bytes are the same bytes by construction.
Two riders, both learned the hard way:

- The pre-verification install needs `--ignore-scripts`. The order is
  verify-THEN-install so a tampered `postinstall` never runs; letting scripts run
  during the scratch install executes attacker code first and audits afterward.
- `npm install -g <local-dir>` **packs** the directory, and a pack excludes
  `node_modules`. So the by-construction guarantee covers the package's own
  contents; a package **with dependencies** gets that closure re-resolved from the
  registry — the same hole one level down. Check the dependency graph before
  claiming the gap is closed, and prove it with `--offline`: if the install
  succeeds offline, nothing was fetched.

**Why:** the review that caught this on #740 flagged it three times independently
(security, correctness, devops) while the code carried a comment asserting the
hole was already closed — the [[comment-asserts-intent-not-code]] shape, where the
prose is what stops the next reader from looking.

**How to apply:** whenever a workflow verifies then installs, ask *"is the thing
being installed the thing that was verified, or merely the same name?"* Guard it
with a test asserting the install reads the verified path — written as a positive
match on that path, since an absence-of-`$pin` check also passes if the install
line is deleted outright. See also [[blocking-empty-is-not-nothing-to-fix]]: the
finding that started this arrived as *deferrable*, not blocking.
