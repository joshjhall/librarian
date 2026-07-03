#!/usr/bin/env bash
# POSITIVE FIXTURE for validate-scanner-category-parity.sh.
#
# Not a real pre-scan tool. This pair's patterns.sh and patterns.py carry the
# SAME category slug set ("alpha-cat", "beta-cat"), so the detector must report
# no mismatch. The gate's self-test asserts a clean pass on this dir. Kept
# minimal and lint-clean (ruff + shell) so the gates scanning tests/ stay green.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

while IFS= read -r file; do
    [ -f "$file" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "1" "alpha-cat" "evidence" "HIGH"
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "2" "beta-cat" "evidence" "HIGH"
done <"$FILE_LIST"
