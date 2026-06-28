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

BIN_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(/usr/bin/dirname "$BIN_DIR")"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

# Extract the "## [VERSION]" section up to (but not including) the next "## [".
extract_section() {
    command awk -v version="$VERSION" '
        $0 ~ "^## \\[" version "\\]" { found = 1; next }
        found && /^## \[/ { exit }
        found { print }
    ' "$CHANGELOG"
}

section=""
if [ -f "$CHANGELOG" ]; then
    # Strip leading/trailing blank lines from the captured section.
    section="$(extract_section | command sed -e '1{/^$/d}' -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
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
