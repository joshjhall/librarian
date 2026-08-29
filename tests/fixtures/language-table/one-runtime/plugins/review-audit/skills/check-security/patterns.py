"""Fixture stub — a Python half that dispatches on .py AND .rs. Not runnable.

The arms emit the `injection-risk` category tag because the gate binds that
matrix column to the arms carrying it (#847). A stub with no tag would resolve
to an empty region and trip the binding anti-vacuity check instead of the
matrix<->source assertion this fixture exists to arm.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "injection-risk", "stub")
    elif ext == "rs":
        emit(path, 1, "injection-risk", "stub")
