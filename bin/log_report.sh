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
# Unified options forwarded to child modules per capability matrix (§4.2):
#   Common (all modules)  : --log-dir, --region, --date/--from/--to/--days,
#                           --conf, --verbose, --format
#   access + iis only     : --merge
#   iis + errors only     : --top
#   iis only              : --slow-api-ms, --slow-app-ms
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
OPT_OUTPUT_DIR=""
OPT_MODULES="access,iis,errors"
OPT_FORMAT="text"
OPT_TOP=10
OPT_SLOW_API_MS=2000
OPT_SLOW_APP_MS=5000
OPT_MERGE=0
REGIONS_CONF=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Master log analysis orchestrator. Runs all analysis modules and combines output.
Unified options (--format, --top, --slow-*-ms, --merge) are forwarded only to
modules that accept them; see the capability matrix below.

Options:
  --log-dir PATH        [required] root log directory
  --days N              integer >= 1              (default: $OPT_DAYS)   [ignored if --date/--from set]
  --from YYYY-MM-DD     start date, inclusive     [use together with --to]
  --to   YYYY-MM-DD     end date, inclusive       [use together with --from]
  --date YYYY-MM-DD     single day                [overrides --days/--from/--to]
  --region REGION       taipei | taichung | all   (default: all)
  --modules LIST        comma-separated modules to run (default: $OPT_MODULES)
                        Available: access, iis, errors
  --output FILE         write combined report to file (default: stdout)
  --output-dir DIR      write each module to a separate file in DIR
  --conf FILE           regions config file (validated when explicitly supplied)
  --format FMT          text | tsv | csv          (default: text)
                        Forwarded to all modules; iis and errors treat non-text as no-op.
  --top N               integer >= 0, 0 = ALL     (default: $OPT_TOP)
                        Forwarded to iis (Endpoint + Client IP) and errors (pattern count).
                        Not forwarded to access.
  --slow-api-ms N       integer ms                (default: $OPT_SLOW_API_MS)
                        Forwarded to iis only; applies to API-role servers.
  --slow-app-ms N       integer ms                (default: $OPT_SLOW_APP_MS)
                        Forwarded to iis only; applies to APP-role servers.
  --merge               flag: merge all regions into one correlation/analysis pass.
                        REQUIRES --region all (default). Forwarded to access and iis.
  -v, --verbose         enable debug logging
  -h, --help            show this help

Capability matrix (forwarding targets):
  Flag             access  iis  errors
  --format           yes   yes   yes   (iis/errors: non-text is no-op)
  --merge            yes   yes    no   (requires --region all)
  --top               no   yes   yes
  --slow-api-ms       no   yes    no
  --slow-app-ms       no   yes    no

Common scenarios (runnable against the bundled dataset):

  # 1. Full report, last 7 days
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # 2. Single-date combined report, taipei only
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --region taipei --modules access,iis

  # 3. Access CSV export, all regions, date range
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --format csv --modules access

  # 4. Merged host-agnostic view with custom IIS SLA
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --merge --top 5 --slow-api-ms 1000

  # 5. Weekly audit, top-5 patterns, write to output dir
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --top 5 --slow-api-ms 3000 \\
       --output-dir ./reports
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)      OPT_LOG_DIR="$2";       shift 2 ;;
            --days)         OPT_DAYS="$2";           shift 2 ;;
            --from)         OPT_FROM="$2";           shift 2 ;;
            --to)           OPT_TO="$2";             shift 2 ;;
            --date)         OPT_DATE="$2";           shift 2 ;;
            --region)       OPT_REGION="$2";         shift 2 ;;
            --modules)      OPT_MODULES="$2";        shift 2 ;;
            --output)       OPT_OUTPUT="$2";         shift 2 ;;
            --output-dir)   OPT_OUTPUT_DIR="$2";     shift 2 ;;
            --conf)         REGIONS_CONF="$2";       shift 2 ;;
            --format)       OPT_FORMAT="$2";         shift 2 ;;
            --top)          OPT_TOP="$2";            shift 2 ;;
            --slow-api-ms)  OPT_SLOW_API_MS="$2";   shift 2 ;;
            --slow-app-ms)  OPT_SLOW_APP_MS="$2";   shift 2 ;;
            --merge)        OPT_MERGE=1;             shift ;;
            -v|--verbose)   LOG_LEVEL=DEBUG;         shift ;;
            -h|--help)      usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    if [[ -z "$OPT_LOG_DIR" ]]; then die "--log-dir is required"; fi
    if [[ ! -d "$OPT_LOG_DIR" ]]; then die "Log directory not found: $OPT_LOG_DIR"; fi
    if [[ -n "$REGIONS_CONF" && ! -f "$REGIONS_CONF" ]]; then
        die "conf file not found: $REGIONS_CONF"
    fi
    assert_enum "--format" "$OPT_FORMAT" text tsv csv
    assert_uint "--top" "$OPT_TOP"
    assert_uint "--slow-api-ms" "$OPT_SLOW_API_MS"
    assert_uint "--slow-app-ms" "$OPT_SLOW_APP_MS"
    if [[ "$OPT_MERGE" -eq 1 && "$OPT_REGION" != "all" ]]; then
        die "--merge requires --region all (got: '$OPT_REGION')"
    fi
}

# ---------------------------------------------------------------------------
# Module runner
# ---------------------------------------------------------------------------

# _MOD_ARGS — populated by build_module_args, consumed by run_module.
# Using an array (not a string) avoids word-splitting bugs when --log-dir
# or --conf paths contain whitespace.
_MOD_ARGS=()

# build_module_args MODULE
#   Purpose : Materialise _MOD_ARGS for a specific module based on the
#             orchestrator's options and the capability matrix (§4.2).
#   Args    : $1 MODULE — analyser script name (analyze_access, analyze_iis,
#             analyze_errors); governs which optional flags are forwarded.
#   Output  : nothing on stdout; mutates global _MOD_ARGS.
#   Returns / Side effects : mutates _MOD_ARGS.
#   Notes   : Uses if/then/fi (not [[ ]] && cmd) to avoid the set-e footgun
#             where the last statement of a function returning 1 aborts the
#             caller. See bash.md for the full explanation.
build_module_args() {
    local module="$1"
    _MOD_ARGS=("--log-dir" "$OPT_LOG_DIR" "--region" "$OPT_REGION")
    if [[ -n "$OPT_DATE" ]]; then _MOD_ARGS+=("--date" "$OPT_DATE"); fi
    if [[ -n "$OPT_FROM" ]]; then _MOD_ARGS+=("--from" "$OPT_FROM"); fi
    if [[ -n "$OPT_TO"   ]]; then _MOD_ARGS+=("--to"   "$OPT_TO");   fi
    if [[ -z "$OPT_DATE" && -z "$OPT_FROM" ]]; then _MOD_ARGS+=("--days" "$OPT_DAYS"); fi
    if [[ -n "${REGIONS_CONF:-}" ]]; then _MOD_ARGS+=("--conf" "$REGIONS_CONF"); fi
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then _MOD_ARGS+=("--verbose"); fi
    _MOD_ARGS+=("--format" "$OPT_FORMAT")          # unified -> every child (iis/errors no-op on non-text)
    case "$module" in
        analyze_access)
            if (( OPT_MERGE )); then _MOD_ARGS+=("--merge"); fi
            ;;
        analyze_iis)
            _MOD_ARGS+=("--top" "$OPT_TOP" "--slow-api-ms" "$OPT_SLOW_API_MS" \
                        "--slow-app-ms" "$OPT_SLOW_APP_MS")
            if (( OPT_MERGE )); then _MOD_ARGS+=("--merge"); fi
            ;;
        analyze_errors)
            _MOD_ARGS+=("--top" "$OPT_TOP")
            ;;
    esac
}

# run_module MODULE_NAME [OUTPUT_FILE]
#   Purpose : Invoke a named analyser as a subprocess with module-specific args.
#   Args    : MODULE_NAME — analyser script name without the .sh suffix
#                            (resolves to bin/<MODULE_NAME>.sh).
#             OUTPUT_FILE — optional; when present, forwarded via --output.
#   Output  : analyser stdout forwarded to caller's stdout (or redirected).
#   Returns / Side effects : exits via die if the analyser is missing.
#   Notes   : build_module_args populates _MOD_ARGS per capability matrix.
run_module() {
    local module="$1" output_file="${2:-}"
    local bin="${SCRIPT_DIR}/${module}.sh"
    [[ -x "$bin" ]] || die "Module not found or not executable: $bin"

    build_module_args "$module"

    if [[ -n "$output_file" ]]; then
        log_info "Running module: $module -> $output_file"
        "$bin" "${_MOD_ARGS[@]}" --output "$output_file"
    else
        log_info "Running module: $module"
        "$bin" "${_MOD_ARGS[@]}"
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
