"""Fixture stub — the `file` binding kind (#847). Not runnable.

Emits no literal category tag, exactly like the real check-docs-missing-api
Python half — which is why its column is bound whole-file rather than by tag.

Covers `py` and `rs` but NOT `rlib`. The matrix marks the Rust row `M (rs only)`,
so the narrowing must restrict that cell to `rs` and read `rlib` as `—`. Drop the
narrowing parse and `rlib` is demanded in both runtimes, and this tree fails.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        pass
    elif ext == "rs":
        pass
