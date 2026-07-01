# log-parse — Design Specification

> Version 2.2 · 2026-06-30 · Audience: developers, SREs, on-call engineers.
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
  │  lib/common.sh        logging, tmpdir, deps,         │
  │                        load_test_hosts, TH_FILTER_FUNC│
  │  lib/date_utils.sh    date ranges, resolve_interval  │
  │  lib/csv_utils.sh     field extraction (awk)         │
  │  lib/fmt_utils.sh     text rendering, fmt_set_color  │
  │  lib/output_utils.sh  always-on persistence (D6)     │
  │  lib/aggregate_utils.sh  AGG_IIS_AWK, AGG_CSV_FUNC,  │
  │                           agg_iis_rows, agg_access_rows│
  └──────────────────────────────────────────────────────┘
                               │ reads
                               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │   conf/regions.conf    (region → server mapping)            │
  │   conf/test_hosts.conf (QA/probe client IPs — single source)│
  └─────────────────────────────────────────────────────────────┘
```

### 2.1 Layering rules

1. **CLI layer** (`bin/`) — parses arguments, drives the workflow, prints reports.
   Never contains parsing logic; delegates to `lib/`.
2. **Library layer** (`lib/`) — pure functions for date math, CSV extraction,
   formatting, logging, persistence, and shared metric computation. No CLI
   parsing; no global mutation outside documented sanctioned globals
   (`WORK_TMPDIR`, `LOG_LEVEL`, region arrays, `RUN_BASE_DIR`,
   `RUN_OUTPUT_DIR`, `RUN_TS`, `INTERVAL_ARGS`).
3. **Configuration layer** (`conf/`) — plain text files with no executable
   content. `regions.conf` is pipe-delimited and consumed by the per-bin
   `load_regions()`. `test_hosts.conf` lists one IPv4 per line and is consumed
   by `load_test_hosts` in `lib/common.sh` (see §3.2.14).

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

- **`AGG_IIS_AWK`** — IIS W3C log analyser. Applies (in order): UTC timezone
  window filter (tz guard, see §3.2.14), `/health` exclusion, test-host mode
  filter, DICOM endpoint grouping, per-category classification. Emits standard
  tagged rows plus `CATEGORY <key> <count> <sum_ms>` rows (one per category,
  always all three for stable downstream parsing; `sum_ms` is the raw integer
  accumulator so downstream can pool across servers and divide once for an
  exact mean — no intermediate rounding). Used via `agg_iis_rows`.
- **`AGG_CSV_FUNC`** — RFC-4180 gawk `q(s)` function (relocated verbatim from
  `bin/analyze_access.sh`). Prepended to both the access `render_csv` and the
  iis csv-detail gawk programs via string concatenation. **No bash-side
  `fmt_csv_field` is introduced** — `q()` is a gawk function; a bash
  reimplementation would create a third parallel copy.
- **`agg_iis_rows COMBINED SLOW_MS [TOP] [TH_MODE] [TH_SET] [TZ_LO] [TZ_HI]`** —
  runs `AGG_IIS_AWK`; the optional `TZ_LO`/`TZ_HI` arguments are the
  half-open UTC datetime bounds computed by `iis_utc_window` (empty = no
  filter, back-compatible with older callers).
- **`agg_access_rows RESULT_SORTED`** — single gawk pass that replaces the three
  separate counting passes formerly at `analyze_access.sh:351-353`.
- **Schema constants** `IIS_STAT_SCHEMA` / `ACCESS_STAT_SCHEMA` + field-index
  helpers (`IIS_F_REGION`, `IIS_F_TAG`, etc.) so analyzers, renderers, and
  overview share one contract. `IIS_STAT_SCHEMA` includes the `CATEGORY` row;
  `IIS_F_AVGSEC` (position 8) is overloaded: it holds `avg_sec` for `ENDPOINT`
  rows and `sum_ms` (integer ms) for `CATEGORY` rows — documented in the
  schema comment. `IIS_F_SUMMS=9` (ENDPOINT rows only) provides the field
  index for the `sum_ms` integer accumulator used by the summary-view avg
  pooling.
- **`overview_health_verdict NORMAL TOTAL`** — maps the integer-truncated
  NORMAL rate to the 整體健康判定 verdict text (verdict single source, per D1).
  Encapsulates `trunc(NORMAL/TOTAL×100)` via `printf "%d"` and the band
  mapping (`>=90 → 正常`, `>=70 → 注意`, `<70 → 警告`, `TOTAL==0 → 無資料`).
  Output is numeric-free (guards H11). Called by `overview_render` in
  `bin/analyze_overview.sh`.

#### `lib/date_utils.sh` — IIS timezone offset constant and window helper

Two additions support the IIS UTC→UTC+8 correction (see §3.2.14):

- **`IIS_UTC_OFFSET_HOURS=8`** — single source for the +8h offset (16 = 24 − 8
  is the UTC cutoff). Set at source time.
- **`IIS_TZ_CUTOFF_UTC`** — `16:00:00` derived from the constant above.
- **`iis_utc_window START END`** — maps a UTC+8 inclusive date range to the
  half-open UTC string bounds `"LO|HI"` used by `agg_iis_rows`. Pure stdout;
  no side effects.

#### `lib/common.sh` — test-host loader and predicate (single source)

`load_test_hosts(conf)` reads `conf/test_hosts.conf`, strips `#` comments and
blank lines, and returns the IP set as a single space-joined string for passing
to gawk via `-v th_set=...` (matched by exact string equality, never regex).
`load_test_hosts` dies if the file is absent — fail-fast parity with
`regions.conf`.

`TH_FILTER_FUNC` is a gawk snippet (a shell variable) that implements the
three filter modes. It is prepended to any gawk program that needs to filter
by client IP, via `"$TH_FILTER_FUNC$AWK_PROG"`. Callers pass
`-v _th_mode=exclude|only|all` and `-v th_set="ip ip ..."`, then call
`th_init(th_set)` in `BEGIN` and `if (th_skip(ip)) next` at the read stage.
`th_skip` returns 1 (drop) or 0 (keep):
- `exclude` (default) — drops requests whose client IP is in the test-host set.
- `only` — keeps only requests from test-host IPs.
- `all` — keeps every request regardless of IP.

This is the **first true shared loader/predicate** in `common.sh`. It mirrors
the `assert_enum`/`die` placement pattern. `load_regions` is defined per-bin
and is **not** a shared loader; do not conflate the two.

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
IIS  ...                         SLOW       <n>
IIS  ...                         UNIQUE_IPS <n>
IIS  ...                         STATUS     <code>  <count>
IIS  ...                         ENDPOINT   <uri>   <count>  <avg_sec>  <sum_ms:int>
IIS  ...                         CLIENT_IP  <ip>    <count>
IIS  ...                         CATEGORY   <key:glcr|ds|nhi>  <count>  <sum_ms:int>
  NOTE: ENDPOINT position 9 = summed time-taken ms over the per-server --top N
        emitted rows only (see GAP-3 caveat in §3.2.5). Field 8 (avg_sec) is
        unchanged and read by all downstream consumers except summary avg pooling.
  NOTE: CATEGORY position 8 = summed time-taken in ms (NOT avg_sec).
        avg_sec = sum_ms/count/1000 (single division → exact cross-server pooled mean).
        CATEGORY pooling is uncapped (full request population, independent of --top).
```

**OVERVIEW_AWK** (`bin/analyze_overview.sh`) also emits an additional row type
from cross-server CATEGORY pooling, used internally by `overview_render`:
```
  CAT_REGION  <region>  <key:glcr|ds|nhi>  <count>  <avg_sec>
```
This row carries the per-region count and exact pooled mean (Σsum_ms / Σcount /
1000) for each category key. Not emitted by `AGG_IIS_AWK`; it is
`OVERVIEW_AWK`'s own regional aggregation step.

All rows reflect **business-only traffic**: `/health` requests are excluded
unconditionally and the test-host mode (§3.2.14) is applied before any row is
emitted. `TOTAL` therefore counts business requests only. The `STATUS` rows
are the descriptive Top-N status-code distribution (business-only); 302/404
may appear there — this is intentional, as they represent real business
responses. The former `5XX`, `503_HEALTH`, and `REDIRECT` aggregate rows have
been removed; dependency-health detection now lives exclusively in
`analyze_errors` (see §3.3).

`role` is `api` or `app` (from `conf/regions.conf`). `region` is `taipei` or
`taichung`; merged mode tags `region=all, server=API_SERVERS|APP_SERVERS`.
Per-server granularity lets overview pool CATEGORY `sum_ms`/`count` across
servers with a single division (exact pooled mean, no intermediate rounding).

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

#### 3.0.4 Two-cut layout with single-numeric-placement rule (C5)

The report presents two distinct decomposition dimensions. **No single
numeric literal appears in more than one cut.**

- **總體概況 (Overall)** — access-business grand totals with value + percentage,
  average API→APP latency, and the qualitative verdict. `存取關聯總數` appears
  **only here**. The verdict line is numeric-free (words only). IIS general
  totals (`IIS 總請求數`, unique IPs) are **not shown** — the overview is
  access-business-focused. An **■ 核心功能效能 (Core Function Performance)**
  sub-block follows immediately inside 總體概況, listing the three IIS-sourced,
  UTC+8 day-corrected categories (雲端查詢 / 報告摘要 / 影像下載) each with
  `呼叫次數 <count>` and `回應時間 <avg>s` (no per-row percentage), plus a
  plain `核心功能存取合計 <sum>` count. See §3.0.7 for category definitions.
- **分區別 (By Region)** — one ■ block per in-scope region, each opening with
  a prose enumeration `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) ·
  UNVERIFIED n (p%)` (percentage within the region total), followed by the same
  three core-function categories (呼叫次數 + 回應時間). Category counts and
  averages are accumulated over the full request population (uncapped —
  independent of `--top`). **Single-region scope (D8):** for `--region taipei`
  the 分區別 台北 block intentionally shows the same N/O/U totals and category
  counts as 總體概況 — this is the correct ROLLUP+breakdown symmetry (not a
  double-count); the regional label and framing are the value added. Suppressing
  the 分區別 cut for single-region scope would break regression tests and add
  scope-specific branching without benefit.

The standalone **核心功能效能** section has been dissolved into 總體概況
(global) and 分區別 (per-region). No information is lost; per-row percentage
and speed sub-labels are removed (see §3.0.7).

**服務別 (By Service Role) is retired.** Its IIS general-request content was
removed as part of the access-business focus (req5); its remaining access role
signals (UNVERIFIED/ORPHAN) are now present in 總體概況, so keeping it would
duplicate information (C5 single-placement rule). No information is lost.

**整體健康判定 criteria** (req4): The verdict is computed by `overview_health_verdict`
in `lib/aggregate_utils.sh` (single source, D1) over the fully-resolved analysis
window. Rate: `P = trunc(NORMAL ÷ 存取關聯總數 × 100)` — integer **truncate
toward zero** (implemented via `printf "%d"`, not banker's rounding;
P = 89.5 % → trunc → 89 → 注意, not 正常; P = 90.0 % → 90 → 正常). IIS
request volume does **not** enter the verdict.

| Condition (integer P = trunc(NORMAL ÷ 存取關聯總數 × 100)) | 判定 | Text |
|---|---|---|
| 存取關聯總數 = 0 | 無資料 | 無資料 — 本期間無存取關聯記錄 |
| P ≥ 90 | 正常 | 正常 — 系統整體運作健康 |
| 70 ≤ P ≤ 89 | 注意 | 注意 — 存在異常存取，建議持續監控 |
| P < 70 | 警告 | 警告 — 存取異常比例偏高，建議立即調查 |

Lower bounds are inclusive (`>=`). P = 89.5 % → trunc → 89 → 注意 (not 正常;
90 is the cutpoint). P = 90.0 % → 90 → 正常.

Sample output (single day `--date 2026-05-21`, all regions,
`--test-hosts exclude` default — business traffic only):
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

#### 3.0.5 Flags accepted / rejected

Accepted: `--log-dir`, `--region`, `--today`, `--date`, `--from`/`--to`,
`--days`, `--slow-api-ms`, `--slow-app-ms`, `--test-hosts`, `--output-dir`,
`--conf`, `-v`, `-h`.

Not accepted (die on receipt): `--view`, `--format`, `--merge`, `--top`,
`--emit-stats`.

#### 3.0.6 Persistence

Summary-only: `persist_views overview summary text overview_render ''`.
Only `overview_summary.txt` is written under the run directory
`<base>/<RUN_TS>/` (`DETAIL_FN=""` → no detail file).
Empty-window boundary: percentages rendered as `N/A` / `0.0%`, exit 0.

#### 3.0.7 核心功能效能 — category definitions (single source: `AGG_IIS_AWK`)

The three categories are matched **case-insensitively on the raw `cs-uri-stem`**
using anchored regex patterns defined once in `AGG_IIS_AWK` (`lib/aggregate_utils.sh`)
and consumed by both `analyze_iis` and `analyze_overview`:

| Key | Label | Pattern | Role |
|-----|-------|---------|------|
| `glcr` | 雲端查詢 | `^/api/GetLungCancerReportURL$` (exact) | APP |
| `ds` | 報告摘要 | `^/api/DigestSummary(/|$)` (prefix) | API |
| `nhi` | 影像下載 | `^/api/NhiPatientImage/studies/` (prefix) | API |

Category matching is independent of the ENDPOINT Top-N cap (`--top`); all
matching rows accumulate regardless of the cap. The `nhi` prefix covers the
full DICOM download family (`series`, `series-uid`, `instances`, `jpg`);
a non-download `NhiPatientImage` sub-path would be excluded by design.

`glcr` traffic is served entirely by APP-role servers (verified in sample:
6 taichung-app + 5 taipei-app = 11 total). `ds` and `nhi` are API-role.

**Exact pooled mean:** `AGG_IIS_AWK` emits the raw integer `sum_ms`
accumulator. `OVERVIEW_AWK` pools `Σsum_ms` and `Σcount` across servers and
divides **once** (`sum_ms / count / 1000.0`) — no intermediate per-server
rounding, no last-digit drift.

**`--slow-api-ms` / `--slow-app-ms` and the overview:** these thresholds are
accepted by `analyze_overview` and forwarded to the IIS child spawn. They
control the global IIS `SLOW` bucket. However, the overview only consumes
`CATEGORY` rows (which carry `count` + `sum_ms`, no slow field), so the
thresholds do **not** influence any value displayed in the overview output.

#### 3.0.8 Single-day hourly bar chart — 存取紀錄橫條圖

When the analysis window is exactly **one day** (`_OVW_N_DATES==1`),
`overview_render` appends a `存取紀錄橫條圖 (每小時)` section using
`_render_hour_chart`:

- **Data source**: `HOUR` rows emitted by `agg_access_records` in
  `analyze_access` via `--emit-stats`; `OVERVIEW_AWK` collects them into
  `acc_hour[HH]` (global) and `acc_hour_r[region,HH]` (per-region).
- **Unit**: NORMAL+ORPHAN APP_TIME hours (same predicate as REQ2; APP_TIME
  is already UTC+8 — no further conversion). UNVERIFIED rows carry no
  APP_TIME and are excluded.
- **Axis**: `00..LAST`, zero-filled. For a past single-day date (e.g.
  `--date 2026-05-21`), `LAST=23` (full axis). For `--today`:
  `LAST = local_hour() - 1`; at hour 0, `LAST=-1` → graceful note
  `(今日尚無完整小時資料)` instead of a bar chart.
- **Today-cap and TZ requirement**: `local_hour()` (in `lib/date_utils.sh`)
  reads the HOST clock identically to `today()`, so the gate
  (`_OVW_DATE_START == today()`) and the cap (`LAST = local_hour()-1`) always
  read the same clock. **PRECONDITION** (inherited, not introduced): the host
  clock must run in UTC+8 (the same assumption `today()` already makes). On
  a non-UTC+8 host run with `TZ=Asia/Taipei` — this shifts both `today()`
  and `local_hour()` together so the gate fires and the cap is correct. Do
  NOT pin only `local_hour()` to Asia/Taipei; doing so would desync the gate
  and the cap on a UTC host.
- **Rendering**: `fmt_bar` in `lib/fmt_utils.sh` renders label+count pairs
  piped on stdin into proportional U+2588 bar glyphs (LC_ALL=C; max 40 cells;
  min 1 cell when val>0; U+2588 emitted as `sprintf "%c%c%c", 226, 150, 136`).
- **Multi-day gating**: when `_OVW_N_DATES > 1` (e.g. `--from`/`--to` or
  `--days`), no chart is rendered. The weekly overview fixtures stay
  chart-free.
- **Layout**: one global chart follows `核心功能存取合計` inside `▶ 總體概況`;
  one per-region chart follows the per-region category rows inside each
  `■ 台北` / `■ 台中` block of `▶ 分區別`.

**Verified anchor values (2026-05-21, all regions, default exclude):**

| Scope | Hour | Count |
|-------|------|-------|
| Global | 13 | 1 |
| Global | 14 | 4 |
| Global | 15 | 4 |
| 台北 | 15 | 3 |
| 台中 | 13 | 1 |
| 台中 | 14 | 4 |
| 台中 | 15 | 1 |

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

Before correlation, records whose `CLIENT_IP` (CSV column 7) matches the
test-host set are dropped at the **extract stage** (inside `extract_api_records`
/ `extract_app_records` in `lib/csv_utils.sh`), controlled by `--test-hosts`
mode (§3.2.14). Because both the API issuance row and the APP verification row
for a test-host token carry the same `CLIENT_IP`, both sides are filtered out
together — no orphan/unverified artifacts are created.

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

#### 3.1.12 `access_ip_counts.tsv` — always-on IP attribution file

Every **real** (non `--emit-stats`) `analyze_access` run writes a third
persisted file `access_ip_counts.tsv` alongside `access_summary.txt` and
`access_detail.*` under `<base>/<RUN_TS>/`:

- **Source**: `result_sorted` rows with `$1 == "NORMAL" || $1 == "ORPHAN"`.
  The identical predicate is used by `agg_access_records` (single source
  shared by REQ2 and REQ3). UNVERIFIED rows are excluded (the APP server
  never received them, so no access occurred).
- **IP key**: `$11` (CLIENT_IP) coalesced — empty or `"-"` → sentinel `"-"`.
  The `"-"` sentinel surfaces the real upstream logging gap (missing
  CLIENT_IP fields) rather than silently omitting those records.
- **Sort order**: count descending, IP ascending for tie-breaking.
- **Schema**: TSV header `CLIENT_IP<TAB>REQUEST_COUNT`, then data rows.
  Empty corpus → header-only file (exactly 1 line).
- **Scope**: covers `--region`, `all`, and `--merge` automatically (reads
  `_ACC_SORTED`, the same post-correlation array used for rendering).
- **Never on stdout**: the file is a side artifact; it never appears in the
  console mirror or `--emit-stats` output.
- **`agg_access_records` guard**: malformed `APP_TIME` (fails
  `/^([01][0-9]|2[0-3])$/` on `substr($3,12,2)`) emits a `[WARN]` to
  stderr and is excluded from the hourly hour-key — but its IP is still
  counted (fail-loud, not silent; matches the existing graceful-degradation
  precedent for `ts_to_epoch` returning `N/A`).

**Verified sample (2026-05-21, --region all, default --test-hosts exclude):**
```
CLIENT_IP	REQUEST_COUNT
-	9
```
(All 9 business CLIENT_IPs are blank upstream under `exclude` mode. With
`--test-hosts all`: an additional row `192.168.139.110<TAB>3` appears with
the IP attribution for the QA test host. With `--test-hosts only`: one row
`192.168.139.110<TAB>3`.)

---

### 3.2 `analyze_iis.sh` — IIS W3C log analysis

#### 3.2.1 Purpose
Surface HTTP-level signals from **business traffic only**: request volume,
status-code distribution, slow endpoints, and unique client IPs. `/health`
requests are unconditionally excluded from all aggregation; test-host IPs are
filtered per `--test-hosts` mode (default: `exclude`). See §3.2.14.

#### 3.2.2 Timezone correction (UTC+0 → UTC+8)

IIS W3C logs carry timestamps in **UTC+0**. The business/reference timezone
(access CSV and .NET app logs) is **UTC+8**. A UTC+8 local day `D` equals
UTC `[D−1 16:00:00, D 16:00:00)` (cutoff = 24 − `IIS_UTC_OFFSET_HOURS` = 16).

**File selection:** for a requested local range `[START, END]`, the analyser
reads files `u_ex(START−1) .. u_ex(END)` (the D−1 file is prepended to
capture the UTC evening hours that map to local midnight–07:59). If the
prior-day file is absent (e.g. `u_ex260517` when `START` is the first
available date), the existing `[[ -f ]]` guard skips it silently — the
boundary is incomplete for the first local morning but does not abort.

**Row filter:** after file selection, `AGG_IIS_AWK` applies a half-open UTC
string-bounds guard:

```
TZ_LO = (START − 1) " 16:00:00"   inclusive
TZ_HI =  END        " 16:00:00"   exclusive
keep row  ⟺  TZ_LO ≤ ($1 " " $2) < TZ_HI
```

`$1` (`YYYY-MM-DD`) and `$2` (`HH:MM:SS`) are fixed-width zero-padded W3C
fields, so lexicographic string comparison is chronologically exact — no
`mktime`, no host-`TZ` dependency.

**Worked midnight example** (`--date 2026-05-21`; `TZ_LO="2026-05-20 16:00:00"`,
`TZ_HI="2026-05-21 16:00:00"`):

| UTC `$1 $2` | Local (+8h) | Result |
|---|---|---|
| `2026-05-20 15:59:00` | 2026-05-20 23:59 | DROP (prior local day) |
| `2026-05-20 16:30:00` | 2026-05-21 00:30 | **KEEP** |
| `2026-05-21 10:48:18` | 2026-05-21 18:48 | **KEEP** |
| `2026-05-21 16:00:00` | 2026-05-22 00:00 | DROP (next local day) |

**Single source of truth:** `IIS_UTC_OFFSET_HOURS=8` and `iis_utc_window`
live in `lib/date_utils.sh`; the string-bounds filter guard lives in
`AGG_IIS_AWK` in `lib/aggregate_utils.sh`. These are the only two places
where the +8h semantic exists. `analyze_iis` and `analyze_overview` are
pure consumers — no TZ logic is duplicated.

**`--date D` semantics:** `analyze_iis --date D` now means the UTC+8 business
day `D`. The display window (`dates.txt`) is unchanged; the IIS file-selection
list (`iis_dates.txt`) is formed by prepending `date_add(START, -1)`.
Access and .NET app logs are natively UTC+8 and are not affected.

**Numerics on the bundled sample:** all non-`/health` IIS rows in the sample
dataset have UTC time < 16:00:00 — the +8h shift is architecturally required
but numerically inert on this dataset (no business counts change).

#### 3.2.3 Inputs

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

#### 3.2.4 Endpoint grouping

The raw `cs-uri-stem` contains DICOM study and series UIDs which would
explode the cardinality of any endpoint count. The analyser collapses three
DICOM-specific path families before counting:

```
/api/NhiPatientImage/studies/{uid}/series/{uid}/...
/api/NhiPatientImage/studies/{uid}/series-uid
/api/NhiPatientImage/studies/{uid}/instances/{uid}
```

Other paths are reported verbatim.

#### 3.2.5 Aggregated signals

All metrics apply to **business requests only**: `/health` requests are
excluded unconditionally (exact stem match `cs-uri-stem == "/health"`,
case-sensitive; the query-string field is separate, so `/health?x=1` still
matches on the stem; `/healthz` and `/Health` are NOT filtered — intentional,
matches prior semantics). Test-host IPs are filtered per `--test-hosts` mode
before any counting (§3.2.14).

| Metric             | Definition                                                                          |
|--------------------|-------------------------------------------------------------------------------------|
| `total`            | Business requests parsed (after /health exclusion and test-host mode applied)       |
| `status_count[]`   | Per-status-code count (e.g. 200, 302, 404) — descriptive Top-N distribution, business-only |
| `slow`             | Rows where `time-taken >= threshold`; threshold is `--slow-api-ms` (default 2000 ms) for API-role servers and `--slow-app-ms` (default 5000 ms) for APP-role servers |
| `client_ips`       | Hash of `c-ip → request_count`; `length()` yields unique-IP count; iterated for the per-IP table. `-` excluded. |
| `top endpoints`    | Top-N endpoints by request count (after DICOM grouping), N controlled by `--top` (default 10, 0=all); each with **mean response time** in seconds (2 dp). **GAP-3 caveat:** each server emits only its own top-N endpoint rows, so the summary-view per-endpoint avg / pct / count are pooled over a **per-server-capped subset** — not the full request population for endpoints that fall outside a server's top N. CATEGORY pooling (雲端查詢 / 報告摘要 / 影像下載) is uncapped and accumulates every matching row. External reproduction of per-endpoint avgs must replicate the per-server cap to get identical numbers. |
| `client_ip_roster` | Top-N unique `c-ip` values with request count and `% of total`, N controlled by `--top` (0=all) |

The `% of total` denominator for all three tables is the `total` business
requests count for that server or bucket. When `--top` truncates the endpoint
or client-IP list, the visible rows' percentages will not sum to 100.

#### 3.2.6 Single computation source

`main()` builds each server's `$combined` once, runs `agg_iis_rows` once per
corpus (writing dimensioned rows with `region role server` prefix to
`iis_stats.tsv`), and never re-parses logs. Pure renderers read `iis_stats.tsv`.

#### 3.2.7 Views

`--view detail` (standalone default — D2): the per-server report layout
described in §3.2.8–3.2.9. No information loss.

`--view summary` (management text; format-independent — always text): concise
KPIs + % for each scope (overall header, then per region→server, or merged
buckets). Includes a `資料範圍` (scope) management banner showing the traffic
universe (business requests; /health excluded; test-hosts mode). Top-3
enumerations only; omits full tables. Every line carries a %.

The summary's **Top 端點 (佔比 · 平均回應時間)** sub-block lists up to `--top`
endpoints with right-aligned rank numbers (` 1.` … `10.`, fixed-width `%2d.`
to prevent column shift at rank 10), percentage of total, and per-endpoint
average response time in seconds. The avg/pct/count are pooled over the
per-server top-N set (see GAP-3 caveat in §3.2.5).

**The summary view is always text regardless of `--format`** (C10). `--format`
governs only the detail file extension and render path.

#### 3.2.8 Detail text output (--format text)

For each server in the selected region(s), or each role bucket under `--merge`:

1. `Scope` banner — `business requests (excl. /health; test-hosts=MODE)` — so
   the reader knows exactly which traffic universe is being reported.
2. Top-line counters: `Total requests`, `Unique client IPs`, `Slow (>Nms)` —
   the threshold value in the label reflects the server's role.
3. HTTP status-code table — columns `["Status", "Count", "% of total"]`,
   sorted by count descending. Sorting happens in-gawk (no external `sort`).
4. Endpoint table — columns `["Endpoint", "Avg(s)", "Count", "% of total"]`,
   sorted by count descending. Capped at `--top` rows (default 10; 0=all).
5. Client IP table — columns `["Client IP", "Count", "% of total"]`, sorted
   by count descending. Capped at `--top` rows. Empty when all rows have
   `c-ip = -`.

IIS tables are exclusively count-descending ranked lists; there is no
per-record chronological detail list.

#### 3.2.9 Detail machine-readable output (--format tsv|csv)

Real long-format table (NEW — was a no-op+warn before this refactor). One
standardized record per metric row; header emitted once; `--top` cap applied
to ENDPOINT and CLIENT_IP rows. Column schema:

```
REGION  ROLE  SERVER       METRIC    KEY                COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37  SUMMARY   TOTAL              723    -        100.0
taipei  api   10.22.63.37  SUMMARY   SLOW               2      -        0.3
taipei  api   10.22.63.37  STATUS    200                631    -        87.3
taipei  api   10.22.63.37  ENDPOINT  /api/Auth/IssueTok 5000   0.12     12.5
taipei  api   10.22.63.37  CLIENT_IP 192.168.139.119    712    -        98.5
```

`TOTAL` and all derived rows count business requests only. The `SUMMARY`
rows are `TOTAL`, `SLOW`, and `UNIQUE_IPS`; the former `5XX`, `503_HEALTH`,
and `REDIRECT` SUMMARY rows have been removed.

CSV uses the shared `q()` RFC-4180 quoter (`AGG_CSV_FUNC`). TSV uses TAB
delimiter with no quoting. Both persisted files carry no ANSI color.

#### 3.2.10 Per-role slow thresholds

`--slow-api-ms` (default 2000 ms) applies to servers listed in `REGION_APIS`;
`--slow-app-ms` (default 5000 ms) applies to servers in `REGION_APPS`. Role
membership is resolved via `conf/regions.conf`. The defaults reflect the
tighter SLA expected of API token-issuance endpoints versus APP DICOM-serving
endpoints. The `Slow (>Nms)` label in the report shows the actual threshold
used for that server's role.

#### 3.2.11 `--top` flag

Controls the maximum number of rows shown in both the Endpoint table and the
Client IP table (default 10; 0=all). The same cap applies to both tables in
the same invocation. The flag is unified across `analyze_iis` and
`analyze_errors` (same name, same 0=all semantics, different target list).

#### 3.2.12 `--merge` — two-bucket cross-region corpus

Under `--merge`, `analyze_merged_iis` builds two corpora by iterating over all
configured regions:

- **API corpus**: concatenates IIS logs from every region's `REGION_APIS` servers.
- **APP corpus**: concatenates IIS logs from every region's `REGION_APPS` servers.

`agg_iis_rows` runs once per corpus, producing two output blocks:
1. `IIS — API_SERVERS (merged, all regions)` — uses `--slow-api-ms` threshold.
2. `IIS — APP_SERVERS (merged, all regions)` — uses `--slow-app-ms` threshold.

#### 3.2.13 `--emit-stats`

Prints `iis_stats.tsv` verbatim to stdout, then returns before `persist_init`
(no files, no banners). This is `analyze_overview.sh`'s data source.

#### 3.2.14 Test-host filtering and `/health` exclusion

Two pre-filters run at the read stage inside `agg_iis_rows` (in
`lib/aggregate_utils.sh`), in this fixed order:

1. **`/health` unconditional exclusion** — any row where `cs-uri-stem ==
   "/health"` (exact, case-sensitive field equality) is dropped before any
   counter is incremented, in all `--test-hosts` modes. This is the business
   universe boundary: health probes account for 95.4% of raw IIS traffic in
   the sample dataset and represent infrastructure checks, not business
   requests. Note: `/healthz`, `/Health`, and `/health?query=...` are NOT
   filtered (the query string is a separate IIS field; only the stem matches).

2. **Test-host IP filter** — after `/health` is dropped, the `--test-hosts`
   mode is applied on `c-ip` (field 9) using the predicate `TH_FILTER_FUNC`
   from `lib/common.sh`:
   - `exclude` (default) — drops rows whose `c-ip` is in `conf/test_hosts.conf`.
   - `only` — keeps only rows from IPs listed in `conf/test_hosts.conf`
     (useful for auditing internal/QA non-health client traffic).
   - `all` — keeps all rows regardless of IP (equivalent to no IP filter).

**`conf/test_hosts.conf`** — one IPv4 per line, `#` comments allowed. The
seeded IPs are `192.168.139.79`, `192.168.139.110`, `192.168.139.28`.
`192.168.139.28` is the health-probe host (95.4% of IIS traffic is `/health`
from this IP, which is already removed by filter 1). `192.168.139.110` is a
QA host (209 business requests/week). Note: `192.168.139.119` is the
production gateway (712 business hits/week) and must **not** be in this file.

The file is **required** on every `analyze_iis` / `analyze_access` run,
including `--test-hosts all` (where the set is not consulted). A missing
file aborts with `die` — fail-fast parity with `regions.conf`.

**`load_test_hosts`** and **`TH_FILTER_FUNC`** live in `lib/common.sh`
(beside `assert_enum`/`die`). They are the first true shared loader/predicate
in `common.sh`. `load_regions` is defined per-bin and is not a shared loader.

**Dependency-health detection** (Oracle-outage): the former IIS 503-on-`/health`
signal has been intentionally removed as part of the business-only exclusion.
Oracle-dependency failures remain fully observable via `analyze_errors` (§3.3),
which reads the `.NET` app logs. No actionable signal is lost — the detection
simply lives only in the errors module now.

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
the resolved **base dir** and timestamp so every child uses the same values:

```bash
persist_init "$OPT_OUTPUT_DIR"
export LOG_PARSE_RUN_TS="$RUN_TS"
export LOG_PARSE_OUTPUT_DIR="$RUN_BASE_DIR"   # base, not the subdir
for m in "${MODULES[@]}"; do run_module "analyze_${m}"; done
```

Children default `OPT_OUTPUT_DIR=""` and read `$LOG_PARSE_OUTPUT_DIR` (C1);
`--output-dir` is **not** forwarded as a flag — the env carries the resolved
base dir. Each child calls `persist_init ""` which reads `$LOG_PARSE_OUTPUT_DIR`
as `RUN_BASE_DIR` and `$LOG_PARSE_RUN_TS` as `RUN_TS`, deriving the same
`RUN_OUTPUT_DIR = <base>/<RUN_TS>` without double-nesting. A
`log_report --output-dir /custom` run correctly lands every child file in
`/custom/<RUN_TS>/`. Each child self-persists its own file pair.
`log_report`'s own stdout is the concatenation of each child's selected-view
console mirror.

A default run produces exactly six files sharing one `RUN_TS` under one
`<base>/<RUN_TS>/` subdir: `overview_summary.txt`, `iis_summary.txt`,
`iis_detail.txt`, `access_summary.txt`, `access_detail.txt`,
`access_ip_counts.tsv`.

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
| `--test-hosts` | F→{overview,iis,access} | F | F | F | **no** | `exclude`; errors has no client IP |

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
layout: `<base>/<RUN_TS>/<module>_<kind>.<ext>`.

| Component | Values |
|---|---|
| `base` | resolved output directory (`--output-dir` \| `$LOG_PARSE_OUTPUT_DIR` \| `./log-parse`) |
| `RUN_TS` | `YYYYMMDD_HHMMSS` — the run-directory name (shared timestamp per run) |
| `module` | `overview`, `iis`, `access`, `errors` |
| `kind` | `summary`, `detail`, or `ip_counts` (access only) |
| `ext` | `txt` for summary (always); `txt`, `tsv`, or `csv` for detail; `tsv` for ip_counts |

**Run-directory rule**: all files produced by one top-level invocation (or
one `log_report` run) land in a single `<base>/<RUN_TS>/` subdir. The
directory name IS the run timestamp; filenames carry no per-file TS suffix.
`log_report` calls `persist_init` once and exports `LOG_PARSE_RUN_TS` so
every child process reads the same timestamp and re-derives the same subdir
without double-nesting.

**Sanctioned globals** (set by `persist_init`, read-only elsewhere):
`RUN_BASE_DIR` — resolved base dir; `RUN_TS` — launch timestamp;
`RUN_OUTPUT_DIR = RUN_BASE_DIR/RUN_TS` — the concrete per-run directory.

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

**Overview** writes only a summary file (`overview_summary.txt` under the
run directory); no detail file is produced.

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
| `--test-hosts` | yes | yes | yes | **no** | fwd→overview,iis,access | `exclude` |
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

- IIS timestamps are UTC+0; `analyze_iis` and `analyze_overview` correct for
  UTC+8 business time via a half-open UTC window filter (`iis_utc_window` in
  `lib/date_utils.sh`). Access and .NET app logs are natively UTC+8 and are
  not adjusted. `analyze_errors` uses `.NET` app logs directly (UTC+8); no TZ
  correction is applied to that module.
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
