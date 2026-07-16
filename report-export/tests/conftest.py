"""Shared pytest fixtures for report_export tests."""

from __future__ import annotations

import logging
from collections.abc import Iterator
from pathlib import Path
from typing import Final

import pytest

#: report-export/reference/hosp_id_map.csv.gz -- the real, checked-in
#: export (tools/export_hosp_table.py output), used by test_lookup.py
#: for anchor assertions against design.md §1.5.2/§1.5.8.
REFERENCE_DIR: Final[Path] = Path(__file__).resolve().parents[1] / "reference"


@pytest.fixture(autouse=True)
def _isolate_report_export_logger() -> Iterator[None]:
    """Snapshot + restore the shared `report_export` logger around every test.

    `logging.getLogger(name)` returns the same process-wide singleton
    for a given name, so any test that calls `configure_logging()`
    (see logging_setup.py) mutates global state (handlers, level,
    propagate) that would otherwise leak into unrelated tests -- e.g.
    breaking `caplog`-based assertions on `report_export.*` child
    loggers by disabling propagation to the root logger.
    """
    logger = logging.getLogger("report_export")
    original_handlers = list(logger.handlers)
    original_level = logger.level
    original_propagate = logger.propagate
    yield
    logger.handlers = original_handlers
    logger.setLevel(original_level)
    logger.propagate = original_propagate
