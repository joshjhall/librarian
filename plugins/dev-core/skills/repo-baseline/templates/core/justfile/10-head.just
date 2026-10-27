# Rendered from librarian's repo-baseline templates.
# CI and the hooks call these same recipes (core § 3).

default:
    @just --list

# Install the git hooks
install-hooks:
    lefthook install

# Run every linter over the whole tree, no skips
lint:
    typos
    dprint check
    taplo fmt --check
    rumdl check .
