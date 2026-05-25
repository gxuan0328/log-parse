#!/usr/bin/env bash
# examples/daily_ops.sh — Daily operations digest for the current day.
#
# Usage:  bash examples/daily_ops.sh [LOG_DIR]
# Output: ./reports/daily_<YYYY-MM-DD>.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${1:-${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG}"
REPORT_DIR="${PROJECT_DIR}/reports"
TODAY="$(date +%F)"

mkdir -p "$REPORT_DIR"

bash "${PROJECT_DIR}/bin/log_report.sh" \
    --log-dir "$LOG_DIR" \
    --date "$TODAY" \
    --output "${REPORT_DIR}/daily_${TODAY}.txt"

echo "[OK] Daily report written to ${REPORT_DIR}/daily_${TODAY}.txt"
