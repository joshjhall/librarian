"""Fixture: a sibling .py that is NOT part of the patterns pair (#772).

The real instance of this is check-ai-config/agnix-normalize.py, a JSON->TSV
bridge living beside patterns.py without being part of it. Folding its slugs
into the pair's python side reports a python-only divergence on a pair that is
in fact in parity — which is exactly what a directory sweep did before
py_sources_for was scoped to declared imports.

The slug below appears in NO patterns.sh, so if this file is ever pulled into
the union the parity check reports it as python-only and the fixture test fails.
"""


def emit_unrelated():
    print("cat-not-in-the-pair")
