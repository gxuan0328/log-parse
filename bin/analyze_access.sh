#!/usr/bin/env bash
# bin/analyze_access.sh
# ----------------------------------------------------------------------------
# Cross-correlate API and APP access logs within each region.
#
# Domain flow:
#   HIS  --(authenticate)-->  API server  --issues URL-Token-->  Browser
#   Browser  --opens viewer with URL-Token-->  APP server  --verifies token-->  DICOM
#
# Correlation key:  API.ISSUE_TOKEN (CSV col 9)  ==  APP.TOKEN (CSV col 2)
#
# For each (region, date range) the analyser yields three categories:
#   NORMAL     -- APP saw a token previously issued by the same region's API.
#   ORPHAN     -- APP received a token with no matching API issuance.
#                  -> cross-region replay, crafted URL, or ingestion lag.
#   UNVERIFIED -- API issued a token that APP never received.
#                  -> user abandoned the session, or network failure.
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
OPT_MERGE=0

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Cross-correlate API and APP access logs within the same region (or merged
across all regions with --merge).  Identifies normal flows and abnormal accesses.

Options:
  --log-dir PATH     [required] root log directory
  --region REGION    taipei | taichung | all   (default: all)
  --days N           integer >= 1              (default: 7)   [ignored if --date/--from set]
  --from YYYY-MM-DD  start date, inclusive     [use together with --to]
  --to   YYYY-MM-DD  end date, inclusive       [use together with --from]
  --date YYYY-MM-DD  single day                [overrides --days/--from/--to]
  --merge            flag: merge all regions into one correlation pass
                     [requires --region all (default)]
  --format FMT       text | tsv | csv          (default: text)
  --output FILE      write report to FILE      (default: stdout)
  --conf FILE        regions config file       (default: conf/regions.conf)
  -v, --verbose      enable debug logging
  -h, --help         show this help

Common scenarios (runnable against the bundled dataset):

  # 1. Default: last 7 days, all regions, text report
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # 2. Single date, taipei region, text report
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --region taipei

  # 3. Week range, CSV output to file
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --format csv --output access_report.csv

  # 4. Host-agnostic merged view (tokens across regions correlate as NORMAL)
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --merge
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)    OPT_LOG_DIR="$2";  shift 2 ;;
            --days)       OPT_DAYS="$2";     shift 2 ;;
            --from)       OPT_FROM="$2";     shift 2 ;;
            --to)         OPT_TO="$2";       shift 2 ;;
            --date)       OPT_DATE="$2";     shift 2 ;;
            --region)     OPT_REGION="$2";   shift 2 ;;
            --output)     OPT_OUTPUT="$2";   shift 2 ;;
            --format)     OPT_FORMAT="$2";   shift 2 ;;
            --merge)      OPT_MERGE=1;       shift ;;
            --conf)       REGIONS_CONF="$2"; shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG;   shift ;;
            -h|--help)    usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$OPT_LOG_DIR" ]]; then
        die "--log-dir is required"
    fi
    if [[ ! -d "$OPT_LOG_DIR" ]]; then
        die "Log directory not found: $OPT_LOG_DIR"
    fi
    if [[ ! -f "$REGIONS_CONF" ]]; then
        die "Regions config not found: $REGIONS_CONF"
    fi
    assert_enum "--format" "$OPT_FORMAT" text tsv csv
    if [[ "$OPT_MERGE" -eq 1 && "$OPT_REGION" != "all" ]]; then
        die "--merge requires --region all (got: '$OPT_REGION')"
    fi
}

# ---------------------------------------------------------------------------
# Region loading
# ---------------------------------------------------------------------------

# load_regions -- sets REGION_IDS[], REGION_NAMES[], REGION_APIS[], REGION_APPS[]
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

# collect_access_csvs SERVER DATE_LIST_FILE -> prints file paths
collect_access_csvs() {
    local server="$1" date_list_file="$2"
    while IFS= read -r d; do
        local f="${OPT_LOG_DIR}/${server}/app/${d}/app-access-${d}.csv"
        if [[ -f "$f" ]]; then
            echo "$f"
        fi
    done < "$date_list_file"
}

# ---------------------------------------------------------------------------
# Core cross-correlation engine (gawk)
# ---------------------------------------------------------------------------

CORRELATE_AWK='
# ----------------------------------------------------------------------------
# Purpose : Correlate API issuances with APP verifications via a shared token.
# Input   : Two TAB-delimited intermediate files produced by csv_utils:
#
#   File 1 (api_tsv):
#     ISSUE_TOKEN | REQ_ID | PATIENT | HOSP | PRSN | CLIENT_IP | SERVER | API_TIME
#
#   File 2 (app_tsv):
#     TOKEN | REQ_ID | VERIFY | PATIENT | HOSP | PRSN | CLIENT_IP | SERVER | APP_TIME
#
# Vars    : api_file = path to api_tsv (used for FILENAME two-file join guard).
#
# Output  : One TAB-delimited line per record; 12 fields after STATUS column:
#
#   $1=STATUS  $2=API_TIME  $3=APP_TIME  $4=DELTA_SEC  $5=VERIFY_STATUS
#   $6=REQUEST_ID  $7=API_SERVER  $8=APP_SERVER
#   $9=HOSP_ID  $10=PRSN_ID  $11=CLIENT_IP  $12=PATIENT_ID_AES
#
#   NORMAL     -- correlated (API + APP seen)
#   ORPHAN     -- APP only (no API issuance on record)
#   UNVERIFIED -- API only (no APP verification received)
# ----------------------------------------------------------------------------

# ts_to_epoch -- convert "YYYY-MM-DD HH:MM:SS.mmm" to Unix epoch with ms.
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

# coalesce -- return a unless empty, else b. Used to fill in fields that the
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
        # NORMAL -- token was issued by the same regional API
        api_ts    = api_time[tok]
        epoch_api = ts_to_epoch(api_ts)
        epoch_app = ts_to_epoch(app_ts)
        delta = (epoch_api > 0 && epoch_app > 0) \
                ? sprintf("%.3f", epoch_app - epoch_api) : "N/A"
        print "NORMAL" "\t" api_ts "\t" app_ts "\t" delta "\t" verify "\t" \
              coalesce(api_req_id[tok], $2) "\t" api_server[tok] "\t" app_srv "\t" \
              hosp "\t" prsn "\t" client "\t" patient
        app_used[tok] = 1
    } else {
        # ORPHAN -- APP received a token with no API issuance on record
        print "ORPHAN" "\t" "-" "\t" app_ts "\t" "-" "\t" verify "\t" \
              $2 "\t" "-" "\t" app_srv "\t" hosp "\t" prsn "\t" client "\t" patient
    }
}

# End-of-input: every API token not consumed by an APP record is UNVERIFIED.
END {
    for (tok in api_time) {
        if (!(tok in app_used)) {
            print "UNVERIFIED" "\t" api_time[tok] "\t" "-" "\t" "-" "\t" "-" "\t" \
                  api_req_id[tok] "\t" api_server[tok] "\t" "-" "\t" \
                  api_hosp[tok] "\t" api_prsn[tok] "\t" api_client_ip[tok] "\t" api_patient[tok]
        }
    }
}
'

# ---------------------------------------------------------------------------
# Sort pre-pass (runs once after CORRELATE_AWK; feeds all renderers)
# ---------------------------------------------------------------------------

SORT_RECORDS_AWK='
# sort_records -- deterministic ASC sort pre-pass for result_tsv.
# Primary key  : STATUS (lexical: NORMAL < ORPHAN < UNVERIFIED).
# Secondary    : category-appropriate time (API_TIME for NORMAL/UNVERIFIED;
#                APP_TIME for ORPHAN -- "API_TIME; when absent, APP_TIME").
# Tertiary     : REQUEST_ID.
# Quaternary   : full line (stable tie-break neutralising hash iteration).
{ t = ($1 == "ORPHAN") ? $3 : $2
  key = $1 SUBSEP t SUBSEP $6 SUBSEP $0
  buf[key] = $0 }
END { n = asorti(buf, idx, "@ind_str_asc"); for (i = 1; i <= n; i++) print buf[idx[i]] }
'

# ---------------------------------------------------------------------------
# Internal: run correlator + sort pre-pass
# ---------------------------------------------------------------------------

# _run_correlate API_TSV APP_TSV RESULT_TSV RESULT_SORTED
#   Purpose : Invoke CORRELATE_AWK then the sort pre-pass; produce two outputs.
#   Args    : API_TSV       -- API extract file.
#             APP_TSV       -- APP extract file.
#             RESULT_TSV    -- destination for raw correlation output.
#             RESULT_SORTED -- destination for sorted correlation output.
#   Output  : nothing on stdout; files written under WORK_TMPDIR.
_run_correlate() {
    local api_tsv="$1" app_tsv="$2" result_tsv="$3" result_sorted="$4"
    gawk -F'\t' -v OFS='\t' -v api_file="$api_tsv" "$CORRELATE_AWK" \
        "$api_tsv" "$app_tsv" > "$result_tsv"
    gawk -F'\t' "$SORT_RECORDS_AWK" "$result_tsv" > "$result_sorted"
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

# render_tsv REGION_NAME RESULT_SORTED
#   Purpose : Emit TAB-delimited rows with REGION column prepended.
#   Args    : REGION_NAME   -- value for the REGION column.
#             RESULT_SORTED -- sorted correlation output.
#   Output  : TSV data rows on stdout (header emitted once by main).
render_tsv() {
    local region_name="$1" result_sorted="$2"
    gawk -F'\t' -v region="$region_name" \
        '{ print region "\t" $0 }' "$result_sorted"
}

# render_csv REGION_NAME RESULT_SORTED
#   Purpose : Emit RFC-4180 CSV rows with REGION column prepended.
#   Args    : REGION_NAME   -- value for the REGION column.
#             RESULT_SORTED -- sorted correlation output.
#   Output  : CSV data rows on stdout (header emitted once by main).
#   Notes   : Fields are quoted conditionally: only when the value contains
#             a double-quote, comma, or newline.
render_csv() {
    local region_name="$1" result_sorted="$2"
    gawk -F'\t' -v region="$region_name" '
        function q(s) {
            if (s ~ /[",\n]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
            return s
        }
        { out = q(region); for (i = 1; i <= NF; i++) out = out "," q($i); print out }
    ' "$result_sorted"
}

# render_text_block REGION_LABEL RESULT_SORTED
#   Purpose : Emit the full text-format analysis block for one correlation corpus.
#   Args    : REGION_LABEL  -- label for the fmt_h2 section header.
#             RESULT_SORTED -- sorted 12-field correlation output.
#   Output  : Human-readable text on stdout; progress on stderr.
render_text_block() {
    local region_label="$1" result_sorted="$2"

    fmt_h2 "$region_label"

    # Summary stats
    local n_normal n_orphan n_unverified
    n_normal=$(     gawk -F'\t' '$1=="NORMAL"     {c++} END{print c+0}' "$result_sorted")
    n_orphan=$(     gawk -F'\t' '$1=="ORPHAN"     {c++} END{print c+0}' "$result_sorted")
    n_unverified=$( gawk -F'\t' '$1=="UNVERIFIED" {c++} END{print c+0}' "$result_sorted")
    local total=$(( n_normal + n_orphan + n_unverified ))

    fmt_kv "Total correlation records"       "$total"
    fmt_kv_color "  NORMAL  (正常流程)"           "$n_normal"     "$C_GREEN"
    fmt_kv_color "  ORPHAN  (APP無對應API)"        "$n_orphan"     "$C_YELLOW"
    fmt_kv_color "  UNVERIFIED (API未被使用)"      "$n_unverified" "$C_GREY"

    # Schema (result_sorted):
    #   $1=STATUS  $2=API_TIME  $3=APP_TIME  $4=DELTA_SEC  $5=VERIFY_STATUS
    #   $6=REQUEST_ID  $7=API_SERVER  $8=APP_SERVER
    #   $9=HOSP_ID  $10=PRSN_ID  $11=CLIENT_IP  $12=PATIENT_ID_AES

    # ── NORMAL records ──────────────────────────────────────────────────────
    if (( n_normal > 0 )); then
        fmt_h3 "正常流程 (NORMAL) — API 簽發後由 APP 驗證"
        gawk -F'\t' -v C_GREY="$C_GREY" -v C_RESET="$C_RESET" '
            BEGIN {
                printf "    " C_GREY "%-23s  %-23s  %-8s  %-7s  %-13s  %-15s  %-15s  %-12s  %-12s  %-16s  %s" C_RESET "\n",
                    "API_TIME", "APP_TIME", "DELTA", "VERIFY", "REQUEST_ID",
                    "API_SRV", "APP_SRV", "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES"
            }
            $1 != "NORMAL" { next }
            {
                delta_str = ($4 == "N/A" || $4 == "-") ? "N/A" \
                            : sprintf("%.1fs", ($4 < 0 ? 0 : $4))
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-23s  %-8s  %-7s  %-13s  %-15s  %-15s  %-12s  %-12s  %-16s  %s\n",
                    $2, $3, delta_str, $5, $6, $7, $8, hosp, prsn, client, $12
            }
        ' "$result_sorted"

        # Delta statistics sub-block (separate pass; DELTA=$4, VERIFY=$5)
        echo ""
        LC_ALL=C gawk -F'\t' "$FMT_AWK_WIDTH"'
            $1 == "NORMAL" && $4 != "N/A" && $4 != "-" {
                d = $4 + 0
                if (d >= 0) {
                    sum += d; count++
                    if (min == "" || d < min) min = d
                    if (d > max) max = d
                }
            }
            END {
                if (count > 0) {
                    printf "    %s%d\n",    rpad("驗證筆數 (有效時間差)", 40), count
                    printf "    %s%.1fs\n", rpad("平均 API→APP 時間差",   40), sum/count
                    printf "    %s%.1fs\n", rpad("最短時間差",             40), min
                    printf "    %s%.1fs\n", rpad("最長時間差",             40), max
                }
            }
        ' "$result_sorted"
    fi

    # ── ORPHAN records ──────────────────────────────────────────────────────
    if (( n_orphan > 0 )); then
        echo ""
        fmt_h3 "非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token"
        gawk -F'\t' -v C_GREY="$C_GREY" -v C_RESET="$C_RESET" '
            BEGIN {
                printf "    " C_GREY "%-23s  %-7s  %-13s  %-15s  %-12s  %-12s  %-16s  %s" C_RESET "\n",
                    "APP_TIME", "VERIFY", "REQUEST_ID", "APP_SRV",
                    "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES"
            }
            $1 != "ORPHAN" { next }
            {
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-7s  %-13s  %-15s  %-12s  %-12s  %-16s  %s\n",
                    $3, $5, $6, $8, hosp, prsn, client, $12
            }
        ' "$result_sorted"

        # Verify summary sub-block (separate pass; VERIFY=$5)
        LC_ALL=C gawk -F'\t' "$FMT_AWK_WIDTH"'
            $1 == "ORPHAN" {
                if ($5 == "OK") ok++
                else            fail++
            }
            END {
                printf "\n    %s%d (成功) / %d (失敗)\n", rpad("ORPHAN 驗證結果", 40), ok+0, fail+0
                if (ok > 0)   printf "    >> [WARN] 存在可能來自其他區域或重播的有效 Token\n"
                if (fail > 0) printf "    >> [NOTE] 存在無效/過期 Token 的存取嘗試\n"
            }
        ' "$result_sorted"
    fi

    # ── UNVERIFIED records ──────────────────────────────────────────────────
    if (( n_unverified > 0 )); then
        echo ""
        fmt_h3 "未被驗證 (UNVERIFIED) — API 簽發但 APP 從未收到驗證請求"
        gawk -F'\t' -v C_GREY="$C_GREY" -v C_RESET="$C_RESET" '
            BEGIN {
                printf "    " C_GREY "%-23s  %-13s  %-15s  %-12s  %-12s  %-16s  %s" C_RESET "\n",
                    "API_TIME", "REQUEST_ID", "API_SRV",
                    "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES"
            }
            $1 != "UNVERIFIED" { next }
            {
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-13s  %-15s  %-12s  %-12s  %-16s  %s\n",
                    $2, $6, $7, hosp, prsn, client, $12
            }
        ' "$result_sorted"
    fi
}

# ---------------------------------------------------------------------------
# Run correlation for a single region
# ---------------------------------------------------------------------------

# correlate_region REGION_ID DATE_LIST_FILE
#   Purpose : Run the full extract -> join -> sort -> render pipeline for one region.
#   Steps   : (1) Collect API records across every configured API server.
#             (2) Collect APP records across every configured APP server.
#             (3) Invoke CORRELATE_AWK with both intermediates.
#             (4) Run sort pre-pass (once; feeds all renderers).
#             (5) Dispatch to renderer (text, tsv, or csv).
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
    log_info "Region [${REGION_NAMES[$region_id]}] -- API records: $api_count, APP records: $app_count"

    if (( api_count == 0 && app_count == 0 )); then
        log_warn "  No access CSV data found for this period."
        return
    fi
    if (( api_count == 0 )); then
        log_info "  No API records found; all APP accesses will be ORPHAN."
    fi
    if (( app_count == 0 )); then
        log_info "  No APP records found; all API issuances will be UNVERIFIED."
    fi

    # Correlate + sort pre-pass (once; all renderers consume result_sorted)
    local result_tsv="${WORK_TMPDIR}/result_${region_id}.tsv"
    local result_sorted="${WORK_TMPDIR}/sorted_${region_id}.tsv"
    _run_correlate "$api_tsv" "$app_tsv" "$result_tsv" "$result_sorted"

    # Dispatch to renderer
    local rname="${REGION_NAMES[$region_id]}"
    case "$OPT_FORMAT" in
        tsv) render_tsv "$rname" "$result_sorted" ;;
        csv) render_csv "$rname" "$result_sorted" ;;
        *)
            local label="Region: ${rname}  (${REGION_APIS[$region_id]} → ${REGION_APPS[$region_id]})"
            render_text_block "$label" "$result_sorted"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Run correlation merged across all regions
# ---------------------------------------------------------------------------

# correlate_merged DATE_LIST_FILE
#   Purpose : Concatenate all regions' API and APP extracts, run CORRELATE_AWK
#             once (host-agnostic), apply the sort pre-pass, and render one block.
#   Args    : DATE_LIST_FILE -- file listing YYYY-MM-DD dates (one per line).
#   Output  : Single merged block on stdout.
#   Notes   : Cross-region token pairs that cannot be correlated per-region
#             (an API issuance in region X verified by region Y's APP) will
#             classify as NORMAL in the merged pass (intended semantic).
#             REGION column = "merged" in tsv/csv outputs.
correlate_merged() {
    local date_list_file="$1"

    local api_tsv="${WORK_TMPDIR}/api_merged.tsv"
    local app_tsv="${WORK_TMPDIR}/app_merged.tsv"
    : > "$api_tsv"
    : > "$app_tsv"

    local rid srv
    for rid in "${REGION_IDS[@]}"; do
        local api_servers app_servers
        IFS=',' read -ra api_servers <<< "${REGION_APIS[$rid]}"
        IFS=',' read -ra app_servers <<< "${REGION_APPS[$rid]}"

        for srv in "${api_servers[@]}"; do
            while IFS= read -r csv_file; do
                log_debug "  Merged API CSV: $csv_file"
                extract_api_records "$csv_file" >> "$api_tsv"
            done < <(collect_access_csvs "$srv" "$date_list_file")
        done

        for srv in "${app_servers[@]}"; do
            while IFS= read -r csv_file; do
                log_debug "  Merged APP CSV: $csv_file"
                extract_app_records "$csv_file" >> "$app_tsv"
            done < <(collect_access_csvs "$srv" "$date_list_file")
        done
    done

    local api_count app_count
    api_count=$(count_lines "$api_tsv")
    app_count=$(count_lines "$app_tsv")
    log_info "Merged -- API records: $api_count, APP records: $app_count"

    if (( api_count == 0 && app_count == 0 )); then
        log_warn "  No access CSV data found for this period (merged)."
        return
    fi

    # Correlate + sort pre-pass
    local result_tsv="${WORK_TMPDIR}/result_merged.tsv"
    local result_sorted="${WORK_TMPDIR}/sorted_merged.tsv"
    _run_correlate "$api_tsv" "$app_tsv" "$result_tsv" "$result_sorted"

    # Dispatch to renderer
    case "$OPT_FORMAT" in
        tsv) render_tsv "merged" "$result_sorted" ;;
        csv) render_csv "merged" "$result_sorted" ;;
        *)   render_text_block "Region: all (merged)" "$result_sorted" ;;
    esac
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

    local date_start date_end n_dates
    date_start=$(head -1 "$date_list_file")
    date_end=$(tail -1 "$date_list_file")
    n_dates=$(count_lines "$date_list_file")

    log_info "Period: $date_start → $date_end ($n_dates days)"
    log_info "Region: $OPT_REGION"

    {
        if [[ "$OPT_FORMAT" == "text" ]]; then
            fmt_h1 "Access Log Cross-Correlation Report"
            fmt_kv "Period" "${date_start}  →  ${date_end}  (${n_dates} days)"
            fmt_kv "Region filter" "$OPT_REGION"
        elif [[ "$OPT_FORMAT" == "tsv" ]]; then
            printf 'REGION\tSTATUS\tAPI_TIME\tAPP_TIME\tDELTA_SEC\tVERIFY_STATUS\tREQUEST_ID\tAPI_SERVER\tAPP_SERVER\tHOSP_ID\tPRSN_ID\tCLIENT_IP\tPATIENT_ID_AES\n'
        elif [[ "$OPT_FORMAT" == "csv" ]]; then
            printf 'REGION,STATUS,API_TIME,APP_TIME,DELTA_SEC,VERIFY_STATUS,REQUEST_ID,API_SERVER,APP_SERVER,HOSP_ID,PRSN_ID,CLIENT_IP,PATIENT_ID_AES\n'
        fi

        if (( OPT_MERGE )); then
            correlate_merged "$date_list_file"
        elif [[ "$OPT_REGION" == "all" ]]; then
            for rid in "${REGION_IDS[@]}"; do
                correlate_region "$rid" "$date_list_file"
            done
        else
            for rid in "${REGION_IDS[@]}"; do
                if [[ "$OPT_REGION" == "$rid" ]]; then
                    correlate_region "$rid" "$date_list_file"
                fi
            done
        fi

        if [[ "$OPT_FORMAT" == "text" ]]; then
            fmt_footer
        fi
    } | if [[ -n "$OPT_OUTPUT" ]]; then tee "$OPT_OUTPUT"; else cat; fi

    if [[ -n "$OPT_OUTPUT" ]]; then
        log_info "Report written to: $OPT_OUTPUT"
    fi
}

main "$@"
