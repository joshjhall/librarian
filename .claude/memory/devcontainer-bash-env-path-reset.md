---
name: devcontainer-bash-env-path-reset
description: "This devcontainer's /etc/bash_env resets $PATH on every non-interactive bash, undoing PATH stubs in tests"
metadata:
  node_type: memory
  type: reference
  originSessionId: 5ab6fd65-c6c6-433d-a590-2ec30160b58e
  modified: 2026-08-28T18:21:13.224Z
---

In this devcontainer, `BASH_ENV=/etc/bash_env` and that file resets `$PATH` on
every non-interactive `bash` invocation. A test that manipulates PATH for a
child process — e.g. stubbing a tool off PATH (`jq`, `tmux`) by pointing at a
hermetic stub-bin — will have its PATH silently restored before the child runs,
so the stub never takes effect and the test passes for the wrong reason.

**How to apply:** when a shell test needs a controlled PATH for a child `bash`,
`unset BASH_ENV` for that child (or invoke with `env -i` / explicit PATH). Seen
in `tests/golem-gate-watch.sh` `test_jq_absent_is_silent_noop` (PR #66). Related
to shell test patterns in [[skill-required-tools-vocabulary]].

**The failure is silent — measure the restriction, never assume it.** A
tool-absent test whose PATH was restored runs the tool-PRESENT path and then
asserts the absent-path outcome, so it fails for a reason unrelated to what it
claims to test, or passes by luck. One line settles it before you trust the
test: `PATH="$stub" bash -c 'command -v <tool>'` must print nothing. Hit again
writing an awk-absent probe (#830): plain `PATH=… bash script` reported `YES at
/usr/bin/awk`; `env -i PATH=… bash --noprofile --norc` was required. Same family
as [[self-skipping-test-hides-the-risky-branch]] — the arm you meant to exercise
is the one that never ran.
