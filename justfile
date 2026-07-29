# Task runner for the librarian plugin marketplace.
# Install `just` via the containers dev-tools feature, then run `just` to list
# recipes or `just <recipe>` to run one.

# Default target: show the list of recipes
default:
    @just --list --unsorted

# Validate marketplace + plugin manifests
validate:
    node tests/validate-manifests.mjs

# Lint everything the pre-commit hooks would (formatting + manifests + python).
# shellcheck runs as part of `just test` (tests/lint-shellcheck.sh).
#
# The ruff step mirrors tests/lint-python.sh's runner resolution (#538): `ruff`
# on PATH -> PROBED `uvx ruff` -> skip. Without it `just lint` hard-failed
# "command not found" on a uvx-only host that `just test` handles gracefully —
# the two documented entry points for the same lint pass disagreed (#544). The
# `uvx ruff --version` probe is load-bearing: uvx can be installed but
# offline/uncached, and an unprobed `uvx ruff check` turns a graceful skip into a
# hard failure.
#
# The probe is BOUNDED with `timeout` like lint-python.sh's. A stalled link (DNS
# resolves, connection hangs) is not the same as a cleanly offline one, and
# unbounded the probe blocks forever. An earlier revision skipped the bound on
# the theory that this is interactive and the operator can Ctrl-C it — but
# nothing stops `just lint` being called from a script or editor task where no
# operator is watching, and "the two entry points agree" is a weaker claim if
# they agree on outcome but not on hang-safety. `timeout` is GNU coreutils and
# absent on base macOS, so it is used only when present (same conditional as
# lint-python.sh's probe_uvx).
#
# One logical line on purpose: just runs each recipe LINE in its own shell, so a
# RUFF assigned on one line is unset on the next. Recipes here are POSIX sh (this
# justfile sets no `shell` directive) — no [[ ]], no local, no arrays.
lint:
    dprint check '**/*.{json,yml,yaml}'
    taplo fmt --check
    rumdl check .
    @if command -v ruff >/dev/null 2>&1; then RUFF="ruff"; \
    elif command -v uvx >/dev/null 2>&1 && { if command -v timeout >/dev/null 2>&1; then timeout "${UVX_PROBE_TIMEOUT:-60}" uvx ruff --version; else uvx ruff --version; fi; } >/dev/null 2>&1; then RUFF="uvx ruff"; \
    else echo "[skip] Python lint did NOT run — no ruff runner (install ruff, or uv for 'uvx ruff')"; exit 0; fi; \
    $RUFF check plugins && $RUFF format --check plugins
    node tests/validate-manifests.mjs

# Format JSON/YAML/TOML/Python (markdown via rumdl is opt-in here, review the diff)
fmt:
    dprint fmt
    taplo fmt
    rumdl fmt .
    ruff format plugins

# Run the full local check suite (no network) — mirrors CI's gate jobs
test:
    bash tests/run-all.sh

# Generate coverage reports for the instrumented runtimes — Python patterns.py
# ports (coverage.xml) + the .mjs validators (coverage/lcov.info). Mirrors CI's
# `coverage` job; additive and non-blocking (NOT part of `just test`). The bash
# patterns.sh fallback is intentionally not measured — see codecov.yml.
coverage:
    bash tests/coverage-python.sh
    bash tests/coverage-mjs.sh

# Install lefthook git hooks
install-hooks:
    lefthook install

# ============================================================================
# Release — repo-level semver tag (what containers' LIBRARIAN_REF pins to).
# Always release through these recipes; never hand-edit VERSION. See CLAUDE.md.
# ============================================================================

# Cut a patch release (0.1.0 -> 0.1.1), non-interactive
release-patch:
    ./bin/release.sh --non-interactive patch

# Cut a minor release (0.1.0 -> 0.2.0), non-interactive
release-minor:
    ./bin/release.sh --non-interactive minor

# Cut a major release (0.1.0 -> 1.0.0), non-interactive
release-major:
    ./bin/release.sh --non-interactive major
