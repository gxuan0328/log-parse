# Sample Outputs

> **Language**: **English** · [繁體中文](README.zh-TW.md)

Pre-generated reports from the bundled sample dataset
(`examples/sample-logs/LUNG-CANCER-REPORT-LOG/`, dates 2026-05-18 → 2026-05-25).

These are committed verbatim so reviewers can preview the toolkit's
output without setting up the runtime. Regenerate at any time with the
command shown next to each file, or run `make samples-regen` to rebuild
all fixtures deterministically.

## Persistence model

Every run writes files to a directory (default `./log-parse/`, overridden by
`--output-dir DIR` or `$LOG_PARSE_OUTPUT_DIR`). Runtime filenames include a
launch timestamp: `<module>_<kind>_<YYYYMMDD_HHMMSS>.<ext>`. The committed
fixtures below use stripped/descriptive names without the volatile timestamp.
Pin `LOG_PARSE_RUN_TS=20260521_000000` to produce exact-match filenames.

All outputs are generated with `NO_COLOR=1` so they remain readable in
plain text. Live runs in a TTY render the same content in colour.

## Overview

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `overview_all_week.txt`               | Management overview — all regions, 2026-05-18 → 2026-05-25 (8 days); 三視角 layout: 總體概況/分區別/服務別; summary-only, text-only | `bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --output-dir /tmp/sample` |
| `overview_taipei_week.txt`            | Management overview — taipei region only, 2026-05-18 → 2026-05-25; single-region 分區別 + 服務別 | `bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --region taipei --output-dir /tmp/sample` |

## IIS

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `iis_summary_all_2026-05-21.txt`     | IIS management summary (all regions, single day); KPI+%, Top-3 endpoints/status/client-IP; format-independent text | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --view summary --output-dir /tmp/sample` |
| `iis_all_2026-05-21.txt`             | IIS detail view — all regions, default per-role slow thresholds (API >2000ms, APP >5000ms); per-server KV block + Status/Endpoint/Client-IP tables | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `iis_taipei_2026-05-21.txt`          | Taipei IIS detail — per-role slow thresholds; Endpoint with Avg(s)/Count/% of total, Status with % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `iis_taichung_2026-05-21.txt`        | Taichung IIS detail — Health-503 events; Endpoint with Avg(s)/Count/% of total, Status with % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --output-dir /tmp/sample` |
| `iis_all_merged_2026-05-21.txt`      | Cross-region merged IIS detail; two blocks: API_SERVERS (>2000ms) and APP_SERVERS (>5000ms) | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge --output-dir /tmp/sample` |
| `iis_detail_all_2026-05-21.tsv`      | IIS detail — TSV long-format (REGION/ROLE/SERVER/METRIC/KEY/COUNT/AVG_SEC/PCT columns); one header, all servers | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --format tsv --output-dir /tmp/sample` |
| `iis_detail_all_2026-05-21.csv`      | IIS detail — CSV (RFC-4180); same schema as TSV; suitable for spreadsheet import | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --format csv --output-dir /tmp/sample` |

## Access correlation

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `access_summary_all_2026-05-21.txt`  | Access management summary (all regions, single day); NORMAL/ORPHAN/UNVERIFIED counts+%, latency stats, per-region breakdown | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --view summary --output-dir /tmp/sample` |
| `access_detail_all_2026-05-21.txt`   | Access detail — all regions, 2026-05-21; per-region NORMAL/ORPHAN/UNVERIFIED record tables with PATIENT_ID_AES | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `access_taipei_2026-05-21.txt`       | Taipei single-day access detail (1 NORMAL, 5 ORPHAN); per-category headers, full PATIENT_ID_AES, merged REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `access_taichung_2026-05-21.txt`     | Taichung single-day access detail (all NORMAL flows); per-category headers, full PATIENT_ID_AES, merged REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --output-dir /tmp/sample` |
| `access_taipei_week.txt`             | Taipei date range 2026-05-18 → 2026-05-25; detail view | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --region taipei --output-dir /tmp/sample` |
| `access_all_week.tsv`                | TSV flat output (all regions, week) for downstream pipelines; deterministic ASC sort, single REQUEST_ID column | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format tsv --output-dir /tmp/sample` |
| `access_all_week.csv`                | CSV flat output (all regions, week) with RFC-4180 conditional quoting; same deterministic sort as TSV | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format csv --output-dir /tmp/sample` |
| `access_all_merged_2026-05-21.txt`   | Cross-region merged correlation detail (all regions treated as one host-agnostic corpus); merged NORMAL count >= sum of per-region | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge --output-dir /tmp/sample` |

## Errors

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `errors_summary_taipei_2026-05-21.txt` | Errors management summary (taipei, single day); per-server Total ERROR, OracleDB failures, restart count — persisted on disk only (no `--view`; console shows detail) | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_taipei_2026-05-21.txt`        | Taipei errors detail (= console output) — restart events, no DB failures | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_detail_taipei_2026-05-21.txt` | Taipei errors detail file (same content as `errors_taipei_2026-05-21.txt`; shows persisted filename convention) | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_taichung_top20_2026-05-21.txt` | Taichung errors detail — 44 OracleDB failures, top 20 patterns | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --top 20 --output-dir /tmp/sample` |

## Combined report (log_report)

| File | What it shows | Reproduce |
|------|---------------|-----------|
| `log_report_full_2026-05-21.txt`          | Full orchestrated report — default modules (overview → iis → access), summary view, all regions, single day; console mirror of all three modules concatenated | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `log_report_taipei_partial_2026-05-21.txt` | Partial modules (iis + access) for taipei only, summary view; canonical order (iis then access) regardless of `--modules` input order | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --modules iis,access --output-dir /tmp/sample` |
