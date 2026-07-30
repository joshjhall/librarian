---
name: set-e-abort-untestable-in-run-test
description: "A test whose subject is a set -e abort is vacuous inside run_test — the harness calls bodies as `if \"$fn\"`, which suspends set -e; slice the real function and run it at top level"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87b555fb-8e69-4c75-98f3-66c34a760396
  modified: 2026-07-30T09:27:17.818Z
---

`tests/lib/harness.sh`'s `run_test` invokes each test body as `if "$test_func";
then` (harness.sh ~line 71). **`set -e` is suspended inside an `if` condition**,
so any failure mode that manifests as *"the script aborts"* CANNOT be observed
from inside a test body. A test asserting such behavior passes identically
whether the guard under test is present or absent.

Hit on #498 (PR #583): `plugin_for_skill` piped `grep | head | cut` under
`set -euo pipefail`, assigned via a bare `plugin="$(plugin_for_skill "$name")"`.
On a lookup miss `grep` exits 1, `pipefail` promotes it, and `set -e` does **not**
exempt a bare command-substitution assignment — so the real (top-level) scan died
mid-run, silently skipping every remaining per-file test. My first test asserted
the degrade path and **passed with the `|| true` fix reverted**. The bug was real;
the test was decoration.

**How to actually pin it:** SLICE the real function out of the file with
`sed -n '/^fname() {$/,/^}$/p' "$SELF_PATH"`, write it into a temp script with
`set -euo pipefail` and a top-level call, run it with `command bash`, and assert
the exit status. Two things make this non-vacuous:

- **Slice, never restate.** A hand-copied function keeps passing after the real
  definition changes — the same textual-test trap #542 cycle 3 caught. Add a
  `SELF_PATH` next to `SCRIPT_DIR` so the slice tracks edits.
- **Assert the extraction.** `assert_contains "$(cat "$sliced")" "fname() {"` —
  a broken `sed` would otherwise make the probe pass for the wrong reason.

**Verify by mutation every time:** remove the guard and confirm the probe fails
on the exit status. If it still passes, the test is measuring nothing.

Related vacuity traps in this repo: a uniqueness check that reads a `sort -u`'d
variable (collapses the collision it looks for — read the raw index instead);
`grep -o` with an alternation dropping refs that share a boundary char; and
[[collect-all-test-assertions-must-not-throw]], the sibling harness trap where a
bare `.field` on a missing entry aborts the run and masks later assertions.
