#!/usr/bin/env bash
# bin/log_report.sh
# ----------------------------------------------------------------------------
# Master orchestrator for the analysis toolkit.
#
# Resolves a shared argument set (log dir, date range, region, verbose flag)
# and forwards it to each analyser sub-process. Modules execute sequentially;
# each runs in its own process so a failure in one cannot poison shared
# state in another.
#
# Output modes:
#   - stdout (default)            : stream every module to stdout in sequence.
#   - --output FILE               : truncate FILE, append every module's output.
#   - --output-dir DIR            : write <module>_<YYYYMMDD_HHMMSS>.txt per module.
#
# See docs/design.md §3.4 for the full specification.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT=""
OPT_MODULES="access,iis,errors"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Master log analysis orchestrator. Runs all analysis modules and combines output.

Options:
  --log-dir PATH        Root log directory [required]
  --days N              Analyze last N days from today (default: $OPT_DAYS)
  --from YYYY-MM-DD     Start date (inclusive)
  --to   YYYY-MM-DD     End date   (inclusive)
  --date YYYY-MM-DD     Single date analysis
  --region REGION       Filter: taipei | taichung | all (default: all)
  --modules LIST        Comma-separated modules to run (default: $OPT_MODULES)
                        Available: access, iis, errors
  --output FILE         Write combined report to file (default: stdout)
  --output-dir DIR      Write each module to a separate file in DIR
  --conf FILE           Regions config file
  -v, --verbose         Enable debug logging
  -h, --help            Show this help

Examples:
  # Full report, last 7 days
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # Access correlation only, taipei, last 3 days
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --modules access --region taipei --days 3

  # Date range, save to separate files
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --output-dir ./reports
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_OUTPUT_DIR=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)    OPT_LOG_DIR="$2";    shift 2 ;;
            --days)       OPT_DAYS="$2";        shift 2 ;;
            --from)       OPT_FROM="$2";        shift 2 ;;
            --to)         OPT_TO="$2";          shift 2 ;;
            --date)       OPT_DATE="$2";        shift 2 ;;
            --region)     OPT_REGION="$2";      shift 2 ;;
            --modules)    OPT_MODULES="$2";     shift 2 ;;
            --output)     OPT_OUTPUT="$2";      shift 2 ;;
            --output-dir) OPT_OUTPUT_DIR="$2";  shift 2 ;;
            --conf)       REGIONS_CONF="$2";    shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG;      shift ;;
            -h|--help)    usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$OPT_LOG_DIR" ]] && die "--log-dir is required"
    [[ -d "$OPT_LOG_DIR" ]] || die "Log directory not found: $OPT_LOG_DIR"
}

# ---------------------------------------------------------------------------
# Module runner
# ---------------------------------------------------------------------------

# _SHARED_ARGS — populated by build_module_args, consumed by run_module.
# Using an array (not a string) avoids word-splitting bugs when --log-dir
# or --conf paths contain whitespace.
_SHARED_ARGS=()

# build_module_args
#   Purpose : Materialise _SHARED_ARGS based on the orchestrator's options.
#   Why if/then/fi (not [[ ]] && cmd):
#     The last `[[ cond ]] && cmd` form in this function would return 1
#     when its condition is false, and a function returning 1 IS a "simple
#     command" subject to `set -e` in the caller. That would abort
#     run_module before it could execute the analyser binary.
build_module_args() {
    _SHARED_ARGS=("--log-dir" "$OPT_LOG_DIR" "--region" "$OPT_REGION")
    if [[ -n "$OPT_DATE"  ]]; then _SHARED_ARGS+=("--date"  "$OPT_DATE");  fi
    if [[ -n "$OPT_FROM"  ]]; then _SHARED_ARGS+=("--from"  "$OPT_FROM");  fi
    if [[ -n "$OPT_TO"    ]]; then _SHARED_ARGS+=("--to"    "$OPT_TO");    fi
    if [[ -z "$OPT_DATE" && -z "$OPT_FROM" ]]; then _SHARED_ARGS+=("--days" "$OPT_DAYS"); fi
    if [[ -n "${REGIONS_CONF:-}" ]]; then _SHARED_ARGS+=("--conf" "$REGIONS_CONF"); fi
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then _SHARED_ARGS+=("--verbose"); fi
}

# run_module MODULE_NAME [OUTPUT_FILE]
#   Purpose : Invoke a named analyser as a subprocess with the shared args.
#   Args    : MODULE_NAME — analyser script name without the .sh suffix
#                            (resolves to bin/<MODULE_NAME>.sh).
#             OUTPUT_FILE — optional; when present, forwarded via --output.
#   Errors  : Aborts (die) if the analyser is missing or not executable.
run_module() {
    local module="$1" output_file="${2:-}"
    local bin="${SCRIPT_DIR}/${module}.sh"
    [[ -x "$bin" ]] || die "Module not found or not executable: $bin"

    build_module_args

    if [[ -n "$output_file" ]]; then
        log_info "Running module: $module → $output_file"
        "$bin" "${_SHARED_ARGS[@]}" --output "$output_file"
    else
        log_info "Running module: $module"
        "$bin" "${_SHARED_ARGS[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Determine module list
    IFS=',' read -ra MODULES <<< "$OPT_MODULES"

    local valid_modules=("access" "iis" "errors")
    for m in "${MODULES[@]}"; do
        local found=0
        for v in "${valid_modules[@]}"; do
            [[ "$m" == "$v" ]] && found=1 && break
        done
        (( found )) || die "Unknown module: '$m' (valid: ${valid_modules[*]})"
    done

    log_info "Modules: ${MODULES[*]}"
    log_info "Log dir: $OPT_LOG_DIR"

    if [[ -n "$OPT_OUTPUT_DIR" ]]; then
        # Write each module to a separate file
        mkdir -p "$OPT_OUTPUT_DIR"
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        for m in "${MODULES[@]}"; do
            local outfile="${OPT_OUTPUT_DIR}/${m}_${ts}.txt"
            run_module "analyze_${m}" "$outfile"
        done
        log_info "All reports written to: $OPT_OUTPUT_DIR"

    elif [[ -n "$OPT_OUTPUT" ]]; then
        # Combine all modules into a single file
        : > "$OPT_OUTPUT"
        for m in "${MODULES[@]}"; do
            run_module "analyze_${m}" >> "$OPT_OUTPUT"
        done
        log_info "Combined report written to: $OPT_OUTPUT"

    else
        # Stream all modules to stdout
        for m in "${MODULES[@]}"; do
            run_module "analyze_${m}"
        done
    fi
}

main "$@"
