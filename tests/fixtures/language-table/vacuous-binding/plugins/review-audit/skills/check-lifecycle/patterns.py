"""Fixture stub — a binding that resolves to NO arm (#847). Not runnable.

Emits `unreaped-subprocess` but never `unclosed-handle`, so the latter column's
tag binding matches nothing. The `unclosed-handle` cell is `—`, which a working
gate would pass silently — the point is that assertion 5 fires on the empty
REGION regardless of whether any cell disagrees.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
