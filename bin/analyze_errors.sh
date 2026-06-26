#!/usr/bin/env bash
# bin/analyze_errors.sh
# ----------------------------------------------------------------------------
# Application error log and lifecycle analyser.
#
# Inputs (pipe-delimited structured-logger format):
#   <log_dir>/<server>/app/<date>/app-all-<date>.log       (preferred — all levels)
#   <log_dir>/<server>/app/<date>/app-error-<date>.log     (fallback — errors only)
#   <log_dir>/<server>/app/<date>/app-lifetime-<date>.log  (Microsoft.Hosting.Lifetime)
#
# Reports:
#   - Total ERROR-level entries.
#   - OracleDB health failures (Unhealthy + TaskCanceledException patterns).
#   - Top-N error patterns with numeric tokens normalised so semantically
#     identical messages collapse to one group.
#   - Application restart events (SHUTDOWN ↔ STARTED pairs) with downtime.
#   - Unmatched SHUTDOWN events (potential hard crashes / pending recoveries).
#
# See docs/design.md §3.3 for the full specification.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"
source "${SCRIPT_DIR}/../lib/csv_utils.sh"
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"

REGIONS_CONF="${SCRIPT_DIR}/../conf/regions.conf"

OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT=""
OPT_FORMAT="text"
OPT_TOP=10

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze application error logs and lifecycle events.
Reports OracleDB health failures, top error patterns, and restart events.

Options:
  --log-dir PATH      [required] Root log directory
  --days N            integer >= 1              (default: $OPT_DAYS)   [ignored if --date/--from set]
  --from YYYY-MM-DD   YYYY-MM-DD inclusive range start (use with --to)
  --to   YYYY-MM-DD   YYYY-MM-DD inclusive range end   (use with --from)
  --date YYYY-MM-DD   Single date analysis (overrides --days/--from/--to)
  --region REGION     taipei | taichung | all  (default: all)
  --top N             integer >= 0, 0 = ALL    (default: $OPT_TOP)   [caps error pattern count]
  --format FMT        text | tsv | csv         (default: text)  [non-text is a no-op for errors]
  --output FILE       Write report to file     (default: stdout)
  --conf FILE         Regions config file      (default: conf/regions.conf)
  -v, --verbose       Enable debug logging
  -h, --help          Show this help

Common scenarios:
  # Default: all regions, last 7 days
  bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # Single date, single region
  bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --region taichung

  # Show top 20 error patterns
  bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --top 20

  # Show ALL error patterns (no cap)
  bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --top 0

  # Weekly range
  bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)   OPT_LOG_DIR="$2";  shift 2 ;;
            --days)      OPT_DAYS="$2";      shift 2 ;;
            --from)      OPT_FROM="$2";      shift 2 ;;
            --to)        OPT_TO="$2";        shift 2 ;;
            --date)      OPT_DATE="$2";      shift 2 ;;
            --region)    OPT_REGION="$2";    shift 2 ;;
            --top)       OPT_TOP="$2";       shift 2 ;;
            --format)    OPT_FORMAT="$2";    shift 2 ;;
            --output)    OPT_OUTPUT="$2";    shift 2 ;;
            --conf)      REGIONS_CONF="$2";  shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG;   shift ;;
            -h|--help)   usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$OPT_LOG_DIR" ]] && die "--log-dir is required"
    [[ -d "$OPT_LOG_DIR" ]] || die "Log directory not found: $OPT_LOG_DIR"
    [[ -f "$REGIONS_CONF" ]] || die "conf file not found: $REGIONS_CONF"
    assert_enum "--format" "$OPT_FORMAT" text tsv csv
    if [[ "$OPT_FORMAT" != "text" ]]; then
        log_warn "format '$OPT_FORMAT' not supported by errors; emitting text"
    fi
    assert_uint "--top" "$OPT_TOP"
}

declare -a REGION_IDS=()
declare -A REGION_NAMES=() REGION_APIS=() REGION_APPS=()

load_regions() {
    while IFS='|' read -r rid rname apis apps; do
        [[ "$rid" =~ ^# || -z "$rid" ]] && continue
        REGION_IDS+=("$rid")
        REGION_NAMES["$rid"]="$rname"
        REGION_APIS["$rid"]="$apis"
        REGION_APPS["$rid"]="$apps"
    done < "$REGIONS_CONF"
}

# ---------------------------------------------------------------------------
# Error analysis awk (pipe-delimited app-all log)
# ---------------------------------------------------------------------------

ERROR_AWK='
# ----------------------------------------------------------------------------
# Error pattern extraction.
#
# Input  : pipe-delimited structured-logger rows. Only level=ERROR participates.
# Vars   : top_errors — number of patterns to surface (bound by --top flag).
#                       0 = emit ALL patterns (no cap).
# Output : TAB-delimited rows with these prefixes:
#            TOTAL_ERRORS\t<n>
#            DB_FAILURES\t<n>
#            DB_TIME\t<timestamp>           (up to 5 of the earliest)
#            TOP_ERROR\t<count>\t<sample>   (sorted desc)
#
# Pattern grouping strategy:
#   1) Truncate at "--- Exception" so stack frames do not dominate the key.
#   2) Cap raw message at 120 chars.
#   3) Replace timing values, dates, and other digits with placeholders so
#      semantically identical messages collapse into one bucket.
# ----------------------------------------------------------------------------
BEGIN { top_n = top_errors + 0 }

/\|level: ERROR\|/ {
    # Timestamp is the first pipe-separated field, e.g. "2026-05-21 14:03:44.332".
    n = split($0, parts, "|")
    ts = parts[1]
    gsub(/^ +| +$/, "", ts)

    # Locate "message: …" segment. Keep the substring after the colon+space.
    msg = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^message:/) {
            msg = substr(parts[i], index(parts[i], ":") + 2)
            idx = index(msg, "--- Exception")     # drop stack trace
            if (idx > 0) msg = substr(msg, 1, idx - 2)
            msg = substr(msg, 1, 120)             # cap length
            break
        }
    }

    total_errors++

    # OracleDB outage signature — both health-check Unhealthy events and
    # query TaskCanceledException after the pool stalls.
    if (msg ~ /OracleDB/ && (msg ~ /Unhealthy/ || msg ~ /TaskCanceledException/)) {
        db_failures++
        db_times[db_failures] = ts
    }

    # Normalise volatile tokens so the pattern key is stable across rows.
    norm = msg
    gsub(/[0-9]+\.[0-9]+ms/,           "Nms",  norm)   # request timings
    gsub(/[0-9]{4}-[0-9]{2}-[0-9]{2}/, "DATE", norm)   # ISO dates
    gsub(/[0-9]+/,                     "N",    norm)   # any remaining number
    error_count[norm]++
    error_sample[norm] = msg
}

END {
    printf "TOTAL_ERRORS\t%d\n", total_errors+0
    printf "DB_FAILURES\t%d\n",  db_failures+0
    for (i = 1; i <= db_failures && i <= 5; i++)
        printf "DB_TIME\t%s\n", db_times[i]

    # Top-N patterns by count, descending.
    n = asorti(error_count, sorted, "@val_num_desc")
    limit = (top_n == 0) ? n : (n < top_n ? n : top_n)
    for (i = 1; i <= limit; i++) {
        key = sorted[i]
        printf "TOP_ERROR\t%d\t%s\n", error_count[key], error_sample[key]
    }
}
'

# ---------------------------------------------------------------------------
# Lifetime analysis awk
# ---------------------------------------------------------------------------

LIFETIME_AWK='
# ----------------------------------------------------------------------------
# Lifetime event extractor.
#
# Input  : pipe-delimited rows; we only care about rows tagged with the
#          Microsoft.Hosting.Lifetime category.
# Output : two event kinds, one per line, in source order:
#            SHUTDOWN\t<timestamp>
#            STARTED\t<timestamp>
#
# These are then paired by pair_restarts() in bash.
# ----------------------------------------------------------------------------
/Microsoft\.Hosting\.Lifetime/ {
    n = split($0, parts, "|")
    ts = parts[1]
    gsub(/^ +| +$/, "", ts)

    # Locate the message field and trim surrounding whitespace.
    msg = ""
    for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^message:/) {
            msg = substr(parts[i], index(parts[i], ":") + 2)
            gsub(/^ +| +$/, "", msg)
            break
        }
    }

    if      (msg ~ /shutting down/)     events[++ne] = "SHUTDOWN\t" ts
    else if (msg ~ /Application started/) events[++ne] = "STARTED\t"  ts
}

END {
    for (i = 1; i <= ne; i++) print events[i]
}
'

# ---------------------------------------------------------------------------
# Restart pairing (bash + awk)
# ---------------------------------------------------------------------------

# pair_restarts LIFETIME_TSV
#   Purpose : Pair chronological SHUTDOWN events with the next STARTED event.
#   Input   : TSV file with columns "SHUTDOWN|STARTED \t timestamp".
#   Output  : RESTART rows + leftover UNMATCHED rows:
#               RESTART\t<shutdown_ts>\t<started_ts>\t<delta_sec>
#               UNMATCHED\t<shutdown_ts>\t-\t-
#   Pairing : A second SHUTDOWN before a STARTED emits the prior unpaired
#             event as UNMATCHED — usually indicates a hard crash.
pair_restarts() {
    local lifetime_tsv="$1"
    gawk -F'\t' '
        function ts_to_epoch(ts,    p, dp, tp, sp) {
            split(ts, p, " ")
            split(p[1], dp, "-")
            split(p[2], tp, ":")
            split(tp[3], sp, ".")
            return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " int(sp[1]))
        }
        $1 == "SHUTDOWN" {
            if (shutdown_ts != "")
                print "UNMATCHED\t" shutdown_ts "\t-\t-"
            shutdown_ts = $2
        }
        $1 == "STARTED" && shutdown_ts != "" {
            started_ts = $2
            e_down = ts_to_epoch(shutdown_ts)
            e_up   = ts_to_epoch(started_ts)
            delta  = (e_down > 0 && e_up > 0) ? e_up - e_down : "?"
            print "RESTART\t" shutdown_ts "\t" started_ts "\t" delta
            shutdown_ts = ""
        }
        END {
            if (shutdown_ts != "")
                print "UNMATCHED\t" shutdown_ts "\t-\t-"
        }
    ' "$lifetime_tsv"
}

# ---------------------------------------------------------------------------
# Per-server analysis
# ---------------------------------------------------------------------------

analyze_server_errors() {
    local server="$1" date_list_file="$2"
    local app_dir="${OPT_LOG_DIR}/${server}/app"
    [[ -d "$app_dir" ]] || { log_debug "  No app dir: $app_dir"; return; }

    local all_log="${WORK_TMPDIR}/appall_${server}.log"
    local lifetime_raw="${WORK_TMPDIR}/lifetime_raw_${server}.log"
    : > "$all_log"
    : > "$lifetime_raw"

    while IFS= read -r d; do
        local day_dir="${app_dir}/${d}"
        [[ -d "$day_dir" ]] || continue
        local appall="${day_dir}/app-all-${d}.log"
        local apperr="${day_dir}/app-error-${d}.log"
        local lifetime="${day_dir}/app-lifetime-${d}.log"

        # Prefer app-all for errors (more compact), fallback to app-error
        if [[ -f "$appall" ]]; then
            cat "$appall" >> "$all_log"
        elif [[ -f "$apperr" ]]; then
            cat "$apperr" >> "$all_log"
        fi

        [[ -f "$lifetime" ]] && cat "$lifetime" >> "$lifetime_raw"
    done < "$date_list_file"

    fmt_h2 "App Errors — Server: $server"

    # Error analysis
    if [[ -s "$all_log" ]]; then
        local stats
        stats=$(gawk -v top_errors="$OPT_TOP" "$ERROR_AWK" "$all_log")

        local total_err db_fail
        total_err=$(echo "$stats" | gawk -F'\t' '$1=="TOTAL_ERRORS" {print $2}')
        db_fail=$(  echo "$stats" | gawk -F'\t' '$1=="DB_FAILURES"  {print $2}')

        fmt_kv "Total ERROR entries"          "${total_err:-0}"
        fmt_kv_color "OracleDB health failures" "${db_fail:-0}" "$C_RED"

        if (( ${db_fail:-0} > 0 )); then
            echo "    首次 OracleDB 失敗時間:"
            echo "$stats" | gawk -F'\t' '$1=="DB_TIME" {printf "      %s\n", $2}' | head -5
        fi

        echo ""
        echo "    Top Error Patterns:"
        printf "    %-6s %s\n" "Count" "Message"
        printf "    %s\n" "--------------------------------------------------------------------"
        echo "$stats" | gawk -F'\t' '$1=="TOP_ERROR" {printf "    %-6d %s\n", $2, substr($3,1,80)}'
    else
        fmt_kv "App log status" "無資料"
    fi

    # Lifetime / restart analysis
    if [[ -s "$lifetime_raw" ]]; then
        echo ""
        fmt_h3 "應用程式重啟事件"
        local lifetime_tsv="${WORK_TMPDIR}/lifetime_${server}.tsv"
        gawk "$LIFETIME_AWK" "$lifetime_raw" > "$lifetime_tsv"

        local restart_tsv="${WORK_TMPDIR}/restart_${server}.tsv"
        pair_restarts "$lifetime_tsv" > "$restart_tsv"

        local restart_count unmatched_count
        restart_count=$(  gawk -F'\t' '$1=="RESTART"   {c++} END{print c+0}' "$restart_tsv")
        unmatched_count=$(gawk -F'\t' '$1=="UNMATCHED" {c++} END{print c+0}' "$restart_tsv")
        fmt_kv "Restart count" "$restart_count"
        (( unmatched_count > 0 )) && fmt_kv_color "  未配對 SHUTDOWN (無對應啟動)" "$unmatched_count" "$C_YELLOW"

        if [[ -s "$restart_tsv" ]]; then
            echo ""
            printf "    %-28s  %-28s  %s\n" "Shutdown Time" "Started Time" "Downtime"
            printf "    %s\n" "------------------------------------------------------------------------"
            LC_ALL=C gawk -F'\t' "$FMT_AWK_WIDTH"'
                $1 == "RESTART" {
                    delta = $4
                    if (delta ~ /^[0-9]+$/) {
                        d = delta + 0
                        if (d >= 60) dur = sprintf("%dm %ds", int(d/60), d%60)
                        else         dur = sprintf("%ds", d)
                    } else {
                        dur = "?"
                    }
                    printf "    %s  %s  %s\n", rpad($2, 28), rpad($3, 28), dur
                }
                $1 == "UNMATCHED" {
                    printf "    %s  %s  %s\n", rpad($2, 28), rpad("(無對應啟動記錄)", 28), "?"
                }
            ' "$restart_tsv"
        fi
    fi
}

analyze_region_errors() {
    local region_id="$1" date_list_file="$2"
    fmt_h1 "Error Analysis — Region: ${REGION_NAMES[$region_id]}"

    local all_servers="${REGION_APIS[$region_id]},${REGION_APPS[$region_id]}"
    IFS=',' read -ra servers <<< "$all_servers"
    for srv in "${servers[@]}"; do
        analyze_server_errors "$srv" "$date_list_file"
    done
}

main() {
    parse_args "$@"
    init_tmpdir
    load_regions

    local date_list_file="${WORK_TMPDIR}/dates.txt"
    build_date_list \
        ${OPT_DATE:+--date "$OPT_DATE"} \
        ${OPT_FROM:+--from "$OPT_FROM"} \
        ${OPT_TO:+--to "$OPT_TO"} \
        ${OPT_DAYS:+--days "$OPT_DAYS"} \
        > "$date_list_file"

    local date_start date_end n_dates
    date_start=$(head -1 "$date_list_file")
    date_end=$(tail -1 "$date_list_file")
    n_dates=$(count_lines "$date_list_file")

    log_info "Period: $date_start → $date_end ($n_dates days)"

    {
        fmt_h1 "Application Error & Lifecycle Report"
        fmt_kv "Period" "${date_start}  →  ${date_end}  (${n_dates} days)"

        for rid in "${REGION_IDS[@]}"; do
            [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]] && continue
            analyze_region_errors "$rid" "$date_list_file"
        done

        fmt_footer
    } | if [[ -n "$OPT_OUTPUT" ]]; then tee "$OPT_OUTPUT"; else cat; fi

    if [[ -n "$OPT_OUTPUT" ]]; then log_info "Report written to: $OPT_OUTPUT"; fi
}

main "$@"
