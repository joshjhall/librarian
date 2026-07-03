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
lint:
    dprint check '**/*.{json,yml,yaml}'
    taplo fmt --check
    rumdl check .
    ruff check plugins
    ruff format --check plugins
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
