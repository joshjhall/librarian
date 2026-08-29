"""Fixture stub — the normative EXT_LANG only. Not runnable.

This tree carries NO governed scanner at all, so with LANG_TABLE_EXPECT_ROSTER
set the four-scanner roster check must report all four as undeclared. It arms
the FAILING branch of test_matrices_present, which otherwise skips under every
fixture root and so is never executed by anything.
"""

EXT_LANG = {
    "py": "py",
}
