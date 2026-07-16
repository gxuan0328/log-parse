"""Unit tests for report_export.errors (exit-code contract, design.md §4.2)."""

from __future__ import annotations

import builtins
from typing import cast

import pytest

from report_export.errors import (
    InputValidationError,
    LockBusyError,
    ReportExportError,
    StateIntegrityError,
    UsageError,
    WriteError,
)
from report_export.errors import ReferenceError as ReportExportReferenceError

ALL_TYPED_ERRORS: tuple[type[ReportExportError], ...] = (
    UsageError,
    InputValidationError,
    StateIntegrityError,
    LockBusyError,
    WriteError,
    ReportExportReferenceError,
)


@pytest.mark.parametrize(
    ("exc_type", "expected_exit_code"),
    [
        (UsageError, 1),
        (InputValidationError, 2),
        (StateIntegrityError, 3),
        (LockBusyError, 4),
        (WriteError, 5),
        (ReportExportReferenceError, 5),
    ],
)
def test_exit_code_matches_design_contract(
    exc_type: type[ReportExportError], expected_exit_code: int
) -> None:
    assert exc_type.exit_code == expected_exit_code


@pytest.mark.parametrize("exc_type", ALL_TYPED_ERRORS)
def test_all_typed_errors_are_report_export_errors(exc_type: type[ReportExportError]) -> None:
    assert issubclass(exc_type, ReportExportError)
    assert issubclass(exc_type, Exception)


@pytest.mark.parametrize("exc_type", ALL_TYPED_ERRORS)
def test_raised_error_carries_message(exc_type: type[ReportExportError]) -> None:
    with pytest.raises(exc_type, match="boom"):
        raise exc_type("boom")


def test_report_export_error_base_default_exit_code() -> None:
    assert ReportExportError.exit_code == 1


def test_reference_error_name_matches_design_contract() -> None:
    # design.md §2.3 names this exception `ReferenceError`; confirm the
    # deliberate builtin shadow (targeted lint suppression in errors.py)
    # is our own type, distinct from the stdlib one, at the import above.
    assert ReportExportReferenceError.__name__ == "ReferenceError"
    # mypy statically proves these two unrelated types can never be the
    # same object (comparison-overlap) -- cast one side to `object` to
    # keep the runtime identity check exactly as written (cast is a
    # no-op at runtime) while comparing as generic objects for the
    # type checker.
    assert cast(object, ReportExportReferenceError) is not builtins.ReferenceError
    assert not issubclass(ReportExportReferenceError, builtins.ReferenceError)
