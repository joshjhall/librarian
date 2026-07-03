---
name: coverage-two-surfaces
description: "patterns.py coverage number comes from coverage-python.sh's own corpus, NOT from the test gates"
metadata:
  node_type: memory
  type: reference
  originSessionId: 38cd8f66-5b91-4af5-b41f-c131957b0c9f
---

Moving the Codecov number for a `patterns.py` port requires extending
**`tests/coverage-python.sh`**'s internal fixture corpus — NOT the behavioral
test gate. They are separate surfaces: `coverage-python.sh` runs each port under
`coverage run` against its OWN `FILE_LIST` (generic app.py/app.ts/…); a new
behavioral gate (e.g. `validate-checker-detectors.sh`) exercises detectors but
its runs are not instrumented, so it does not change `coverage.xml`.

To lift a port's coverage: add fixtures to `coverage-python.sh` (special-case the
port in the run loop if it needs a different corpus / env like threshold
overrides), AND add a behavioral gate that asserts the findings. Coverage is the
byproduct; the assertions are the deliverable. See [[mjs-coverage-c8-excludes-tests]]
for the mjs-side analogue. #204 (check-ai-config 34%→92%) established the pattern.
