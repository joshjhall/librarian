#!/usr/bin/env bash
# Fixture pre-scan (malformed-sibling arm): emits the one category its contract
# declares. Present to prove a good domain is still reported when a sibling
# domain's contract has an empty Categories table.
set -euo pipefail

file="${1:-}"
line="1"
command printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "alpha-finding" "demo" "HIGH"
