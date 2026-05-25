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

| Flags supplied                  | Effective range                          |
|---------------------------------|------------------------------------------|
| `--date 2026-05-21`             | 2026-05-21 only                          |
| `--from 2026-05-18 --to 2026-05-25` | 2026-05-18 → 2026-05-25 (8 days)     |
| `--from 2026-05-20` (no `--to`) | 2026-05-20 → today                       |
| `--to 2026-05-22` (no `--from`) | (today − default days) → 2026-05-22      |
| `--days 3`                      | last 3 days ending today                 |
| *(none)*                        | last 7 days ending today                 |

---

## 1. `bin/analyze_access.sh`

Cross-correlate API ↔ APP access logs to surface NORMAL / ORPHAN /
UNVERIFIED tokens.

### Options

| Flag                       | Default | Description                                                  |
|----------------------------|---------|--------------------------------------------------------------|
| `--log-dir PATH`           | —       | **Required.** Root log directory.                            |
| `--days N`                 | `7`     | Analyse the last N days ending today.                        |
| `--from YYYY-MM-DD`        | —       | Start date (inclusive).                                      |
| `--to YYYY-MM-DD`          | —       | End date (inclusive).                                        |
| `--date YYYY-MM-DD`        | —       | Single-day analysis.                                         |
| `--region taipei\|taichung\|all` | `all` | Region filter.                                            |
| `--output FILE`            | stdout  | Write report to file (also echoes to stdout).                |
| `--format text\|tsv`       | `text`  | `text` = human-readable; `tsv` = machine-readable.           |
| `--conf FILE`              | `conf/regions.conf` | Override region mapping.                          |
| `-v`, `--verbose`          | off     | Enable DEBUG-level logging.                                  |
| `-h`, `--help`             | —       | Show help and exit 0.                                        |

### Examples

```bash
# 1. Last 7 days, all regions, default text output
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. Specific date, Taipei only
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei

# 3. Week-long date range, Taichung only, write to file
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taichung \
    --output ./reports/access_taichung_w21.txt

# 4. TSV output for downstream ingestion (e.g. into a SIEM)
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-21 --to 2026-05-25 --format tsv \
    --output ./reports/access_w21.tsv

# 5. Verbose debug logging
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 -v

# 6. Custom region mapping
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
    NORMAL  (正常流程)                    1
    ORPHAN  (APP無對應API)                5
    UNVERIFIED (API未被使用)              0

    ■ 正常流程 (NORMAL) — API 簽發後由 APP 驗證
    2026-05-21 10:48:18.802     2026-05-21 10:48:23.624     4.8s  OK  HOSP:1234567890  CLIENT:192.168.139.110

    驗證筆數 (有效時間差)                    1
    平均 API→APP 時間差                  4.8s

    ■ 非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token
    2026-05-21 15:19:53.610  APP:10.21.3.35  VERIFY:OK  HOSP:-  PATIENT:2EDEBACB75D9FA54...
    ...
    ORPHAN 驗證結果                         5 (成功) / 0 (失敗)
    >> [WARN] 存在可能來自其他區域或重播的有效 Token
```

> Full sample preserved in [`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt).

---

## 2. `bin/analyze_iis.sh`

Analyse IIS W3C extended logs for request volume, status distribution,
slow requests, and health-check 503 anomalies.

### Options

| Flag                 | Default | Description                                                |
|----------------------|---------|------------------------------------------------------------|
| `--log-dir PATH`     | —       | **Required.** Root log directory.                          |
| `--days N`           | `7`     | Analyse the last N days ending today.                      |
| `--from YYYY-MM-DD`  | —       | Start date (inclusive).                                    |
| `--to YYYY-MM-DD`    | —       | End date (inclusive).                                      |
| `--date YYYY-MM-DD`  | —       | Single-day analysis.                                       |
| `--region`           | `all`   | `taipei` / `taichung` / `all`.                             |
| `--slow-ms N`        | `5000`  | Slow-request threshold in milliseconds.                    |
| `--output FILE`      | stdout  | Write report to file.                                      |
| `--conf FILE`        | `conf/regions.conf` | Override region mapping.                       |
| `-v`, `--verbose`    | off     | Enable DEBUG logging.                                      |
| `-h`, `--help`       | —       | Show help and exit 0.                                      |

### Examples

```bash
# 1. Default 7-day rollup for all servers
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. Single-day performance audit with a tighter slow threshold (3s)
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --slow-ms 3000

# 3. Per-region weekly summary
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 4. Save full report
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/iis_2026-05-21.txt
```

### Sample output

```
▶ IIS — Server: 10.22.63.37
  Total requests                          483
  Unique client IPs                       3
  302 Redirects                           0
  5xx errors                              0
    Health 503                            0
  Slow (>5000ms)                          0

    Status     Count
    --------------------
    200        480
    204        3

    Count  Endpoint
    -------------------------------------------------------------------
    472    /health
    11     /api/GetLungCancerReportURL

    Count  Client IP          % of total
    ------------------------------------------
    472    192.168.139.28      97.7%
    6      192.168.139.110      1.2%
    5      10.22.63.37          1.0%
```

The trailing **client-IP roster** lists every distinct client IP that
issued at least one request, ranked by request count, with the share of
total traffic. Useful for spotting health-checker dominance, scanner
bursts, or unexpected client identities.

> Full multi-server sample in [`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt) (Taipei) and [`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt) (Taichung — exhibits 50 Health-503 events from the simulated OracleDB outage).

---

## 3. `bin/analyze_errors.sh`

Analyse application error logs and lifecycle events.

### Options

| Flag                 | Default | Description                                                |
|----------------------|---------|------------------------------------------------------------|
| `--log-dir PATH`     | —       | **Required.** Root log directory.                          |
| `--days N`           | `7`     | Analyse the last N days ending today.                      |
| `--from YYYY-MM-DD`  | —       | Start date (inclusive).                                    |
| `--to YYYY-MM-DD`    | —       | End date (inclusive).                                      |
| `--date YYYY-MM-DD`  | —       | Single-day analysis.                                       |
| `--region`           | `all`   | `taipei` / `taichung` / `all`.                             |
| `--top N`            | `10`    | Show top-N error patterns.                                 |
| `--output FILE`      | stdout  | Write report to file.                                      |
| `--conf FILE`        | `conf/regions.conf` | Override region mapping.                       |
| `-v`, `--verbose`    | off     | Enable DEBUG logging.                                      |
| `-h`, `--help`       | —       | Show help and exit 0.                                      |

### Examples

```bash
# 1. Default 7-day error rollup
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. Taichung DB troubleshooting — show top 20 patterns
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --date 2026-05-21 --top 20

# 3. Restart audit for a date range
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 4. Quick top-3 sanity check
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

| Flag                       | Default                  | Description                                              |
|----------------------------|--------------------------|----------------------------------------------------------|
| `--log-dir PATH`           | —                        | **Required.** Root log directory.                        |
| `--days N`                 | `7`                      | Last N days ending today.                                |
| `--from YYYY-MM-DD`        | —                        | Start date.                                              |
| `--to YYYY-MM-DD`          | —                        | End date.                                                |
| `--date YYYY-MM-DD`        | —                        | Single-day analysis.                                     |
| `--region`                 | `all`                    | `taipei` / `taichung` / `all`.                           |
| `--modules LIST`           | `access,iis,errors`      | Comma-separated subset of modules to run.                |
| `--output FILE`            | stdout                   | Write **combined** report to a single file.              |
| `--output-dir DIR`         | —                        | Write **each module** to its own file in DIR.            |
| `--conf FILE`              | `conf/regions.conf`      | Override region mapping.                                 |
| `-v`, `--verbose`          | off                      | Forwards `--verbose` to all child modules.               |
| `-h`, `--help`             | —                        | Show help and exit 0.                                    |

### Examples

```bash
# 1. Full daily report — all modules, all regions, single date
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. Access-only quick check for Taipei over 3 days
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access --region taipei --days 3

# 3. Combined report to a single file
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/daily_2026-05-21.txt

# 4. Weekly digest — each module in its own file with timestamp
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports/weekly

# Produces (filenames include a fresh timestamp):
#   ./reports/weekly/analyze_access_20260525_140312.txt
#   ./reports/weekly/analyze_iis_20260525_140312.txt
#   ./reports/weekly/analyze_errors_20260525_140312.txt

# 5. Errors only, debug
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules errors --region taichung -v

# 6. Invalid module is caught early
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access,unknown
#   → Unknown module: 'unknown' (valid: access iis errors)
#     exits with code 1
```

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

### 5.5 Performance audit (slow requests > 3 s, all servers, all regions)
```bash
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-ms 3000
```

### 5.6 Machine-readable pipeline (TSV → grep → wc)
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-21 --to 2026-05-25 --format tsv \
| awk -F'\t' '$2 == "ORPHAN" { print $1 "\t" $11 "\t" $14 }' \
| sort -u
```

---

## 6. Exit codes

| Code | Meaning                                                        |
|------|----------------------------------------------------------------|
| 0    | Success (even when no data was found for the requested period). |
| 1    | Usage / validation error (missing `--log-dir`, bad date format, unknown region or module, missing region config file). |

---

## 7. Environment variables

| Variable    | Effect                                                          |
|-------------|-----------------------------------------------------------------|
| `LOG_LEVEL` | `DEBUG` / `INFO` (default) / `WARN` / `ERROR`. Overridden by `-v`. |
| `NO_COLOR`  | When set, disables ANSI colour codes in all output.             |
| `TMPDIR`    | Base directory for temp files (`mktemp -d`). Defaults to `/tmp`.|
