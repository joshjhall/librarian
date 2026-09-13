"""Fixture: the python half of a split-BASH impl (#991).

Flat on purpose — the split under test is on the bash side. Declares both slugs
the bash impl declares across its two files, so the pair is in true parity and
any reported divergence is the extractor's fault, not the fixture's.
"""


def emit_entry() -> str:
    return "cat-entry-side"


def emit_frag() -> str:
    return "cat-frag-only"
