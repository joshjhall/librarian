#!/usr/bin/env bash
# check-docs-staleness — Deterministic Pre-Scan
#
# Detects potential staleness indicators in documentation files using
# regex patterns. Results are passed to the LLM for confirmation/dismissal.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# Current date components for staleness comparison
CURRENT_YEAR=$(/usr/bin/date +%Y)
CURRENT_MONTH=$(/usr/bin/date +%m)

# Staleness threshold in months (default 12, overridable via env)
STALENESS_MONTHS="${CHECK_STALENESS_MONTHS:-12}"

# Calculate threshold date (year and month)
THRESHOLD_MONTHS=$((CURRENT_YEAR * 12 + CURRENT_MONTH - STALENESS_MONTHS))
THRESHOLD_YEAR=$((THRESHOLD_MONTHS / 12))
THRESHOLD_MONTH=$((THRESHOLD_MONTHS % 12))
if [ "$THRESHOLD_MONTH" -eq 0 ]; then
    THRESHOLD_MONTH=12
    THRESHOLD_YEAR=$((THRESHOLD_YEAR - 1))
fi

# is_date_stale YYYY MM — returns 0 if the date is older than threshold
is_date_stale() {
    local year="${1}" month="${2}"
    local date_months=$((year * 12 + month))
    [ "$date_months" -lt "$THRESHOLD_MONTHS" ]
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # --- Category: expired-date ---
    # Match YYYY-MM-DD and YYYY/MM/DD patterns
    /usr/bin/grep -nE '\b(20[0-9]{2})[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12][0-9]|3[01])\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            # Extract year and month from the match
            year=$(/usr/bin/echo "$content" | /usr/bin/grep -oE '20[0-9]{2}' | /usr/bin/head -1)
            month=$(/usr/bin/echo "$content" | /usr/bin/grep -oE '20[0-9]{2}[-/](0[1-9]|1[0-2])' | /usr/bin/head -1 | /usr/bin/grep -oE '(0[1-9]|1[0-2])$')

            if [ -n "$year" ] && [ -n "$month" ]; then
                # Strip leading zero for arithmetic
                month_num=$(/usr/bin/echo "$month" | /usr/bin/sed 's/^0//')
                if is_date_stale "$year" "$month_num"; then
                    evidence=$(/usr/bin/printf '%.80s' "$content")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "expired-date" \
                        "Date reference older than ${STALENESS_MONTHS} months: ${evidence}" "HIGH"
                fi
            fi
        done || true

    # --- Category: outdated-reference ---
    # Version references (vN.N.N or N.N.N patterns in doc context)
    /usr/bin/grep -nE '\bv?[0-9]+\.[0-9]+\.[0-9]+\b' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            # Skip lines that are clearly changelog entries or release notes
            case "$content" in
                *"### ["*) continue ;;
                *"## ["*) continue ;;
                *"- v"*) continue ;;
            esac
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "outdated-reference" \
                "Version reference to verify: ${evidence}" "HIGH"
        done || true

    # --- Category: stale-comment ---
    # Staleness markers: TODO/FIXME/HACK combined with staleness keywords
    /usr/bin/grep -niE '(TODO|FIXME|XXX|HACK|WORKAROUND).*(updat|outdat|stale|obsolete|deprecat|remov|old |was )' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "stale-comment" \
                "Staleness marker: ${evidence}" "HIGH"
        done || true

    # --- Category: outdated-reference ---
    # Broken-looking URLs (common patterns for dead links in docs)
    /usr/bin/grep -nE 'https?://[^ )>"]+' "$file" 2>/dev/null |
        /usr/bin/grep -iE '(deprecated|removed|old|legacy|archive|sunset)' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "outdated-reference" \
                "URL with deprecation indicators: ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
