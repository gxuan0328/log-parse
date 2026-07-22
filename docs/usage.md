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

File layout: `<base>/<YYYYMMDD_HHMMSS>/<module>_<kind>.<ext>` where:
- `<base>` is the resolved output directory
- `<YYYYMMDD_HHMMSS>` is the run-directory name (shared launch timestamp;
  all files of one run land in this single subdir)
- `<kind>` is `summary`, `detail`, or `ip_counts` (access only)
- `<ext>` is `txt` for summary (always), `txt`/`tsv`/`csv` for detail,
  and `tsv` for `access_ip_counts` (follows `--format` for detail only)

Persisted files are always color-free. The `--view` flag controls only
the console mirror (which view streams to stdout); all files are always
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
The file seeds seven addresses: `192.168.139.79`, `192.168.139.110`,
`192.168.139.28`, `192.168.117.90`, `192.168.105.149`, `192.168.117.73`, and
`192.168.117.104`. A missing file is a fatal error even with `--test-hosts all`
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
computation). Only `overview_summary.txt` is written to the run directory
`<base>/<YYYYMMDD_HHMMSS>/` (no detail file).

**Single-day hourly bar chart (存取紀錄橫條圖):** when `--date` or `--today`
selects exactly one day, a `存取紀錄橫條圖 (每小時)` section is appended
in both 總體概況 (global) and each ■ region block of 分區別. The chart
counts NORMAL+ORPHAN APP_TIME hours (UTC+8; unit = access record = one
browser request that reached the APP server). Axis: `00..LAST` zero-filled.
For a past single-day date: `LAST=23` (full 00..23 axis). For `--today`:
`LAST = local_hour() - 1`; at hour 0: `LAST=-1` → graceful note
`(今日尚無完整小時資料)` instead of bars. Multi-day windows (`--from`/`--to`,
`--days`) produce no chart.

**Host clock precondition and `TZ` remedy:** `local_hour()` reads the HOST
clock (same as `today()`). **Precondition:** host clock must be in UTC+8. On
a non-UTC+8 host run with `TZ=Asia/Taipei` — this shifts both `today()` and
`local_hour()` together so the gate and cap stay in sync. Override with
`LOG_PARSE_NOW_HOUR=H` for deterministic scripting or tests.

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
> Single-day sample (with 存取紀錄橫條圖): [`../examples/sample-outputs/overview_all_2026-05-21.txt`](../examples/sample-outputs/overview_all_2026-05-21.txt).

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
`PATIENT_ID_AES` is never truncated, followed by `BIRTHDAY` (decoded
date-of-birth, `YYYYMMDD`) as the final column.
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

Both formats emit one record per correlation result across 14 tab- or
comma-separated columns in this order:

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES  BIRTHDAY
```

`csv` uses RFC-4180 conditional quoting: only fields containing `"`, `,`, or
a newline are quoted; internal `"` characters are doubled. A header row is
always the first line. The summary file is always `.txt` regardless of
`--format`; only the detail file uses the `.tsv` / `.csv` extension.

> Samples: [`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

### IP attribution file (access_ip_counts.tsv)

Every **real** (non `--emit-stats`) `analyze_access` run writes a third
file `access_ip_counts.tsv` alongside the summary and detail files under
the run directory `<base>/<YYYYMMDD_HHMMSS>/`:

- **Header**: `CLIENT_IP<TAB>REQUEST_COUNT`
- **Data**: one row per unique CLIENT_IP, sorted count descending, IP
  ascending for tie-breaking.
- **Unit**: NORMAL+ORPHAN records (same predicate as the overview hourly
  chart). UNVERIFIED records are excluded (no APP access occurred).
- **IP coalescing**: empty or `"-"` CLIENT_IP fields → sentinel `"-"`.
  With `--test-hosts exclude` (default), business CLIENT_IPs that are
  blank upstream are aggregated under `"-"`.
- **Never on stdout**: side artifact only; does not appear in the console
  mirror or in `--emit-stats` output.
- **Empty corpus**: header-only file (exactly 1 line), no data rows.
- **`--test-hosts all`** surfaces real IPs (e.g. `192.168.139.110` with
  count 3 on 2026-05-21). **`--test-hosts only`**: only test-host IPs.

Sample (2026-05-21, all regions, default `--test-hosts exclude`):
```
CLIENT_IP	REQUEST_COUNT
-	3
10.243.129.44	2
10.238.23.241	1
10.241.93.164	1
10.248.1.29	1
10.249.8.10	1
```

> Fixture: [`../examples/sample-outputs/access_ip_counts_all_2026-05-21.tsv`](../examples/sample-outputs/access_ip_counts_all_2026-05-21.tsv)

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
(`errors_summary.txt` under the run directory). Both `errors_summary.txt`
and `errors_detail.txt` are always written to the run directory.

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

The `errors_summary.txt` file is written to the run directory
`<base>/<YYYYMMDD_HHMMSS>/` but is not mirrored to the console.
It contains compact per-server signal counts for each region:

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
  <YYYYMMDD_HHMMSS>/
    overview_summary.txt
    iis_summary.txt
    iis_detail.txt             (text by default; tsv/csv with --format)
    access_summary.txt
    access_detail.txt          (or .tsv / .csv with --format)
    access_ip_counts.tsv       (always written on real access runs)
    errors_summary.txt         (only when errors is in --modules)
    errors_detail.txt          (only when errors is in --modules)
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
| `--report-export` | flag | off | no | Run the `report-export` container on this run's CSV and attach the resulting `YYYY-MM-DD_連線紀錄.xlsx` to the notification. **Requires `--format csv` and the access module.** Needs the optional dependency `docker`. Uses `<output-dir>/production/{input,state,output}`. See [Report export](#report-export). |
| `--top N` | uint ≥ 0 | `10` | no | Forwarded to iis (endpoints + client IPs) and errors (patterns). `0` = ALL. |
| `--slow-api-ms N` | uint ms | `2000` | no | Forwarded to overview and iis; applies to API-role servers. |
| `--slow-app-ms N` | uint ms | `5000` | no | Forwarded to overview and iis; applies to APP-role servers. |
| `--merge` | flag | off | no | Forwarded to access and iis. **Requires `--region all`**. |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | no | Forwarded to overview, iis, and access. **Not** forwarded to errors (`analyze_errors` does not accept it — fatal error if supplied directly). See [Test-host filtering](#test-host-filtering). |
| `--notify` | flag | off | no | Mail the run's persisted report bundle through the SMTP API as the last step of `main()`, after every requested module has finished. Optional deps `curl`/`base64` are checked only when this flag is set. Recipients come from `conf/receivers.conf`. **A delivery failure is fatal** — compose with `\|\| true` to tolerate it. See [Notification](#notification). |
| `--notify-dry-run` | flag | off | no | Build the full payload and write it to `<RUN_OUTPUT_DIR>/notify_payload.json` (mode `0600`) without ever invoking `curl`. Requires `--notify`. |
| `--notify-attach all\|summary` | enum | `all` | no | Which persisted files become attachments. `all` (default) attaches every file the run produced, including `access_detail.*` and `access_ip_counts.tsv`. `summary` narrows to `*_summary.txt` files only. Requires `--notify`. |
| `--notify-url URL` | url | `""` | no | SMTP API endpoint override. Resolved as: flag > `$LOG_PARSE_NOTIFY_URL` > the built-in default (`http://haididev.intra.nhi.gov.tw:8080/api/email/send`). Validated even under `--notify-dry-run`. Requires `--notify`. |
| `--receivers-conf FILE` | path | `conf/receivers.conf` | no | Override the recipients file. Must exist and contain at least one valid `DISPLAY_NAME\|ADDRESS` row. Requires `--notify`. |
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
| `--notify`, `--notify-dry-run`, `--notify-attach`, `--notify-url`, `--receivers-conf` | — | — | — | — |
| `--report-export` | — | — | — | — |

F = forwarded. `--output-dir` is resolved once by log_report and shared
via `$LOG_PARSE_OUTPUT_DIR`; it is NOT forwarded as a flag argument to
child modules (prevents split-brain when a custom `--output-dir` is
given). The `--notify*` flag family is never forwarded to any child
module — it is handled entirely inside `log_report.sh`, in-process, as
the last step of `main()`, after every requested module has already run.
See [Notification](#notification). `--report-export` is likewise never
forwarded — it runs in-process, between the module loop and the notify
step. See [Report export](#report-export).

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

# 10. Daily report, mailed to conf/receivers.conf (all persisted files attached)
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --notify
```

> Full combined sample: [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt).
> Partial (Taipei, overview+iis+access): [`../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt`](../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt).

### Notification

`log_report.sh --notify` mails the run's persisted report bundle through an
internal SMTP-relay HTTP API as the very last step of `main()`, after every
requested module has already finished and persisted its files. It is
opt-in, single-shot (no automatic retry), and is never reached unless
`--notify` is given — every existing workflow is completely unaffected.

**What gets sent.** One JSON document, POSTed with header
`Content-Type: application/json`:

```json
{
  "From": { "DisplayName": "系統通知", "Address": "notify@nhi.gov.tw" },
  "To": [ { "DisplayName": "Jason Chao", "Address": "jason.chao@cohesiondata.com" } ],
  "Subject": "【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-21",
  "Body": "Run timestamp : 20260521_090000\nAnalysis range: 2026-05-21 ~ 2026-05-21\n... (the run's KEY SUMMARY, see below)",
  "Attachments": { "access_detail.txt": "<base64>", "overview_summary.txt": "<base64>", "...": "<base64>" }
}
```

`From` is a single object (sender identity); `To` is an **array**, one
object per `conf/receivers.conf` row, in file order; `Attachments` is a
**key–value map** — key = attached file's basename, value = its base64
content — never an array of objects. There are no `isBodyHtml`, `cc`,
`bcc`, `fileName`, or `contentBase64` keys anywhere in the payload.

`Body` is **not** boilerplate: it carries the run's real KEY SUMMARY,
extracted by `gawk` from the run's own `overview_summary.txt` (envelope +
the `▶ 總體概況` block, including the `整體健康判定` verdict), followed by
an attachment manifest. Rendered example (`--date 2026-05-21`, default
`--notify-attach all`):

```
Run timestamp : 20260521_090000
Analysis range: 2026-05-21 ~ 2026-05-21
Region        : all
Modules       : overview, iis, access
Output dir    : ./reports/20260521_090000
Attach mode   : all

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

Attachments (6):
  access_detail.txt            3955 bytes
  access_ip_counts.tsv           28 bytes
  access_summary.txt            732 bytes
  iis_detail.txt               9231 bytes
  iis_summary.txt              1375 bytes
  overview_summary.txt         3821 bytes

Generated by log-parse. Full reports are attached and also retained at
./reports/20260521_090000 on the analysis host.
```

The extractor stops at the hourly bar chart (a wall of block-drawing
characters that is unreadable in a proportional mail font) or at the
second `▶ ` section heading, whichever comes first, and hard-caps at 60
printed lines; the whole Body is additionally capped at 65536 bytes
(truncated with a visible marker line on overflow — the authoritative file
is always attached in full regardless). If `overview_summary.txt` is
absent (e.g. `--modules iis`), the Body falls back to the first 25 lines of
the lexicographically-first `*_summary.txt` present; if no summary file
exists at all, it falls back to a literal placeholder line — the Body is
never blank and building it never aborts the send.

**Recipients — `conf/receivers.conf`.** This file lists recipients only
(收件者); the sender identity is configured separately via environment
variables (see the table below), never here. One row per line:

```
DISPLAY_NAME|ADDRESS
```

`#` comments and blank lines are ignored; leading/trailing whitespace and
CR are stripped from every field. At least one row is required — the same
fail-fast contract as `regions.conf` / `test_hosts.conf`: a missing,
empty, or malformed file (wrong field count, an invalid address, a
display name containing `` | , ; < > " `` or a control character, or a
duplicate address) aborts with an explicit error before anything is sent.
Override the path with `--receivers-conf FILE` (default
`conf/receivers.conf`). The shipped file seeds one row:

```
Jason Chao|jason.chao@cohesiondata.com
```

**Environment variables** (all optional — every one has a working
default, so `--notify` alone is always usable):

| Variable | Default | Effect |
|---|---|---|
| `LOG_PARSE_NOTIFY_URL` | `http://haididev.intra.nhi.gov.tw:8080/api/email/send` | Endpoint; `--notify-url` overrides it. |
| `LOG_PARSE_NOTIFY_SUBJECT` | derived (date-based, see above) | Replaces the whole `Subject` string; no flag exists for this. |
| `LOG_PARSE_NOTIFY_FROM_NAME` | `系統通知` | `From.DisplayName`. |
| `LOG_PARSE_NOTIFY_FROM_ADDR` | `notify@nhi.gov.tw` | `From.Address`; validated against the same address pattern as every `conf/receivers.conf` row. |
| `LOG_PARSE_NOTIFY_CURL_BIN` | `curl` | Absolute `curl` path on locked-down hosts; also the automated-test shim hook. |
| `LOG_PARSE_NOTIFY_INTERNAL_DOMAINS` | *(empty)* | Space-separated domains exempt from the external-recipient warning. |
| `LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES` | `2097152` (2 MiB) | Per-file raw-byte cap, checked before base64 encoding. |
| `LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES` | `8388608` (8 MiB) | Per-run raw-byte cap across all attachments. |
| `LOG_PARSE_NOTIFY_CONNECT_TIMEOUT` | `5` | `curl --connect-timeout` (seconds). |
| `LOG_PARSE_NOTIFY_MAX_TIME` | `60` | `curl --max-time` (seconds). |

**Dependencies — optional, checked lazily.** `curl` and `base64` are
**not** part of the toolkit's unconditional dependency set
(`bash gawk sort date mktemp`). They are named only inside
`lib/notify_utils.sh` and are checked only once `--notify` is actually
supplied: `--notify-dry-run` needs `base64` alone (no network is ever
touched); a real send needs both. Every run that omits `--notify` is
completely unaffected, even on a host with neither binary installed. If
`curl` is missing, a real send fails in well under a second — before any
log analysis starts — with:

```
[ERROR] --notify needs the optional dependency 'curl' (HTTP client for the SMTP API).
[ERROR] Install curl, or use --notify-dry-run to build the payload without sending.
[ERROR] missing required commands: curl
```

Use `--notify-dry-run` to validate the payload shape and recipients
offline, on a host with no outbound network access at all.

**Exit codes.**

| Situation | Exit code |
|---|---|
| everything OK | **0** |
| `--notify-dry-run` | **0** |
| analysis produced no data (empty corpus) | **0** — unchanged; the reports exist and say so, and the mail is still sent |
| config/validation defect (bad `--notify-attach` value, bad URL, bad `conf/receivers.conf`, bad `LOG_PARSE_NOTIFY_FROM_ADDR`, missing `curl`) | **1** — fails in argument parsing, before any analysis module runs |
| an attachment, or the run's total attachment size, exceeds its cap | **1** — nothing is sent |
| the SMTP API returns a non-2xx status, or the request otherwise fails to transport | **1** |
| any analysis module itself fails | **1**, and **no mail is sent** (the run stops before the notify stage ever runs) |

**Delivery failure is fatal by design.** The operator explicitly asked for
a notification, so a run that could not deliver it did not do what was
asked, and there is no separate resend command. If a scheduled run must
stay green even when the mail relay is unreachable, compose tolerance with
the shell — the project's existing idiom for optional steps:

```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --notify || true
```

There is deliberately no `--notify-best-effort` flag.

**PII — read before enabling.** The default `--notify-attach all` mails
**every** file the run produced, including `access_detail.*` (raw client
IPs and the JWT-derived `BIRTHDAY` plaintext date-of-birth field — see
[`design.md`](design.md) §3.1.5) and `access_ip_counts.tsv` (a raw
client-IP census), to **every address listed in `conf/receivers.conf`**.
There is no `--to` flag — retargeting delivery requires editing that
version-controlled, warning-headed configuration file, never a crontab
typo. Every send logs (at `WARN`, unsuppressable) the complete recipient
list and the complete attached-file list, and separately flags any
recipient whose domain is not listed in
`LOG_PARSE_NOTIFY_INTERNAL_DOMAINS` as external. Use `--notify-attach
summary` to narrow delivery to aggregate `*_summary.txt` views — no
per-record IPs, no `BIRTHDAY` column — when the recipient list is not
fully trusted. The default endpoint is plain HTTP; every send against an
`http://` URL logs an explicit warning that the payload, attachments
included, is transmitted unencrypted.

---

### Report export

`log_report.sh --report-export` runs the independent
[`report-export`](../report-export/README.md) Docker image against this
run's own `access_detail.csv` and attaches the resulting
`YYYY-MM-DD_連線紀錄.xlsx` deliverable to the SMTP notification. It is
opt-in, single-shot (no automatic retry), and runs strictly **between**
the analysis-module loop and `--notify`: every requested module has
already persisted its files before the container runs, and a failed
export always aborts before any mail can be sent (see "Ordering
guarantee", below).

**Hard requirements**, both enforced in argument parsing — before
`resolve_interval` and before any analyzer subprocess runs:

```
[ERROR] --report-export requires --format csv (got: 'text')
[ERROR] --report-export requires the access module (got --modules 'overview,iis')
```

`--format csv` is required because the CSV detail file is the only
input `report-export` accepts; the access module is required because
`analyze_access.sh` is the sole producer of `access_detail.csv`.

**The `production/{input,state,output}` tree.** Unlike every other
artefact this toolkit produces, `report-export`'s state is **cross-run
accumulating** (its own `REQUEST_ID` deduplication depends on seeing
every prior run), so the three directories below are created as
**siblings** of the timestamped run directories, never nested inside
one:

```
<--output-dir>/
├── production/
│   ├── input/    week-<WINDOW_START>.csv                 (staged copy; :ro mount)
│   ├── state/    records.csv, records.csv.bak, runs.jsonl (accumulates across runs)
│   └── output/   <run_date>_連線紀錄.xlsx                 (the deliverable)
└── <YYYYMMDD_HHMMSS>/                                     (this run's own report files, unaffected)
    └── ...
```

The three subdirectory names and `production/` itself are fixed, not
configurable. All four directories are created with `mkdir -p` under
`umask 077`, each is rejected outright if it is a symlink (protects
against a pre-existing symlinked mount point redirecting the `docker -v`
bind mount to an arbitrary host directory), and each is then
best-effort `chmod 0700`'d; if a previous run under a **different
uid** left them unwritable — most commonly a prior `root`/`-` opt-out
(see below) — the run dies early with an explicit `chown` remedy
rather than an opaque mid-run permission error.

**Permissions are not guaranteed on every filesystem.** `chmod 0700`
(directories) and `chmod 600` (the staged CSV) are best-effort: on a
filesystem that does not support Unix permission bits — DrvFs/9p/WSL,
which this project's own `--output-dir` can itself live on — chmod is
commonly accepted and silently ignored, leaving the tree readable by
more than the owner despite every other check succeeding. log-parse
reads the resulting mode back and, when it does not match, emits one
unmissable warning naming every affected path:

```
[WARN] report-export: SECURITY: chmod 0700 did not take effect on: /srv/log-parse/production ... -- this filesystem may not support Unix permission bits (common on DrvFs/WSL/9p mounts); the PII accumulating under production/ is NOT confidentiality-protected by chmod on this host. Restrict access by another means (host ACL, an encrypted volume, or a --output-dir on a filesystem that honours chmod).
```

This is deliberately a warning, not a fatal error — dying here would
make `--report-export` entirely unusable on exactly this kind of mount
— but it is never silent either: do not treat `chmod 0700`/`600` as a
confidentiality guarantee without confirming this warning did not fire,
and prefer a `--output-dir` on a filesystem that actually honours Unix
permissions for any deployment that takes `production/state`'s
accumulating PII seriously.

**Staged filename — the window START, not the run date.**
`access_detail.csv` is copied (never moved) into
`production/input/week-<D>.csv`, where `<D>` is the **first day of the
analysis window**: `--date D` → `D`; `--from A --to B` → `A`; `--days N`
→ the earliest day of the rolling N-day window; `--today` → today.
Re-running the same window overwrites the same staged filename (logged
at `INFO`, "already staged (identical)"); staging a genuinely different
window while an earlier stage's file is still present is logged at
`WARN` ("overwriting existing staged input") before overwriting — both
are non-fatal repair paths, never silent.

**The deliverable's date need not match the window.** `report-export`
names its own output after `run_date`, which is `date.today()` inside
the container under its own `TZ=Asia/Taipei` clock — it is **not**
settable by any flag, environment variable, or Docker argument. Running
`--report-export` today against last week's window (a back-fill) is
completely normal and produces a deliverable dated today, staged from a
CSV named after an earlier date. See
[`report-export/docs/usage.md`](../report-export/docs/usage.md) for the
canonical worked example (`week-2026-07-13.csv` in,
`2026-07-16_連線紀錄.xlsx` out).

**One-time image build** (run from `report-export/`, not from this
directory):

```bash
cd report-export
docker build -t report-export:1.0.0 -f docker/Dockerfile .
```

`--report-export` never builds or pulls the image itself. A missing
daemon or an unbuilt image is a fast, pre-analysis failure:

```
[ERROR] docker image inspect failed for 'report-export:1.0.0' (daemon unreachable, or the image is not built/pulled on this host); build it with: docker build -t report-export:1.0.0 -f docker/Dockerfile .   (run from report-export/)
```

**The rendered `docker run` command.** Exactly the three fixed bind
mounts, `--network none` (the container needs no network; this closes
off any exfiltration path for the PII the CSV carries), and — by
default — `--user <uid>:<gid>` of the **invoking** user:

```
docker run --rm --network none \
  -v <output-dir>/production/input:/data/input:ro \
  -v <output-dir>/production/state:/data/state \
  -v <output-dir>/production/output:/data/output \
  --user <uid>:<gid> \
  report-export:1.0.0 /data/input/week-<WINDOW_START>.csv
```

`<uid>:<gid>` is `${UID}:${GROUPS[0]}` — bash builtins, no new
dependency on `id`. The `report-export` image itself still ships with
no `USER` directive and is still designed to run as root for a
*standalone, manual* invocation (see
[`report-export/docs/usage.md`](../report-export/docs/usage.md), "HOST
權限說明") — that fact, and that doc, are unchanged. But
`log_report.sh --report-export` is not a standalone invocation: when
`--notify` is also given, it reads the deliverable back on the **host**
side immediately afterward to base64-attach it (see "Attaching the
xlsx to the mail", below), and a root-owned, mode-`0600` file — what
the image writes given no `--user` at all — is unreadable by the
typically non-root user running `log_report.sh`. Passing `--user` by
default closes that gap: the container's bind-mounted
`production/{input,state,output}` directories already belong to that
same uid ([`design.md`](design.md) §4.10.3), so nothing about the
container's own writes is impeded, and the deliverable comes back
owned by, and readable by, the process that has to read it next.

Two escape hatches, both via `LOG_PARSE_REPORT_EXPORT_USER` (below): a
numeric `uid[:gid]` overrides the default target; the sentinel `root`
(case-insensitive) or `-` opts OUT of `--user` entirely. Opting out
restores the original trade-off — files under `production/state` and
`production/output` become **root-owned**, `sudo` is required to
remove or edit them from the host side (the same trade-off
`report-export`'s own docs record for manual runs), and because the
deliverable is then unreadable by a non-root operator, `log_report.sh`
itself must also run as root for `--notify` to attach it.

**Environment variables** (all optional):

| Variable | Default | Effect |
|---|---|---|
| `LOG_PARSE_REPORT_EXPORT_DOCKER_BIN` | `docker` | Container-runtime binary; also the automated-test shim hook. |
| `LOG_PARSE_REPORT_EXPORT_IMAGE` | `report-export:1.0.0` | Image reference (pin an `@sha256:` digest in production if desired). A private registry with a port is supported, e.g. `registry.example.com:5000/report-export:1.0.0`. |
| `LOG_PARSE_REPORT_EXPORT_USER` | *(empty)* | **Default** (empty): emits `--user ${UID}:${GROUPS[0]}`, the invoking user, exactly as shown above. **Override**: a value matching `uid[:gid]` (digits only, e.g. `1000:1000`) is passed verbatim to `docker run --user`. **Opt-out**: the sentinel `root` (case-insensitive) or `-` emits no `--user` at all — the container runs as root and its output becomes root-owned. Any other value dies at preflight, before analysis starts. |

**Dependencies — optional, checked lazily.** `docker` is **not** part of
the toolkit's unconditional dependency set (`bash gawk sort date
mktemp`). It is named only inside `lib/report_export_utils.sh` and
checked only once `--report-export` is actually supplied — a `docker
image inspect` round trip that confirms both daemon reachability and
image presence, sub-second, before any analysis module runs. Every run
that omits `--report-export` is completely unaffected, even on a host
with no `docker` installed at all. If `docker` itself is missing:

```
[ERROR] --report-export needs the optional dependency 'docker' (container runtime that runs the report-export image).
[ERROR] Install docker, or drop --report-export to produce the analysis reports only.
[ERROR] missing required commands: docker
```

**Ordering guarantee relative to `--notify`.** `report_export_run`
executes strictly before `notify_run`. Because every export failure is
fatal, a notification is **never** sent for a run whose export did not
succeed — the alternative (notify first) could ship a mail whose body
promises an attachment it does not carry, an undetectable failure for
the recipient. Analysis reports are already persisted at that point, so
the fatality costs nothing analytical: rerun with the same
`--output-dir`, and `report-export`'s own `input_sha256` idempotency
absorbs the retry. `--report-export` and `--notify` are otherwise
**orthogonal** — either may be used without the other; with
`--report-export` alone, the xlsx simply lands in `production/output`
and `log_report` logs its host path for the operator to find.

**Attaching the xlsx to the mail.** When both flags are given, the
validated deliverable path is passed into the same
`notify_collect_attachments` call that gathers the run's own files, so
it inherits every existing rule unmodified: the `notify_payload.json`
exclusion, the attachment-name collision check, the byte-size probe,
base64 encoding as a separate attachment (never a zip), and the mail
body's attachment manifest. Two interactions are worth calling out
explicitly:

- **`--notify-attach summary` does not hide the xlsx.** That mode
  normally narrows attachments to `*_summary.txt` files, but the xlsx is
  the entire reason the operator passed `--report-export`, so it is
  deliberately exempted from that filter and is always attached
  alongside the summaries.
- **The xlsx is not exempt from the size caps.**
  `LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES` (default 2 MiB) and
  `LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES` (default 8 MiB) apply to it exactly
  as to any other file. A breach is loud and fatal (`NOTIFY_RESULT
  status=skipped reason=attachment_too_large:<name>`) — never a silently
  incomplete mail. Raise the caps (see [Notification](#notification))
  before the first week whose xlsx is larger than the default per-file
  limit.

```bash
# Weekly consolidated run: analyse, export the xlsx, and mail everything
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --days 7 --format csv --output-dir /srv/log-parse \
    --report-export --notify
```

**Try it end-to-end against the bundled sample.** No production data or
network access is required to exercise the full pipeline once the
image is built (above): `examples/sample-logs/LUNG-CANCER-REPORT-LOG`'s
`--date 2026-05-21` fixture carries realistic, reference-map-resolving
`CLIENT_IP`/`HOSP_ID`/`PRSN_ID` values on its six `STATUS=NORMAL`
access rows, so this one command runs analysis, stages the CSV,
invokes the real `report-export:1.0.0` image, and selects the
deliverable — and, because `--notify-dry-run` is given, writes rather
than sends the mail payload:

```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --format csv --output-dir /tmp/log-parse-demo \
    --report-export --notify --notify-dry-run
```

This lands `production/output/<run_date>_連線紀錄.xlsx` under
`/tmp/log-parse-demo/` (container summary: `normal=6, unique_ips=5,
unmapped_hosp_ids=0`) and writes the run's `notify_payload.json` with
the xlsx as its 7th attachment — every step of "Attaching the xlsx to
the mail" (above) is inspectable without ever reaching a real SMTP
endpoint (`conf/receivers.conf` still needs its usual at-least-one-row,
see [Notification](#notification); `--notify-dry-run` just never
actually sends). This does not change `analyze_access`'s
own `STATUS` classification for the date — NORMAL/ORPHAN/UNVERIFIED
remain 6/9 — only the previously-blank `CLIENT_IP`/`HOSP_ID`/`PRSN_ID`
fields on those already-`NORMAL` rows are now populated.

**PII and retention — read before enabling.** `production/state`
accumulates every distinct week's records **indefinitely** — it is
canonical, cross-run state, not per-run scratch, and this toolkit
performs no rotation or purge of it. Retention is the **operator's**
responsibility (a scheduler is explicitly out of scope for this
project, CLAUDE.md §1). Re-review `conf/receivers.conf` before enabling
`--report-export --notify` for the first time: the xlsx carries the
same client-IP-derived PII as `access_detail.csv`, mailed to every
address the file lists.

**No built-in timeout.** A wedged Docker daemon or a hung container
blocks indefinitely — `timeout(1)` is outside this project's sanctioned
dependency set. Wrap scheduled invocations with a scheduler-level
timeout (`systemd`'s `RuntimeMaxSec=`, or `cron` plus your own `timeout`
wrapper).

**Failure triage.** Every failure is fatal (exit 1); classification is
carried by the message and by the grep-able
`REPORT_EXPORT_RESULT status=ok|failed reason=<slug> deliverable=<name|->`
stderr line (mirroring `NOTIFY_RESULT`):

| `reason=` slug | Condition | Operator action |
|---|---|---|
| *(pre-analysis; no result line yet)* | `--report-export` without `--format csv` / without the access module / `docker` missing / a bad image or user-spec override / `docker image inspect` failed | Fix the flag, env var, or image build and rerun; no run directory was created. |
| `dirs` | `production/` could not be created, or its resolved path is unsafe (too shallow, or `--output-dir` resolves to `/`) | Check `--output-dir` and host filesystem permissions. |
| `dirs_perm` | `production/{input,state,output}` exist but are not writable by this uid — typically a **previous run under a different uid** (most often a prior `root`/`-` opt-out) | Run the exact `sudo chown -R <uid>:<gid> .../production` command printed in the error message. |
| `path_colon` | The resolved `--output-dir` path contains `:` | `docker -v` cannot parse a colon in a host path; choose a path without one. |
| `window_start` | The analysis window's start date could not be derived | Defensive check only — should not occur, since `resolve_interval` has already validated the interval before this step runs; report as an orchestration-boundary defect. |
| `source_missing` / `source_empty` | This run's `access_detail.csv` is missing or zero bytes | Confirm `--format csv` and that the access module actually ran; a header-only CSV is fine and is **not** this error. |
| `stage_compare` | The byte-for-byte comparison against an already-staged `week-<D>.csv` could not be performed (one of the two files could not be opened) | Check permissions/existence of both `production/input/week-<D>.csv` and this run's own `access_detail.csv`; typically a permissions or transient I/O issue. |
| `stage` | The copy/rename into `production/input/` failed | Check free space and permissions on `production/input`. |
| `container_usage` | Container exited 1 (usage error) | Orchestration bug — report the argv logged just above the error. |
| `container_input` | Container exited 2 (input validation) | The staged CSV was rejected; the container's own stderr (surfaced above the die message) names the offending row/column. |
| `container_state` | Container exited 3 (state integrity) | `production/state/records.csv` failed integrity verification and its `.bak` could not recover it — see [`report-export/docs/usage.md`](../report-export/docs/usage.md) "state 完整性問題"; needs manual operator intervention. |
| `container_lock` | Container exited 4 (lock busy) | Another export already holds the lock on `production/state`; this run did **not** export. Confirm no concurrent run, then simply rerun later — never retried automatically. |
| `container_write` | Container exited 5 (write/reference error) | Check free space and ownership of `production/output`, or that the image's bundled reference table is intact. |
| `docker` | Any other non-zero `docker run` exit (e.g. 125–127) | Inspect the surfaced stderr; usually a Docker Engine-level failure, not a report-export one. |
| `summary_shape` | Container exited 0 but stdout was empty or more than one line | Should not happen against an unmodified image; treated as an orchestration-boundary defect rather than guessed at. |
| `summary_field` | Container exited 0 but its JSON summary had zero, or more than one, `deliverable` field | Same as above. |
| `deliverable_shape` | The reported `deliverable` value failed the hostile-input whitelist, OR the mapped host path is a symlink, OR it resolves outside the expected output directory | Should not happen against an unmodified image; refused rather than guessed at. A symlink or unexpected resolution is treated as a potential exfiltration attempt (CWE-61) and is never followed. |
| `deliverable_missing` | The reported deliverable does not exist (or is empty) on the host | Almost always a bind-mount or uid mismatch — inspect `production/output` directly. |
| `deliverable_stale` | The reported deliverable's mtime predates this invocation | The container's clock may be skewed from the host, or a stale file was left in place; investigate before trusting the attachment. |

In every case above, this run's own analysis reports remain intact
under `<output-dir>/<RUN_TS>/` — a failed export never discards
anything already persisted.

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
# Produces (one shared run-directory <T>):
#   ./reports/weekly/<T>/overview_summary.txt
#   ./reports/weekly/<T>/iis_summary.txt
#   ./reports/weekly/<T>/iis_detail.txt
#   ./reports/weekly/<T>/access_summary.txt
#   ./reports/weekly/<T>/access_detail.txt
#   ./reports/weekly/<T>/access_ip_counts.tsv
#   ./reports/weekly/<T>/errors_summary.txt
#   ./reports/weekly/<T>/errors_detail.txt
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

TSV/CSV column reference (14 fields in order):
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)` `BIRTHDAY(14)`.

`BIRTHDAY(14)` is the decoded date-of-birth (`YYYYMMDD`, or `-` when absent
or malformed) from the report-url token's JWT payload — see
[`design.md`](design.md) §3.1.5 "Internal schema — CORRELATE_AWK output".
Unlike the AES-encrypted `PATIENT_ID_AES`, this is plaintext PII: handle
exported or copied detail files with the same care as `PATIENT_ID_AES`.

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
