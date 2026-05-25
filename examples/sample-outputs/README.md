# Sample Outputs

> **Language**: **English** · [繁體中文](README.zh-TW.md)

Pre-generated reports from the bundled sample dataset
(`examples/sample-logs/LUNG-CANCER-REPORT-LOG/`, dates 2026-05-18 → 2026-05-25).

These are committed verbatim so reviewers can preview the toolkit's
output without setting up the runtime. Regenerate at any time with the
command shown next to each file.

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `access_taipei_2026-05-21.txt`           | Taipei single-day access correlation (1 NORMAL, 5 ORPHAN) | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `access_taichung_2026-05-21.txt`         | Taichung single-day (all NORMAL flows)                  | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung` |
| `access_taipei_week.txt`                 | Taipei date range 2026-05-21 → 2026-05-25               | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-21 --to 2026-05-25 --region taipei` |
| `access_all_week.tsv`                    | TSV output for downstream pipelines                     | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-21 --to 2026-05-25 --format tsv` |
| `iis_taipei_2026-05-21.txt`              | Taipei IIS metrics — status mix, top endpoints          | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `iis_taichung_2026-05-21.txt`            | Taichung IIS — note the 50 Health-503 events            | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung` |
| `iis_all_slow3000_2026-05-21.txt`        | Performance audit with `--slow-ms 3000`                 | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --slow-ms 3000` |
| `errors_taipei_2026-05-21.txt`           | Taipei errors — restart events, no DB failures          | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `errors_taichung_top20_2026-05-21.txt`   | Taichung errors — 44 OracleDB failures, top 20 patterns | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --top 20` |
| `log_report_full_2026-05-21.txt`         | Full orchestrated report — all modules, both regions    | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21` |
| `log_report_taipei_partial_2026-05-21.txt` | Partial modules (access + errors) for Taipei only     | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --modules access,errors` |

All outputs were generated with `NO_COLOR=1` so they remain readable in
plain text. Live runs in a TTY render the same content in colour.
