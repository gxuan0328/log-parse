"""Wire S0-S10 into one pipeline run, returning a `RunSummary`
(design.md §3.2 pipeline, §5, §12.1).

The sole effectful orchestrator: every stage function it calls is
either a pure transform (`transform`/`aggregate`) or a narrowly-scoped
I/O boundary module (`csv_reader`/`lookup`/`state`/`statelock`/
`xlsx_writer`). `run()` accepts internal `run_date`/`reference_path`
parameters purely as test seams (design.md §3.4, §11.1) -- the CLI
itself never exposes a `--run-date` (or `--reference`) flag; production
callers always take the defaults (today's date under the container's
TZ=Asia/Taipei, and the reference table bundled next to the installed
package, design.md §5 S0-S1, §9.2, §10.2).
"""

from __future__ import annotations

import hashlib
import logging
import os
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Final

from report_export import (
    aggregate,
    csv_reader,
    dedup,
    lookup,
    state,
    statelock,
    transform,
    xlsx_writer,
)
from report_export.config import Config
from report_export.errors import InputValidationError, WriteError
from report_export.models import StateRecord

__all__ = ["RunSummary", "run"]

logger = logging.getLogger(__name__)

#: design.md §9.2/§10.2: the bundled reference table lives one
#: directory above the installed package -- `report-export/reference/`
#: on a host editable install (this file resolves to
#: `.../report-export/src/report_export/pipeline.py`), or
#: `/app/reference/` inside the Docker image (which `COPY`s `src/` and
#: `reference/` as siblings under `/app`, design.md §10.2). Computed
#: relative to this module's own file so no CLI flag or environment
#: variable is needed (design.md §11 lean CLI, YAGNI).
_PACKAGE_ROOT: Final[Path] = Path(__file__).resolve().parent.parent.parent
_DEFAULT_REFERENCE_PATH: Final[Path] = _PACKAGE_ROOT / "reference" / "hosp_id_map.csv.gz"

_READ_CHUNK_SIZE: Final[int] = 1 << 16  # 64 KiB
_RUN_UTC_FMT: Final[str] = "%Y-%m-%dT%H:%M:%SZ"
_RUN_DATE_FMT: Final[str] = "%Y-%m-%d"


@dataclass(frozen=True, slots=True)
class RunSummary:
    """The pipeline's single stdout-JSON-serializable result (design.md §11.2).

    Field names are exactly the §11.2 stdout JSON keys -- `cli.py`
    serializes this via `dataclasses.asdict()` with no renaming.
    """

    deliverable: str
    run_date: str
    batch_seq: int
    input: str
    input_sha256: str
    rows_in: int
    normal: int
    dropped_nonnormal: int
    new_records: int
    skipped_cross_state: int
    skipped_intra_batch: int
    unknown_status_skipped: int
    state_total: int
    unique_ips: int
    unmapped_hosp_ids: int


def run(
    config: Config, *, run_date: date | None = None, reference_path: Path | None = None
) -> RunSummary:
    """Execute one full ingest+report run (design.md §5 S0-S9).

    `run_date` defaults to `date.today()` (the container's
    TZ=Asia/Taipei "today", design.md §5 S0) and `reference_path`
    defaults to the bundled `hosp_id_map.csv.gz` -- both parameters
    exist purely as test seams, never exposed as CLI flags (design.md
    §11.1).

    Raises:
        InputValidationError, ReferenceError, StateIntegrityError,
        LockBusyError, WriteError: propagated unmodified from whichever
        stage boundary raised them -- `cli.py` is the sole catcher
        (design.md §11.4).
    """
    resolved_run_date = run_date if run_date is not None else date.today()
    resolved_reference_path = (
        reference_path if reference_path is not None else _DEFAULT_REFERENCE_PATH
    )

    with statelock.acquire(config.state_dir):
        state.cleanup_tmp_files(config.state_dir)
        return _run_locked(
            config, run_date=resolved_run_date, reference_path=resolved_reference_path
        )


def _run_locked(config: Config, *, run_date: date, reference_path: Path) -> RunSummary:
    run_utc = datetime.now(UTC)
    input_sha256 = _sha256_file(config.input_path)

    hosp_table = lookup.load(reference_path)  # S1
    load_result = state.load(config.state_dir)  # S2

    numbered_rows, unknown_status_skipped = csv_reader.read(config.input_path)  # S3
    rows_in = len(numbered_rows) + unknown_status_skipped

    normal_rows = transform.filter_normal(numbered_rows)  # S4
    transformed = transform.project(normal_rows, hosp_table)  # S5
    unmapped_hosp_ids = sum(1 for record in transformed if not record.hosp_abbr)
    if unmapped_hosp_ids:
        logger.warning(
            "batch contains rows with an unmapped HOSP_ID (HOSP_ABBR resolved to empty)",
            extra={"unmapped_hosp_ids": unmapped_hosp_ids},
        )

    line_numbers = [line_no for line_no, _row in normal_rows]
    numbered_transformed = list(zip(line_numbers, transformed, strict=True))
    new_records, skipped_intra, skipped_cross = dedup.apply(  # S6
        numbered_transformed, load_result.existing_request_ids
    )

    # S7
    new_state_records = state.assign_batch(new_records, max_batch_seq=load_result.max_batch_seq)
    full_state = load_result.existing + new_state_records
    report_rows = aggregate.build(full_state)

    # design.md §6.5: the deliverable's yellow highlight always falls on
    # `max(batch_id in full_state)` -- `batch_seq` in the summary/audit
    # trail mirrors that SAME quantity, so it always names whichever
    # batch is actually current in (and highlighted in) this run's
    # output. On a 0-new idempotent rerun this is deliberately the
    # EXISTING latest batch, never a "next" batch number that no record
    # ever ends up carrying (`new_state_records` may be empty).
    batch_seq = max((record.batch_id for record in full_state), default=0)

    today_runs = state.read_runs_for_date(config.state_dir, run_date)
    tmp_path, final_path = xlsx_writer.write(  # S8
        config.out_dir,
        full_state,
        report_rows,
        run_date=run_date,
        today_runs=today_runs,
        input_sha256=input_sha256,
    )

    if new_state_records:  # S9.1 -- 0-new is a no-op, idempotent (design.md §5 S9)
        state.commit(config.state_dir, full_state)
    _replace_deliverable(tmp_path, final_path)  # S9.2

    summary = RunSummary(
        deliverable=str(final_path),
        run_date=run_date.strftime(_RUN_DATE_FMT),
        batch_seq=batch_seq,
        input=str(config.input_path),
        input_sha256=input_sha256,
        rows_in=rows_in,
        normal=len(normal_rows),
        dropped_nonnormal=len(numbered_rows) - len(normal_rows),
        new_records=len(new_state_records),
        skipped_cross_state=skipped_cross,
        skipped_intra_batch=skipped_intra,
        unknown_status_skipped=unknown_status_skipped,
        state_total=len(full_state),
        unique_ips=len(report_rows),
        unmapped_hosp_ids=unmapped_hosp_ids,
    )

    state.append_run(  # S9.3
        config.state_dir,
        _build_run_record(
            run_utc=run_utc, run_date=run_date, summary=summary, new_state_records=new_state_records
        ),
    )

    logger.info(
        "run complete",
        extra={"deliverable": summary.deliverable, "new_records": summary.new_records},
    )
    return summary


def _build_run_record(
    *,
    run_utc: datetime,
    run_date: date,
    summary: RunSummary,
    new_state_records: list[StateRecord],
) -> dict[str, object]:
    """Build one `runs.jsonl` audit record (design.md §6.7).

    Field names here are the §6.7 audit-trail schema, deliberately
    distinct from `RunSummary`'s §11.2 stdout-JSON field names (e.g.
    `skipped_cross` here vs `skipped_cross_state` there) -- each
    section of design.md defines its own field names and both are
    reproduced exactly as specified.
    """
    return {
        "run_utc": run_utc.strftime(_RUN_UTC_FMT),
        "run_date": run_date.strftime(_RUN_DATE_FMT),
        "input_path": summary.input,
        "input_sha256": summary.input_sha256,
        "rows_in": summary.rows_in,
        "normal": summary.normal,
        "dropped_nonnormal": summary.dropped_nonnormal,
        "skipped_cross": summary.skipped_cross_state,
        "skipped_intra": summary.skipped_intra_batch,
        "appended": summary.new_records,
        "batch_seq": summary.batch_seq,
        "deliverable_name": Path(summary.deliverable).name,
        "appended_request_ids": [record.request_id for record in new_state_records],
        "state_total": summary.state_total,
        "unique_ips": summary.unique_ips,
        "unmapped_hosp_ids": summary.unmapped_hosp_ids,
    }


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(_READ_CHUNK_SIZE), b""):
                digest.update(chunk)
    except OSError as exc:
        raise InputValidationError(f"cannot read input CSV for hashing: {path} ({exc})") from exc
    return digest.hexdigest()


def _replace_deliverable(tmp_path: Path, final_path: Path) -> None:
    try:
        os.replace(tmp_path, final_path)
    except OSError as exc:
        raise WriteError(f"cannot finalize deliverable: {final_path} ({exc})") from exc
