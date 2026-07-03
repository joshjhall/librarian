#!/usr/bin/env bash
# check-docs-organization — Deterministic Pre-Scan
#
# Checks for missing standard root documents and directories without READMEs.
# The checks are DRIVEN BY the passed file list: an empty list (a PR that
# touched no relevant files) produces empty output and exit 0 — a deterministic
# pre-scan must never emit project-level findings on empty input (issue #64).
# When the list is non-empty the root-document check runs against the project
# root, and the directory-README check runs only for directories that contain a
# listed file (and their ancestors up to the root), not the whole tree.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
# Runtime: Python 3.11+ primary (patterns.py); this bash body is the portable
# fallback. PATTERNS_FORCE_BASH=1 forces bash. See CLAUDE.md § Key conventions.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

# Read the passed file list into an array of non-empty, non-blank paths. The
# whole scan is gated on this: an empty list means there is nothing to evaluate,
# so emit nothing and exit 0 rather than scanning the project root regardless.
FILES=()
while IFS= read -r _line || [ -n "$_line" ]; do
    # Trim surrounding whitespace; skip blank lines.
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [ -n "$_line" ] && FILES+=("$_line")
done <"$FILE_LIST"

if [ "${#FILES[@]}" -eq 0 ]; then
    exit 0
fi

# Determine project root from the file list (use the common prefix)
# For simplicity, use the directory of the first file's git root
PROJECT_ROOT=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null || /usr/bin/echo ".")

# --- Category: missing-root-doc ---
# Check for standard root-level documentation files
for expected_file in README.md LICENSE CHANGELOG.md; do
    found=false
    # Check common variations
    case "$expected_file" in
        LICENSE)
            for variant in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md; do
                [ -f "${PROJECT_ROOT}/${variant}" ] && found=true && break
            done
            ;;
        *)
            [ -f "${PROJECT_ROOT}/${expected_file}" ] && found=true
            ;;
    esac

    if [ "$found" = "false" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "${PROJECT_ROOT}" "1" "missing-root-doc" \
            "Missing standard file: ${expected_file}" "HIGH"
    fi
done

# --- Category: missing-dir-readme ---
# Check directories with significant content but no README. Driven by the passed
# file list: only the directories that actually contain a listed file are
# candidates (capped at the configured depth below the project root), so a PR
# emits a finding only for a directory it touched — never for the whole tree.
MAX_DEPTH="${CHECK_ORG_README_DEPTH:-2}"
MIN_FILES="${CHECK_ORG_MIN_FILES:-5}"

# Collect the unique directories of the listed files (absolute paths), so the
# missing-README check considers only touched directories.
candidate_dirs() {
    local f abs
    for f in "${FILES[@]}"; do
        case "$f" in
            /*) abs="$f" ;;
            *) abs="${PROJECT_ROOT}/${f}" ;;
        esac
        /usr/bin/dirname "$abs"
    done | command sort -u
}

candidate_dirs | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    # Skip project root (covered by the missing-root-doc check above).
    [ "$dir" = "$PROJECT_ROOT" ] && continue
    # Only consider directories that exist and live under the project root.
    [ -d "$dir" ] || continue
    case "$dir" in
        "${PROJECT_ROOT}"/*) : ;;
        *) continue ;;
    esac

    # Respect the configured max depth below the project root.
    rel="${dir#"${PROJECT_ROOT}"/}"
    depth=$(/usr/bin/printf '%s\n' "$rel" | /usr/bin/awk -F/ '{print NF}')
    [ "$depth" -le "$MAX_DEPTH" ] || continue

    # Skip excluded / generated trees. `*/.*` already covers any hidden
    # directory (including .git), so it is not listed separately.
    case "$dir" in
        */.* | */node_modules/* | */vendor/* | */__pycache__/* | */dist/* | */build/*) continue ;;
    esac

    # Skip if README exists
    [ -f "${dir}/README.md" ] && continue
    [ -f "${dir}/README.rst" ] && continue
    [ -f "${dir}/README" ] && continue

    # Count meaningful files (exclude hidden, generated)
    file_count=$(/usr/bin/find "$dir" -maxdepth 1 -type f \
        -not -name '.*' \
        -not -name '*.pyc' \
        -not -name '*.o' \
        2>/dev/null | /usr/bin/wc -l)

    if [ "$file_count" -ge "$MIN_FILES" ]; then
        relative_dir=$(/usr/bin/echo "$dir" | /usr/bin/sed "s|^${PROJECT_ROOT}/||")
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$dir" "1" "missing-dir-readme" \
            "Directory ${relative_dir}/ has ${file_count} files but no README" "HIGH"
    fi
done || true
