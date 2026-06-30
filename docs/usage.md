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

### Interval selection — choose exactly one

All five CLIs enforce **mutual exclusion** on date selectors: supplying
more than one explicit selector causes the script to abort with:

```
interval flags are mutually exclusive
  (priority --date > --from/--to > --today > --days): choose exactly ONE (got N)
```

The priority ranking in the message shows the canonical order; the
runtime behavior is always abort-on-conflict, not silent resolution.

| Flag(s) | Effective range |
|---------|-----------------|
| `--date 2026-05-21` | 2026-05-21 only |
| `--today` | today only (alias for `--date <today>`) |
| `--from 2026-05-18 --to 2026-05-25` | 2026-05-18 → 2026-05-25 (8 days) |
| `--days 3` | last 3 days ending today |
| *(none)* | last 7 days ending today (implicit `--days 7` fallback) |

`--from` and `--to` must always be supplied as a pair; `--from` without
`--to` (or vice versa) also aborts.

### Always-on persistence

Every run automatically writes report files to the **output directory**
(not just to stdout). Default directory: `./log-parse` (created if
absent). Override with `--output-dir DIR` or the `LOG_PARSE_OUTPUT_DIR`
environment variable. Precedence: `--output-dir` flag > `$LOG_PARSE_OUTPUT_DIR`
> `./log-parse`.

File naming convention: `<module>_<kind>_<TS>.<ext>` where:
- `<kind>` is `summary` or `detail`
- `<TS>` is a shared `YYYYmmdd_HHMMSS` launch timestamp (all files of
  one run share the same suffix)
- `<ext>` is `txt` for summary (always) and `txt`/`tsv`/`csv` for
  detail (follows `--format`)

Persisted files are always color-free. The `--view` flag controls only
the console mirror (which view streams to stdout); both files are always
written. Add `/log-parse/` to `.gitignore` to avoid committing run
artifacts.

### Changed and removed flags

| Flag | Status | Notes |
|---|---|---|
| `--output FILE` (all CLIs) | **Removed** | Superseded by always-on directory persistence. Use `--output-dir DIR` to redirect files. |
| `--format text\|tsv` on iis | **Now real** | Previously accepted with a notice; tsv/csv now produce a proper long-format detail table. |
| `--format text\|tsv\|csv` on errors | Accepted (warns) | errors is text-only; non-`text` values log a notice and continue. |
| `--slow-ms N` (iis) | **Removed** | Replaced by `--slow-api-ms N` and `--slow-app-ms N`. |
| `--top N` | **Unified** | Now accepted by iis (endpoints + client IPs) and errors (patterns). `0` = ALL. |
| `--modules LIST` on log_report | **New default** | Default changed from `access,iis,errors` to `overview,iis,access`. errors is opt-in. |

### Test-host filtering

All `analyze_iis` and `analyze_access` runs require **`conf/test_hosts.conf`** — a
plain-text list of internal QA / health-probe client IPs (one IPv4 per line).
The file seeds three addresses: `192.168.139.79`, `192.168.139.110`, and
`192.168.139.28`. A missing file is a fatal error even with `--test-hosts all`
(fail-fast, consistent with `regions.conf`).

The `--test-hosts` flag controls how those IPs are treated at the read stage:

| Value | Behavior |
|---|---|
| `exclude` (default) | Drop records from test-host IPs — reports reflect real external traffic. |
| `only` | Keep **only** records from test-host IPs — audit internal QA / non-health client traffic. |
| `all` | No test-host filtering — include every client IP. |

**Important:** `/health` is excluded from IIS aggregation **unconditionally** (before
the test-host filter runs) in all three modes. Health-probe volume (`192.168.139.28`,
~95% of raw IIS traffic) is therefore **never visible via `--test-hosts`**.
`--test-hosts only` surfaces only the non-health hits of test hosts
(e.g. `192.168.139.110`'s 209 business requests on 2026-05-21) — it is an audit of
internal QA or non-health client traffic, **not** an audit of probe traffic.

`analyze_overview` and `log_report` accept `--test-hosts` and forward it to their
`analyze_iis` and `analyze_access` children. `analyze_errors` does **not** accept
`--test-hosts` (app logs have no client IP field; passing it is a fatal error).

**Total request counts** throughout IIS reports are always **business-only**
(post `/health`-exclusion, post test-host filter). The `資料範圍` line in the
summary and the `Scope` line in the detail banner show the active mode explicitly.

---

## 0. `bin/analyze_overview.sh`

Management overview combining access cross-correlation results and IIS core-function
performance into a single report with two panels:

- **總體概況 (Overall)** — access NORMAL/ORPHAN/UNVERIFIED counts with value + % of 存取關聯總數; average API→APP latency; 整體健康判定 verdict (thresholds: P = trunc(NORMAL ÷ 存取關聯總數 × 100); P ≥ 90 → 正常, 70 ≤ P ≤ 89 → 注意, P < 70 → 警告, total = 0 → 無資料); followed by an ■ 核心功能效能 (Core Function Performance) sub-block with the three IIS-sourced, UTC+8 day-corrected categories — 雲端查詢 (`/api/GetLungCancerReportURL`), 報告摘要 (`/api/DigestSummary` prefix), 影像下載 (`/api/NhiPatientImage/studies/…` prefix) — each row showing 呼叫次數 (count) and 回應時間 (average seconds, 2 dp); plus 核心功能存取合計 (plain count, no percentage). Category counts and averages are accumulated over the full request population (not top-N capped).
- **分區別 (By Region)** — one ■ block per in-scope region, each opening with a prose enumeration `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)` (percentages within that region), followed by the same three core-function categories (呼叫次數 + 回應時間). For a single-region run (e.g. `--region taipei`) the 分區別 block intentionally mirrors 總體概況 — this is the correct ROLLUP+breakdown symmetry, not a double-count.

**IIS date semantics (UTC+8):** `--date D` means the UTC+8 business day D. IIS W3C
logs are timestamped UTC+0; a local day D = UTC `[D-1 16:00, D 16:00)`. The module
reads `u_ex(D-1)` rows ≥ 16:00 UTC and `u_ex(D)` rows < 16:00 UTC to cover the
full local day. If `u_ex(D-1)` is absent the early-morning window is silently
incomplete (fail-soft). Access and .NET app logs are natively UTC+8 and unchanged.

Overview is **summary-only** (no `--view`) and **text-only** (no
`--format`). It sources metrics from `analyze_iis` and `analyze_access`
via `--emit-stats` (DRY — zero re-parse, zero duplicated metric
computation). Only the `overview_summary_<TS>.txt` file is written to
the output directory (no detail file).

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--today` | flag | off | no | Single-day run for today. Mutually exclusive with other interval selectors. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | date pair | — | no | Inclusive date range. Both must be supplied. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Implicit fallback only. |
| `--slow-api-ms N` | uint ms | `2000` | no | Slow-request threshold for API-role servers. Forwarded to the iis spawn only (not to access). Drives the IIS per-server `慢速率` KPI in `analyze_iis` summaries; does **not** affect the overview (核心功能效能 has no 慢速 column). |
| `--slow-app-ms N` | uint ms | `5000` | no | Slow-request threshold for APP-role servers. Forwarded to the iis spawn only. Drives the IIS per-server `慢速率` KPI; does **not** affect the overview. |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | no | Test-host IP filter mode. Forwarded to both `analyze_iis` and `analyze_access` children. See [Test-host filtering](#test-host-filtering). |
| `--output-dir DIR` | path | `""` | no | Persistence directory. Resolved as: flag > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

Flags **not accepted**: `--view`, `--format`, `--merge`, `--top`, `--emit-stats`.

### Examples

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. Daily management overview, all regions
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 2. Today's quick overview
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" --today

# 3. Weekly overview, all regions (default 7-day window)
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25

# 4. Taipei only, with tightened API SLA
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --slow-api-ms 1000

# 5. Write to a custom directory (avoid CWD ./log-parse)
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --output-dir ./reports
```

### Sample output

The sample below shows `--date 2026-05-21`, default `--test-hosts exclude` mode
(all regions). `存取關聯總數` counts business-only access records (test-host IPs
excluded). IIS core-function counts are UTC+8 day-corrected.

```
========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-21  →  2026-05-21  (1 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  存取關聯總數                            9
  NORMAL 正常流程                         6 (66.7%)
  ORPHAN 無對應簽發                       3 (33.3%)
  UNVERIFIED 簽發未使用                   0 (0.0%)
  平均 API→APP 延遲                       19.5s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

    ■ 核心功能效能 (Core Function Performance)
      雲端查詢    呼叫次數 11       回應時間 0.11s
      報告摘要    呼叫次數 186      回應時間 0.38s
      影像下載    呼叫次數 427      回應時間 0.93s
      核心功能存取合計 624

▶ 分區別 (By Region)
------------------------------------------------------------------------

    ■ 台北 (taipei)
      存取關聯 3 筆 — NORMAL 0 (0.0%) · ORPHAN 3 (100.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 5        回應時間 0.02s
      報告摘要    呼叫次數 71       回應時間 0.22s
      影像下載    呼叫次數 220      回應時間 1.48s

    ■ 台中 (taichung)
      存取關聯 6 筆 — NORMAL 6 (100.0%) · ORPHAN 0 (0.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 6        回應時間 0.19s
      報告摘要    呼叫次數 115      回應時間 0.47s
      影像下載    呼叫次數 207      回應時間 0.34s
```

Content rules enforced by the implementation:
- `存取關聯總數` and the NORMAL/ORPHAN/UNVERIFIED counts appear only in the 總體概況 block (not in 分區別).
- 分區別 shows one ■ block per in-scope region with a prose `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)` enumeration (percentages within that region), followed by 呼叫次數 + 回應時間 for each category. The `ORPHAN` and `UNVERIFIED` keywords appear in the prose line only, not as rpad-aligned columns.
- 核心功能效能 rows show 呼叫次數 (count) and 回應時間 (average seconds); there is **no per-row share percentage** and **no speed sub-description** (e.g. no `前端轉跳速度`). There is **no 慢速 column** (per-server `慢速率` remains in `analyze_iis` summaries).
- The 整體健康判定 verdict is always numeric-free. Verdict bands: P = trunc(NORMAL ÷ 存取關聯總數 × 100); P ≥ 90 → 正常, 70 ≤ P ≤ 89 → 注意, P < 70 → 警告, total = 0 → 無資料. On 2026-05-21 all-region: 6/9 → trunc(66.7) = 66 < 70 → 警告.
- Single-region scope (e.g. `--region taipei`): the 分區別 台北 block reproduces the same N/O/U and category figures as 總體概況. This is intentional ROLLUP+breakdown symmetry — not a double-count. The regional label is the meaningful difference.
- An empty analysis window (no data) yields zeros and `N/A` rates; exit code 0.

> Full weekly sample: [`../examples/sample-outputs/overview_all_week.txt`](../examples/sample-outputs/overview_all_week.txt).
> Single-region sample: [`../examples/sample-outputs/overview_taipei_week.txt`](../examples/sample-outputs/overview_taipei_week.txt).

---

## 1. `bin/analyze_access.sh`

Cross-correlate API ↔ APP access logs to surface NORMAL / ORPHAN /
UNVERIFIED tokens.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--today` | flag | off | no | Single-day run for today. Mutually exclusive with other interval selectors. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | date pair | — | no | Inclusive date range. Both must be supplied. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Implicit fallback only. |
| `--view summary\|detail` | enum | `detail` | no | Console view. `summary` = concise management text; `detail` = full per-record tables. Both files are always written regardless. |
| `--format text\|tsv\|csv` | enum | `text` | no | Governs the **detail** file extension and the detail console mirror. Summary is always text. `tsv` = tab-separated; `csv` = RFC-4180. |
| `--merge` | flag | off | no | Cross-region correlation in one combined block. **Requires `--region all`** (explicit or default). |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | no | Test-host client IP filter. `conf/test_hosts.conf` is **always required**, even for `all` mode. See [Test-host filtering](#test-host-filtering). |
| `--output-dir DIR` | path | `""` | no | Persistence directory. Resolved as: flag > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

`--emit-stats` is an internal flag (used by `analyze_overview`); it
prints machine-readable `access_stats.tsv` rows to stdout with no
persistence, no banner, and accepts only the interval / region / conf /
verbose subset of flags.

### Examples

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. Last 7 days, all regions, default detail text output
bash bin/analyze_access.sh --log-dir "$LOG_DIR"

# 2. Single date, Taipei only, management summary view
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --view summary

# 3. Week range, CSV detail for downstream ingestion
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format csv --view detail \
    --output-dir ./reports

# 4. TSV flat-file detail
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format tsv --view detail \
    --output-dir ./reports

# 5. Cross-region merged correlation (all servers in one pass)
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge

# 6. Today's access summary
bash bin/analyze_access.sh --log-dir "$LOG_DIR" --today --view summary

# 7. Custom region mapping
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --conf ./conf/regions.staging.conf

# 8. Audit internal/QA non-health client traffic (test-hosts only mode)
#    NOTE: /health is removed before mode selection; only mode shows non-health
#    hits from test-host IPs (e.g. 192.168.139.110 business requests).
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts only --view summary

# 9. Include all client IPs (no test-host filter)
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts all --view summary
```

### Summary view

```
============ Access Cross-Correlation Summary ============
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  Region filter                           all
  關聯總數                                12
    NORMAL  (正常流程)                    7  (58.3%)
    ORPHAN  (APP無對應API)                5  (41.7%)
    UNVERIFIED (API未被使用)              0  (0.0%)
  ORPHAN 驗證結果                         5 (成功) / 0 (失敗)
  延遲 API→APP                            平均 17.4s · 最短 4.822s · 最長 37.554s

    ■ 分區別 (% within region)
    台北    NORMAL 16.7%     ORPHAN 83.3%     UNVERIFIED 0.0%
    台中    NORMAL 100.0%    ORPHAN 0.0%      UNVERIFIED 0.0%
```

> Full summary sample: [`../examples/sample-outputs/access_summary_all_2026-05-21.txt`](../examples/sample-outputs/access_summary_all_2026-05-21.txt).

### Detail view (text)

The detail view shows per-record tables for each category (NORMAL,
ORPHAN, UNVERIFIED). Each category shows only its relevant columns;
`PATIENT_ID_AES` is always the trailing column and is never truncated.
Records within each category are sorted chronologically ascending.
The NORMAL block footer label is `驗證筆數` (the former `驗證筆數 (有效時間差)` suffix was removed).

```
▶ Region: 台北  (10.22.63.37 → 10.21.3.35,10.21.3.36)
------------------------------------------------------------------------
  Total correlation records               6
    NORMAL  (正常流程)                    1
    ORPHAN  (APP無對應API)                5
    UNVERIFIED (API未被使用)              0
    ...
```

> Full detail sample: [`../examples/sample-outputs/access_detail_all_2026-05-21.txt`](../examples/sample-outputs/access_detail_all_2026-05-21.txt).
> Taipei detail: [`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt).

### Flat output (tsv / csv)

Both formats emit one record per correlation result across 13 tab- or
comma-separated columns in this order:

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

`csv` uses RFC-4180 conditional quoting: only fields containing `"`, `,`, or
a newline are quoted; internal `"` characters are doubled. A header row is
always the first line. The summary file is always `.txt` regardless of
`--format`; only the detail file uses the `.tsv` / `.csv` extension.

> Samples: [`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

---

## 2. `bin/analyze_iis.sh`

Analyse IIS W3C extended logs for **business** request volume, status distribution,
slow requests, and per-endpoint breakdowns. The `/health` endpoint is excluded
unconditionally from all aggregation (totals, endpoints, status mix, slow counts,
unique IPs). Test-host client IPs are pre-filtered per `--test-hosts` mode.
Dependency-health / Oracle-outage detection is handled by `analyze_errors` instead.

**IIS timezone (UTC+0 → UTC+8):** IIS W3C logs are timestamped UTC+0; the reference
timezone (access CSV + .NET app logs) is UTC+8. `--date D` means the UTC+8 business
day D: the module reads `u_ex(D-1)` rows with UTC time ≥ 16:00 and `u_ex(D)` rows
with UTC time < 16:00, covering local midnight through 23:59 (half-open UTC filter
`[D-1 16:00, D 16:00)`, lexicographic string bounds, no `mktime`; single source in
`date_utils.sh` `IIS_UTC_OFFSET_HOURS=8`). If `u_ex(D-1)` does not exist the
early-morning window is silently incomplete (fail-soft). This is architecturally
required even when all business rows happen to have UTC time < 16:00 (as on the
bundled sample). `--from`/`--to` ranges are corrected the same way. Access and
error log analyzers are natively UTC+8 and unchanged.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--today` | flag | off | no | Single-day run for today. Mutually exclusive with other interval selectors. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | date pair | — | no | Inclusive date range. Both must be supplied. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Implicit fallback only. |
| `--view summary\|detail` | enum | `detail` | no | Console view. `summary` = concise management text; `detail` = full per-server tables. Both files always written. |
| `--format text\|tsv\|csv` | enum | `text` | no | Governs the **detail** file extension and the detail console mirror. Summary is always text. `tsv`/`csv` produce a standardized long-format table (see below). |
| `--top N` | uint ≥ 0 | `10` | no | Rows in the Endpoint table and Client-IP table per server. `0` = ALL. Also caps the summary top-endpoint list. |
| `--slow-api-ms N` | uint ms | `2000` | no | Slow-request threshold for API-role servers. |
| `--slow-app-ms N` | uint ms | `5000` | no | Slow-request threshold for APP-role servers. |
| `--merge` | flag | off | no | Cross-region host merge; renders one API-servers block and one APP-servers block. **Requires `--region all`**. |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | no | Test-host client IP filter. `conf/test_hosts.conf` is **always required**, even for `all` mode. See [Test-host filtering](#test-host-filtering). |
| `--output-dir DIR` | path | `""` | no | Persistence directory. Resolved as: flag > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

`--emit-stats` is an internal flag (used by `analyze_overview`).

### Examples

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. Daily health check, all regions, default per-role slow thresholds
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 2. Management summary, all regions, single date
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --view summary

# 3. Weekly audit, tighten API SLA to 1 s, show ALL endpoints
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0

# 4. Weekly detail export as CSV for record-keeping
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --view detail --format csv \
    --output-dir ./reports

# 5. Host-agnostic merged view (API vs APP buckets), all regions
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge

# 6. Taipei only, top 5 endpoints and client IPs, summary
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --top 5 --view summary

# 7. Today's quick IIS summary
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" --today --view summary

# 8. Audit internal/QA non-health client traffic (only mode)
#    Shows the 209 non-/health hits from test-host IPs on 2026-05-21.
#    Health-probe IP 192.168.139.28 never appears — /health is dropped before mode selection.
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts only --view summary

# 9. No test-host filter — all client IPs retained (all mode)
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts all --view summary
```

### Summary view

The `資料範圍` line appears at the top of every summary and states the active
scope. `總請求數` is always **business-only** (post `/health`-exclusion and post
test-host filter).

```
============ IIS Summary — Region: all ============
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  資料範圍                                業務請求 (排除 /health；測試主機=exclude)
  總請求數                                723
  不重複用戶端 IP                         6
  慢速率                                  0.3%  (2)

    ■ Top 端點 (佔比 · 平均回應時間)
     1. /api/NhiPatientImage/studies/{uid}/series/{uid}/...    50.8%   1.05s
     2. /api/DigestSummary/hospital                            21.9%   0.33s
     3. /api/NhiPatientImage/studies/{uid}/series-uid           8.3%   0.18s
    ...

    ■ 狀態碼分布 (Top 3)
      200 87.3% · 404 9.7% · 304 1.8%

    ■ Top 用戶端 IP
      192.168.139.119 98.5% · 10.1.73.37 0.8% · 10.22.63.37 0.7%
```

The **Top 端點** section title is **佔比 · 平均回應時間**. Each row shows rank
(right-aligned `%2d.` so ` 1.`…` 9.` and `10.` keep the URI column at an
identical offset), percentage of the summary `總請求數`, and per-endpoint average
response time in seconds (2 dp).

> **Pooling caveat (GAP-3).** The per-endpoint average is pooled from each
> server's `--top N` emitted rows, not from the full request population for that
> endpoint. This is the same population the count and percentage already report,
> so it is internally consistent. External raw-gawk verification must replicate
> the per-server `--top N` cap before pooling to reproduce the pinned values. By
> contrast, the 核心功能效能 category counts and averages in the overview are
> accumulated over the full request population and are not affected by `--top N`.

The status-code distribution (Top-N) is retained as descriptive business-status
accounting. 302 or 4xx codes may still appear there; that is intentional
(business-only view of actual HTTP responses).

> Full summary sample: [`../examples/sample-outputs/iis_summary_all_2026-05-21.txt`](../examples/sample-outputs/iis_summary_all_2026-05-21.txt).

### Detail view (text)

The detail view shows per-server KV blocks with Status, Endpoint, and
Client-IP percentage tables. API-role servers show `Slow (>2000ms)`;
APP-role servers show `Slow (>5000ms)` unless overridden with
`--slow-api-ms` / `--slow-app-ms`. The `Scope` line at the top of each
server block confirms the active mode. `/health` is excluded from every
count — totals, endpoints, status codes, slow, and client IPs.

```
▶ IIS — 10.22.63.37
------------------------------------------------------------------------
  Scope                                   business requests (excl. /health; test-hosts=exclude)
  Total requests                          5
  Unique client IPs                       1
  Slow (>2000ms)                          0

    Status      Count     % of total
    --------------------------------
    200         5         100.0%

    Endpoint                                                 Avg(s)    Count     % of total
    ---------------------------------------------------------------------------------------
    /api/GetLungCancerReportURL                              0.02      5         100.0%

    Client IP           Count     % of total
    ----------------------------------------
    10.22.63.37         5         100.0%
```

> Full detail sample (all regions): [`../examples/sample-outputs/iis_all_2026-05-21.txt`](../examples/sample-outputs/iis_all_2026-05-21.txt).
> Taipei: [`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt).
> Taichung: [`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt).

### Detail view (tsv / csv)

With `--format tsv` or `--format csv` the detail file/view is a
standardized long-format table. One header line, then one data row per
metric per server:

```
REGION  ROLE  SERVER         METRIC     KEY                      COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37    SUMMARY    TOTAL                    5      -        100.0
taipei  api   10.22.63.37    SUMMARY    SLOW                     0      -        0.0
taipei  api   10.22.63.37    SUMMARY    UNIQUE_IPS               1      -        0.0
taipei  api   10.22.63.37    STATUS     200                      5      -        100.0
taipei  api   10.22.63.37    ENDPOINT   /api/GetLungCancerReportURL  5  0.02     100.0
taipei  api   10.22.63.37    CLIENT_IP  10.22.63.37              5      -        100.0
```

`METRIC` values: `SUMMARY` (totals: `TOTAL`, `SLOW`, `UNIQUE_IPS`), `STATUS` (per
HTTP code), `ENDPOINT` (per URI, capped by `--top`), `CLIENT_IP` (per IP, capped by
`--top`). `/health` rows never appear in the output. The summary view is always text
regardless of `--format` (the summary file is always `.txt`).

> Samples: [`../examples/sample-outputs/iis_detail_all_2026-05-21.tsv`](../examples/sample-outputs/iis_detail_all_2026-05-21.tsv) · [`../examples/sample-outputs/iis_detail_all_2026-05-21.csv`](../examples/sample-outputs/iis_detail_all_2026-05-21.csv)

---

## 3. `bin/analyze_errors.sh`

Analyse application error logs and lifecycle events.

This module has **no `--view` flag**: the console always shows the detail
view, and the summary is written to disk only
(`errors_summary_<TS>.txt`). Both `errors_summary_<TS>.txt` and
`errors_detail_<TS>.txt` are always written to the output directory.

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--region taipei\|taichung\|all` | enum | `all` | no | Region filter. |
| `--today` | flag | off | no | Single-day run for today. Mutually exclusive with other interval selectors. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | date pair | — | no | Inclusive date range. Both must be supplied. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Implicit fallback only. |
| `--top N` | uint ≥ 0 | `10` | no | Error pattern rows to show. `0` = ALL patterns. |
| `--format text\|tsv\|csv` | enum | `text` | no | Accepted; errors always emits text. Non-`text` values log a notice and continue. |
| `--output-dir DIR` | path | `""` | no | Persistence directory. Resolved as: flag > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. File must exist. |
| `-v`, `--verbose` | flag | off | no | Enable DEBUG-level logging. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Examples

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. Default 7-day error rollup
bash bin/analyze_errors.sh --log-dir "$LOG_DIR"

# 2. Taichung DB troubleshooting — show top 20 patterns
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --region taichung --date 2026-05-21 --top 20

# 3. Show ALL error patterns (no limit)
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --top 0

# 4. Restart audit for a date range
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 5. Today's errors, Taipei
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --today --region taipei

# 6. Quick top-3 sanity check, write to custom dir
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --top 3 --output-dir ./reports
```

### Console output (detail — always shown)

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

### Summary file (disk only)

The `errors_summary_<TS>.txt` file is written to the output directory
but is not mirrored to the console. It contains compact per-server
signal counts for each region:

```
  Error Analysis Summary
...
    ■ Server: 10.1.72.35
  Total ERROR                             16
  OracleDB health failures                15
  Restart count                           4
  Unmatched SHUTDOWN                      0
```

> Aggregated across all three Taichung servers, baseline figures are
> ERROR=46, OracleDB=44, Restart=9 (verified by `tests/run_tests.sh`
> sections C06/C07). Full detail sample in
> [`../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt`](../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt).
> Taipei summary sample: [`../examples/sample-outputs/errors_summary_taipei_2026-05-21.txt`](../examples/sample-outputs/errors_summary_taipei_2026-05-21.txt).

---

## 4. `bin/log_report.sh`

Orchestrator that runs all enabled analysis modules in canonical order
(`overview → iis → access → errors`) with per-module persistence.

By default, `log_report` runs **overview, iis, and access** with the
**summary** view. The `errors` module is opt-in (add it via
`--modules`). Each module writes its own file pair to the shared output
directory; all files share one launch timestamp.

```
[shared output directory]
  overview_summary_<TS>.txt
  iis_summary_<TS>.txt
  iis_detail_<TS>.txt          (text by default; tsv/csv with --format)
  access_summary_<TS>.txt
  access_detail_<TS>.txt       (or .tsv / .csv with --format)
  errors_summary_<TS>.txt      (only when errors is in --modules)
  errors_detail_<TS>.txt       (only when errors is in --modules)
```

### Options

| Flag | Type | Default | Req? | Description |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **yes** | Root log directory. Directory must exist. |
| `--region REGION` | enum | `all` | no | Region filter. Forwarded to all modules. |
| `--today` | flag | off | no | Single-day run for today. Mutually exclusive with other interval selectors. |
| `--date YYYY-MM-DD` | date | — | no | Single-day analysis. |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | date pair | — | no | Inclusive date range. Both must be supplied. |
| `--days N` | uint ≥ 1 | `7` | no | Last N days ending today. Implicit fallback only. |
| `--modules LIST` | csv | `overview,iis,access` | no | Comma-separated modules. Valid values: `overview`, `iis`, `access`, `errors`. Errors is opt-in (OFF by default). Modules run in canonical order regardless of input order. Unknown module names abort. |
| `--view summary\|detail` | enum | `summary` | no | Console view. Forwarded to iis and access only; overview and errors are unaffected. Summary is always text (format-independent). |
| `--format text\|tsv\|csv` | enum | `text` | no | Governs the detail file extension and detail mirror. Forwarded to iis and access; ignored by overview and errors. |
| `--top N` | uint ≥ 0 | `10` | no | Forwarded to iis (endpoints + client IPs) and errors (patterns). `0` = ALL. |
| `--slow-api-ms N` | uint ms | `2000` | no | Forwarded to overview and iis; applies to API-role servers. |
| `--slow-app-ms N` | uint ms | `5000` | no | Forwarded to overview and iis; applies to APP-role servers. |
| `--merge` | flag | off | no | Forwarded to access and iis. **Requires `--region all`**. |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | no | Forwarded to overview, iis, and access. **Not** forwarded to errors (`analyze_errors` does not accept it — fatal error if supplied directly). See [Test-host filtering](#test-host-filtering). |
| `--output-dir DIR` | path | `""` | no | Persistence directory. Resolved as: flag > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`. Shared by all child modules via `$LOG_PARSE_OUTPUT_DIR`; `--output-dir` is NOT forwarded as a flag to children. |
| `--conf FILE` | path | `conf/regions.conf` | no | Override region mapping. Forwarded to all modules when supplied. |
| `-v`, `--verbose` | flag | off | no | Forwards `--verbose` to all child modules. |
| `-h`, `--help` | flag | — | — | Show help and exit 0. |

### Flag forwarding matrix

| Flag | overview | iis | access | errors |
|---|:---:|:---:|:---:|:---:|
| `--log-dir`, `--region`, interval flags, `--verbose`, `--conf` | F | F | F | F |
| `--view` | — | F | F | — |
| `--format` | — | F | F | — |
| `--top` | — | F | — | F |
| `--slow-api-ms`, `--slow-app-ms` | F | F | — | — |
| `--merge` | — | F | F | — |
| `--test-hosts` | F | F | F | — |
| `--output-dir`, `--modules` | own | own | own | own |

F = forwarded. `--output-dir` is resolved once by log_report and shared
via `$LOG_PARSE_OUTPUT_DIR`; it is NOT forwarded as a flag argument to
child modules (prevents split-brain when a custom `--output-dir` is
given).

### Examples

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. Default report — overview + iis + access, last 7 days, summary view
bash bin/log_report.sh --log-dir "$LOG_DIR"

# 2. Single-date summary, all regions
bash bin/log_report.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 3. Today's quick report
bash bin/log_report.sh --log-dir "$LOG_DIR" --today

# 4. Weekly audit including errors, custom output directory
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 \
    --modules overview,iis,access,errors \
    --output-dir ./reports/weekly

# 5. Detail view with CSV export (iis + access detail files become .csv)
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --view detail --format csv \
    --output-dir ./reports

# 6. Taipei only, errors included, top 5 patterns
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei \
    --modules overview,iis,access,errors --top 5

# 7. Tighten API SLA across overview and iis
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --slow-api-ms 3000

# 8. Merged ops review — cross-region correlation + IIS two-bucket split
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge --top 5

# 9. Unknown module is caught early and aborts
bash bin/log_report.sh --log-dir "$LOG_DIR" --modules access,unknown
#   exits with code 1
```

> Full combined sample: [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt).
> Partial (Taipei, overview+iis+access): [`../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt`](../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt).

---

## 5. Scenario playbook

End-to-end commands matching the scenarios in the test suite.

### 5.1 Daily ops snapshot

```bash
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date "$(date +%F)" \
    --output-dir ./reports/daily
```

### 5.2 Security investigation (orphan tokens, last week, Taipei)

```bash
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7 --view detail \
    --output-dir ./reports/security
```

### 5.3 DB outage triage (Taichung, last 24 h, top 20 patterns)

```bash
bash bin/analyze_errors.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --days 1 --top 20 \
    --output-dir ./reports/triage
```

### 5.4 Weekly digest (Mon–Sun) to disk with errors

```bash
START=$(date -d 'last monday' +%F)
END=$(date -d 'last sunday' +%F)
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from "$START" --to "$END" \
    --modules overview,iis,access,errors \
    --output-dir ./reports/weekly
# Produces (one shared timestamp T):
#   ./reports/weekly/overview_summary_<T>.txt
#   ./reports/weekly/iis_summary_<T>.txt
#   ./reports/weekly/iis_detail_<T>.txt
#   ./reports/weekly/access_summary_<T>.txt
#   ./reports/weekly/access_detail_<T>.txt
#   ./reports/weekly/errors_summary_<T>.txt
#   ./reports/weekly/errors_detail_<T>.txt
```

### 5.5 Per-role slow audit (API ≤ 1 s, APP ≤ 3 s, all servers)

```bash
bash bin/analyze_iis.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 1000 --slow-app-ms 3000 \
    --output-dir ./reports
```

### 5.6 Merged ops review — cross-region correlation + IIS two-bucket split

```bash
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5 \
    --output-dir ./reports
```

### 5.7 Machine-readable CSV pipeline (ORPHAN CLIENT_IP + PATIENT_ID_AES)

```bash
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv --view detail \
    --output-dir ./reports \
| awk -F',' '$2 == "ORPHAN" { print $12 "," $13 }' \
| sort -u
```

TSV/CSV column reference (13 fields in order):
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)`.

### 5.8 Management overview (standalone, Taipei, daily)

```bash
bash bin/analyze_overview.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei \
    --output-dir ./reports
```

### 5.9 Test-host audit (non-health hits from internal QA clients)

Use `--test-hosts only` to see only the IIS and access activity originating
from the test-host IPs in `conf/test_hosts.conf`, after `/health` exclusion.
This is useful for auditing internal QA tool behaviour, not for viewing
health-probe traffic (health probes are never visible in any mode).

```bash
# IIS report scoped to test-host client IPs only (health excluded)
bash bin/analyze_iis.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts only --view summary

# Access correlation for test-host client IPs only
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts only --view summary

# Full report including all client IPs (no test-host filter)
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts all \
    --output-dir ./reports
```

See [`../examples/sample-outputs/iis_only_2026-05-21.txt`](../examples/sample-outputs/iis_only_2026-05-21.txt) for the `--test-hosts only` sample.
See [`../examples/sample-outputs/iis_allmode_2026-05-21.txt`](../examples/sample-outputs/iis_allmode_2026-05-21.txt) for the `--test-hosts all` sample.

---

## 6. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (even when no data was found for the requested period). |
| 1 | Usage / validation error: missing `--log-dir`, bad flag value, unknown region or module, missing config file (`regions.conf` or `test_hosts.conf`), `--merge` without `--region all`, more than one interval selector supplied, or `--test-hosts` passed to `analyze_errors`. |

---

## 7. Environment variables

| Variable | Effect |
|---|---|
| `LOG_LEVEL` | `DEBUG` / `INFO` (default) / `WARN` / `ERROR`. Overridden by `-v`. |
| `NO_COLOR` | When set, disables ANSI colour codes in all output. Persisted files are always color-free regardless of this variable. |
| `TMPDIR` | Base directory for temp files (`mktemp -d`). Defaults to `/tmp`. |
| `LOG_PARSE_OUTPUT_DIR` | Default output directory for persisted files. Overridden by `--output-dir DIR`. Superseded by the literal `./log-parse` when both this variable and the flag are unset. |
| `LOG_PARSE_RUN_TS` | Shared launch timestamp in `YYYYmmdd_HHMMSS` format. Set by `log_report` and exported to child modules so all files of one run share the same suffix. Override with a fixed value in scripts or tests to produce deterministic file names. |
