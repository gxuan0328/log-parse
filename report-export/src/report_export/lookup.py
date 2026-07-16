"""HOSP_ID -> HOSP_ABBR lookup table (design.md §3.2 lookup, §9.2, §5 S1).

Loads the pre-exported `reference/hosp_id_map.csv.gz` (produced by the
one-off dev tool `tools/export_hosp_table.py`) into an in-memory dict.
This module never reads the 93,781-row source xlsx at runtime -- that
workbook is a dev/ops-only input to the export tool; the 2.3MB master
file must never be used as a runtime lookup source (design.md §9.1, §9.3).
"""

from __future__ import annotations

import csv
import gzip
import logging
from collections import Counter
from collections.abc import Mapping
from pathlib import Path
from typing import Final

from report_export.errors import ReferenceError as ReportExportReferenceError

__all__ = ["get", "load"]

logger = logging.getLogger(__name__)

EXPECTED_HEADER: Final[tuple[str, str]] = ("HOSP_ID", "HOSP_ABBR")

#: Sanity-check thresholds (design.md §5 S1: sanity-check anomalies are
#: WARN-only, tolerating master-table evolution). The real table is
#: ~93.8k rows with 10-char keys (design.md §2.8); a large deviation is
#: a signal the source master table changed shape, not a reason to
#: fail the run.
_EXPECTED_KEY_LEN: Final[int] = 10
_MIN_SANE_ROW_COUNT: Final[int] = 1000


def load(path: Path) -> dict[str, str]:
    """Load `path` (gzip CSV, header `HOSP_ID,HOSP_ABBR`) into `dict[str, str]`.

    Every value is read as `str` via `csv.reader` (never `csv.DictReader`
    with type inference), so leading-zero HOSP_IDs -- 531 of the
    93,781 keys, design.md §2.8 -- survive verbatim.

    Sanity checks (row count floor, key length, duplicate keys) are
    WARN-only: the source master table is allowed to evolve (design.md
    §5 S1, §17 R2). Only a missing/unreadable/malformed-header file is
    fail-fast.

    Raises:
        ReferenceError: `path` does not exist, is not a regular file,
            is unreadable, has an unexpected header, or contains a row
            with other than 2 columns (exit 5).
    """
    rows = _read_rows(path)
    table: dict[str, str] = {}
    seen_counts: Counter[str] = Counter()
    for hosp_id, hosp_abbr in rows:
        seen_counts[hosp_id] += 1
        table[hosp_id] = hosp_abbr
    _warn_on_sanity_issues(table=table, seen_counts=seen_counts, path=path)
    return table


def get(table: Mapping[str, str], hosp_id: str) -> str:
    """IFERROR / XLOOKUP-not-found semantics: unmapped `hosp_id` -> `""` (design.md §9.2)."""
    return table.get(hosp_id, "")


def _read_rows(path: Path) -> list[tuple[str, str]]:
    if not path.is_file():
        raise ReportExportReferenceError(f"hosp_id_map reference file not found: {path}")
    try:
        with gzip.open(path, mode="rt", encoding="utf-8", newline="") as fh:
            reader = csv.reader(fh)
            header = next(reader, None)
            if header is None or tuple(header[:2]) != EXPECTED_HEADER:
                raise ReportExportReferenceError(
                    f"hosp_id_map reference file has unexpected header {header!r} "
                    f"(expected {EXPECTED_HEADER!r}): {path}"
                )
            rows: list[tuple[str, str]] = []
            for line_no, row in enumerate(reader, start=2):
                if len(row) != 2:
                    raise ReportExportReferenceError(
                        f"hosp_id_map reference file row {line_no} has {len(row)} columns, "
                        f"expected 2: {path}"
                    )
                rows.append((row[0], row[1]))
    except OSError as exc:
        raise ReportExportReferenceError(
            f"hosp_id_map reference file unreadable: {path} ({exc})"
        ) from exc
    return rows


def _warn_on_sanity_issues(*, table: dict[str, str], seen_counts: Counter[str], path: Path) -> None:
    row_count = len(table)
    if row_count < _MIN_SANE_ROW_COUNT:
        logger.warning(
            "hosp_id_map row count looks unexpectedly small",
            extra={"path": str(path), "row_count": row_count},
        )

    dup_keys = sum(1 for count in seen_counts.values() if count > 1)
    if dup_keys:
        logger.warning(
            "hosp_id_map contains duplicate HOSP_ID keys (last write wins)",
            extra={"path": str(path), "dup_keys": dup_keys},
        )

    key_lengths = (len(key) for key in table)
    non_standard_len = Counter(length for length in key_lengths if length != _EXPECTED_KEY_LEN)
    if non_standard_len:
        logger.warning(
            "hosp_id_map contains HOSP_ID keys with non-standard length",
            extra={"path": str(path), "non_standard_len_hist": dict(non_standard_len)},
        )
