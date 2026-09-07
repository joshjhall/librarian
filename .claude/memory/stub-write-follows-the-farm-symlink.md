---
name: stub-write-follows-the-farm-symlink
description: Writing a stub over a symlink-farm entry targets the REAL binary and dies Permission denied; rm -f the link first
metadata:
  type: feedback
---

A tool-absence/misbehavior fixture usually builds a **symlink farm** (link every
tool the script resolves, so it does not die 127 at a forgotten one — see
[[tool-absence-fixture-needs-a-symlink-farm]]) and then overwrites **one** entry
with a stub. That second step is where it breaks: a `>` redirect **follows a
symlink**, so `printf ... >"$stub/stat"` writes through the farm's link into the
real `/usr/bin/stat` and fails `Permission denied`. `command rm -f "$stub/stat"`
first, then write.

**Why:** the failure is loud but the *diagnosis* is misleading — the test errors
on a permissions message about a system path, which reads like a sandbox or
container problem rather than a fixture bug. Worse is the near-miss: anywhere the
write would succeed (a farm of copies, a writable prefix), the stub silently does
not replace what the script resolves, the real tool stays live, and the guard
under test is never exercised — a green test proving nothing. Same family as
[[false-negative-from-env-restoring-path]]: the fixture believes it removed a
tool it did not.

**How to apply:** order is `ln -sf` the farm → `rm -f` the one entry → write the
stub → `chmod +x`. Then confirm the stub is what actually runs before trusting a
pass: assert on a marker only the stub produces, not merely on the absence of the
real tool's effect. Measured on #522, where the farm/stub collision on `stat`
failed the run outright.
