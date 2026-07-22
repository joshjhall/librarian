#!/usr/bin/env bash
# Fixture pre-scan for the patterns-coverage gate (gapped-coverage arm).
# Emits only 1 of the 3 categories the sibling contract.md declares -> 1/3 (33%).
# The missing gamma-finding / delta-finding are the heuristic categories.
set -euo pipefail

file="${1:-}"
line="1"
command printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "alpha-finding" "demo" "HIGH"
