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
        # TRAILING comment, on a line that really does emit a DIFFERENT category.
        # Stripping only whole-line comments leaves this one in the searched text
        # and `unclosed-handle` still reads as covered — the gap that shipped in
        # the first version of strip_comments, whose docstring called exactly
        # this case "harmless".
        emit(path, 1, "unreaped-subprocess", "stub")  # not "unclosed-handle" yet
        # TODO: also emit "unclosed-handle" here once the Rust arms land (#838).
        # The whole-line form of the same mistake.

    # A `#` inside a STRING is code, not a comment. The `#` must sit on the SAME
    # line as the category tag and BEFORE it: a quote-blind stripper cuts at that
    # `#` and takes the tag with it, so `unclosed-handle` loses its only py
    # evidence and the M cell fails. Split across two lines this proves nothing —
    # cutting a line the tag is not on costs the match nothing (measured: that
    # arrangement let the quote-blind mutation survive).
    if ext == "py":
        emit(path, 2, "#{interp}", "unclosed-handle")
