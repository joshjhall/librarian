# shellcheck shell=bash
# Fixture: the sourced fragment of a multi-file bash impl (#991).
#
# Sourced, not executed — no shebang, per the repo's sourced-fragment rule.
# Declares the slug the entry does not, so an entry-only read misses it.
emit_frag() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-frag-only"
}
