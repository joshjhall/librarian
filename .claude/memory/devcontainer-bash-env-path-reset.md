---
name: devcontainer-bash-env-path-reset
description: "This devcontainer's /etc/bash_env resets $PATH on every non-interactive bash, undoing PATH stubs in tests"
metadata:
  node_type: memory
  type: reference
  originSessionId: 5ab6fd65-c6c6-433d-a590-2ec30160b58e
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
