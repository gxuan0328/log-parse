"""Recompute 院所分析 from the full persisted state (design.md §3.2
aggregate, §4.3, §5 S7, §8.4, §12.1).

Pure function: no I/O, no mutation of `full_state`. Every run rebuilds
院所分析 from scratch out of the COMPLETE state (existing rows plus
this run's newly appended batch) -- there is no incremental/delta
aggregation path, mirroring how xlsx_writer rebuilds the whole 調閱紀錄
sheet from state on every run (design.md §6.5 per-run reset
semantics).
"""

from __future__ import annotations

import logging

from report_export.models import ReportRow, StateRecord

__all__ = ["build"]

logger = logging.getLogger(__name__)


def build(full_state: list[StateRecord]) -> list[ReportRow]:
    """Rebuild 院所分析 from `full_state` (design.md §4.3, §2.2, §2.3).

    Semantics mirror the template's Excel 365 dynamic-array formulas,
    evaluated against 調閱紀錄 ITSELF -- never the 93k reference master
    (design.md §2.3), plus the tool's own WEEKLY/TOTAL split (design.md
    §4.3 REQ3, which has no template formula to mirror -- the template
    only ever had a single COUNT column):

        A  UNIQUE(FILTER(CLIENT_IP, CLIENT_IP<>""))   -- first-seen order
        B  XLOOKUP(IP, 調閱紀錄!C:C, 調閱紀錄!E:E)      -- first-match
        C  XLOOKUP(IP, 調閱紀錄!C:C, 調閱紀錄!F:F)      -- first-match
        D  COUNTIFS(調閱紀錄!C:C, IP, BATCH_ID, max(BATCH_ID))  -- WEEKLY ACCESS
        E  COUNTIF(調閱紀錄!C:C, IP)                            -- TOTAL ACCESS

    `max_batch_id` is computed once over the whole `full_state`; a row
    counts toward WEEKLY ACCESS only when its own `batch_id` equals
    that maximum -- everything else (including a 0-new idempotent
    rerun, where `full_state` is unchanged from the previous run)
    always counts toward TOTAL ACCESS. A CLIENT IP whose rows carry
    more than one distinct HOSP_ID keeps the first-seen row's
    HOSP_ID/HOSP_ABBR (matching XLOOKUP first-match) and logs one
    WARNING naming the IP and the full set of conflicting HOSP_IDs
    (design.md §13-11) -- a data-quality signal, never a fail-fast
    condition: dedup only ever keys on REQUEST_ID, never HOSP_ID
    (design.md §7.4).
    """
    max_batch_id = max((record.batch_id for record in full_state), default=0)

    first_seen: dict[str, StateRecord] = {}
    total_access: dict[str, int] = {}
    weekly_access: dict[str, int] = {}
    hosp_ids_by_ip: dict[str, set[str]] = {}
    order: list[str] = []

    for record in full_state:
        ip = record.client_ip
        if ip not in first_seen:
            first_seen[ip] = record
            order.append(ip)
            hosp_ids_by_ip[ip] = set()
        total_access[ip] = total_access.get(ip, 0) + 1
        if record.batch_id == max_batch_id:
            weekly_access[ip] = weekly_access.get(ip, 0) + 1
        hosp_ids_by_ip[ip].add(record.hosp_id)

    for ip in order:
        distinct_hosp_ids = hosp_ids_by_ip[ip]
        if len(distinct_hosp_ids) > 1:
            logger.warning(
                "CLIENT IP maps to multiple distinct HOSP_IDs; using first-seen value",
                extra={"client_ip": ip, "hosp_ids": sorted(distinct_hosp_ids)},
            )

    return [
        ReportRow(
            client_ip=ip,
            hosp_id=first_seen[ip].hosp_id,
            hosp_abbr=first_seen[ip].hosp_abbr,
            weekly_access=weekly_access.get(ip, 0),
            total_access=total_access[ip],
        )
        for ip in order
    ]
