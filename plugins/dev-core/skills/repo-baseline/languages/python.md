# Repo Baseline — Python Slice

Language slice for Python. Conforms to `../slice-contract.md`; adds to
`../core.md`, never relaxes it. It is written for the common ops-repo shape — a
set of standalone `bin/*.py` scripts with hyphenated names — and notes the
package variant under `## Test framework & runner`.

The ruff values are librarian's current configuration; the test layout was
validated on two script repos (ruff + pytest-via-uv, green in hooks and CI).

## Tools & versions

| Tool   | Purpose                  | Pinned version | Single source / accessor                               | Class    |
| ------ | ------------------------ | -------------- | ------------------------------------------------------ | -------- |
| ruff   | lint + format (auto-fix) | 0.16.10        | `ruff.toml` `required-version` / `bin/ruff-version.sh` | optional |
| uv     | runs pytest with no venv | 0.12.23        | `uv.toml` `required-version`                           | optional |
| pytest | test framework           | 9.1.1          | `tests/requirements.txt`                               | optional |
| python | runtime                  | 3.11 (floor)   | `.python-version`                                      | required |

ruff and uv both **refuse to run** when the binary disagrees with their
`required-version` — uv even under `--no-project` — so neither pin can drift
silently (`core.md` § 4). pytest is installed by uv from `tests/requirements.txt`
on every run, so the pin is what runs; no local install exists to disagree.

The python floor is the **oldest runtime the scripts run on**, not the newest
available. `.python-version` holds it (uv honors it under `--no-project`, so the
tests run on the floor, not on whatever is newest), and `ruff.toml`'s
`target-version` must name the same version.

## Config files

`ruff.toml` — required.

```toml
# Must stay TOP-LEVEL — under [format] ruff rejects it as an unknown field.
required-version = "==0.16.10"

# per-repo: the oldest Python the scripts run on; must match .python-version.
target-version = "py311"
line-length = 88

[lint]
# per-repo: add "UP" (pyupgrade) when target-version is the current Python —
# on an older floor it suggests syntax the floor cannot run.
select = ["F", "E", "W", "I", "B"]

[format]
quote-style = "double"
```

The settings lines of this block equal librarian's own `ruff.toml`;
`tests/validate-repo-baseline-slices.sh` fails if they drift apart, so a pin
bump that forgets this slice fails the suite.

`bin/ruff-version.sh` — required: prints the bare pin from `ruff.toml` and
fails loud when it is missing, so every installer reads one source. Copy
librarian's `bin/ruff-version.sh` verbatim.

`uv.toml` — required.

```toml
required-version = "==0.12.23"
```

`.python-version` — required.

```text
3.11
```

`tests/requirements.txt` — required.

```text
pytest==9.1.1
```

`tests/conftest.py` — required in a script repo. Scripts keep their hyphenated,
executable names, which `import` cannot spell, so tests load them by path:

```python
"""Shared fixtures: load a `bin/<name>.py` script as a module by path."""

import importlib.util
import sys
from pathlib import Path

import pytest

BIN_DIR = Path(__file__).resolve().parent.parent / "bin"


def _load(name):
    path = BIN_DIR / f"{name}.py"
    if not path.is_file():
        raise FileNotFoundError(f"no script at {path}")
    module_name = name.replace("-", "_")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclasses and pickling can resolve the module.
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def load_script():
    """Return a loader: `load_script("rotate-logs")` -> the module object."""
    return _load
```

A test then reads `load_script("rotate-logs").main([...])`. Loading executes
the module body, so a script keeps its side effects under
`if __name__ == "__main__":`.

`tests/run.sh` — required: the single entry point (`core.md` § 6).

```bash
#!/usr/bin/env bash
# Single test entry point: the pre-push hook and CI both call this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v uv >/dev/null 2>&1; then
    echo "SKIP: uv not found — install it (https://docs.astral.sh/uv/) to run the tests" >&2
    exit 77
fi

uv run --no-project --with-requirements tests/requirements.txt \
    python -m pytest tests/ "$@"
```

`--no-project` keeps uv from creating or reading a project venv: there is no
`pyproject.toml` to resolve, and the same command runs in the hook, in CI, and
by hand.

## Hook entries

`lefthook.yml` — pre-commit:

```yaml
pre-commit:
  commands:
    ruff-format:
      glob: "*.py"
      skip:
        - run: "! command -v ruff >/dev/null 2>&1"
      run: ruff format {staged_files}
      stage_fixed: true

    ruff-check:
      glob: "*.py"
      skip:
        - run: "! command -v ruff >/dev/null 2>&1"
      run: ruff check {staged_files}
```

`lefthook.yml` — pre-push:

```yaml
pre-push:
  commands:
    ruff:
      glob: "*.py"
      skip:
        - run: "! command -v ruff >/dev/null 2>&1"
      run: ruff check . && ruff format --check .

    tests:
      glob:
        - "bin/**"
        - "tests/**"
        - "uv.toml"
        - ".python-version"
      skip:
        - run: "! command -v uv >/dev/null 2>&1"
      run: bash tests/run.sh
```

The `tests` glob names whole directories plus the runner's own pin files, so a
push that touches only `tests/requirements.txt` or `uv.toml` still runs the
suite. Never narrow it to `"{bin,tests}/**/*.py"`: lefthook's default matcher
(measured on 2.2.1) does **not** match a flat `bin/rotate-logs.py` or
`tests/test_rotate.py` against `dir/**/*.py`, so the suite would silently skip on
exactly this layout's commonest pushes — and a skipped hook reads as a pass.

A bare `ruff` here is safe because of `required-version`: a wrong local ruff
exits 2 rather than formatting differently. Pre-push re-runs ruff over the whole
tree (pre-commit saw only the staged slice) and calls the same `tests/run.sh` CI
calls (`core.md` § 1). The `tests` entry is skip-guarded on `uv` because
lefthook reads any non-zero exit — the `77` sentinel included — as a failure,
and a hook must never block a machine without an optional tool; run directly,
`tests/run.sh` reports the missing `uv` as `77`.

## CI job

GitHub Actions — `lint` and `test` stages:

```yaml
python-lint:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@<40-char-sha> # vX.Y.Z
    - name: Install ruff
      run: |
        ruff_version="$(bash bin/ruff-version.sh)" || exit 1
        pipx install "ruff==$ruff_version"
    - run: ruff check .
    - run: ruff format --check .

python-test:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@<40-char-sha> # vX.Y.Z
    - uses: astral-sh/setup-uv@<40-char-sha> # vX.Y.Z
    - run: command -v uv # fail, never skip, when the install did not land
    - run: bash tests/run.sh
```

The pin is read into a variable before `pipx install`, not inlined as
`"ruff==$(...)"`: a failing substitution inline yields `ruff==` and surfaces as
a confusing pipx error instead of the accessor's own message.

GitLab CI — `lint` and `test` stages:

```yaml
python-lint:
  stage: lint
  image: ghcr.io/astral-sh/ruff:0.16.10-alpine # pinned tag, never :latest
  script:
    - ruff check .
    - ruff format --check .

python-test:
  stage: test
  image: ghcr.io/astral-sh/uv:0.12.23-trixie-slim # Debian: has bash
  script:
    - bash tests/run.sh
```

Pick each image variant by what its `script:` needs, because the bare tags have
no shell: `ghcr.io/astral-sh/ruff:<v>` is the `/ruff` binary alone with
`ENTRYPOINT ["/ruff"]`, and `ghcr.io/astral-sh/uv:<v>` is likewise distroless,
so GitLab cannot run a `script:` in either.

- **Lint** uses the ruff `-alpine` variant: it has `/bin/sh`, ruff on PATH, and
  an empty entrypoint, and the job needs nothing beyond `ruff`.
- **Test** uses a **Debian-based** uv image (`-trixie-slim`, or the
  `-debian-slim` alias; `-bookworm-slim` is not published at this uv version),
  because uv's `-alpine` variant has no bash and `bash tests/run.sh` exits 127.

Image tags are a second copy of the ruff and uv pins — bump them with
`ruff.toml` and `uv.toml`.

## Test framework & runner

[pytest](https://docs.pytest.org/), run as
`uv run --no-project --with-requirements tests/requirements.txt python -m pytest`
**from** the single entry point `tests/run.sh` (`core.md` § 6) — never as a
second CI job or hook beside it. No venv and no system install: uv fetches the
pinned pytest into its cache. On a contributor host without `uv` the entry point
exits `77` (skipped, never passed); in CI the job installs uv first, so a
missing `uv` is a failure. Tests are `tests/test_*.py`, Arrange-Act-Assert
(`testing-patterns`), and reach a script through the `load_script` fixture.

**Package variant.** When the repo is an installable package rather than
scripts, it has `pyproject.toml` (with `requires-python` as the floor and
pytest in a `dev` dependency group) and a committed `uv.lock`; `tests/run.sh`
runs `uv run pytest` instead, and the conftest loader is unnecessary because
the package imports normally. `uv.lock` then replaces `tests/requirements.txt`
as pytest's pin source.

**Legacy exception — librarian itself.** The reference repo has no pytest: its
Python is the `patterns.py` pre-scan ports, tested through the bash harness and
the bash↔python parity suite, with coverage.py measuring the corpus. That
predates this slice; a new repo does not copy it.

## Size-budget override

none — Python uses the default budget in `check-decomposition/thresholds.yml`
(there is no `py` key under `per_language`).

## Open decisions

- **Pinning `astral-sh/setup-uv`'s uv version.** The GitHub job above installs
  whatever uv `setup-uv` resolves, and relies on `uv.toml`'s `required-version`
  to fail on a mismatch. Passing the pin explicitly (`with: version:`) read from
  `uv.toml` would make the install match rather than merely fail; owner: the
  repo-baseline epic.
