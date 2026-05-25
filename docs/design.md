# log-parse — Design Specification

> Version 1.0 · 2026-05-25 · Audience: developers, SREs, on-call engineers.
> **Language**: **English** · [繁體中文](design.zh-TW.md)

This document specifies **what** the system does and **why** it is structured
the way it is. For command-line usage see [`usage.md`](usage.md); for coding
conventions see [`../CLAUDE.md`](../CLAUDE.md).

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

---

## 2. Architecture

```
                       ┌──────────────────────────┐
                       │     log_report.sh        │   (orchestrator)
                       └────────┬─────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
      ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
      │ analyze_      │ │ analyze_iis   │ │ analyze_      │
      │   access.sh   │ │       .sh     │ │   errors.sh   │
      └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
              │                 │                 │
              └─────────────────┼─────────────────┘
                                │ sources
                                ▼
        ┌────────────────────────────────────────────────┐
        │  lib/common.sh      logging, tmpdir, deps      │
        │  lib/date_utils.sh  date ranges, filename map  │
        │  lib/csv_utils.sh   field extraction (awk)     │
        │  lib/fmt_utils.sh   text rendering             │
        └────────────────────────────────────────────────┘
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
   formatting, logging. No CLI parsing, no global mutation outside documented
   `WORK_TMPDIR` / `LOG_LEVEL` / region arrays.
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

---

## 3. Module specifications

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

#### 3.1.4 Output categories

| Status     | Meaning                                                           | Severity         |
|------------|-------------------------------------------------------------------|------------------|
| NORMAL     | APP saw a token previously issued by the **same region's** API    | green (expected) |
| ORPHAN     | APP received a token with no matching API issuance                | yellow (warn)    |
| UNVERIFIED | API issued a token that APP never received                        | grey (info)      |

Causes for ORPHAN include cross-region token replay, manual URL crafting,
and CSV ingestion lag. Causes for UNVERIFIED include users abandoning the
session before opening the viewer.

#### 3.1.5 Output fields (text mode)

For NORMAL flows:
- `API_TIME`, `APP_TIME` — the issuance and verification timestamps
- `DELTA` — `APP_TIME − API_TIME` in seconds (clamped ≥ 0)
- `VERIFY` — `OK` or `FAIL` from APP side
- `HOSP`, `CLIENT` — hospital code and client IP

Aggregate statistics emitted at the end of the NORMAL section: count,
mean, min, max time delta.

For ORPHAN: `APP_TIME`, `APP_SRV`, `VERIFY`, `HOSP`, truncated `PATIENT_ID`.
A warning is appended when at least one ORPHAN has `VERIFY=OK` (potential
valid replay).

For UNVERIFIED: `API_TIME`, `API_SRV`, `HOSP`, truncated `PATIENT_ID`.

#### 3.1.6 Output format `tsv`

When `--format tsv` is supplied the report becomes machine-readable TSV with
columns: `REGION, STATUS, API_REQUEST_ID, APP_REQUEST_ID, PATIENT_ID_AES,
HOSP_ID, PRSN_ID, CLIENT_IP, API_SERVER, APP_SERVER, API_TIME, APP_TIME,
DELTA_SEC, VERIFY_STATUS`. Suitable for downstream ETL.

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
| `slow`             | Rows where `time-taken >= --slow-ms` **AND** `uri != /health`                       |
| `redirect`         | Rows where `status == 302`                                                          |
| `client_ips`       | `length(unique(c-ip))` excluding `-`                                                |
| `top endpoints`    | Top 15 endpoints by request count (after DICOM grouping)                            |

Health-check 503s are surfaced as a **separate metric** (not just a 5xx
count) because they indicate dependency-health failure, not application
fault — the response is intentionally 503 when OracleDB is unhealthy.

#### 3.2.5 Output sections

For each server in the selected region(s):
1. Top-line counters (`Total`, `Unique IPs`, `5xx`, `Health 503`, `Slow`).
2. Status-code table (sorted by count descending).
3. Top-15 endpoint table (sorted by count descending).

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
   override via `--top N`).

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

#### 3.3.6 Output

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
Single entry point for "give me everything". Selects which modules to run
and where their output goes.

#### 3.4.2 Module selection

`--modules` accepts a comma-separated subset of `access,iis,errors` (default
all three). Unknown names abort with a clear error.

#### 3.4.3 Output modes

| Mode             | Trigger                            | Behaviour                                              |
|------------------|------------------------------------|--------------------------------------------------------|
| Stdout (default) | Neither `--output` nor `--output-dir` | Streams each module to stdout in sequence            |
| Combined file    | `--output FILE`                    | Truncates FILE, appends each module's output          |
| Per-module dir   | `--output-dir DIR`                 | Writes `<module>_<YYYYMMDD_HHMMSS>.txt` files in DIR  |

`--output` and `--output-dir` are mutually exclusive in practice; if both are
supplied, `--output-dir` wins (the per-module branch fires first).

#### 3.4.4 Argument propagation

`build_module_args()` builds a shared `_SHARED_ARGS` array that is forwarded
verbatim to each child invocation. Conditional appends use the `if ... then
... fi` form (rather than `[[ ]] && cmd`) so that a false predicate at the
end of the function does not cause the function to return 1 — which under
`set -e` would otherwise abort the orchestrator before any module runs.

---

## 4. Cross-cutting concerns

### 4.1 Date handling

A single `build_date_list` (in `lib/date_utils.sh`) is the source of truth.
Priority order:

1. `--date YYYY-MM-DD` — single day.
2. `--from YYYY-MM-DD --to YYYY-MM-DD` — inclusive range.
3. `--days N` — last N days ending today (default `N=7`).

All dates are validated via `date -d`; an invalid input aborts with `die`.

### 4.2 Logging

`lib/common.sh` exposes `log_debug` / `log_info` / `log_warn` / `log_error`
honouring `LOG_LEVEL`. All logs go to **stderr** so the report itself can be
safely piped to a file or tool. Colour is auto-disabled when stdout is not a
TTY or `NO_COLOR=1` is set.

### 4.3 Temp file management

`init_tmpdir` creates `${TMPDIR:-/tmp}/log_analyze.XXXXXX` and installs a
trap on `EXIT INT TERM` to remove it. All intermediate files (per-server
combined logs, per-region join inputs, restart event TSVs) live there.

### 4.4 Error handling

- `set -euo pipefail` in every executable script.
- Required arguments validated up-front; missing `--log-dir` aborts.
- Missing per-server directories are demoted to `log_warn` (per-server
  graceful skip) rather than fatal — one region's outage should not block
  the other region's analysis.
- Empty date data is reported (`無資料` / `No data`) but not treated as an
  error.

### 4.5 Performance characteristics

- Disk I/O is the dominant cost. The two-pass awk join runs at roughly
  100k rows/sec on commodity hardware.
- Memory is bounded by the **unique-token cardinality**, not by row count
  (the API hash size). For one day across both regions this is in the
  thousands.
- The orchestrator runs modules sequentially. Adding parallelism would
  require independent `WORK_TMPDIR`s per child and is currently not
  warranted at the observed scale.

---

## 5. Extensibility

### 5.1 Adding a region
Append to `conf/regions.conf` — no code change required. The new region
appears in all reports automatically.

### 5.2 Adding a new analyser
1. Create `bin/analyze_<name>.sh` following the existing `parse_args` /
   `load_regions` / `main` skeleton.
2. Add `<name>` to the `valid_modules` array in `bin/log_report.sh`.
3. Add a row to the module table in this document and in `usage.md`.
4. Add a section to `tests/run_tests.sh`.

### 5.3 Changing the access-CSV schema
Update column indices in `lib/csv_utils.sh` (`extract_api_records`,
`extract_app_records`) and the documented field table in §3.1.2. Run the
test suite to confirm baselines still hold (or update them deliberately).

---

## 6. Known limitations

- IIS time field is treated as UTC; reports do not localise.
- The error-pattern grouper is heuristic — it will collapse messages that
  differ only by numeric IDs / timestamps, which is correct most of the
  time but loses fidelity for error families distinguished by string state.
- Restart pairing assumes events arrive in chronological order; if logs are
  rotated mid-event this can produce a false `UNMATCHED`.
- Only Linux/WSL is supported; macOS requires `gdate` aliasing.
