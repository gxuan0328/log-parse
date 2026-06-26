# log-parse — Design Specification

> Version 1.0 · 2026-05-25 · Audience: developers, SREs, on-call engineers.
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

#### 3.1.7 Text output — per-category columns

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

#### 3.1.8 Machine-readable output — `tsv` and `csv`

Both formats are flat outputs over `result_sorted` (same deterministic order
as text, §3.1.6). Each row is prefixed with a `REGION` column (region name,
or `merged` under `--merge`). The 13-column schema:

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

- **`--format tsv`** — TAB delimiter, no quoting.
- **`--format csv`** — comma delimiter, RFC-4180 conditional quoting: a field
  is quoted only when it contains `"`, `,`, or a newline; embedded `"`
  characters are doubled. LF line endings. Fields with none of these characters
  appear unquoted.

A header row is emitted once at the top of each output (TAB-joined for tsv,
comma-joined for csv). Both formats share the byte-stable ordering from §3.1.6.

#### 3.1.9 `--merge` semantics

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

#### 3.2.5 Output sections

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
per-record chronological detail list, so the deterministic ASC sort introduced
for `analyze_access` does not apply here.

#### 3.2.6 Per-role slow thresholds

`--slow-api-ms` (default 2000 ms) applies to servers listed in `REGION_APIS`;
`--slow-app-ms` (default 5000 ms) applies to servers in `REGION_APPS`. Role
membership is resolved via `conf/regions.conf`. The defaults reflect the
tighter SLA expected of API token-issuance endpoints versus APP DICOM-serving
endpoints. The `Slow (>Nms)` label in the report shows the actual threshold
used for that server's role.

#### 3.2.7 `--top` flag

Controls the maximum number of rows shown in both the Endpoint table and the
Client IP table (default 10; 0=all). The same cap applies to both tables in
the same invocation. The flag is unified across `analyze_iis` and
`analyze_errors` (same name, same 0=all semantics, different target list).

#### 3.2.8 `--merge` — two-bucket cross-region corpus

Under `--merge`, `analyze_merged_iis` builds two corpora by iterating over all
configured regions:

- **API corpus**: concatenates IIS logs from every region's `REGION_APIS` servers.
- **APP corpus**: concatenates IIS logs from every region's `REGION_APPS` servers.

The shared `render_iis_stats LABEL COMBINED THRESHOLD` helper runs IIS_AWK
once on the combined log file, emits the KV summary block, and emits the three
reordered tables (§3.2.5). Both `analyze_server_iis` (non-merged, per-server)
and `analyze_merged_iis` (merged, two-bucket) delegate to this helper; the
caller owns the `fmt_h2` section label.

`render_iis_stats` is invoked once per corpus, producing two output blocks:
1. `IIS — API_SERVERS (merged, all regions)` — uses `--slow-api-ms` threshold.
2. `IIS — APP_SERVERS (merged, all regions)` — uses `--slow-app-ms` threshold.

Each block contains the identical KV summary and three ranked tables as the
per-server non-merged path, with the role-resolved `Slow (>Nms)` label.

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

`build_module_args()` builds a per-module `_MOD_ARGS` array forwarded verbatim
to each child invocation. Conditional appends use the `if ... then ... fi`
form (rather than `[[ ]] && cmd`) so that a false predicate at the end of the
function does not cause the function to return 1 — which under `set -e` would
otherwise abort the orchestrator before any module runs.

The function is **module-aware**: common flags (`--log-dir`, `--region`,
`--days`/`--date`/`--from`/`--to`, `--conf`, `--verbose`, `--format`) are
appended for every module; flags that apply only to specific modules are
appended inside a `case "$module"` block:

- `analyze_access` receives `--merge` (when set).
- `analyze_iis` receives `--top`, `--slow-api-ms`, `--slow-app-ms`, and
  `--merge` (when set).
- `analyze_errors` receives `--top`.

`--conf` is appended only when explicitly supplied by the caller (`REGIONS_CONF`
non-empty). When `--conf` is omitted, each child module resolves its own
default (`conf/regions.conf`). log_report validates `--conf` only when the
flag is explicitly supplied; it does not validate the children's default.

`--format` is forwarded to every child. Modules that do not render tsv/csv
(`analyze_iis`, `analyze_errors`) accept the flag, emit a one-line warning,
and continue in text mode — so `--format csv` from log_report reaches
`analyze_access` (which renders csv) while iis and errors stay text without
aborting.

#### 3.4.5 Option forwarding matrix

| Flag | log_report | access | iis | errors | Notes |
|---|---|---|---|---|---|
| `--log-dir` | own | F | F | F | required |
| `--region` | own | F | F | F | gates `--merge` |
| `--days` / `--date` / `--from` / `--to` | own | F | F | F | |
| `--conf` | own (validates only when supplied) | F | F | F | |
| `--output` / `--output-dir` / `--modules` | own | — | — | — | orchestrator-only |
| `--verbose` | own | F | F | F | |
| `--format` | F→all | renders tsv/csv | no-op+warn | no-op+warn | |
| `--top` | F→{iis,errors} | — | Endpoint+Client-IP | pattern count | 0=ALL |
| `--slow-api-ms` | F→iis | — | API-role servers | — | default 2000 ms |
| `--slow-app-ms` | F→iis | — | APP-role servers | — | default 5000 ms |
| `--merge` | F→{access,iis} | cross-region | two-bucket | — | requires `--region all` |

Legend: `own` = log_report acts on this flag itself · `F` = forwarded to child ·
`—` = not accepted by that module (unknown option → `die`).

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

### 4.6 CJK-aware rendering

KV rows and stat blocks are padded by **display width** (wcwidth: CJK ideographs = 2 columns) via the `FMT_AWK_WIDTH` engine in `lib/fmt_utils.sh`, so CJK and ASCII labels align correctly in the terminal.

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
