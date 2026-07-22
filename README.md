# log-parse

> Cross-region log analysis toolkit for the LUNG-CANCER-REPORT system.
> Correlates access tokens, surfaces IIS anomalies, and tracks application
> lifecycle events across paired API / APP servers.

[![Tests](https://img.shields.io/badge/tests-358%2F358-brightgreen)](tests/run_tests.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-lightgrey)](https://www.gnu.org/software/bash/)

**Language**: **English** · [繁體中文](README.zh-TW.md)

---

## What it does

The toolkit consumes raw daily logs from six servers organised into two
geographic regions (Taipei / Taichung) and produces correlated reports:

| Module               | Inputs                                        | Produces                                                                              |
|----------------------|-----------------------------------------------|---------------------------------------------------------------------------------------|
| `analyze_overview`   | IIS + Access stats via `--emit-stats`         | Management overview: two-cut layout — ▶ 總體概況 (access NORMAL/ORPHAN/UNVERIFIED value+%; 整體健康判定 verdict >=90 正常/>=70 注意/<70 警告; ■ 核心功能效能 sub-block: 雲端查詢/報告摘要/影像下載 呼叫次數+回應時間; 核心功能存取合計) / ▶ 分區別 (per-region 存取關聯 N 筆 N/O/U prose + same three categories 呼叫次數+回應時間); summary-only, text-only |
| `analyze_access`     | API + APP access CSVs                         | Token-issuance ↔ verification flows, orphan / unverified usage; `--view summary|detail` |
| `analyze_iis`        | IIS W3C extended logs                         | Business-only request metrics: slow requests, endpoint breakdown, status distribution; `--view summary|detail` |
| `analyze_errors`     | `app-all` / `app-error` / `app-lifetime`      | OracleDB outages, top error patterns, restart downtime                                |
| `log_report`         | All of the above                              | Orchestrator; default modules: `overview,iis,access`; errors opt-in via `--modules`; optionally mails the persisted bundle via `--notify` (see [Notification](docs/usage.md#notification)), and can export a `連線紀錄.xlsx` deliverable via `--report-export` (see [Report export](docs/usage.md#report-export)) |

All reports default to **business traffic only**: `/health` is excluded unconditionally from all IIS aggregation, and internal test-host IPs listed in `conf/test_hosts.conf` are pre-filtered by `--test-hosts exclude|only|all` (default: `exclude`). `Total requests` / `IIS 總請求數` therefore reflect real external user traffic only.

Every run automatically persists reports to `./log-parse/` under the current working
directory (override with `--output-dir DIR` or `$LOG_PARSE_OUTPUT_DIR`). Layout:
`<base>/<YYYYMMDD_HHMMSS>/<module>_<kind>.<ext>`, where the timestamp names the
run directory (shared by every file from that run, not appended to the filename).
Files are always color-free; stdout is a clean pipeable mirror of the selected view
(`--view summary|detail`).

See [`docs/design.md`](docs/design.md) for the full data-flow and field
semantics, and [`docs/usage.md`](docs/usage.md) for every CLI flag.

---

## Quick start

```bash
# 1. Verify dependencies
make install-deps

# 2. Run the full battery against the sample dataset
make report LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG REGION=all DAYS=7

# 3. Or invoke a single module
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei
```

### Common scenarios

```bash
# Management overview — all regions, last 7 days (two-cut: 總體概況+核心功能 / 分區別+N/O/U)
bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# Daily ops snapshot for a specific date (default modules: overview→iis→access)
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21

# Security investigation — orphan tokens for Taipei
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7

# DB troubleshooting — top error patterns for Taichung (opt-in via --modules)
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --top 20

# Weekly digest with errors; reports written to ./reports/
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --modules overview,iis,access,errors \
    --output-dir ./reports

# Performance audit — IIS detail export as CSV (API >3s, APP >3s)
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 3000 --slow-app-ms 3000 --format csv --view detail
```

---

## Repository layout

```
.
├── bin/                     Executable CLI entry points
│   ├── analyze_access.sh    API/APP token cross-correlation
│   ├── analyze_iis.sh       IIS W3C log analysis
│   ├── analyze_errors.sh    Application error & lifecycle analysis
│   ├── analyze_overview.sh  Management overview (two-cut: 總體概況/分區別; 核心功能 sub-blocks)
│   └── log_report.sh        Master orchestrator (default: overview→iis→access)
├── lib/                     Reusable shell modules (sourced-only)
│   ├── common.sh            Logging, tmpdir, dependency checks, color state
│   ├── date_utils.sh        Date range generation, interval-mutex validator
│   ├── csv_utils.sh         Access / IIS / app-log field extraction
│   ├── fmt_utils.sh         Report formatting helpers
│   ├── output_utils.sh      Always-on report persistence (persist_init/persist_views)
│   ├── aggregate_utils.sh   Shared metric computation & CSV quoter (AGG_IIS_AWK)
│   ├── notify_utils.sh      SMTP-API report delivery (--notify; curl/base64 optional)
│   └── report_export_utils.sh  report-export container integration (--report-export; docker optional)
├── conf/
│   ├── regions.conf         Region ↔ server mapping
│   ├── test_hosts.conf      QA / health-probe client IPs (filter with --test-hosts)
│   └── receivers.conf       Mail recipients for --notify (DISPLAY_NAME|ADDRESS)
├── docs/
│   ├── design.md / design.zh-TW.md   Architecture & data-flow specification
│   └── usage.md  / usage.zh-TW.md    Full CLI reference & worked examples
├── examples/
│   ├── sample-logs/         Bundled sample log dataset
│   ├── sample-outputs/      Sample rendered reports
│   └── *.sh                 Scenario-driving scripts
├── tests/
│   └── run_tests.sh         358-test functional suite
├── report-export/           Independent Python subtool: weekly xlsx export
│   ├── src/report_export/   Package (pure-function core + I/O boundary)
│   ├── docs/                design.md · usage.md · data-fidelity.md (zh-TW)
│   ├── reference/           Bundled HOSP_ID→HOSP_ABBR lookup (gz)
│   ├── docker/              Dockerfile + compose + committed example/ demo
│   ├── tests/               391-test pytest suite (unit + e2e)
│   └── README.md            Subtool quick start (zh-TW)
├── .claude/
│   ├── CLAUDE.md            Core conventions (auto-loaded every session)
│   ├── rules/               Path-scoped detailed conventions (loaded on demand)
│   └── skills/              Project automation skills (e.g. feature-workflow)
├── CHANGELOG.md             Release history
├── LICENSE                  MIT
└── Makefile                 Convenience targets (test / lint / report)
```

---

## Requirements

- **Bash** ≥ 4.0
- **GNU awk** (`gawk`) — used for all field extraction and correlation
- **GNU date** — used for date arithmetic (Linux-native; on macOS install
  `coreutils` and alias `gdate` → `date`)
- **coreutils**: `sort`, `mktemp`, `head`, `tail`
- **Optional** (only when `--notify` is used): `curl` (HTTP POST), `base64`
  (attachment encoding) — checked lazily; every other workflow is
  unaffected even without them. See [Notification](docs/usage.md#notification).
- **Optional** (only when `--report-export` is used): `docker` (runs the
  companion `report-export` image) — checked lazily; every other workflow
  is unaffected even without it. See [Report export](docs/usage.md#report-export).

Verify with `make install-deps`.

---

## Configuration

Region ↔ server mappings live in [`conf/regions.conf`](conf/regions.conf):

```
# REGION_ID|REGION_NAME|API_SERVERS|APP_SERVERS
taipei|台北|10.22.63.37|10.21.3.35,10.21.3.36
taichung|台中|10.1.73.37|10.1.72.35,10.1.72.36
```

Override at runtime with `--conf /path/to/custom.conf`.

---

## Testing

```bash
make test            # runs tests/run_tests.sh
```

The suite covers all five scripts, both regions, every parameter combination,
validation paths, interval-mutex checks, persistence assertions, and scenario
simulations. Baselines are derived from the bundled
`examples/sample-logs/LUNG-CANCER-REPORT-LOG/` sample data.

---

## Companion subtool — report-export

An independent, self-contained Python subtool that automates the weekly
連線紀錄 (connection-log) Excel deliverable — replacing the manual
copy-paste-into-template workflow. It consumes the 14-column CSV produced
by `analyze_access --format csv`, filters to `STATUS=NORMAL`, deduplicates
by `REQUEST_ID` into its own canonical CSV state, and regenerates a
2-sheet pure-value `.xlsx` (調閱紀錄 + 院所分析) on every run.

[![report-export tests](https://img.shields.io/badge/tests-391%2F391-brightgreen)](report-export/tests/)
[![report-export coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)](report-export/pyproject.toml)

It shares **no code** with the bash/gawk toolkit above and runs via Docker
or Python 3.12+, entirely independently of everything else in this
repository. See [`report-export/README.md`](report-export/README.md) for
quick start, and [`report-export/docs/`](report-export/docs/)
(`design.md` / `usage.md` / `data-fidelity.md`, zh-TW) for the full design
and operations reference.

---

## Documentation

| Document                            | Audience           | Purpose                                                    |
|-------------------------------------|--------------------|------------------------------------------------------------|
| [`docs/design.md`](docs/design.md)  | New contributors   | Architecture, modules, data flow, output field semantics   |
| [`docs/usage.md`](docs/usage.md)    | Operators / SREs   | Every CLI flag with copy-pasteable examples                |
| [`.claude/CLAUDE.md`](.claude/CLAUDE.md) | AI assistants & devs | Coding conventions, bash idioms, awk patterns            |
| [`CHANGELOG.md`](CHANGELOG.md)      | Everyone           | Release history (Keep a Changelog format)                  |
| [`report-export/README.md`](report-export/README.md) | Ops (weekly xlsx export) | Independent Python subtool; NORMAL→dedup→2-sheet xlsx; zh-TW docs |

---

## License

[MIT](LICENSE) © 2026 log-parse contributors
