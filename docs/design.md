# log-parse — Design Specification

> Version 2.0 · 2026-06-29 · Audience: developers, SREs, on-call engineers.
> **Language**: **English** · [繁體中文](design.zh-TW.md)

This document specifies **what** the system does and **why** it is structured
the way it is. For command-line usage see [`usage.md`](usage.md); for coding
conventions see [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md).

---

## 1. System Overview

### 1.1 Domain context

The LUNG-CANCER-REPORT system serves clinical study-report viewing across two
hospitals (Taipei / Taichung). Each region runs three servers:

| Role  | Function                                                    | Servers (Taipei)                | Servers (Taichung)              |
|-------|-------------------------------------------------------------|---------------------------------|---------------------------------|
| API   | Issues short-lived URL tokens after HIS authentication      | `10.22.63.37`                   | `10.1.73.37`                    |
| APP   | Verifies URL tokens, serves the DICOM viewer to clinicians  | `10.21.3.35`, `10.21.3.36`      | `10.1.72.35`, `10.1.72.36`      |

Each server emits three log families:

| Family       | Path pattern                                                 | Format                | Producer        |
|--------------|--------------------------------------------------------------|-----------------------|-----------------|
| Access CSV   | `<server>/app/<YYYY-MM-DD>/app-access-<date>.csv`            | RFC 4180 CSV          | API & APP apps  |
| IIS W3C      | `<server>/iis/u_ex<YYMMDD>.log`                              | W3C extended, space   | IIS             |
| App logs     | `<server>/app/<YYYY-MM-DD>/app-{all,error,lifetime}-<d>.log` | Pipe-delimited        | .NET app        |

### 1.2 Use cases addressed

| ID  | Persona              | Question answered                                                           | Module                |
|-----|----------------------|------------------------------------------------------------------------------|-----------------------|
| UC1 | Security analyst     | "Did anyone access the APP without first being authenticated by our API?"   | `analyze_access`      |
| UC2 | Capacity planner     | "What's our request volume / status distribution / slow-request rate?"      | `analyze_iis`         |
| UC3 | DBA / on-call        | "When did OracleDB go unhealthy? How often does the app crash and restart?" | `analyze_errors`      |
| UC4 | Operations lead      | "Give me the full daily / weekly digest in one go."                         | `log_report`          |
| UC5 | Compliance auditor   | "How long after issuing a token did the user actually present it?"          | `analyze_access`      |
| UC6 | Management           | "Give me a one-page system health overview across all regions and roles."   | `analyze_overview`    |

---

## 2. Architecture

```
                       ┌──────────────────────────┐
                       │     log_report.sh        │   (orchestrator)
                       └────────┬─────────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         ▼                      ▼                      ▼
 ┌──────────────┐   ┌───────────────┐   ┌───────────────────┐
 │ analyze_     │   │ analyze_iis   │   │ analyze_overview  │
 │   access.sh  │   │       .sh     │   │         .sh       │
 └──────┬───────┘   └───────┬───────┘   └─────────┬─────────┘
        │                   │                     │ --emit-stats
        │                   │               ┌─────┴──────┐
        │                   │               ▼            ▼
        │                   │      analyze_iis  analyze_access
        │                   │       (--emit-stats only, no persist)
        │                   │
 ┌──────────────┐
 │ analyze_     │
 │   errors.sh  │
 └──────┬───────┘
        │
        └──────────────────────┬─────────────────────────┘
                               │ sources
                               ▼
  ┌──────────────────────────────────────────────────────┐
  │  lib/common.sh        logging, tmpdir, deps          │
  │  lib/date_utils.sh    date ranges, resolve_interval  │
  │  lib/csv_utils.sh     field extraction (awk)         │
  │  lib/fmt_utils.sh     text rendering, fmt_set_color  │
  │  lib/output_utils.sh  always-on persistence (D6)     │
  │  lib/aggregate_utils.sh  AGG_IIS_AWK, AGG_CSV_FUNC,  │
  │                           agg_iis_rows, agg_access_rows│
  └──────────────────────────────────────────────────────┘
                               │ reads
                               ▼
  ┌────────────────────────────────────────────────┐
  │   conf/regions.conf  (region → server mapping) │
  └────────────────────────────────────────────────┘
```

### 2.1 Layering rules

1. **CLI layer** (`bin/`) — parses arguments, drives the workflow, prints reports.
   Never contains parsing logic; delegates to `lib/`.
2. **Library layer** (`lib/`) — pure functions for date math, CSV extraction,
   formatting, logging, persistence, and shared metric computation. No CLI
   parsing; no global mutation outside documented sanctioned globals
   (`WORK_TMPDIR`, `LOG_LEVEL`, region arrays, `RUN_OUTPUT_DIR`, `RUN_TS`,
   `INTERVAL_ARGS`).
3. **Configuration layer** (`conf/`) — pipe-delimited text consumed by
   `load_regions()`. No executable content.

### 2.2 Process model

Each CLI is a single bash process. Heavy work (joins, group-bys, sorts) is
delegated to `gawk` invocations via pipe and temp files under `WORK_TMPDIR`.
Temp files are auto-removed by the `EXIT`/`INT`/`TERM` trap installed by
`init_tmpdir`.

The orchestrator (`log_report.sh`) **spawns sub-processes** to keep module
boundaries clean: it re-invokes each `analyze_*.sh` with the resolved
argument set rather than sourcing them. This guarantees that a crash in one
module cannot corrupt the orchestrator state.

`analyze_overview.sh` also spawns `analyze_iis.sh` and `analyze_access.sh` in
`--emit-stats` mode to source aggregated statistics. These child spawns produce
no persistence files and write no banners; they stream raw TAB-delimited stat
rows to stdout.

### 2.3 New library modules

#### `lib/output_utils.sh` — always-on persistence (D6)

Provides `persist_init`, `persist_ext`, `persist_path`, and `persist_views`.
Every analyzer module calls this after computing stats. Globals: `RUN_OUTPUT_DIR`
(resolved absolute path), `RUN_TS` (fixed launch timestamp `YYYYMMDD_HHMMSS`).

Directory precedence (C1): `--output-dir` flag > `$LOG_PARSE_OUTPUT_DIR` env >
`./log-parse`. The `./log-parse` literal lives **only** inside `persist_init`;
every CLI defaults `OPT_OUTPUT_DIR=""` so the flag > env precedence holds.

#### `lib/aggregate_utils.sh` — shared metric computation + CSV quoter (D5)

Single source of truth for IIS metric awk and the RFC-4180 CSV quoter:

- **`AGG_IIS_AWK`** — IIS W3C log analyser (relocated verbatim from
  `bin/analyze_iis.sh`; no logic change). Used via `agg_iis_rows COMBINED SLOW_MS`.
- **`AGG_CSV_FUNC`** — RFC-4180 gawk `q(s)` function (relocated verbatim from
  `bin/analyze_access.sh`). Prepended to both the access `render_csv` and the
  iis csv-detail gawk programs via string concatenation. **No bash-side
  `fmt_csv_field` is introduced** — `q()` is a gawk function; a bash
  reimplementation would create a third parallel copy.
- **`agg_iis_rows COMBINED SLOW_MS [TOP]`** — runs `AGG_IIS_AWK`, emits tagged rows.
- **`agg_access_rows RESULT_SORTED`** — single gawk pass that replaces the three
  separate counting passes formerly at `analyze_access.sh:351-353`.
- **Schema constants** `IIS_STAT_SCHEMA` / `ACCESS_STAT_SCHEMA` + field-index
  helpers (`IIS_F_REGION`, `IIS_F_TAG`, etc.) so analyzers, renderers, and
  overview share one contract.

#### `lib/fmt_utils.sh` + `lib/common.sh` — re-entrant color state (C3)

The one-time inline color decision formerly at `lib/common.sh:49` is extracted
into **`fmt_set_color_state()`** and called once at source time (preserving
current behavior) plus re-called by `persist_views`:

```bash
fmt_set_color_state() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET='\033[0m';    C_BOLD='\033[1m'
        C_RED='\033[0;31m';   C_YELLOW='\033[0;33m'
        C_GREEN='\033[0;32m'; C_CYAN='\033[0;36m';  C_GREY='\033[0;90m'
    else
        C_RESET='' C_BOLD='' C_RED='' C_YELLOW='' C_GREEN='' C_CYAN='' C_GREY=''
    fi
}
```

`C_CYAN` is mandatory — `fmt_h3` (`fmt_utils.sh`) uses it for `■` sub-headers.
Single-quoted `\033` literals are kept; `printf "%b"` and gawk `-v C_*=...`
both expand them to real ESC bytes at output time. This single toggle covers
every ANSI emitter: `fmt_h1/h2/h3`, `fmt_kv/fmt_kv_color`, `fmt_ok/warn/err`,
`_log`, and the direct `-v C_*="$C_*"` gawk passes in `analyze_access.sh`.

---

## 3. Module specifications

### 3.0 `analyze_overview.sh` — Management overview (NEW)

#### 3.0.1 Purpose

Provide a single-page, management-level system health overview across all
regions and service roles. Summary-only; text-only; no `--view` or `--format`
flag. Defaults to `--region all` with 7-day window.

#### 3.0.2 DRY data sourcing — `--emit-stats` handoff with split arg vectors (C2)

`analyze_overview.sh` contains **zero** log-collection, **zero** parsing, and
**zero** metric awk. It spawns `analyze_iis.sh` and `analyze_access.sh` in
`--emit-stats` mode and reads their TAB-delimited stat rows. The arg vectors
**must** be split because `analyze_access.sh` does not accept `--slow-*-ms`:

```bash
IIS_ARGS=("${BASE_ARGS[@]}" --slow-api-ms "$OPT_SLOW_API_MS" \
                             --slow-app-ms "$OPT_SLOW_APP_MS")
ACCESS_ARGS=("${BASE_ARGS[@]}")   # NO slow thresholds (C2)

analyze_iis.sh    "${IIS_ARGS[@]}"    --emit-stats > "$iis_stats"
analyze_access.sh "${ACCESS_ARGS[@]}" --emit-stats > "$acc_stats"
```

Passing `--slow-*-ms` to `analyze_access.sh` would trigger its fail-fast
`die` on unknown arg and crash the second spawn.

#### 3.0.3 Canonical `--emit-stats` schema

Both analyzers write TAB-delimited rows under the following contracts (defined
as constants in `lib/aggregate_utils.sh`):

**IIS schema** (`IIS_STAT_SCHEMA`):
```
IIS  <region>  <role>  <server>  TOTAL      <n>
IIS  ...                         5XX        <n>
IIS  ...                         503_HEALTH <n>
IIS  ...                         SLOW       <n>
IIS  ...                         REDIRECT   <n>
IIS  ...                         UNIQUE_IPS <n>
IIS  ...                         STATUS     <code>  <count>
IIS  ...                         ENDPOINT   <uri>   <count>  <avg_sec>
IIS  ...                         CLIENT_IP  <ip>    <count>
```

`role` is `api` or `app` (from `conf/regions.conf`). `region` is `taipei` or
`taichung`; merged mode tags `region=all, server=API_SERVERS|APP_SERVERS`.
Per-server granularity lets overview bucket into total / per-region / per-role
by summation.

**Access schema** (`ACCESS_STAT_SCHEMA`):
```
ACCESS  <region>  NORMAL        <n>
ACCESS  ...       ORPHAN        <n>
ACCESS  ...       UNVERIFIED    <n>
ACCESS  ...       ORPHAN_OK     <n>
ACCESS  ...       ORPHAN_FAIL   <n>
ACCESS  ...       DELTA_COUNT   <n>
ACCESS  ...       DELTA_SUM     <sec>
ACCESS  ...       DELTA_MIN     <sec>
ACCESS  ...       DELTA_MAX     <sec>
```

#### 3.0.4 Three-cut layout with single-numeric-placement rule (C5)

The report presents three distinct decomposition dimensions. **No single
numeric literal appears in more than one cut.**

- **總體概況 (Overall)** — system grand totals + headline rates + qualitative
  verdict. Grand totals (`IIS 總請求數`, `存取關聯總數`) appear **only here**.
  The verdict line is numeric-free (words only).
- **分區別 (By Region)** — per-region request *share %*, per-region NORMAL%,
  per-region combined anomaly count. No grand totals; no role-specific signals.
- **服務別 (By Service Role)** — per-role request volume + share % plus role-
  specific problem signals: `UNVERIFIED` only in the API sub-slice (issuance
  side); `ORPHAN`, `503_HEALTH`, `SLOW` only in the APP sub-slice (verification
  side). `5XX` and `SLOW` literals appear **only** inside this block.

Request volume legitimately appears as three different decompositions (grand
total, region split, role split) — but each numeric literal is distinct.

Sample output (weekly, `--from 2026-05-18 --to 2026-05-25`, all regions):
```
========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-18  →  2026-05-25  (8 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  IIS 總請求數                            20651
  不重複用戶端 IP                         21
  存取關聯總數                            14
  NORMAL 正常流程率                       57.1%
  平均 API→APP 延遲                       15.6s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

▶ 分區別 (By Region)
------------------------------------------------------------------------
  [佔比；總量見總體概況]
  台北                                    IIS 佔比 50.4%   NORMAL 25.0%   異常 6
  台中                                    IIS 佔比 49.6%   NORMAL 100.0%   異常 0

▶ 服務別 (By Service Role)
------------------------------------------------------------------------

    ■ API 伺服器 (2 台 · 簽發 Token)
  IIS 請求數 (佔比)                       6595 (31.9%)
  5XX 錯誤                                125
  慢速率 (>2000ms)                        0.0%
  UNVERIFIED (簽發未使用)                 0

    ■ APP 伺服器 (4 台 · 驗證 Token / DICOM)
  IIS 請求數 (佔比)                       14056 (68.1%)
  健康檢查 503 (Oracle 相依)              367
  慢速率 (>5000ms)                        0.0%
  ORPHAN (無對應簽發)                     6
```

#### 3.0.5 Flags accepted / rejected

Accepted: `--log-dir`, `--region`, `--today`, `--date`, `--from`/`--to`,
`--days`, `--slow-api-ms`, `--slow-app-ms`, `--output-dir`, `--conf`, `-v`, `-h`.

Not accepted (die on receipt): `--view`, `--format`, `--merge`, `--top`,
`--emit-stats`.

#### 3.0.6 Persistence

Summary-only: `persist_views overview summary text overview_render ''`.
Only `overview_summary_<TS>.txt` is written (`DETAIL_FN=""` → no detail file).
Empty-window boundary: percentages rendered as `N/A` / `0.0%`, exit 0.

---

### 3.1 `analyze_access.sh` — Access-token cross-correlation

#### 3.1.1 Purpose
Verify that every APP-side access can be traced to a legitimate API-issued
URL token, and vice versa. Surface anomalies in three categories.

#### 3.1.2 Inputs

`<log_dir>/<server>/app/<YYYY-MM-DD>/app-access-<YYYY-MM-DD>.csv`

CSV schema (header row required):

| Col | Name            | Description                                        |
|-----|-----------------|----------------------------------------------------|
| 1   | `REQUEST_ID`    | Per-request UUID                                   |
| 2   | `TOKEN`         | URL token presented to APP (empty on API server)   |
| 3   | `VERIFY_STATUS` | `OK` / `FAIL` (APP only)                           |
| 4   | `PATIENT_ID_AES`| AES-encrypted patient ID                           |
| 5   | `HOSP_ID`       | Hospital code                                      |
| 6   | `PRSN_ID`       | Clinician ID (encrypted)                           |
| 7   | `CLIENT_IP`     | Browser-side IP                                    |
| 8   | `SERVER_IP`     | Server that handled the request                    |
| 9   | `ISSUE_TOKEN`   | URL token generated by API (empty on APP server)   |
| 10  | `REQUEST_TIME`  | `YYYY-MM-DD HH:MM:SS.mmm`                          |

#### 3.1.3 Correlation logic

**Join key**: `API.ISSUE_TOKEN (col 9)` ≡ `APP.TOKEN (col 2)`.

For each region, the analyser:

1. Concatenates all CSVs across the configured API servers and date range
   into one TSV (`api_tsv`).
2. Repeats for APP servers (`app_tsv`).
3. Runs a two-file gawk join (`CORRELATE_AWK`):
   - First pass (`FILENAME == api_file`): builds a hash keyed by ISSUE_TOKEN.
     The `FILENAME` predicate replaces the more idiomatic `FNR == NR` because
     the latter mis-routes records when `api_tsv` is empty (FNR resets).
   - Second pass (default block): for each APP record, looks up its TOKEN in
     the API hash. Match → `NORMAL`; miss → `ORPHAN`. Marks the API record
     as "used" so the END block can emit anything left as `UNVERIFIED`.

Under `--merge`, `correlate_merged` concatenates every configured region's
API-server extracts into one `api_tsv` and every region's APP-server extracts
into one `app_tsv`, then runs CORRELATE_AWK once over the combined corpus —
see §3.1.9.

#### 3.1.4 Output categories

| Status     | Meaning                                                                                                            | Severity         |
|------------|--------------------------------------------------------------------------------------------------------------------|------------------|
| NORMAL     | APP saw a token issued by an API server in the corpus (same region by default; any region under `--merge`)         | green (expected) |
| ORPHAN     | APP received a token with no matching API issuance in the corpus                                                   | yellow (warn)    |
| UNVERIFIED | API issued a token that APP never received                                                                         | grey (info)      |

Causes for ORPHAN include cross-region token replay (when not using `--merge`),
manual URL crafting, and CSV ingestion lag. Causes for UNVERIFIED include
users abandoning the session before opening the viewer.

#### 3.1.5 Internal schema — CORRELATE_AWK output

The two-file gawk join produces 12 tab-delimited fields per record. Column
order follows "when → outcome → identity → server → patient", placing time
sort keys first and the variable-width `PATIENT_ID_AES` last.

| # | Field | NORMAL | ORPHAN | UNVERIFIED |
|---|-------|--------|--------|------------|
| $1 | `STATUS` | `NORMAL` | `ORPHAN` | `UNVERIFIED` |
| $2 | `API_TIME` | `api_ts` | `-` | `api_time[tok]` |
| $3 | `APP_TIME` | `app_ts` | `app_ts` | `-` |
| $4 | `DELTA_SEC` | `delta` / `N/A` | `-` | `-` |
| $5 | `VERIFY_STATUS` | `verify` | `verify` | `-` |
| $6 | `REQUEST_ID` | `coalesce(api_req_id, app_req)` | `app_req` | `api_req_id` |
| $7 | `API_SERVER` | `api_server` | `-` | `api_server` |
| $8 | `APP_SERVER` | `app_srv` | `app_srv` | `-` |
| $9 | `HOSP_ID` | coalesced | coalesced | `api_hosp` |
| $10 | `PRSN_ID` | coalesced | coalesced | `api_prsn` |
| $11 | `CLIENT_IP` | coalesced | coalesced | `api_client_ip` |
| $12 | `PATIENT_ID_AES` | coalesced (full) | coalesced (full) | `api_patient` (full) |

`REQUEST_ID` consolidates the former `API_REQUEST_ID` and `APP_REQUEST_ID`
fields; the coalesce rule is "prefer API id, fall back to APP id". All three
categories include `PRSN_ID` and `CLIENT_IP`. `PATIENT_ID_AES` is emitted in
full — the prior `substr(…, 1, 16)"..."` truncation is removed. `-` denotes a
field absent for that category.

#### 3.1.6 Deterministic sort pre-pass

After CORRELATE_AWK, a single shared gawk pass (`sort_records`) sorts all
12-field records into `result_sorted` before any renderer runs. This produces a
byte-stable order shared by text, tsv, and csv modes.

**Composite sort key (four levels):**

1. `STATUS` ($1) — groups NORMAL, ORPHAN, UNVERIFIED together.
2. Category-appropriate time — `API_TIME` ($2) for NORMAL and UNVERIFIED;
   `APP_TIME` ($3) for ORPHAN (the leading time column in each category's
   text display).
3. `REQUEST_ID` ($6) — distinguishes records with identical timestamps.
4. Full line — stable tie-break neutralising gawk hash-iteration order for
   the UNVERIFIED `for (tok in api_time)` loop.

`asorti(buf, idx, "@ind_str_asc")` is safe because all timestamps are
fixed-width zero-padded (`YYYY-MM-DD HH:MM:SS.mmm`), so lexical ascending
order is identical to chronological ascending order.

All three renderers consume `result_sorted`; none re-sort.

#### 3.1.7 Views

`--view detail` (standalone default): the per-record correlation tables, as
described in §3.1.8–3.1.9. Governs both the console output and the persisted
detail file.

`--view summary` (management text; format-independent — always text): KPI
block showing aggregate counts + percentages, per-region breakdown, ORPHAN
verify-result summary, and mean/min/max API→APP latency. Does not contain
per-record `PATIENT_ID_AES`.

**The summary view is always text regardless of `--format`** (C10). `--format`
governs only the detail file extension and render path.

#### 3.1.8 Text output — per-category columns (detail view)

Each category shows only its present columns; columns absent for that category
are dropped. All categories include `PRSN_ID`, `CLIENT_IP`, and a full
untruncated `PATIENT_ID_AES` as the trailing variable-width column. A header
row (in grey) is printed once per category. Records appear in deterministic
ASC order from §3.1.6.

Shared column widths: `TIME=23 · SERVER=15 · DELTA=8 · VERIFY=7 ·
REQID=13 · HOSP=12 · PRSN=12 · CLIENT=16`.

**NORMAL** — leads with both time columns, includes delta and verify:
`API_TIME, APP_TIME, DELTA, VERIFY, REQUEST_ID, API_SRV, APP_SRV, HOSP_ID,
PRSN_ID, CLIENT_IP, PATIENT_ID_AES`.
Delta formatted as `%.1fs` (clamped ≥ 0), or `N/A` when absent. Followed by
aggregate statistics: count with valid delta, mean, min, max.

**ORPHAN** — leads with `APP_TIME` (no `API_TIME`, `API_SERVER`, or `DELTA`):
`APP_TIME, VERIFY, REQUEST_ID, APP_SRV, HOSP_ID, PRSN_ID, CLIENT_IP,
PATIENT_ID_AES`.
Followed by a verify-result summary; a warning is appended when any ORPHAN
has `VERIFY=OK`.

**UNVERIFIED** — leads with `API_TIME` (no `APP_TIME`, `APP_SERVER`, `DELTA`,
or `VERIFY`):
`API_TIME, REQUEST_ID, API_SRV, HOSP_ID, PRSN_ID, CLIENT_IP, PATIENT_ID_AES`.

The `PATIENT_ID_AES` column is always last and may wrap on narrow terminals.
No truncation is applied.

#### 3.1.9 Machine-readable output — `tsv` and `csv` (detail view)

Both formats are flat outputs over `result_sorted` (same deterministic order
as text, §3.1.6). Each row is prefixed with a `REGION` column (region name,
or `merged` under `--merge`). The 13-column schema:

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

- **`--format tsv`** — TAB delimiter, no quoting.
- **`--format csv`** — comma delimiter, RFC-4180 conditional quoting via the
  shared `q()` function (`AGG_CSV_FUNC` from `lib/aggregate_utils.sh`): a
  field is quoted only when it contains `"`, `,`, or a newline; embedded `"`
  characters are doubled. LF line endings. Fields with none of these characters
  appear unquoted.

A header row is emitted once at the top of each output (TAB-joined for tsv,
comma-joined for csv). Both formats share the byte-stable ordering from §3.1.6.

#### 3.1.10 `--merge` semantics

`--merge` requires `--region all` (explicit or default). Supplying a
single-region `--region` with `--merge` aborts with an error.

`correlate_merged` builds one `api_tsv` from all configured regions'
API-server logs and one `app_tsv` from all regions' APP-server logs, then runs
CORRELATE_AWK once over the combined corpus. A token issued by region X's API
server and presented to region Y's APP server classifies as **NORMAL** — not
ORPHAN — because the merged corpus is host-agnostic. Merged NORMAL counts are
≥ the sum of per-region NORMAL counts; the difference equals the number of
cross-region token exchanges in the dataset.

Per-region analysis (the default) preserves regional identity. `--merge` is a
deliberately host-agnostic view for auditing the end-to-end token flow across
all regions.

Text output: a single `Region: all (merged)` block with three ASC-sorted
category lists. tsv / csv output: `REGION` column value is `merged`.

#### 3.1.11 `--emit-stats`

Prints `access_stats.tsv` verbatim to stdout, then returns before
`persist_init` (no files, no banners). This is `analyze_overview.sh`'s data
source. Accepts only the interval/region/conf/verbose subset of flags — never
`--slow-*-ms` (which would trigger the fail-fast `die` on unknown arg).

---

### 3.2 `analyze_iis.sh` — IIS W3C log analysis

#### 3.2.1 Purpose
Surface HTTP-level signals: traffic volume, error rates, slow endpoints,
and health-check failures.

#### 3.2.2 Inputs

`<log_dir>/<server>/iis/u_ex<YYMMDD>.log` — IIS W3C extended format.

Field schema (1-based positional, default IIS configuration):

| Idx | Field          | Notes                                                    |
|-----|----------------|----------------------------------------------------------|
| 1   | `date`         | `YYYY-MM-DD`                                             |
| 2   | `time`         | `HH:MM:SS` (UTC)                                         |
| 4   | `cs-method`    | HTTP verb                                                |
| 5   | `cs-uri-stem`  | Path without query string                                |
| 9   | `c-ip`         | Client IP (use `client_ips[]` set for uniques)           |
| 12  | `sc-status`    | HTTP status code                                         |
| 17  | `time-taken`   | Request duration in milliseconds                         |

Lines starting with `#` are W3C directives and are skipped. Lines with fewer
than 17 fields are skipped (malformed / truncated).

#### 3.2.3 Endpoint grouping

The raw `cs-uri-stem` contains DICOM study and series UIDs which would
explode the cardinality of any endpoint count. The analyser collapses three
DICOM-specific path families before counting:

```
/api/NhiPatientImage/studies/{uid}/series/{uid}/...
/api/NhiPatientImage/studies/{uid}/series-uid
/api/NhiPatientImage/studies/{uid}/instances/{uid}
```

Other paths are reported verbatim.

#### 3.2.4 Aggregated signals

| Metric             | Definition                                                                          |
|--------------------|-------------------------------------------------------------------------------------|
| `total`            | Lines parsed (excluding comments and short rows)                                    |
| `status_count[]`   | Per-status-code count (e.g. 200, 302, 404, 500, 503)                                |
| `error5xx`         | Rows where `status >= 500`                                                          |
| `health503`        | Rows where `status == 503` **AND** `uri == /health`                                 |
| `slow`             | Rows where `time-taken >= threshold` **AND** `uri != /health`; threshold is `--slow-api-ms` (default 2000 ms) for API-role servers and `--slow-app-ms` (default 5000 ms) for APP-role servers |
| `redirect`         | Rows where `status == 302`                                                          |
| `client_ips`       | Hash of `c-ip → request_count`; `length()` yields unique-IP count; iterated for the per-IP table. `-` excluded. |
| `top endpoints`    | Top-N endpoints by request count (after DICOM grouping), N controlled by `--top` (default 10, 0=all); each with **mean response time** in seconds (2 dp) |
| `client_ip_roster` | Top-N unique `c-ip` values with request count and `% of total`, N controlled by `--top` (0=all) |

Health-check 503s are surfaced as a **separate metric** (not just a 5xx
count) because they indicate dependency-health failure, not application
fault — the response is intentionally 503 when OracleDB is unhealthy.

The `% of total` denominator for all three tables is the `total` requests
count for that server or bucket (including `/health` and redirects). When
`--top` truncates the endpoint or client-IP list, the visible rows' percentages
will not sum to 100.

#### 3.2.5 Single computation source

`main()` builds each server's `$combined` once, runs `agg_iis_rows` once per
corpus (writing dimensioned rows with `region role server` prefix to
`iis_stats.tsv`), and never re-parses logs. Pure renderers read `iis_stats.tsv`.

#### 3.2.6 Views

`--view detail` (standalone default — D2): the per-server report layout
described in §3.2.7–3.2.8. No information loss.

`--view summary` (management text; format-independent — always text): concise
KPIs + % for each scope (overall header, then per region→server, or merged
buckets). Top-3 enumerations only; omits full tables. Every line carries a %.

**The summary view is always text regardless of `--format`** (C10). `--format`
governs only the detail file extension and render path.

#### 3.2.7 Detail text output (--format text)

For each server in the selected region(s), or each role bucket under `--merge`:

1. Top-line counters: `Total requests`, `Unique client IPs`, `302 Redirects`,
   `5xx errors`, `Health 503`, `Slow (>Nms)` — the threshold value in the
   label reflects the server's role.
2. HTTP status-code table — columns `["Status", "Count", "% of total"]`,
   sorted by count descending. Sorting happens in-gawk (no external `sort`).
3. Endpoint table — columns `["Endpoint", "Avg(s)", "Count", "% of total"]`,
   sorted by count descending. Capped at `--top` rows (default 10; 0=all).
4. Client IP table — columns `["Client IP", "Count", "% of total"]`, sorted
   by count descending. Capped at `--top` rows. Empty when all rows have
   `c-ip = -`.

IIS tables are exclusively count-descending ranked lists; there is no
per-record chronological detail list.

#### 3.2.8 Detail machine-readable output (--format tsv|csv)

Real long-format table (NEW — was a no-op+warn before this refactor). One
standardized record per metric row; header emitted once; `--top` cap applied
to ENDPOINT and CLIENT_IP rows. Column schema:

```
REGION  ROLE  SERVER       METRIC    KEY                COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37  SUMMARY   TOTAL              40000  -        100.0
taipei  api   10.22.63.37  SUMMARY   5XX                120    -        0.3
taipei  api   10.22.63.37  STATUS    200                36800  -        92.0
taipei  api   10.22.63.37  ENDPOINT  /api/Auth/IssueTok 5000   0.12     12.5
taipei  api   10.22.63.37  CLIENT_IP 10.21.3.35         7280   -        18.2
```

CSV uses the shared `q()` RFC-4180 quoter (`AGG_CSV_FUNC`). TSV uses TAB
delimiter with no quoting. Both persisted files carry no ANSI color.

#### 3.2.9 Per-role slow thresholds

`--slow-api-ms` (default 2000 ms) applies to servers listed in `REGION_APIS`;
`--slow-app-ms` (default 5000 ms) applies to servers in `REGION_APPS`. Role
membership is resolved via `conf/regions.conf`. The defaults reflect the
tighter SLA expected of API token-issuance endpoints versus APP DICOM-serving
endpoints. The `Slow (>Nms)` label in the report shows the actual threshold
used for that server's role.

#### 3.2.10 `--top` flag

Controls the maximum number of rows shown in both the Endpoint table and the
Client IP table (default 10; 0=all). The same cap applies to both tables in
the same invocation. The flag is unified across `analyze_iis` and
`analyze_errors` (same name, same 0=all semantics, different target list).

#### 3.2.11 `--merge` — two-bucket cross-region corpus

Under `--merge`, `analyze_merged_iis` builds two corpora by iterating over all
configured regions:

- **API corpus**: concatenates IIS logs from every region's `REGION_APIS` servers.
- **APP corpus**: concatenates IIS logs from every region's `REGION_APPS` servers.

`agg_iis_rows` runs once per corpus, producing two output blocks:
1. `IIS — API_SERVERS (merged, all regions)` — uses `--slow-api-ms` threshold.
2. `IIS — APP_SERVERS (merged, all regions)` — uses `--slow-app-ms` threshold.

#### 3.2.12 `--emit-stats`

Prints `iis_stats.tsv` verbatim to stdout, then returns before `persist_init`
(no files, no banners). This is `analyze_overview.sh`'s data source.

---

### 3.3 `analyze_errors.sh` — Application errors & lifecycle

#### 3.3.1 Purpose
Diagnose the application layer: OracleDB connectivity outages, top
recurring error patterns, and unplanned restarts with downtime.

#### 3.3.2 Inputs

Pipe-delimited rows in `app-all-<d>.log` (preferred) or `app-error-<d>.log`:

```
2026-05-21 14:03:44.332|eventId: 0|level: ERROR|traceId: ...|logger: ...|message: <text>|
```

`app-lifetime-<d>.log` contains lines tagged with the `Microsoft.Hosting.Lifetime`
category and carrying `Application started` or `Application is shutting down`
messages.

#### 3.3.3 Error pattern extraction (`ERROR_AWK`)

1. Filter to rows containing `|level: ERROR|`.
2. Extract `message:` field, truncate at `--- Exception` marker (the stack
   trace would otherwise dominate the message).
3. Cap message at 120 chars.
4. Build a **normalised** key for grouping:
   - Replace `\d+\.\d+ms` with literal `Nms` (per-request timing varies).
   - Replace any `YYYY-MM-DD` with literal `DATE`.
   - Replace remaining `\d+` with `N`.
5. Increment `error_count[norm]` and store the first observed `msg` as the
   sample for that group.
6. End-of-input: emit `TOTAL_ERRORS`, `DB_FAILURES`, up to 5 `DB_TIME`
   stamps, and the top-N normalised patterns sorted by count (default 10,
   override via `--top N`; when `--top 0` is supplied, **all** patterns are
   emitted).

#### 3.3.4 OracleDB failure detection

A row counts as a DB failure when its message matches both:
- contains `OracleDB`
- contains `Unhealthy` **OR** `TaskCanceledException`

This pattern is borne out by the sample data: every DB outage in the corpus
shows up as either a health-check `Unhealthy` event or a query
`TaskCanceledException` after the connection pool stalls.

#### 3.3.5 Restart pairing (`LIFETIME_AWK` + `pair_restarts`)

1. `LIFETIME_AWK` scans `app-lifetime` lines and emits
   `SHUTDOWN <ts>` / `STARTED <ts>` events.
2. `pair_restarts` walks the (chronological) event list:
   - When it sees `STARTED` after a held `SHUTDOWN`, it emits a
     `RESTART <shutdown_ts> <started_ts> <delta_sec>` row.
   - If a second `SHUTDOWN` arrives before a matching `STARTED`, the prior
     unpaired event is emitted as `UNMATCHED`. The same is done at EOF.

Downtime delta is computed with `mktime()` from the parsed timestamp
(seconds resolution; sub-second precision is dropped).

#### 3.3.6 Views and persistence

`analyze_errors` has **no `--view` flag**. Console always shows the detail
view. The persisted `errors_summary_<TS>.txt` exists on disk but is not
selectable to stdout (de-emphasis: errors is optional and off by default in
`log_report`).

- **`errors_render_summary`** (thin management text): per region/server
  `Total ERROR`, `OracleDB health failures` (with % of total errors), `Restart
  count`, `Unmatched SHUTDOWN`.
- **`errors_render_detail`**: the full report — top patterns, DB first-failure
  times, restart table — unchanged from prior behavior.

`--format` accepts `text|tsv|csv` for forwarding compatibility but only `text`
renders (non-text value triggers `log_warn` and falls back to text; C25).
Both `errors_summary_*.txt` and `errors_detail_*.txt` are always written.

#### 3.3.7 Output (detail view)

- `Total ERROR entries` — raw count.
- `OracleDB health failures` — DB-specific subset, in red.
- First 5 DB-failure timestamps when count > 0.
- Top-N error patterns table.
- Restart event table (Shutdown / Started / Downtime).
- `Unmatched SHUTDOWN` count when nonzero (yellow), with `(無對應啟動記錄)`
  rows so the operator can see exactly which shutdown lacked a corresponding
  startup — usually a hard crash or pending recovery.

---

### 3.4 `log_report.sh` — Orchestrator

#### 3.4.1 Purpose
Single entry point for "give me everything". Selects which modules to run,
forwards the appropriate flags to each child, and manages shared persistence
state.

#### 3.4.2 Module selection

`--modules` accepts a comma-separated subset of `overview,iis,access,errors`.
Default: `overview,iis,access` (this order; errors is **opt-in / off by
default**). Unknown names abort with `die`. Modules are executed in the order
listed.

#### 3.4.3 Persistence model

`log_report.sh` calls `persist_init "$OPT_OUTPUT_DIR"` **once**, then exports
the resolved dir and timestamp so every child uses the same values:

```bash
persist_init "$OPT_OUTPUT_DIR"
export LOG_PARSE_RUN_TS="$RUN_TS"
export LOG_PARSE_OUTPUT_DIR="$RUN_OUTPUT_DIR"
for m in "${MODULES[@]}"; do run_module "analyze_${m}"; done
```

Children default `OPT_OUTPUT_DIR=""` and read `$LOG_PARSE_OUTPUT_DIR` (C1);
`--output-dir` is **not** forwarded as a flag — the env carries the resolved
dir. A `log_report --output-dir /custom` run correctly lands every child file
in `/custom`. Each child self-persists its own file pair. `log_report`'s own
stdout is the concatenation of each child's selected-view console mirror.

A default run produces exactly five files sharing one `RUN_TS`:
`overview_summary`, `iis_summary`, `iis_detail`, `access_summary`,
`access_detail`.

#### 3.4.4 Default view

`OPT_VIEW="summary"` — forwarded to `analyze_iis` and `analyze_access` only.
`analyze_overview` is summary-only; `analyze_errors` has no `--view`. Callers
may pass `--view detail` to see per-record tables in the console mirror.

#### 3.4.5 Argument propagation

`build_module_args()` builds a per-module `_MOD_ARGS` array forwarded verbatim
to each child invocation. Conditional appends use the `if ... then ... fi`
form (rather than `[[ ]] && cmd`) so that a false predicate at the end of the
function does not cause the function to return 1 — which under `set -e` would
otherwise abort the orchestrator before any module runs.

`--output-dir` is deliberately **not** forwarded as a flag; the env carries
the resolved dir (see §3.4.3).

#### 3.4.6 Option forwarding matrix

| Flag | log_report | overview | access | iis | errors | Notes |
|---|---|---|---|---|---|---|
| `--log-dir` | own | F | F | F | F | required |
| `--region` | own | F | F | F | F | gates `--merge` |
| `--today` | own | F | F | F | F | interval selector |
| `--date` / `--from` / `--to` / `--days` | own | F | F | F | F | interval |
| `--conf` | own (validates only when supplied) | F | F | F | F | |
| `--output-dir` | own | env | env | env | env | never flag-forwarded (C1) |
| `--modules` | own | — | — | — | — | orchestrator-only |
| `--verbose` | own | F | F | F | F | |
| `--view` | own | — (summary-only) | F | F | — (no view) | default summary |
| `--format` | own | — (text-only) | F | F | warn+text | governs detail only |
| `--top` | F→{iis,errors} | — | — | Endpoint+Client-IP | pattern count | 0=ALL |
| `--slow-api-ms` | F→{overview,iis} | F | — | API-role servers | — | default 2000 ms |
| `--slow-app-ms` | F→{overview,iis} | F | — | APP-role servers | — | default 5000 ms |
| `--merge` | F→{access,iis} | — | cross-region | two-bucket | — | requires `--region all` |

Legend: `own` = log_report acts on this flag itself · `F` = forwarded to child ·
`env` = carried via `LOG_PARSE_OUTPUT_DIR` env var · `—` = not accepted.

---

### 3.5 `--output FILE` — REMOVED (breaking)

`--output FILE` has been removed from **all** CLIs. It is superseded by the
always-on directory persistence model (incompatible with the two-files-per-
module + multi-module design). No alias is provided. Migration: use
`--output-dir DIR` and locate the generated files inside that directory.

---

## 4. Cross-cutting concerns

### 4.1 Interval selection (mutex, D3)

All five CLIs accept the same set of interval flags, enforced by
`resolve_interval` (in `lib/date_utils.sh`):

| Flag | Meaning | Notes |
|---|---|---|
| `--today` | Single day = today's date | Maps to `--date $(today)` |
| `--date YYYY-MM-DD` | Single specific day | |
| `--from D --to D` | Inclusive range (both required) | Counted as one selector |
| `--days N` | Last N calendar days ending today | Default implicit fallback (N=7) |

**Rule: choose exactly one explicit selector.** Supplying more than one
aborts with `die`. The error message cites the canonical priority ranking so
the user knows which to keep:

```
interval flags are mutually exclusive
(priority --date > --from/--to > --today > --days): choose exactly ONE (got N)
```

`--days` is the **only implicit fallback**; it is not counted as a conflict
unless explicitly supplied with another selector. `resolve_interval` populates
the global `INTERVAL_ARGS[]` which callers forward verbatim to
`build_date_list`.

The priority ranking in the error message is informational (it names a
commonly-intended resolution) but the behavior is always hard mutex — the
tool never silently picks one selector and proceeds. This satisfies project
rule #1 ("fail fast, loud; no silent suppression").

### 4.2 Persistence & filenames

Every run of any analyzer module writes report files to a directory. File
naming convention: `<module>_<kind>_<TS>.<ext>`.

| Component | Values |
|---|---|
| `module` | `overview`, `iis`, `access`, `errors` |
| `kind` | `summary`, `detail` |
| `TS` | `YYYYMMDD_HHMMSS` — single shared timestamp per run |
| `ext` | `txt` for summary (always); `txt`, `tsv`, or `csv` for detail |

**Single-TS rule**: all files produced by one top-level invocation (or one
`log_report` run) share exactly one `RUN_TS`. `log_report` calls
`persist_init` once and exports `LOG_PARSE_RUN_TS` so every child process
reads the same value.

**Directory precedence** (C1):
1. `--output-dir DIR` flag (highest)
2. `$LOG_PARSE_OUTPUT_DIR` environment variable
3. `./log-parse` (default, created if absent)

Every CLI defaults `OPT_OUTPUT_DIR=""`. The `./log-parse` literal lives **only**
inside `persist_init`; this ensures the flag > env precedence actually holds
when `log_report` spawns children.

**Color-free guarantee** (C3): all persisted files are written with
`NO_COLOR=1` + `fmt_set_color_state` so `C_*` globals are blank during file
writes. The console mirror is re-rendered after restoring the original color
state. No ANSI ESC byte (`0x1b`) appears in any persisted file.

**Overview** writes only a summary file (`overview_summary_<TS>.txt`); no
detail file is produced.

**`--emit-stats`** mode writes **no files**; it short-circuits before
`persist_init`.

### 4.3 Date handling

A single `build_date_list` (in `lib/date_utils.sh`) is the source of truth
for date range generation. `resolve_interval` is the single source of truth
for interval-flag validation (see §4.1).

All dates are validated via `date -d`; an invalid input aborts with `die`.

### 4.4 Logging

`lib/common.sh` exposes `log_debug` / `log_info` / `log_warn` / `log_error`
honouring `LOG_LEVEL`. All logs go to **stderr** so the report itself can be
safely piped to a file or tool. Colour is governed by `fmt_set_color_state`
(auto-disabled when stdout is not a TTY or `NO_COLOR=1` is set).

### 4.5 Temp file management

`init_tmpdir` creates `${TMPDIR:-/tmp}/log_analyze.XXXXXX` and installs a
trap on `EXIT INT TERM` to remove it. All intermediate files (per-server
combined logs, per-region join inputs, restart event TSVs, `iis_stats.tsv`,
`access_stats.tsv`) live there.

### 4.6 Error handling

- `set -euo pipefail` in every executable script.
- Required arguments validated up-front; missing `--log-dir` aborts.
- Missing per-server directories are demoted to `log_warn` (per-server
  graceful skip) rather than fatal — one region's outage should not block
  the other region's analysis.
- Empty date data is reported (`無資料` / `No data`) but not treated as an
  error.

### 4.7 Performance characteristics

- Disk I/O is the dominant cost. The two-pass awk join runs at roughly
  100k rows/sec on commodity hardware.
- Memory is bounded by the **unique-token cardinality**, not by row count
  (the API hash size). For one day across both regions this is in the
  thousands.
- The orchestrator runs modules sequentially. Adding parallelism would
  require independent `WORK_TMPDIR`s per child and is currently not
  warranted at the observed scale.
- `analyze_overview.sh` spawns two child processes that re-read the log
  files (one for IIS, one for access). This double-read is an accepted
  cost of process isolation; the binding DRY requirement is single-source
  computation (`lib/aggregate_utils.sh`), not single-read I/O. An
  `--agg-cache` handoff is explicitly out of scope.

### 4.8 CJK-aware rendering

KV rows and stat blocks are padded by **display width** (wcwidth: CJK ideographs = 2 columns) via the `FMT_AWK_WIDTH` engine in `lib/fmt_utils.sh`, so CJK and ASCII labels align correctly in the terminal.

---

## 5. Capability matrix

| Flag / Feature | analyze_overview | analyze_access | analyze_iis | analyze_errors | log_report | Default |
|---|---|---|---|---|---|---|
| `--log-dir` | req | req | req | req | req | — |
| `--region` | yes | yes | yes | yes | yes | `all` |
| `--today` | yes | yes | yes | yes | yes | off |
| `--date` | yes | yes | yes | yes | yes | `""` |
| `--from`/`--to` | yes | yes | yes | yes | yes | `""` |
| `--days` | yes | yes | yes | yes | yes | `7` |
| `--view summary\|detail` | — (summary-only) | yes | yes | — (detail-only) | yes (fwd→iis,access) | standalone=`detail`; log_report=`summary` |
| `--format text\|tsv\|csv` | — (text-only) | yes | yes (real) | warn+text | yes (fwd) | `text` |
| `--top N` | — | — | yes | yes | fwd→iis,errors | `10` |
| `--slow-api-ms` | yes | — | yes | — | fwd→overview,iis | `2000` |
| `--slow-app-ms` | yes | — | yes | — | fwd→overview,iis | `5000` |
| `--merge` | — | yes | yes | — | fwd→access,iis | off |
| `--output-dir` | yes | yes | yes | yes | yes | `""` → `./log-parse` |
| `--emit-stats` | — | yes | yes | — | — | off |
| `--modules` | — | — | — | — | yes | `overview,iis,access` |
| `--conf` | yes | yes | yes | yes | yes | `conf/regions.conf` |
| `-v`/`--verbose`, `-h` | yes | yes | yes | yes | yes | off |
| `--output FILE` | REMOVED | REMOVED | REMOVED | REMOVED | REMOVED | n/a |

`--format` on `analyze_iis` is now **real** (governs the detail file/view);
it was formerly a no-op + warning. Summary is always text regardless of
`--format` (C10).

---

## 6. Extensibility

### 6.1 Adding a region
Append to `conf/regions.conf` — no code change required. The new region
appears in all reports automatically.

### 6.2 Adding a new analyser
1. Create `bin/analyze_<name>.sh` following the existing `parse_args` /
   `load_regions` / `main` skeleton. Source `lib/output_utils.sh` and call
   `persist_views` at the end of `main`.
2. Add `<name>` to the `valid_modules` array in `bin/log_report.sh`.
3. Add a row to the module table in this document and in `usage.md`.
4. Add a section to `tests/run_tests.sh`.

### 6.3 Changing the access-CSV schema
Update column indices in `lib/csv_utils.sh` (`extract_api_records`,
`extract_app_records`) and the documented field table in §3.1.2. Run the
test suite to confirm baselines still hold (or update them deliberately).

---

## 7. Known limitations

- IIS time field is treated as UTC; reports do not localise.
- The error-pattern grouper is heuristic — it will collapse messages that
  differ only by numeric IDs / timestamps, which is correct most of the
  time but loses fidelity for error families distinguished by string state.
- Restart pairing assumes events arrive in chronological order; if logs are
  rotated mid-event this can produce a false `UNMATCHED`.
- Only Linux/WSL is supported; macOS requires `gdate` aliasing.
- Every run writes files to the output directory. Use `--output-dir` or
  `LOG_PARSE_OUTPUT_DIR` to control placement; add `/log-parse/` to
  `.gitignore` to prevent committing default-dir output.
- `analyze_errors` summary is persisted to disk but not selectable to the
  console (no `--view` flag on errors). Add `--view` to errors only on
  explicit future request.
