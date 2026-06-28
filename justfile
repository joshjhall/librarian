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
