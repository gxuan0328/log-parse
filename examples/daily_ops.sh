#!/usr/bin/env bash
# examples/daily_ops.sh — Daily operations digest for the current day.
#
# Usage:  bash examples/daily_ops.sh [LOG_DIR]
# Output: ./reports/daily_<YYYY-MM-DD>/ (always-on persistence; files are
#         named <module>_<kind>_<timestamp>.txt by the toolkit).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${1:-${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG}"
TODAY="$(date +%F)"
REPORT_DIR="${PROJECT_DIR}/reports/daily_${TODAY}"

mkdir -p "$REPORT_DIR"

bash "${PROJECT_DIR}/bin/log_report.sh" \
    --log-dir "$LOG_DIR" \
    --date "$TODAY" \
    --output-dir "$REPORT_DIR"

echo "[OK] Daily report written to ${REPORT_DIR}/"
