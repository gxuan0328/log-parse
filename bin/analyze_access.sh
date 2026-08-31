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
# Views: --view detail (default) = per-record tables; --view summary = KPI text.
# Formats: --format text (default) | tsv | csv (governs detail file/view; C10).
# Persistence: always-on via output_utils (persist_init + persist_views).
#   Real runs write THREE files: access_summary.txt, access_detail.<ext>, and
#   access_ip_counts.tsv (CLIENT_IP request counts sorted by count desc / IP asc).
#   access_ip_counts.tsv is a machine-readable side artifact, never written to stdout.
# Emit-stats: --emit-stats prints access_stats.tsv verbatim; short-circuits before
#   persist_init (no files, no banner). Accepts interval/region/conf/verbose only.
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
# shellcheck source=../lib/aggregate_utils.sh
source "${SCRIPT_DIR}/../lib/aggregate_utils.sh"
# shellcheck source=../lib/output_utils.sh
source "${SCRIPT_DIR}/../lib/output_utils.sh"

REGIONS_CONF="${SCRIPT_DIR}/../conf/regions.conf"
TEST_HOSTS_CONF="${LOG_PARSE_TEST_HOSTS_CONF:-${SCRIPT_DIR}/../conf/test_hosts.conf}"
OPT_TEST_HOSTS="exclude"
TEST_HOST_SET=""

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT_DIR=""    # always-on persistence directory (C1: default empty)
OPT_TODAY=0
OPT_DAYS_SET=0
OPT_FORMAT="text"
OPT_VIEW="detail"    # detail (default, standalone) | summary
OPT_MERGE=0
OPT_EMIT_STATS=0

# ---------------------------------------------------------------------------
# Renderer context globals (set in main, read by access_render_* functions)
# ---------------------------------------------------------------------------
_ACC_DATE_START=""
_ACC_DATE_END=""
_ACC_N_DATES=0
_ACC_REGION="all"

# Corpus tracking arrays (populated by correlate_region / correlate_merged)
declare -a _ACC_LABELS=()   # text labels for fmt_h2 headers in render_text_block
declare -a _ACC_SORTED=()   # result_sorted file paths
declare -a _ACC_RNAMES=()   # region names for tsv/csv REGION column

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
  --today            alias for --date \$(today); sets single-day window
  --days N           integer >= 1              (default: 7)   [implicit fallback]
  --from YYYY-MM-DD  start date, inclusive     [use together with --to]
  --to   YYYY-MM-DD  end date, inclusive       [use together with --from]
  --date YYYY-MM-DD  single day
  --view V           summary | detail          (default: detail)
  --format FMT       text | tsv | csv          (default: text)
  --merge            flag: merge all regions into one correlation pass
                     [requires --region all (default)]
  --emit-stats       print access_stats.tsv to stdout; no persistence, no banner
                     Accepts: interval/region/conf/verbose subset only (C2).
  --output-dir DIR   persistence dir           (default: env > ./log-parse)
  --conf FILE        regions config file       (default: conf/regions.conf)
  -v, --verbose      enable debug logging
  -h, --help         show this help

Interval flags are mutually exclusive: choose ONE of
  --today | --date | --from/--to | --days (explicit)
  If multiple are supplied the script aborts (fail-fast per project rule #1).

Common scenarios (runnable against the bundled dataset):

  # 1. Default: last 7 days, all regions, text report
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

  # 2. Single date, taipei region, management summary
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21 --region taipei --view summary

  # 3. Week range, CSV detail output
  bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --format csv --view detail

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
            --log-dir)    OPT_LOG_DIR="$2";               shift 2 ;;
            --days)       OPT_DAYS="$2"; OPT_DAYS_SET=1;  shift 2 ;;
            --from)       OPT_FROM="$2";                   shift 2 ;;
            --to)         OPT_TO="$2";                     shift 2 ;;
            --date)       OPT_DATE="$2";                   shift 2 ;;
            --today)      OPT_TODAY=1;                     shift ;;
            --region)     OPT_REGION="$2";                 shift 2 ;;
            --output-dir) OPT_OUTPUT_DIR="$2";             shift 2 ;;
            --view)       OPT_VIEW="$2";                   shift 2 ;;
            --format)     OPT_FORMAT="$2";                 shift 2 ;;
            --emit-stats) OPT_EMIT_STATS=1;               shift ;;
            --merge)      OPT_MERGE=1;                     shift ;;
            --test-hosts) OPT_TEST_HOSTS="$2";             shift 2 ;;
            --conf)       REGIONS_CONF="$2";               shift 2 ;;
            -v|--verbose) LOG_LEVEL=DEBUG;                 shift ;;
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
    assert_enum "--format"     "$OPT_FORMAT"     text tsv csv
    assert_enum "--view"       "$OPT_VIEW"       summary detail
    assert_enum "--test-hosts" "$OPT_TEST_HOSTS" exclude only all
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
# Output  : One TAB-delimited line per record; 13 fields after STATUS column:
#
#   $1=STATUS  $2=API_TIME  $3=APP_TIME  $4=DELTA_SEC  $5=VERIFY_STATUS
#   $6=REQUEST_ID  $7=API_SERVER  $8=APP_SERVER
#   $9=HOSP_ID  $10=PRSN_ID  $11=CLIENT_IP  $12=PATIENT_ID_AES  $13=BIRTHDAY
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
    dob      = jwt_dob(tok)

    if (tok in api_time) {
        # NORMAL -- token was issued by the same regional API
        api_ts    = api_time[tok]
        epoch_api = ts_to_epoch(api_ts)
        epoch_app = ts_to_epoch(app_ts)
        delta = (epoch_api > 0 && epoch_app > 0) \
                ? sprintf("%.3f", epoch_app - epoch_api) : "N/A"
        print "NORMAL" "\t" api_ts "\t" app_ts "\t" delta "\t" verify "\t" \
              coalesce(api_req_id[tok], $2) "\t" api_server[tok] "\t" app_srv "\t" \
              hosp "\t" prsn "\t" client "\t" patient "\t" dob
        app_used[tok] = 1
    } else {
        # ORPHAN -- APP received a token with no API issuance on record
        print "ORPHAN" "\t" "-" "\t" app_ts "\t" "-" "\t" verify "\t" \
              $2 "\t" "-" "\t" app_srv "\t" hosp "\t" prsn "\t" client "\t" patient "\t" dob
    }
}

# End-of-input: every API token not consumed by an APP record is UNVERIFIED.
END {
    for (tok in api_time) {
        if (!(tok in app_used)) {
            print "UNVERIFIED" "\t" api_time[tok] "\t" "-" "\t" "-" "\t" "-" "\t" \
                  api_req_id[tok] "\t" api_server[tok] "\t" "-" "\t" \
                  api_hosp[tok] "\t" api_prsn[tok] "\t" api_client_ip[tok] "\t" api_patient[tok] "\t" jwt_dob(tok)
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
#   Returns / Side effects : none.
#   Errors / Notes : none; empty inputs produce empty outputs cleanly.
_run_correlate() {
    local api_tsv="$1" app_tsv="$2" result_tsv="$3" result_sorted="$4"
    LC_ALL=C gawk -F'\t' -v OFS='\t' -v api_file="$api_tsv" \
        "$JWT_DOB_FUNC$CORRELATE_AWK" "$api_tsv" "$app_tsv" > "$result_tsv"
    gawk -F'\t' "$SORT_RECORDS_AWK" "$result_tsv" > "$result_sorted"
}

# ---------------------------------------------------------------------------
# Renderers (detail view; called by access_render_detail)
# ---------------------------------------------------------------------------

# render_tsv REGION_NAME RESULT_SORTED
#   Purpose : Emit TAB-delimited rows with REGION column prepended.
#   Args    : REGION_NAME   -- value for the REGION column.
#             RESULT_SORTED -- sorted correlation output.
#   Output  : TSV data rows on stdout (header emitted once by access_render_detail).
#   Returns / Side effects : none.
#   Errors / Notes : none; empty RESULT_SORTED produces no rows.
render_tsv() {
    local region_name="$1" result_sorted="$2"
    gawk -F'\t' -v region="$region_name" \
        '{ print region "\t" $0 }' "$result_sorted"
}

# render_csv REGION_NAME RESULT_SORTED
#   Purpose : Emit RFC-4180 CSV rows with REGION column prepended.
#   Args    : REGION_NAME   -- value for the REGION column.
#             RESULT_SORTED -- sorted correlation output.
#   Output  : CSV data rows on stdout (header emitted once by access_render_detail).
#   Returns / Side effects : none.
#   Errors / Notes : Uses AGG_CSV_FUNC (q()) from aggregate_utils — single source C7.
render_csv() {
    local region_name="$1" result_sorted="$2"
    gawk -F'\t' -v region="$region_name" \
        "$AGG_CSV_FUNC"'{ out = q(region); for (i = 1; i <= NF; i++) out = out "," q($i); print out }' \
        "$result_sorted"
}

# render_text_block REGION_LABEL RESULT_SORTED
#   Purpose : Emit the full text-format analysis block for one correlation corpus.
#   Args    : REGION_LABEL  -- label for the fmt_h2 section header.
#             RESULT_SORTED -- sorted 13-field correlation output.
#   Output  : Human-readable text on stdout; progress on stderr.
#   Returns / Side effects : none.
#   Errors / Notes : C_GREY/C_RESET passed via -v; blanked by fmt_set_color_state
#             under NO_COLOR=1 so persisted files contain no ANSI (C3/I08).
render_text_block() {
    local region_label="$1" result_sorted="$2"

    fmt_h2 "$region_label"

    # Summary stats (three passes; counts backed by access_stats.tsv in summary view;
    # detail text re-reads result_sorted directly to stay output-identical — A baselines).
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
    #   $9=HOSP_ID  $10=PRSN_ID  $11=CLIENT_IP  $12=PATIENT_ID_AES  $13=BIRTHDAY

    # ── NORMAL records ──────────────────────────────────────────────────────
    if (( n_normal > 0 )); then
        fmt_h3 "正常流程 (NORMAL) — API 簽發後由 APP 驗證"
        gawk -F'\t' -v C_GREY="$C_GREY" -v C_RESET="$C_RESET" '
            BEGIN {
                printf "    " C_GREY "%-23s  %-23s  %-8s  %-7s  %-13s  %-15s  %-15s  %-12s  %-12s  %-16s  %-32s  %s" C_RESET "\n",
                    "API_TIME", "APP_TIME", "DELTA", "VERIFY", "REQUEST_ID",
                    "API_SRV", "APP_SRV", "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES", "BIRTHDAY"
            }
            $1 != "NORMAL" { next }
            {
                delta_str = ($4 == "N/A" || $4 == "-") ? "N/A" \
                            : sprintf("%.1fs", ($4 < 0 ? 0 : $4))
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-23s  %-8s  %-7s  %-13s  %-15s  %-15s  %-12s  %-12s  %-16s  %-32s  %s\n",
                    $2, $3, delta_str, $5, $6, $7, $8, hosp, prsn, client, $12, $13
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
                    printf "    %s%d\n",    rpad("驗證筆數", 40), count
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
                printf "    " C_GREY "%-23s  %-7s  %-13s  %-15s  %-12s  %-12s  %-16s  %-32s  %s" C_RESET "\n",
                    "APP_TIME", "VERIFY", "REQUEST_ID", "APP_SRV",
                    "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES", "BIRTHDAY"
            }
            $1 != "ORPHAN" { next }
            {
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-7s  %-13s  %-15s  %-12s  %-12s  %-16s  %-32s  %s\n",
                    $3, $5, $6, $8, hosp, prsn, client, $12, $13
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
                printf "    " C_GREY "%-23s  %-13s  %-15s  %-12s  %-12s  %-16s  %-32s  %s" C_RESET "\n",
                    "API_TIME", "REQUEST_ID", "API_SRV",
                    "HOSP_ID", "PRSN_ID", "CLIENT_IP", "PATIENT_ID_AES", "BIRTHDAY"
            }
            $1 != "UNVERIFIED" { next }
            {
                hosp   = ($9  != "" && $9  != "-") ? $9  : "-"
                prsn   = ($10 != "" && $10 != "-") ? $10 : "-"
                client = ($11 != "" && $11 != "-") ? $11 : "-"
                printf "    %-23s  %-13s  %-15s  %-12s  %-12s  %-16s  %-32s  %s\n",
                    $2, $6, $7, hosp, prsn, client, $12, $13
            }
        ' "$result_sorted"
    fi
}

# ---------------------------------------------------------------------------
# access_region_stats — aggregate correlation results into access_stats.tsv
# ---------------------------------------------------------------------------

# access_region_stats REGION RESULT_SORTED
#   Purpose : Run agg_access_rows once on RESULT_SORTED and append the
#             dimensioned rows (ACCESS<TAB>REGION<TAB>TAG<TAB>value) to
#             ${WORK_TMPDIR}/access_stats.tsv. Called once per corpus after
#             correlation + sort pre-pass complete. No second correlation.
#   Args    : REGION        -- region id (or "merged") for the stats prefix.
#             RESULT_SORTED -- path to the sorted 13-field correlation TSV.
#   Output  : nothing on stdout; appends to ${WORK_TMPDIR}/access_stats.tsv.
#   Returns / Side effects : appends to access_stats.tsv.
#   Errors / Notes : agg_access_rows handles empty RESULT_SORTED gracefully.
access_region_stats() {
    local region="$1" result_sorted="$2"
    agg_access_rows "$result_sorted" \
        | gawk -F'\t' -v region="$region" \
          'BEGIN{OFS="\t"} {print "ACCESS", region, $1, $2}' \
        >> "${WORK_TMPDIR}/access_stats.tsv"
    agg_access_records "$result_sorted" \
        | gawk -F'\t' -v region="$region" \
          'BEGIN{OFS="\t"} $1=="HOUR"{print "HOUR", region, $2, $3}' \
        >> "${WORK_TMPDIR}/access_stats.tsv"
}

# ---------------------------------------------------------------------------
# access_write_ip_counts — write per-IP request counts to access_ip_counts.tsv
# ---------------------------------------------------------------------------

# access_write_ip_counts
#   Purpose : Aggregate CLIENT_IP request counts (predicate: NORMAL|ORPHAN) from
#             all post-correlation result_sorted files and write to
#             ${RUN_OUTPUT_DIR}/access_ip_counts.tsv (machine-readable side
#             artifact; never written to stdout).  Header is always written;
#             data rows are written only when _ACC_SORTED is non-empty.
#             Sort order: REQUEST_COUNT descending, then CLIENT_IP ascending.
#             Coalesced IP key: empty or "-" -> sentinel "-" (surfaces the real
#             upstream logging gap rather than silently dropping the record).
#   Args    : none (reads global _ACC_SORTED array and OPT_OUTPUT_DIR context).
#   Output  : nothing on stdout; writes ${RUN_OUTPUT_DIR}/access_ip_counts.tsv.
#   Returns / Side effects : writes one file; logs its path via log_info.
#   Errors / Notes : persist_init must be called before this function.
#             Always TSV (machine record), independent of --format.
#             Empty corpus (_ACC_SORTED empty) -> header-only file (1 line, 0 data rows).
#             Covers region/all/merge automatically (reads _ACC_SORTED, already
#             test-host filtered; no separate per-region run needed).
access_write_ip_counts() {
    local outfile
    outfile="$(persist_path access ip_counts tsv)"
    printf 'CLIENT_IP\tREQUEST_COUNT\n' > "$outfile"
    if (( ${#_ACC_SORTED[@]} > 0 )); then
        agg_access_records "${_ACC_SORTED[@]}" \
            | gawk -F'\t' '$1=="IP"{print $2"\t"$3}' \
            | sort -t$'\t' -k2,2nr -k1,1 \
            >> "$outfile"
    fi
    log_info "Persisted IP counts: $outfile"
}

# ---------------------------------------------------------------------------
# access_render_summary — management summary view (format-independent, always text)
# ---------------------------------------------------------------------------

# access_render_summary
#   Purpose : Aggregate stats across all corpora in access_stats.tsv and render
#             a concise management-level summary: KPIs + percentages + ORPHAN
#             verification result + delta timing + per-region breakdown.
#             Format-independent (always text) per C10.
#   Args    : none (uses globals: _ACC_DATE_*, _ACC_REGION, OPT_MERGE,
#             REGION_IDS, REGION_NAMES, WORK_TMPDIR).
#   Output  : summary block on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : gracefully handles empty stats (all zeros/N/A).
access_render_summary() {
    local stats_file="${WORK_TMPDIR}/access_stats.tsv"

    printf "%b============ Access Cross-Correlation Summary ============%b\n" \
        "$C_BOLD" "$C_RESET"
    fmt_kv "Period" "${_ACC_DATE_START}  →  ${_ACC_DATE_END}  (${_ACC_N_DATES} days)"
    fmt_kv "Region filter" "$_ACC_REGION"

    # Single-pass aggregation: totals + per-region arrays + delta min/max
    local agg_out
    agg_out=$(LC_ALL=C gawk -F'\t' '
        $1=="ACCESS" {
            r = $2; tag = $3; val = $4+0
            if (tag == "NORMAL")      { norm[r]  = val; tot_normal   += val }
            if (tag == "ORPHAN")      { orph[r]  = val; tot_orphan   += val }
            if (tag == "UNVERIFIED")  { unvr[r]  = val; tot_unver    += val }
            if (tag == "ORPHAN_OK")   tot_ok     += val
            if (tag == "ORPHAN_FAIL") tot_fail   += val
            if (tag == "DELTA_COUNT") { dc[r]    = val; tot_dc       += val }
            if (tag == "DELTA_SUM")   { ds[r]    = val; tot_ds       += val }
            if (tag == "DELTA_MIN")   dm[r]      = val
            if (tag == "DELTA_MAX")   dmx[r]     = val
        }
        END {
            total = tot_normal + tot_orphan + tot_unver
            gmin = ""; gmx = 0
            for (r in dc) {
                if (dc[r] > 0) {
                    if (gmin == "" || dm[r] < gmin) gmin = dm[r]
                    if (dmx[r] > gmx) gmx = dmx[r]
                }
            }
            printf "TOTAL\t%d\n",      total
            printf "NORMAL\t%d\n",     tot_normal
            printf "ORPHAN\t%d\n",     tot_orphan
            printf "UNVERIFIED\t%d\n", tot_unver
            printf "ORPHAN_OK\t%d\n",  tot_ok
            printf "ORPHAN_FAIL\t%d\n",tot_fail
            printf "DELTA_COUNT\t%d\n",tot_dc
            printf "DELTA_SUM\t%g\n",  tot_ds
            printf "DELTA_MIN\t%g\n",  (gmin == "" ? 0 : gmin+0)
            printf "DELTA_MAX\t%g\n",  gmx+0
            # Per-region lines: REGION <TAB> region_id <TAB> normal <TAB> orphan <TAB> unver
            n = asorti(norm, rkeys, "@ind_str_asc")
            for (i = 1; i <= n; i++) {
                rk = rkeys[i]
                printf "REGION\t%s\t%d\t%d\t%d\n", rk, norm[rk]+0, orph[rk]+0, unvr[rk]+0
            }
        }
    ' "$stats_file")

    local total normal orphan unverified orphan_ok orphan_fail
    local delta_count delta_sum delta_min delta_max
    total=$(       printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="TOTAL"      {print $2}')
    normal=$(      printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="NORMAL"     {print $2}')
    orphan=$(      printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ORPHAN"     {print $2}')
    unverified=$(  printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="UNVERIFIED" {print $2}')
    orphan_ok=$(   printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ORPHAN_OK"  {print $2}')
    orphan_fail=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ORPHAN_FAIL"{print $2}')
    delta_count=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="DELTA_COUNT"{print $2}')
    delta_sum=$(   printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="DELTA_SUM"  {print $2}')
    delta_min=$(   printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="DELTA_MIN"  {print $2}')
    delta_max=$(   printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="DELTA_MAX"  {print $2}')

    local pct_normal pct_orphan pct_unverified
    pct_normal=$(     fmt_pct "${normal:-0}"     "${total:-0}")
    pct_orphan=$(     fmt_pct "${orphan:-0}"     "${total:-0}")
    pct_unverified=$( fmt_pct "${unverified:-0}" "${total:-0}")

    fmt_kv "關聯總數" "${total:-0}"
    fmt_kv_color "  NORMAL  (正常流程)"        "${normal:-0}  (${pct_normal})"        "$C_GREEN"
    fmt_kv_color "  ORPHAN  (APP無對應API)"    "${orphan:-0}  (${pct_orphan})"        "$C_YELLOW"
    fmt_kv_color "  UNVERIFIED (API未被使用)"  "${unverified:-0}  (${pct_unverified})" "$C_GREY"
    fmt_kv "ORPHAN 驗證結果" "${orphan_ok:-0} (成功) / ${orphan_fail:-0} (失敗)"

    if (( ${delta_count:-0} > 0 )); then
        local avg_delta
        avg_delta=$(gawk -v s="${delta_sum:-0}" -v c="${delta_count:-1}" \
                    'BEGIN{printf "%.1f", (c>0 ? s/c : 0)}')
        fmt_kv "延遲 API→APP" "平均 ${avg_delta}s · 最短 ${delta_min:-0}s · 最長 ${delta_max:-0}s"
    fi

    # Per-region breakdown (not for merged runs — merged has no individual region rows)
    if [[ "$OPT_MERGE" -eq 0 ]]; then
        local has_multi=0
        local rid
        for rid in "${REGION_IDS[@]}"; do
            if [[ "$OPT_REGION" == "all" || "$OPT_REGION" == "$rid" ]]; then
                has_multi=$((has_multi + 1))
            fi
        done
        if (( has_multi > 1 )); then
            fmt_h3 "分區別 (% within region)"
            for rid in "${REGION_IDS[@]}"; do
                if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$rid" ]]; then continue; fi
                local rname="${REGION_NAMES[$rid]}"
                local r_line r_normal r_orphan r_unver r_total
                r_line=$(printf '%s\n' "$agg_out" | gawk -F'\t' -v r="$rid" \
                    '$1=="REGION" && $2==r {print $3, $4, $5; exit}')
                if [[ -z "$r_line" ]]; then continue; fi
                r_normal=$(  printf '%s\n' "$r_line" | awk '{print $1}')
                r_orphan=$(  printf '%s\n' "$r_line" | awk '{print $2}')
                r_unver=$(   printf '%s\n' "$r_line" | awk '{print $3}')
                r_total=$(( ${r_normal:-0} + ${r_orphan:-0} + ${r_unver:-0} ))
                local rp_normal rp_orphan rp_unver
                rp_normal=$(  fmt_pct "${r_normal:-0}" "$r_total")
                rp_orphan=$(  fmt_pct "${r_orphan:-0}" "$r_total")
                rp_unver=$(   fmt_pct "${r_unver:-0}"  "$r_total")
                printf "    %-8s  NORMAL %-8s  ORPHAN %-8s  UNVERIFIED %s\n" \
                    "$rname" "$rp_normal" "$rp_orphan" "$rp_unver"
            done
        fi
    fi
}

# ---------------------------------------------------------------------------
# access_render_detail — detail view dispatcher (text | tsv | csv)
# ---------------------------------------------------------------------------

# access_render_detail
#   Purpose : Render the full detail view, routing to text or structured
#             format based on OPT_FORMAT.  Iterates the corpus tracking arrays
#             (_ACC_LABELS, _ACC_SORTED, _ACC_RNAMES) populated by the
#             correlate_* functions.
#   Args    : none (uses globals: OPT_FORMAT, _ACC_*, WORK_TMPDIR).
#   Output  : detail content on stdout (header + all corpora + optional footer).
#   Returns / Side effects : none.
#   Errors / Notes : text format is output-identical to the pre-refactor inline
#             rendering (guards A-section baselines). tsv/csv produce one header
#             row then data rows from each corpus via render_tsv/render_csv.
#             C_GREY/C_RESET passed by render_text_block are blanked by
#             fmt_set_color_state under NO_COLOR=1 in persist_views (C3/I08).
access_render_detail() {
    local i
    case "$OPT_FORMAT" in
        tsv)
            printf 'REGION\tSTATUS\tAPI_TIME\tAPP_TIME\tDELTA_SEC\tVERIFY_STATUS\tREQUEST_ID\tAPI_SERVER\tAPP_SERVER\tHOSP_ID\tPRSN_ID\tCLIENT_IP\tPATIENT_ID_AES\tBIRTHDAY\n'
            for i in "${!_ACC_SORTED[@]}"; do
                render_tsv "${_ACC_RNAMES[$i]}" "${_ACC_SORTED[$i]}"
            done
            ;;
        csv)
            printf 'REGION,STATUS,API_TIME,APP_TIME,DELTA_SEC,VERIFY_STATUS,REQUEST_ID,API_SERVER,APP_SERVER,HOSP_ID,PRSN_ID,CLIENT_IP,PATIENT_ID_AES,BIRTHDAY\n'
            for i in "${!_ACC_SORTED[@]}"; do
                render_csv "${_ACC_RNAMES[$i]}" "${_ACC_SORTED[$i]}"
            done
            ;;
        *)  # text
            fmt_h1 "Access Log Cross-Correlation Report"
            fmt_kv "Period" "${_ACC_DATE_START}  →  ${_ACC_DATE_END}  (${_ACC_N_DATES} days)"
            fmt_kv "Region filter" "$_ACC_REGION"
            for i in "${!_ACC_SORTED[@]}"; do
                render_text_block "${_ACC_LABELS[$i]}" "${_ACC_SORTED[$i]}"
            done
            fmt_footer
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Run correlation for a single region
# ---------------------------------------------------------------------------

# correlate_region REGION_ID DATE_LIST_FILE
#   Purpose : Run the full extract -> join -> sort pipeline for one region;
#             collect stats into access_stats.tsv; register corpus for rendering.
#   Steps   : (1) Collect API records across every configured API server.
#             (2) Collect APP records across every configured APP server.
#             (3) Invoke CORRELATE_AWK with both intermediates.
#             (4) Run sort pre-pass (once; feeds all renderers).
#             (5) Call access_region_stats to append dimensioned rows.
#             (6) Register result_sorted and label for access_render_detail.
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
    local srv
    for srv in "${api_servers[@]}"; do
        while IFS= read -r csv_file; do
            log_debug "  API CSV: $csv_file"
            extract_api_records "$csv_file" "$OPT_TEST_HOSTS" "$TEST_HOST_SET" >> "$api_tsv"
        done < <(collect_access_csvs "$srv" "$date_list_file")
    done

    # Extract APP records
    : > "$app_tsv"
    for srv in "${app_servers[@]}"; do
        while IFS= read -r csv_file; do
            log_debug "  APP CSV: $csv_file"
            extract_app_records "$csv_file" "$OPT_TEST_HOSTS" "$TEST_HOST_SET" >> "$app_tsv"
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

    # Aggregate stats into access_stats.tsv (single-pass via agg_access_rows)
    access_region_stats "$region_id" "$result_sorted"

    # Register corpus for access_render_detail
    local rname="${REGION_NAMES[$region_id]}"
    local label="Region: ${rname}  (${REGION_APIS[$region_id]} → ${REGION_APPS[$region_id]})"
    _ACC_LABELS+=("$label")
    _ACC_SORTED+=("$result_sorted")
    _ACC_RNAMES+=("$rname")
}

# ---------------------------------------------------------------------------
# Run correlation merged across all regions
# ---------------------------------------------------------------------------

# correlate_merged DATE_LIST_FILE
#   Purpose : Concatenate all regions' API and APP extracts, run CORRELATE_AWK
#             once (host-agnostic), apply the sort pre-pass, collect stats, and
#             register the merged corpus for rendering.
#   Args    : DATE_LIST_FILE -- file listing YYYY-MM-DD dates (one per line).
#   Output  : nothing on stdout; access_stats.tsv and _ACC_* updated.
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
                extract_api_records "$csv_file" "$OPT_TEST_HOSTS" "$TEST_HOST_SET" >> "$api_tsv"
            done < <(collect_access_csvs "$srv" "$date_list_file")
        done

        for srv in "${app_servers[@]}"; do
            while IFS= read -r csv_file; do
                log_debug "  Merged APP CSV: $csv_file"
                extract_app_records "$csv_file" "$OPT_TEST_HOSTS" "$TEST_HOST_SET" >> "$app_tsv"
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

    # Aggregate stats into access_stats.tsv
    access_region_stats "merged" "$result_sorted"

    # Register corpus for access_render_detail
    _ACC_LABELS+=("Region: all (merged)")
    _ACC_SORTED+=("$result_sorted")
    _ACC_RNAMES+=("merged")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_tmpdir
    load_regions
    TEST_HOST_SET="$(load_test_hosts "$TEST_HOSTS_CONF")"

    # Resolve interval (mutex: die on >1 selector; L2 die message cites priority)
    resolve_interval \
        --today "$OPT_TODAY" --date "$OPT_DATE" \
        --from  "$OPT_FROM"  --to   "$OPT_TO" \
        --days-set "$OPT_DAYS_SET" --days "$OPT_DAYS"

    local date_list_file="${WORK_TMPDIR}/dates.txt"
    build_date_list "${INTERVAL_ARGS[@]}" > "$date_list_file"

    _ACC_DATE_START=$(head -1 "$date_list_file")
    _ACC_DATE_END=$(tail -1 "$date_list_file")
    _ACC_N_DATES=$(count_lines "$date_list_file")
    _ACC_REGION="$OPT_REGION"

    log_info "Period: ${_ACC_DATE_START} → ${_ACC_DATE_END} (${_ACC_N_DATES} days)"
    log_info "Region: $OPT_REGION"

    # Initialise the stats file (one append target for all corpora)
    local stats_file="${WORK_TMPDIR}/access_stats.tsv"
    : > "$stats_file"

    # Run correlations: each call appends to access_stats.tsv and _ACC_* arrays
    if (( OPT_MERGE )); then
        correlate_merged "$date_list_file"
    elif [[ "$OPT_REGION" == "all" ]]; then
        local rid
        for rid in "${REGION_IDS[@]}"; do
            correlate_region "$rid" "$date_list_file"
        done
    else
        local rid
        for rid in "${REGION_IDS[@]}"; do
            if [[ "$OPT_REGION" == "$rid" ]]; then
                correlate_region "$rid" "$date_list_file"
            fi
        done
    fi

    # --emit-stats: short-circuit BEFORE persist_init (no files, no banner)
    if [[ "$OPT_EMIT_STATS" -eq 1 ]]; then
        cat "$stats_file"
        return
    fi

    persist_init "$OPT_OUTPUT_DIR"
    access_write_ip_counts

    persist_views access "$OPT_VIEW" "$OPT_FORMAT" \
        access_render_summary access_render_detail
}

main "$@"
