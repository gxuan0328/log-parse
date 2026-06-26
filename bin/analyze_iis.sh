#!/usr/bin/env bash
# bin/analyze_iis.sh
# ----------------------------------------------------------------------------
# IIS W3C log analyser — surfaces HTTP-level signals per server, per region.
#
# Inputs : <log_dir>/<server>/iis/u_exYYMMDD.log  (W3C extended, space-delim)
# Metrics:
#   - Total requests, unique client IPs, 302 redirect count.
#   - 5xx errors and the Health-503 subset (status==503 && uri==/health).
#   - Slow requests where time-taken >= role-resolved threshold AND uri != /health.
#     API servers use --slow-api-ms; APP servers use --slow-app-ms.
#   - Status code distribution.
#   - Top-N endpoints (--top, default 10, 0=all), with DICOM study/series UIDs
#     collapsed into templates so cardinality stays manageable.
#   - Top-N client IPs (--top, default 10, 0=all).
#
# See docs/design.md §3.2 for field semantics.
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
OPT_TOP=10
OPT_SLOW_API_MS=2000
OPT_SLOW_APP_MS=5000
OPT_FORMAT="text"
OPT_MERGE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze IIS W3C access logs: request counts, status codes, slow requests,
health-check 503 events, and per-endpoint breakdowns.

Options:
  --log-dir PATH     [required] root log directory
  --region REGION    taipei | taichung | all   (default: all)
  --days N           integer >= 1              (default: 7)   [ignored if --date/--from set]
  --from / --to DATE YYYY-MM-DD inclusive range (use together)
  --date DATE        YYYY-MM-DD single day     (overrides --days/--from/--to)
  --top N            integer >= 0, 0 = ALL     (default: 10)  [caps Endpoint AND Client IP]
  --slow-api-ms N    integer ms                (default: 2000)[API-role servers]
  --slow-app-ms N    integer ms                (default: 5000)[APP-role servers]
  --merge            flag    REQUIRES --region all; merges hosts, splits API vs APP buckets
  --format FMT       text | tsv | csv          (default: text)[iis: non-text is a no-op]
  --output FILE      path                      (default: stdout)
  --conf FILE        path                      (default: conf/regions.conf)
  -v, --verbose / -h, --help

Common scenarios:
  # 1. Daily IIS health, all regions, default per-role slow thresholds
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21

  # 2. Weekly audit, tighten API SLA to 1s, show ALL endpoints
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0

  # 3. Host-agnostic merged view (API vs APP), all regions
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)      OPT_LOG_DIR="$2";      shift 2 ;;
            --days)         OPT_DAYS="$2";          shift 2 ;;
            --from)         OPT_FROM="$2";          shift 2 ;;
            --to)           OPT_TO="$2";            shift 2 ;;
            --date)         OPT_DATE="$2";          shift 2 ;;
            --region)       OPT_REGION="$2";        shift 2 ;;
            --top)          OPT_TOP="$2";           shift 2 ;;
            --slow-api-ms)  OPT_SLOW_API_MS="$2";  shift 2 ;;
            --slow-app-ms)  OPT_SLOW_APP_MS="$2";  shift 2 ;;
            --merge)        OPT_MERGE=1;            shift ;;
            --format)       OPT_FORMAT="$2";        shift 2 ;;
            --output)       OPT_OUTPUT="$2";        shift 2 ;;
            --conf)         REGIONS_CONF="$2";      shift 2 ;;
            -v|--verbose)   LOG_LEVEL=DEBUG;        shift ;;
            -h|--help)      usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    if [[ -z "$OPT_LOG_DIR" ]]; then die "--log-dir is required"; fi
    if [[ ! -d "$OPT_LOG_DIR" ]]; then die "Log directory not found: $OPT_LOG_DIR"; fi
    if [[ ! -f "$REGIONS_CONF" ]]; then die "conf file not found: $REGIONS_CONF"; fi
    assert_enum "--format" "$OPT_FORMAT" text tsv csv
    if [[ "$OPT_FORMAT" != "text" ]]; then
        log_warn "format '$OPT_FORMAT' not supported by analyze_iis; emitting text"
    fi
    assert_uint "--top" "$OPT_TOP"
    assert_uint "--slow-api-ms" "$OPT_SLOW_API_MS"
    assert_uint "--slow-app-ms" "$OPT_SLOW_APP_MS"
    if [[ "$OPT_MERGE" -eq 1 && "$OPT_REGION" != "all" ]]; then
        die "--merge requires --region all (got: '$OPT_REGION')"
    fi
}

declare -a REGION_IDS=()
declare -A REGION_NAMES=() REGION_APIS=() REGION_APPS=()

load_regions() {
    while IFS='|' read -r rid rname apis apps; do
        if [[ "$rid" =~ ^# || -z "$rid" ]]; then continue; fi
        REGION_IDS+=("$rid")
        REGION_NAMES["$rid"]="$rname"
        REGION_APIS["$rid"]="$apis"
        REGION_APPS["$rid"]="$apps"
    done < "$REGIONS_CONF"
}

# ---------------------------------------------------------------------------
# IIS analysis awk program (embedded)
# ---------------------------------------------------------------------------

IIS_AWK='
# ----------------------------------------------------------------------------
# Purpose : Analyse IIS W3C log lines; emit TAB-delimited kind-tagged rows.
# Input   : Raw W3C extended log lines (space-delimited; # lines = comments).
# Vars    : slow_ms — role-resolved slow-request threshold in milliseconds.
#           top     — max rows for ENDPOINT and CLIENT_IP (0 = all).
# Output  : TAB-delimited, kind-prefixed rows on stdout:
#             TOTAL\t<n>
#             5XX\t<n>
#             503_HEALTH\t<n>
#             SLOW\t<n>
#             REDIRECT\t<n>
#             UNIQUE_IPS\t<n>
#             STATUS\t<status>\t<count>
#             ENDPOINT\t<uri>\t<count>\t<avg_sec>   (Top-N by count desc,
#                                                    --top default 10, 0=all)
#             CLIENT_IP\t<ip>\t<count>              (Top-N by count desc,
#                                                    --top default 10, 0=all)
# ----------------------------------------------------------------------------
BEGIN {
    health_path    = "/health"
    slow_threshold = slow_ms + 0
}

# Skip W3C directive lines and any truncated rows missing required fields.
/^#/ { next }
NF < 17 { next }

{
    # Default IIS W3C field positions (1-based):
    #   1=date  2=time  3=s-ip  4=cs-method  5=cs-uri-stem  6=cs-uri-query
    #   7=s-port 8=cs-username 9=c-ip 10=cs(User-Agent) 11=cs(Referer)
    #   12=sc-status 13=sc-substatus 14=sc-win32-status
    #   15=sc-bytes 16=cs-bytes 17=time-taken (ms)
    method = $4
    uri    = $5
    status = $12 + 0
    ttms   = $17 + 0
    client = $9

    total++
    status_count[status]++

    # Per-client request counter; "-" appears when IIS could not resolve
    # the client and is excluded from the unique-IP set.
    if (client != "-") client_ips[client]++

    # DICOM endpoints embed study/series UIDs in the path; collapse them so
    # the top-endpoint table reflects logical endpoints, not UID variants.
    ep = uri
    if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/series\//) {
        ep = "/api/NhiPatientImage/studies/{uid}/series/{uid}/..."
    } else if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/series-uid/) {
        ep = "/api/NhiPatientImage/studies/{uid}/series-uid"
    } else if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/instances\//) {
        ep = "/api/NhiPatientImage/studies/{uid}/instances/{uid}"
    }
    ep_count[ep]++
    ep_time_ms[ep] += ttms   # accumulate time-taken for the per-endpoint mean

    # Severity / health counters. Note: health-check 503s are deliberately
    # split out from the generic 5xx bucket because they signal a dependency
    # outage (OracleDB unhealthy), not an application fault.
    if (status >= 500)                                error5xx++
    if (ttms >= slow_threshold && uri != health_path) slow++
    if (status == 503 && uri == health_path)          health503++
    if (status == 302)                                redirect++
}

END {
    printf "TOTAL\t%d\n",      total
    printf "5XX\t%d\n",        error5xx+0
    printf "503_HEALTH\t%d\n", health503+0
    printf "SLOW\t%d\n",       slow+0
    printf "REDIRECT\t%d\n",   redirect+0
    printf "UNIQUE_IPS\t%d\n", length(client_ips)

    # Emit raw STATUS counts; render_iis_stats re-sorts in-gawk for display.
    for (s in status_count)
        printf "STATUS\t%d\t%d\n", s, status_count[s]

    # Top-N endpoints by request count (descending). 4th field = mean response
    # time in seconds (time-taken logged in ms). top=0 emits all endpoints.
    n = asorti(ep_count, ep_sorted, "@val_num_desc")
    lim = (top == 0) ? n : (n < top ? n : top)
    for (i = 1; i <= lim; i++) {
        e = ep_sorted[i]
        avg_sec = (ep_count[e] > 0) ? (ep_time_ms[e] / ep_count[e] / 1000.0) : 0
        printf "ENDPOINT\t%s\t%d\t%.2f\n", e, ep_count[e], avg_sec
    }

    # Top-N unique client IPs with request counts, sorted descending.
    # top=0 emits all client IPs.
    m = asorti(client_ips, ip_sorted, "@val_num_desc")
    lim2 = (top == 0) ? m : (m < top ? m : top)
    for (i = 1; i <= lim2; i++)
        printf "CLIENT_IP\t%s\t%d\n", ip_sorted[i], client_ips[ip_sorted[i]]
}
'

# append_iis_server_files SERVER DATE_LIST_FILE OUTPUT_FILE
#   Purpose : Append existing IIS log files for SERVER into OUTPUT_FILE.
#   Args    : SERVER — hostname/IP; DATE_LIST_FILE — one YYYY-MM-DD per line;
#             OUTPUT_FILE — destination file (must already exist).
#   Output  : nothing on stdout.
#   Returns : none (missing server dir logged as warning).
#   Notes   : Uses date_to_iis_file from lib/date_utils.sh for filename mapping.
append_iis_server_files() {
    local server="$1" date_list_file="$2" output="$3"
    local iis_dir="${OPT_LOG_DIR}/${server}/iis"
    if [[ ! -d "$iis_dir" ]]; then
        log_warn "  No IIS dir: $iis_dir"
        return
    fi
    while IFS= read -r d; do
        local fname fpath
        fname=$(date_to_iis_file "$d")
        fpath="${iis_dir}/${fname}"
        if [[ -f "$fpath" ]]; then cat "$fpath" >> "$output"; fi
    done < "$date_list_file"
}

# render_iis_stats LABEL COMBINED THRESHOLD
#   Purpose : Run IIS_AWK once on COMBINED and emit the KV summary block plus
#             three reordered %-tables (Status, Endpoint, Client IP).
#   Args    : LABEL     — server/corpus name (for debug context);
#             COMBINED  — path to concatenated IIS log file;
#             THRESHOLD — slow-request threshold in ms (role-resolved).
#   Output  : KV rows + three tables on stdout.
#   Returns : none.
#   Notes   : Caller must print fmt_h2 before calling this.
#             OPT_TOP governs Endpoint + Client IP row cap (0 = all).
render_iis_stats() {
    local label="$1" combined="$2" threshold="$3"
    log_debug "render_iis_stats: $label (threshold=${threshold}ms, top=${OPT_TOP})"

    local stats
    stats=$(gawk -v slow_ms="$threshold" -v top="$OPT_TOP" "$IIS_AWK" "$combined")

    local total error5xx h503 slow redir unique_ips
    total=$(     echo "$stats" | gawk -F'\t' '$1=="TOTAL"     {print $2}')
    error5xx=$(  echo "$stats" | gawk -F'\t' '$1=="5XX"       {print $2}')
    h503=$(      echo "$stats" | gawk -F'\t' '$1=="503_HEALTH"{print $2}')
    slow=$(      echo "$stats" | gawk -F'\t' '$1=="SLOW"      {print $2}')
    redir=$(     echo "$stats" | gawk -F'\t' '$1=="REDIRECT"  {print $2}')
    unique_ips=$(echo "$stats" | gawk -F'\t' '$1=="UNIQUE_IPS"{print $2}')

    fmt_kv "Total requests"               "${total:-0}"
    fmt_kv "Unique client IPs"            "${unique_ips:-0}"
    fmt_kv "302 Redirects"                "${redir:-0}"
    fmt_kv_color "5xx errors"             "${error5xx:-0}"  "$C_RED"
    fmt_kv_color "  Health 503"           "${h503:-0}"      "$C_YELLOW"
    fmt_kv_color "Slow (>${threshold}ms)" "${slow:-0}"      "$C_YELLOW"

    # HTTP Status table: [Status, Count, % of total], count-desc sort in-gawk.
    # Composite key (zero-padded count + status-code) gives deterministic order.
    echo ""
    printf "    %-10s  %-8s  %s\n" "Status" "Count" "% of total"
    printf "    %s\n" "--------------------------------"
    echo "$stats" | gawk -F'\t' -v total="${total:-0}" '
        $1 == "STATUS" {
            k = sprintf("%012d\t%s", $3, $2)
            code[k] = $2
            cnt[k]  = $3
        }
        END {
            m = asorti(code, idx, "@ind_str_desc")
            for (i = 1; i <= m; i++) {
                c   = code[idx[i]]
                n   = cnt[idx[i]]
                pct = (total > 0) ? (n / total * 100) : 0
                printf "    %-10s  %-8d  %5.1f%%\n", c, n, pct
            }
        }'

    # Endpoint table: [Endpoint, Avg(s), Count, % of total], count-desc.
    echo ""
    printf "    %-55s  %-8s  %-8s  %s\n" "Endpoint" "Avg(s)" "Count" "% of total"
    printf "    %s\n" "---------------------------------------------------------------------------------------"
    echo "$stats" | gawk -F'\t' -v total="${total:-0}" '
        $1 == "ENDPOINT" {
            pct = (total > 0) ? ($3 / total * 100) : 0
            printf "    %-55s  %-8.2f  %-8d  %5.1f%%\n", $2, $4, $3, pct
        }'

    # Client IP table: [Client IP, Count, % of total], count-desc.
    echo ""
    printf "    %-18s  %-8s  %s\n" "Client IP" "Count" "% of total"
    printf "    %s\n" "----------------------------------------"
    echo "$stats" | gawk -F'\t' -v total="${total:-0}" '
        $1 == "CLIENT_IP" {
            pct = (total > 0) ? ($3 / total * 100) : 0
            printf "    %-18s  %-8d  %5.1f%%\n", $2, $3, pct
        }'
}

analyze_server_iis() {
    local server="$1" date_list_file="$2" slow_ms="$3"
    local combined="${WORK_TMPDIR}/iis_${server}.log"
    : > "$combined"

    append_iis_server_files "$server" "$date_list_file" "$combined"

    if [[ ! -s "$combined" ]]; then
        log_warn "  No IIS logs found for $server"
        return
    fi

    fmt_h2 "IIS — $server"
    render_iis_stats "IIS — $server" "$combined" "$slow_ms"
}

analyze_region_iis() {
    local region_id="$1" date_list_file="$2"
    local apis="${REGION_APIS[$region_id]}"
    local apps="${REGION_APPS[$region_id]}"
    local -a api_servers app_servers

    fmt_h1 "IIS Analysis — Region: ${REGION_NAMES[$region_id]}"

    IFS=',' read -ra api_servers <<< "$apis"
    for srv in "${api_servers[@]}"; do
        analyze_server_iis "$srv" "$date_list_file" "$OPT_SLOW_API_MS"
    done

    IFS=',' read -ra app_servers <<< "$apps"
    for srv in "${app_servers[@]}"; do
        analyze_server_iis "$srv" "$date_list_file" "$OPT_SLOW_APP_MS"
    done
}

analyze_merged_iis() {
    local date_list_file="$1"
    local combined_api combined_app rid apis apps
    local -a api_servers app_servers

    combined_api="${WORK_TMPDIR}/iis_merged_api.log"
    combined_app="${WORK_TMPDIR}/iis_merged_app.log"
    : > "$combined_api"
    : > "$combined_app"

    for rid in "${REGION_IDS[@]}"; do
        apis="${REGION_APIS[$rid]}"
        apps="${REGION_APPS[$rid]}"

        IFS=',' read -ra api_servers <<< "$apis"
        for srv in "${api_servers[@]}"; do
            append_iis_server_files "$srv" "$date_list_file" "$combined_api"
        done

        IFS=',' read -ra app_servers <<< "$apps"
        for srv in "${app_servers[@]}"; do
            append_iis_server_files "$srv" "$date_list_file" "$combined_app"
        done
    done

    fmt_h2 "IIS — API_SERVERS (merged, all regions)"
    if [[ -s "$combined_api" ]]; then
        render_iis_stats "IIS — API_SERVERS (merged, all regions)" "$combined_api" "$OPT_SLOW_API_MS"
    else
        log_warn "  No API IIS logs found for merged analysis"
    fi

    fmt_h2 "IIS — APP_SERVERS (merged, all regions)"
    if [[ -s "$combined_app" ]]; then
        render_iis_stats "IIS — APP_SERVERS (merged, all regions)" "$combined_app" "$OPT_SLOW_APP_MS"
    else
        log_warn "  No APP IIS logs found for merged analysis"
    fi
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
        fmt_h1 "IIS Log Analysis Report"
        fmt_kv "Period" "${date_start}  →  ${date_end}  (${n_dates} days)"

        if [[ "$OPT_MERGE" -eq 1 ]]; then
            analyze_merged_iis "$date_list_file"
        else
            for rid in "${REGION_IDS[@]}"; do
                if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]]; then continue; fi
                analyze_region_iis "$rid" "$date_list_file"
            done
        fi

        fmt_footer
    } | if [[ -n "$OPT_OUTPUT" ]]; then tee "$OPT_OUTPUT"; else cat; fi

    if [[ -n "$OPT_OUTPUT" ]]; then log_info "Report written to: $OPT_OUTPUT"; fi
}

main "$@"
