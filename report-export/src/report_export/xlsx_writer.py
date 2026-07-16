"""Build the 2-sheet, value-only deliverable workbook and resolve its
output filename (design.md §3.2 xlsx_writer, §8, §12.1).

Every cell is a literal Python value (`datetime`, `str`, or `int`) --
never a formula string -- reproducing the template's Excel 365
dynamic-array formulas (`UNIQUE`/`FILTER`/`XLOOKUP`/`ANCHORARRAY`/
`COUNTIF`) as pre-computed values (design.md §8.1, §17 R5). The
workbook is built entirely in memory (`build_workbook`); `write()`
layers the filesystem concerns on top: same-day filename
disambiguation (design.md §8.2), directory creation, and a tmp write +
fsync. The FINAL `os.replace` into the live deliverable name is
deliberately left to the caller (design.md §5 S8 vs S9.2: pipeline.py
performs it only after `state.commit()` has already succeeded --
state-first ordering, design.md §6.5).
"""

from __future__ import annotations

import logging
import os
from collections.abc import Mapping, Sequence
from datetime import date, datetime
from pathlib import Path
from typing import Final

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill
from openpyxl.worksheet.worksheet import Worksheet

from report_export.errors import WriteError
from report_export.models import ReportRow, StateRecord

__all__ = ["build_workbook", "resolve_filename", "write"]

logger = logging.getLogger(__name__)

_SHEET_RECORDS: Final[str] = "調閱紀錄"
_SHEET_AGGREGATE: Final[str] = "院所分析"

_RECORDS_HEADER: Final[tuple[str, ...]] = (
    "DATE",
    "TIME",
    "CLIENT IP",
    "SERVER IP",
    "HOSP_ID",
    "HOSP_ABBR",
    "PRSN_ID",
    "BIRTHDAY",
    "PATIENT ID AES",
)
_AGGREGATE_HEADER: Final[tuple[str, ...]] = ("CLIENT IP", "HOSP_ID", "HOSP_ABBR", "COUNT")

#: design.md §2.6/§5 S4: the same two accepted APP_TIME formats as
#: transform.py's contract, duplicated here deliberately -- xlsx_writer
#: is declared to depend only on (openpyxl, models), never transform
#: (design.md §3.2), so the rendering layer re-parses the persisted
#: APP_TIME_ISO string independently rather than importing transform's
#: private constant.
_APP_TIME_FORMATS: Final[tuple[str, ...]] = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")

#: design.md §8.3: exact number_format strings measured off the real
#: template's 調閱紀錄 sheet (A/B columns).
_DATE_NUMBER_FORMAT: Final[str] = r"yyyy\-mm\-dd;@"
_TIME_NUMBER_FORMAT: Final[str] = r"h:mm:ss;@"
#: design.md §4.2/§8.3: text columns are hardened to `@` even where the
#: template itself measured `General` -- deliberate, over the template.
_TEXT_NUMBER_FORMAT: Final[str] = "@"

#: design.md §8.3, §2.9: explicit 8-hex ARGB, FF alpha -- a 6-hex
#: `'FFFF00'` gets stored by openpyxl with alpha=00 (fully transparent).
_HIGHLIGHT_FILL: Final[PatternFill] = PatternFill(fill_type="solid", fgColor="FFFFFF00")
#: design.md §8.5: explicit RGB, not a theme index -- reading a theme
#: color's `fgColor.rgb` raises `Values must be of type str` (measured,
#: design.md §2.5), and theme colors do not portably travel to a new
#: workbook either way. 8-hex with an explicit `FF` alpha for the same
#: reason as the yellow highlight (design.md §2.9): a bare 6-hex
#: `'E2EFDA'` is stored by openpyxl as `'00E2EFDA'` (alpha=00), which
#: would silently defeat the visible-header intent.
_HEADER_FILL: Final[PatternFill] = PatternFill(fill_type="solid", fgColor="FFE2EFDA")
_HEADER_FONT: Final[Font] = Font(bold=True, size=12)

_FILENAME_DATE_FMT: Final[str] = "%Y-%m-%d"
_DELIVERABLE_SUFFIX: Final[str] = "_連線紀錄.xlsx"


# --------------------------------------------------------------------
# build_workbook() -- pure, in-memory (design.md §8.1, §8.3-§8.5)
# --------------------------------------------------------------------


def build_workbook(full_state: Sequence[StateRecord], report_rows: Sequence[ReportRow]) -> Workbook:
    """Build the complete 2-sheet workbook in memory.

    `full_state` order is preserved verbatim onto 調閱紀錄 (existing
    rows first, this run's newly appended batch last, design.md §8.3);
    `report_rows` order is preserved verbatim onto 院所分析
    (first-seen order, design.md §4.3). Rows whose `batch_id` equals
    the highest BATCH_ID present in `full_state` get the yellow
    highlight (design.md §6.5) -- computed fresh from `full_state`
    every call, so a 0-new-records run correctly re-highlights the
    EXISTING latest batch rather than a batch that was never created.

    Exactly 2 sheets, in this order, and the openpyxl default `Sheet`
    is removed (design.md §8.1) -- no 紀錄匯入/格式轉換/HOSP_ID對照表,
    and no formula is ever written (every cell gets a literal value).
    """
    workbook = Workbook()
    workbook.remove(workbook.active)
    _write_records_sheet(workbook.create_sheet(_SHEET_RECORDS), full_state)
    _write_aggregate_sheet(workbook.create_sheet(_SHEET_AGGREGATE), report_rows)
    return workbook


def _write_records_sheet(sheet: Worksheet, full_state: Sequence[StateRecord]) -> None:
    _write_header(sheet, _RECORDS_HEADER)
    max_batch_id = max((record.batch_id for record in full_state), default=0)
    for row_idx, record in enumerate(full_state, start=2):
        _write_record_row(sheet, row_idx, record, highlight=record.batch_id == max_batch_id)


def _write_record_row(
    sheet: Worksheet, row_idx: int, record: StateRecord, *, highlight: bool
) -> None:
    # design.md §4.2/§8.3: A(DATE) and B(TIME) hold the SAME datetime
    # object -- only the number_format differs -- so the round-trip
    # value (including microseconds) is identical on both cells.
    app_time = _parse_app_time_iso(record.app_time_iso)

    date_cell = sheet.cell(row=row_idx, column=1, value=app_time)
    date_cell.number_format = _DATE_NUMBER_FORMAT
    time_cell = sheet.cell(row=row_idx, column=2, value=app_time)
    time_cell.number_format = _TIME_NUMBER_FORMAT
    row_cells = [date_cell, time_cell]

    text_values = (
        record.client_ip,
        record.server_ip,
        record.hosp_id,
        record.hosp_abbr,
        record.prsn_id,
        record.birthday,
        record.patient_id_aes,
    )
    for column, value in enumerate(text_values, start=3):
        cell = sheet.cell(row=row_idx, column=column, value=value)
        cell.number_format = _TEXT_NUMBER_FORMAT
        row_cells.append(cell)

    if highlight:
        for cell in row_cells:
            cell.fill = _HIGHLIGHT_FILL


def _write_aggregate_sheet(sheet: Worksheet, report_rows: Sequence[ReportRow]) -> None:
    _write_header(sheet, _AGGREGATE_HEADER)
    for row_idx, report_row in enumerate(report_rows, start=2):
        text_values = (report_row.client_ip, report_row.hosp_id, report_row.hosp_abbr)
        for column, value in enumerate(text_values, start=1):
            cell = sheet.cell(row=row_idx, column=column, value=value)
            cell.number_format = _TEXT_NUMBER_FORMAT
        sheet.cell(row=row_idx, column=4, value=report_row.count)


def _write_header(sheet: Worksheet, header: tuple[str, ...]) -> None:
    for column, title in enumerate(header, start=1):
        cell = sheet.cell(row=1, column=column, value=title)
        cell.font = _HEADER_FONT
        cell.fill = _HEADER_FILL


def _parse_app_time_iso(raw: str) -> datetime:
    for fmt in _APP_TIME_FORMATS:
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    # Unreachable through the pipeline's own call graph: every
    # APP_TIME_ISO persisted into state already passed
    # transform._validate_app_time's identical format check before
    # being written (design.md §5 S5-S7) -- kept as a fail-loud guard
    # against a hand-edited or otherwise-corrupted records.csv
    # (design.md §9.5 R7: records.csv is machine-owned, never hand-edited,
    # but this module must not silently mis-render it if that happens).
    raise WriteError(f"cannot render APP_TIME_ISO as a datetime: {raw!r}")


# --------------------------------------------------------------------
# Filename resolution -- same-day disambiguation (design.md §8.2)
# --------------------------------------------------------------------


def resolve_filename(
    *,
    run_date: date,
    out_dir: Path,
    today_runs: Sequence[Mapping[str, object]],
    input_sha256: str,
) -> str:
    """Resolve the deliverable's filename for this run (design.md §8.2).

    `today_runs` is every `runs.jsonl` record already logged for
    `run_date` (chronological order), fetched by the caller
    (pipeline.py, via `state.read_runs_for_date`) -- this function only
    reasons over that already-filtered slice, never touches the
    filesystem for `runs.jsonl` itself, keeping xlsx_writer's
    dependency to (openpyxl, models) as declared (design.md §3.2).

    The base name `{run_date}_連線紀錄.xlsx` is used whenever it does
    not already exist in `out_dir` -- the common case (first ingest of
    the day). If it DOES exist: an identical `input_sha256` to the last
    logged run today means an idempotent re-ingest -- reuse the same
    name (deterministic overwrite, design.md §6.5); a DIFFERENT
    `input_sha256` means a genuinely distinct second batch the same day
    -- append `_{seq:02d}` (design.md §8.2, §13-18).
    """
    base_name = f"{run_date.strftime(_FILENAME_DATE_FMT)}{_DELIVERABLE_SUFFIX}"
    if not (out_dir / base_name).exists():
        return base_name
    if today_runs and today_runs[-1].get("input_sha256") == input_sha256:
        return base_name
    # The base file already existing proves at least one earlier batch
    # landed today even if `today_runs` has no record of it (e.g. a
    # lost/reset runs.jsonl) -- never silently reuse/clobber it without
    # a confirmed sha256 match; the disambiguated suffix always starts
    # at 2, never 1 (a lone "_01" would be a nonsensical sibling of the
    # unsuffixed base name that is never itself produced).
    seq = max(len(today_runs), 1) + 1
    stem = base_name.removesuffix(".xlsx")
    return f"{stem}_{seq:02d}.xlsx"


# --------------------------------------------------------------------
# write() -- build + persist to `.tmp`, fsync (design.md §5 S8)
# --------------------------------------------------------------------


def write(
    out_dir: Path,
    full_state: Sequence[StateRecord],
    report_rows: Sequence[ReportRow],
    *,
    run_date: date,
    today_runs: Sequence[Mapping[str, object]],
    input_sha256: str,
) -> tuple[Path, Path]:
    """Build the workbook and persist it to `{filename}.tmp` under
    `out_dir`, fsync'd (design.md §5 S8).

    Returns `(tmp_path, final_path)` WITHOUT renaming `tmp_path` into
    place -- the caller (pipeline.py S9.2) performs that `os.replace`
    only after `state.commit()` has already succeeded, so the
    deliverable never becomes visible ahead of the state it is a
    projection of (design.md §6.5 state-first ordering).

    Raises:
        WriteError (exit 5): `out_dir` cannot be prepared, or the
            workbook cannot be built/saved/fsync'd.
    """
    _ensure_out_dir(out_dir)
    filename = resolve_filename(
        run_date=run_date, out_dir=out_dir, today_runs=today_runs, input_sha256=input_sha256
    )
    final_path = out_dir / filename
    tmp_path = out_dir / f"{filename}.tmp"

    workbook = build_workbook(full_state, report_rows)
    try:
        workbook.save(str(tmp_path))
        os.chmod(tmp_path, 0o600)
        _fsync_path(tmp_path)
    except OSError as exc:
        raise WriteError(f"cannot write deliverable workbook: {tmp_path} ({exc})") from exc
    return tmp_path, final_path


def _ensure_out_dir(out_dir: Path) -> None:
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(out_dir, 0o700)
    except OSError as exc:
        raise WriteError(f"cannot prepare out_dir: {out_dir} ({exc})") from exc


def _fsync_path(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
