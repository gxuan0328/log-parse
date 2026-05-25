#!/usr/bin/env bash
# examples/weekly_digest.sh — Weekly per-module digest (last Mon–Sun).
#
# Usage:  bash examples/weekly_digest.sh [LOG_DIR]
# Output: ./reports/weekly/{access,iis,errors}_<timestamp>.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${1:-${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG}"
REPORT_DIR="${PROJECT_DIR}/reports/weekly"

START="$(date -d 'last monday' +%F)"
END="$(date -d 'last sunday' +%F)"

mkdir -p "$REPORT_DIR"

bash "${PROJECT_DIR}/bin/log_report.sh" \
    --log-dir "$LOG_DIR" \
    --from "$START" --to "$END" \
    --output-dir "$REPORT_DIR"

echo "[OK] Weekly digest (${START} → ${END}) written to ${REPORT_DIR}"
