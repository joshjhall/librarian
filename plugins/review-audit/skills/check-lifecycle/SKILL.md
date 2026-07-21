---
description: Deterministic resource-lifecycle pre-scan for unreaped subprocesses, terminate-without-kill timeouts, unclosed handles, and unpaired listeners. Runs patterns.sh before LLM analysis. Used by the checker agent.
---

# check-lifecycle

Resource-lifetime defect detection. Answers the question the other scanners
structurally can't: **did every acquired resource get released on every path,
including error/timeout paths?** The `patterns.sh` pre-scan surfaces the
single-line-tractable *candidates* (spawn sites, terminate sites, handle
acquisitions, listener registrations) before LLM analysis; the judgment-heavy
cases (`unjoined-worker`, `unbounded-growth`) are pass-2 LLM heuristics.

**Companion files**: See `contract.md` for the output format. See
`thresholds.yml` for configurable severity levels.

## Pre-Scan Categories

`patterns.sh` detects these lifecycle patterns. Unlike a hardcoded secret, a
spawn-without-reap is only **suspicious** on a single line — the paired
release may live elsewhere in the function — so the pre-scan emits these at
certainty `MEDIUM` (method `deterministic`) as *candidates* for the LLM pass to
confirm or dismiss, not as auto-fixable definite defects.

| Category                 | What it detects                                                                                          |
| ------------------------ | -------------------------------------------------------------------------------------------------------- |
| `unreaped-subprocess`    | Subprocess spawn site with no obvious reap — Swift `Process()`, Python `Popen(` / `subprocess.Popen(`, Node `spawn/spawnSync/exec/execFile/execFileSync/execSync(`, Go `exec.Command(` |
| `terminate-without-kill` | A `.terminate()` (Swift/Python/JS) / `os.Interrupt` (Go) send site — flagged so the LLM can confirm there is no SIGKILL escalation and no final wait |
| `unclosed-handle`        | A file/socket/pipe acquired in **assignment** form (Python `x = open(`, Swift `= FileHandle(`, Go `os.Open(` / `os.Create(`, Node `= fs.openSync/createReadStream/createWriteStream(`). The assignment anchor structurally excludes only the *same-line* scoped form (Python `with open() as f:` has no `= open(`). A **following-line** `defer f.Close()` / `try-finally` close is NOT visible to a single-line regex, so a defer-closed Go/JS handle IS still flagged as a MEDIUM candidate — the LLM pass-2 confirms the paired close and dismisses it. |
| `unpaired-listener`      | A registration site — JS `addEventListener` / `setInterval` / `.on(`, Swift `addObserver` / `scheduledTimer` — flagged so the LLM can confirm a matching remove/off/invalidate/clear exists |

## Pass 2 — LLM Analysis

The pre-scan hands each candidate to the LLM to confirm against the whole
function/scope (does a `defer`/`finally`/`with`/teardown actually release it? is
the reap on the error path too?). Beyond confirming the pre-scan candidates,
analyze for the two categories no single-line regex can catch:

- **`unjoined-worker`**: a thread / goroutine / `DispatchQueue` / `Task` /
  `Thread(` started in a scope with **no join, cancellation, or lifetime owner** —
  the work outlives its logical parent with nothing awaiting or stopping it.
  Requires understanding scope ownership, so it is LLM-only.
- **`unbounded-growth`**: a collection (dict / array / set / map) that is only
  ever **inserted into — never removed from or size-bounded** — inside a
  long-lived loop or resident process. A cache with no eviction, a registry that
  only grows. Requires tracing every mutation of the collection, so it is
  LLM-only.

For the pre-scan candidates, also apply lifetime judgment the regex cannot:

- `unreaped-subprocess`: a subprocess **detached onto a persistent side-channel**
  (a socket, a named session) is not a child of the spawning process, so
  language-level reaping never touches it — only an explicit teardown does. A
  `defer`/`finally`-only cleanup still orphans it if the process crashes before
  the defer runs. Confirm the teardown covers the **error/crash** path, not just
  the happy path.
- `terminate-without-kill`: confirm the timeout/cancel branch escalates to
  SIGKILL (or equivalent) and issues a final `waitUntilExit()`/`.wait()` — a bare
  `.terminate()` that returns lets a wedged child survive as a zombie/orphan.

## Exclusions

The pre-scan automatically skips:

- Non-source files (markdown, JSON, YAML, TOML, config, lock files)
- Test files (lifecycle shortcuts in test scaffolding are expected)

Encode as **negative fixtures** the false positives a generic scanner must not
flag: a background pipe-reader that *does* drain and signal correctly (no fd
leak), a scoped `with open() as f:` / `use`/`defer`-closed handle, and a
collection that *is* cleared or evicted (bounded, not `unbounded-growth`).
