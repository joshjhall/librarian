#!/usr/bin/env bash
# check-docs-organization — Deterministic Pre-Scan
#
# Checks for missing standard root documents and directories without READMEs.
# Operates on the project root, not individual files.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
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
# Check directories with significant content but no README
# Configurable depth (default: 2 levels deep)
MAX_DEPTH="${CHECK_ORG_README_DEPTH:-2}"
MIN_FILES="${CHECK_ORG_MIN_FILES:-5}"

/usr/bin/find "$PROJECT_ROOT" -maxdepth "$MAX_DEPTH" -type d \
    -not -path '*/\.*' \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    -not -path '*/.git/*' \
    2>/dev/null | while IFS= read -r dir; do
    # Skip project root (already checked above)
    [ "$dir" = "$PROJECT_ROOT" ] && continue

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
