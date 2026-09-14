#!/usr/bin/env bash
# Fixture: the entry of a MULTI-FILE *bash* impl (#991).
#
# The mirror of ../multifile/, which splits the PYTHON half. Here the bash half
# is the split one: `cat-frag-only` is declared in the sourced fragment, not
# here, so parity holds only if sh_sources_for unions this entry with
# `bundle-frag.sh`. Reading the entry alone reports "cat-frag-only" as
# python-only — which is exactly what a split patterns.sh did to
# check-okf-conformance before #991 taught the bash side to follow its sources.
#
# `unrelated-tool.sh` sits beside it and is NOT sourced: it pins that the union
# follows source lines rather than sweeping the directory.
#
# NOT executed by anything: this is source-text input to the slug extractor.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/fixtures/category-parity/multifile-sh/bundle-frag.sh
. "$_here/bundle-frag.sh"

emit_entry() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-entry-side"
}
