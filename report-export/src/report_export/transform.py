"""Filter NORMAL rows, validate + project them into 9-field payloads
(design.md §3.2 transform, §5 S4/S5, §12.1).

Pure functions only: no I/O, no mutation of inputs. `project()` takes
the already-loaded HOSP_ID -> HOSP_ABBR table as a plain
`Mapping[str, str]` parameter rather than importing `lookup.py` --
`Mapping.get(key, "")` already IS the IFERROR/XLOOKUP-not-found
semantics `lookup.get()` documents, so no extra module dependency is
needed to resolve HOSP_ABBR here (design.md §5 S5, §9.2).
"""

from __future__ import annotations

import logging
from collections.abc import Mapping
from datetime import datetime
from typing import Final

from report_export.errors import InputValidationError
from report_export.models import InputRow, Status, TransformedRecord

__all__ = ["filter_normal", "project"]

logger = logging.getLogger(__name__)

#: design.md §5 S4: try the millisecond-precision format first (the
#: real input contract, design.md §2.6), then the no-ms form for
#: compatibility.
_APP_TIME_FORMATS: Final[tuple[str, ...]] = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")
_DASH_SENTINEL: Final[str] = "-"


def filter_normal(rows: list[tuple[int, InputRow]]) -> list[tuple[int, InputRow]]:
    """Keep only rows whose STATUS is NORMAL, Excel `=` case-insensitive
    semantics (design.md §5 S4, §12.1): `status.strip().upper() ==
    "NORMAL"`, so `Normal`/`normal`/`NORMAL` are all accepted. Line
    numbers are preserved, order is preserved. Logs the dropped
    ORPHAN/UNVERIFIED count at INFO (design.md §5 S4).
    """
    normal: list[tuple[int, InputRow]] = []
    dropped = 0
    for line_no, row in rows:
        if row.status.strip().upper() == Status.NORMAL.value:
            normal.append((line_no, row))
        else:
            dropped += 1
    logger.info(
        "filtered to NORMAL rows", extra={"normal": len(normal), "dropped_nonnormal": dropped}
    )
    return normal


def project(
    rows: list[tuple[int, InputRow]], hosp_table: Mapping[str, str]
) -> list[TransformedRecord]:
    """Validate + project already NORMAL-filtered rows into
    `TransformedRecord`s (design.md §5 S5, §4.2).

    `app_time_iso` is the untouched original APP_TIME string -- the
    sole source DATE/TIME are later derived from (design.md §4.2) --
    this stage only proves it is parseable under one of
    `_APP_TIME_FORMATS`; it never stores the parsed `datetime` itself
    (xlsx_writer, a later phase, re-parses at write time to avoid any
    intermediate float/serial drift, design.md §8.3, §17 R4).

    HOSP_ABBR is resolved inline via `hosp_table.get(hosp_id, "")`
    (IFERROR semantics, design.md §9.2) and frozen into the record now,
    so a later reference-table update never retroactively rewrites a
    historical row (design.md §5 S5).

    Raises:
        InputValidationError (exit 2): a row's APP_TIME is the dash
            sentinel, blank, or unparsable in both accepted formats;
            or its REQUEST_ID/APP_SERVER/CLIENT_IP is blank or the dash
            sentinel (design.md §5 S4, §7.4, §13-4, §13-8). A blank/dash
            REQUEST_ID is rejected fail-fast here rather than silently
            accepted as a synthetic dedup key (design.md §7.4: "空/缺
            REQUEST_ID...不以合成鍵掩蓋"). The message names only the
            line number and column, never echoes surrounding row
            content (design.md §5 S4: "只報行號+欄名").
    """
    projected: list[TransformedRecord] = []
    for line_no, row in rows:
        _validate_app_time(row.app_time, line_no=line_no)
        _validate_required_field(row.request_id, column="REQUEST_ID", line_no=line_no)
        _validate_required_field(row.app_server, column="APP_SERVER", line_no=line_no)
        _validate_required_field(row.client_ip, column="CLIENT_IP", line_no=line_no)
        projected.append(
            TransformedRecord(
                request_id=row.request_id,
                app_time_iso=row.app_time,
                client_ip=row.client_ip,
                server_ip=row.app_server,
                hosp_id=row.hosp_id,
                hosp_abbr=hosp_table.get(row.hosp_id, ""),
                prsn_id=row.prsn_id,
                birthday=row.birthday,
                patient_id_aes=row.patient_id_aes,
            )
        )
    return projected


def _validate_app_time(raw: str, *, line_no: int) -> None:
    if raw == _DASH_SENTINEL or not raw.strip():
        raise InputValidationError(
            f"line {line_no}: NORMAL row is missing APP_TIME (column APP_TIME)"
        )
    for fmt in _APP_TIME_FORMATS:
        try:
            datetime.strptime(raw, fmt)
        except ValueError:
            continue
        else:
            return
    raise InputValidationError(
        f"line {line_no}: NORMAL row has an unparsable APP_TIME (column APP_TIME)"
    )


def _validate_required_field(value: str, *, column: str, line_no: int) -> None:
    if not value.strip() or value == _DASH_SENTINEL:
        raise InputValidationError(
            f"line {line_no}: NORMAL row is missing required {column} (column {column})"
        )
