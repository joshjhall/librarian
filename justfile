# Task runner for the librarian plugin marketplace.
# Install `just` via the containers dev-tools feature, then run `just` to list
# recipes or `just <recipe>` to run one.

# Default target: show the list of recipes
default:
    @just --list --unsorted

# Validate marketplace + plugin manifests
validate:
    node tests/validate-manifests.mjs

# Lint everything the pre-commit hooks would (formatting + manifests)
lint:
    dprint check '**/*.{json,yml,yaml}'
    taplo fmt --check
    rumdl check .
    node tests/validate-manifests.mjs

# Format JSON/YAML/TOML (markdown via rumdl is opt-in here, review the diff)
fmt:
    dprint fmt
    taplo fmt
    rumdl fmt .

# Run the full local check suite (no network)
test: validate

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
