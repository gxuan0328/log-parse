# Sample Outputs

> **Language**: **English** · [繁體中文](README.zh-TW.md)

Pre-generated reports from the bundled sample dataset
(`examples/sample-logs/LUNG-CANCER-REPORT-LOG/`, dates 2026-05-18 → 2026-05-25).

These are committed verbatim so reviewers can preview the toolkit's
output without setting up the runtime. Regenerate at any time with the
command shown next to each file.

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `access_taipei_2026-05-21.txt`           | Taipei single-day access correlation (1 NORMAL, 5 ORPHAN); per-category headers, full PATIENT_ID_AES, merged REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `access_taichung_2026-05-21.txt`         | Taichung single-day (all NORMAL flows); per-category headers, full PATIENT_ID_AES, merged REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung` |
| `access_taipei_week.txt`                 | Taipei date range 2026-05-18 → 2026-05-25               | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --region taipei` |
| `access_all_week.tsv`                    | TSV flat output (all regions, week) for downstream pipelines; deterministic ASC sort, single REQUEST_ID column | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format tsv` |
| `access_all_week.csv`                    | CSV flat output (all regions, week) with RFC-4180 conditional quoting; same deterministic sort as TSV | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format csv` |
| `access_all_merged_2026-05-21.txt`       | Cross-region merged correlation (all regions treated as one host-agnostic corpus); merged NORMAL count >= sum of per-region | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge` |
| `iis_all_2026-05-21.txt`                 | All-region IIS report with default per-role slow thresholds (API >2000ms, APP >5000ms); Endpoint/Avg(s)/Count/% of total columns | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21` |
| `iis_taipei_2026-05-21.txt`              | Taipei IIS — per-role slow thresholds; Endpoint with Avg(s)/Count/% of total, Status with % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `iis_taichung_2026-05-21.txt`            | Taichung IIS — Health-503 events; Endpoint with Avg(s)/Count/% of total, Status with % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung` |
| `iis_all_merged_2026-05-21.txt`          | Cross-region merged IIS split into two blocks: API_SERVERS (>2000ms) and APP_SERVERS (>5000ms) | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge` |
| `errors_taipei_2026-05-21.txt`           | Taipei errors — restart events, no DB failures          | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei` |
| `errors_taichung_top20_2026-05-21.txt`   | Taichung errors — 44 OracleDB failures, top 20 patterns | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --top 20` |
| `log_report_full_2026-05-21.txt`         | Full orchestrated report — all modules, both regions    | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21` |
| `log_report_taipei_partial_2026-05-21.txt` | Partial modules (access + iis) for Taipei only; demonstrates --modules forwarding | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --modules access,iis` |

All outputs were generated with `NO_COLOR=1` so they remain readable in
plain text. Live runs in a TTY render the same content in colour.
