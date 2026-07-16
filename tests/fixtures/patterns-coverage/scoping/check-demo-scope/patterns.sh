#!/usr/bin/env bash
# Fixture pre-scan (sed-scoping arm). Emits the single real category so the
# domain is 1/1 covered — proving the out-of-section `zzz-should-not-count`
# token in the sibling contract.md is excluded by the `## Categories` scoping,
# not merely absent from the emitted set. Not a real scanner.
set -euo pipefail

file="${1:-}"
line="1"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "real-finding" "demo" "HIGH"
