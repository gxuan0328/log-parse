# log-parse — CLI Usage Reference

> Every flag for every command, with copy-pasteable examples.
> For architecture and field semantics see [`design.md`](design.md).
> **Language**: **English** · [繁體中文](usage.zh-TW.md)

---

## Conventions

- `LOG_DIR` is always the root that contains the six per-server directories
  (e.g. `examples/sample-logs/LUNG-CANCER-REPORT-LOG/10.22.63.37/...`).
- Dates are `YYYY-MM-DD`. Date range is inclusive on both ends.
- Region values: `taipei`, `taichung`, `all` (default).
- All scripts use exit code `0` for success, `1` for usage / validation
  failures.

### Date selection priority

When multiple date flags are given, the precedence is **`--date` > `--from`/`--to` > `--days`**.

| Flags supplied                      | Effective range                          |
|-------------------------------------|------------------------------------------|
| `--date 2026-05-21`                 | 2026-05-21 only                          |
| `--from 2026-05-18 --to 2026-05-25` | 2026-05-18 → 2026-05-25 (8 days)        |
| `--from 2026-05-20` (no `--to`)     | 2026-05-20 → today                       |
| `--to 2026-05-22` (no `--from`)     | (today − default days) → 2026-05-22      |
| `--days 3`                          | last 3 days ending today                 |
| *(none)*                            | last 7 days ending today                 |

### Renamed and removed flags

| Old flag | Status | Replacement | Notes |
|---|---|---|---|
| `--slow-ms N` (iis) | **Removed** | `--slow-api-ms N` · `--slow-app-ms N` | Split by server role. API default 2000 ms, APP default 5000 ms. Passing the old flag exits with `Unknown option`. |
| `--format text\|tsv` (access) | **Extended** | `--format text\|tsv\|csv` | `csv` added (RFC-4180 conditional quoting). Now accepted by all four scripts; iis and errors always emit text and log a notice for non-`text` values. |
| `--top N` (errors only) | **Unified** | `--top N` (iis + errors) | `0` now means ALL (endpoints, client IPs, error patterns). Previously `0` produced zero rows in errors. |

---

## 1. `bin/analyze_access.sh`

Cross-correlate API ↔ APP access logs to surface NORMAL / ORPHAN /
UNVERIFIED tokens.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Ignored when `--date` or `--from` is set. |
| `--from YYYY-MM-DD` | date | — | no | Start of inclusive range. Pair with `--to`. |
| `--to YYYY-MM-DD` | date | — | no | End of inclusive range. Pair with `--from`. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. Overrides `--days` and range. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--merge` | flag | off | no | Cross-region correlation in one combined block. **Requires `--region all`** (explicit or default); otherwise exits with an error. |
| `--format text\|tsv\|csv` | enum | `text` | no | `text` = human-readable; `tsv` = tab-separated flat file; `csv` = RFC-4180 comma-separated. |
| `--output FILE` | path | stdout | no | Write report to file. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Examples

```bash
# 1. Last 7 days, all regions, default text output
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. Single date, Taipei only
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei

# 3. Week range, CSV output for downstream ingestion
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
    --output ./reports/access_w21.csv

# 4. TSV flat file output
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format tsv \
    --output ./reports/access_w21.tsv

# 5. Cross-region merged correlation (all servers in one pass)
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge

# 6. Week range, Taichung only, write to file
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taichung \
    --output ./reports/access_taichung_w21.txt

# 7. Custom region mapping
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --conf ./conf/regions.staging.conf
```

### Sample output (text)

```
========================================================================
  Access Log Cross-Correlation Report
========================================================================
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  Region filter                           taipei

▶ Region: 台北  (10.22.63.37 → 10.21.3.35,10.21.3.36)
------------------------------------------------------------------------
  Total correlation records               6
    NORMAL  (正常流程)                1
    ORPHAN  (APP無對應API)             5
    UNVERIFIED (API未被使用)          0

    ■ 正常流程 (NORMAL) — API 簽發後由 APP 驗證
    API_TIME                 APP_TIME                 DELTA     VERIFY   REQUEST_ID     API_SRV          APP_SRV          HOSP_ID       PRSN_ID       CLIENT_IP         PATIENT_ID_AES
    2026-05-21 10:48:18.802  2026-05-21 10:48:23.624  4.8s      OK       4000000a-0001-fb00-b63f-84710c7967bb  10.22.63.37      10.21.3.35       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E

    驗證筆數 (有效時間差)                            1
    平均 API→APP 時間差                          4.8s
    最短時間差                                   4.8s
    最長時間差                                   4.8s


    ■ 非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token
    APP_TIME                 VERIFY   REQUEST_ID     APP_SRV          HOSP_ID       PRSN_ID       CLIENT_IP         PATIENT_ID_AES
    2026-05-21 15:16:35.342  OK       40000336-0003-ff00-b63f-84710c7967bb  10.21.3.36       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 15:19:53.610  OK       400001ce-0007-fd00-b63f-84710c7967bb  10.21.3.35       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 15:28:17.947  OK       40000092-0005-fe00-b63f-84710c7967bb  10.21.3.36       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 17:12:53.004  OK       40000216-0001-fe00-b63f-84710c7967bb  10.21.3.35       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E
    2026-05-21 17:14:43.624  OK       400000a6-0005-fe00-b63f-84710c7967bb  10.21.3.36       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E

    ORPHAN 驗證結果                             5 (成功) / 0 (失敗)
    >> [WARN] 存在可能來自其他區域或重播的有效 Token
```

Each category shows only its relevant columns; `PATIENT_ID_AES` is always the
trailing column and is never truncated. Records within each category are sorted
chronologically ascending by the category's leading time key (NORMAL and
UNVERIFIED by `API_TIME`; ORPHAN by `APP_TIME`).

> Full sample preserved in [`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt).

### Flat output (tsv / csv)

Both formats emit one record per correlation result across 13 tab- or
comma-separated columns in this order:

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

`csv` uses RFC-4180 conditional quoting: only fields that contain `"`, `,`, or
a newline are quoted; internal `"` characters are doubled. A header row is
always the first line.

> Samples: [`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

---

## 2. `bin/analyze_iis.sh`

Analyse IIS W3C extended logs for request volume, status distribution,
slow requests, and health-check 503 anomalies.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Ignored when `--date` or `--from` is set. |
| `--from YYYY-MM-DD` | date | — | no | Start of inclusive range. Pair with `--to`. |
| `--to YYYY-MM-DD` | date | — | no | End of inclusive range. Pair with `--from`. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. Overrides `--days` and range. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--top N` | uint ≥ 0 | `10` | no | Rows shown in the Endpoint table **and** Client-IP table per server block. `0` = ALL. |
| `--slow-api-ms N` | uint ms | `2000` | no | Slow-request threshold for API-role servers. |
| `--slow-app-ms N` | uint ms | `5000` | no | Slow-request threshold for APP-role servers. |
| `--merge` | flag | off | no | Cross-region host merge; renders one API-servers block and one APP-servers block. **Requires `--region all`**. |
| `--format text\|tsv\|csv` | enum | `text` | no | Accepted by the parser; iis always emits text. A non-`text` value logs a notice and continues. |
| `--output FILE` | path | stdout | no | Write report to file. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Examples

```bash
# 1. Daily health check, all regions, default per-role slow thresholds
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. Weekly audit, tighten API SLA to 1 s, show ALL endpoints
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0

# 3. Host-agnostic merged view (API vs APP buckets), all regions
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge

# 4. Taipei only, top 5 endpoints and client IPs
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei --top 5

# 5. Save full report
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/iis_2026-05-21.txt
```

### Sample output (text)

```
▶ IIS — 10.22.63.37
------------------------------------------------------------------------
  Total requests                          483
  Unique client IPs                       3
  302 Redirects                           0
  5xx errors                              0
    Health 503                            0
  Slow (>2000ms)                          0

    Status      Count     % of total
    --------------------------------
    200         480        99.4%
    204         3           0.6%

    Endpoint                                                 Avg(s)    Count     % of total
    ---------------------------------------------------------------------------------------
    /health                                                  0.06      472        97.7%
    /api/GetLungCancerReportURL                              0.10      11          2.3%

    Client IP           Count     % of total
    ----------------------------------------
    192.168.139.28      472        97.7%
    192.168.139.110     6           1.2%
    10.22.63.37         5           1.0%
```

The **Endpoint** table columns are: Endpoint, Avg(s) (mean response time in
seconds rounded to 2 decimals; IIS logs `time-taken` in milliseconds), Count,
and % of total. The **Status** table adds `% of total` for each HTTP status
code. Both tables are sorted count-descending. Rows in the Endpoint and
Client-IP tables are capped by `--top` (default 10); `--top 0` shows all.

Each API-role server block labels its slow threshold `Slow (>2000ms)` and each
APP-role server block labels its slow threshold `Slow (>5000ms)` unless
overridden with `--slow-api-ms` / `--slow-app-ms`. `/health` requests are
always excluded from the slow count.

> Full multi-server sample: [`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt) (Taipei) and [`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt) (Taichung — exhibits 50 Health-503 events from the simulated OracleDB outage).

---

## 3. `bin/analyze_errors.sh`

Analyse application error logs and lifecycle events.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Ignored when `--date` or `--from` is set. |
| `--from YYYY-MM-DD` | date | — | no | Start of inclusive range. Pair with `--to`. |
| `--to YYYY-MM-DD` | date | — | no | End of inclusive range. Pair with `--from`. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. Overrides `--days` and range. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--top N` | uint ≥ 0 | `10` | no | Error pattern rows to show. `0` = ALL patterns. |
| `--format text\|tsv\|csv` | enum | `text` | no | Accepted by the parser; errors always emits text. A non-`text` value logs a notice and continues. |
| `--output FILE` | path | stdout | no | Write report to file. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Examples

```bash
# 1. Default 7-day error rollup
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. Taichung DB troubleshooting — show top 20 patterns
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --date 2026-05-21 --top 20

# 3. Show ALL error patterns (no limit)
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --top 0

# 4. Restart audit for a date range
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 5. Quick top-3 sanity check
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --top 3
```

### Sample output

```
▶ App Errors — Server: 10.1.72.35
------------------------------------------------------------------------
  Total ERROR entries                     16
  OracleDB health failures                15
    首次 OracleDB 失敗時間:
      2026-05-21 00:10:40.3560
      2026-05-21 00:33:32.0321
      2026-05-21 04:28:16.8366

    Top Error Patterns:
    Count  Message
    --------------------------------------------------------------------
    15     Health check 正式_OracleDB with status Unhealthy completed after 37935.4919ms with
    1      系統在處理請求時發生未預期例外：A task was canceled.

    ■ 應用程式重啟事件
  Restart count                           4

    Shutdown Time                 Started Time                  Downtime
    ------------------------------------------------------------------------
    2026-05-21 08:14:08.221       2026-05-21 08:15:01.992       53s
```

> Aggregated across all three Taichung servers, baseline figures are
> ERROR=46, OracleDB=44, Restart=9 (verified by `tests/run_tests.sh`
> sections C06/C07). Full sample in
> [`../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt`](../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt).

---

## 4. `bin/log_report.sh`

Orchestrator that runs `analyze_access`, `analyze_iis`, and `analyze_errors`
in sequence.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Ignored when `--date` or `--from` is set. |
| `--from YYYY-MM-DD` | date | — | no | Start of inclusive range. Pair with `--to`. |
| `--to YYYY-MM-DD` | date | — | no | End of inclusive range. Pair with `--from`. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. Overrides `--days` and range. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. Forwarded to all modules. |
| `--modules LIST` | csv | `access,iis,errors` | no | Comma-separated subset of modules to run. |
| `--top N` | uint ≥ 0 | `10` | no | Forwarded to iis (Endpoint + Client-IP cap) and errors (pattern cap). `0` = ALL. |
| `--slow-api-ms N` | uint ms | `2000` | no | Forwarded to iis only; API-role slow threshold. |
| `--slow-app-ms N` | uint ms | `5000` | no | Forwarded to iis only; APP-role slow threshold. |
| `--merge` | flag | off | no | Forwarded to access and iis. **Requires `--region all`**. |
| `--format text\|tsv\|csv` | enum | `text` | no | Forwarded to all modules. access renders tsv/csv; iis/errors always emit text and log a notice. |
| `--output FILE` | path | stdout | no | Write combined report to a single file. |
| `--output-dir DIR` | path | — | no | Write each module to its own timestamped file in DIR. |
| `--conf FILE` | path | — | no | Override region mapping. Forwarded to all modules when supplied; validated only when explicitly set. |
| `-v`, `--verbose` | flag | off | no | Forwards `--verbose` to all child modules. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Flag forwarding matrix

| Flag | access | iis | errors |
|---|:---:|:---:|:---:|
| `--log-dir`, `--region`, `--days`, `--from`, `--to`, `--date`, `--verbose`, `--conf` | F | F | F |
| `--format` | F | F (no-op, notice) | F (no-op, notice) |
| `--top` | — | F | F |
| `--slow-api-ms` | — | F | — |
| `--slow-app-ms` | — | F | — |
| `--merge` | F | F | — |
| `--output`, `--output-dir`, `--modules` | own | own | own |

F = forwarded and acted upon by the child module (or accepted with a notice for iis/errors non-`text` format).

### Examples

```bash
# 1. Full daily report — all modules, all regions, single date
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. Access-only quick check for Taipei over 3 days
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access --region taipei --days 3

# 3. Merged ops review — access + iis cross-region, top 5
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5

# 4. CSV export (access renders csv; iis + errors emit text with a notice)
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
    --output ./reports/week_access.csv

# 5. Per-role slow audit — tighten API to 3 s, keep APP at default 5 s
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --slow-api-ms 3000

# 6. Combined report to a single file
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/daily_2026-05-21.txt

# 7. Weekly digest — each module in its own file with timestamp
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports/weekly

# Produces (filenames include a fresh timestamp):
#   ./reports/weekly/analyze_access_20260525_140312.txt
#   ./reports/weekly/analyze_iis_20260525_140312.txt
#   ./reports/weekly/analyze_errors_20260525_140312.txt

# 8. Errors only, debug
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules errors --region taichung -v

# 9. Invalid module is caught early
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access,unknown
#   → Unknown module: 'unknown' (valid: access iis errors)
#     exits with code 1
```

> Full combined sample in [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt).

---

## 5. Scenario playbook

End-to-end commands matching the user scenarios in the test suite.

### 5.1 Daily ops snapshot
```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date $(date +%F)
```

### 5.2 Security investigation (orphan tokens, last week, Taipei)
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7 \
    --output ./reports/security_$(date +%F).txt
```

### 5.3 DB outage triage (Taichung, last 24 h, top 20 patterns)
```bash
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --days 1 --top 20
```

### 5.4 Weekly digest (Mon–Sun) to disk
```bash
START=$(date -d 'last monday' +%F)
END=$(date -d 'last sunday' +%F)
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from "$START" --to "$END" --output-dir ./reports/weekly
```

### 5.5 Per-role slow audit (API ≤ 1 s, APP ≤ 3 s, all servers)
```bash
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 1000 --slow-app-ms 3000
```

### 5.6 Merged ops review — cross-region correlation + IIS two-bucket split
```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5
```

### 5.7 Machine-readable CSV pipeline (ORPHAN CLIENT_IP + PATIENT_ID_AES)
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
| awk -F',' '$2 == "ORPHAN" { print $12 "," $13 }' \
| sort -u
```

TSV/CSV column reference (13 fields in order):
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)`.

---

## 6. Exit codes

| Code | Meaning                                                        |
|------|----------------------------------------------------------------|
| 0    | Success (even when no data was found for the requested period). |
| 1    | Usage / validation error (missing `--log-dir`, bad flag value, unknown region or module, missing region config file, `--merge` without `--region all`). |

---

## 7. Environment variables

| Variable    | Effect                                                          |
|-------------|-----------------------------------------------------------------|
| `LOG_LEVEL` | `DEBUG` / `INFO` (default) / `WARN` / `ERROR`. Overridden by `-v`. |
| `NO_COLOR`  | When set, disables ANSI colour codes in all output.             |
| `TMPDIR`    | Base directory for temp files (`mktemp -d`). Defaults to `/tmp`.|
