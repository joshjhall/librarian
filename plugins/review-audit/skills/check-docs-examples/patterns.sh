#!/usr/bin/env bash
# check-docs-examples — Deterministic Pre-Scan
#
# Extracts code examples from markdown files and validates imports/references
# against actual project source files.
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

PROJECT_ROOT=$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null || /usr/bin/echo ".")

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Only process markdown files
    case "$file" in
        *.md | *.rst) ;;
        *) continue ;;
    esac

    # --- Category: broken-example ---
    # Find Python imports in fenced code blocks and verify modules exist
    # Track if we're inside a code block
    in_code_block=false
    code_lang=""
    line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Detect code block boundaries
        case "$line" in
            '```'python* | '```'py*)
                in_code_block=true
                code_lang="python"
                continue
                ;;
            '```'javascript* | '```'js* | '```'typescript* | '```'ts*)
                in_code_block=true
                code_lang="js"
                continue
                ;;
            '```'bash* | '```'shell* | '```'sh*)
                in_code_block=true
                code_lang="shell"
                continue
                ;;
            '```'*)
                if [ "$in_code_block" = "true" ]; then
                    in_code_block=false
                    code_lang=""
                else
                    in_code_block=true
                    code_lang="unknown"
                fi
                continue
                ;;
        esac

        [ "$in_code_block" = "false" ] && continue

        # Python: check imports
        if [ "$code_lang" = "python" ]; then
            # Match: from X import Y or import X
            module=$(/usr/bin/echo "$line" | /usr/bin/grep -oE '^(from|import) [a-zA-Z_][a-zA-Z0-9_.]*' | /usr/bin/awk '{print $2}' | /usr/bin/head -1)
            if [ -n "$module" ]; then
                # Convert module path to file path
                module_path=$(/usr/bin/echo "$module" | /usr/bin/sed 's/\./\//g')
                # Check if the module exists as a file or directory
                if [ ! -f "${PROJECT_ROOT}/${module_path}.py" ] &&
                    [ ! -f "${PROJECT_ROOT}/${module_path}/__init__.py" ] &&
                    [ ! -d "${PROJECT_ROOT}/${module_path}" ]; then
                    # Skip standard library and common third-party modules
                    case "$module" in
                        os | sys | re | json | typing | pathlib | collections | functools | itertools | dataclasses | \
                            datetime | math | random | copy | io | abc | enum | logging | unittest | pytest | \
                            flask | django | fastapi | requests | numpy | pandas | click | pydantic) continue ;;
                    esac
                    evidence=$(/usr/bin/printf '%.80s' "Import not found in project: ${line}")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "broken-example" \
                        "$evidence" "HIGH"
                fi
            fi
        fi

        # Shell: check script references
        if [ "$code_lang" = "shell" ]; then
            # Match: ./scripts/foo.sh or bash scripts/foo.sh
            script=$(/usr/bin/echo "$line" | /usr/bin/grep -oE '(\./|bash |sh )[a-zA-Z0-9_./-]+\.sh' | /usr/bin/sed 's/^bash //' | /usr/bin/sed 's/^sh //' | /usr/bin/head -1)
            if [ -n "$script" ]; then
                if [ ! -f "${PROJECT_ROOT}/${script}" ]; then
                    evidence=$(/usr/bin/printf '%.80s' "Script not found: ${script}")
                    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "broken-example" \
                        "$evidence" "HIGH"
                fi
            fi
        fi

    done <"$file"

done <"$FILE_LIST"
