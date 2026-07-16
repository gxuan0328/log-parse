"""Unit tests for report_export.transform (design.md §7.1 test_transform,
§3.8 S4/S5, §3.4.4, §6-4, §6-7, §6-8).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from report_export import csv_reader, transform
from report_export.errors import InputValidationError
from report_export.models import InputRow, TransformedRecord

TEMPLATE_DIR = Path(__file__).resolve().parents[2] / "template"
SOURCE_LOG_PATH = TEMPLATE_DIR / "source-log.csv"
REFERENCE_DIR = Path(__file__).resolve().parents[2] / "reference"
HOSP_ID_MAP_PATH = REFERENCE_DIR / "hosp_id_map.csv.gz"


def _row(line_no: int = 2, **overrides: str) -> tuple[int, InputRow]:
    base: dict[str, str] = {
        "region": "台北",
        "status": "NORMAL",
        "api_time": "2026-07-05 16:03:24.381",
        "app_time": "2026-07-05 16:03:34.359",
        "delta_sec": "9.978",
        "verify_status": "OK",
        "request_id": "40000930-0002-7a00-b63f-84710c7967bb",
        "api_server": "10.22.63.37",
        "app_server": "10.21.3.35",
        "hosp_id": "1145010038",
        "prsn_id": "21B026FA29B9A716C23AEB10D3F04A63",
        "client_ip": "10.243.129.44",
        "patient_id_aes": "2EDEBACB75D9FA547F2018E13E695AF1",
        "birthday": "19560711",
    }
    base.update(overrides)
    return line_no, InputRow(**base)


# --------------------------------------------------------------------
# filter_normal -- Excel `=` case-insensitive STATUS filter (design.md §3.8 S4)
# --------------------------------------------------------------------


def test_real_fixture_filters_25_rows_down_to_19_normal() -> None:
    # design.md §1.5.1 e2e row-count anchor: 25 input rows -> 19 NORMAL.
    all_rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    assert len(all_rows) == 25
    normal_rows = transform.filter_normal(all_rows)
    assert len(normal_rows) == 19


def test_filter_normal_keeps_only_normal_rows() -> None:
    rows = [_row(status="NORMAL"), _row(status="ORPHAN"), _row(status="UNVERIFIED")]
    result = transform.filter_normal(rows)
    assert len(result) == 1
    assert result[0][1].status == "NORMAL"


@pytest.mark.parametrize("raw_status", ["Normal", "normal", "NORMAL", " normal ", "NoRmAl"])
def test_filter_normal_is_case_insensitive(raw_status: str) -> None:
    # Excel `=` semantics: STATUS comparison is case-insensitive.
    rows = [_row(status=raw_status)]
    result = transform.filter_normal(rows)
    assert len(result) == 1


def test_filter_normal_preserves_line_numbers_and_order() -> None:
    rows = [
        _row(line_no=2, status="NORMAL", request_id="a"),
        _row(line_no=3, status="ORPHAN", request_id="b"),
        _row(line_no=4, status="NORMAL", request_id="c"),
    ]
    result = transform.filter_normal(rows)
    assert [(line_no, row.request_id) for line_no, row in result] == [(2, "a"), (4, "c")]


def test_filter_normal_on_empty_input_returns_empty() -> None:
    assert transform.filter_normal([]) == []


def test_filter_normal_does_not_mutate_input() -> None:
    rows = [_row(status="NORMAL"), _row(status="ORPHAN")]
    original = list(rows)
    transform.filter_normal(rows)
    assert rows == original


# --------------------------------------------------------------------
# project -- APP_TIME validation + 9-field projection (design.md §3.8 S5)
# --------------------------------------------------------------------


def test_project_maps_all_fields_correctly() -> None:
    rows = [_row()]
    result = transform.project(rows, hosp_table={})
    assert len(result) == 1
    record = result[0]
    assert isinstance(record, TransformedRecord)
    assert record.request_id == "40000930-0002-7a00-b63f-84710c7967bb"
    assert record.app_time_iso == "2026-07-05 16:03:34.359"
    assert record.client_ip == "10.243.129.44"
    assert record.server_ip == "10.21.3.35"  # from APP_SERVER
    assert record.hosp_id == "1145010038"
    assert record.prsn_id == "21B026FA29B9A716C23AEB10D3F04A63"
    assert record.birthday == "19560711"
    assert record.patient_id_aes == "2EDEBACB75D9FA547F2018E13E695AF1"


def test_project_keeps_full_original_app_time_string_with_milliseconds() -> None:
    rows = [_row(app_time="2026-07-05 16:03:34.359")]
    result = transform.project(rows, hosp_table={})
    assert result[0].app_time_iso == "2026-07-05 16:03:34.359"


def test_project_accepts_no_millisecond_app_time() -> None:
    rows = [_row(app_time="2026-07-05 16:03:34")]
    result = transform.project(rows, hosp_table={})
    assert result[0].app_time_iso == "2026-07-05 16:03:34"


def test_project_preserves_leading_zero_hosp_id() -> None:
    rows = [_row(hosp_id="0937010019")]
    result = transform.project(rows, hosp_table={})
    assert result[0].hosp_id == "0937010019"
    assert isinstance(result[0].hosp_id, str)


def test_project_resolves_hosp_abbr_from_table() -> None:
    rows = [_row(hosp_id="0937010019")]
    result = transform.project(rows, hosp_table={"0937010019": "秀傳醫院"})
    assert result[0].hosp_abbr == "秀傳醫院"


def test_project_unmapped_hosp_id_resolves_to_empty_string() -> None:
    rows = [_row(hosp_id="9999999999")]
    result = transform.project(rows, hosp_table={"0937010019": "秀傳醫院"})
    assert result[0].hosp_abbr == ""


def test_project_against_real_reference_table_matches_design_anchor() -> None:
    from report_export import lookup

    hosp_table = lookup.load(HOSP_ID_MAP_PATH)
    rows = [_row(hosp_id="0937010019")]
    result = transform.project(rows, hosp_table=hosp_table)
    assert result[0].hosp_abbr == "秀傳醫院"


def test_project_on_empty_input_returns_empty() -> None:
    assert transform.project([], hosp_table={}) == []


def test_project_preserves_order() -> None:
    rows = [
        _row(request_id="first", client_ip="10.0.0.1"),
        _row(request_id="second", client_ip="10.0.0.2"),
    ]
    result = transform.project(rows, hosp_table={})
    assert [record.request_id for record in result] == ["first", "second"]


def test_project_is_pure_does_not_mutate_hosp_table() -> None:
    hosp_table = {"0937010019": "秀傳醫院"}
    original = dict(hosp_table)
    transform.project([_row(hosp_id="0937010019")], hosp_table=hosp_table)
    assert hosp_table == original


# --------------------------------------------------------------------
# End-to-end against the real 19 NORMAL rows (design.md §7.2 invariant)
# --------------------------------------------------------------------


def test_real_fixture_all_19_normal_rows_project_without_error() -> None:
    all_rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    normal_rows = transform.filter_normal(all_rows)
    result = transform.project(normal_rows, hosp_table={})
    assert len(result) == 19


def test_real_fixture_orphan_row_excluded_before_project() -> None:
    # design.md §6-9: the ORPHAN row (line 8, CLIENT_IP 10.243.129.44)
    # has a valid APP_TIME but a dash API_TIME; it must never reach
    # project() at all because filter_normal() already dropped it.
    all_rows, _ = csv_reader.read(SOURCE_LOG_PATH)
    normal_rows = transform.filter_normal(all_rows)
    normal_line_numbers = {line_no for line_no, _ in normal_rows}
    assert 8 not in normal_line_numbers


# --------------------------------------------------------------------
# NORMAL-row contract violations -> InputValidationError exit 2
# (design.md §3.8 S4, §6-8)
# --------------------------------------------------------------------


def test_dash_app_time_on_normal_row_raises() -> None:
    rows = [_row(app_time="-")]
    with pytest.raises(InputValidationError, match="APP_TIME"):
        transform.project(rows, hosp_table={})


def test_blank_app_time_on_normal_row_raises() -> None:
    rows = [_row(app_time="   ")]
    with pytest.raises(InputValidationError, match="APP_TIME"):
        transform.project(rows, hosp_table={})


def test_unparsable_app_time_on_normal_row_raises() -> None:
    rows = [_row(app_time="not-a-timestamp")]
    with pytest.raises(InputValidationError, match="APP_TIME"):
        transform.project(rows, hosp_table={})


def test_wrong_format_app_time_raises() -> None:
    rows = [_row(app_time="07/05/2026 16:03:34")]
    with pytest.raises(InputValidationError, match="APP_TIME"):
        transform.project(rows, hosp_table={})


def test_app_time_error_message_reports_line_number_only() -> None:
    rows = [_row(line_no=42, app_time="-")]
    with pytest.raises(InputValidationError) as exc_info:
        transform.project(rows, hosp_table={})
    message = str(exc_info.value)
    assert "42" in message
    assert "APP_TIME" in message


def test_missing_request_id_on_normal_row_raises() -> None:
    # design.md §3.4.4/§6-4: blank/missing REQUEST_ID on a NORMAL row is
    # an input-contract violation, never silently accepted as a
    # synthetic dedup key.
    rows = [_row(request_id="")]
    with pytest.raises(InputValidationError, match="REQUEST_ID"):
        transform.project(rows, hosp_table={})


def test_dash_request_id_on_normal_row_raises() -> None:
    rows = [_row(request_id="-")]
    with pytest.raises(InputValidationError, match="REQUEST_ID"):
        transform.project(rows, hosp_table={})


def test_missing_app_server_on_normal_row_raises() -> None:
    rows = [_row(app_server="")]
    with pytest.raises(InputValidationError, match="APP_SERVER"):
        transform.project(rows, hosp_table={})


def test_dash_app_server_on_normal_row_raises() -> None:
    rows = [_row(app_server="-")]
    with pytest.raises(InputValidationError, match="APP_SERVER"):
        transform.project(rows, hosp_table={})


def test_missing_client_ip_on_normal_row_raises() -> None:
    rows = [_row(client_ip="")]
    with pytest.raises(InputValidationError, match="CLIENT_IP"):
        transform.project(rows, hosp_table={})


def test_dash_client_ip_on_normal_row_raises() -> None:
    rows = [_row(client_ip="-")]
    with pytest.raises(InputValidationError, match="CLIENT_IP"):
        transform.project(rows, hosp_table={})


def test_first_invalid_row_reported_even_when_later_rows_are_valid() -> None:
    rows = [_row(line_no=2, app_time="-"), _row(line_no=3)]
    with pytest.raises(InputValidationError, match=r"\b2\b"):
        transform.project(rows, hosp_table={})
