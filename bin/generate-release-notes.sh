#!/usr/bin/env bash
# Generate GitHub release notes by extracting one version's section from
# CHANGELOG.md. Used by the release flow and the tag-triggered CI workflow.
set -euo pipefail

VERSION="${1:-}"
GH_REPO="${GH_REPO:-joshjhall/librarian}"

if [ -z "$VERSION" ]; then
    command echo "Usage: $0 VERSION" >&2
    exit 1
fi

BIN_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(command dirname "$BIN_DIR")"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

# Extract the "## [VERSION]" section up to (but not including) the next "## [".
extract_section() {
    command awk -v version="$VERSION" '
        $0 ~ "^## \\[" version "\\]" { found = 1; next }
        found && /^## \[/ { exit }
        found { print }
    ' "$CHANGELOG"
}

# strip_blank_edges — drop leading and trailing blank lines from stdin.
#
# NOT a sed one-liner. The previous spelling was
# `sed -e '1{/^$/d}' -e :a -e '/^\n*$/{$d;N;ba' -e '}'`, which GNU sed accepts
# and **BSD sed REJECTS**: it requires a newline or `;` before a closing `}` and
# dies with `extra characters at the end of d command`. The enclosing command
# substitution swallowed that error, `section` came back EMPTY, and the script
# silently produced the generic fallback notes instead of the real CHANGELOG
# section — a wrong release body, emitted with exit 0, on any macOS run (#932).
#
# Pure bash has no dialect, so the question cannot come back. Trailing blanks are
# additionally handled by `$( )` itself, which strips trailing newlines.
strip_blank_edges() {
    local line lead_done="" out=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines until the first line with content.
        if [ -z "$lead_done" ]; then
            case "$line" in
                *[![:space:]]*) lead_done=1 ;;
                *) continue ;;
            esac
        fi
        out="$out$line
"
    done
    command printf '%s' "$out"
}

section=""
if [ -f "$CHANGELOG" ]; then
    # Strip leading/trailing blank lines from the captured section.
    section="$(extract_section | strip_blank_edges)"
fi

if [ -n "$section" ]; then
    command printf '%s\n' "$section"
else
    command cat <<EOF
## Release v$VERSION

See [CHANGELOG.md](https://github.com/${GH_REPO}/blob/v${VERSION}/CHANGELOG.md) for complete details.

Install from the librarian marketplace:

\`\`\`bash
claude plugin marketplace add ${GH_REPO}
claude plugin install dev-core@librarian
claude plugin install review-audit@librarian
claude plugin install workflow@librarian
\`\`\`
EOF
fi
