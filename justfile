# Task runner for the librarian plugin marketplace.
# Install `just` via the containers dev-tools feature, then run `just` to list
# recipes or `just <recipe>` to run one.

# Default target: show the list of recipes
default:
    @just --list --unsorted

# Validate marketplace + plugin manifests
validate:
    node tests/validate-manifests.mjs

# Regenerate the enrolled workflow.js harnesses from their workflow.src/
# fragments (#806). Run this after editing ANY fragment: the artifact is what
# the Workflow engine executes and what `claude plugin install` copies, so an
# unregenerated edit runs stale bytes. `just test` fails the tree until you do
# (tests/lint-workflow-js-generated.sh).
gen-workflow-js:
    node bin/generate-workflow-js.mjs

# Copy the shared prelude (plugins/lib/prelude.js) into every consuming harness
# (#586). Run this after editing that source — NEVER edit a generated copy, which
# the next run overwrites. `just test` fails the tree until you do
# (tests/validate-prelude-sync.sh).
#
# ORDER MATTERS when you touch both: run gen-prelude FIRST, then gen-workflow-js.
# The prelude writes a FRAGMENT for the two enrolled harnesses (#811), and the
# artifact must then be rebuilt from the updated fragment.
gen-prelude:
    node bin/generate-prelude.mjs

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
# The uvx branch resolves the PINNED ruff (#542) — `uvx ruff@<v>`, version from
# ruff.toml's required-version via bin/ruff-version.sh — so a uvx-only host lints
# with the same release as CI. The `ruff`-on-PATH branch needs no pin: ruff
# enforces required-version itself and refuses to run on a mismatch. An
# unreadable pin aborts the recipe rather than falling through to a floating
# ruff, which is the drift this closed.
#
# One logical line on purpose: just runs each recipe LINE in its own shell, so a
# RUFF assigned on one line is unset on the next. Recipes here are POSIX sh (this
# justfile sets no `shell` directive) — no [[ ]], no local, no arrays.
lint:
    dprint check '**/*.{json,yml,yaml}'
    taplo fmt --check
    rumdl check .
    @RUFF_PIN="$(bash bin/ruff-version.sh)" || exit 1; \
    . bin/bounded-run.sh; \
    if command -v ruff >/dev/null 2>&1; then RUFF="ruff"; \
    elif command -v uvx >/dev/null 2>&1 && bounded_run "${UVX_PROBE_TIMEOUT:-60}" uvx "ruff@$RUFF_PIN" --version >/dev/null 2>&1; then RUFF="uvx ruff@$RUFF_PIN"; \
    else echo "[skip] Python lint did NOT run — no ruff runner (install ruff, or uv for 'uvx ruff')"; exit 0; fi; \
    $RUFF check plugins && $RUFF format --check plugins
    @if command -v typos >/dev/null 2>&1; then typos .; \
    else echo "[skip] spell check did NOT run — typos is not installed (cargo install typos-cli)"; fi
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
