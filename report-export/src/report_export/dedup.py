"""REQUEST_ID dedup: cross-state + intra-batch, warn-skip (design.md
§2.3 dedup, §3.4, §7.1).

A duplicate REQUEST_ID is an EXPECTED outcome of re-running the same
weekly input (idempotent re-ingest, design.md §4.1) or of two
overlapping batches -- never a fail-fast condition. Every duplicate is
WARN-logged (REQUEST_ID + source line number) and skipped; the process
exit code stays 0 (design.md §3.4.3: warn-skip is the only strategy,
baked in, no `--on-duplicate` flag).
"""

from __future__ import annotations

import logging

from report_export.models import TransformedRecord

__all__ = ["apply"]

logger = logging.getLogger(__name__)


def apply(
    rows: list[tuple[int, TransformedRecord]], existing_request_ids: set[str]
) -> tuple[list[TransformedRecord], int, int]:
    """Drop rows whose REQUEST_ID already exists in state or earlier in
    this same batch (design.md §3.4.2).

    `existing_request_ids` is read-only here: this function only
    queries it, never mutates it -- state.py owns the authoritative
    set. A `request_id` already seen earlier IN THIS BATCH is checked
    first: once any occurrence of a given REQUEST_ID has been
    processed (whether it became a new record or was itself skipped as
    a cross-state duplicate), every later occurrence of that same ID
    within the batch counts as an intra-batch duplicate -- this avoids
    re-emitting the same "already in state" WARN for every repeat of
    one duplicated ID within a single file.

    Returns `(new_records, skipped_intra, skipped_cross)`: `new_records`
    preserves input order and holds only rows whose REQUEST_ID was
    genuinely new (neither in `existing_request_ids` nor seen earlier
    in `rows`).
    """
    new_records: list[TransformedRecord] = []
    seen_in_batch: set[str] = set()
    skipped_intra = 0
    skipped_cross = 0

    for line_no, record in rows:
        request_id = record.request_id
        if request_id in seen_in_batch:
            logger.warning(
                "duplicate REQUEST_ID within this batch, skipping",
                extra={"request_id": request_id, "line_no": line_no},
            )
            skipped_intra += 1
            continue
        seen_in_batch.add(request_id)
        if request_id in existing_request_ids:
            logger.warning(
                "duplicate REQUEST_ID already present in state, skipping",
                extra={"request_id": request_id, "line_no": line_no},
            )
            skipped_cross += 1
            continue
        new_records.append(record)

    return new_records, skipped_intra, skipped_cross
