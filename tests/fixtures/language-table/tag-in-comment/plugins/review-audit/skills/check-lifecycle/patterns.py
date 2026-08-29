"""Fixture stub — a category tag MENTIONED in a comment (#847). Not runnable.

The `rs` arm emits `unreaped-subprocess` and only talks about `unclosed-handle`
in a comment. The matrix marks that cell `—`, truthfully.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
        emit(path, 1, "unclosed-handle", "stub")
    elif ext == "rs":
        emit(path, 1, "unreaped-subprocess", "stub")
        # TODO: also emit "unclosed-handle" here once the Rust arms land (#838).
        # This mention is the fixture: a raw-body tag match reads it as coverage.
