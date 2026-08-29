"""Fixture stub — an M cell in a column with no binding (#847). Not runnable.

The `future-detector` column has no entry in BINDINGS, so nothing can check its
cells. The arm below deliberately DOES emit that category, so the tree is
otherwise self-consistent: the defect being armed is the missing binding, not a
missing detector.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
        emit(path, 1, "future-detector", "stub")
