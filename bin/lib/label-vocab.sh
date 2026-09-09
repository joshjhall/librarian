#!/usr/bin/env bash
# The declared `status/*` label vocabulary — ONE parser, two callers (issue #938).
#
# Description:
#   The union of the `labels:` blocks across plugins/**/metadata.yml is this
#   repo's declaration of which `status/*` labels exist. Two things read it, and
#   they are the two halves of one contract:
#
#     tests/lint-status-label-refs.sh    offline: prose may not name a label
#                                        that nothing declares (#921)
#     bin/label-vocab-reconcile.sh       scheduled: the declaration must match
#                                        `gh label list` in both directions
#
#   WHY THIS FILE EXISTS RATHER THAN A SECOND awk BLOCK. Two parsers over one
#   vocabulary that must agree is precisely the duplication #663 was filed to
#   eliminate, and the failure would be silent in the worst direction: a
#   reconciler whose parser drifted narrow would report a declared label as
#   "absent from the repo" — a false alarm on the job whose entire value is
#   being believed. So the parser is shared, not cross-referenced.
#
# Usage:
#   . "${REPO_ROOT}/bin/lib/label-vocab.sh"
#   declared_status_labels "${REPO_ROOT}/plugins"    # -> sorted, one per line
#
# bash-3.2 clean and BSD-regex clean (macOS target) per CLAUDE.md § Runtime
# policy: no `declare -A`/`mapfile`, and character classes rather than `\s`/`\w`,
# which BSD grep/awk read as literals.

# Header guard to prevent multiple sourcing.
if [ -n "${_LIBRARIAN_LABEL_VOCAB_INCLUDED:-}" ]; then
    return 0
fi
readonly _LIBRARIAN_LABEL_VOCAB_INCLUDED=1

# declared_status_labels - the sorted union of declared `status/*` labels.
#
# Arguments:
#   $1 - path to the plugins/ directory to walk
# Output:
#   One label per line on stdout, sorted and de-duplicated. Prints nothing when
#   the directory holds no metadata.yml or no status/* entries — CALLERS MUST
#   TREAT EMPTY AS FATAL, never as an empty vocabulary: an empty declared set
#   makes every reference undeclared and every live label undeclared at once,
#   which is a parser regression wearing the costume of a finding.
# Returns:
#   0 always (an absent directory yields no output, not an error).
declared_status_labels() {
    local plugins_dir="$1"

    [ -n "$plugins_dir" ] || return 0
    [ -d "$plugins_dir" ] || return 0

    command find "$plugins_dir" -type f -name 'metadata.yml' 2>/dev/null |
        while IFS= read -r meta; do
            [ -n "$meta" ] || continue
            # `inblock` opens at a column-0 `labels:` and closes at the next
            # column-0 key, so a `status/` string in some other block cannot
            # read as a declaration.
            command awk '
                /^labels:/ { inblock = 1; next }
                inblock && /^[a-zA-Z_]+:/ { inblock = 0 }
                # The optional quote in the MATCH, not just in the cleanup below:
                # requiring `status/` immediately after `name:` means a quoted
                # `- name: "status/x"` never matches at all, so the label reads as
                # UNDECLARED rather than as declared-with-quotes. Stripping quotes
                # after the fact cannot fix a line the pattern already skipped —
                # found by the fixture that was written to test the stripping.
                inblock && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*["'"'"']?status\// {
                    sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
                    # A TRAILING COMMENT OR QUOTE IS NOT PART OF THE NAME. No
                    # metadata.yml uses either today, but this function is now the
                    # single source BOTH the offline gate and the scheduled
                    # reconciler trust — so a corpus edit adding `# note` after a
                    # label would produce a false "declared but absent" in one and
                    # a false "undeclared reference" in the other, from one typo.
                    # Extraction is what raised the blast radius; the trim is what
                    # bounds it. Order matters: strip the comment before trimming
                    # trailing space, or the space the comment left behind stays.
                    sub(/[[:space:]]*#.*$/, "")
                    gsub(/["'"'"']/, "")
                    sub(/[[:space:]]+$/, "")
                    print
                }
            ' "$meta"
        done | command sort -u
}
