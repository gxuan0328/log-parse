"""`python -m report_export` entry point (design.md §2.3 __main__)."""

from __future__ import annotations

import sys

# `as main` is a deliberate explicit re-export (mypy --strict no_implicit_reexport)
# so `report_export.__main__.main` is a valid, typed attribute for callers/tests.
from report_export.cli import main as main

if __name__ == "__main__":
    sys.exit(main())
