#!/usr/bin/env bash
# NEGATIVE FIXTURE for validate-scanner-category-parity.sh.
#
# This is NOT a real pre-scan tool — it is a deliberately one-sided pair used to
# prove the category-parity detector fires. This bash impl emits a shared slug
# plus one slug the sibling python impl does not; the python impl emits the
# shared slug plus a different one-sided slug. The gate's self-test points the
# detector at this dir and asserts it reports both divergences. Kept minimal and
# lint-clean (ruff + shell) so the lint gates that scan tests/ stay green.
#
# NOTE: comments here must not quote the sibling's one-sided slug literal, or the
# category-slug extractor (which scans the whole file) would see both slugs in
# both impls and the sets would falsely match.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

while IFS= read -r file; do
    [ -f "$file" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "1" "shared-category" "evidence" "HIGH"
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "2" "cat-sh-only" "evidence" "HIGH"
done <"$FILE_LIST"
