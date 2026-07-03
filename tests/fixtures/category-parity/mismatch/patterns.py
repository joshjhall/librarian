#!/usr/bin/env python3
"""NEGATIVE FIXTURE for validate-scanner-category-parity.sh.

Not a real pre-scan tool. This sibling of the mismatch patterns.sh emits a
shared slug plus one slug the bash impl lacks, so their per-file slug sets
differ. The gate's self-test asserts the detector reports both one-sided slugs.
Minimal + ruff clean.

NOTE: this docstring must not quote the bash impl's one-sided slug literal, or
the category-slug extractor (which scans the whole file) would see both slugs in
both impls and the sets would falsely match.
"""

import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: patterns.py <file-list>", file=sys.stderr)
        return 1
    with open(argv[1], encoding="utf-8") as handle:
        for raw in handle:
            path = raw.strip()
            if not path:
                continue
            print("\t".join((path, "1", "shared-category", "evidence", "HIGH")))
            print("\t".join((path, "2", "cat-py-only", "evidence", "HIGH")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
