#!/usr/bin/env bash
# bin/log_report.sh
# ----------------------------------------------------------------------------
# Master orchestrator for the analysis toolkit.
#
# Resolves a shared interval (resolve_interval, D3 mutex) and forwarding
# args, then executes requested modules in canonical order
# (overview → iis → access → errors).  Modules run as child processes;
# failure in one cannot poison shared state in another.
#
# Always-on persistence (D6): persist_init resolves <base>/<RUN_TS>/ once and
# exports LOG_PARSE_RUN_TS + LOG_PARSE_OUTPUT_DIR (the BASE dir, not the subdir)
# so every child re-derives the same RUN_OUTPUT_DIR = <base>/<RUN_TS> without
# double-nesting. Files land under <base>/<timestamp>/. --output-dir is NOT
# forwarded as a flag (env carries the resolved base dir, C1).
#
# Unified flags forwarded to children per capability matrix (§4.2):
#   Common (all modules)  : --log-dir, --region, ${INTERVAL_ARGS[@]}, --conf, --verbose
#   overview only         : --slow-api-ms, --slow-app-ms
#   iis only              : --format, --view, --top, --slow-api-ms, --slow-app-ms, --merge
#   access only           : --format, --view, --merge
#   errors only           : --top
#
# REMOVED (feat!): --output FILE — superseded by always-on dir persistence.
#
# See docs/design.md §3.4 for the full specification.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"
source "${SCRIPT_DIR}/../lib/output_utils.sh"

# ---------------------------------------------------------------------------
# Defaults  (OPT_OUTPUT_DIR="" is mandatory — never ./log-parse here, C1)
# ---------------------------------------------------------------------------
OPT_LOG_DIR=""
OPT_DAYS=7
OPT_TODAY=0
OPT_DAYS_SET=0
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT_DIR=""
OPT_MODULES="overview,iis,access"   # errors opt-in; canonical order in main()
OPT_VIEW="summary"                   # forwarded to iis + access only
OPT_FORMAT="text"
OPT_TOP=10
OPT_SLOW_API_MS=2000
OPT_SLOW_APP_MS=5000
OPT_MERGE=0
OPT_TEST_HOSTS="exclude"
REGIONS_CONF=""
INTERVAL_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Master log analysis orchestrator. Runs all analysis modules in canonical order
(overview → iis → access → errors) and persists each module's summary+detail
pair to the resolved output directory (always-on, D6).

Interval flags are mutually exclusive (D3): choose exactly ONE of
  --today | --date | --from/--to | --days (default: last 7 days)

Options:
  --log-dir PATH        [required] root log directory
  --today               single-day run for today (= --date \$(date +%F))
  --days N              integer >= 1              (default: $OPT_DAYS; sets explicit selector)
  --from YYYY-MM-DD     start date, inclusive     [use together with --to]
  --to   YYYY-MM-DD     end date, inclusive       [use together with --from]
  --date YYYY-MM-DD     single day
  --region REGION       taipei | taichung | all   (default: all)
  --modules LIST        comma-separated modules (default: $OPT_MODULES)
                        Valid: overview, iis, access, errors  (errors = opt-in)
                        Executed in canonical order regardless of input order.
  --view S|D            summary | detail           (default: $OPT_VIEW)
                        Forwarded to iis + access only; summary is format-independent.
  --output-dir DIR      base output directory (default: ./log-parse)
                        Files land under <base>/<YYYYMMDD_HHMMSS>/ (subdir = run TS).
                        Precedence: flag > \$LOG_PARSE_OUTPUT_DIR > ./log-parse (C1).
                        log_report exports the BASE (not the subdir) so children
                        re-derive the same subdir without double-nesting.
  --conf FILE           regions config file (validated when explicitly supplied)
  --format FMT          text | tsv | csv          (default: text)
                        Forwarded to iis + access; governs detail file only (C10).
  --top N               integer >= 0, 0 = ALL     (default: $OPT_TOP)
                        Forwarded to iis (Endpoint + Client IP) and errors (pattern count).
  --slow-api-ms N       integer ms                (default: $OPT_SLOW_API_MS)
                        Forwarded to overview + iis; applies to API-role servers.
  --slow-app-ms N       integer ms                (default: $OPT_SLOW_APP_MS)
                        Forwarded to overview + iis; applies to APP-role servers.
  --merge               flag: merge all regions into one correlation/analysis pass.
                        REQUIRES --region all (default). Forwarded to access and iis.
  -v, --verbose         enable debug logging
  -h, --help            show this help

Capability matrix (forwarding targets):
  Flag             overview  access  iis  errors
  --view               no     yes   yes    no    (summary = always text, C10)
  --format             no     yes   yes    no    (governs detail file)
  --merge              no     yes   yes    no    (requires --region all)
  --top                no      no   yes   yes
  --slow-api-ms       yes      no   yes    no
  --slow-app-ms       yes      no   yes    no

Common scenarios (runnable against the bundled dataset):

  # 1. Default report (overview + iis + access, last 7 days)
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # 2. Single-date summary, taipei only
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --region taipei

  # 3. Weekly audit with errors, custom output dir
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --modules overview,iis,access,errors \\
       --output-dir ./reports

  # 4. Detail view, CSV export
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --view detail --format csv
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)      OPT_LOG_DIR="$2";       shift 2 ;;
            --today)        OPT_TODAY=1;             shift ;;
            --days)         OPT_DAYS="$2"; OPT_DAYS_SET=1; shift 2 ;;
            --from)         OPT_FROM="$2";           shift 2 ;;
            --to)           OPT_TO="$2";             shift 2 ;;
            --date)         OPT_DATE="$2";           shift 2 ;;
            --region)       OPT_REGION="$2";         shift 2 ;;
            --modules)      OPT_MODULES="$2";        shift 2 ;;
            --view)         OPT_VIEW="$2";           shift 2 ;;
            --output-dir)   OPT_OUTPUT_DIR="$2";     shift 2 ;;
            --conf)         REGIONS_CONF="$2";       shift 2 ;;
            --format)       OPT_FORMAT="$2";         shift 2 ;;
            --top)          OPT_TOP="$2";            shift 2 ;;
            --slow-api-ms)  OPT_SLOW_API_MS="$2";   shift 2 ;;
            --slow-app-ms)  OPT_SLOW_APP_MS="$2";   shift 2 ;;
            --merge)        OPT_MERGE=1;             shift ;;
            --test-hosts)   OPT_TEST_HOSTS="$2";     shift 2 ;;
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
    assert_enum "--view"       "$OPT_VIEW"       summary detail
    assert_enum "--format"     "$OPT_FORMAT"     text tsv csv
    assert_enum "--test-hosts" "$OPT_TEST_HOSTS" exclude only all
    assert_uint "--top"          "$OPT_TOP"
    assert_uint "--slow-api-ms"  "$OPT_SLOW_API_MS"
    assert_uint "--slow-app-ms"  "$OPT_SLOW_APP_MS"
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
#             --output-dir is NOT included (env carries the resolved dir, C1).
#   Args    : $1 MODULE — analyser script name (analyze_overview, analyze_access,
#             analyze_iis, analyze_errors); governs which optional flags are forwarded.
#   Output  : nothing on stdout; mutates global _MOD_ARGS.
#   Returns / Side effects : mutates _MOD_ARGS.
#   Errors / Notes : Uses if/then/fi (not [[ ]] && cmd) to avoid the set-e footgun
#             where the last statement of a function returning 1 aborts the caller.
#             INTERVAL_ARGS must be populated by resolve_interval before this call.
build_module_args() {
    local module="$1"
    _MOD_ARGS=("--log-dir" "$OPT_LOG_DIR" "--region" "$OPT_REGION")
    _MOD_ARGS+=("${INTERVAL_ARGS[@]}")
    if [[ -n "${REGIONS_CONF:-}" ]]; then _MOD_ARGS+=("--conf" "$REGIONS_CONF"); fi
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then _MOD_ARGS+=("--verbose"); fi
    if [[ "$module" != "analyze_errors" ]]; then
        _MOD_ARGS+=(--test-hosts "$OPT_TEST_HOSTS")
    fi
    case "$module" in
        analyze_overview)
            _MOD_ARGS+=(--slow-api-ms "$OPT_SLOW_API_MS" \
                        --slow-app-ms "$OPT_SLOW_APP_MS")
            ;;
        analyze_iis)
            _MOD_ARGS+=(--format "$OPT_FORMAT" --view "$OPT_VIEW" \
                        --top "$OPT_TOP" \
                        --slow-api-ms "$OPT_SLOW_API_MS" \
                        --slow-app-ms "$OPT_SLOW_APP_MS")
            if (( OPT_MERGE )); then _MOD_ARGS+=(--merge); fi
            ;;
        analyze_access)
            _MOD_ARGS+=(--format "$OPT_FORMAT" --view "$OPT_VIEW")
            if (( OPT_MERGE )); then _MOD_ARGS+=(--merge); fi
            ;;
        analyze_errors)
            _MOD_ARGS+=(--top "$OPT_TOP")
            ;;
    esac
}

# run_module MODULE_NAME
#   Purpose : Invoke a named analyser as a subprocess with module-specific args.
#             Children inherit LOG_PARSE_RUN_TS + LOG_PARSE_OUTPUT_DIR via env
#             (set by main before this call); persist_init in each child resolves
#             OPT_OUTPUT_DIR="" → $LOG_PARSE_OUTPUT_DIR (C1, D6).
#   Args    : MODULE_NAME — analyser script name without the .sh suffix
#                            (resolves to bin/<MODULE_NAME>.sh).
#   Output  : analyser stdout forwarded to caller's stdout.
#   Returns / Side effects : exits via die if the analyser is missing or non-exec.
#   Errors / Notes : build_module_args populates _MOD_ARGS per capability matrix.
#             --output-dir is never forwarded as a flag; env carries the resolved dir.
run_module() {
    local module="$1"
    local bin="${SCRIPT_DIR}/${module}.sh"
    [[ -x "$bin" ]] || die "Module not found or not executable: $bin"
    build_module_args "$module"
    log_info "Running module: $module"
    "$bin" "${_MOD_ARGS[@]}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Resolve interval once; populate INTERVAL_ARGS for all child spawns (D3)
    resolve_interval \
        --today    "$OPT_TODAY"    \
        --date     "$OPT_DATE"     \
        --from     "$OPT_FROM"     \
        --to       "$OPT_TO"       \
        --days-set "$OPT_DAYS_SET" \
        --days     "$OPT_DAYS"

    # Parse and validate module list
    IFS=',' read -ra MODULES <<< "$OPT_MODULES"

    local valid_modules=("overview" "iis" "access" "errors")
    local m v found
    for m in "${MODULES[@]}"; do
        found=0
        for v in "${valid_modules[@]}"; do
            if [[ "$m" == "$v" ]]; then found=1; fi
        done
        if [[ "$found" -eq 0 ]]; then
            die "Unknown module: '$m' (valid: ${valid_modules[*]})"
        fi
    done

    # Execute in canonical fixed order (overview → iis → access → errors),
    # regardless of input order.
    local -a ORDERED_MODULES=()
    for v in "${valid_modules[@]}"; do
        for m in "${MODULES[@]}"; do
            if [[ "$m" == "$v" ]]; then ORDERED_MODULES+=("$m"); fi
        done
    done

    log_info "Modules: ${ORDERED_MODULES[*]}"
    log_info "Log dir: $OPT_LOG_DIR"

    # Resolve output dir + timestamp once; export for child processes (D6, C1)
    persist_init "$OPT_OUTPUT_DIR"
    export LOG_PARSE_RUN_TS="$RUN_TS"
    export LOG_PARSE_OUTPUT_DIR="$RUN_BASE_DIR"
    log_info "Output dir: $RUN_OUTPUT_DIR  ts: $RUN_TS"

    for m in "${ORDERED_MODULES[@]}"; do
        run_module "analyze_${m}"
    done
}

main "$@"
