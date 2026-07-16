"""Unit tests for report_export.csv_reader (design.md §7.1 test_csv_reader,
§3.8 S3, §6-15).
"""

from __future__ import annotations

import logging
from pathlib import Path

import pytest

from report_export import csv_reader
from report_export.errors import InputValidationError
from report_export.models import InputRow

# report-export/template/source-log.csv -- the real, checked-in e2e
# fixture (design.md §1.5.6: 25 data rows, CRLF, no BOM, no trailing
# newline on the last line).
TEMPLATE_DIR = Path(__file__).resolve().parents[2] / "template"
SOURCE_LOG_PATH = TEMPLATE_DIR / "source-log.csv"

HEADER_LINE = ",".join(csv_reader.EXPECTED_HEADER)


def _write_csv(path: Path, *lines: str, newline: str = "\n") -> None:
    path.write_bytes((newline.join(lines) + newline).encode("utf-8"))


def _data_row(**overrides: str) -> str:
    base = {
        "REGION": "台北",
        "STATUS": "NORMAL",
        "API_TIME": "2026-07-05 16:03:24.381",
        "APP_TIME": "2026-07-05 16:03:34.359",
        "DELTA_SEC": "9.978",
        "VERIFY_STATUS": "OK",
        "REQUEST_ID": "40000930-0002-7a00-b63f-84710c7967bb",
        "API_SERVER": "10.22.63.37",
        "APP_SERVER": "10.21.3.35",
        "HOSP_ID": "1145010038",
        "PRSN_ID": "21B026FA29B9A716C23AEB10D3F04A63",
        "CLIENT_IP": "10.243.129.44",
        "PATIENT_ID_AES": "2EDEBACB75D9FA547F2018E13E695AF1",
        "BIRTHDAY": "19560711",
    }
    base.update(overrides)
    return ",".join(base[col] for col in csv_reader.EXPECTED_HEADER)


# --------------------------------------------------------------------
# Real template/source-log.csv -- e2e input fixture anchors
# --------------------------------------------------------------------


def test_real_fixture_reads_all_25_known_status_rows() -> None:
    rows, unknown_status_skipped = csv_reader.read(SOURCE_LOG_PATH)
    assert len(rows) == 25
    assert unknown_status_skipped == 0


def test_real_fixture_line_numbers_start_at_2() -> None:
    rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    line_numbers = [line_no for line_no, _ in rows]
    assert line_numbers[0] == 2
    assert line_numbers == list(range(2, 27))


def test_real_fixture_status_counts_match_design_anchor() -> None:
    # design.md §1.5.1: NORMAL 19 / ORPHAN 1 / UNVERIFIED 5.
    rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    statuses = [row.status for _, row in rows]
    assert statuses.count("NORMAL") == 19
    assert statuses.count("ORPHAN") == 1
    assert statuses.count("UNVERIFIED") == 5


def test_real_fixture_crlf_last_field_has_no_trailing_cr() -> None:
    # design.md §1.5.6/§3.8 S3/§7.1: CRLF input read with newline="" must
    # not leave a trailing \r on the last column of any row.
    rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    for _, row in rows:
        assert not row.birthday.endswith("\r")
        assert "\r" not in row.birthday


def test_real_fixture_last_row_has_no_trailing_newline_artifact() -> None:
    # source-log.csv's last physical line has no trailing newline at
    # all (design.md §1.5.6) -- confirm the last row still parses cleanly.
    rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    last_line_no, last_row = rows[-1]
    assert last_line_no == 26
    assert last_row.status == "UNVERIFIED"
    assert not last_row.birthday.endswith("\r")


def test_real_fixture_preserves_leading_zero_hosp_id() -> None:
    rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    hosp_ids = {row.hosp_id for _, row in rows}
    assert "0937010019" in hosp_ids


# --------------------------------------------------------------------
# Header validation (design.md §3.8 S3: exact name + order, 14 columns)
# --------------------------------------------------------------------


def test_valid_header_with_zero_data_rows_returns_empty(tmp_path: Path) -> None:
    path = tmp_path / "empty.csv"
    _write_csv(path, HEADER_LINE)
    rows, unknown_status_skipped = csv_reader.read(path)
    assert rows == []
    assert unknown_status_skipped == 0


def test_missing_column_in_header_raises_with_expected_vs_got(tmp_path: Path) -> None:
    path = tmp_path / "bad_header.csv"
    bad_header = ",".join(csv_reader.EXPECTED_HEADER[:-1])  # drop BIRTHDAY
    _write_csv(path, bad_header, _data_row())
    with pytest.raises(InputValidationError) as exc_info:
        csv_reader.read(path)
    message = str(exc_info.value)
    assert "expected" in message
    assert "got" in message
    assert "BIRTHDAY" in message


def test_reordered_header_columns_raises(tmp_path: Path) -> None:
    path = tmp_path / "reordered.csv"
    columns = list(csv_reader.EXPECTED_HEADER)
    columns[0], columns[1] = columns[1], columns[0]  # swap REGION/STATUS
    _write_csv(path, ",".join(columns))
    with pytest.raises(InputValidationError, match="header mismatch"):
        csv_reader.read(path)


def test_extra_header_column_raises(tmp_path: Path) -> None:
    path = tmp_path / "extra_col.csv"
    _write_csv(path, HEADER_LINE + ",EXTRA")
    with pytest.raises(InputValidationError, match="header mismatch"):
        csv_reader.read(path)


def test_completely_empty_file_raises_header_mismatch(tmp_path: Path) -> None:
    path = tmp_path / "totally_empty.csv"
    path.write_bytes(b"")
    with pytest.raises(InputValidationError, match="header mismatch"):
        csv_reader.read(path)


def test_missing_input_file_raises_input_validation_error(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist.csv"
    with pytest.raises(InputValidationError, match="unreadable"):
        csv_reader.read(missing)


def test_directory_as_input_raises_input_validation_error(tmp_path: Path) -> None:
    with pytest.raises(InputValidationError):
        csv_reader.read(tmp_path)


# --------------------------------------------------------------------
# Strict 14-column row validation (design.md §3.8 S3: line number on mismatch)
# --------------------------------------------------------------------


def test_row_with_too_few_columns_raises_with_line_number(tmp_path: Path) -> None:
    path = tmp_path / "short_row.csv"
    _write_csv(path, HEADER_LINE, "台北,NORMAL,only,three,fields")
    with pytest.raises(InputValidationError, match=r"row 2\b"):
        csv_reader.read(path)


def test_row_with_too_many_columns_raises_with_line_number(tmp_path: Path) -> None:
    path = tmp_path / "long_row.csv"
    _write_csv(path, HEADER_LINE, _data_row() + ",EXTRA_FIELD")
    with pytest.raises(InputValidationError, match=r"row 2\b"):
        csv_reader.read(path)


def test_column_count_error_reports_correct_line_number_for_later_row(tmp_path: Path) -> None:
    path = tmp_path / "later_bad_row.csv"
    _write_csv(path, HEADER_LINE, _data_row(), _data_row(), "bad,row")
    with pytest.raises(InputValidationError, match=r"row 4\b"):
        csv_reader.read(path)


def test_quoted_field_containing_comma_counts_as_one_column(tmp_path: Path) -> None:
    # Standard CSV quoting must not be mistaken for an extra column.
    path = tmp_path / "quoted.csv"
    row = _data_row(REGION='"台北,分區"')
    _write_csv(path, HEADER_LINE, row)
    rows, _ = csv_reader.read(path)
    assert len(rows) == 1
    assert rows[0][1].region == "台北,分區"


# --------------------------------------------------------------------
# STATUS: unknown value -> WARN + skip + count (design.md §3.8 S3)
# --------------------------------------------------------------------


def test_unknown_status_is_skipped_and_counted(tmp_path: Path) -> None:
    path = tmp_path / "unknown_status.csv"
    _write_csv(path, HEADER_LINE, _data_row(STATUS="BOGUS"), _data_row())
    rows, unknown_status_skipped = csv_reader.read(path)
    assert len(rows) == 1
    assert unknown_status_skipped == 1


def test_unknown_status_logs_warning_with_line_number(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    path = tmp_path / "unknown_status_warn.csv"
    _write_csv(path, HEADER_LINE, _data_row(STATUS="GARBAGE"))
    with caplog.at_level(logging.WARNING, logger="report_export.csv_reader"):
        csv_reader.read(path)
    assert any(
        "unknown STATUS" in record.message and getattr(record, "line_no", None) == 2
        for record in caplog.records
    )


@pytest.mark.parametrize("raw_status", ["Normal", "normal", "NORMAL", " normal ", "NoRmAl"])
def test_case_insensitive_known_status_values_are_kept(tmp_path: Path, raw_status: str) -> None:
    path = tmp_path / "mixed_case.csv"
    _write_csv(path, HEADER_LINE, _data_row(STATUS=raw_status))
    rows, unknown_status_skipped = csv_reader.read(path)
    assert unknown_status_skipped == 0
    assert len(rows) == 1


def test_orphan_and_unverified_are_known_statuses(tmp_path: Path) -> None:
    path = tmp_path / "other_statuses.csv"
    _write_csv(path, HEADER_LINE, _data_row(STATUS="ORPHAN"), _data_row(STATUS="UNVERIFIED"))
    rows, unknown_status_skipped = csv_reader.read(path)
    assert unknown_status_skipped == 0
    assert len(rows) == 2


# --------------------------------------------------------------------
# Dash sentinel normalization (design.md §3.8 S3)
# --------------------------------------------------------------------


def test_stray_whitespace_around_dash_is_normalized(tmp_path: Path) -> None:
    path = tmp_path / "dash.csv"
    _write_csv(path, HEADER_LINE, _data_row(API_TIME=" - "))
    rows, _ = csv_reader.read(path)
    assert rows[0][1].api_time == "-"


def test_bare_dash_is_left_unchanged(tmp_path: Path) -> None:
    path = tmp_path / "bare_dash.csv"
    _write_csv(path, HEADER_LINE, _data_row(API_TIME="-"))
    rows, _ = csv_reader.read(path)
    assert rows[0][1].api_time == "-"


def test_non_dash_field_is_never_stripped(tmp_path: Path) -> None:
    # Only the dash sentinel is normalized -- every other value passes
    # through byte-for-byte, whitespace included (design.md §3.8 S3: not
    # a general .strip(), a narrow dash-only normalization).
    path = tmp_path / "not_dash.csv"
    _write_csv(path, HEADER_LINE, _data_row(REGION=" 台北 "))
    rows, _ = csv_reader.read(path)
    assert rows[0][1].region == " 台北 "


# --------------------------------------------------------------------
# Encoding (design.md §3.8 S3: utf-8-sig; §6-15: strict decode errors)
# --------------------------------------------------------------------


def test_bom_prefixed_file_is_tolerated(tmp_path: Path) -> None:
    path = tmp_path / "bom.csv"
    content = (HEADER_LINE + "\n" + _data_row() + "\n").encode("utf-8-sig")
    path.write_bytes(content)
    rows, _ = csv_reader.read(path)
    assert len(rows) == 1
    # A leftover BOM would corrupt the first header field (REGION),
    # which would surface as a header-mismatch failure above -- so
    # reaching here with 1 row already proves BOM stripping worked.
    assert rows[0][1].status == "NORMAL"


def test_invalid_utf8_bytes_raise_input_validation_error(tmp_path: Path) -> None:
    path = tmp_path / "bad_encoding.csv"
    path.write_bytes((HEADER_LINE + "\n").encode("utf-8") + b"\xff\xfe\x00bad,row,here\n")
    with pytest.raises(InputValidationError, match="UTF-8"):
        csv_reader.read(path)


# --------------------------------------------------------------------
# Return shape
# --------------------------------------------------------------------


def test_returns_input_row_instances(tmp_path: Path) -> None:
    path = tmp_path / "shape.csv"
    _write_csv(path, HEADER_LINE, _data_row())
    rows, _ = csv_reader.read(path)
    line_no, row = rows[0]
    assert isinstance(line_no, int)
    assert isinstance(row, InputRow)
