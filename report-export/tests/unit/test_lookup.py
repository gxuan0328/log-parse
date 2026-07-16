"""Unit tests for report_export.lookup (design.md §7.1 test_lookup, §1.5.2, §1.5.8, §3.3)."""

from __future__ import annotations

import csv
import gzip
import logging
from pathlib import Path

import pytest

from report_export import lookup
from report_export.errors import ReferenceError as ReportExportReferenceError

# report-export/reference/hosp_id_map.csv.gz -- computed locally
# (rather than imported from tests/conftest.py) so this file has no
# cross-test-module import dependency under pytest's default
# `--import-mode=prepend` (no `tests/__init__.py` is used, by design).
REFERENCE_DIR = Path(__file__).resolve().parents[2] / "reference"
HOSP_ID_MAP_PATH = REFERENCE_DIR / "hosp_id_map.csv.gz"


def _write_gz_csv(path: Path, rows: list[tuple[str, ...]]) -> None:
    with gzip.open(path, mode="wt", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerows(rows)


@pytest.fixture(scope="module")
def hosp_table() -> dict[str, str]:
    return lookup.load(HOSP_ID_MAP_PATH)


# --------------------------------------------------------------------
# Real reference/hosp_id_map.csv.gz -- anchors from design.md §1.5.2 / §1.5.8
# --------------------------------------------------------------------


def test_load_returns_expected_row_count(hosp_table: dict[str, str]) -> None:
    assert len(hosp_table) == 93781


def test_known_hosp_id_maps_to_expected_abbr(hosp_table: dict[str, str]) -> None:
    # design.md §1.5.2 row 9 / §1.5.8 anchor.
    assert hosp_table["0937010019"] == "秀傳醫院"


def test_second_known_hosp_id_maps_to_expected_abbr(hosp_table: dict[str, str]) -> None:
    # design.md §1.5.2 row 7 anchor.
    assert hosp_table["3501200000"] == "臺北虛擬診"


def test_leading_zero_key_preserved_as_string(hosp_table: dict[str, str]) -> None:
    assert "0937010019" in hosp_table
    assert "937010019" not in hosp_table  # would indicate leading-zero loss


def test_all_keys_are_str_type() -> None:
    table = lookup.load(HOSP_ID_MAP_PATH)
    sample_key = next(iter(table))
    assert isinstance(sample_key, str)
    assert isinstance(table[sample_key], str)


# --------------------------------------------------------------------
# get() -- IFERROR / XLOOKUP-not-found semantics (design.md §3.3)
# --------------------------------------------------------------------


def test_get_returns_mapped_value(hosp_table: dict[str, str]) -> None:
    assert lookup.get(hosp_table, "0937010019") == "秀傳醫院"


def test_get_unmapped_hosp_id_returns_empty_string(hosp_table: dict[str, str]) -> None:
    # Deliberately NOT an all-zero/all-nine numeric string: the real
    # master table uses several such all-digit values as its own
    # "unknown hospital" placeholder sentinels (e.g. "0000000000" and
    # "9999999999" are both present, mapped to an "unknown" label, in
    # the live reference export), so they are not safe stand-ins for
    # "truly unmapped".
    assert lookup.get(hosp_table, "NOT-A-REAL-HOSP-ID") == ""


def test_get_does_not_raise_on_unmapped_key(hosp_table: dict[str, str]) -> None:
    # IFERROR semantics: never raises, always falls back to "".
    result = lookup.get(hosp_table, "not-a-real-hosp-id")
    assert result == ""


# --------------------------------------------------------------------
# load() -- gz loading mechanics + fail-fast boundaries
# --------------------------------------------------------------------


def test_load_missing_file_raises_reference_error(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist.csv.gz"
    with pytest.raises(ReportExportReferenceError, match="not found"):
        lookup.load(missing)


def test_load_corrupt_gzip_raises_reference_error(tmp_path: Path) -> None:
    # A file that exists (passes is_file()) but is not valid gzip must
    # surface as our typed ReferenceError, never a raw gzip.BadGzipFile.
    corrupt = tmp_path / "corrupt.csv.gz"
    corrupt.write_bytes(b"not actually gzip data at all")
    with pytest.raises(ReportExportReferenceError, match="unreadable"):
        lookup.load(corrupt)


def test_load_bad_header_raises_reference_error(tmp_path: Path) -> None:
    bad = tmp_path / "bad_header.csv.gz"
    _write_gz_csv(bad, [("WRONG", "HEADER"), ("1", "x")])
    with pytest.raises(ReportExportReferenceError, match="header"):
        lookup.load(bad)


def test_load_empty_file_raises_reference_error(tmp_path: Path) -> None:
    empty = tmp_path / "empty.csv.gz"
    with gzip.open(empty, mode="wt", encoding="utf-8"):
        pass
    with pytest.raises(ReportExportReferenceError, match="header"):
        lookup.load(empty)


def test_load_ragged_row_raises_reference_error(tmp_path: Path) -> None:
    bad = tmp_path / "ragged.csv.gz"
    _write_gz_csv(bad, [("HOSP_ID", "HOSP_ABBR"), ("1", "x", "extra")])
    with pytest.raises(ReportExportReferenceError, match="row 2"):
        lookup.load(bad)


def test_load_small_valid_table_round_trips(tmp_path: Path) -> None:
    small = tmp_path / "small.csv.gz"
    _write_gz_csv(
        small,
        [("HOSP_ID", "HOSP_ABBR"), ("0937010019", "秀傳醫院"), ("1234567890", "")],
    )
    table = lookup.load(small)
    assert table == {"0937010019": "秀傳醫院", "1234567890": ""}


def test_load_rejects_directory_path(tmp_path: Path) -> None:
    with pytest.raises(ReportExportReferenceError, match="not found"):
        lookup.load(tmp_path)


# --------------------------------------------------------------------
# Sanity-check warnings -- WARN-only, tolerate master data evolution
# (design.md §3.8 S1, §8 R2)
# --------------------------------------------------------------------


def test_duplicate_keys_warn_but_do_not_raise(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    dup = tmp_path / "dup.csv.gz"
    _write_gz_csv(
        dup,
        [("HOSP_ID", "HOSP_ABBR"), ("0000000001", "A"), ("0000000001", "B")],
    )
    with caplog.at_level(logging.WARNING, logger="report_export.lookup"):
        table = lookup.load(dup)
    assert table["0000000001"] == "B"  # last write wins; loading never raises
    assert any("duplicate" in record.message for record in caplog.records)


def test_non_standard_key_length_warns(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    short_key = tmp_path / "short_key.csv.gz"
    _write_gz_csv(
        short_key,
        [("HOSP_ID", "HOSP_ABBR"), *[(f"{i:010d}", "x") for i in range(1200)], ("123", "y")],
    )
    with caplog.at_level(logging.WARNING, logger="report_export.lookup"):
        lookup.load(short_key)
    assert any("non-standard length" in record.message for record in caplog.records)


def test_small_row_count_warns(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    small = tmp_path / "tiny.csv.gz"
    _write_gz_csv(small, [("HOSP_ID", "HOSP_ABBR"), ("0937010019", "秀傳醫院")])
    with caplog.at_level(logging.WARNING, logger="report_export.lookup"):
        lookup.load(small)
    assert any("row count" in record.message for record in caplog.records)
