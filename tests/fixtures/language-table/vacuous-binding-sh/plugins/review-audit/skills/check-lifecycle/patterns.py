"""Fixture stub — mirror image of vacuous-binding/ (#847). Not runnable.

Here the PYTHON half emits `unclosed-handle` and the bash half does not, so the
binding is vacuous in the sh runtime only. vacuous-binding/ is the same tree with
the runtimes swapped.

Two fixtures rather than one because a tree vacuous in BOTH runtimes cannot tell
the detection branches apart — either `if not got_py` or `if not got_sh` alone
still reports it, so deleting one branch survives. Measured: with a single
symmetric fixture both single-branch mutations survived. One asymmetric tree per
runtime is what makes each branch independently pinned.
"""


def scan_file(path: str) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext == "py":
        emit(path, 1, "unreaped-subprocess", "stub")
        emit(path, 1, "unclosed-handle", "stub")
