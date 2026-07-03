#!/usr/bin/env python3
"""POSITIVE FIXTURE for validate-scanner-category-parity.sh.

Not a real pre-scan tool. This sibling of the match patterns.sh carries the SAME
category slug set ("alpha-cat", "beta-cat"), so the detector reports no mismatch
and the gate's self-test asserts a clean pass. Minimal + ruff clean.
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
            print("\t".join((path, "1", "alpha-cat", "evidence", "HIGH")))
            print("\t".join((path, "2", "beta-cat", "evidence", "HIGH")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
