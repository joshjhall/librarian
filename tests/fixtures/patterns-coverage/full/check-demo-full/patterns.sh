#!/usr/bin/env bash
# Fixture pre-scan for the patterns-coverage gate (full-coverage arm).
# Emits both categories the sibling contract.md declares -> 2/2 (100%).
# Not a real scanner; the coverage tool only reads the quoted slug literals.
set -euo pipefail

file="${1:-}"
line="1"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "alpha-finding" "demo" "HIGH"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "beta-finding" "demo" "HIGH"
