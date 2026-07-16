"""Unit tests for report_export.dedup (design.md §7.1 test_dedup, §3.4)."""

from __future__ import annotations

import logging

import pytest

from report_export import dedup
from report_export.models import TransformedRecord


def _record(request_id: str, **overrides: str) -> TransformedRecord:
    base: dict[str, str] = {
        "request_id": request_id,
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


# --------------------------------------------------------------------
# No duplicates: every row is new
# --------------------------------------------------------------------


def test_all_unique_rows_all_become_new_records() -> None:
    rows = [(2, _record("a")), (3, _record("b")), (4, _record("c"))]
    new_records, skipped_intra, skipped_cross = dedup.apply(rows, existing_request_ids=set())
    assert [r.request_id for r in new_records] == ["a", "b", "c"]
    assert skipped_intra == 0
    assert skipped_cross == 0


def test_empty_batch_returns_empty() -> None:
    new_records, skipped_intra, skipped_cross = dedup.apply([], existing_request_ids=set())
    assert new_records == []
    assert skipped_intra == 0
    assert skipped_cross == 0


# --------------------------------------------------------------------
# Cross-state duplicates (design.md §3.4.2)
# --------------------------------------------------------------------


def test_cross_state_duplicate_is_skipped() -> None:
    rows = [(2, _record("a")), (3, _record("b"))]
    new_records, skipped_intra, skipped_cross = dedup.apply(rows, existing_request_ids={"a"})
    assert [r.request_id for r in new_records] == ["b"]
    assert skipped_cross == 1
    assert skipped_intra == 0


def test_cross_state_duplicate_logs_warning_with_request_id_and_line(
    caplog: pytest.LogCaptureFixture,
) -> None:
    rows = [(7, _record("dup-id"))]
    with caplog.at_level(logging.WARNING, logger="report_export.dedup"):
        dedup.apply(rows, existing_request_ids={"dup-id"})
    assert any(
        getattr(record, "request_id", None) == "dup-id" and getattr(record, "line_no", None) == 7
        for record in caplog.records
    )


def test_rerun_of_same_input_yields_zero_new_records() -> None:
    # design.md §7.1/§6-4: re-ingesting an identical batch is fully
    # idempotent -- every REQUEST_ID is already in state.
    rows = [(2, _record("a")), (3, _record("b")), (4, _record("c"))]
    existing_ids = {"a", "b", "c"}
    new_records, skipped_intra, skipped_cross = dedup.apply(rows, existing_request_ids=existing_ids)
    assert new_records == []
    assert skipped_cross == 3
    assert skipped_intra == 0


def test_existing_request_ids_is_not_mutated() -> None:
    existing = {"a"}
    dedup.apply([(2, _record("a")), (3, _record("b"))], existing_request_ids=existing)
    assert existing == {"a"}


# --------------------------------------------------------------------
# Intra-batch duplicates (design.md §3.4.2, §6-5: keep first occurrence)
# --------------------------------------------------------------------


def test_intra_batch_duplicate_keeps_first_occurrence_only() -> None:
    rows = [(2, _record("x", client_ip="10.0.0.1")), (3, _record("x", client_ip="10.0.0.2"))]
    new_records, skipped_intra, skipped_cross = dedup.apply(rows, existing_request_ids=set())
    assert len(new_records) == 1
    assert new_records[0].client_ip == "10.0.0.1"
    assert skipped_intra == 1
    assert skipped_cross == 0


def test_intra_batch_duplicate_logs_warning_with_request_id_and_line(
    caplog: pytest.LogCaptureFixture,
) -> None:
    rows = [(2, _record("x")), (9, _record("x"))]
    with caplog.at_level(logging.WARNING, logger="report_export.dedup"):
        dedup.apply(rows, existing_request_ids=set())
    assert any(
        getattr(record, "request_id", None) == "x" and getattr(record, "line_no", None) == 9
        for record in caplog.records
    )


def test_triple_intra_batch_duplicate_counts_two_skips() -> None:
    rows = [(2, _record("x")), (3, _record("x")), (4, _record("x"))]
    new_records, skipped_intra, _skipped_cross = dedup.apply(rows, existing_request_ids=set())
    assert len(new_records) == 1
    assert skipped_intra == 2


def test_repeat_of_a_cross_state_duplicate_is_counted_as_intra_not_cross() -> None:
    # First occurrence of "a" is a cross-state dup; the SECOND
    # occurrence within this same batch is then an intra-batch dup of
    # the first occurrence, not a second cross-state warning.
    rows = [(2, _record("a")), (3, _record("a"))]
    new_records, skipped_intra, skipped_cross = dedup.apply(rows, existing_request_ids={"a"})
    assert new_records == []
    assert skipped_cross == 1
    assert skipped_intra == 1


# --------------------------------------------------------------------
# Mixed scenario + exit-code contract (design.md §3.4.3: always warn-skip, never raises)
# --------------------------------------------------------------------


def test_mixed_new_intra_and_cross_duplicates_in_one_batch() -> None:
    rows = [
        (2, _record("new-1")),
        (3, _record("existing-1")),  # cross
        (4, _record("new-1")),  # intra (repeat of line 2)
        (5, _record("new-2")),
    ]
    new_records, skipped_intra, skipped_cross = dedup.apply(
        rows, existing_request_ids={"existing-1"}
    )
    assert [r.request_id for r in new_records] == ["new-1", "new-2"]
    assert skipped_intra == 1
    assert skipped_cross == 1


def test_apply_never_raises_on_duplicates() -> None:
    # design.md §3.4.3: warn-skip is the only strategy; duplicates never
    # escalate to an exception (exit code stays 0 at the CLI layer).
    rows = [(2, _record("dup")), (3, _record("dup"))]
    dedup.apply(rows, existing_request_ids={"dup"})  # must not raise
