#!/usr/bin/env bash
# drift-detect — Deterministic Pre-Scan
#
# Compares planned files (from issue body) against actual changed files
# (from git diff) to detect file-level drift.
#
# Input:
#   $1 = file containing actual changed file paths (one per line)
#   $2 = file containing planned file paths (one per line)
#
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

ACTUAL_FILES="${1:?Usage: patterns.sh <actual-files> <planned-files>}"
PLANNED_FILES="${2:?Usage: patterns.sh <actual-files> <planned-files>}"

if [ ! -f "$ACTUAL_FILES" ]; then
    echo "Error: actual files list not found: $ACTUAL_FILES" >&2
    exit 1
fi

if [ ! -f "$PLANNED_FILES" ]; then
    echo "Error: planned files list not found: $PLANNED_FILES" >&2
    exit 1
fi

# Known side-effect files that are commonly modified as a consequence
# of other changes (not scope drift)
SIDE_EFFECT_PATTERNS=(
    'package-lock.json'
    'yarn.lock'
    'pnpm-lock.yaml'
    'go.sum'
    'Cargo.lock'
    'Gemfile.lock'
    'poetry.lock'
    'composer.lock'
    '.gitignore'
)

# --- Category: planned-not-touched ---
# Files listed in the plan that are not in the actual diff
while IFS= read -r planned; do
    [ -z "$planned" ] && continue
    # Trim whitespace
    planned=$(/usr/bin/printf '%s' "$planned" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$planned" ] && continue

    # Check if planned file (or a file within a planned directory) appears
    # in the actual changes
    found=0
    while IFS= read -r actual; do
        [ -z "$actual" ] && continue
        # Exact match
        if [ "$actual" = "$planned" ]; then
            found=1
            break
        fi
        # Directory match: planned path is a prefix of actual path
        case "$actual" in
            "${planned}/"*)
                found=1
                break
                ;;
        esac
    done <"$ACTUAL_FILES"

    if [ "$found" -eq 0 ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$planned" "0" "planned-not-touched" \
            "Planned file not found in git diff" "HIGH"
    fi
done <"$PLANNED_FILES"

# --- Category: unplanned-modification ---
# Files in the actual diff that are not in the plan
while IFS= read -r actual; do
    [ -z "$actual" ] && continue

    # Check if this file is in the planned list
    found=0
    while IFS= read -r planned; do
        [ -z "$planned" ] && continue
        planned=$(/usr/bin/printf '%s' "$planned" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$planned" ] && continue
        # Exact match
        if [ "$actual" = "$planned" ]; then
            found=1
            break
        fi
        # Directory match: actual is within a planned directory
        case "$actual" in
            "${planned}/"*)
                found=1
                break
                ;;
        esac
    done <"$PLANNED_FILES"

    if [ "$found" -eq 0 ]; then
        # Check if this is a known side-effect file
        is_side_effect=0
        for pattern in "${SIDE_EFFECT_PATTERNS[@]}"; do
            case "$actual" in
                *"$pattern")
                    is_side_effect=1
                    break
                    ;;
            esac
        done

        # Check if this is a test file for a planned source file
        is_test_for_planned=0
        while IFS= read -r planned; do
            [ -z "$planned" ] && continue
            planned=$(/usr/bin/printf '%s' "$planned" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$planned" ] && continue
            # Extract base name without extension for matching
            planned_base=$(/usr/bin/basename "$planned" | /usr/bin/sed 's/\.[^.]*$//')
            case "$actual" in
                *test*"$planned_base"* | *"$planned_base"*test* | *"$planned_base"*spec*)
                    is_test_for_planned=1
                    break
                    ;;
            esac
        done <"$PLANNED_FILES"

        if [ "$is_side_effect" -eq 1 ] || [ "$is_test_for_planned" -eq 1 ]; then
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$actual" "0" "unplanned-modification" \
                "Modified but not in plan (side-effect or test)" "LOW"
        else
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$actual" "0" "unplanned-modification" \
                "Modified but not listed in plan" "MEDIUM"
        fi
    fi
done <"$ACTUAL_FILES"
