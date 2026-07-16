"""Typed exceptions for report_export (design.md §3.2 errors, §11.4).

Every exception maps 1:1 to a CLI process exit code:

    exit 1  UsageError              bad CLI usage / arguments
    exit 2  InputValidationError    malformed / contract-violating input CSV
    exit 3  StateIntegrityError     records.csv tail-integrity failed, .bak also failed
    exit 4  LockBusyError           state_dir lock not acquired immediately
    exit 5  WriteError              deliverable / state write or IO failure
    exit 5  ReferenceError          hosp_id_map reference table missing/unreadable

`cli.py` (a later phase) is the single place that catches these and
calls `sys.exit(exc.exit_code)`; every other module lets them propagate
unmodified -- fail fast, loud, no `except: pass`.
"""

from __future__ import annotations

__all__ = [
    "InputValidationError",
    "LockBusyError",
    "ReferenceError",
    "ReportExportError",
    "StateIntegrityError",
    "UsageError",
    "WriteError",
]


class ReportExportError(Exception):
    """Base class for every typed report_export error.

    Subclasses set `exit_code` to the process exit code defined in
    docs/design.md §11.4. Never caught-and-swallowed internally --
    only `cli.py` catches this family, to translate it into an exit
    code after the structured log record has already been emitted.
    """

    exit_code: int = 1


class UsageError(ReportExportError):
    """Invalid CLI usage or arguments, e.g. an unresolvable path (exit 1)."""

    exit_code = 1


class InputValidationError(ReportExportError):
    """Malformed or contract-violating input CSV (exit 2).

    Covers: header mismatch, wrong column count, unparsable APP_TIME on
    a NORMAL row, missing APP_SERVER/CLIENT_IP/REQUEST_ID, bad
    encoding (design.md §5 S3/S4, §13).
    """

    exit_code = 2


class StateIntegrityError(ReportExportError):
    """records.csv tail-integrity check failed and `.bak` recovery also failed (exit 3)."""

    exit_code = 3


class LockBusyError(ReportExportError):
    """`state_dir`'s lock could not be acquired immediately -- no waiting (exit 4)."""

    exit_code = 4


class WriteError(ReportExportError):
    """Deliverable or state write/IO failure (exit 5)."""

    exit_code = 5


class ReferenceError(ReportExportError):  # noqa: A001 -- name is the design.md §3.2 contract
    """The hosp_id_map reference table is missing, unreadable, or malformed (exit 5)."""

    exit_code = 5
