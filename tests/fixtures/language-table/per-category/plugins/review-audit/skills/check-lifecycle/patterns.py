"""Fixture stub — per-category divergence (#847). Not runnable.

`py` is covered by BOTH categories. `rs` is covered by `unreaped-subprocess`
ONLY, while the matrix claims `M` for it in `unclosed-handle` too.

The point of the fixture is that `rs` IS dispatched in this file — so the
whole-file union contains it, and the old per-language check was satisfied. Only
a per-CATEGORY check sees that the `unclosed-handle` region lacks the arm.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
        emit(path, 1, "unclosed-handle", "stub")
    elif ext == "rs":
        emit(path, 1, "unreaped-subprocess", "stub")
