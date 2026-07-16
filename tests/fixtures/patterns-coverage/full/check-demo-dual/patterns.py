#!/usr/bin/env python3
"""Fixture pre-scan (dual-impl union arm, python half).

Emits ONLY py-finding; the sibling patterns.sh emits sh-finding. The coverage
tool must union the two to score this domain 2/2. Not a real scanner; the tool
reads the double-quoted kebab slug literal below, exactly as it does for a real
patterns.py category constant.
"""

import sys

CATEGORY = "py-finding"


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    print("\t".join([path, "1", CATEGORY, "demo", "HIGH"]))


if __name__ == "__main__":
    main()
