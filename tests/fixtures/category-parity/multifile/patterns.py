"""Fixture: the ENTRY module of a multi-file python impl (#772).

Imports TWO siblings by bare name — the same flat, same-directory shape the real
split scanners use (check-decomposition/patterns.py imports both `loc_engine`
and `prose_spec`) — and emits one slug of its own. Two, not one, on purpose: a
single-import fixture cannot catch a union that processes only the FIRST
declared import.

`unrelated_tool.py` sits beside this file and is NOT imported. It must be
EXCLUDED from the union: that is the boundary this fixture exists to pin, and
the reason py_sources_for follows declared imports rather than globbing the
directory (a directory sweep wrongly folded in
check-ai-config/agnix-normalize.py).
"""

from helper_mod import emit_helper
from second_mod import emit_second


def emit_entry():
    print("cat-entry-side")


def run():
    emit_entry()
    emit_helper()
    emit_second()
