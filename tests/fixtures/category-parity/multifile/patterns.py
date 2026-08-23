"""Fixture: the ENTRY module of a multi-file python impl (#772).

Imports `helper_mod` by bare name — the same flat, same-directory import shape
the real split scanners use — and emits one slug of its own. The other slug
lives in the imported sibling.

`unrelated_tool.py` sits beside this file and is NOT imported. It must be
EXCLUDED from the union: that is the boundary this fixture exists to pin, and
the reason py_sources_for follows declared imports rather than globbing the
directory (a directory sweep wrongly folded in
check-ai-config/agnix-normalize.py).
"""

from helper_mod import emit_helper


def emit_entry():
    print("cat-entry-side")


def run():
    emit_entry()
    emit_helper()
