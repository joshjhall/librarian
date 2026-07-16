#!/usr/bin/env bash
# Fixture pre-scan (edge-slug parity arm). Emits both the normal `real-finding`
# and the edge `x-finding` (single-character first segment). The strict slug
# shape excludes `x-finding` from BOTH extractors, so the domain scores 1/1 on
# `real-finding` only when contract_categories() shares that shape. Reintroducing
# the looser contract pattern makes `x-finding` declared-but-never-emitted (1/2),
# failing --strict 100. Not a real scanner; only the quoted slug literals matter.
set -euo pipefail

file="${1:-}"
line="1"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "real-finding" "demo" "HIGH"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "x-finding" "demo" "HIGH"
