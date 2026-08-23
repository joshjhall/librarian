"""Fixture: the IMPORTED sibling module of a multi-file python impl (#772).

Carries the second slug. It is reachable only through the entry's
`from helper_mod import ...` line, so a union built from declared imports
includes it and an entry-only read does not.
"""


def emit_helper():
    print("cat-helper-only")
