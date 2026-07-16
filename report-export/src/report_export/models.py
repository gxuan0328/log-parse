"""Typed data model shapes for the report_export pipeline
(design.md §2.3 models, §3.1.1-§3.1.3, §3.5.2).

Four value objects flow through the pipeline, in this order:

    InputRow          14 cols, as read from CSV, every field `str`
      |  (transform.filter_normal + transform.project, later phase)
      v
    TransformedRecord  9 cols: REQUEST_ID + 8 payload; APP_TIME validated,
      |                HOSP_ABBR resolved -- everything StateRecord holds
      |                except BATCH_ID (design.md §3.8 S5)
      |  (dedup.apply + state.assign_batch, later phase)
      v
    StateRecord        10 cols: 2 internal keys + 8 payload; persisted to
      |                records.csv
      |  (aggregate; later phase)
      v
    ReportRow          5 cols; one row per unique CLIENT IP (院所分析)

Plus `Status`, the enum of canonical STATUS values (design.md §3.1.1 col B).

Deliberately NOT using `from __future__ import annotations` here: these
dataclasses are introspected by field *type* at runtime (tests assert
`dataclasses.fields(...)[i].type is str`), which requires real type
objects rather than the postponed-evaluation string form.
"""

from dataclasses import dataclass
from enum import StrEnum

__all__ = ["InputRow", "ReportRow", "StateRecord", "Status", "TransformedRecord"]


class Status(StrEnum):
    """Canonical STATUS enum values (design.md §3.1.1 col B).

    Matching a raw CSV value against this enum is case-insensitive per
    Excel `=` semantics (design.md §3.8 S4, §7.1): callers must
    `.strip().upper()` the raw field before constructing, e.g.
    `Status(raw_status.strip().upper())`.
    """

    NORMAL = "NORMAL"
    ORPHAN = "ORPHAN"
    UNVERIFIED = "UNVERIFIED"


@dataclass(frozen=True, slots=True)
class InputRow:
    """One raw input CSV row: the 14 columns of the analyze_access
    `--format csv` contract (design.md §3.1.1), in column order A-N.

    Every field is `str` -- the whole CSV is read as text (design.md
    §3.1.1: the full 14-column contract is read as plain strings),
    deferring all interpretation (STATUS enum matching, APP_TIME
    parsing, dash-sentinel normalisation) to later pipeline stages
    (csv_reader/transform, later phases).
    """

    region: str
    status: str
    api_time: str
    app_time: str
    delta_sec: str
    verify_status: str
    request_id: str
    api_server: str
    app_server: str
    hosp_id: str
    prsn_id: str
    client_ip: str
    patient_id_aes: str
    birthday: str


@dataclass(frozen=True, slots=True)
class TransformedRecord:
    """One NORMAL row after `transform.project()` (design.md §3.8 S5):
    APP_TIME validated (parseable under the ms/no-ms contract),
    HOSP_ABBR resolved via the reference lookup table (IFERROR
    semantics -- frozen in now so later master-table updates never
    retroactively change historical rows).

    Identical to `StateRecord` minus `batch_id`: dedup.apply() and
    state.assign_batch() are the only two stages between this shape
    and a fully-formed `StateRecord` (design.md §3.8 S6-S7). BATCH_ID is
    deliberately absent here rather than carrying a placeholder value
    -- a row is only entitled to a BATCH_ID after it has survived
    dedup (design.md §3.8 S6 runs before S7), so this type makes
    "not yet batch-assigned" unrepresentable as anything other than
    "the field does not exist yet".
    """

    request_id: str
    app_time_iso: str
    client_ip: str
    server_ip: str
    hosp_id: str
    hosp_abbr: str
    prsn_id: str
    birthday: str
    patient_id_aes: str


@dataclass(frozen=True, slots=True)
class StateRecord:
    """One durable `records.csv` row: 2 internal keys + 8 payload
    columns, in exact schema order (design.md §3.5.2):

        BATCH_ID, REQUEST_ID, APP_TIME_ISO, CLIENT_IP, SERVER_IP,
        HOSP_ID, HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT_ID_AES

    `batch_id`/`request_id` never appear in the 調閱紀錄 deliverable
    projection -- they are the persistence layer's internal
    dedup/highlight keys (design.md §3.5.2, §3.4.1).
    """

    batch_id: int
    request_id: str
    app_time_iso: str
    client_ip: str
    server_ip: str
    hosp_id: str
    hosp_abbr: str
    prsn_id: str
    birthday: str
    patient_id_aes: str


@dataclass(frozen=True, slots=True)
class ReportRow:
    """One 院所分析 aggregate row (design.md §3.1.3): a unique CLIENT IP,
    the first-seen HOSP_ID/HOSP_ABBR for that IP (XLOOKUP first-match
    semantics against the state itself), and two row counts across the
    full state (design.md §3.1.3 REQ3):

        weekly_access  this IP's row count within the LATEST batch
                        only (`batch_id == max(BATCH_ID)`); 0 means the
                        IP has no rows in this run's latest batch (it
                        only appears in older batches) -- the
                        xlsx_writer layer renders that case as the
                        string "-", but the model itself stays a plain
                        `int` (0 = none), kept numeric and testable.
        total_access    this IP's row count across the ENTIRE state
                        (the pre-REQ3 single COUNT column).

    A single-batch state (e.g. a first-ever ingest) has
    `weekly_access == total_access` for every row, since every row
    belongs to the one and only (and therefore latest) batch.
    """

    client_ip: str
    hosp_id: str
    hosp_abbr: str
    weekly_access: int
    total_access: int
