"""Unit tests for report_export.aggregate (design.md §7.1 test_aggregate,
§1.5.2, §1.5.3, §3.1.3)."""

from __future__ import annotations

import logging

import pytest

from report_export import aggregate
from report_export.models import ReportRow, StateRecord


def _record(
    batch_id: int, request_id: str, client_ip: str, hosp_id: str, hosp_abbr: str
) -> StateRecord:
    return StateRecord(
        batch_id=batch_id,
        request_id=request_id,
        app_time_iso="2026-07-05 16:03:34.359",
        client_ip=client_ip,
        server_ip="10.21.3.35",
        hosp_id=hosp_id,
        hosp_abbr=hosp_abbr,
        prsn_id="21B026FA29B9A716C23AEB10D3F04A63",
        birthday="19560711",
        patient_id_aes="2EDEBACB75D9FA547F2018E13E695AF1",
    )


# design.md §1.5.2: the 16 NORMAL rows of template/source-log.csv, in
# first-seen CLIENT_IP order -- this module's landed anchor values.
_ANCHOR_TABLE: tuple[tuple[str, str, str, int], ...] = (
    ("10.243.129.44", "1145010038", "門諾醫院", 1),
    ("10.249.8.10", "1101150011", "新光醫院", 1),
    ("10.249.10.249", "1301170017", "台北醫大", 1),
    ("10.238.3.1", "1532061065", "大園敏盛", 1),
    ("10.241.189.173", "3831014971", "晨軒中醫", 1),
    ("10.241.93.164", "1111060015", "基隆長庚", 1),
    ("10.251.166.61", "3505070032", "誼仁診所", 1),
    ("10.245.1.125", "0937010019", "秀傳醫院", 7),
    ("10.245.11.141", "1137080017", "彰基二林醫", 1),
    ("10.238.23.241", "1503190020", "長安醫院", 1),
)


def _anchor_full_state() -> list[StateRecord]:
    records: list[StateRecord] = []
    seq = 0
    for client_ip, hosp_id, hosp_abbr, count in _ANCHOR_TABLE:
        for _ in range(count):
            seq += 1
            records.append(_record(1, f"req-{seq}", client_ip, hosp_id, hosp_abbr))
    return records


# --------------------------------------------------------------------
# Landed anchors (design.md §1.5.2)
# --------------------------------------------------------------------


def test_anchor_unique_ip_count_is_10() -> None:
    rows = aggregate.build(_anchor_full_state())
    assert len(rows) == 10


def test_anchor_first_seen_order_matches_template() -> None:
    rows = aggregate.build(_anchor_full_state())
    assert [row.client_ip for row in rows] == [ip for ip, *_rest in _ANCHOR_TABLE]


def test_anchor_counts_match_template() -> None:
    # design.md §1.5.2/§3.1.3 REQ3: a single-batch state (all rows
    # BATCH_ID=1) means every row IS in the latest batch -- WEEKLY
    # ACCESS equals TOTAL ACCESS equals the old COUNT column for every
    # IP, and no "-" appears anywhere.
    rows = aggregate.build(_anchor_full_state())
    assert [row.total_access for row in rows] == [1, 1, 1, 1, 1, 1, 1, 7, 1, 1]
    assert [row.weekly_access for row in rows] == [1, 1, 1, 1, 1, 1, 1, 7, 1, 1]


def test_anchor_counts_sum_to_16() -> None:
    rows = aggregate.build(_anchor_full_state())
    assert sum(row.total_access for row in rows) == 16
    assert sum(row.weekly_access for row in rows) == 16


def test_anchor_shuchuan_hospital_count_is_7() -> None:
    rows = aggregate.build(_anchor_full_state())
    [row] = [r for r in rows if r.hosp_id == "0937010019"]
    assert row.hosp_abbr == "秀傳醫院"
    assert row.total_access == 7
    assert row.weekly_access == 7


def test_anchor_orphan_excluded_ip_count_is_1() -> None:
    # design.md §1.5.2/§6-9: 10.243.129.44's ORPHAN row (source-log.csv
    # row 8, same IP) never reaches state -- proven by TOTAL ACCESS
    # staying at 1, not 2.
    rows = aggregate.build(_anchor_full_state())
    [row] = [r for r in rows if r.client_ip == "10.243.129.44"]
    assert row.total_access == 1
    assert row.weekly_access == 1


def test_anchor_row_shape_matches_report_row() -> None:
    rows = aggregate.build(_anchor_full_state())
    assert rows[0] == ReportRow(
        client_ip="10.243.129.44",
        hosp_id="1145010038",
        hosp_abbr="門諾醫院",
        weekly_access=1,
        total_access=1,
    )


# --------------------------------------------------------------------
# First-seen semantics (design.md §1.5.3, §3.1.3: XLOOKUP first-match
# against 調閱紀錄 itself, never the 93k reference master)
# --------------------------------------------------------------------


def test_hosp_id_taken_from_first_seen_row_not_master_table() -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "第一次"),
        _record(1, "b", "10.1.1.1", "1111111111", "第一次"),
    ]
    [row] = aggregate.build(records)
    assert row.hosp_abbr == "第一次"


def test_empty_state_returns_empty_list() -> None:
    assert aggregate.build([]) == []


def test_single_record_returns_single_row_with_count_1() -> None:
    [row] = aggregate.build([_record(1, "a", "10.1.1.1", "1111111111", "醫院")])
    assert row.total_access == 1
    assert row.weekly_access == 1


def test_preserves_first_seen_order_across_batches() -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "A"),
        _record(1, "b", "10.2.2.2", "2222222222", "B"),
        _record(2, "c", "10.1.1.1", "1111111111", "A"),  # later batch, same IP
    ]
    rows = aggregate.build(records)
    assert [row.client_ip for row in rows] == ["10.1.1.1", "10.2.2.2"]
    assert [row.total_access for row in rows] == [2, 1]
    # design.md §3.1.3 REQ3: WEEKLY ACCESS only counts batch_id==max(2).
    # 10.1.1.1 has 1 row in batch 2 (weekly<total); 10.2.2.2 has NONE in
    # batch 2 -- it only exists in the now-older batch 1 -> weekly_access=0.
    assert [row.weekly_access for row in rows] == [1, 0]


def test_hosp_abbr_unmapped_carries_through_as_empty_string() -> None:
    [row] = aggregate.build([_record(1, "a", "10.1.1.1", "9999999999", "")])
    assert row.hosp_abbr == ""


# --------------------------------------------------------------------
# Multiple distinct HOSP_ID for one CLIENT IP (design.md §6-11):
# first-seen wins, WARN logged
# --------------------------------------------------------------------


def test_multiple_hosp_ids_for_one_ip_keeps_first_seen(caplog: pytest.LogCaptureFixture) -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "醫院甲"),
        _record(1, "b", "10.1.1.1", "2222222222", "醫院乙"),
    ]
    with caplog.at_level(logging.WARNING, logger="report_export.aggregate"):
        [row] = aggregate.build(records)
    assert row.hosp_id == "1111111111"
    assert row.hosp_abbr == "醫院甲"
    assert row.total_access == 2
    assert row.weekly_access == 2


def test_multiple_hosp_ids_for_one_ip_logs_warning_with_ip_and_ids(
    caplog: pytest.LogCaptureFixture,
) -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "醫院甲"),
        _record(1, "b", "10.1.1.1", "2222222222", "醫院乙"),
    ]
    with caplog.at_level(logging.WARNING, logger="report_export.aggregate"):
        aggregate.build(records)
    [record] = caplog.records
    assert record.client_ip == "10.1.1.1"  # type: ignore[attr-defined]
    assert record.hosp_ids == ["1111111111", "2222222222"]  # type: ignore[attr-defined]


def test_single_hosp_id_per_ip_does_not_warn(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING, logger="report_export.aggregate"):
        aggregate.build(_anchor_full_state())
    assert caplog.records == []


# --------------------------------------------------------------------
# WEEKLY ACCESS vs TOTAL ACCESS (design.md §3.1.3 REQ3): weekly counts
# only rows whose batch_id == max(BATCH_ID) in the full state; total
# counts every row regardless of batch.
# --------------------------------------------------------------------


def test_single_batch_state_has_weekly_equal_total_for_all_ips() -> None:
    # design.md §7.2 E2E-1: a first-ever ingest is a single batch, so
    # every row belongs to the (sole, and therefore latest) batch --
    # WEEKLY ACCESS == TOTAL ACCESS everywhere, never 0.
    rows = aggregate.build(_anchor_full_state())
    assert [row.weekly_access for row in rows] == [row.total_access for row in rows]
    assert all(row.weekly_access > 0 for row in rows)


def test_weekly_access_counts_only_latest_batch_rows() -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "A"),
        _record(2, "b", "10.1.1.1", "1111111111", "A"),
        _record(2, "c", "10.1.1.1", "1111111111", "A"),
    ]
    [row] = aggregate.build(records)
    assert row.total_access == 3
    assert row.weekly_access == 2  # only the 2 batch-2 (max BATCH_ID) rows


def test_older_only_ip_has_weekly_access_zero() -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "A"),  # older batch only
        _record(2, "b", "10.2.2.2", "2222222222", "B"),  # proves batch 2 IS latest
    ]
    rows = aggregate.build(records)
    older_only = next(r for r in rows if r.client_ip == "10.1.1.1")
    assert older_only.total_access == 1
    assert older_only.weekly_access == 0


def test_brand_new_ip_in_latest_batch_has_weekly_equal_total() -> None:
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "A"),
        _record(2, "b", "10.2.2.2", "2222222222", "B"),  # brand new this batch
    ]
    rows = aggregate.build(records)
    brand_new = next(r for r in rows if r.client_ip == "10.2.2.2")
    assert brand_new.total_access == 1
    assert brand_new.weekly_access == 1
    assert brand_new.weekly_access == brand_new.total_access


def test_idempotent_rerun_max_batch_id_unchanged_keeps_weekly_semantics() -> None:
    # A 0-new-records idempotent rerun never appends a new BATCH_ID --
    # aggregate.build() is still called with the SAME full_state, so
    # max_batch_id (and therefore which rows count as "weekly") is
    # unchanged run over run (design.md §4.1 per-run reset semantics).
    records = [
        _record(1, "a", "10.1.1.1", "1111111111", "A"),
        _record(2, "b", "10.2.2.2", "2222222222", "B"),
    ]
    first = aggregate.build(records)
    second = aggregate.build(list(records))  # same state, re-passed
    assert first == second
