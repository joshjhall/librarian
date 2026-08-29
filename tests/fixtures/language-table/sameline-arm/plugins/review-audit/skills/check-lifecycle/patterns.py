"""Fixture stub — the Python twin of the same-line `;;` trap tree (#847).

Mirrors the bash half's real coverage: `py` is modeled, `rs` is not. Python has
no `;;` construct, so this half is correct under both a working and a broken
bash splitter — which is the point. It keeps the fixture's ONLY variable the
bash arm-delimiting, so a failure here can mean nothing else. Not runnable.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
    elif ext == "rs":
        emit(path, 1, "some-other-category", "stub")
