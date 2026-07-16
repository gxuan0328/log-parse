"""Read + validate the 14-column input CSV (design.md §2.3 csv_reader,
§3.8 S3, §7.1, §6-15).

Boundary module: the only place that opens/reads `INPUT`. Validates the
exact header contract (name + order), a strict 14-column count on every
data row, and known-STATUS enum membership; normalizes stray-whitespace
dash sentinels. Deliberately never parses APP_TIME (or any other value)
here -- that is transform.py's job (design.md §3.8 S4/S5): every `InputRow`
field this module produces is still an opaque `str`.
"""

from __future__ import annotations

import csv
import logging
from collections.abc import Iterator
from pathlib import Path
from typing import Final

from report_export.errors import InputValidationError
from report_export.models import InputRow, Status

__all__ = ["EXPECTED_HEADER", "read"]

logger = logging.getLogger(__name__)

#: design.md §3.1.1 columns A-N, exact literal header row (name + order).
EXPECTED_HEADER: Final[tuple[str, ...]] = (
    "REGION",
    "STATUS",
    "API_TIME",
    "APP_TIME",
    "DELTA_SEC",
    "VERIFY_STATUS",
    "REQUEST_ID",
    "API_SERVER",
    "APP_SERVER",
    "HOSP_ID",
    "PRSN_ID",
    "CLIENT_IP",
    "PATIENT_ID_AES",
    "BIRTHDAY",
)
_EXPECTED_COLS: Final[int] = len(EXPECTED_HEADER)

#: design.md §3.1.1: "-" marks an absent/inapplicable value. A field may
#: carry stray whitespace around it from upstream tooling; normalize
#: any such variant to the canonical sentinel (design.md §3.8 S3).
_DASH_SENTINEL: Final[str] = "-"

_KNOWN_STATUSES: Final[frozenset[str]] = frozenset(member.value for member in Status)


def read(path: Path) -> tuple[list[tuple[int, InputRow]], int]:
    """Read + validate `path` into `InputRow` objects.

    `open(path, newline="", encoding="utf-8-sig")`: `newline=""` is
    required so the `csv` module -- not universal-newline translation
    -- owns CRLF handling (a CRLF input must not leave a trailing
    `\\r` on the last field of a row); `utf-8-sig` transparently
    strips an optional BOM.

    Returns `(numbered_rows, unknown_status_skipped)`. Each element of
    `numbered_rows` pairs a data row's 1-indexed source line number
    (2 = the first row after the header) with its parsed `InputRow`,
    order preserved. Downstream stages (transform.py) need that
    original line number to report "line+col" validation errors
    (design.md §3.8 S4, §4.3) -- `InputRow` itself cannot carry it,
    since its 14 fields are fixed to the CSV contract (design.md
    §3.1.1) and this project's field-order tests pin that shape exactly.

    `unknown_status_skipped` counts data rows dropped because STATUS
    (after `.strip().upper()`) matched none of
    NORMAL/ORPHAN/UNVERIFIED; each such row is also WARN-logged with
    its line number and NOT included in `numbered_rows` (design.md §3.8
    S3).

    Raises:
        InputValidationError: `path` is unreadable or not valid UTF-8
            (exit 2); the header row is missing or does not match the
            14-column contract exactly, name and order (exit 2, lists
            expected vs. got); any data row does not have exactly 14
            columns (exit 2, names the line number) (design.md §3.8 S3,
            §6-15).
    """
    try:
        with path.open(newline="", encoding="utf-8-sig") as fh:
            reader = csv.reader(fh)
            _validate_header(next(reader, None), path=path)
            return _read_data_rows(reader)
    except OSError as exc:
        raise InputValidationError(f"input CSV unreadable: {path} ({exc})") from exc
    except UnicodeDecodeError as exc:
        raise InputValidationError(f"input CSV is not valid UTF-8: {path} ({exc})") from exc


def _validate_header(header: list[str] | None, *, path: Path) -> None:
    got = tuple(header) if header is not None else ()
    if got != EXPECTED_HEADER:
        raise InputValidationError(
            f"input CSV header mismatch in {path}: expected {EXPECTED_HEADER!r}, got {got!r}"
        )


def _read_data_rows(reader: Iterator[list[str]]) -> tuple[list[tuple[int, InputRow]], int]:
    rows: list[tuple[int, InputRow]] = []
    unknown_status_skipped = 0
    for line_no, raw_row in enumerate(reader, start=2):
        if len(raw_row) != _EXPECTED_COLS:
            raise InputValidationError(
                f"input CSV row {line_no} has {len(raw_row)} columns, expected {_EXPECTED_COLS}"
            )
        normalized = [_normalize_dash(field) for field in raw_row]
        status_raw = normalized[1]
        if status_raw.strip().upper() not in _KNOWN_STATUSES:
            logger.warning(
                "unknown STATUS value, skipping row",
                extra={"line_no": line_no, "status": status_raw},
            )
            unknown_status_skipped += 1
            continue
        rows.append((line_no, _to_input_row(normalized)))
    return rows, unknown_status_skipped


def _normalize_dash(field: str) -> str:
    """Collapse stray-whitespace dashes (`" - "`, `"-\\t"`, ...) to the
    canonical `-` sentinel; every other value is returned byte-for-byte
    unchanged (design.md §3.8 S3 dash normalization) -- this is
    deliberately narrower than a general `.strip()`, which would
    silently mask malformed data in non-dash fields.
    """
    return _DASH_SENTINEL if field.strip() == _DASH_SENTINEL else field


def _to_input_row(fields: list[str]) -> InputRow:
    (
        region,
        status,
        api_time,
        app_time,
        delta_sec,
        verify_status,
        request_id,
        api_server,
        app_server,
        hosp_id,
        prsn_id,
        client_ip,
        patient_id_aes,
        birthday,
    ) = fields
    return InputRow(
        region=region,
        status=status,
        api_time=api_time,
        app_time=app_time,
        delta_sec=delta_sec,
        verify_status=verify_status,
        request_id=request_id,
        api_server=api_server,
        app_server=app_server,
        hosp_id=hosp_id,
        prsn_id=prsn_id,
        client_ip=client_ip,
        patient_id_aes=patient_id_aes,
        birthday=birthday,
    )
