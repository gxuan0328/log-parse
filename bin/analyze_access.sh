#!/usr/bin/env bash
# bin/analyze_access.sh
# ----------------------------------------------------------------------------
# Cross-correlate API and APP access logs within each region.
#
# Domain flow:
#   HIS  ──(authenticate)──▶  API server  ──issues URL-Token──▶  Browser
#   Browser  ──opens viewer with URL-Token──▶  APP server  ──verifies token──▶ DICOM
#
# Correlation key:  API.ISSUE_TOKEN (CSV col 9)  ≡  APP.TOKEN (CSV col 2)
#
# For each (region, date range) the analyser yields three categories:
#   NORMAL     — APP saw a token previously issued by the same region's API.
#   ORPHAN     — APP received a token with no matching API issuance.
#                  → cross-region replay, crafted URL, or ingestion lag.
#   UNVERIFIED — API issued a token that APP never received.
#                  → user abandoned the session, or network failure.
#
# See docs/design.md §3.1 for the full specification.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/date_utils.sh
source "${SCRIPT_DIR}/../lib/date_utils.sh"
# shellcheck source=../lib/csv_utils.sh
source "${SCRIPT_DIR}/../lib/csv_utils.sh"
# shellcheck source=../lib/fmt_utils.sh
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"

REGIONS_CONF="${SCRIPT_DIR}/../conf/regions.conf"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT=""
OPT_FORMAT="text"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Cross-correlate API and APP access logs within the same region.
Identifies normal flows (API-issued token → APP verification) and abnormal accesses.

Options:
  --log-dir PATH          Root log directory [required]
  --days N                Analyze last N days from today (default: $OPT_DAYS)
  --from YYYY-MM-DD       Start date (inclusive)
  --to   YYYY-MM-DD       End date   (inclusive)
  --date YYYY-MM-DD       Single date analysis
  --region REGION         Region filter: taipei | taichung | all (default: all)
  --output FILE           Write report to file (default: stdout)
  --format text|tsv       Output format (default: text)
  --conf FILE             Regions config file (default: conf/regions.conf)
  -v, --verbose           Enable debug logging
  -h, --help              Show this help

Examples:
  # Analyze last 7 days for all regions
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # Specific date, taipei only
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei

  # Date range, TSV output to file
  $(basename "$0") --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-21 --to 2026-05-25 --format tsv --output access_report.tsv
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)  OPT_LOG_DIR="$2";  shift 2 ;;
            --days)     OPT_DAYS="$2";     shift 2 ;;
            --from)     OPT_FROM="$2";     shift 2 ;;
            --to)       OPT_TO="$2";       shift 2 ;;
            --date)     OPT_DATE="$2";     shift 2 ;;
            --region)   OPT_REGION="$2";   shift 2 ;;
            --output)   OPT_OUTPUT="$2";   shift 2 ;;
            --format)   OPT_FORMAT="$2";   shift 2 ;;
            --conf)     REGIONS_CONF="$2"; shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG; shift ;;
            -h|--help)  usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$OPT_LOG_DIR" ]] && die "--log-dir is required"
    [[ -d "$OPT_LOG_DIR" ]] || die "Log directory not found: $OPT_LOG_DIR"
    [[ -f "$REGIONS_CONF" ]] || die "Regions config not found: $REGIONS_CONF"
}

# ---------------------------------------------------------------------------
# Region loading
# ---------------------------------------------------------------------------

# load_regions — sets REGION_IDS[], REGION_NAMES[], REGION_APIS[], REGION_APPS[]
declare -a REGION_IDS=()
declare -A REGION_NAMES=() REGION_APIS=() REGION_APPS=()

load_regions() {
    while IFS='|' read -r rid rname apis apps; do
        [[ "$rid" =~ ^# || -z "$rid" ]] && continue
        REGION_IDS+=("$rid")
        REGION_NAMES["$rid"]="$rname"
        REGION_APIS["$rid"]="$apis"    # comma-separated server IPs
        REGION_APPS["$rid"]="$apps"
    done < "$REGIONS_CONF"
    log_debug "Loaded ${#REGION_IDS[@]} regions: ${REGION_IDS[*]}"
}

# ---------------------------------------------------------------------------
# File collection
# ---------------------------------------------------------------------------

# collect_access_csvs SERVER DATE_LIST_FILE → prints file paths
collect_access_csvs() {
    local server="$1" date_list_file="$2"
    while IFS= read -r d; do
        local f="${OPT_LOG_DIR}/${server}/app/${d}/app-access-${d}.csv"
        [[ -f "$f" ]] && echo "$f"
    done < "$date_list_file"
}

# ---------------------------------------------------------------------------
# Core cross-correlation engine (gawk)
# ---------------------------------------------------------------------------

CORRELATE_AWK='
# ----------------------------------------------------------------------------
# Cross-correlation awk program.
#
# Inputs (two TAB-delimited intermediate files produced by csv_utils):
#
#   File 1 (api_tsv):
#     ISSUE_TOKEN | REQ_ID | PATIENT | HOSP | PRSN | CLIENT_IP | SERVER | API_TIME
#
#   File 2 (app_tsv):
#     TOKEN | REQ_ID | VERIFY | PATIENT | HOSP | PRSN | CLIENT_IP | SERVER | APP_TIME
#
# Output (one TAB-delimited line per record, prefixed by STATUS):
#
#   NORMAL     | api_req_id | app_req_id | patient | hosp | prsn |
#              | client_ip  | api_server | app_server |
#              | api_time   | app_time   | delta_sec | verify_status
#
#   ORPHAN     | -          | app_req_id | patient | hosp | prsn |
#              | client_ip  | -          | app_server |
#              | -          | app_time   | -         | verify_status
#
#   UNVERIFIED | api_req_id | -          | patient | hosp | prsn |
#              | client_ip  | api_server | -        |
#              | api_time   | -          | -        | -
# ----------------------------------------------------------------------------

# ts_to_epoch — convert "YYYY-MM-DD HH:MM:SS.mmm" to Unix epoch with ms.
function ts_to_epoch(ts,    parts, dparts, tparts, sparts) {
    n = split(ts, parts, " ")
    if (n < 2) return 0
    split(parts[1], dparts, "-")
    split(parts[2], tparts, ":")
    split(tparts[3], sparts, ".")
    epoch = mktime(dparts[1] " " dparts[2] " " dparts[3] " " tparts[1] " " tparts[2] " " int(sparts[1]))
    ms = (length(sparts) > 1) ? sparts[2]+0 : 0
    return epoch + ms / 1000
}

# coalesce — return a unless empty, else b. Used to fill in fields that the
# APP-side record left blank by borrowing from the API-side row.
function coalesce(a, b) { return (a != "") ? a : b }

# First pass: ingest the API issuances into a token-keyed hash.
# We use FILENAME == api_file rather than the idiomatic FNR == NR because
# the latter mis-classifies the second file when api_tsv is empty (FNR
# resets to 1 on the second file, which matches NR==1).
FILENAME == api_file {
    tok = $1
    if (tok == "") next
    api_req_id[tok]    = $2
    api_patient[tok]   = $3
    api_hosp[tok]      = $4
    api_prsn[tok]      = $5
    api_client_ip[tok] = $6
    api_server[tok]    = $7
    api_time[tok]      = $8
    next
}

# Second pass: classify each APP record as NORMAL or ORPHAN; mark token used.
{
    tok = $1
    if (tok == "") next
    verify   = $3
    patient  = coalesce($4, api_patient[tok])
    hosp     = coalesce($5, api_hosp[tok])
    prsn     = coalesce($6, api_prsn[tok])
    client   = coalesce($7, api_client_ip[tok])
    app_srv  = $8
    app_ts   = $9

    if (tok in api_time) {
        # NORMAL — token was issued by the same regional API
        api_ts    = api_time[tok]
        epoch_api = ts_to_epoch(api_ts)
        epoch_app = ts_to_epoch(app_ts)
        delta = (epoch_api > 0 && epoch_app > 0) \
                ? sprintf("%.3f", epoch_app - epoch_api) : "N/A"
        print "NORMAL" "\t" api_req_id[tok] "\t" $2 "\t" patient "\t" hosp "\t" prsn \
              "\t" client "\t" api_server[tok] "\t" app_srv \
              "\t" api_ts "\t" app_ts "\t" delta "\t" verify
        app_used[tok] = 1
    } else {
        # ORPHAN — APP received a token with no API issuance on record
        print "ORPHAN" "\t" "-" "\t" $2 "\t" patient "\t" hosp "\t" prsn \
              "\t" client "\t" "-" "\t" app_srv \
              "\t" "-" "\t" app_ts "\t" "-" "\t" verify
    }
}

# End-of-input: every API token not consumed by an APP record is UNVERIFIED.
END {
    for (tok in api_time) {
        if (!(tok in app_used)) {
            print "UNVERIFIED" "\t" api_req_id[tok] "\t" "-" "\t" api_patient[tok] \
                  "\t" api_hosp[tok] "\t" api_prsn[tok] "\t" api_client_ip[tok] \
                  "\t" api_server[tok] "\t" "-" \
                  "\t" api_time[tok] "\t" "-" "\t" "-" "\t" "-"
        }
    }
}
'

# ---------------------------------------------------------------------------
# Run correlation for a single region
# ---------------------------------------------------------------------------

# correlate_region REGION_ID DATE_LIST_FILE
#   Purpose : Run the full extract → join → render pipeline for one region.
#   Steps   : (1) Collect API records across every configured API server.
#             (2) Collect APP records across every configured APP server.
#             (3) Invoke CORRELATE_AWK with both intermediates.
#             (4) Hand off to a renderer (text or tsv).
#   Notes   : An empty region (no records on either side) logs a warning and
#             returns cleanly so other regions still process.
correlate_region() {
    local region_id="$1" date_list_file="$2"

    local api_servers app_servers
    IFS=',' read -ra api_servers <<< "${REGION_APIS[$region_id]}"
    IFS=',' read -ra app_servers <<< "${REGION_APPS[$region_id]}"

    local api_tsv="${WORK_TMPDIR}/api_${region_id}.tsv"
    local app_tsv="${WORK_TMPDIR}/app_${region_id}.tsv"

    # Extract API records
    : > "$api_tsv"
    for srv in "${api_servers[@]}"; do
        while IFS= read -r csv_file; do
            log_debug "  API CSV: $csv_file"
            extract_api_records "$csv_file" >> "$api_tsv"
        done < <(collect_access_csvs "$srv" "$date_list_file")
    done

    # Extract APP records
    : > "$app_tsv"
    for srv in "${app_servers[@]}"; do
        while IFS= read -r csv_file; do
            log_debug "  APP CSV: $csv_file"
            extract_app_records "$csv_file" >> "$app_tsv"
        done < <(collect_access_csvs "$srv" "$date_list_file")
    done

    local api_count app_count
    api_count=$(count_lines "$api_tsv")
    app_count=$(count_lines "$app_tsv")
    log_info "Region [${REGION_NAMES[$region_id]}] — API records: $api_count, APP records: $app_count"

    if (( api_count == 0 && app_count == 0 )); then
        log_warn "  No access CSV data found for this period."
        return
    fi
    (( api_count == 0 )) && log_info "  No API records found; all APP accesses will be ORPHAN."
    (( app_count == 0 )) && log_info "  No APP records found; all API issuances will be UNVERIFIED."

    # Run the correlator — pass api_tsv path as variable so FILENAME comparison works
    local result_tsv="${WORK_TMPDIR}/result_${region_id}.tsv"
    gawk -F'\t' -v OFS='\t' -v api_file="$api_tsv" "$CORRELATE_AWK" \
        "$api_tsv" "$app_tsv" > "$result_tsv"

    # Render
    if [[ "$OPT_FORMAT" == "tsv" ]]; then
        render_tsv "$region_id" "$result_tsv"
    else
        render_text_region "$region_id" "$result_tsv"
    fi
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

render_tsv() {
    local region_id="$1" result_tsv="$2"
    local rname="${REGION_NAMES[$region_id]}"
    # Print TSV with region column prepended
    gawk -F'\t' -v OFS='\t' -v region="$rname" \
        '{ print region, $0 }' "$result_tsv"
}

render_text_region() {
    local region_id="$1" result_tsv="$2"
    local rname="${REGION_NAMES[$region_id]}"

    fmt_h2 "Region: ${rname}  (${REGION_APIS[$region_id]} → ${REGION_APPS[$region_id]})"

    # Compute summary stats
    local n_normal n_orphan n_unverified
    n_normal=$(     gawk -F'\t' '$1=="NORMAL"     {c++} END{print c+0}' "$result_tsv")
    n_orphan=$(     gawk -F'\t' '$1=="ORPHAN"     {c++} END{print c+0}' "$result_tsv")
    n_unverified=$( gawk -F'\t' '$1=="UNVERIFIED" {c++} END{print c+0}' "$result_tsv")
    local total=$(( n_normal + n_orphan + n_unverified ))

    fmt_kv "Total correlation records"  "$total"
    fmt_kv_color "  NORMAL  (正常流程)"    "$n_normal"     "$C_GREEN"
    fmt_kv_color "  ORPHAN  (APP無對應API)" "$n_orphan"    "$C_YELLOW"
    fmt_kv_color "  UNVERIFIED (API未被使用)" "$n_unverified" "$C_GREY"

    # ── NORMAL records ──────────────────────────────────────────────────
    if (( n_normal > 0 )); then
        fmt_h3 "正常流程 (NORMAL) — API 簽發後由 APP 驗證"
        gawk -F'\t' '
            $1 != "NORMAL" { next }
            {
                # Cols: STATUS(1) API_REQ(2) APP_REQ(3) PATIENT(4) HOSP(5) PRSN(6)
                #       CLIENT_IP(7) API_SRV(8) APP_SRV(9) API_TIME(10) APP_TIME(11)
                #       DELTA(12) VERIFY(13)
                pid     = substr($4, 1, 16) "..."
                api_t   = $10
                app_t   = $11
                delta   = $12
                verify  = $13
                hosp    = ($5 != "") ? $5 : "-"
                client  = ($7 != "") ? $7 : "-"

                if (delta == "N/A" || delta == "-") {
                    delta_str = "N/A"
                } else {
                    d = delta + 0
                    if (d < 0) d = 0
                    delta_str = sprintf("%.1fs", d)
                }
                printf "    %-28s  %-28s  %8s  %s  HOSP:%-12s  CLIENT:%s\n",
                    api_t, app_t, delta_str, verify, hosp, client
            }
        ' "$result_tsv"

        # Time delta statistics
        echo ""
        gawk -F'\t' '
            $1 == "NORMAL" && $12 != "N/A" && $12 != "-" {
                d = $12 + 0
                if (d >= 0) {
                    sum += d; count++
                    if (min == "" || d < min) min = d
                    if (d > max) max = d
                }
            }
            END {
                if (count > 0) {
                    printf "    %-40s%d\n",  "驗證筆數 (有效時間差)", count
                    printf "    %-40s%.1fs\n", "平均 API→APP 時間差",  sum/count
                    printf "    %-40s%.1fs\n", "最短時間差",           min
                    printf "    %-40s%.1fs\n", "最長時間差",           max
                }
            }
        ' "$result_tsv"
    fi

    # ── ORPHAN records ───────────────────────────────────────────────────
    if (( n_orphan > 0 )); then
        echo ""
        fmt_h3 "非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token"
        gawk -F'\t' '
            $1 != "ORPHAN" { next }
            {
                # ORPHAN: STATUS(1) -(2) APP_REQ(3) PATIENT(4) HOSP(5) PRSN(6)
                #         CLIENT_IP(7) -(8) APP_SRV(9) -(10) APP_TIME(11) -(12) VERIFY(13)
                pid    = substr($4, 1, 16) "..."
                verify = $13
                app_t  = $11
                hosp   = ($5 != "") ? $5 : "-"
                client = ($7 != "") ? $7 : "-"
                printf "    %-28s  APP:%-15s  VERIFY:%-5s  HOSP:%-12s  PATIENT:%s\n",
                    app_t, $9, verify, hosp, pid
            }
        ' "$result_tsv"

        gawk -F'\t' '
            $1 == "ORPHAN" {
                verify = $13
                if (verify == "OK")   ok++
                else                  fail++
            }
            END {
                printf "\n    %-40s%d (成功) / %d (失敗)\n", "ORPHAN 驗證結果", ok+0, fail+0
                if (ok > 0) {
                    printf "    >> [WARN] 存在可能來自其他區域或重播的有效 Token\n"
                }
                if (fail > 0) {
                    printf "    >> [NOTE] 存在無效/過期 Token 的存取嘗試\n"
                }
            }
        ' "$result_tsv"
    fi

    # ── UNVERIFIED records ───────────────────────────────────────────────
    if (( n_unverified > 0 )); then
        echo ""
        fmt_h3 "未被驗證 (UNVERIFIED) — API 簽發但 APP 從未收到驗證請求"
        gawk -F'\t' '
            $1 != "UNVERIFIED" { next }
            {
                pid    = substr($4, 1, 16) "..."
                api_t  = $10
                hosp   = ($5 != "") ? $5 : "-"
                client = ($7 != "") ? $7 : "-"
                printf "    %-28s  API:%-15s  HOSP:%-12s  PATIENT:%s\n",
                    api_t, $8, hosp, pid
            }
        ' "$result_tsv"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_tmpdir
    load_regions

    # Build date list
    local date_list_file="${WORK_TMPDIR}/dates.txt"
    build_date_list \
        ${OPT_DATE:+--date "$OPT_DATE"} \
        ${OPT_FROM:+--from "$OPT_FROM"} \
        ${OPT_TO:+--to "$OPT_TO"} \
        ${OPT_DAYS:+--days "$OPT_DAYS"} \
        > "$date_list_file"

    local date_start date_end
    date_start=$(head -1 "$date_list_file")
    date_end=$(tail -1 "$date_list_file")
    local n_dates
    n_dates=$(count_lines "$date_list_file")

    log_info "Period: $date_start → $date_end ($n_dates days)"
    log_info "Region: $OPT_REGION"

    # Render to buffer (stdout or file)
    local output_cmd=""
    if [[ -n "$OPT_OUTPUT" ]]; then
        output_cmd="tee $OPT_OUTPUT"
    fi

    {
        if [[ "$OPT_FORMAT" == "text" ]]; then
            fmt_h1 "Access Log Cross-Correlation Report"
            fmt_kv "Period" "${date_start}  →  ${date_end}  (${n_dates} days)"
            fmt_kv "Region filter" "$OPT_REGION"
        elif [[ "$OPT_FORMAT" == "tsv" ]]; then
            # TSV header
            printf 'REGION\tSTATUS\tAPI_REQUEST_ID\tAPP_REQUEST_ID\tPATIENT_ID_AES\tHOSP_ID\tPRSN_ID\tCLIENT_IP\tAPI_SERVER\tAPP_SERVER\tAPI_TIME\tAPP_TIME\tDELTA_SEC\tVERIFY_STATUS\n'
        fi

        for rid in "${REGION_IDS[@]}"; do
            if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]]; then
                continue
            fi
            correlate_region "$rid" "$date_list_file"
        done

        [[ "$OPT_FORMAT" == "text" ]] && fmt_footer
    } | if [[ -n "$OPT_OUTPUT" ]]; then tee "$OPT_OUTPUT"; else cat; fi

    if [[ -n "$OPT_OUTPUT" ]]; then
        log_info "Report written to: $OPT_OUTPUT"
    fi
}

main "$@"
