#!/usr/bin/env bash
# examples/security_scan.sh — Surface ORPHAN tokens for the last 7 days.
#
# Useful for spotting cross-region replay or manually crafted token URLs.
# Pipeline: text report for humans + TSV for downstream SIEM ingestion.
#
# Usage:  bash examples/security_scan.sh [LOG_DIR] [REGION]
#         REGION defaults to "all"; pass "taipei" or "taichung" to narrow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${1:-${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG}"
REGION="${2:-all}"
REPORT_DIR="${PROJECT_DIR}/reports/security"
STAMP="$(date '+%Y%m%d_%H%M%S')"

mkdir -p "$REPORT_DIR"

# Human-readable report
bash "${PROJECT_DIR}/bin/analyze_access.sh" \
    --log-dir "$LOG_DIR" --region "$REGION" --days 7 \
    --output "${REPORT_DIR}/access_${REGION}_${STAMP}.txt"

# Machine-readable TSV — filter ORPHAN rows for ingestion
bash "${PROJECT_DIR}/bin/analyze_access.sh" \
    --log-dir "$LOG_DIR" --region "$REGION" --days 7 --format tsv \
| awk -F'\t' 'NR == 1 || $2 == "ORPHAN"' \
> "${REPORT_DIR}/orphans_${REGION}_${STAMP}.tsv"

# Host-agnostic merged ORPHAN scan: correlate tokens across ALL regions in a
# single pass (--merge requires --region all).  Tokens seen in both taipei and
# taichung are classified NORMAL here; true cross-region replays surface as
# ORPHAN/UNVERIFIED and are written to a dedicated TSV for SIEM ingestion.
bash "${PROJECT_DIR}/bin/analyze_access.sh" \
    --log-dir "$LOG_DIR" --region all --days 7 --format tsv --merge \
| awk -F'\t' 'NR == 1 || $1 == "ORPHAN"' \
> "${REPORT_DIR}/orphans_merged_${STAMP}.tsv"

echo "[OK] Security scan written to ${REPORT_DIR}"
echo "      Text : access_${REGION}_${STAMP}.txt"
echo "      TSV  : orphans_${REGION}_${STAMP}.tsv"
echo "      TSV  : orphans_merged_${STAMP}.tsv  (merged, all regions)"
