"""Unit tests for report_export.models (design.md §4.1-§4.3, §6.2)."""

from __future__ import annotations

import dataclasses

import pytest

from report_export.models import InputRow, ReportRow, StateRecord, Status, TransformedRecord

TRANSFORMED_RECORD_FIELD_ORDER: tuple[str, ...] = (
    "request_id",
    "app_time_iso",
    "client_ip",
    "server_ip",
    "hosp_id",
    "hosp_abbr",
    "prsn_id",
    "birthday",
    "patient_id_aes",
)

INPUT_ROW_FIELD_ORDER: tuple[str, ...] = (
    "region",
    "status",
    "api_time",
    "app_time",
    "delta_sec",
    "verify_status",
    "request_id",
    "api_server",
    "app_server",
    "hosp_id",
    "prsn_id",
    "client_ip",
    "patient_id_aes",
    "birthday",
)

STATE_RECORD_FIELD_ORDER: tuple[str, ...] = (
    "batch_id",
    "request_id",
    "app_time_iso",
    "client_ip",
    "server_ip",
    "hosp_id",
    "hosp_abbr",
    "prsn_id",
    "birthday",
    "patient_id_aes",
)


def _sample_input_row() -> InputRow:
    return InputRow(
        region="台北",
        status="NORMAL",
        api_time="2026-07-05 16:03:24.381",
        app_time="2026-07-05 16:03:34.359",
        delta_sec="9.978",
        verify_status="OK",
        request_id="40000930-0002-7a00-b63f-84710c7967bb",
        api_server="10.22.63.37",
        app_server="10.21.3.35",
        hosp_id="1145010038",
        prsn_id="21B026FA29B9A716C23AEB10D3F04A63",
        client_ip="10.243.129.44",
        patient_id_aes="2EDEBACB75D9FA547F2018E13E695AF1",
        birthday="19560711",
    )


def _sample_state_record(**overrides: object) -> StateRecord:
    base: dict[str, object] = {
        "batch_id": 1,
        "request_id": "40000930-0002-7a00-b63f-84710c7967bb",
        "app_time_iso": "2026-07-05 16:03:34.359",
        "client_ip": "10.243.129.44",
        "server_ip": "10.21.3.35",
        "hosp_id": "1145010038",
        "hosp_abbr": "門諾醫院",
        "prsn_id": "21B026FA29B9A716C23AEB10D3F04A63",
        "birthday": "19560711",
        "patient_id_aes": "2EDEBACB75D9FA547F2018E13E695AF1",
    }
    base.update(overrides)
    return StateRecord(**base)  # type: ignore[arg-type]


# --------------------------------------------------------------------
# InputRow
# --------------------------------------------------------------------


def test_input_row_field_order_matches_design_columns_a_to_n() -> None:
    names = tuple(f.name for f in dataclasses.fields(InputRow))
    assert names == INPUT_ROW_FIELD_ORDER


def test_input_row_all_fields_are_str_typed() -> None:
    for f in dataclasses.fields(InputRow):
        assert f.type is str


def test_input_row_is_frozen() -> None:
    row = _sample_input_row()
    with pytest.raises(dataclasses.FrozenInstanceError):
        row.region = "台中"  # type: ignore[misc]


def test_input_row_preserves_leading_zero_hosp_id() -> None:
    row = dataclasses.replace(_sample_input_row(), hosp_id="0937010019")
    assert row.hosp_id == "0937010019"
    assert len(row.hosp_id) == 10


# --------------------------------------------------------------------
# Status
# --------------------------------------------------------------------


def test_status_enum_values() -> None:
    assert Status.NORMAL == "NORMAL"
    assert Status.ORPHAN == "ORPHAN"
    assert Status.UNVERIFIED == "UNVERIFIED"


def test_status_enum_has_exactly_three_members() -> None:
    assert {member.value for member in Status} == {"NORMAL", "ORPHAN", "UNVERIFIED"}


def test_status_constructible_from_normalized_raw_value() -> None:
    raw = "  normal  "
    assert Status(raw.strip().upper()) is Status.NORMAL


def test_status_rejects_unknown_value() -> None:
    with pytest.raises(ValueError, match="UNKNOWN"):
        Status("UNKNOWN")


# --------------------------------------------------------------------
# StateRecord
# --------------------------------------------------------------------


def test_state_record_field_order_matches_schema() -> None:
    names = tuple(f.name for f in dataclasses.fields(StateRecord))
    assert names == STATE_RECORD_FIELD_ORDER


def test_state_record_has_10_fields_2_internal_plus_8_payload() -> None:
    assert len(dataclasses.fields(StateRecord)) == 10


def test_state_record_batch_id_is_int_typed() -> None:
    field_by_name = {f.name: f for f in dataclasses.fields(StateRecord)}
    assert field_by_name["batch_id"].type is int


def test_state_record_payload_fields_are_str_typed() -> None:
    field_by_name = {f.name: f for f in dataclasses.fields(StateRecord)}
    for name in STATE_RECORD_FIELD_ORDER:
        if name in ("batch_id",):
            continue
        assert field_by_name[name].type is str, name


def test_state_record_round_trips_values() -> None:
    record = _sample_state_record(batch_id=1)
    assert record.batch_id == 1
    assert isinstance(record.batch_id, int)
    assert record.hosp_id == "1145010038"


def test_state_record_is_frozen() -> None:
    record = _sample_state_record()
    with pytest.raises(dataclasses.FrozenInstanceError):
        record.batch_id = 2  # type: ignore[misc]


def test_state_record_preserves_leading_zero_hosp_id_and_birthday() -> None:
    record = _sample_state_record(hosp_id="0937010019", birthday="19560711")
    assert record.hosp_id == "0937010019"
    assert record.birthday == "19560711"


# --------------------------------------------------------------------
# TransformedRecord
# --------------------------------------------------------------------


def _sample_transformed_record(**overrides: str) -> TransformedRecord:
    base: dict[str, str] = {
        "request_id": "40000930-0002-7a00-b63f-84710c7967bb",
        "app_time_iso": "2026-07-05 16:03:34.359",
        "client_ip": "10.243.129.44",
        "server_ip": "10.21.3.35",
        "hosp_id": "1145010038",
        "hosp_abbr": "門諾醫院",
        "prsn_id": "21B026FA29B9A716C23AEB10D3F04A63",
        "birthday": "19560711",
        "patient_id_aes": "2EDEBACB75D9FA547F2018E13E695AF1",
    }
    base.update(overrides)
    return TransformedRecord(**base)


def test_transformed_record_field_order_matches_state_record_minus_batch_id() -> None:
    names = tuple(f.name for f in dataclasses.fields(TransformedRecord))
    assert names == TRANSFORMED_RECORD_FIELD_ORDER
    assert names == STATE_RECORD_FIELD_ORDER[1:]  # everything but BATCH_ID


def test_transformed_record_has_9_fields() -> None:
    assert len(dataclasses.fields(TransformedRecord)) == 9


def test_transformed_record_all_fields_are_str_typed() -> None:
    for f in dataclasses.fields(TransformedRecord):
        assert f.type is str


def test_transformed_record_has_no_batch_id_field() -> None:
    names = {f.name for f in dataclasses.fields(TransformedRecord)}
    assert "batch_id" not in names


def test_transformed_record_is_frozen() -> None:
    record = _sample_transformed_record()
    with pytest.raises(dataclasses.FrozenInstanceError):
        record.client_ip = "10.0.0.1"  # type: ignore[misc]


def test_transformed_record_preserves_leading_zero_hosp_id_and_birthday() -> None:
    record = _sample_transformed_record(hosp_id="0937010019", birthday="19560711")
    assert record.hosp_id == "0937010019"
    assert record.birthday == "19560711"


def test_transformed_record_values() -> None:
    record = _sample_transformed_record(hosp_abbr="秀傳醫院")
    assert record.hosp_abbr == "秀傳醫院"
    assert record.request_id == "40000930-0002-7a00-b63f-84710c7967bb"


# --------------------------------------------------------------------
# ReportRow
# --------------------------------------------------------------------


def test_report_row_field_order() -> None:
    names = tuple(f.name for f in dataclasses.fields(ReportRow))
    assert names == ("client_ip", "hosp_id", "hosp_abbr", "count")


def test_report_row_count_is_int_typed() -> None:
    field_by_name = {f.name: f for f in dataclasses.fields(ReportRow)}
    assert field_by_name["count"].type is int


def test_report_row_values() -> None:
    row = ReportRow(client_ip="10.245.1.125", hosp_id="0937010019", hosp_abbr="秀傳醫院", count=7)
    assert row.count == 7
    assert isinstance(row.count, int)
    assert row.hosp_id == "0937010019"


def test_report_row_is_frozen() -> None:
    row = ReportRow(client_ip="x", hosp_id="y", hosp_abbr="z", count=1)
    with pytest.raises(dataclasses.FrozenInstanceError):
        row.count = 2  # type: ignore[misc]
