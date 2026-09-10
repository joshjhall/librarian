---
name: proxy-path-returns-200-not-json
description: "BIFROST_URL is derivable from ANTHROPIC_BASE_URL by stripping the proxy suffix; the proxy path returns HTTP 200 with HTML, so a status-code probe reads as success"
metadata:
  node_type: memory
  type: reference
---

`token-report.sh` needs **`BIFROST_URL`**, the gateway **admin** root. It is
usually unset, but it is **derivable** from `ANTHROPIC_BASE_URL`, which is set:
strip the proxy suffix.

```console
$ echo $ANTHROPIC_BASE_URL
https://bifrost.<host>/anthropic     # proxy path
$ BIFROST_URL=https://bifrost.<host> # admin root — suffix stripped
```

**Why the mistake is easy and self-concealing.** Both paths answer
`/api/logs/stats` with **HTTP 200**. The proxy path returns the web UI's
**HTML**; only the admin root returns `application/json`. So a probe that checks
the status code — the obvious probe — reads the wrong URL as working:

```console
$ curl -o /dev/null -w '%{http_code} %{content_type}' .../anthropic/api/logs/stats
200 text/html; charset=utf-8
$ curl -o /dev/null -w '%{http_code} %{content_type}' .../api/logs/stats
200 application/json
```

This is the same shape as [[grep-q-under-pipefail-inverts-a-match]] and
[[background-task-exit-code-is-the-wrappers]]: the success signal is real, and
about the wrong thing. Check the **content type or body**, never the status
alone.

**Cost when missed.** #797 recorded its AC6 as DEFERRED — "not measurable in
this environment" — on an unset `BIFROST_URL`. A 2026-09-09 orchestrator
repeated the claim on #972 and told the operator the gateway was unreachable;
the operator corrected it, and the value was one suffix away in the environment
the whole time. `token-report.sh:168-172` documents the trap precisely, so the
information was present and unread.

**How to apply:** before recording a measurement AC as blocked on a missing
gateway, derive `BIFROST_URL` from `ANTHROPIC_BASE_URL` and run the tool. Verify
with a real call (`token-report.sh window …` prints a `reconciled` line), not a
reachability probe. A tool that *refuses* on an unset variable is not evidence
the variable is unavailable — see [[untestable-is-a-claim-about-your-search]].
