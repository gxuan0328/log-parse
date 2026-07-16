"""report_export: independent weekly Excel connection-log report automation.

See docs/design.md for the full contract. This package is deliberately
decoupled from the log-parse bash/gawk CLI (design.md §0): no shared
code, no shared config, no shared state.
"""

__version__ = "1.0.0"

__all__ = ["__version__"]
