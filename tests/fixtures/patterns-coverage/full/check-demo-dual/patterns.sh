#!/usr/bin/env bash
# Fixture pre-scan (dual-impl union arm, bash half). Emits ONLY sh-finding; the
# sibling patterns.py emits py-finding. The coverage tool must union the two to
# score this domain 2/2. Not a real scanner; only the quoted slug literals are
# read.
set -euo pipefail

file="${1:-}"
line="1"
/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "sh-finding" "demo" "HIGH"
