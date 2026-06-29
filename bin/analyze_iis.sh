#!/usr/bin/env bash
# bin/analyze_iis.sh
# ----------------------------------------------------------------------------
# IIS W3C log analyser — surfaces HTTP-level signals per server, per region.
# Reports business-only traffic: /health excluded unconditionally; test-host
# client IPs filtered per --test-hosts mode (default: exclude).
#
# Inputs : <log_dir>/<server>/iis/u_exYYMMDD.log  (W3C extended, space-delim)
# Metrics (business requests only):
#   - Total requests, unique client IPs.
#   - Slow requests where time-taken >= role-resolved threshold.
#     API servers use --slow-api-ms; APP servers use --slow-app-ms.
#   - Status code distribution (Top-N, business-only).
#   - Top-N endpoints (--top, default 10, 0=all), with DICOM study/series UIDs
#     collapsed into templates so cardinality stays manageable.
#   - Top-N client IPs (--top, default 10, 0=all).
#
# Views: --view detail (default) = per-server tables; --view summary = KPI text.
# Formats: --format text (default) | tsv | csv (governs detail file/view; C10).
# Persistence: always-on via output_utils (persist_init + persist_views).
# Emit-stats: --emit-stats prints iis_stats.tsv verbatim; short-circuits before
#   persist_init (no files, no banner). Machine-readable handoff for overview.
#
# See docs/design.md §3.2 for field semantics.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"
source "${SCRIPT_DIR}/../lib/csv_utils.sh"
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"
source "${SCRIPT_DIR}/../lib/aggregate_utils.sh"
source "${SCRIPT_DIR}/../lib/output_utils.sh"

REGIONS_CONF="${SCRIPT_DIR}/../conf/regions.conf"
TEST_HOSTS_CONF="${SCRIPT_DIR}/../conf/test_hosts.conf"
OPT_TEST_HOSTS="exclude"
TEST_HOST_SET=""

OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT_DIR=""    # always-on persistence directory (C1: default empty)
OPT_TODAY=0
OPT_DAYS_SET=0
OPT_TOP=10
OPT_SLOW_API_MS=2000
OPT_SLOW_APP_MS=5000
OPT_FORMAT="text"
OPT_VIEW="detail"    # detail (default, standalone) | summary
OPT_MERGE=0
OPT_EMIT_STATS=0

# ---------------------------------------------------------------------------
# Renderer context globals (set in main, read by iis_render_* functions)
# ---------------------------------------------------------------------------
_IIS_DATE_START=""
_IIS_DATE_END=""
_IIS_N_DATES=0
_IIS_MERGED=0
declare -a  _IIS_SERVER_KEYS=()   # ordered "region|role|server" keys
declare -A  _IIS_THRESHOLD=()     # key -> slow_ms threshold

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze IIS W3C access logs: business-only request counts, status codes,
slow requests, and per-endpoint breakdowns.
/health is excluded unconditionally. Test-host client IPs are filtered
per --test-hosts mode (default: exclude).

Options:
  --log-dir PATH       [required] root log directory
  --region REGION      taipei | taichung | all       (default: all)
  --today              alias for --date \$(today); sets single-day window
  --days N             integer >= 1                  (default: 7)   [implicit fallback]
  --from / --to DATE   YYYY-MM-DD inclusive range    (use together)
  --date DATE          YYYY-MM-DD single day
  --view V             summary | detail              (default: detail)
  --format FMT         text | tsv | csv              (default: text)
  --top N              integer >= 0, 0 = ALL         (default: 10)
  --slow-api-ms N      integer ms                    (default: 2000)
  --slow-app-ms N      integer ms                    (default: 5000)
  --merge              REQUIRES --region all; merges hosts, splits API vs APP
  --emit-stats         print iis_stats.tsv to stdout; no persistence, no banner
  --test-hosts MODE    exclude | only | all          (default: exclude)
                       exclude = drop test-host IPs (business-only)
                       only    = keep ONLY test-host IPs (QA audit)
                       all     = keep all IPs (no test-host filter)
  --output-dir DIR     persistence dir               (default: env > ./log-parse)
  --conf FILE          regions config                (default: conf/regions.conf)
  -v, --verbose / -h, --help

Interval flags are mutually exclusive: choose ONE of
  --today | --date | --from/--to | --days (explicit)
  If multiple are supplied the script aborts (fail-fast per project rule #1).

Common scenarios:
  # 1. Daily IIS health, all regions, default per-role slow thresholds
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21

  # 2. Weekly audit, tighten API SLA, show ALL endpoints, CSV export
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0 \\
       --view detail --format csv

  # 3. Management summary, top-3 endpoints
  bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --view summary --top 3
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)      OPT_LOG_DIR="$2";                   shift 2 ;;
            --days)         OPT_DAYS="$2"; OPT_DAYS_SET=1;      shift 2 ;;
            --from)         OPT_FROM="$2";                      shift 2 ;;
            --to)           OPT_TO="$2";                        shift 2 ;;
            --date)         OPT_DATE="$2";                      shift 2 ;;
            --today)        OPT_TODAY=1;                        shift ;;
            --region)       OPT_REGION="$2";                    shift 2 ;;
            --view)         OPT_VIEW="$2";                      shift 2 ;;
            --format)       OPT_FORMAT="$2";                    shift 2 ;;
            --top)          OPT_TOP="$2";                       shift 2 ;;
            --slow-api-ms)  OPT_SLOW_API_MS="$2";              shift 2 ;;
            --slow-app-ms)  OPT_SLOW_APP_MS="$2";              shift 2 ;;
            --merge)        OPT_MERGE=1;                        shift ;;
            --emit-stats)   OPT_EMIT_STATS=1;                  shift ;;
            --test-hosts)   OPT_TEST_HOSTS="$2";               shift 2 ;;
            --output-dir)   OPT_OUTPUT_DIR="$2";               shift 2 ;;
            --conf)         REGIONS_CONF="$2";                  shift 2 ;;
            -v|--verbose)   LOG_LEVEL=DEBUG;                    shift ;;
            -h|--help)      usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    if [[ -z "$OPT_LOG_DIR" ]]; then die "--log-dir is required"; fi
    if [[ ! -d "$OPT_LOG_DIR" ]]; then die "Log directory not found: $OPT_LOG_DIR"; fi
    if [[ ! -f "$REGIONS_CONF" ]]; then die "conf file not found: $REGIONS_CONF"; fi
    assert_enum "--format"     "$OPT_FORMAT"     text tsv csv
    assert_enum "--view"       "$OPT_VIEW"       summary detail
    assert_enum "--test-hosts" "$OPT_TEST_HOSTS" exclude only all
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

# append_iis_server_files SERVER DATE_LIST_FILE OUTPUT_FILE
#   Purpose : Append existing IIS log files for SERVER into OUTPUT_FILE.
#   Args    : SERVER — hostname/IP; DATE_LIST_FILE — one YYYY-MM-DD per line;
#             OUTPUT_FILE — destination file (must already exist).
#   Output  : nothing on stdout.
#   Returns / Side effects : none (missing server dir logged as warning).
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

# iis_corpus_stats SERVER ROLE REGION COMBINED THRESHOLD
#   Purpose : Run AGG_IIS_AWK once on COMBINED, prefix each row with
#             IIS<TAB>REGION<TAB>ROLE<TAB>SERVER<TAB>, and append the
#             dimensioned rows to ${WORK_TMPDIR}/iis_stats.tsv.
#             Also records the server key and threshold in renderer globals.
#   Args    : SERVER — hostname/IP or merged label; ROLE — api|app;
#             REGION — region id or "all" (merged); COMBINED — path to
#             concatenated IIS log file (must be non-empty); THRESHOLD —
#             slow-request threshold in ms (role-resolved).
#   Output  : nothing on stdout; appends to ${WORK_TMPDIR}/iis_stats.tsv.
#   Returns / Side effects : appends to _IIS_SERVER_KEYS; sets _IIS_THRESHOLD[key].
#   Errors / Notes : caller must ensure COMBINED is non-empty before calling.
iis_corpus_stats() {
    local server="$1" role="$2" region="$3" combined="$4" threshold="$5"
    local key="${region}|${role}|${server}"
    _IIS_SERVER_KEYS+=("$key")
    _IIS_THRESHOLD["$key"]="$threshold"
    agg_iis_rows "$combined" "$threshold" "$OPT_TOP" "$OPT_TEST_HOSTS" "$TEST_HOST_SET" \
        | gawk -F'\t' -v region="$region" -v role="$role" -v server="$server" \
          'BEGIN{OFS="\t"} {print "IIS", region, role, server, $0}' \
        >> "${WORK_TMPDIR}/iis_stats.tsv"
}

# ---------------------------------------------------------------------------
# iis_render_summary — management summary view (format-independent, always text)
# ---------------------------------------------------------------------------

# iis_render_summary
#   Purpose : Aggregate stats across all servers in iis_stats.tsv and render
#             a concise management-level summary: KPIs + percentages + Top-N
#             enumeration of endpoints, status codes, client IPs.
#             Format-independent (always text) per C10.
#   Args    : none (uses globals: OPT_REGION, OPT_TOP, _IIS_DATE_*, WORK_TMPDIR).
#   Output  : summary block on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : gracefully handles empty stats (all zeros/N/A).
iis_render_summary() {
    local stats_file="${WORK_TMPDIR}/iis_stats.tsv"
    local rlabel
    if [[ "$OPT_REGION" == "all" ]]; then
        rlabel="all"
    else
        rlabel="${REGION_NAMES[$OPT_REGION]:-$OPT_REGION}"
    fi

    printf "%b============ IIS Summary — Region: %s ============%b\n" \
        "$C_BOLD" "$rlabel" "$C_RESET"
    fmt_kv "Period" "${_IIS_DATE_START}  →  ${_IIS_DATE_END}  (${_IIS_N_DATES} days)"

    # Single-pass aggregation across all servers
    # (re-aggregates iis_stats.tsv which is already business-filtered by agg_iis_rows)
    local agg_out
    agg_out=$(gawk -F'\t' -v top="$OPT_TOP" '
        $1=="IIS" && $5=="TOTAL"      { tot     += $6+0 }
        $1=="IIS" && $5=="SLOW"       { slow    += $6+0 }
        $1=="IIS" && $5=="UNIQUE_IPS" { uniq_ip += $6+0 }
        $1=="IIS" && $5=="ENDPOINT"   { ep[$6]  += $7+0 }
        $1=="IIS" && $5=="STATUS"     { st[$6]  += $7+0 }
        $1=="IIS" && $5=="CLIENT_IP"  { ip[$6]  += $7+0 }
        END {
            printf "TOTAL\t%d\n",      tot
            printf "SLOW\t%d\n",       slow
            printf "UNIQUE_IPS\t%d\n", uniq_ip
            n = asorti(ep, ep_sorted, "@val_num_desc")
            lim = (top==0) ? n : (n < top ? n : top)
            for (i=1; i<=lim; i++) {
                e = ep_sorted[i]
                pct = (tot>0) ? (ep[e]/tot*100) : 0
                printf "ENDPOINT\t%s\t%d\t%.1f\n", e, ep[e], pct
            }
            m = asorti(st, st_sorted, "@val_num_desc")
            lim3 = (m < 3) ? m : 3
            for (i=1; i<=lim3; i++) {
                c = st_sorted[i]
                pct = (tot>0) ? (st[c]/tot*100) : 0
                printf "STATUS\t%s\t%d\t%.1f\n", c, st[c], pct
            }
            k = asorti(ip, ip_sorted, "@val_num_desc")
            lim3 = (k < 3) ? k : 3
            for (i=1; i<=lim3; i++) {
                a = ip_sorted[i]
                pct = (tot>0) ? (ip[a]/tot*100) : 0
                printf "CLIENT_IP\t%s\t%d\t%.1f\n", a, ip[a], pct
            }
        }
    ' "$stats_file")

    local total slow unique_ips
    total=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="TOTAL"     {print $2}')
    slow=$(      printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="SLOW"      {print $2}')
    unique_ips=$(printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="UNIQUE_IPS"{print $2}')

    local pct_slow
    pct_slow=$(fmt_pct "${slow:-0}" "${total:-0}")

    fmt_kv "資料範圍"        "業務請求 (排除 /health；測試主機=${OPT_TEST_HOSTS})"
    fmt_kv "總請求數"          "${total:-0}"
    fmt_kv "不重複用戶端 IP"   "${unique_ips:-0}"
    fmt_kv "慢速率"            "${pct_slow}  (${slow:-0})"

    # Top-N endpoints (numbered list)
    fmt_h3 "Top 端點 (佔比)"
    local ep_i=0
    while IFS=$'\t' read -r tag ep cnt pct; do
        if [[ "$tag" != "ENDPOINT" ]]; then continue; fi
        ep_i=$((ep_i + 1))
        printf "    %d. %-52s  %s%%\n" "$ep_i" "$ep" "$pct"
    done < <(printf '%s\n' "$agg_out")

    # Top-3 status codes (inline)
    local st_line=""
    while IFS=$'\t' read -r tag code cnt pct; do
        if [[ "$tag" != "STATUS" ]]; then continue; fi
        if [[ -n "$st_line" ]]; then st_line="${st_line} · "; fi
        st_line="${st_line}${code} ${pct}%"
    done < <(printf '%s\n' "$agg_out")
    fmt_h3 "狀態碼分布 (Top 3)"
    printf "      %s\n" "${st_line:-N/A}"

    # Top-3 client IPs (inline)
    local ip_line=""
    while IFS=$'\t' read -r tag ip_addr cnt pct; do
        if [[ "$tag" != "CLIENT_IP" ]]; then continue; fi
        if [[ -n "$ip_line" ]]; then ip_line="${ip_line} · "; fi
        ip_line="${ip_line}${ip_addr} ${pct}%"
    done < <(printf '%s\n' "$agg_out")
    fmt_h3 "Top 用戶端 IP"
    printf "      %s\n" "${ip_line:-N/A}"
}

# ---------------------------------------------------------------------------
# iis_render_detail — detail view dispatcher (text | tsv | csv)
# ---------------------------------------------------------------------------

# iis_render_detail
#   Purpose : Render the full detail view, routing to text or structured
#             format based on OPT_FORMAT.
#   Args    : none (uses globals: OPT_FORMAT, _IIS_*, WORK_TMPDIR, REGION_NAMES).
#   Output  : detail content on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : text format is byte-for-byte compatible with the pre-refactor
#             per-server layout (guards B-section baselines, B37/B33). tsv/csv
#             produce a standardized long-format table via AGG_CSV_FUNC.
iis_render_detail() {
    if [[ "$OPT_FORMAT" == "tsv" || "$OPT_FORMAT" == "csv" ]]; then
        _iis_render_detail_structured
        return
    fi
    _iis_render_detail_text
}

# _iis_render_detail_text
#   Purpose : Render the current (pre-refactor-compatible) per-server text layout.
#             Byte-for-byte identical output to the old render_iis_stats function
#             but reads from iis_stats.tsv (no re-parse of raw log files).
#   Args    : none.
#   Output  : fmt_h1 banner + per-region/server KV blocks + tables + fmt_footer.
#   Returns / Side effects : none.
#   Notes   : Color-safe: uses $C_RED/$C_YELLOW/$C_RESET which are blanked by
#             fmt_set_color_state when NO_COLOR=1 inside persist_views (C3/I08).
_iis_render_detail_text() {
    fmt_h1 "IIS Log Analysis Report"
    fmt_kv "Period" "${_IIS_DATE_START}  →  ${_IIS_DATE_END}  (${_IIS_N_DATES} days)"

    local prev_region=""
    for skey in "${_IIS_SERVER_KEYS[@]}"; do
        local region role server
        IFS='|' read -r region role server <<< "$skey"
        local threshold="${_IIS_THRESHOLD[$skey]}"

        if [[ "$_IIS_MERGED" -eq 0 ]]; then
            if [[ "$region" != "$prev_region" ]]; then
                fmt_h1 "IIS Analysis — Region: ${REGION_NAMES[$region]}"
                prev_region="$region"
            fi
        fi

        fmt_h2 "IIS — ${server}"
        _iis_render_server_text "$region" "$role" "$server" "$threshold"
    done

    fmt_footer
}

# _iis_render_server_text REGION ROLE SERVER THRESHOLD
#   Purpose : Render one server's KV block + Status/Endpoint/Client-IP tables
#             from iis_stats.tsv.  Output is byte-compatible with the old
#             render_iis_stats function.
#   Args    : REGION — region id; ROLE — api|app; SERVER — hostname/IP or merged
#             label; THRESHOLD — slow-ms for label display.
#   Output  : KV rows + three tables on stdout.
#   Returns / Side effects : none.
#   Notes   : Reads ${WORK_TMPDIR}/iis_stats.tsv; multiple gawk passes acceptable
#             (formatting-only; stats were computed once in iis_corpus_stats).
_iis_render_server_text() {
    local region="$1" role="$2" server="$3" threshold="$4"
    local stats_file="${WORK_TMPDIR}/iis_stats.tsv"

    # Extract scalar KPIs in a single gawk pass
    local scalars
    scalars=$(gawk -F'\t' -v r="$region" -v ro="$role" -v s="$server" '
        $1=="IIS" && $2==r && $3==ro && $4==s {
            if ($5=="TOTAL")      printf "TOTAL\t%s\n",      $6
            if ($5=="SLOW")       printf "SLOW\t%s\n",       $6
            if ($5=="UNIQUE_IPS") printf "UNIQUE_IPS\t%s\n", $6
        }
    ' "$stats_file")

    local total slow unique_ips
    total=$(     printf '%s\n' "$scalars" | gawk -F'\t' '$1=="TOTAL"     {print $2}')
    slow=$(      printf '%s\n' "$scalars" | gawk -F'\t' '$1=="SLOW"      {print $2}')
    unique_ips=$(printf '%s\n' "$scalars" | gawk -F'\t' '$1=="UNIQUE_IPS"{print $2}')

    fmt_kv "Scope"                        "business requests (excl. /health; test-hosts=${OPT_TEST_HOSTS})"
    fmt_kv "Total requests"               "${total:-0}"
    fmt_kv "Unique client IPs"            "${unique_ips:-0}"
    fmt_kv_color "Slow (>${threshold}ms)" "${slow:-0}"      "$C_YELLOW"

    # HTTP Status table: [Status, Count, % of total], count-desc sort in-gawk.
    # Composite key (zero-padded count + status-code) gives deterministic order.
    echo ""
    printf "    %-10s  %-8s  %s\n" "Status" "Count" "% of total"
    printf "    %s\n" "--------------------------------"
    gawk -F'\t' -v r="$region" -v ro="$role" -v s="$server" \
        -v total="${total:-0}" '
        $1=="IIS" && $2==r && $3==ro && $4==s && $5=="STATUS" {
            k = sprintf("%012d\t%s", $7, $6)
            code[k] = $6; cnt[k] = $7
        }
        END {
            m = asorti(code, idx, "@ind_str_desc")
            for (i = 1; i <= m; i++) {
                c   = code[idx[i]]
                n   = cnt[idx[i]]
                pct = (total > 0) ? (n / total * 100) : 0
                printf "    %-10s  %-8d  %5.1f%%\n", c, n, pct
            }
        }' "$stats_file"

    # Endpoint table: [Endpoint, Avg(s), Count, % of total], count-desc.
    echo ""
    printf "    %-55s  %-8s  %-8s  %s\n" "Endpoint" "Avg(s)" "Count" "% of total"
    printf "    %s\n" "---------------------------------------------------------------------------------------"
    gawk -F'\t' -v r="$region" -v ro="$role" -v s="$server" \
        -v total="${total:-0}" '
        $1=="IIS" && $2==r && $3==ro && $4==s && $5=="ENDPOINT" {
            pct = (total > 0) ? ($7 / total * 100) : 0
            printf "    %-55s  %-8.2f  %-8d  %5.1f%%\n", $6, $8, $7, pct
        }' "$stats_file"

    # Client IP table: [Client IP, Count, % of total], count-desc.
    echo ""
    printf "    %-18s  %-8s  %s\n" "Client IP" "Count" "% of total"
    printf "    %s\n" "----------------------------------------"
    gawk -F'\t' -v r="$region" -v ro="$role" -v s="$server" \
        -v total="${total:-0}" '
        $1=="IIS" && $2==r && $3==ro && $4==s && $5=="CLIENT_IP" {
            pct = (total > 0) ? ($7 / total * 100) : 0
            printf "    %-18s  %-8d  %5.1f%%\n", $6, $7, pct
        }' "$stats_file"
}

# _iis_render_detail_structured
#   Purpose : Emit the standardized long-format table (TSV or CSV) for the
#             detail view.  One row per (server, metric, key) combination.
#             Header printed once; --top cap applied during stats collection
#             (ENDPOINT/CLIENT_IP already limited in iis_stats.tsv).
#   Args    : none (uses globals: OPT_FORMAT, _IIS_SERVER_KEYS, WORK_TMPDIR,
#             AGG_CSV_FUNC).
#   Output  : header row + data rows on stdout.
#   Returns / Side effects : none.
#   Notes   : Columns: REGION ROLE SERVER METRIC KEY COUNT AVG_SEC PCT.
#             METRIC ∈ {SUMMARY, STATUS, ENDPOINT, CLIENT_IP}.
#             AVG_SEC = float for ENDPOINT rows, "-" for all others.
_iis_render_detail_structured() {
    local stats_file="${WORK_TMPDIR}/iis_stats.tsv"
    local use_csv=0
    if [[ "$OPT_FORMAT" == "csv" ]]; then use_csv=1; fi

    # Print header
    if [[ "$use_csv" -eq 1 ]]; then
        printf 'REGION,ROLE,SERVER,METRIC,KEY,COUNT,AVG_SEC,PCT\n'
    else
        printf 'REGION\tROLE\tSERVER\tMETRIC\tKEY\tCOUNT\tAVG_SEC\tPCT\n'
    fi

    # Per-server gawk pass; maintains _IIS_SERVER_KEYS ordering
    local struct_prog
    struct_prog="${AGG_CSV_FUNC}"'
function row(r, ro, s, metric, key, count, avgsec, pct) {
    if (use_csv) {
        printf "%s,%s,%s,%s,%s,%s,%s,%s\n",
            q(r), q(ro), q(s), q(metric), q(key), count, q(avgsec), pct
    } else {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
            r, ro, s, metric, key, count, avgsec, pct
    }
}
$1=="IIS" && $2==srv_r && $3==srv_ro && $4==srv_s {
    tag = $5
    if (tag=="TOTAL")      total  = $6+0
    if (tag=="SLOW")       slow   = $6+0
    if (tag=="UNIQUE_IPS") uniq   = $6+0
    if (tag=="STATUS")     { st_c[$6]  = $7+0 }
    if (tag=="ENDPOINT")   { ep_c[$6]  = $7+0; ep_a[$6] = $8+0 }
    if (tag=="CLIENT_IP")  { ip_c[$6]  = $7+0 }
}
END {
    tot = total+0
    row(srv_r, srv_ro, srv_s, "SUMMARY", "TOTAL",      tot,       "-", sprintf("%.1f", (tot>0)?100.0:0))
    pct = (tot>0) ? slow/tot*100 : 0
    row(srv_r, srv_ro, srv_s, "SUMMARY", "SLOW",       slow+0,    "-", sprintf("%.1f", pct))
    row(srv_r, srv_ro, srv_s, "SUMMARY", "UNIQUE_IPS", uniq+0,    "-", "0.0")
    for (code in st_c) {
        pct = (tot>0) ? st_c[code]/tot*100 : 0
        row(srv_r, srv_ro, srv_s, "STATUS", code, st_c[code], "-", sprintf("%.1f", pct))
    }
    n = asorti(ep_c, ep_sorted, "@val_num_desc")
    for (i=1; i<=n; i++) {
        e = ep_sorted[i]
        pct = (tot>0) ? ep_c[e]/tot*100 : 0
        row(srv_r, srv_ro, srv_s, "ENDPOINT", e, ep_c[e],
            sprintf("%.2f", ep_a[e]+0), sprintf("%.1f", pct))
    }
    m = asorti(ip_c, ip_sorted, "@val_num_desc")
    for (i=1; i<=m; i++) {
        ip = ip_sorted[i]
        pct = (tot>0) ? ip_c[ip]/tot*100 : 0
        row(srv_r, srv_ro, srv_s, "CLIENT_IP", ip, ip_c[ip], "-", sprintf("%.1f", pct))
    }
}
'
    for skey in "${_IIS_SERVER_KEYS[@]}"; do
        local region role server
        IFS='|' read -r region role server <<< "$skey"
        gawk -F'\t' \
            -v srv_r="$region" -v srv_ro="$role" -v srv_s="$server" \
            -v use_csv="$use_csv" \
            "$struct_prog" "$stats_file"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_tmpdir
    load_regions
    TEST_HOST_SET="$(load_test_hosts "$TEST_HOSTS_CONF")"

    # Resolve interval (mutex: die on >1 selector)
    resolve_interval \
        --today "$OPT_TODAY" --date "$OPT_DATE" \
        --from  "$OPT_FROM"  --to   "$OPT_TO" \
        --days-set "$OPT_DAYS_SET" --days "$OPT_DAYS"

    local date_list_file="${WORK_TMPDIR}/dates.txt"
    build_date_list "${INTERVAL_ARGS[@]}" > "$date_list_file"

    _IIS_DATE_START=$(head -1 "$date_list_file")
    _IIS_DATE_END=$(tail -1 "$date_list_file")
    _IIS_N_DATES=$(count_lines "$date_list_file")

    log_info "Period: ${_IIS_DATE_START} → ${_IIS_DATE_END} (${_IIS_N_DATES} days)"

    local stats_file="${WORK_TMPDIR}/iis_stats.tsv"
    : > "$stats_file"

    # Build iis_stats.tsv — one corpus per server (or merged pool)
    if [[ "$OPT_MERGE" -eq 1 ]]; then
        _IIS_MERGED=1
        local combined_api="${WORK_TMPDIR}/iis_merged_api.log"
        local combined_app="${WORK_TMPDIR}/iis_merged_app.log"
        : > "$combined_api"
        : > "$combined_app"

        local rid
        for rid in "${REGION_IDS[@]}"; do
            local apis="${REGION_APIS[$rid]}" apps="${REGION_APPS[$rid]}"
            local -a api_srvs app_srvs
            IFS=',' read -ra api_srvs <<< "$apis"
            for srv in "${api_srvs[@]}"; do
                append_iis_server_files "$srv" "$date_list_file" "$combined_api"
            done
            IFS=',' read -ra app_srvs <<< "$apps"
            for srv in "${app_srvs[@]}"; do
                append_iis_server_files "$srv" "$date_list_file" "$combined_app"
            done
        done

        if [[ -s "$combined_api" ]]; then
            iis_corpus_stats "API_SERVERS (merged, all regions)" "api" "all" \
                "$combined_api" "$OPT_SLOW_API_MS"
        else
            log_warn "  No API IIS logs found for merged analysis"
        fi
        if [[ -s "$combined_app" ]]; then
            iis_corpus_stats "APP_SERVERS (merged, all regions)" "app" "all" \
                "$combined_app" "$OPT_SLOW_APP_MS"
        else
            log_warn "  No APP IIS logs found for merged analysis"
        fi

    else
        _IIS_MERGED=0
        local rid
        for rid in "${REGION_IDS[@]}"; do
            if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]]; then continue; fi
            local apis="${REGION_APIS[$rid]}" apps="${REGION_APPS[$rid]}"
            local -a api_srvs app_srvs

            IFS=',' read -ra api_srvs <<< "$apis"
            for srv in "${api_srvs[@]}"; do
                local combined="${WORK_TMPDIR}/iis_${srv}.log"
                : > "$combined"
                append_iis_server_files "$srv" "$date_list_file" "$combined"
                if [[ -s "$combined" ]]; then
                    iis_corpus_stats "$srv" "api" "$rid" "$combined" "$OPT_SLOW_API_MS"
                else
                    log_warn "  No IIS logs found for $srv"
                fi
            done

            IFS=',' read -ra app_srvs <<< "$apps"
            for srv in "${app_srvs[@]}"; do
                local combined="${WORK_TMPDIR}/iis_${srv}.log"
                : > "$combined"
                append_iis_server_files "$srv" "$date_list_file" "$combined"
                if [[ -s "$combined" ]]; then
                    iis_corpus_stats "$srv" "app" "$rid" "$combined" "$OPT_SLOW_APP_MS"
                else
                    log_warn "  No IIS logs found for $srv"
                fi
            done
        done
    fi

    # --emit-stats: short-circuit BEFORE persist_init (no files, no banner)
    if [[ "$OPT_EMIT_STATS" -eq 1 ]]; then
        cat "$stats_file"
        return
    fi

    persist_init "$OPT_OUTPUT_DIR"

    persist_views iis "$OPT_VIEW" "$OPT_FORMAT" \
        iis_render_summary iis_render_detail
}

main "$@"
