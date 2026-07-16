"""Unit tests for report_export.state (design.md §12.1 test_state, §6.2-§6.8)."""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import date
from pathlib import Path

import pytest

from report_export import state
from report_export.errors import StateIntegrityError, WriteError
from report_export.models import StateRecord, TransformedRecord


def _state_record(batch_id: int = 1, request_id: str = "req-1", **overrides: str) -> StateRecord:
    base: dict[str, object] = {
        "batch_id": batch_id,
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
    return StateRecord(**base)  # type: ignore[arg-type]


def _transformed(request_id: str, **overrides: str) -> TransformedRecord:
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
# Empty start (design.md §5 S2, §6.8, §13-10)
# --------------------------------------------------------------------


def test_load_missing_records_csv_returns_empty_state(tmp_path: Path) -> None:
    result = state.load(tmp_path / "state")
    assert result.existing == []
    assert result.existing_request_ids == set()
    assert result.max_batch_seq == 0


def test_load_on_nonexistent_state_dir_returns_empty_state(tmp_path: Path) -> None:
    result = state.load(tmp_path / "brand" / "new" / "state")
    assert result.existing == []
    assert result.max_batch_seq == 0


# --------------------------------------------------------------------
# assign_batch -- BATCH_ID from 1 (design.md §5 S7, §6.2, §6.8, §13-10)
# --------------------------------------------------------------------


def test_assign_batch_starts_at_1_for_empty_state() -> None:
    records = state.assign_batch([_transformed("a"), _transformed("b")], max_batch_seq=0)
    assert [r.batch_id for r in records] == [1, 1]


def test_assign_batch_increments_from_existing_max() -> None:
    records = state.assign_batch([_transformed("a")], max_batch_seq=5)
    assert records[0].batch_id == 6


def test_assign_batch_preserves_all_payload_fields() -> None:
    transformed = _transformed("req-x", client_ip="10.1.1.1", hosp_abbr="秀傳醫院")
    [record] = state.assign_batch([transformed], max_batch_seq=0)
    assert record.request_id == "req-x"
    assert record.client_ip == "10.1.1.1"
    assert record.hosp_abbr == "秀傳醫院"
    assert record.app_time_iso == transformed.app_time_iso


def test_assign_batch_on_empty_list_returns_empty() -> None:
    assert state.assign_batch([], max_batch_seq=3) == []


def test_assign_batch_preserves_order() -> None:
    transformed = [_transformed("a"), _transformed("b"), _transformed("c")]
    records = state.assign_batch(transformed, max_batch_seq=0)
    assert [r.request_id for r in records] == ["a", "b", "c"]


# --------------------------------------------------------------------
# commit() + load() round trip (design.md §6.1-§6.2; no ms drift)
# --------------------------------------------------------------------


def test_round_trip_preserves_all_fields(tmp_path: Path) -> None:
    original = [_state_record(batch_id=1, request_id="req-1", hosp_id="0937010019")]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.existing == original


def test_round_trip_app_time_iso_has_no_millisecond_drift(tmp_path: Path) -> None:
    original = [_state_record(app_time_iso="2026-07-05 16:03:34.359")]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.existing[0].app_time_iso == "2026-07-05 16:03:34.359"


def test_round_trip_preserves_leading_zero_hosp_id(tmp_path: Path) -> None:
    original = [_state_record(hosp_id="0937010019")]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.existing[0].hosp_id == "0937010019"


def test_round_trip_preserves_record_order(tmp_path: Path) -> None:
    original = [
        _state_record(request_id="a"),
        _state_record(request_id="b"),
        _state_record(request_id="c"),
    ]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert [r.request_id for r in result.existing] == ["a", "b", "c"]


def test_round_trip_computes_max_batch_seq(tmp_path: Path) -> None:
    original = [
        _state_record(batch_id=1, request_id="a"),
        _state_record(batch_id=2, request_id="b"),
    ]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.max_batch_seq == 2


def test_round_trip_builds_existing_request_ids_set(tmp_path: Path) -> None:
    original = [_state_record(request_id="a"), _state_record(request_id="b")]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.existing_request_ids == {"a", "b"}


def test_round_trip_handles_field_containing_comma(tmp_path: Path) -> None:
    original = [_state_record(hosp_abbr="醫院, 分院")]
    state.commit(tmp_path, original)
    result = state.load(tmp_path)
    assert result.existing[0].hosp_abbr == "醫院, 分院"


def test_commit_empty_list_produces_header_only_state(tmp_path: Path) -> None:
    state.commit(tmp_path, [])
    result = state.load(tmp_path)
    assert result.existing == []
    assert result.max_batch_seq == 0


# --------------------------------------------------------------------
# In-file #META integrity tail (design.md §6.3)
# --------------------------------------------------------------------


def test_commit_writes_meta_tail_line(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    text = (tmp_path / "records.csv").read_text(encoding="utf-8")
    lines = text.rstrip("\n").split("\n")
    assert lines[-1].startswith("#META")
    assert "records=1" in lines[-1]
    assert "last_batch_seq=1" in lines[-1]
    assert "sha256=" in lines[-1]


def test_meta_tail_last_batch_seq_reflects_max_batch_id(tmp_path: Path) -> None:
    records = [_state_record(batch_id=1, request_id="a"), _state_record(batch_id=3, request_id="b")]
    state.commit(tmp_path, records)
    text = (tmp_path / "records.csv").read_text(encoding="utf-8")
    assert "last_batch_seq=3" in text.rstrip("\n").split("\n")[-1]


def test_valid_state_loads_without_any_warning(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    state.commit(tmp_path, [_state_record()])
    with caplog.at_level(logging.WARNING, logger="report_export.state"):
        state.load(tmp_path)
    assert caplog.records == []


# --------------------------------------------------------------------
# Case 3: tail MISSING -> WARN, non-fatal, backfilled on next write
# --------------------------------------------------------------------


def test_missing_tail_warns_but_loads_successfully(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    state.commit(tmp_path, [_state_record(request_id="a")])
    _strip_meta_tail(tmp_path / "records.csv")

    with caplog.at_level(logging.WARNING, logger="report_export.state"):
        result = state.load(tmp_path)

    assert len(result.existing) == 1
    assert result.existing[0].request_id == "a"
    assert any("#META" in record.message for record in caplog.records)


def test_missing_tail_is_backfilled_by_next_commit(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record(request_id="a")])
    _strip_meta_tail(tmp_path / "records.csv")
    result = state.load(tmp_path)

    state.commit(tmp_path, result.existing)
    text = (tmp_path / "records.csv").read_text(encoding="utf-8")
    assert text.rstrip("\n").split("\n")[-1].startswith("#META")


def _strip_meta_tail(records_path: Path) -> None:
    text = records_path.read_text(encoding="utf-8")
    lines = text.rstrip("\n").split("\n")
    assert lines[-1].startswith("#META")
    records_path.write_text("\n".join(lines[:-1]) + "\n", encoding="utf-8")


# --------------------------------------------------------------------
# Case 4/5: tail mismatch / unparsable -> .bak recovery or exit 3
# --------------------------------------------------------------------


def test_corrupted_sha256_with_no_backup_raises_state_integrity_error(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    _corrupt_sha256(tmp_path / "records.csv")

    with pytest.raises(StateIntegrityError):
        state.load(tmp_path)


def test_corrupted_records_csv_recovers_from_valid_backup(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    state.commit(tmp_path, [_state_record(request_id="first-batch")])
    second_batch = [
        _state_record(request_id="first-batch"),
        _state_record(batch_id=2, request_id="second-batch"),
    ]
    state.commit(tmp_path, second_batch)
    # records.csv now holds both; records.csv.bak holds only the first
    # commit. Corrupt the CURRENT records.csv -> must recover .bak.
    _corrupt_sha256(tmp_path / "records.csv")

    with caplog.at_level(logging.WARNING, logger="report_export.state"):
        result = state.load(tmp_path)

    assert [r.request_id for r in result.existing] == ["first-batch"]
    assert any(".bak" in record.message for record in caplog.records)


def test_unparsable_body_with_no_backup_raises_state_integrity_error(tmp_path: Path) -> None:
    state_dir = tmp_path
    state_dir.mkdir(exist_ok=True)
    (state_dir / "records.csv").write_text("not,even,close,to,valid,csv,header\n", encoding="utf-8")

    with pytest.raises(StateIntegrityError):
        state.load(state_dir)


def test_ragged_row_with_no_backup_raises_state_integrity_error(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    records_path = tmp_path / "records.csv"
    text = records_path.read_text(encoding="utf-8")
    lines = text.split("\n")
    lines[1] = "1,only,three,fields"  # corrupt the one data row
    records_path.write_text("\n".join(lines), encoding="utf-8")

    with pytest.raises(StateIntegrityError):
        state.load(tmp_path)


def test_both_primary_and_backup_corrupted_raises_state_integrity_error(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record(request_id="a")])
    second_batch = [_state_record(request_id="a"), _state_record(batch_id=2, request_id="b")]
    state.commit(tmp_path, second_batch)
    _corrupt_sha256(tmp_path / "records.csv")
    _corrupt_sha256(tmp_path / "records.csv.bak")

    with pytest.raises(StateIntegrityError):
        state.load(tmp_path)


def test_state_integrity_error_message_names_state_dir(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    _corrupt_sha256(tmp_path / "records.csv")

    with pytest.raises(StateIntegrityError, match=re.escape(str(tmp_path))):
        state.load(tmp_path)


def _corrupt_sha256(records_path: Path) -> None:
    text = records_path.read_text(encoding="utf-8")
    corrupted = re.sub(r"sha256=[0-9a-f]+", "sha256=deadbeef", text)
    assert corrupted != text
    records_path.write_text(corrupted, encoding="utf-8")


# --------------------------------------------------------------------
# Atomic write: tmp -> fsync -> .bak -> os.replace (design.md §6.6)
# --------------------------------------------------------------------


def test_first_commit_creates_no_backup(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    assert not (tmp_path / "records.csv.bak").exists()


def test_second_commit_creates_backup_of_first(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record(request_id="a")])
    first_content = (tmp_path / "records.csv").read_text(encoding="utf-8")

    second_batch = [_state_record(request_id="a"), _state_record(batch_id=2, request_id="b")]
    state.commit(tmp_path, second_batch)

    backup_content = (tmp_path / "records.csv.bak").read_text(encoding="utf-8")
    assert backup_content == first_content


def test_commit_leaves_no_stray_tmp_file(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    assert not list(tmp_path.glob("*.tmp"))


def test_records_csv_gets_0600_permissions(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    mode = (tmp_path / "records.csv").stat().st_mode & 0o777
    assert oct(mode) == "0o600"


def test_state_dir_gets_0700_permissions(tmp_path: Path) -> None:
    state_dir = tmp_path / "fresh_state"
    state.commit(state_dir, [_state_record()])
    assert oct(state_dir.stat().st_mode & 0o777) == "0o700"


def test_backup_file_gets_0600_permissions(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record(request_id="a")])
    second_batch = [_state_record(request_id="a"), _state_record(batch_id=2, request_id="b")]
    state.commit(tmp_path, second_batch)
    mode = (tmp_path / "records.csv.bak").stat().st_mode & 0o777
    assert oct(mode) == "0o600"


def test_commit_creates_state_dir_if_missing(tmp_path: Path) -> None:
    state_dir = tmp_path / "brand" / "new"
    state.commit(state_dir, [_state_record()])
    assert (state_dir / "records.csv").exists()


# --------------------------------------------------------------------
# Startup *.tmp cleanup (design.md §5 S0, §13-13)
# --------------------------------------------------------------------


def test_cleanup_tmp_files_removes_stray_tmp_files(tmp_path: Path) -> None:
    tmp_path.mkdir(exist_ok=True)
    (tmp_path / "records.csv.tmp").write_text("leftover", encoding="utf-8")
    (tmp_path / "other.tmp").write_text("leftover", encoding="utf-8")
    (tmp_path / "records.csv").write_text("keep-me", encoding="utf-8")

    removed = state.cleanup_tmp_files(tmp_path)

    assert removed == 2
    assert not (tmp_path / "records.csv.tmp").exists()
    assert not (tmp_path / "other.tmp").exists()
    assert (tmp_path / "records.csv").exists()


def test_cleanup_tmp_files_on_nonexistent_dir_returns_zero(tmp_path: Path) -> None:
    assert state.cleanup_tmp_files(tmp_path / "does-not-exist") == 0


def test_cleanup_tmp_files_on_dir_with_no_tmp_files_returns_zero(tmp_path: Path) -> None:
    tmp_path.mkdir(exist_ok=True)
    (tmp_path / "records.csv").write_text("data", encoding="utf-8")
    assert state.cleanup_tmp_files(tmp_path) == 0


# --------------------------------------------------------------------
# runs.jsonl audit trail (design.md §6.7)
# --------------------------------------------------------------------


def test_append_run_writes_one_json_line(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"run_utc": "2026-07-15T00:00:00Z", "batch_seq": 1})
    lines = (tmp_path / "runs.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0]) == {"run_utc": "2026-07-15T00:00:00Z", "batch_seq": 1}


def test_append_run_appends_without_truncating(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"batch_seq": 1})
    state.append_run(tmp_path, {"batch_seq": 2})
    lines = (tmp_path / "runs.jsonl").read_text(encoding="utf-8").splitlines()
    assert [json.loads(line)["batch_seq"] for line in lines] == [1, 2]


def test_append_run_creates_state_dir_if_missing(tmp_path: Path) -> None:
    state_dir = tmp_path / "brand" / "new"
    state.append_run(state_dir, {"batch_seq": 1})
    assert (state_dir / "runs.jsonl").exists()


def test_runs_jsonl_gets_0600_permissions(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"batch_seq": 1})
    mode = (tmp_path / "runs.jsonl").stat().st_mode & 0o777
    assert oct(mode) == "0o600"


def test_append_run_preserves_non_ascii_content(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"deliverable_name": "2026-07-15_連線紀錄.xlsx"})
    line = (tmp_path / "runs.jsonl").read_text(encoding="utf-8").splitlines()[0]
    assert json.loads(line)["deliverable_name"] == "2026-07-15_連線紀錄.xlsx"


# --------------------------------------------------------------------
# Malformed BATCH_ID in a data row (design.md §6.4 case 5: unparsable)
# --------------------------------------------------------------------


def test_non_integer_batch_id_with_no_backup_raises_state_integrity_error(tmp_path: Path) -> None:
    state.commit(tmp_path, [_state_record()])
    records_path = tmp_path / "records.csv"
    text = records_path.read_text(encoding="utf-8")
    lines = text.split("\n")
    # Corrupt the BATCH_ID column (index 0) of the one data row.
    fields = lines[1].split(",")
    fields[0] = "not-a-number"
    lines[1] = ",".join(fields)
    records_path.write_text("\n".join(lines), encoding="utf-8")

    with pytest.raises(StateIntegrityError):
        state.load(tmp_path)


# --------------------------------------------------------------------
# read_runs_for_date() -- same-day disambiguation support (design.md
# §6.7, §8.2)
# --------------------------------------------------------------------


def test_read_runs_for_date_on_missing_runs_jsonl_returns_empty(tmp_path: Path) -> None:
    assert state.read_runs_for_date(tmp_path, date(2026, 7, 15)) == []


def test_read_runs_for_date_filters_by_run_date(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": 1})
    state.append_run(tmp_path, {"run_date": "2026-07-16", "batch_seq": 2})
    state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": 3})

    matches = state.read_runs_for_date(tmp_path, date(2026, 7, 15))

    assert [record["batch_seq"] for record in matches] == [1, 3]


def test_read_runs_for_date_preserves_append_order(tmp_path: Path) -> None:
    for seq in range(1, 4):
        state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": seq})

    matches = state.read_runs_for_date(tmp_path, date(2026, 7, 15))

    assert [record["batch_seq"] for record in matches] == [1, 2, 3]


def test_read_runs_for_date_no_matches_returns_empty(tmp_path: Path) -> None:
    state.append_run(tmp_path, {"run_date": "2026-07-16", "batch_seq": 1})
    assert state.read_runs_for_date(tmp_path, date(2026, 7, 15)) == []


def test_read_runs_for_date_skips_unparsable_line_with_warning(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": 1})
    runs_path = tmp_path / "runs.jsonl"
    with runs_path.open("a", encoding="utf-8") as fh:
        fh.write("not valid json at all\n")
    state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": 2})

    with caplog.at_level(logging.WARNING, logger="report_export.state"):
        matches = state.read_runs_for_date(tmp_path, date(2026, 7, 15))

    assert [record["batch_seq"] for record in matches] == [1, 2]
    assert any("unparsable" in record.message for record in caplog.records)


def test_read_runs_for_date_skips_blank_lines(tmp_path: Path) -> None:
    runs_path = tmp_path / "runs.jsonl"
    runs_path.parent.mkdir(parents=True, exist_ok=True)
    runs_path.write_text('\n{"run_date": "2026-07-15", "batch_seq": 1}\n\n', encoding="utf-8")

    matches = state.read_runs_for_date(tmp_path, date(2026, 7, 15))

    assert [record["batch_seq"] for record in matches] == [1]


def test_read_runs_for_date_wraps_unexpected_read_failure_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state.append_run(tmp_path, {"run_date": "2026-07-15", "batch_seq": 1})

    def _raise_eio(self: Path, *args: object, **kwargs: object) -> str:
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(Path, "read_text", _raise_eio)
    with pytest.raises(WriteError, match=r"cannot read runs\.jsonl"):
        state.read_runs_for_date(tmp_path, date(2026, 7, 15))


# --------------------------------------------------------------------
# Unexpected IO failures surface as WriteError, never a raw OSError
# (design.md: fail-fast with typed exceptions at every boundary)
# --------------------------------------------------------------------


def test_commit_wraps_unexpected_os_replace_failure_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _raise_eio(src: object, dst: object) -> None:
        raise OSError(5, "Input/output error")  # errno.EIO

    monkeypatch.setattr(os, "replace", _raise_eio)
    with pytest.raises(WriteError, match="cannot commit state"):
        state.commit(tmp_path, [_state_record()])


def test_append_run_wraps_unexpected_fsync_failure_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _raise_eio(fd: int) -> None:
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(os, "fsync", _raise_eio)
    with pytest.raises(WriteError, match=r"cannot append to runs\.jsonl"):
        state.append_run(tmp_path, {"batch_seq": 1})


def test_ensure_dir_wraps_unexpected_mkdir_failure_as_write_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _raise_eio(
        self: Path, *, mode: int = 0o777, parents: bool = False, exist_ok: bool = False
    ) -> None:
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(Path, "mkdir", _raise_eio)
    with pytest.raises(WriteError, match="cannot prepare state_dir"):
        state.commit(tmp_path / "unwritable", [_state_record()])
