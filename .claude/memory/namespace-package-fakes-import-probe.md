---
name: namespace-package-fakes-import-probe
description: "A skip gate using `python3 -c 'import X'` passes against an empty ./X/ build-output dir (PEP 420) — probe an attribute instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5d4f27be-4b8b-4fa0-b825-01bf01cb2b15
  modified: 2026-07-30T15:28:20.379Z
---

`python3 -c 'import coverage'` is **not** evidence coverage.py is installed. PEP
420 makes any directory on `sys.path` an implicit **namespace package**, so when
a script runs from the repo root and `./coverage/` exists as a *build-output*
directory (`tests/coverage-mjs.sh` writes `lcov.info` there), the import binds
that empty dir and **succeeds with the library entirely absent**.

Found in `tests/coverage-python.sh` (#564): the skip gate was bypassed, the
script ran on to `coverage xml`, and the run hard-failed with a misleading
"coverage xml failed" instead of skipping cleanly. Fixed by probing a real
attribute — `import coverage; coverage.Coverage` — which a namespace package
cannot satisfy.

**Why:** the hazard is that the *output* directory of one tool is named after
the *module* another tool imports. That collision is invisible until a host
lacks the library, so it survives every run on a machine that has it.

**How to apply:** when gating on a Python dependency, always touch an attribute,
never bare importability — and be suspicious whenever a build-output dir shares
a name with an importable module. Testing this needs care too: a real installed
package always outranks a namespace package regardless of path order, so a
`PYTHONPATH`-prepend fixture silently resolves the real library on a host that
has it. Replace the path outright (`sys.path[:] = ['<fixture>']`) so the case is
deterministic in both host states — verify it both ways.

Related: [[typos-gate-blocks-push]], [[jq-validate-empty-vs-e]] — same family of
"the check passes for the wrong reason".
