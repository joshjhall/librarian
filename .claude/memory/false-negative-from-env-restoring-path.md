---
name: false-negative-from-env-restoring-path
description: Shimming PATH does not hide a tool when BASH_ENV restores it — a fail-loud test passed green and read as a real gate bug
metadata:
  type: feedback
---

To prove a gate fails loudly when its runtime is missing, the obvious test is to
run it under a PATH containing only shims. In this devcontainer that produces a
**false negative**: `BASH_ENV=/etc/bash_env` is sourced by *every* non-interactive
bash and re-adds `/usr/local/bin` to PATH, so `node` is still found. The gate ran
normally, exited 0 with all tests passing, and looked exactly like the
silent-skip bug the check exists to catch.

The tell was the *shape* of the result: a gate that cannot run should report a
skip, not a full green sweep. A passing suite where you expected a skip means the
absence was never created.

Fix: neutralize the restorer too — `env -u BASH_ENV PATH="$SHIM" bash gate.sh`.
Then the sentinel appears (exit 77, `GATE DID NOT RUN`).

**Why:** absence must be *verified*, not assumed from the setup step. A test that
manufactures a condition has two failure modes — the subject is broken, or the
condition was never established — and they are indistinguishable from the exit
code alone. Here the second masqueraded as the first, and nearly sent me editing
a correct gate.

**How to apply:** whenever a test manufactures an absence (missing binary,
unset var, unreadable file), assert the absence *first* and print it
(`command -v node || echo ABSENT`), before asserting what the subject does about
it. In containers, check `BASH_ENV`, `/etc/profile.d/*`, and wrapper shims before
trusting a PATH override. Related: [[self-skipping-test-hides-the-risky-branch]],
[[devcontainer-bash-env-path-reset]], [[exemption-is-a-runtime-claim-measure-it]].
