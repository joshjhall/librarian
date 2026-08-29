"""Fixture stub — a Python half that dispatches on .py AND .rs. Not runnable."""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        pass
    elif ext == "rs":
        pass
