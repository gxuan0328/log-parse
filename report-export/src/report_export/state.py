"""canonical `records.csv` state: crash-tolerant load, atomic commit,
in-file `#META` integrity tail, `.bak` recovery, `runs.jsonl` audit
trail, BATCH_ID assignment (design.md §2.3 state, §3.5, §7.1).

`records.csv` is the single source of truth. It is UTF-8, `\\n`-only
line endings, all-`str` columns (design.md §3.5.1 -- always via `csv`,
never pandas-style dtype inference, so leading zeros never get
numerically coerced), with one machine-owned tail line (`#META`) that
lets a single `os.replace()` cover both the data and its own
completeness/integrity description in one atomic step (design.md §3.5.3
-- this is what makes a fully-committed state provably unbrickable: no
window ever exists where the data is committed but its integrity
descriptor is not, or vice versa).
"""

from __future__ import annotations

import contextlib
import csv
import hashlib
import io
import json
import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Final

from report_export.errors import StateIntegrityError, WriteError
from report_export.models import StateRecord, TransformedRecord

__all__ = [
    "LoadResult",
    "append_run",
    "assign_batch",
    "cleanup_tmp_files",
    "commit",
    "load",
    "read_runs_for_date",
]

logger = logging.getLogger(__name__)

_SCHEMA_VERSION: Final[int] = 1
_HEADER: Final[tuple[str, ...]] = (
    "BATCH_ID",
    "REQUEST_ID",
    "APP_TIME_ISO",
    "CLIENT_IP",
    "SERVER_IP",
    "HOSP_ID",
    "HOSP_ABBR",
    "PRSN_ID",
    "BIRTHDAY",
    "PATIENT_ID_AES",
)

_RECORDS_FILENAME: Final[str] = "records.csv"
_BACKUP_SUFFIX: Final[str] = ".bak"
_RUNS_FILENAME: Final[str] = "runs.jsonl"
_META_PREFIX: Final[str] = "#META"


@dataclass(frozen=True, slots=True)
class LoadResult:
    """`state.load()`'s output (design.md §3.8 S2): the full existing
    state, its REQUEST_ID set (for dedup.apply()), and the highest
    BATCH_ID seen so far (0 for an empty state, design.md §3.5.5).
    """

    existing: list[StateRecord]
    existing_request_ids: set[str]
    max_batch_seq: int


class _TailIntegrityError(Exception):
    """Internal signal only: `records.csv` (or `.bak`) failed to parse
    or failed its `#META` tail-integrity check. `load()` catches this
    to decide between falling back to `.bak` and raising the public
    `StateIntegrityError` -- it never escapes this module.
    """


# --------------------------------------------------------------------
# load() -- crash-tolerant (design.md §3.8 S2, §3.5.4 cases 1-5)
# --------------------------------------------------------------------


def load(state_dir: Path) -> LoadResult:
    """Load `state_dir/records.csv` with crash-tolerant tail-integrity
    recovery (design.md §3.5.4). A fully-committed state is never
    misdiagnosed as corrupt.

    Cases (design.md §3.5.4):
      1. `records.csv` missing -> empty state (`existing=[]`,
         `max_batch_seq=0`) -- the normal first-ever-run path
         (design.md §3.5.5), not an error.
      2. Parses; tail present; `records`/`sha256` match -> normal load.
      3. Parses; tail MISSING -> WARN (non-fatal); the next `commit()`
         backfills a correct tail.
      4. Parses; tail `records`/`sha256` MISMATCH -> try `.bak`; WARN
         and continue if `.bak` validates, else `StateIntegrityError`.
      5. Unparsable / wrong column count -> same `.bak` recovery as
         case 4.

    Raises:
        StateIntegrityError (exit 3): `records.csv` fails validation
            AND `.bak` recovery also fails (or `.bak` is absent).
    """
    records_path = state_dir / _RECORDS_FILENAME
    if not records_path.is_file():
        return LoadResult(existing=[], existing_request_ids=set(), max_batch_seq=0)

    try:
        return _load_validated(records_path)
    except _TailIntegrityError as primary_error:
        logger.warning(
            "records.csv failed tail-integrity check, attempting .bak recovery",
            extra={"path": str(records_path), "reason": str(primary_error)},
        )
        backup_path = state_dir / f"{_RECORDS_FILENAME}{_BACKUP_SUFFIX}"
        try:
            result = _load_validated(backup_path)
        except _TailIntegrityError as backup_error:
            raise StateIntegrityError(
                f"records.csv is corrupt ({primary_error}) and .bak recovery also failed "
                f"({backup_error}): {state_dir}"
            ) from backup_error
        logger.warning("recovered state from records.csv.bak", extra={"path": str(backup_path)})
        return result


def _load_validated(path: Path) -> LoadResult:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise _TailIntegrityError(f"{path}: unreadable ({exc})") from exc

    body, meta = _split_tail(text)
    records = _parse_body(body, source=path)

    if meta is None:
        logger.warning(
            "records.csv is missing its #META integrity tail; proceeding "
            "(non-fatal -- the next commit() backfills a correct tail)",
            extra={"path": str(path)},
        )
    else:
        _verify_meta(meta, body=body, records=records, source=path)

    max_batch_seq = max((record.batch_id for record in records), default=0)
    existing_request_ids = {record.request_id for record in records}
    return LoadResult(
        existing=records, existing_request_ids=existing_request_ids, max_batch_seq=max_batch_seq
    )


def _split_tail(text: str) -> tuple[str, dict[str, str] | None]:
    """Split `text` into `(body, meta)`.

    `body` is exactly the header+data-row text that was hashed at
    write time (design.md §3.5.3); `meta` is the parsed `#META` tail's
    key/value tokens, or `None` if no tail line is present (case 3).
    """
    without_trailing = text[:-1] if text.endswith("\n") else text
    lines = without_trailing.split("\n")
    if lines and lines[-1].startswith(_META_PREFIX):
        body = "".join(f"{line}\n" for line in lines[:-1])
        return body, _parse_meta_line(lines[-1])
    return text, None


def _parse_meta_line(meta_line: str) -> dict[str, str]:
    tokens = meta_line.split("\t")
    if not tokens or tokens[0] != _META_PREFIX:
        # Defensive only: the sole caller (_split_tail) already checked
        # `.startswith(_META_PREFIX)` before invoking this function, so
        # this branch is unreachable through the current call graph --
        # kept as a guard against a future second call site.
        raise _TailIntegrityError(f"malformed #META tail line: {meta_line!r}")  # pragma: no cover
    meta: dict[str, str] = {}
    for token in tokens[1:]:
        key, _, value = token.partition("=")
        meta[key] = value
    return meta


def _verify_meta(
    meta: Mapping[str, str], *, body: str, records: list[StateRecord], source: Path
) -> None:
    expected_sha256 = _compute_sha256(body)
    actual_sha256 = meta.get("sha256")
    actual_records = meta.get("records")
    if actual_sha256 != expected_sha256 or actual_records != str(len(records)):
        raise _TailIntegrityError(
            f"{source}: #META mismatch (records={actual_records!r} vs {len(records)}, "
            f"sha256={actual_sha256!r} vs {expected_sha256!r})"
        )


def _parse_body(body: str, *, source: Path) -> list[StateRecord]:
    reader = csv.reader(io.StringIO(body, newline=""))
    header = next(reader, None)
    if header is None or tuple(header) != _HEADER:
        raise _TailIntegrityError(f"{source}: header mismatch, got {header!r}")

    records: list[StateRecord] = []
    for line_no, row in enumerate(reader, start=2):
        if len(row) != len(_HEADER):
            raise _TailIntegrityError(
                f"{source}: row {line_no} has {len(row)} columns, expected {len(_HEADER)}"
            )
        try:
            batch_id = int(row[0])
        except ValueError as exc:
            raise _TailIntegrityError(
                f"{source}: row {line_no} has non-integer BATCH_ID {row[0]!r}"
            ) from exc
        records.append(
            StateRecord(
                batch_id=batch_id,
                request_id=row[1],
                app_time_iso=row[2],
                client_ip=row[3],
                server_ip=row[4],
                hosp_id=row[5],
                hosp_abbr=row[6],
                prsn_id=row[7],
                birthday=row[8],
                patient_id_aes=row[9],
            )
        )
    return records


# --------------------------------------------------------------------
# commit() -- atomic write: tmp -> fsync -> .bak -> os.replace
# (design.md §3.8 S9.1, §3.5.3, §3.5.4)
# --------------------------------------------------------------------


def commit(state_dir: Path, full_state: list[StateRecord]) -> None:
    """Atomically persist `full_state` as the new `records.csv`.

    Order (design.md §3.5.4): write `records.csv.tmp` -> `fsync` -> copy
    the CURRENT `records.csv` (if any) to `records.csv.bak` -> `
    os.replace(tmp, records.csv)` (POSIX-atomic). The `#META` tail is
    written in the exact same file as the data it describes, so
    `records.csv` is always either fully absent or fully
    self-consistent -- never observable half-written (design.md §3.5.3).

    Raises:
        WriteError (exit 5): any IO failure while writing the tmp
            file, backing up the previous `records.csv`, or replacing.
    """
    _ensure_dir(state_dir)
    body = _serialize_body(full_state)
    sha256 = _compute_sha256(body)
    last_batch_seq = max((record.batch_id for record in full_state), default=0)
    meta_line = _build_meta_line(
        records=len(full_state), last_batch_seq=last_batch_seq, sha256=sha256
    )
    content = body + meta_line + "\n"

    records_path = state_dir / _RECORDS_FILENAME
    tmp_path = state_dir / f"{_RECORDS_FILENAME}.tmp"
    try:
        with tmp_path.open("w", encoding="utf-8", newline="") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_path, 0o600)
        if records_path.exists():
            backup_path = state_dir / f"{_RECORDS_FILENAME}{_BACKUP_SUFFIX}"
            backup_path.write_bytes(records_path.read_bytes())
            os.chmod(backup_path, 0o600)
        os.replace(tmp_path, records_path)
    except OSError as exc:
        raise WriteError(f"cannot commit state: {records_path} ({exc})") from exc


def _serialize_body(records: list[StateRecord]) -> str:
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    writer.writerow(_HEADER)
    for record in records:
        writer.writerow(_record_to_row(record))
    return buffer.getvalue()


def _record_to_row(record: StateRecord) -> tuple[str, ...]:
    return (
        str(record.batch_id),
        record.request_id,
        record.app_time_iso,
        record.client_ip,
        record.server_ip,
        record.hosp_id,
        record.hosp_abbr,
        record.prsn_id,
        record.birthday,
        record.patient_id_aes,
    )


def _compute_sha256(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _build_meta_line(*, records: int, last_batch_seq: int, sha256: str) -> str:
    return (
        f"{_META_PREFIX}\tschema={_SCHEMA_VERSION}\trecords={records}"
        f"\tlast_batch_seq={last_batch_seq}\tsha256={sha256}"
    )


# --------------------------------------------------------------------
# BATCH_ID assignment (design.md §3.8 S7, §3.5.2, §3.5.5: from 1, no seeding)
# --------------------------------------------------------------------


def assign_batch(new_records: list[TransformedRecord], *, max_batch_seq: int) -> list[StateRecord]:
    """Assign the next BATCH_ID (`max_batch_seq + 1` -- 1 for an empty
    state, design.md §3.5.2, §3.5.5) to every already-deduped record,
    producing the final `StateRecord`s ready to merge into
    `existing + new` and persist via `commit()` (design.md §3.8 S7).
    """
    batch_seq = max_batch_seq + 1
    return [
        StateRecord(
            batch_id=batch_seq,
            request_id=record.request_id,
            app_time_iso=record.app_time_iso,
            client_ip=record.client_ip,
            server_ip=record.server_ip,
            hosp_id=record.hosp_id,
            hosp_abbr=record.hosp_abbr,
            prsn_id=record.prsn_id,
            birthday=record.birthday,
            patient_id_aes=record.patient_id_aes,
        )
        for record in new_records
    ]


# --------------------------------------------------------------------
# Startup housekeeping + audit trail
# --------------------------------------------------------------------


def cleanup_tmp_files(state_dir: Path) -> int:
    """Remove leftover `*.tmp` files from a previous crashed run
    (design.md §3.8 S0, §7.1).

    `records.csv`'s own atomicity guarantees it is always either fully
    committed or absent, so any stray `.tmp` sibling can only be an
    incomplete write from a run that died before its `os.replace` --
    always safe to discard. Returns the number of files removed.
    """
    if not state_dir.is_dir():
        return 0
    removed = 0
    for tmp_path in sorted(state_dir.glob("*.tmp")):
        with contextlib.suppress(FileNotFoundError):
            tmp_path.unlink()
            removed += 1
    if removed:
        logger.info(
            "cleaned up stale .tmp files from a previous run",
            extra={"state_dir": str(state_dir), "removed": removed},
        )
    return removed


def append_run(state_dir: Path, record: Mapping[str, object]) -> None:
    """Append one JSON line to `runs.jsonl` (design.md §3.5.6 audit
    trail).

    Best-effort append-only log, deliberately NOT part of the atomic
    `commit()` -- a failure here is a genuine IO error (`WriteError`),
    never a reason to roll back an already-committed `records.csv`.
    """
    _ensure_dir(state_dir)
    runs_path = state_dir / _RUNS_FILENAME
    line = json.dumps(record, ensure_ascii=False, sort_keys=True)
    try:
        with runs_path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(runs_path, 0o600)
    except OSError as exc:
        raise WriteError(f"cannot append to runs.jsonl: {runs_path} ({exc})") from exc


def read_runs_for_date(state_dir: Path, run_date: date) -> list[dict[str, object]]:
    """Return every `runs.jsonl` record for `run_date`, in the order
    they were appended (design.md §3.5.6, §3.7.2 same-day disambiguation).

    Best-effort, mirroring `append_run`'s own audit-sidecar status: a
    missing `runs.jsonl` yields `[]` (no runs yet, e.g. the very first
    run ever); any single unparsable line is WARN-logged and skipped
    rather than failing the whole read -- `runs.jsonl` is a
    non-authoritative audit trail, never a gate on pipeline correctness
    (contrast `records.csv`'s `#META` tail, design.md §3.5.3-§3.5.4, which
    IS a hard gate).
    """
    runs_path = state_dir / _RUNS_FILENAME
    if not runs_path.is_file():
        return []
    try:
        lines = runs_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise WriteError(f"cannot read runs.jsonl: {runs_path} ({exc})") from exc

    target = run_date.strftime("%Y-%m-%d")
    matches: list[dict[str, object]] = []
    for line_no, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            logger.warning(
                "skipping unparsable runs.jsonl line",
                extra={"path": str(runs_path), "line_no": line_no},
            )
            continue
        if isinstance(record, dict) and record.get("run_date") == target:
            matches.append(record)
    return matches


def _ensure_dir(state_dir: Path) -> None:
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(state_dir, 0o700)
    except OSError as exc:
        raise WriteError(f"cannot prepare state_dir: {state_dir} ({exc})") from exc
