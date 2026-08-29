"""Fixture stub — the `fn` binding kind (#847). Not runnable.

Both functions emit the SAME `debug-statement` category, exactly as the real
check-code-health does. Only the enclosing function name separates them, so this
tree pins the fn-tracking in py_arms: collapse the two and `rs` reads as
debug-print-covered, contradicting its `—` cell.

The function names match the real BINDINGS entries on purpose — the map keys on
`_scan_debug_print`/`_scan_debugger`, so a fixture using different names would
exercise nothing.
"""


def _scan_debug_print(path: str, ext: str) -> None:
    if ext == "py":
        emit(path, 1, "debug-statement", "stub")


def _scan_debugger(path: str, ext: str) -> None:
    if ext == "py":
        emit(path, 1, "debug-statement", "stub")
    elif ext == "rs":
        emit(path, 1, "debug-statement", "stub")
