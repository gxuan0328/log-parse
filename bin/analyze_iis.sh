#!/usr/bin/env bash
# bin/analyze_iis.sh
# ----------------------------------------------------------------------------
# IIS W3C log analyser — surfaces HTTP-level signals per server, per region.
#
# Inputs : <log_dir>/<server>/iis/u_exYYMMDD.log  (W3C extended, space-delim)
# Metrics:
#   - Total requests, unique client IPs, 302 redirect count.
#   - 5xx errors and the Health-503 subset (status==503 && uri==/health).
#   - Slow requests where time-taken >= --slow-ms AND uri != /health.
#   - Status code distribution.
#   - Top-15 endpoints, with DICOM study/series UIDs collapsed into templates
#     so cardinality stays manageable.
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
OPT_SLOW_MS=5000   # threshold for slow requests

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze IIS W3C access logs: request counts, status codes, slow requests,
health-check 503 events, and per-endpoint breakdowns.

Options:
  --log-dir PATH      Root log directory [required]
  --days N            Analyze last N days from today (default: $OPT_DAYS)
  --from YYYY-MM-DD   Start date (inclusive)
  --to   YYYY-MM-DD   End date   (inclusive)
  --date YYYY-MM-DD   Single date analysis
  --region REGION     Filter: taipei | taichung | all (default: all)
  --slow-ms N         Slow request threshold in ms (default: $OPT_SLOW_MS)
  --output FILE       Write report to file (default: stdout)
  --conf FILE         Regions config file
  -v, --verbose       Enable debug logging
  -h, --help          Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)  OPT_LOG_DIR="$2";  shift 2 ;;
            --days)     OPT_DAYS="$2";     shift 2 ;;
            --from)     OPT_FROM="$2";     shift 2 ;;
            --to)       OPT_TO="$2";       shift 2 ;;
            --date)     OPT_DATE="$2";     shift 2 ;;
            --region)   OPT_REGION="$2";   shift 2 ;;
            --slow-ms)  OPT_SLOW_MS="$2";  shift 2 ;;
            --output)   OPT_OUTPUT="$2";   shift 2 ;;
            --conf)     REGIONS_CONF="$2"; shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG; shift ;;
            -h|--help)  usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -z "$OPT_LOG_DIR" ]] && die "--log-dir is required"
    [[ -d "$OPT_LOG_DIR" ]] || die "Log directory not found: $OPT_LOG_DIR"
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
# IIS analysis awk program (embedded)
# ---------------------------------------------------------------------------

IIS_AWK='
# ----------------------------------------------------------------------------
# IIS analysis awk program.
#
# Input  : raw W3C extended log lines (space-delimited, # = comments).
# Variables passed in via -v:
#   slow_ms — slow-request threshold in milliseconds.
#
# Output : multiple record types on stdout, TAB-delimited, each prefixed by
#          its kind so the bash caller can grep/awk it back apart:
#            TOTAL\t<n>
#            5XX\t<n>
#            503_HEALTH\t<n>
#            SLOW\t<n>
#            REDIRECT\t<n>
#            UNIQUE_IPS\t<n>
#            STATUS\t<status>\t<count>     (one row per observed status)
#            ENDPOINT\t<uri>\t<count>      (top 15, count desc)
#            CLIENT_IP\t<ip>\t<count>      (one row per unique client IP,
#                                            count desc; "-" excluded)
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

    # Severity / health counters. Note: health-check 503s are deliberately
    # split out from the generic 5xx bucket because they signal a dependency
    # outage (OracleDB unhealthy), not an application fault.
    if (status >= 500)                           error5xx++
    if (ttms >= slow_threshold && uri != health_path) slow++
    if (status == 503 && uri == health_path)     health503++
    if (status == 302)                           redirect++
}

END {
    printf "TOTAL\t%d\n",      total
    printf "5XX\t%d\n",        error5xx+0
    printf "503_HEALTH\t%d\n", health503+0
    printf "SLOW\t%d\n",       slow+0
    printf "REDIRECT\t%d\n",   redirect+0
    printf "UNIQUE_IPS\t%d\n", length(client_ips)

    # Emit raw STATUS counts; the bash caller re-sorts for display.
    for (s in status_count)
        printf "STATUS\t%d\t%d\n", s, status_count[s]

    # Top-15 endpoints by request count (descending).
    n = asorti(ep_count, ep_sorted, "@val_num_desc")
    for (i = 1; i <= (n < 15 ? n : 15); i++)
        printf "ENDPOINT\t%s\t%d\n", ep_sorted[i], ep_count[ep_sorted[i]]

    # All unique client IPs with request counts, sorted descending.
    # No top-N cap: under normal medical operations the cardinality stays
    # in the low tens; a flood would itself be a useful signal.
    m = asorti(client_ips, ip_sorted, "@val_num_desc")
    for (i = 1; i <= m; i++)
        printf "CLIENT_IP\t%s\t%d\n", ip_sorted[i], client_ips[ip_sorted[i]]
}
'

analyze_server_iis() {
    local server="$1" date_list_file="$2"
    local iis_dir="${OPT_LOG_DIR}/${server}/iis"
    [[ -d "$iis_dir" ]] || { log_warn "  No IIS dir: $iis_dir"; return; }

    local combined="${WORK_TMPDIR}/iis_${server}.log"
    : > "$combined"

    while IFS= read -r d; do
        local fname
        fname=$(date_to_iis_file "$d")
        local fpath="${iis_dir}/${fname}"
        [[ -f "$fpath" ]] && cat "$fpath" >> "$combined"
    done < "$date_list_file"

    [[ -s "$combined" ]] || { log_warn "  No IIS logs found for $server"; return; }

    local stats
    stats=$(gawk -v slow_ms="$OPT_SLOW_MS" "$IIS_AWK" "$combined")

    local total error5xx h503 slow redir unique_ips
    total=$(      echo "$stats" | gawk -F'\t' '$1=="TOTAL"     {print $2}')
    error5xx=$(   echo "$stats" | gawk -F'\t' '$1=="5XX"       {print $2}')
    h503=$(       echo "$stats" | gawk -F'\t' '$1=="503_HEALTH"{print $2}')
    slow=$(       echo "$stats" | gawk -F'\t' '$1=="SLOW"      {print $2}')
    redir=$(      echo "$stats" | gawk -F'\t' '$1=="REDIRECT"  {print $2}')
    unique_ips=$( echo "$stats" | gawk -F'\t' '$1=="UNIQUE_IPS"{print $2}')

    fmt_h2 "IIS — Server: $server"
    fmt_kv "Total requests"             "${total:-0}"
    fmt_kv "Unique client IPs"          "${unique_ips:-0}"
    fmt_kv "302 Redirects"              "${redir:-0}"
    fmt_kv_color "5xx errors"           "${error5xx:-0}"  "$C_RED"
    fmt_kv_color "  Health 503"         "${h503:-0}"      "$C_YELLOW"
    fmt_kv_color "Slow (>${OPT_SLOW_MS}ms)"  "${slow:-0}" "$C_YELLOW"

    echo ""
    printf "    %-10s %s\n" "Status" "Count"
    printf "    %s\n" "--------------------"
    echo "$stats" | sort -t$'\t' -k3 -rn | gawk -F'\t' '$1=="STATUS" {printf "    %-10s %s\n", $2, $3}'

    echo ""
    printf "    %-6s %-55s\n" "Count" "Endpoint"
    printf "    %s\n" "-------------------------------------------------------------------"
    echo "$stats" | gawk -F'\t' '$1=="ENDPOINT" {printf "    %-6d %s\n", $3, $2}'

    # Unique client IP roster — every IP that issued at least one request,
    # ranked by request count. The "% of total" column helps spot whether
    # one client dominates traffic (e.g. health-checker, leaked credential).
    echo ""
    printf "    %-6s %-18s %s\n" "Count" "Client IP" "% of total"
    printf "    %s\n" "------------------------------------------"
    echo "$stats" | gawk -F'\t' -v total="${total:-0}" '
        $1 == "CLIENT_IP" {
            pct = (total > 0) ? ($3 / total * 100) : 0
            printf "    %-6d %-18s %5.1f%%\n", $3, $2, pct
        }
    '
}

analyze_region_iis() {
    local region_id="$1" date_list_file="$2"
    fmt_h1 "IIS Analysis — Region: ${REGION_NAMES[$region_id]}"

    local all_servers="${REGION_APIS[$region_id]},${REGION_APPS[$region_id]}"
    IFS=',' read -ra servers <<< "$all_servers"
    for srv in "${servers[@]}"; do
        analyze_server_iis "$srv" "$date_list_file"
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
        fmt_h1 "IIS Log Analysis Report"
        fmt_kv "Period" "${date_start}  →  ${date_end}  (${n_dates} days)"

        for rid in "${REGION_IDS[@]}"; do
            [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]] && continue
            analyze_region_iis "$rid" "$date_list_file"
        done

        fmt_footer
    } | if [[ -n "$OPT_OUTPUT" ]]; then tee "$OPT_OUTPUT"; else cat; fi

    if [[ -n "$OPT_OUTPUT" ]]; then log_info "Report written to: $OPT_OUTPUT"; fi
}

main "$@"
