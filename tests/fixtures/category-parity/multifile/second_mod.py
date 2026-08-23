"""Fixture: a SECOND imported sibling of a multi-file python impl (#772).

The real shape has two: check-decomposition/patterns.py imports both
`loc_engine` and `prose_spec`, each contributing slugs. A fixture with only one
sibling cannot catch a union that processes just the first declared import —
and the self-test's exact-count assertion would actively pin that bug in place.
"""


def emit_second():
    print("cat-second-sibling")
