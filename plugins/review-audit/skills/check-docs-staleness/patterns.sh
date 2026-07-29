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
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | command grep -qixF "$_cand"; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

# Current date components for staleness comparison
CURRENT_YEAR=$(command date +%Y)
CURRENT_MONTH=$(command date +%m)

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
    command grep -nE '\b(20[0-9]{2})[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12][0-9]|3[01])\b' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            # Extract year and month from the match
            year=$(command echo "$content" | command grep -oE '20[0-9]{2}' | command head -1)
            month=$(command echo "$content" | command grep -oE '20[0-9]{2}[-/](0[1-9]|1[0-2])' | command head -1 | command grep -oE '(0[1-9]|1[0-2])$')

            if [ -n "$year" ] && [ -n "$month" ]; then
                # Strip leading zero for arithmetic
                month_num=$(command echo "$month" | command sed 's/^0//')
                if is_date_stale "$year" "$month_num"; then
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "expired-date" \
                        "Date reference older than ${STALENESS_MONTHS} months: ${evidence}" "HIGH"
                fi
            fi
        done || true

    # --- Category: outdated-reference ---
    # Version references (vN.N.N or N.N.N patterns in doc context)
    command grep -nE '\bv?[0-9]+\.[0-9]+\.[0-9]+\b' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            # Skip lines that are clearly changelog entries or release notes
            case "$content" in
                *"### ["*) continue ;;
                *"## ["*) continue ;;
                *"- v"*) continue ;;
            esac
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "outdated-reference" \
                "Version reference to verify: ${evidence}" "HIGH"
        done || true

    # --- Category: stale-comment ---
    # Staleness markers: TODO/FIXME/HACK combined with staleness keywords
    command grep -niE '(TODO|FIXME|XXX|HACK|WORKAROUND).*(updat|outdat|stale|obsolete|deprecat|remov|old |was )' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "stale-comment" \
                "Staleness marker: ${evidence}" "HIGH"
        done || true

    # --- Category: outdated-reference ---
    # Broken-looking URLs (common patterns for dead links in docs)
    command grep -nE 'https?://[^ )>"]+' "$file" 2>/dev/null |
        command grep -iE '(deprecated|removed|old|legacy|archive|sunset)' |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "outdated-reference" \
                "URL with deprecation indicators: ${evidence}" "HIGH"
        done || true

done <"$FILE_LIST"
