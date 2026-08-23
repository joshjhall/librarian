#!/usr/bin/env bash
# Fixture: the bash half of a MULTI-FILE python impl (#772).
#
# Declares both slugs — one emitted from the entry, one from the imported
# sibling module. Parity holds only if py_sources_for unions the entry with
# `helper_mod.py`; reading the entry alone reports "cat-helper-only" as
# sh-only.
#
# NOT executed by anything: this is source-text input to the slug extractor.
emit_entry() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-entry-side"
}

emit_helper() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-helper-only"
}

emit_second() {
    printf 'x\t1\t%s\tevidence\tHIGH\n' "cat-second-sibling"
}
