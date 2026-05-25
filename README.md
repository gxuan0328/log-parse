# log-parse

> Cross-region log analysis toolkit for the LUNG-CANCER-REPORT system.
> Correlates access tokens, surfaces IIS anomalies, and tracks application
> lifecycle events across paired API / APP servers.

[![Tests](https://img.shields.io/badge/tests-103%2F103-brightgreen)](tests/run_tests.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-lightgrey)](https://www.gnu.org/software/bash/)

**Language**: **English** · [繁體中文](README.zh-TW.md)

---

## What it does

The toolkit consumes raw daily logs from six servers organised into two
geographic regions (Taipei / Taichung) and produces three correlated reports:

| Module          | Inputs                                  | Detects                                                        |
|-----------------|-----------------------------------------|----------------------------------------------------------------|
| `analyze_access`| API + APP access CSVs                   | Token-issuance ↔ verification flows, orphan / unverified usage |
| `analyze_iis`   | IIS W3C extended logs                   | 5xx error spikes, slow requests, health-check 503 anomalies    |
| `analyze_errors`| `app-all` / `app-error` / `app-lifetime`| OracleDB outages, top error patterns, restart downtime         |
| `log_report`    | All of the above                        | Combined orchestrator with single-file or per-module output    |

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
# Daily ops snapshot for a specific date
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21

# Security investigation — orphan tokens for Taipei
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7

# DB troubleshooting — top error patterns for Taichung
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --top 20

# Weekly digest written to per-module files
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports

# Performance audit — slow IIS requests (>3s)
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-ms 3000
```

---

## Repository layout

```
.
├── bin/                  Executable CLI entry points
│   ├── analyze_access.sh API/APP token cross-correlation
│   ├── analyze_iis.sh    IIS W3C log analysis
│   ├── analyze_errors.sh Application error & lifecycle analysis
│   └── log_report.sh     Master orchestrator
├── lib/                  Reusable shell modules
│   ├── common.sh         Logging, tmpdir, dependency checks
│   ├── date_utils.sh     Date range generation & filename mapping
│   ├── csv_utils.sh      Access / IIS / app-log field extraction
│   └── fmt_utils.sh      Report formatting helpers
├── conf/
│   └── regions.conf      Region ↔ server mapping
├── docs/
│   ├── design.md         Architecture & data-flow specification
│   └── usage.md          Full CLI reference & worked examples
├── examples/             Sample outputs & scripted scenarios
├── tests/
│   └── run_tests.sh      103-test functional suite
├── CLAUDE.md             Coding conventions & design principles
├── CHANGELOG.md          Release history
├── LICENSE               MIT
└── Makefile              Convenience targets (test / lint / report)
```

---

## Requirements

- **Bash** ≥ 4.0
- **GNU awk** (`gawk`) — used for all field extraction and correlation
- **GNU date** — used for date arithmetic (Linux-native; on macOS install
  `coreutils` and alias `gdate` → `date`)
- **coreutils**: `sort`, `mktemp`, `head`, `tail`

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

The suite covers all four scripts, both regions, every parameter combination,
validation paths, and six end-user scenario simulations. Baselines are derived
from the bundled `examples/sample-logs/LUNG-CANCER-REPORT-LOG/` sample data.

---

## Documentation

| Document                            | Audience           | Purpose                                                    |
|-------------------------------------|--------------------|------------------------------------------------------------|
| [`docs/design.md`](docs/design.md)  | New contributors   | Architecture, modules, data flow, output field semantics   |
| [`docs/usage.md`](docs/usage.md)    | Operators / SREs   | Every CLI flag with copy-pasteable examples                |
| [`CLAUDE.md`](CLAUDE.md)            | AI assistants & devs | Coding conventions, bash idioms, awk patterns            |
| [`CHANGELOG.md`](CHANGELOG.md)      | Everyone           | Release history (Keep a Changelog format)                  |

---

## License

[MIT](LICENSE) © 2026 log-parse contributors
