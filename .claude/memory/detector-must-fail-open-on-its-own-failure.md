---
name: detector-must-fail-open-on-its-own-failure
description: A guard that cannot RUN has learned nothing about its subject — report unverified and proceed; only outcomes it can actually read may refuse
metadata:
  type: feedback
---

When a guard's own machinery fails — its scraper stops matching, its temp file
or temp directory cannot be created, its probe times out — it has learned
**nothing about the subject**. Treating that as "the subject is bad" turns every
host into a refusal the moment the environment shifts: an outage, and in the
**opposite direction** from whatever the guard was built to catch.

Report the outcomes separately: the ones the guard can actually read may refuse;
the ones meaning "I could not tell" must warn loudly and proceed.

**Why:** #946's plugin-resolvability guard refuses dispatch when a plugin is
missing. Its count is scraped from CLI text (no structured mode exists), so a
rewording would return nothing — and the first draft read that as "absent" and
would have blocked every golem on every host. Review caught it; two more
instances of the identical shape were then found in the same function.

**How to apply:** after fixing one fail-closed branch, **grep the function for
every other early return that yields the same sentinel** — three turned up in
one function here, each reachable the whole time. Give each cause its own
message: a `mktemp -d` failure reported as "check TMPDIR" for a temp *file*
sends the operator to the one thing already known to work. Related:
[[blocking-empty-is-not-nothing-to-fix]], [[measured-cause-may-invert-the-remedy]].
